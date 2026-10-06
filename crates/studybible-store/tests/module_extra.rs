//! Модуль v1: детерминизм хэша, метаданные, пропуски, неизвестные виды промежутков.

use rusqlite::Connection;
use studybible_convert::usfm;
use studybible_core::BookCode;
use studybible_core::text::Span;
use studybible_store::{Meta, Module, ModuleError, ModuleWriter};

const SRC: &str = "\\id GEN\n\\h Бытие\n\\toc1 Бытие\n\
\\c 1\n\\p\n\\v 1 Первый.\\f + \\ft сноска\\f*\n\\v 2 Второй.\n\
\\c 3\n\\v 1 Третья глава.\n";

fn meta() -> Meta {
    Meta {
        id: "t".into(),
        language: "ru".into(),
        versification: "rsc".into(),
        ..Meta::default()
    }
}

fn build(path: &std::path::Path) {
    let b = usfm::parse(SRC).unwrap();
    let mut w = ModuleWriter::create(path, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
}

#[test]
fn hash_deterministic() {
    let dir = tempfile::tempdir().unwrap();
    let p1 = dir.path().join("a.sb");
    let p2 = dir.path().join("b.sb");
    build(&p1);
    build(&p2);
    let h1 = Module::open(&p1).unwrap().meta().content_hash.clone();
    let h2 = Module::open(&p2).unwrap().meta().content_hash.clone();
    assert_eq!(h1, h2, "одинаковое содержимое → одинаковый хэш");
}

#[test]
fn hash_ignores_meta_but_counts_structure() {
    let dir = tempfile::tempdir().unwrap();
    let p1 = dir.path().join("a.sb");
    build(&p1);
    // Меняем только meta — хэш тот же.
    let p2 = dir.path().join("b.sb");
    let b = usfm::parse(SRC).unwrap();
    let mut meta2 = meta();
    meta2.title = "Другое название".into();
    let mut w = ModuleWriter::create(&p2, &meta2).unwrap();
    w.add_book(b.code, 1, "X", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
    let h1 = Module::open(&p1).unwrap().meta().content_hash.clone();
    let h2 = Module::open(&p2).unwrap().meta().content_hash.clone();
    assert_eq!(h1, h2, "meta не входит в хэш содержимого");
}

#[test]
fn extra_meta_keys_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    let b = usfm::parse(SRC).unwrap();
    let mut meta = meta();
    meta.extra.insert("translator".into(), "кто-то".into());
    meta.extra
        .insert("ot.source.url".into(), "https://example".into());
    let mut w = ModuleWriter::create(&p, &meta).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
    let m = Module::open(&p).unwrap();
    assert_eq!(
        m.meta().extra.get("translator").map(String::as_str),
        Some("кто-то")
    );
    assert_eq!(
        m.meta().extra.get("ot.source.url").map(String::as_str),
        Some("https://example")
    );
}

#[test]
fn missing_content() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    build(&p);
    let m = Module::open(&p).unwrap();
    let g = BookCode::new("GEN").unwrap();
    let exo = BookCode::new("EXO").unwrap();
    // Глава 2 не записана (в источнике её нет).
    assert!(m.chapter(g, 2).unwrap().is_none());
    assert!(m.chapter(g, 999).unwrap().is_none());
    assert!(m.chapter(exo, 1).unwrap().is_none());
    assert!(m.verse_text(g, 1, 99).unwrap().is_none());
    assert!(m.verse_text(exo, 1, 1).unwrap().is_none());
    assert!(m.book_header(g, "неттакого").unwrap().is_none());
}

#[test]
fn unknown_span_kind_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    build(&p);
    // Вставляем промежуток неизвестного вида — чтение должно его пропустить,
    // не сломав остальную главу.
    let conn = Connection::open(&p).unwrap();
    conn.execute(
        "INSERT INTO spans VALUES('GEN', 1, 0, 99, 'z', NULL, '', '', '', 'тайное')",
        [],
    )
    .unwrap();
    drop(conn);
    let m = Module::open(&p).unwrap();
    let ch = m
        .chapter(BookCode::new("GEN").unwrap(), 1)
        .unwrap()
        .unwrap();
    assert!(
        ch.blocks
            .iter()
            .flat_map(|b| &b.spans)
            .all(|s| !matches!(s, Span::Text { text, .. } if text == "тайное"))
    );
    assert_eq!(
        m.verse_text(BookCode::new("GEN").unwrap(), 1, 1).unwrap(),
        Some("Первый.".into())
    );
}

#[test]
fn open_missing_file() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("нет.sb");
    assert!(matches!(
        Module::open(&p),
        Err(ModuleError::Sqlite(_)) | Err(ModuleError::Io(_))
    ));
}

#[test]
fn open_directory_fails() {
    let dir = tempfile::tempdir().unwrap();
    assert!(Module::open(dir.path()).is_err());
}

#[test]
fn books_ordered() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    let g = usfm::parse(SRC).unwrap();
    let e = usfm::parse("\\id EXO\n\\h Исход\n\\c 1\n\\v 1 А.").unwrap();
    let mut w = ModuleWriter::create(&p, &meta()).unwrap();
    // Пишем Исход первым, но ord у Бытия меньше → books() по ord.
    w.add_book(e.code, 2, "Исход", &e.header).unwrap();
    w.add_book(g.code, 1, "Бытие", &g.header).unwrap();
    for ch in &g.chapters {
        w.add_chapter(g.code, ch).unwrap();
    }
    for ch in &e.chapters {
        w.add_chapter(e.code, ch).unwrap();
    }
    w.finish().unwrap();
    let m = Module::open(&p).unwrap();
    let codes: Vec<String> = m
        .books()
        .unwrap()
        .iter()
        .map(|(c, _)| c.as_str().to_string())
        .collect();
    assert_eq!(codes, ["GEN", "EXO"]);
}

const SRC_WORDS: &str = "\\id GEN\n\\h Бытие\n\\toc1 Бытие\n\
\\c 1\n\\p\n\\v 1 \\w Вначале|strong=\"H7225\" lemma=\"בראשית\"\\w* \
\\w сотворил|strong=\"H1254\" morph=\"qalive\"\\w* Бог.\n\
\\v 2 \\w Земля|gr=\"אָרֶץ\"\\w* же.\n";

#[test]
fn tokens_written_and_read() {
    // ADR 0016: токены выводятся из спанов с attrs/стилем 'w' —
    // конвертеру не нужно отдельного кода.
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    let b = usfm::parse(SRC_WORDS).unwrap();
    let mut w = ModuleWriter::create(&p, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    assert!(w.tokens_written() > 0);
    w.finish().unwrap();

    let m = Module::open(&p).unwrap();
    let toks = m.tokens(BookCode::new("GEN").unwrap(), 1).unwrap();
    assert!(toks.len() >= 3, "токены записаны: {toks:?}");
    assert_eq!(toks[0].verse, 1);
    assert_eq!(toks[0].seq, 0);
    assert_eq!(toks[0].surface, "Вначале");
    assert_eq!(toks[0].strong, "H7225");
    assert_eq!(toks[0].lemma, "בראשית");
    // Пара подстрочника: gr — слово оригинала, текст — глосса.
    let last = toks.last().unwrap();
    assert_eq!(last.verse, 2);
    assert_eq!(last.surface, "אָרֶץ");
    assert_eq!(last.gloss, "Земля");
}

#[test]
fn kind_features_rights_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    let b = usfm::parse(SRC).unwrap();
    let mut meta = meta();
    meta.kind = "interlinear".into();
    meta.features = vec!["strongs".into(), "tokens".into()];
    meta.rights = vec!["no-distribute".into(), "no-ai".into()];
    let mut w = ModuleWriter::create(&p, &meta).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
    let m = Module::open(&p).unwrap();
    assert_eq!(m.meta().kind, "interlinear");
    assert_eq!(m.meta().features, ["strongs", "tokens"]);
    assert_eq!(m.meta().rights, ["no-distribute", "no-ai"]);
    // Новые ключи не протекают в extra.
    assert!(!m.meta().extra.contains_key("kind"));
    assert!(!m.meta().extra.contains_key("features"));
    assert!(!m.meta().extra.contains_key("rights"));
}

#[test]
fn create_twice_fails() {
    // Повторная запись поверх существующего файла — ошибка схемы.
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("a.sb");
    build(&p);
    assert!(ModuleWriter::create(&p, &meta()).is_err());
}
