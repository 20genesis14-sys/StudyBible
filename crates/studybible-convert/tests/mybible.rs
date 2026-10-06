//! Тесты конвертера MyBible: синтетические базы SQLite в temp-каталоге.

use rusqlite::Connection;
use studybible_convert::mybible;
use studybible_core::text::Span;

fn bible_db() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("test.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE info(name TEXT, value TEXT);
         CREATE TABLE books(book_number INT, short_name TEXT, long_name TEXT);
         CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         CREATE TABLE stories(book_number INT, chapter INT, verse INT,
                              order_if_several INT, title TEXT);",
    )
    .unwrap();
    conn.execute(
        "INSERT INTO info VALUES('description','Тест'),('language','ru'),
         ('strong_numbers_prefix','')",
        [],
    )
    .unwrap();
    conn.execute_batch(
        "INSERT INTO books VALUES(10,'Быт','Бытие'),(500,'Ин','Евангелие от Иоанна');
         INSERT INTO verses VALUES
          (10,1,1,'В <i>начале</i> сотворил<S>1254</S> Бог небо.<f>сноска к стиху</f>'),
          (10,1,2,'Земля<pb/>же была <J>пуста</J>.'),
          (500,1,1,'В начале было<S>3056</S> Слово.'),
          (500,1,2,'Оно было у <e>Бога</e>.<n>примечание</n>');
         INSERT INTO stories VALUES(10,1,1,0,'Сотворение мира');",
    )
    .unwrap();
    dir
}

#[test]
fn bible_books_strong_notes_stories() {
    let dir = bible_db();
    let books = mybible::parse_file(&dir.path().join("test.SQLite3")).unwrap();
    assert_eq!(books.len(), 2);
    assert_eq!(books[0].code.as_str(), "GEN");
    assert_eq!(books[1].code.as_str(), "JHN");
    assert_eq!(books[0].header.get("toc1").unwrap(), "Бытие");

    let first = &books[0];
    let ch1 = first.chapter(1).unwrap();
    // Заголовок раздела из stories перед первым стихом.
    assert!(ch1.blocks.iter().any(|b| b.marker == "s1"));
    // Стих 1: курсив «начале» → add; <S> на слове «сотворил» → w+strong H;
    // <f> → сноска.
    let mut saw_add = false;
    let mut saw_w = false;
    let mut saw_f = false;
    for b in &ch1.blocks {
        for s in &b.spans {
            match s {
                Span::Text { text, style, attrs } => {
                    if style == "add" && text.contains("начале") {
                        saw_add = true;
                    }
                    if style == "w" && text.contains("сотворил") && attrs.contains("H1254")
                    {
                        saw_w = true;
                    }
                }
                Span::Note { kind, text, .. } if *kind == 'f' && text.contains("сноска") => {
                    saw_f = true;
                }
                _ => {}
            }
        }
    }
    assert!(saw_add && saw_w && saw_f, "{:?}", ch1.blocks);

    // НЗ: префикс G.
    let jhn = &books[1];
    let mut g = false;
    for b in &jhn.chapters[0].blocks {
        for s in &b.spans {
            if let Span::Text { style, attrs, .. } = s
                && style == "w"
                && attrs.contains("G3056")
            {
                g = true;
            }
        }
    }
    assert!(g);
}

#[test]
fn unknown_book_number_is_error() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("bad.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE info(name TEXT, value TEXT);
         CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO verses VALUES(999,1,1,'текст');",
    )
    .unwrap();
    let e = mybible::parse_file(&dir.path().join("bad.SQLite3")).unwrap_err();
    assert!(e.0.contains("999"), "{e}");
}

#[test]
fn commentary_range_to_first_verse() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("t.commentaries.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE commentaries(book_number INT, chapter_number_from INT,
          verse_number_from INT, chapter_number_to INT, verse_number_to INT,
          marker TEXT, text TEXT);
         INSERT INTO commentaries VALUES(500,1,1,1,5,'','Комментарий к 1-5.');",
    )
    .unwrap();
    let books = mybible::parse_commentary_file(&dir.path().join("t.commentaries.SQLite3")).unwrap();
    assert_eq!(books.len(), 1);
    let ch = &books[0].chapters[0];
    let first = ch.blocks[0].spans.first().unwrap();
    assert!(matches!(first, Span::Verse(1)));
    assert!(books[0].verse_text(1, 1).unwrap().contains("Комментарий"));
}

#[test]
fn dictionary_to_entries() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("t.dictionary.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE dictionary(topic TEXT, definition TEXT);
         INSERT INTO dictionary VALUES('Аарон','<i>первосвященник</i>');",
    )
    .unwrap();
    let es = mybible::parse_dictionary_file(&dir.path().join("t.dictionary.SQLite3")).unwrap();
    assert_eq!(es.len(), 1);
    assert_eq!(es[0].headword, "Аарон");
    assert_eq!(es[0].text, "первосвященник");
}
