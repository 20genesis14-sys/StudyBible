//! Сквозной тест `inject_xrefs`: минимальный модуль .sb через
//! ModuleWriter + синтетический cross_references.txt → бинарник
//! вставляет спаны `x` в конец стиха со сдвигом seq без дыр.

use std::path::Path;
use std::process::Command;

use studybible_core::BookCode;
use studybible_core::text::Span;
use studybible_store::{Meta, Module, ModuleWriter};

fn make_module(path: &Path) {
    let meta = Meta {
        id: "t".into(),
        language: "ru".into(),
        // Координаты источника OpenBible — 'eng'; модуль тоже 'eng',
        // перевод версификаций — тождество.
        versification: "eng".into(),
        name_profile: "syn".into(),
        ..Meta::default()
    };
    let mut w = ModuleWriter::create(path, &meta).unwrap();
    let bk = BookCode::new("GEN").unwrap();
    w.add_book(bk, 1, "Бытие", &Default::default()).unwrap();
    for c in &studybible_convert::usfm::parse(
        "\\id GEN\n\\c 1\n\\p \\v 1 Первый. \\v 2 Второй. \\v 3 Третий.\n",
    )
    .unwrap()
    .chapters
    {
        w.add_chapter(bk, c).unwrap();
    }
    w.finish().unwrap();
}

#[test]
fn injects_x_spans_before_next_verse() {
    let dir = tempfile::tempdir().unwrap();
    let sb = dir.path().join("m.sb");
    make_module(&sb);
    let xrefs = dir.path().join("cross_references.txt");
    std::fs::write(
        &xrefs,
        "From Verse\tTo Verse\t# Votes\n\
         Gen.1.1\tPs.104.30\t5\n\
         Gen.1.2\tIsa.40.28-Isa.40.29\t7\n\
         Gen.1.3\tPs.1.1\t1\n\
         Gen.1.99\tPs.2.1\t9\n\
         бред\tбред\tбред\n",
    )
    .unwrap();

    let out = Command::new(env!("CARGO_BIN_EXE_inject_xrefs"))
        .args([sb.to_str().unwrap(), xrefs.to_str().unwrap(), "ru"])
        .output()
        .expect("запуск inject_xrefs");
    assert!(
        out.status.success(),
        "inject_xrefs: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    // Три реальных стиха получили ссылки; Gen.1.99 и битая строка
    // отброшены.
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("вставлено 3"), "stdout: {stdout}");

    let m = Module::open(&sb).unwrap();
    let ch = m
        .chapter(BookCode::new("GEN").unwrap(), 1)
        .unwrap()
        .unwrap();
    let spans = &ch.blocks[0].spans;
    // Порядок: x стиха 1 — после текста стиха 1, но перед маркером
    // стиха 2; x стиха 3 — в конец блока.
    let kinds: Vec<String> = spans
        .iter()
        .map(|s| match s {
            Span::Verse(n) => format!("v{n}"),
            Span::Text { text, .. } => format!("t:{text}"),
            Span::Note { kind, text, .. } => format!("{kind}:{text}"),
        })
        .collect();
    assert_eq!(
        kinds,
        [
            "v1",
            "t:Первый. ",
            "x:Пс 104:30",
            "v2",
            "t:Второй. ",
            "x:Ис 40:28-29",
            "v3",
            "t:Третий. ",
            "x:Пс 1:1",
        ],
        "spans: {kinds:?}"
    );
}

#[test]
fn inject_xrefs_requires_args() {
    let out = Command::new(env!("CARGO_BIN_EXE_inject_xrefs"))
        .output()
        .unwrap();
    assert!(!out.status.success());
}
