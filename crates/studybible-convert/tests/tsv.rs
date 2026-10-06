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
fn tsv_variants_group_readings() {
    let src = "GEN 1:1\t0-1\tв-начале\t1\tMT SP\n\
               GEN 1:1\t0-1\tв-началах\t0\tLXX\n\
               GEN 1:5\t2\tдругое\t0\t\n";
    let vs = tsv::parse_variants(src).unwrap();
    assert_eq!(vs.len(), 2);
    assert_eq!(vs[0].readings.len(), 2);
    assert!(vs[0].readings[0].is_base);
    assert_eq!(vs[0].readings[0].witnesses, ["MT", "SP"]);
    assert_eq!(vs[1].readings.len(), 1);
    assert_eq!(vs[1].token_from, 2);
    assert_eq!(vs[1].token_to, 2); // одиночный токен без «-»
}

#[test]
fn tsv_verse_segment_letters_ignored() {
    // «GEN 1:1a» — часть стиха отбрасывается до номера.
    let books = tsv::parse("GEN 1:1a\tבְּרֵאשִׁית\tв-начале\n").unwrap();
    let ch = &books[0].chapters[0];
    assert!(matches!(ch.blocks[0].spans[0], Span::Verse(1)));
}

// --- словарь (format=entries) ---

#[test]
fn tsv_entries_parse() {
    let src = "# словарь\n\
               Авраам\tОтец множества.\tавраам\n\
               Агарь\tСлужанка Сары.\n\
               \n\
               Ваал\tХанаанское божество.\n";
    let es = tsv::parse_entries(src).unwrap();
    assert_eq!(es.len(), 3);
    assert_eq!(es[0].headword, "Авраам");
    assert_eq!(es[0].text, "Отец множества.");
    assert_eq!(es[0].norm, "авраам");
    // norm можно не давать — выведется из заголовка при записи.
    assert_eq!(es[1].norm, "");
}

#[test]
fn tsv_entries_reject_bad() {
    assert!(tsv::parse_entries("").is_err());
    assert!(tsv::parse_entries("# только комментарии\n").is_err());
    assert!(tsv::parse_entries("одно поле без таба\n").is_err());
    assert!(tsv::parse_entries("\tтекст без заголовка\n").is_err());
}

// --- метки времени (ключ marks в modules.json) ---

#[test]
fn tsv_marks_parse() {
    let src = "# аудио-метки Быт 1\n\
               GEN 1:1\t0\t1200\tВ\n\
               GEN 1:1\t1200\t800\tначале\n\
               GEN 1:1\t2000\t\tсотворил\n\
               GEN 1:2\t5400\n";
    let ms = tsv::parse_marks(src).unwrap();
    assert_eq!(ms.len(), 4);
    assert_eq!(
        (ms[0].seq, ms[0].offset_ms, ms[0].dur_ms),
        (0, 0, Some(1200))
    );
    assert_eq!(ms[1].seq, 1);
    // Пустая длительность — «до следующей метки».
    assert_eq!(ms[2].dur_ms, None);
    assert_eq!(ms[2].text, "сотворил");
    // Стих 2 — свой счётчик seq.
    assert_eq!(ms[3].verse, 2);
    assert_eq!(ms[3].seq, 0);
    assert_eq!(ms[3].text, "");
}

#[test]
fn tsv_marks_reject_bad() {
    assert!(tsv::parse_marks("GEN 1:1\n").is_err());
    assert!(tsv::parse_marks("GEN 1:1\tне-число\n").is_err());
    assert!(tsv::parse_marks("GEN 1:1\t10\tне-число\n").is_err());
    assert!(tsv::parse_marks("плохая ссылка\t10\n").is_err());
}
