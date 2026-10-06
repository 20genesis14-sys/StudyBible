//! Разбор OSIS: минимальные документы, краевые случаи и круговая запись.

use studybible_convert::{osis, usfm};
use studybible_core::text::{BlockKind, Chapter, Span};

fn notes(spans: &[Span]) -> Vec<(char, String, String)> {
    spans
        .iter()
        .filter_map(|s| match s {
            Span::Note {
                kind, caller, text, ..
            } => Some((*kind, caller.clone(), text.clone())),
            _ => None,
        })
        .collect()
}

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

/// Поток главы для сравнения: хвостовые пробелы промежутков не значимы
/// (разметка исходника их даёт или не даёт), пустые текстовые — пропускаются.
fn canon(ch: &Chapter) -> Vec<(String, Vec<String>)> {
    ch.blocks
        .iter()
        .map(|b| {
            let spans = b
                .spans
                .iter()
                .filter_map(|s| match s {
                    Span::Verse(n) => Some(format!("v{n}")),
                    Span::Text { text, style, attrs } => {
                        let t = text.trim_end();
                        (!t.is_empty()).then(|| format!("t:{style}|{attrs}|{t}"))
                    }
                    Span::Note {
                        kind, caller, text, ..
                    } => Some(format!("n:{kind}:{caller}:{text}")),
                })
                .collect();
            (b.marker.clone(), spans)
        })
        .collect()
}

/// Минимальный модуль: вехи стихов и глав, абзац, сноска, перекрёстная ссылка.
const GEN: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<osis xmlns="http://www.bibletechnologies.net/2003/OSIS/namespace">
<osisText osisIDWork="Gen" osisRefWork="Bible" xml:lang="ru">
<header><work osisWork="Gen"><title>Ген</title></work></header>
<div type="book" osisID="Gen">
<title type="main">Бытие</title>
<chapter osisID="Gen.1" sID="Gen.1"/>
<div type="section"><title>Сотворение мира</title>
<p><verse osisID="Gen.1.1" sID="Gen.1.1"/>В начале сотворил Бог небо и землю.<verse eID="Gen.1.1"/>
<verse osisID="Gen.1.2" sID="Gen.1.2"/>Земля же была<note type="x-footnote" n="+">Сноска о земле.</note> безвидна и пуста.<verse eID="Gen.1.2"/></p>
<p><verse osisID="Gen.1.3" sID="Gen.1.3"/>И сказал Бог: да будет свет.<note type="crossReference" n="-"><reference osisRef="Gen.1.1">Быт 1:1</reference></note><verse eID="Gen.1.3"/></p>
</div>
<chapter eID="Gen.1"/>
</div>
</osisText></osis>"#;

#[test]
fn basic_milestones() {
    let books = osis::parse(GEN).unwrap();
    assert_eq!(books.len(), 1);
    let b = &books[0];
    assert_eq!(b.code.as_str(), "GEN");
    assert_eq!(b.header["mt1"], "Бытие");
    assert_eq!(
        b.verse_text(1, 1).as_deref(),
        Some("В начале сотворил Бог небо и землю.")
    );
    assert_eq!(
        b.verse_text(1, 2).as_deref(),
        Some("Земля же была безвидна и пуста.")
    );
}

#[test]
fn heading_own_block() {
    let b = &osis::parse(GEN).unwrap()[0];
    let ch = b.chapter(1).unwrap();
    let head = ch
        .blocks
        .iter()
        .find(|b| b.kind() == BlockKind::Heading)
        .expect("заголовок");
    assert_eq!(head.marker, "s1");
    assert!(text(&head.spans).contains("Сотворение мира"));
    assert!(
        !head.spans.iter().any(|s| matches!(s, Span::Verse(_))),
        "стих не должен оказаться в блоке заголовка"
    );
}

#[test]
fn footnote_and_crossref() {
    let b = &osis::parse(GEN).unwrap()[0];
    let ch = b.chapter(1).unwrap();
    let all: Vec<_> = ch.blocks.iter().flat_map(|b| notes(&b.spans)).collect();
    assert!(
        all.iter()
            .any(|(k, c, t)| *k == 'f' && c == "+" && t == "Сноска о земле.")
    );
    assert!(
        all.iter().any(|(k, _, t)| *k == 'x' && t == "Быт 1:1"),
        "текст <reference> внутри ссылки сохраняется"
    );
}

#[test]
fn note_catchword_anchor() {
    // ADR 0016, п. 8: <catchWord> → attrs q="…", в текст не идёт.
    let src = r#"<osis><osisText><div type="book" osisID="Gen"><title>Бытие</title>
<chapter osisID="Gen.1"><p><verse osisID="Gen.1.1" sID="Gen.1.1"/>В начале<note n="a">сноска <catchWord>В начале</catchWord> конец.</note><verse eID="Gen.1.1"/></p></chapter>
</div></osisText></osis>"#;
    let b = &osis::parse(src).unwrap()[0];
    let ch = b.chapter(1).unwrap();
    let (attrs, text) = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .find_map(|s| match s {
            Span::Note { attrs, text, .. } => Some((attrs.clone(), text.clone())),
            _ => None,
        })
        .expect("сноска");
    assert_eq!(attrs, "q=\"В начале\"");
    // Текст <catchWord> в сноску не попадает — он ушёл в привязку.
    assert_eq!(text, "сноска конец.");
}

#[test]
fn container_form() {
    // Обёртки <verse>…</verse> вместо вех sID/eID и <chapter> с закрывающим тегом.
    let src = r#"<osis><osisText><div type="book" osisID="Exod"><title>Исход</title>
<chapter osisID="Exod.1"><p><verse osisID="Exod.1.1">Имена сынов.</verse><verse osisID="Exod.1.2">Рувим, Симеон.</verse></p></chapter>
</div></osisText></osis>"#;
    let b = &osis::parse(src).unwrap()[0];
    assert_eq!(b.code.as_str(), "EXO");
    assert_eq!(b.verse_text(1, 1).as_deref(), Some("Имена сынов."));
    assert_eq!(b.verse_text(1, 2).as_deref(), Some("Рувим, Симеон."));
    // Заголовок без type — первый заголовок книги → mt1.
    assert_eq!(b.header["mt1"], "Исход");
}

#[test]
fn styles_added_wj_nd_w() {
    let src = r#"<osis><osisText><div type="book" osisID="Matt"><title>Матфей</title>
<chapter osisID="Matt.1"><p><verse osisID="Matt.1.1" sID="Matt.1.1"/><transChange type="added">было</transChange> сказано
<q who="Jesus" marker="">слово</q> и <divineName>Господь</divineName>
<w lemma="strong:H7225">начало</w>.</p></chapter></div></osisText></osis>"#;
    let b = &osis::parse(src).unwrap()[0];
    let ch = b.chapter(1).unwrap();
    let styles: Vec<(&str, &str)> = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .filter_map(|s| match s {
            Span::Text { text, style, .. } if !style.is_empty() => {
                Some((style.as_str(), text.as_str()))
            }
            _ => None,
        })
        .collect();
    assert_eq!(
        styles,
        [
            ("add", "было"),
            ("wj", "слово"),
            ("nd", "Господь "), // пробел от перевода строки перед <w>
            ("w", "начало")
        ]
    );
    let attrs: Vec<&str> = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .filter_map(|s| match s {
            Span::Text { style, attrs, .. } if style == "w" => Some(attrs.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(attrs, ["strong=\"H7225\""]);
    assert_eq!(
        b.verse_text(1, 1).as_deref(),
        Some("было сказано слово и Господь начало.")
    );
}

#[test]
fn poetry_lines() {
    let src = r#"<osis><osisText><div type="book" osisID="Ps"><title>Псалмы</title>
<chapter osisID="Ps.1"><lg><l level="1"><verse osisID="Ps.1.1" sID="Ps.1.1"/>Первая строка.</l>
<l level="2"><verse osisID="Ps.1.2" sID="Ps.1.2"/>Вторая строка.</l></lg></chapter>
</div></osisText></osis>"#;
    let b = &osis::parse(src).unwrap()[0];
    let ch = b.chapter(1).unwrap();
    assert_eq!(ch.blocks[0].kind(), BlockKind::Poetry);
    assert_eq!(ch.blocks[0].marker, "q1");
    assert_eq!(ch.blocks[1].marker, "q2");
    assert_eq!(b.verse_text(1, 2).as_deref(), Some("Вторая строка."));
}

#[test]
fn superscription_psalm() {
    let src = r#"<osis><osisText><div type="book" osisID="Ps">
<chapter osisID="Ps.3"><title type="psalm" canonical="true">Псалом Давида.</title>
<l><verse osisID="Ps.3.1" sID="Ps.3.1"/>Господи! как умножились враги мои!</l></chapter>
</div></osisText></osis>"#;
    let b = &osis::parse(src).unwrap()[0];
    let ch = b.chapter(3).unwrap();
    assert_eq!(ch.blocks[0].kind(), BlockKind::Superscription);
    let vs = ch.verse_texts();
    assert_eq!(vs[0], (0, "Псалом Давида.".into()));
}

#[test]
fn verse_between_blocks_continues() {
    // Стих между абзацами (веха вне <p>) — отдельный блок-продолжение.
    let src = r#"<osis><osisText><div type="book" osisID="Gen">
<chapter osisID="Gen.1"><p><verse osisID="Gen.1.1" sID="Gen.1.1"/>Раз.</p>
<verse osisID="Gen.1.2" sID="Gen.1.2"/>Два.<p>Три — тот же стих?</p></chapter>
</div></osisText></osis>"#;
    let b = &osis::parse(src).unwrap()[0];
    let ch = b.chapter(1).unwrap();
    assert_eq!(
        b.verse_text(1, 2).as_deref(),
        Some("Два. Три — тот же стих?")
    );
    // Стих 2 начался в блоке-продолжении без маркера.
    assert!(
        ch.blocks
            .iter()
            .any(|b| b.marker.is_empty() && b.spans.iter().any(|s| matches!(s, Span::Verse(2))))
    );
}

#[test]
fn several_books_one_file() {
    let src = r#"<osis><osisText><div type="book" osisID="Gen"><title>Бытие</title>
<chapter osisID="Gen.1"><p><verse osisID="Gen.1.1" sID="Gen.1.1"/>Раз.</p></chapter></div>
<div type="book" osisID="Exod"><title>Исход</title>
<chapter osisID="Exod.1"><p><verse osisID="Exod.1.1" sID="Exod.1.1"/>Два.</p></chapter></div>
</osisText></osis>"#;
    let books = osis::parse(src).unwrap();
    assert_eq!(books.len(), 2);
    assert_eq!(books[0].code.as_str(), "GEN");
    assert_eq!(books[1].code.as_str(), "EXO");
}

#[test]
fn unknown_book_and_no_book() {
    assert!(
        osis::parse("<osis><osisText><div type=\"book\" osisID=\"Nosuch\"/></osisText></osis>")
            .is_err()
    );
    assert!(osis::parse("<osis><osisText/></osis>").is_err());
    assert!(osis::parse("").is_err());
    assert!(osis::parse("<osis><osisText><div type=\"book\">").is_err());
}

/// Равнозначные USFM- и OSIS-источники дают одинаковый поток чтения.
#[test]
fn same_stream_as_usfm() {
    let usfm_src = "\\id GEN\n\\h Бытие\n\\c 1\n\\s1 Сотворение мира\n\\p\n\\v 1 В начале сотворил Бог небо и землю.\n\
\\v 2 Земля же была\\f + \\ft Сноска о земле.\\f* безвидна и пуста.\n\\p\n\\v 3 И сказал Бог: да будет свет.\\x - \\xo 1:1 \\xt Быт 1:1\\x*";
    let u = usfm::parse(usfm_src).unwrap();
    let o = &osis::parse(GEN).unwrap()[0];
    assert_eq!(
        u.chapters.iter().map(canon).collect::<Vec<_>>(),
        o.chapters.iter().map(canon).collect::<Vec<_>>(),
        "потоки USFM и OSIS совпадают"
    );
}

#[test]
fn roundtrip_osis() {
    let a = osis::parse(GEN).unwrap().remove(0);
    let b = osis::parse(&a.to_osis()).unwrap().remove(0);
    assert_eq!(a.code, b.code);
    assert_eq!(a.header, b.header);
    assert_eq!(
        a.chapters.iter().map(canon).collect::<Vec<_>>(),
        b.chapters.iter().map(canon).collect::<Vec<_>>(),
        "круговая запись сохраняет поток"
    );
}

#[test]
fn roundtrip_styles_and_attrs() {
    let src = r#"<osis><osisText><div type="book" osisID="Matt"><title type="main">Матфей</title>
<chapter osisID="Matt.1"><title type="psalm">Надпись.</title>
<lg><l level="2"><verse osisID="Matt.1.1" sID="Matt.1.1"/><transChange type="added">а</transChange>
<q who="Jesus" marker="">б</q> <divineName>в</divineName> <w lemma="strong:H1">г</w>.</l></lg></chapter>
</div></osisText></osis>"#;
    let a = osis::parse(src).unwrap().remove(0);
    let b = osis::parse(&a.to_osis()).unwrap().remove(0);
    assert_eq!(
        a.chapters.iter().map(canon).collect::<Vec<_>>(),
        b.chapters.iter().map(canon).collect::<Vec<_>>()
    );
}
