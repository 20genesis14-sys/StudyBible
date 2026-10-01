//! Подготовка текста: нормализация для поиска, чистый текст стихов, озвучиваемый текст.

use studybible_core::normalize::for_search;
use studybible_core::speech::speakable;
use studybible_core::text::{Block, BlockKind, Chapter, Span, collapse_spaces};

fn text_span(t: &str) -> Span {
    Span::Text {
        text: t.into(),
        style: String::new(),
        attrs: String::new(),
    }
}

fn para(spans: Vec<Span>) -> Block {
    Block {
        marker: "p".into(),
        spans,
    }
}

#[test]
fn normalize_search() {
    // Регистр и ё.
    assert_eq!(for_search("ИЕГОВА"), "иегова");
    assert_eq!(for_search("Ёлка ЁЛКА"), "елка елка");
    // Дореформенные буквы.
    assert_eq!(
        for_search("вѣчный ісповѣдую ѳеодосіи"),
        "вечный исповедую феодосии"
    );
    // Ударения и диакритика снимаются (NFD + снятие Mn).
    assert_eq!(for_search("миро\u{0301}"), "миро");
    assert_eq!(for_search("élève"), "eleve");
    // Мягкий перенос исчезает.
    assert_eq!(for_search("сло\u{ad}во"), "слово");
    // Еврейские огласовки/теамим снимаются.
    assert_eq!(for_search("בְּרֵאשִׁ֖ית"), "בראשית");
    // Греческая диакритика снимается.
    assert_eq!(for_search("λόγος"), "λογος"); // конечная ς → σ по Unicode-нижнему регистру
    // Русский текст не меняется по слогу.
    assert_eq!(for_search("В начале"), "в начале");
    // «й» не сливается с «и» (NFD разлагает её в «и»+бреве — сохраняем).
    assert_eq!(for_search("мой мои"), "мой мои");
}

#[test]
fn collapse_spaces_edges() {
    assert_eq!(collapse_spaces("  а   б  "), "а б");
    assert_eq!(collapse_spaces("текст , тест ."), "текст, тест.");
    assert_eq!(collapse_spaces("сказал : да"), "сказал: да");
    assert_eq!(collapse_spaces(""), "");
    assert_eq!(collapse_spaces("( Иегова )"), "( Иегова)"); // открывающая скобка — слово
    assert_eq!(collapse_spaces("да ! нет ?"), "да! нет?");
    assert_eq!(collapse_spaces("а\n\tб"), "а б");
}

#[test]
fn verse_texts_excludes_non_verse_content() {
    let ch = Chapter {
        number: 3,
        blocks: vec![
            Block {
                marker: "d".into(),
                spans: vec![text_span("Псалом Давида")],
            },
            Block {
                marker: "s1".into(),
                spans: vec![text_span("Заголовок раздела")],
            },
            para(vec![
                Span::Verse(1),
                text_span("Первый стих"),
                Span::Note {
                    kind: 'f',
                    caller: "+".into(),
                    text: "сноска".into(),
                },
                text_span(", продолжение"),
                Span::Verse(2),
                text_span("Второй стих"),
            ]),
        ],
    };
    let vs = ch.verse_texts();
    assert_eq!(vs.len(), 3); // 0 — надписание, 1, 2
    assert_eq!(vs[0], (0, "Псалом Давида".into()));
    assert_eq!(vs[1], (1, "Первый стих, продолжение".into()));
    assert_eq!(vs[2], (2, "Второй стих".into()));
}

#[test]
fn verse_texts_across_blocks() {
    // Стих продолжается за разрывом абзаца (без нового \v).
    let ch = Chapter {
        number: 1,
        blocks: vec![
            para(vec![Span::Verse(1), text_span("Начало")]),
            para(vec![text_span(" продолжение того же стиха")]),
        ],
    };
    let vs = ch.verse_texts();
    assert_eq!(vs, vec![(1, "Начало продолжение того же стиха".into())]);
}

#[test]
fn verse_texts_drops_text_before_first_verse() {
    // Текст до \v 1 (вводный абзац) не принадлежит ни одному стиху.
    let ch = Chapter {
        number: 1,
        blocks: vec![
            para(vec![text_span("Вводный текст без стиха")]),
            para(vec![Span::Verse(1), text_span("Стих один")]),
        ],
    };
    let vs = ch.verse_texts();
    assert_eq!(vs, vec![(1, "Стих один".into())]);
}

#[test]
fn verse_texts_empty_chapter() {
    let ch = Chapter::default();
    assert!(ch.verse_texts().is_empty());
    assert_eq!(ch.last_verse(), 0);
    assert_eq!(ch.verse_text(1), None);
}

#[test]
fn superscription_only_when_first() {
    // \d после стиха — текст попадает в текущий стих (стих 0 только в начале).
    let ch = Chapter {
        number: 1,
        blocks: vec![
            para(vec![Span::Verse(1), text_span("Первый")]),
            Block {
                marker: "d".into(),
                spans: vec![text_span("подпись")],
            },
        ],
    };
    let vs = ch.verse_texts();
    assert_eq!(vs, vec![(1, "Первый подпись".into())]);
}

#[test]
fn block_kind_classification() {
    let kind = |m: &str| {
        Block {
            marker: m.into(),
            spans: vec![],
        }
        .kind()
    };
    assert_eq!(kind("s1"), BlockKind::Heading);
    assert_eq!(kind("mt2"), BlockKind::Heading);
    assert_eq!(kind("r"), BlockKind::Heading);
    assert_eq!(kind("d"), BlockKind::Superscription);
    assert_eq!(kind("b"), BlockKind::Blank);
    assert_eq!(kind("q2"), BlockKind::Poetry);
    assert_eq!(kind("qm1"), BlockKind::Poetry);
    assert_eq!(kind("p"), BlockKind::Paragraph);
    assert_eq!(kind("li3"), BlockKind::Paragraph);
    assert_eq!(kind(""), BlockKind::Paragraph);
}

#[test]
fn speakable_ranges_and_superscription() {
    let ch = Chapter {
        number: 3,
        blocks: vec![
            Block {
                marker: "d".into(),
                spans: vec![text_span("Псалом Давида.")],
            },
            para(vec![
                Span::Verse(1),
                text_span("Стих первый."),
                Span::Verse(2),
                text_span("Стих второй."),
                Span::Verse(3),
                text_span("Стих третий."),
            ]),
        ],
    };
    // Вся глава: надписание входит.
    assert_eq!(
        speakable(&ch, 0, u16::MAX),
        "Псалом Давида. Стих первый. Стих второй. Стих третий."
    );
    // Диапазон без надписания.
    assert_eq!(speakable(&ch, 2, 3), "Стих второй. Стих третий.");
    // Один стих.
    assert_eq!(speakable(&ch, 3, 3), "Стих третий.");
    // Пустой диапазон.
    assert_eq!(speakable(&ch, 5, 9), "");
}
