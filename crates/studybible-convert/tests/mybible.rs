//! Тесты конвертера MyBible: синтетические базы SQLite в temp-каталоге.

use rusqlite::Connection;
use studybible_convert::{mybible, usfm};
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

/// Счётчики по книгам: (стихи, strong-спаны, сноски).
fn counts(books: &[usfm::Book]) -> (usize, usize, usize) {
    let mut verses = 0;
    let mut strongs = 0;
    let mut notes = 0;
    for b in books {
        for ch in &b.chapters {
            for blk in &ch.blocks {
                for s in &blk.spans {
                    match s {
                        Span::Verse(_) => verses += 1,
                        Span::Note { .. } => notes += 1,
                        Span::Text { attrs, .. } if attrs.contains("strong=") => strongs += 1,
                        _ => {}
                    }
                }
            }
        }
    }
    (verses, strongs, notes)
}

/// strong_numbers_prefix из info переопределяет префикс по завету:
/// 'G' на ВЗ-книге → G, не H.
#[test]
fn strong_prefix_from_info() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("p.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE info(name TEXT, value TEXT);
         CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO info VALUES('strong_numbers_prefix','G');
         INSERT INTO verses VALUES(10,1,1,'слово<S>1254</S> текст');",
    )
    .unwrap();
    let books = mybible::parse_file(&dir.path().join("p.SQLite3")).unwrap();
    let spans: Vec<&Span> = books[0].chapters[0]
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .collect();
    assert!(
        spans.iter().any(|s| matches!(
            s,
            Span::Text { attrs, .. } if attrs.contains("G1254")
        )),
        "{spans:?}"
    );
    // Пустое значение — префикс по завету (ВЗ < 470 → H); покрыто
    // выше в bible_books_strong_notes_stories.
}

/// Несколько <S> в одном стихе → несколько спанов `w`; <f> и <n> —
/// обе сноски (kind 'f'), текст примечания сохраняется.
#[test]
fn multiple_strongs_and_both_note_kinds() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("m.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO verses VALUES(10,1,1,'А<S>1</S> Б<S>2</S> В<f>сноска</f> Г<n>примечание</n>');",
    )
    .unwrap();
    let books = mybible::parse_file(&dir.path().join("m.SQLite3")).unwrap();
    let spans: Vec<&Span> = books[0].chapters[0]
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .collect();
    let strongs: Vec<&Span> = spans
        .iter()
        .filter(|s| matches!(s, Span::Text { style, .. } if style == "w"))
        .copied()
        .collect();
    assert_eq!(strongs.len(), 2, "{spans:?}");
    let note_texts: Vec<&str> = spans
        .iter()
        .filter_map(|s| match s {
            Span::Note { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(note_texts.len(), 2, "{spans:?}");
    assert!(note_texts.iter().any(|t| t.contains("сноска")));
    assert!(note_texts.iter().any(|t| t.contains("примечание")));
}

/// stories с order_if_several > 1: заголовки склеиваются по порядку.
#[test]
fn stories_order_if_several() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("s.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         CREATE TABLE stories(book_number INT, chapter INT, verse INT,
                              order_if_several INT, title TEXT);
         INSERT INTO verses VALUES(10,1,1,'текст');
         INSERT INTO stories VALUES(10,1,1,2,'Второй'),(10,1,1,1,'Первый');",
    )
    .unwrap();
    let books = mybible::parse_file(&dir.path().join("s.SQLite3")).unwrap();
    let s1 = books[0].chapters[0]
        .blocks
        .iter()
        .find(|b| b.marker == "s1")
        .expect("блок s1");
    let title: String = s1
        .spans
        .iter()
        .filter_map(|s| match s {
            Span::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(title.trim(), "Первый Второй", "{title:?}");
}

/// Комментарий на диапазон, выходящий в соседнюю главу: запись
/// привязывается к стиху начала (chapter_number_to игнорируется).
#[test]
fn commentary_range_into_next_chapter() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("c.commentaries.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE commentaries(book_number INT, chapter_number_from INT,
          verse_number_from INT, chapter_number_to INT, verse_number_to INT,
          marker TEXT, text TEXT);
         INSERT INTO commentaries VALUES(10,1,31,2,3,'','На стыке глав.'),
                                       (10,1,1,1,1,'','К первому стиху.');",
    )
    .unwrap();
    let books = mybible::parse_commentary_file(&dir.path().join("c.commentaries.SQLite3")).unwrap();
    assert_eq!(books.len(), 1);
    let ch1 = &books[0].chapters[0];
    assert_eq!(ch1.number, 1);
    assert!(ch1.verse_text(1).unwrap().contains("К первому"));
    assert!(ch1.verse_text(31).unwrap().contains("стыке глав"));
    // В главу 2 запись не размножается.
    assert_eq!(books[0].chapters.len(), 1);
}

/// Неканонические номера книг MyBible → коды второго канона.
#[test]
fn noncanonical_book_numbers() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("n.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO verses VALUES(170,1,1,'Тов'),(280,1,1,'Сир'),(462,1,1,'1Мак'),
          (464,1,1,'2Мак'),(466,1,1,'3Мак'),(165,1,1,'2Езд'),(468,1,1,'3Езд'),
          (145,1,1,'Ман'),(315,1,1,'Посл'),(320,1,1,'Вар'),(270,1,1,'Прем'),
          (180,1,1,'Иудифь');",
    )
    .unwrap();
    let books = mybible::parse_file(&dir.path().join("n.SQLite3")).unwrap();
    let codes: Vec<&str> = books.iter().map(|b| b.code.as_str()).collect();
    assert_eq!(
        codes,
        [
            "MAN", "1ES", "TOB", "JDT", "WIS", "SIR", "LJE", "BAR", "1MA", "2MA", "3MA", "2ES"
        ]
    );
}

/// Пустой текст стиха — стих существует с пустым телом (маркер есть).
#[test]
fn empty_verse_text() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("e.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO verses VALUES(10,1,1,''),(10,1,2,'непустой');",
    )
    .unwrap();
    let books = mybible::parse_file(&dir.path().join("e.SQLite3")).unwrap();
    let ch = &books[0].chapters[0];
    assert_eq!(ch.verse_text(1).unwrap_or_default(), "");
    assert_eq!(ch.verse_text(2).unwrap(), "непустой");
}

/// Отсутствие таблицы stories — не ошибка (обязательной её нет).
#[test]
fn no_stories_table_ok() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("nost.SQLite3")).unwrap();
    conn.execute_batch(
        "CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO verses VALUES(10,1,1,'текст');",
    )
    .unwrap();
    let books = mybible::parse_file(&dir.path().join("nost.SQLite3")).unwrap();
    assert_eq!(books.len(), 1);
    assert!(books[0].chapters[0].blocks.iter().all(|b| b.marker != "s1"));
}

/// Повреждённый файл (не SQLite) — аккуратная ошибка, не паника.
/// (Имя файла в ошибку добавляет вызывающий — см. CLI-тесты.)
#[test]
fn corrupted_file_is_error() {
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("broken.SQLite3");
    std::fs::write(&f, "это вообще не база данных sqlite").unwrap();
    let e = mybible::parse_file(&f).unwrap_err();
    assert!(e.0.contains("MyBible"), "{e}");
}

/// Реальный RST+ (MyBible): 66 книг, ~31162 стиха, ~345k номеров
/// Стронга, сноски <f>. SKIPPED, если источника нет.
#[test]
fn rst_plus_real() {
    let dir = std::path::Path::new(r"D:\StudyBible-data\sources\mybible");
    let f = dir.join("RST+.SQLite3");
    if !f.exists() {
        eprintln!("SKIPPED: нет {f:?}");
        return;
    }
    let books = mybible::parse_file(&f).unwrap();
    assert_eq!(books.len(), 66);
    let (verses, strongs, notes) = counts(&books);
    eprintln!("RST+: {verses} стихов, {strongs} strong, {notes} сносок");
    assert_eq!(verses, 31162);
    assert!(strongs > 300_000, "strongs={strongs}");
    assert_eq!(notes, 108);

    // Соседний файл комментариев того же модуля.
    let c = dir.join("RST+.commentaries.SQLite3");
    if !c.exists() {
        eprintln!("SKIPPED: нет {c:?}");
        return;
    }
    let comm = mybible::parse_commentary_file(&c).unwrap();
    assert!(!comm.is_empty());
    assert!(
        comm.iter().any(|b| b.code.as_str() == "GEN"),
        "комментарии к Бытию"
    );
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
