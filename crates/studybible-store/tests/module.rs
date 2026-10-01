//! Формат модуля v1: круговая запись/чтение и защищённое открытие.

use std::fs;

use rusqlite::Connection;
use studybible_convert::usfm;
use studybible_core::text::Span;
use studybible_core::{BookCode, BookOrder, NameProfile};
use studybible_store::{Meta, Module, ModuleError, ModuleWriter};

const GEN_USFM: &str = "\\id GEN Russian test\n\
\\h Бытие\n\
\\toc1 Бытие\n\
\\mt1 Бытие\n\
\\c 1\n\
\\p\n\
\\v 1 В начале сотворил Бог небо и землю.\n\
\\v 2 Земля же была безвидна и пуста.\n\
\\s1 Отделение света\n\
\\v 3 И сказал Бог: да будет свет.\\f + \\ft Сноска.\\f* И стал свет.\n\
\\c 2\n\
\\v 1 Так совершены небо и земля.\n";

fn meta() -> Meta {
    Meta {
        id: "test-syn".into(),
        title: "Синодальный".into(),
        language: "ru".into(),
        direction: "ltr".into(),
        versification: "rsc".into(),
        name_profile: "syn".into(),
        book_order: "syn".into(),
        version: "1.0.0".into(),
        license: "public domain".into(),
        attribution: "eBible.org".into(),
        source: "russyn".into(),
        ..Meta::default()
    }
}

fn build(path: &std::path::Path) -> usfm::Book {
    let book = usfm::parse(GEN_USFM).unwrap();
    let mut w = ModuleWriter::create(path, &meta()).unwrap();
    w.add_book(book.code, 1, "Бытие", &book.header).unwrap();
    for ch in &book.chapters {
        w.add_chapter(book.code, ch).unwrap();
    }
    w.finish().unwrap();
    book
}

#[test]
fn roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gen.sb");
    let src = build(&path);

    let m = Module::open(&path).unwrap();
    assert_eq!(m.meta().id, "test-syn");
    assert_eq!(m.meta().versification, "rsc");
    assert_eq!(m.meta().license, "public domain");
    assert_eq!(m.meta().content_hash.len(), 64);
    assert_eq!(
        m.books().unwrap(),
        vec![(BookCode::new("GEN").unwrap(), "Бытие".to_string())]
    );
    assert_eq!(
        m.book_header(BookCode::new("GEN").unwrap(), "toc1")
            .unwrap()
            .as_deref(),
        Some("Бытие")
    );

    let cat = studybible_core::BookCatalog::builtin();
    assert_eq!(
        cat.by_code(BookCode::new("GEN").unwrap())
            .unwrap()
            .order(BookOrder::List),
        Some(1)
    );
    assert_eq!(
        cat.by_code(BookCode::new("GEN").unwrap())
            .unwrap()
            .abbr(NameProfile::Synodal),
        "Быт"
    );

    let ch = m
        .chapter(BookCode::new("GEN").unwrap(), 1)
        .unwrap()
        .unwrap();
    let orig = src.chapter(1).unwrap();
    assert_eq!(ch, *orig, "поток чтения сохраняется один в один");
    for v in 1..=3 {
        assert_eq!(
            m.verse_text(BookCode::new("GEN").unwrap(), 1, v).unwrap(),
            orig.verse_text(v)
        );
    }
    // Заголовок не вошёл в текст стиха; сноска сохранилась.
    assert_eq!(
        m.verse_text(BookCode::new("GEN").unwrap(), 1, 3)
            .unwrap()
            .as_deref(),
        Some("И сказал Бог: да будет свет. И стал свет.")
    );
    let has_note = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .any(|s| matches!(s, Span::Note { kind: 'f', .. }));
    assert!(has_note);
}

#[test]
fn defensive_open() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("gen.sb");
    build(&path);
    let m = Module::open(&path).unwrap();

    // Только чтение.
    let r = m.conn().execute("CREATE TABLE t(x)", []);
    assert!(r.is_err(), "запись запрещена");
    // Формулы в схеме отключены.
    assert!(m.conn().execute("SELECT load_extension('x')", []).is_err());
}

#[test]
fn rejects_bad_files() {
    let dir = tempfile::tempdir().unwrap();

    // Не SQLite.
    let garbage = dir.path().join("garbage.sb");
    fs::write(&garbage, b"not a database").unwrap();
    assert!(matches!(
        Module::open(&garbage),
        Err(ModuleError::Sqlite(_)) | Err(ModuleError::BadFormat(_))
    ));

    // SQLite без нашей схемы.
    let plain = dir.path().join("plain.db");
    Connection::open(&plain)
        .unwrap()
        .execute_batch("CREATE TABLE x(y)")
        .unwrap();
    assert!(matches!(
        Module::open(&plain),
        Err(ModuleError::BadFormat(_))
    ));

    // Модуль с неверной версией формата.
    let wrong = dir.path().join("wrong.sb");
    build(&wrong);
    Connection::open(&wrong)
        .unwrap()
        .execute("UPDATE meta SET value='99' WHERE key='format_version'", [])
        .unwrap();
    assert!(matches!(
        Module::open(&wrong),
        Err(ModuleError::BadFormat(_))
    ));

    // Модуль с неподдерживаемой обязательной возможностью.
    let need = dir.path().join("need.sb");
    build(&need);
    Connection::open(&need)
        .unwrap()
        .execute(
            "UPDATE meta SET value='encryption' WHERE key='required'",
            [],
        )
        .unwrap();
    assert!(matches!(
        Module::open(&need),
        Err(ModuleError::UnsupportedFeature(_))
    ));

    // Модуль без таблицы.
    let truncated = dir.path().join("truncated.sb");
    build(&truncated);
    Connection::open(&truncated)
        .unwrap()
        .execute("DROP TABLE spans", [])
        .unwrap();
    assert!(matches!(
        Module::open(&truncated),
        Err(ModuleError::BadFormat(_))
    ));
}

#[test]
fn content_hash_changes_with_content() {
    let dir = tempfile::tempdir().unwrap();
    let p1 = dir.path().join("a.sb");
    build(&p1);
    let h1 = Module::open(&p1).unwrap().meta().content_hash.clone();

    let p2 = dir.path().join("b.sb");
    let mut book = usfm::parse(GEN_USFM).unwrap();
    for ch in &mut book.chapters {
        for b in &mut ch.blocks {
            for s in &mut b.spans {
                if let Span::Text { text, .. } = s {
                    *text = text.replace("свет", "тьма");
                }
            }
        }
    }
    let mut w = ModuleWriter::create(&p2, &meta()).unwrap();
    w.add_book(book.code, 1, "Бытие", &book.header).unwrap();
    for ch in &book.chapters {
        w.add_chapter(book.code, ch).unwrap();
    }
    w.finish().unwrap();
    let h2 = Module::open(&p2).unwrap().meta().content_hash.clone();

    assert_ne!(h1, h2);
}
