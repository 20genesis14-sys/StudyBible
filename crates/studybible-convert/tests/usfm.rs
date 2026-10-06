//! Разбор USFM: краевые случаи и круговая запись.

use studybible_convert::usfm;
use studybible_core::text::{BlockKind, Span};

fn text(spans: &[Span]) -> String {
    spans
        .iter()
        .filter_map(|s| match s {
            Span::Text { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("")
}

#[test]
fn id_required() {
    assert!(usfm::parse("\\c 1\n\\v 1 Текст.").is_err());
    assert!(usfm::parse("").is_err());
    // Мусорная строка вместо \id.
    assert!(usfm::parse("\\id\n\\c 1\n\\v 1 Текст.").is_err());
}

#[test]
fn verse_before_chapter() {
    let e = usfm::parse("\\id GEN\n\\v 1 Текст.").unwrap_err();
    assert!(e.to_string().contains("стих"));
}

#[test]
fn bom_and_header() {
    let b = usfm::parse("\u{feff}\\id GEN\n\\h Бытие\n\\mt1 Бытие\n\\c 1\n\\v 1 Текст.").unwrap();
    assert_eq!(b.code.as_str(), "GEN");
    assert_eq!(b.header["h"], "Бытие");
    assert_eq!(b.header["mt1"], "Бытие");
}

#[test]
fn footnote_caller_and_trailing() {
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1 Начало\\f + \\fr 1:1 \\ft текст сноски\\f* конец.")
        .unwrap();
    let ch = b.chapter(1).unwrap();
    let note = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .find_map(|s| match s {
            Span::Note {
                kind, caller, text, ..
            } => Some((*kind, caller.clone(), text.clone())),
            _ => None,
        })
        .expect("сноска");
    assert_eq!(note.0, 'f');
    assert_eq!(note.1, "+");
    assert_eq!(note.2, "текст сноски"); // fr пропущен
    // Текст после \f* не теряется.
    assert_eq!(b.verse_text(1, 1).as_deref(), Some("Начало конец."));
}

#[test]
fn crossref_note() {
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1 Стих\\x - \\xo 1:1 \\xt Быт 2:2\\x*.").unwrap();
    let ch = b.chapter(1).unwrap();
    let note = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .find_map(|s| match s {
            Span::Note {
                kind: 'x', text, ..
            } => Some(text.clone()),
            _ => None,
        })
        .expect("перекрёстная ссылка");
    assert_eq!(note, "Быт 2:2");
}

#[test]
fn note_part_and_anchor() {
    // ADR 0016, п. 8: \fr «1:1a» → part="a", \fq → q-привязка.
    let b = usfm::parse(
        "\\id GEN\n\\c 1\n\\v 1 Начало\\f + \\fr 1:1a \\fq в начале \\ft сноска\\f* конец.",
    )
    .unwrap();
    let ch = b.chapter(1).unwrap();
    let note = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .find_map(|s| match s {
            Span::Note {
                kind: 'f',
                attrs,
                text,
                ..
            } => Some((attrs.clone(), text.clone())),
            _ => None,
        })
        .expect("сноска");
    assert_eq!(note.0, "part=\"a\" q=\"в начале\"");
    assert!(note.1.contains("в начале") && note.1.contains("сноска"));

    // Перекрёстная ссылка: \xo «2:3b» → part="b", \xq → q.
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1 Стих\\x - \\xo 2:3b \\xq слово \\xt Быт 2:3\\x*.")
        .unwrap();
    let attrs = b
        .chapter(1)
        .unwrap()
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .find_map(|s| match s {
            Span::Note {
                kind: 'x', attrs, ..
            } => Some(attrs.clone()),
            _ => None,
        })
        .expect("ссылка");
    assert_eq!(attrs, "part=\"b\" q=\"слово\"");

    // Без буквы части — attrs пуст.
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1 Т\\f + \\fr 1:1 \\ft с\\f*.").unwrap();
    let has = b
        .chapter(1)
        .unwrap()
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .any(|s| matches!(s, Span::Note { attrs, .. } if !attrs.is_empty()));
    assert!(!has);
}

#[test]
fn strongs_attrs() {
    let b = usfm::parse(
        "\\id GEN\n\\c 1\n\\v 1 \\w In|strong=\"H1234\" lemma=\"x\"\\w* \\w beginning|strong=\"H5678\"\\w*.",
    )
    .unwrap();
    let ch = b.chapter(1).unwrap();
    let attrs: Vec<&str> = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .filter_map(|s| match s {
            Span::Text { style, attrs, .. } if style == "w" => Some(attrs.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(attrs.len(), 2);
    assert!(attrs[0].contains("H1234"));
}

#[test]
fn nested_styles_innermost() {
    // Вложенный стиль: виден самый внутренний.
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1 \\add a \\it b\\it* c\\add* d.").unwrap();
    let ch = b.chapter(1).unwrap();
    let styles: Vec<&str> = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .filter_map(|s| match s {
            Span::Text { style, .. } if !style.is_empty() => Some(style.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(styles, ["add", "it", "add"]);
    assert_eq!(b.verse_text(1, 1).as_deref(), Some("a b c d."));
}

#[test]
fn verse_after_heading_own_block() {
    let b =
        usfm::parse("\\id GEN\n\\c 1\n\\p\n\\v 1 Первый.\n\\s1 Заголовок\n\\v 2 Второй.").unwrap();
    let ch = b.chapter(1).unwrap();
    // Заголовок — свой блок, стих 2 — отдельный.
    let head = ch
        .blocks
        .iter()
        .find(|b| b.kind() == BlockKind::Heading)
        .expect("заголовок");
    assert!(text(&head.spans).contains("Заголовок"));
    assert!(
        !head.spans.iter().any(|s| matches!(s, Span::Verse(_))),
        "стих не должен оказаться в блоке заголовка"
    );
    assert_eq!(b.verse_text(1, 2).as_deref(), Some("Второй."));
}

#[test]
fn combined_verse_first_number() {
    // \\v 1-2 — объединённый стих берёт первый номер (задокументированное упрощение).
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1-2 Совместный стих.").unwrap();
    assert_eq!(b.verse_text(1, 1).as_deref(), Some("Совместный стих."));
    assert_eq!(b.verse_text(1, 2), None);
}

#[test]
fn superscription_is_verse_zero() {
    let b = usfm::parse(
        "\\id PSA\n\\c 3\n\\d Псалом Давида.\n\\q1\n\\v 1 Господи! как умножились враги мои!",
    )
    .unwrap();
    let ch = b.chapter(3).unwrap();
    assert_eq!(ch.blocks[0].kind(), BlockKind::Superscription);
    let vs = ch.verse_texts();
    assert_eq!(vs[0], (0, "Псалом Давида.".into()));
    assert_eq!(vs[1].0, 1);
}

#[test]
fn unclosed_note_at_eof() {
    // Незакрытая сноска в конце файла — не падает.
    let b = usfm::parse("\\id GEN\n\\c 1\n\\v 1 Стих\\f + \\ft сноска без конца").unwrap();
    assert_eq!(b.verse_text(1, 1).as_deref(), Some("Стих"));
}

#[test]
fn poetry_and_blank_blocks() {
    let b = usfm::parse(
        "\\id PSA\n\\c 1\n\\q1\n\\v 1 Строка первая.\n\\q2\n\\v 2 Строка вторая.\n\\b\n\\p\n\\v 3 Абзац.",
    )
    .unwrap();
    let ch = b.chapter(1).unwrap();
    assert_eq!(ch.blocks[0].kind(), BlockKind::Poetry);
    assert_eq!(ch.blocks[1].kind(), BlockKind::Poetry);
    assert_eq!(ch.blocks[2].kind(), BlockKind::Blank);
    assert_eq!(ch.blocks[3].kind(), BlockKind::Paragraph);
}

#[test]
fn chapter_sizes() {
    let b = usfm::parse("\\id GEN\n\\c 2\n\\v 1 А.\n\\v 2 Б.\n\\c 1\n\\v 1 В.").unwrap();
    assert_eq!(b.chapter_sizes(), vec![1, 2]); // отсортировано по номеру главы
    assert_eq!(b.chapter(2).unwrap().number, 2);
}

#[test]
fn roundtrip_usfm() {
    let src = "\\id GEN\n\\h Бытие\n\\mt1 Бытие\n\
\\c 1\n\\p\n\\v 1 В начале сотворил Бог небо и землю.\n\
\\v 2 \\add Приблизительно\\add* \\w слово|strong=\"H1\"\\w* текст.\\f + \\ft Сноска.\\f*\n\
\\s1 Заголовок\n\\v 3 Третий.";
    let a = usfm::parse(src).unwrap();
    let b = usfm::parse(&a.to_usfm()).unwrap();
    assert_eq!(a.chapters, b.chapters, "круговая запись сохраняет поток");
}

#[test]
fn char_style_continuation_plus() {
    // \+ft — продолжение маркера в сноске; \+add — вложенный стиль.
    let b =
        usfm::parse("\\id GEN\n\\c 1\n\\v 1 Слово\\f + \\ft часть \\+ft продолжение\\f* после.")
            .unwrap();
    assert_eq!(b.verse_text(1, 1).as_deref(), Some("Слово после."));
}
