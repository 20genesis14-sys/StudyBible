//! Модуль-слой перекрёстных ссылок (ADR 0023): `add_xref` пишет
//! `x`-спаны вне блоков, `xrefs()` отдаёт их по главе, `has_xrefs`
//! различает модули с собственными параллельными и без.

use rusqlite::Connection;
use studybible_convert::usfm;
use studybible_core::BookCode;
use studybible_core::book::{BookCatalog, BookOrder, NameProfile};
use studybible_store::{Meta, Module, ModuleWriter};

const SRC: &str = "\\id GEN\n\\h Бытие\n\
\\c 1\n\\p\n\\v 1 Первый.\n\\v 2 Второй.\n\\c 3\n\\v 1 Третья глава.\n";

fn meta() -> Meta {
    Meta {
        id: "t".into(),
        language: "ru".into(),
        versification: "rsc".into(),
        ..Meta::default()
    }
}

/// Обычный текстовый модуль без `x`-спанов.
fn build_bible(path: &std::path::Path) {
    let b = usfm::parse(SRC).unwrap();
    let mut w = ModuleWriter::create(path, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
}

/// Слой: книги + строки `x` без глав и текста.
fn build_layer(path: &std::path::Path) {
    let mut w = ModuleWriter::create(
        path,
        &Meta {
            id: "openbible-xrefs".into(),
            versification: "eng".into(),
            kind: "layer".into(),
            features: vec!["xrefs".into()],
            ..Meta::default()
        },
    )
    .unwrap();
    let cat = BookCatalog::builtin();
    for b in cat.ordered(BookOrder::List) {
        w.add_book(
            b.code,
            b.order(BookOrder::List).unwrap(),
            b.name(NameProfile::English),
            &Default::default(),
        )
        .unwrap();
    }
    let gen_ = BookCode::new("GEN").unwrap();
    let psa = BookCode::new("PSA").unwrap();
    w.add_xref(gen_, 1, 1, 0, "Ps 33:6; John 1:1").unwrap();
    w.add_xref(gen_, 1, 2, 1, "2Cor 4:6").unwrap();
    w.add_xref(psa, 104, 30, 0, "Gen 1:2").unwrap();
    w.finish().unwrap();
}

#[test]
fn layer_xrefs_read_back() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("layer.sb");
    build_layer(&p);
    let m = Module::open(&p).unwrap();

    assert!(m.has_xrefs());
    assert_eq!(m.meta().kind, "layer");
    let xs = m.xrefs(BookCode::new("GEN").unwrap(), 1).unwrap();
    assert_eq!(
        xs,
        vec![(1, "Ps 33:6; John 1:1".to_string()), (2, "2Cor 4:6".into())]
    );
    // Главы/стихи без ссылок — пусто, не ошибка.
    assert!(
        m.xrefs(BookCode::new("GEN").unwrap(), 3)
            .unwrap()
            .is_empty()
    );
    assert!(
        m.xrefs(BookCode::new("EXO").unwrap(), 1)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn bible_without_xrefs_reports_false() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    build_bible(&p);
    let m = Module::open(&p).unwrap();

    assert!(!m.has_xrefs());
    assert!(
        m.xrefs(BookCode::new("GEN").unwrap(), 1)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn layer_has_no_chapter_text() {
    // Слой — не читаемый перевод: главы пусты, но файл валиден.
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("layer.sb");
    build_layer(&p);
    let m = Module::open(&p).unwrap();
    assert!(
        m.chapter(BookCode::new("GEN").unwrap(), 1)
            .unwrap()
            .is_none()
    );

    // x-строки видны прямым SQL — схема прозрачна для сторонних.
    let conn = Connection::open(&p).unwrap();
    let n: i64 = conn
        .query_row("SELECT count(*) FROM spans WHERE kind='x'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(n, 3);
}
