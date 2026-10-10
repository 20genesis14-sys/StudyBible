//! ADR 0022: блоб-упаковка `t`-спанов, токенов и alignment.
//! Проверяем эквивалентность чтения, метку `required="pack"`,
//! физику файла (строк нет) и чтение старых строковых модулей.

use rusqlite::Connection;
use studybible_convert::usfm;
use studybible_core::BookCode;
use studybible_store::{Meta, Module, ModuleWriter};

const SRC: &str = "\\id GEN\n\\h Бытие\n\\toc1 Бытие\n\
\\c 1\n\\p\n\
\\v 1 \\w В|strong=\"H7225\"\\w* \\w начале|strong=\"H7225\"\\w* сотворил Бог небо.\\f + \\ft Сноска.\\f*\n\
\\v 2 Земля же была безвидна.\n\
\\x + \\xo 1:1 \\xt Параллельное место\\x*\n";

fn meta() -> Meta {
    Meta {
        id: "t-pack".into(),
        language: "ru".into(),
        versification: "rsc".into(),
        ..Meta::default()
    }
}

fn build(path: &std::path::Path) -> usfm::Book {
    let b = usfm::parse(SRC).unwrap();
    let mut w = ModuleWriter::create(path, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
    b
}

#[test]
fn packed_module_roundtrips() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("genb.sb");
    let src = build(&path);
    let m = Module::open(&path).unwrap();

    // Логический поток чтения не изменился.
    let genb = BookCode::new("GEN").unwrap();
    let ch = m.chapter(genb, 1).unwrap().unwrap();
    assert_eq!(&ch, src.chapter(1).unwrap());

    // Токены и alignment распаковались.
    let toks = m.tokens(genb, 1).unwrap();
    assert!(toks.len() >= 2, "ожидались токены w-спанов");
    assert_eq!(toks[0].strong, "H7225");
    assert_eq!(toks[0].surface, "В");
    let al = m.alignment(genb, 1).unwrap();
    assert_eq!(al.len(), toks.len());
    assert!(al.iter().all(|a| a.token_seq < toks.len() as u16));

    // Метка обязательной возможности выставлена.
    assert!(m.meta().required.iter().any(|r| r == "pack"));
}

#[test]
fn pack_tables_hold_data() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("genb.sb");
    build(&path);

    // Физика: t-строк нет в spans, блобы есть в pack-таблицах.
    let conn = Connection::open(&path).unwrap();
    let t_rows: i64 = conn
        .query_row("SELECT count(*) FROM spans WHERE kind='t'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(t_rows, 0);
    let packed: i64 = conn
        .query_row("SELECT count(*) FROM span_pack", [], |r| r.get(0))
        .unwrap();
    assert!(packed > 0);
    let tok_packed: i64 = conn
        .query_row("SELECT count(*) FROM token_pack", [], |r| r.get(0))
        .unwrap();
    assert!(tok_packed > 0);
    // f/x/v остаются построчными.
    let fx: i64 = conn
        .query_row(
            "SELECT count(*) FROM spans WHERE kind IN ('f','x')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(fx, 2);
}

#[test]
fn legacy_row_module_still_reads() {
    // Строковый модуль «как раньше»: собираем вручную без pack-таблиц.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("legacy.sb");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "PRAGMA application_id = 0x53424D31;
         CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
         CREATE TABLE books(book_id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL,
                            ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
         CREATE TABLE book_headers(book_id INTEGER NOT NULL, marker TEXT NOT NULL,
                            text TEXT NOT NULL, PRIMARY KEY(book_id, marker));
         CREATE TABLE blocks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                            seq INTEGER NOT NULL, marker TEXT NOT NULL DEFAULT '',
                            PRIMARY KEY(book_id, chapter, seq));
         CREATE TABLE spans(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                            block INTEGER NOT NULL, seq INTEGER NOT NULL,
                            kind TEXT NOT NULL, num INTEGER, verse INTEGER,
                            start INTEGER, len INTEGER, style TEXT NOT NULL DEFAULT '',
                            attrs TEXT NOT NULL DEFAULT '', caller TEXT NOT NULL DEFAULT '',
                            text TEXT NOT NULL DEFAULT '',
                            PRIMARY KEY(book_id, chapter, block, seq));
         CREATE TABLE verses(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                            verse INTEGER NOT NULL, text TEXT NOT NULL,
                            PRIMARY KEY(book_id, chapter, verse));
         INSERT INTO meta VALUES('format_version','1'),('id','legacy'),('language','ru'),
            ('versification','rsc'),('required','');
         INSERT INTO books VALUES(1,'GEN',1,'Бытие');
         INSERT INTO blocks VALUES(1,1,0,'p');
         INSERT INTO spans VALUES(1,1,0,0,'t',NULL,1,0,12,'w','strong=\"H1\"','','');
         INSERT INTO verses VALUES(1,1,1,'Первый');
        ",
    )
    .unwrap();
    drop(conn);

    let m = Module::open(&path).unwrap();
    let genb = BookCode::new("GEN").unwrap();
    let ch = m.chapter(genb, 1).unwrap().unwrap();
    // t-спан восстановил текст из verses по (start,len).
    assert_eq!(m.verse_text(genb, 1, 1).unwrap().as_deref(), Some("Первый"));
    assert!(
        ch.blocks[0].spans.iter().any(
            |s| matches!(s, studybible_core::text::Span::Text { text, .. } if text == "Первый")
        )
    );
    assert!(m.tokens(genb, 1).unwrap().is_empty());
    assert!(m.alignment(genb, 1).unwrap().is_empty());
}

#[test]
fn unknown_required_still_rejected() {
    // Обязательная возможность, которой нет, — по-прежнему отказ.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("genb.sb");
    build(&path);
    {
        let conn = Connection::open(&path).unwrap();
        conn.execute(
            "UPDATE meta SET value='pack,hyperspace' WHERE key='required'",
            [],
        )
        .unwrap();
    }
    match Module::open(&path) {
        Err(studybible_store::ModuleError::UnsupportedFeature(f)) => {
            assert_eq!(f, "hyperspace")
        }
        Err(e) => panic!("ожидался UnsupportedFeature, получено {e}"),
        Ok(_) => panic!("ожидался UnsupportedFeature, модуль открылся"),
    }
}
