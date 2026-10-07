//! Инъекция перекрёстных ссылок OpenBible (`cross_references.txt`, CC-BY)
//! в готовый модуль .sb: на каждый стих — спан `x` (caller '+') с топ-N
//! ссылок в аббревиатурах профиля модуля. Координаты источника — 'eng',
//! переводятся в версификацию модуля через `Versification::convert`.
//!
//! Использование:
//!   inject_xrefs <модуль.sb> <cross_references.txt> <ru|en> [top N]

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;

use rusqlite::Connection;
use studybible_core::book::{BookCatalog, BookCode, NameProfile};
use studybible_core::versification::{VerseKey, Versification};
use studybible_store::Module;

const TOP_N: usize = 8;

/// «Gen.1.1» → VerseKey (англ. версификация источника OpenBible).
fn parse_ref(s: &str, cat: &BookCatalog) -> Option<VerseKey> {
    let (book, cv) = s.trim().split_once('.')?;
    let code = cat.by_osis(book)?.code;
    let (c, v) = cv.split_once('.')?;
    Some(VerseKey::new(code, c.parse().ok()?, v.parse().ok()?))
}

/// «Ps.148.4-Ps.148.5» или «Isa.40.28» → пара (начало, конец).
fn parse_to(s: &str, cat: &BookCatalog) -> Option<(VerseKey, VerseKey)> {
    let mut parts = s.trim().splitn(2, '-');
    let a = parse_ref(parts.next()?, cat)?;
    let b = match parts.next() {
        Some(t) => parse_ref(t, cat)?,
        None => a,
    };
    Some((a, b))
}

/// Текст ссылки в аббревиатурах профиля: «Пс 104:30», «Ин 1:1-3»,
/// «Быт 1:26-31», «Ос 4:6 – Ил 2:28» (переход через главу/книгу).
fn fmt_ref(a: VerseKey, b: VerseKey, cat: &BookCatalog, profile: NameProfile) -> String {
    let ab = |k: &VerseKey| cat.by_code(k.book).map(|x| x.abbr(profile)).unwrap_or("");
    if a.book == b.book && a.chapter == b.chapter {
        if a.verse == b.verse {
            format!("{} {}:{}", ab(&a), a.chapter, a.verse)
        } else {
            format!("{} {}:{}-{}", ab(&a), a.chapter, a.verse, b.verse)
        }
    } else if a.book == b.book {
        format!(
            "{} {}:{}-{}:{}",
            ab(&a),
            a.chapter,
            a.verse,
            b.chapter,
            b.verse
        )
    } else {
        format!(
            "{} {}:{} \u{2013} {} {}:{}",
            ab(&a),
            a.chapter,
            a.verse,
            ab(&b),
            b.chapter,
            b.verse
        )
    }
}

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        return Err("inject_xrefs <модуль.sb> <cross_references.txt> <ru|en> [top N]".into());
    }
    let path = Path::new(&args[0]);
    let top: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(TOP_N);
    // Языковой профиль аббревиатур: явный аргумент ru|en|alt,
    // иначе — name_profile модуля.
    let profile_of = |s: &str| match s {
        "ru" | "syn" => Some(NameProfile::Synodal),
        "alt" => Some(NameProfile::Alt),
        "en" => Some(NameProfile::English),
        _ => None,
    };
    let arg_profile = profile_of(&args[2]);

    let m = Module::open(path).map_err(|e| e.to_string())?;
    let profile = arg_profile
        .or_else(|| profile_of(&m.meta().name_profile))
        .ok_or_else(|| format!("профиль '{}' неизвестен", m.meta().name_profile))?;
    let mod_v = Versification::builtin(&m.meta().versification)
        .ok_or_else(|| format!("нет версификации '{}'", m.meta().versification))?;
    let eng_v = Versification::builtin("eng").unwrap();
    let cat = BookCatalog::builtin();
    let in_module: BTreeSet<String> = m
        .books()
        .map_err(|e| e.to_string())?
        .iter()
        .map(|(c, _)| c.as_str().to_string())
        .collect();

    // Ссылки из файла: from → [(to_start, to_end, votes)].
    let text = std::fs::read_to_string(&args[1]).map_err(|e| format!("{}: {e}", args[1]))?;
    let mut refs: BTreeMap<VerseKey, Vec<(VerseKey, VerseKey, i64)>> = BTreeMap::new();
    for line in text.lines().skip(1) {
        let mut it = line.split('\t');
        let (Some(f), Some(t), Some(v)) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        let (Some(fk), Some((ta, tb)), Ok(votes)) =
            (parse_ref(f, cat), parse_to(t, cat), v.trim().parse())
        else {
            continue;
        };
        refs.entry(fk).or_default().push((ta, tb, votes));
    }

    // Кандидаты на вставку: координаты версификации модуля → текст ссылки.
    let mut xref: HashMap<(BookCode, u16, u16), String> = HashMap::new();
    for (fk, mut lst) in refs {
        lst.sort_by_key(|a| std::cmp::Reverse(a.2));
        let texts: Vec<String> = lst
            .iter()
            .take(top)
            .filter_map(|(ta, tb, _)| {
                // Концы диапазона в версификацию модуля.
                let ca = eng_v.convert(mod_v, *ta).first().copied()?;
                let cb = eng_v.convert(mod_v, *tb).first().copied()?;
                Some(fmt_ref(ca, cb, cat, profile))
            })
            .collect();
        if texts.is_empty() {
            continue;
        }
        for mk in eng_v.convert(mod_v, fk) {
            // Книга цели должна быть в модуле.
            if !in_module.contains(mk.book.as_str()) {
                continue;
            }
            xref.insert((mk.book, mk.chapter, mk.verse), texts.join("; "));
        }
    }

    // Модуль открыт read-only — пишем отдельным соединением.
    let mut conn = Connection::open(path).map_err(|e| format!("{e}"))?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    // Код → book_id (схема 1.1: в spans числовой book_id, а не код).
    let book_ids: HashMap<String, i64> = {
        let mut st = tx
            .prepare("SELECT code, book_id FROM books")
            .map_err(|e| e.to_string())?;
        st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<_>>()
            .map_err(|e| e.to_string())?
    };
    let mut n_ins = 0u64;
    for ((book, ch, v), txt) in &xref {
        let Some(&bid) = book_ids.get(book.as_str()) else {
            continue;
        };
        // Первый спан стиха: у непустых стихов спаны несут verse=?, у
        // пустых — единственная строка kind='v' с num=? (verse NULL).
        let (block, vseq): (i64, i64) = match tx.query_row(
            "SELECT block, seq FROM spans
             WHERE book_id=?1 AND chapter=?2
               AND (verse=?3 OR (kind='v' AND num=?3))
             ORDER BY block, seq LIMIT 1",
            rusqlite::params![bid, ch, v],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ) {
            Ok(x) => x,
            Err(_) => continue,
        };
        // Граница вставки — перед первым спаном следующего стиха в этом
        // же блоке или в конец блока.
        let next_vseq: Option<i64> = tx
            .query_row(
                "SELECT MIN(seq) FROM spans
                 WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq>?4
                   AND (verse>?5 OR (kind='v' AND num>?5))",
                rusqlite::params![bid, ch, block, vseq, v],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let at: i64 = next_vseq.unwrap_or_else(|| {
            tx.query_row(
                "SELECT MAX(seq)+1 FROM spans WHERE book_id=?1 AND chapter=?2 AND block=?3",
                rusqlite::params![bid, ch, block],
                |r| r.get(0),
            )
            .unwrap_or(vseq + 1)
        });
        // Сдвиг seq двумя фазами: PK-конфликт, если трогать +1 напрямую.
        tx.execute(
            "UPDATE spans SET seq=seq+1000000 WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq>=?4",
            rusqlite::params![bid, ch, block, at],
        )
        .and_then(|_| {
            tx.execute(
                "UPDATE spans SET seq=seq-999999 WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq>=?4+1000000",
                rusqlite::params![bid, ch, block, at],
            )
        })
        .map_err(|e| e.to_string())?;
        // verse=NULL: позиция задаётся seq, иначе после v-маркера пустого
        // стиха читатель синтезировал бы второй маркер того же стиха.
        tx.execute(
            "INSERT INTO spans (book_id,chapter,block,seq,kind,num,verse,start,len,style,attrs,caller,text) \
             VALUES (?1,?2,?3,?4,'x',NULL,NULL,NULL,NULL,'','','+',?5)",
            rusqlite::params![bid, ch, block, at, txt],
        )
        .map_err(|e| e.to_string())?;
        n_ins += 1;
    }
    tx.commit().map_err(|e| e.to_string())?;
    println!("{}: вставлено {n_ins} ссылок-x (top {top})", m.meta().id);
    Ok(())
}
