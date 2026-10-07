//! Эталон версификаций: канонический снимок `to_org`/`from_org` по всем
//! строкам-соответствиям `.vrs` и выборочные cross-конверсии —
//! `data/tests/vrs_golden.json`. Тот же файл проверяет Dart-порт
//! (`apps/studybible-flutter/test/vrs_golden_test.dart`), так что любое
//! расхождение портов всплывает сразу.
//!
//! Перегенерация после правок `.vrs`/логики:
//!   VRS_GOLDEN=write cargo test -p studybible-core --test vrs_golden
//! (см. data/tests/README.md).

use std::collections::BTreeMap;
use std::path::PathBuf;

use studybible_core::versification::BUILTIN;
use studybible_core::{BookCode, VerseKey, Versification};

fn repo() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn golden_path() -> PathBuf {
    repo().join("data/tests/vrs_golden.json")
}

fn fmt_key(k: VerseKey) -> String {
    format!("{} {}:{}", k.book, k.chapter, k.verse)
}

/// Развернуть сторону соответствия `BOOK c:v` / `BOOK c:v-w` — зеркало
/// приватного `expand()` из versification.rs, чтобы перечислить стихи
/// каждой строки `.vrs` (движок их не отдаёт).
fn expand(side: &str) -> Option<Vec<VerseKey>> {
    let side = side.trim();
    match side.split_once('-') {
        None => Some(vec![VerseKey::parse(side)?]),
        Some((start, end)) => {
            let s = VerseKey::parse(start)?;
            let end: u16 = end
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .ok()?;
            (s.verse <= end).then(|| {
                (s.verse..=end)
                    .map(|verse| VerseKey { verse, ..s })
                    .collect()
            })
        }
    }
}

/// Запросы cross-конверсий: rsc↔eng для псалмов 89/90 и 141/142
/// (смещение на псалом и надписания-стихи 0), vul: DAG→S3Y/SUS/BEL.
fn cross_queries() -> Vec<(&'static str, &'static str, VerseKey)> {
    fn k(b: &str, c: u16, v: u16) -> VerseKey {
        VerseKey::new(BookCode::new(b).unwrap(), c, v)
    }
    let mut out = Vec::new();
    for ch in [89u16, 90, 141, 142] {
        let max = 25; // верхний предел разгона; лишние стихи просто снимаем
        for v in 0..=max {
            out.push(("rsc", "eng", k("PSA", ch, v)));
            out.push(("eng", "rsc", k("PSA", ch, v)));
        }
    }
    for (c, v) in [(3, 52), (3, 53), (13, 1), (13, 63), (14, 42)] {
        out.push(("vul", "org", k("DAG", c, v)));
        out.push(("org", "vul", k("DAG", c, v)));
    }
    for v in [29u16, 30, 31] {
        out.push(("org", "vul", k("S3Y", 1, v)));
    }
    for v in [1u16, 63] {
        out.push(("org", "vul", k("SUS", 1, v)));
    }
    out
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn json_list(v: &[String]) -> String {
    format!(
        "[{}]",
        v.iter()
            .map(|s| format!("\"{}\"", json_escape(s)))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// Полный эталон: по каждой версификации — skipped-строки, to_org для
/// всех стихов левых сторон соответствий, from_org для всех стихов
/// правых сторон; плюс cross-конверсии.
fn generate() -> String {
    let mut out = String::from("{\n  \"vrs\": {\n");
    let mut vrs_chunks = Vec::new();
    for name in BUILTIN {
        let text =
            std::fs::read_to_string(repo().join(format!("data/versification/{name}.vrs"))).unwrap();
        let v = Versification::builtin(name).unwrap();
        let mut to_org: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut from_org: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for raw in text.lines() {
            let line = raw.split('#').next().unwrap_or("").trim();
            let Some((lhs, rhs)) = line.split_once('=') else {
                continue;
            };
            for key in expand(lhs).into_iter().flatten() {
                to_org.insert(
                    fmt_key(key),
                    v.to_org(key).iter().map(|k| fmt_key(*k)).collect(),
                );
            }
            for key in expand(rhs).into_iter().flatten() {
                from_org.insert(
                    fmt_key(key),
                    v.from_org(key).iter().map(|k| fmt_key(*k)).collect(),
                );
            }
        }
        let map_json = |m: &BTreeMap<String, Vec<String>>, ind: &str| {
            m.iter()
                .map(|(k, vs)| format!("{ind}\"{}\": {}", json_escape(k), json_list(vs)))
                .collect::<Vec<_>>()
                .join(",\n")
        };
        vrs_chunks.push(format!(
            "    \"{name}\": {{\n      \"skipped\": {},\n      \"to_org\": {{\n{}\n      }},\n      \"from_org\": {{\n{}\n      }}\n    }}",
            json_list(&v.skipped().iter().map(|s| s.to_string()).collect::<Vec<_>>()),
            map_json(&to_org, "        "),
            map_json(&from_org, "        "),
        ));
    }
    out.push_str(&vrs_chunks.join(",\n"));
    out.push_str("\n  },\n  \"cross\": [\n");

    // Кросс-запросы: фиксируем и запрос, и ответ — Dart-сторона
    // проигрывает те же запросы.
    let mut lines = Vec::new();
    for (from, to, key) in cross_queries() {
        let vf = Versification::builtin(from).unwrap();
        let vt = Versification::builtin(to).unwrap();
        let result: Vec<String> = vf.convert(vt, key).iter().map(|k| fmt_key(*k)).collect();
        lines.push(format!(
            "    {{\"from\": \"{from}\", \"to\": \"{to}\", \"key\": \"{}\", \"result\": {}}}",
            json_escape(&fmt_key(key)),
            json_list(&result),
        ));
    }
    out.push_str(&lines.join(",\n"));
    out.push_str("\n  ]\n}\n");
    out
}

#[test]
fn vrs_golden_matches() {
    let generated = generate();
    let path = golden_path();
    if std::env::var_os("VRS_GOLDEN").is_some_and(|v| v == "write") {
        std::fs::write(&path, &generated).unwrap();
        eprintln!("vrs_golden: переписан {}", path.display());
        return;
    }
    let saved = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{}: {e} — сгенерируйте с VRS_GOLDEN=write", path.display()));
    if saved != generated {
        // Первая расходящаяся строка — для быстрого разбора.
        for (i, (a, b)) in saved.lines().zip(generated.lines()).enumerate() {
            assert_eq!(a, b, "расхождение в строке {}", i + 1);
        }
        assert_eq!(
            saved.len(),
            generated.len(),
            "разная длина эталона — перегенерируйте с VRS_GOLDEN=write"
        );
    }
}
