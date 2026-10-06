//! Конвертер TSV → поток чтения (ADR 0016): простой вход авторов.

use studybible_convert::tsv;
use studybible_core::BookCode;
use studybible_core::text::Span;

const TSV: &str = "# подстрочник Быт 1\n\
GEN 1:1\tבְּרֵאשִׁית\tв-начале\tbereshit\tH7225\t\n\
GEN 1:1\tבָּרָא\tсотворил\tbara\tH1254\tqal\n\
GEN 1:1\tאֱלֹהִים\tБог\telohim\tH430\t\n\
GEN 1:2\tהָאָרֶץ\tземлю\t\n\
# комментарий пропускается\n\
EXO 1:1\tוְאֵלֶּה\tи-вот\t\n";

#[test]
fn tsv_parses_books_in_order() {
    let books = tsv::parse(TSV).unwrap();
    assert_eq!(books.len(), 2);
    assert_eq!(books[0].code, BookCode::new("GEN").unwrap());
    assert_eq!(books[1].code, BookCode::new("EXO").unwrap());
    let ch = &books[0].chapters[0];
    assert_eq!(ch.number, 1);
    // Стих 1: маркер + три пары; стих 2: маркер + одна пара.
    let b0 = &ch.blocks[0];
    assert!(matches!(b0.spans[0], Span::Verse(1)));
    let w: Vec<_> = b0
        .spans
        .iter()
        .filter(|s| matches!(s, Span::Text { style, .. } if style == "w"))
        .collect();
    assert_eq!(w.len(), 3);
    if let Span::Text { text, attrs, .. } = w[0] {
        assert_eq!(text.trim(), "в-начале");
        assert!(attrs.contains("gr=\"בְּרֵאשִׁית\""));
        assert!(attrs.contains("lemma=\"bereshit\""));
        assert!(attrs.contains("strong=\"H7225\""));
        assert!(!attrs.contains("morph="));
    } else {
        panic!("не текстовый спан");
    }
    if let Span::Text { attrs, .. } = w[1] {
        assert!(attrs.contains("morph=\"qal\""));
    }
}

#[test]
fn tsv_rejects_bad_lines() {
    assert!(tsv::parse("").is_err());
    assert!(tsv::parse("GEN 1:1\ttолько два").is_err());
    assert!(tsv::parse("gen 1:1\ta\tb").is_err()); // код — только верхний регистр
    assert!(tsv::parse("GE 1:1\ta\tb").is_err());
    assert!(tsv::parse("GEN x:1\ta\tb").is_err());
}

#[test]
fn tsv_verse_segment_letters_ignored() {
    // «GEN 1:1a» — часть стиха отбрасывается до номера.
    let books = tsv::parse("GEN 1:1a\tבְּרֵאשִׁית\tв-начале\n").unwrap();
    let ch = &books[0].chapters[0];
    assert!(matches!(ch.blocks[0].spans[0], Span::Verse(1)));
}
