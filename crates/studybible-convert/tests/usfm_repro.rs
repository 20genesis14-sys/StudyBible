//! Репро: `\f*текст` без пробела — звезда не должна входить в имя маркера,
//! иначе сноска не закрывается и проглатывает следующие стихи.
use studybible_convert::usfm;

#[test]
fn footnote_close_glued_to_text() {
    let src = "\\id JDG\n\\c 16\n\\p \\v 14 a14a,\\f + \\fr 16:14 \\ft note\\f*a14b.\n\\p \\v 15 a15.\n\\p \\v 16 a16. \\v 17 a17.\n\\p \\v 18 a18.\n\\p \\v 19 a19a,\\f + \\fr 16:19 \\ft n\\f* a19b. \\v 20 a20.\n";
    let b = usfm::parse(src).unwrap();
    for v in 14..=20 {
        assert!(
            b.verse_text(16, v).is_some(),
            "стих {} потерян",
            v
        );
    }
    let t14 = b.verse_text(16, 14).unwrap();
    assert!(t14.contains("a14b"), "хвост стиха 14: {t14}");
    assert!(!t14.contains("a19b"), "стих 14 проглотил 19: {t14}");
}
