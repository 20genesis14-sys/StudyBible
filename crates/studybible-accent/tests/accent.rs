//! Тесты акцентора на реальной модели RUAccent — она же ассет
//! приложения `assets/voice/ru/` (fs и gzip только в тестах).

use std::io::Read;
use std::path::PathBuf;
use std::sync::OnceLock;

use studybible_accent::Accentor;

fn assets() -> PathBuf {
    // tests/ → crates/studybible-accent → корень → assets приложения.
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../apps/studybible-flutter/assets/voice/ru")
}

fn read_gz(name: &str) -> String {
    let f = std::fs::File::open(assets().join(name)).unwrap();
    let mut s = String::new();
    flate2::read::GzDecoder::new(f)
        .read_to_string(&mut s)
        .unwrap();
    s
}

fn accentor() -> &'static Accentor {
    static A: OnceLock<Accentor> = OnceLock::new();
    A.get_or_init(|| {
        let dir = assets();
        let model = std::fs::read(dir.join("accent.onnx")).unwrap();
        let vocab = std::fs::read_to_string(dir.join("vocab.txt")).unwrap();
        let yo = read_gz("yo_words.tsv.gz");
        let lexicon = read_gz("lexicon.tsv.gz");
        Accentor::new(&model, &vocab, Some(&yo), Some(&lexicon)).unwrap()
    })
}

#[test]
fn known_words() {
    let a = accentor();
    assert_eq!(a.accent_word("сотворил"), "сотвори́л");
    assert_eq!(a.accent_word("небо"), "не́бо");
}

#[test]
fn lexicon_beats_network() {
    let a = accentor();
    // Лексикон (словарь RUAccent по словоформам модулей) бьёт
    // нейросеть: та на «землю» ошибается («землю́»).
    assert_eq!(a.accent_text("землю"), "зе́млю");
    assert_eq!(a.accent_text("было"), "бы́ло");
    // «один» — омограф, в лексикон не вошёл: идёт в нейросеть
    // (её вывод здесь просто фиксируем, а не канонизируем).
    assert!(!a.accent_text("один").is_empty());
    // «замок» — омограф: нейросеть выбрала «замо́к».
    assert_eq!(a.accent_text("замок"), "замо́к");
}

#[test]
fn single_stress_per_word() {
    let a = accentor();
    // Ни одно слово не получает двух ударений (раньше «хорош»
    // выходил «хо́ро́ш»).
    let text = "В начале сотворил Бог небо и землю. Земля же была безвидна и пуста, и тьма над бездною, и Дух Божий носился над водою. И сказал Бог: да будет свет. И стал свет. И увидел Бог свет, что он хорош, и отделил Бог свет от тьмы. И назвал Бог свет днем, а тьму ночью. И был вечер, и было утро: день один.";
    let out = a.accent_text(text);
    for w in out.split(|c: char| !(c.is_alphabetic() || c == '-' || c == '\u{0301}')) {
        assert!(
            w.matches('\u{0301}').count() <= 1,
            "два ударения в слове {w:?}"
        );
        // Односложные слова ударений не получают.
        let vowels = w
            .chars()
            .filter(|c| "аеёиоуыэюяАЕЁИОУЫЭЮЯ".contains(*c))
            .count();
        if vowels <= 1 {
            assert!(!w.contains('\u{0301}'), "односложное с ударением: {w:?}");
        }
    }
}

#[test]
fn text_keeps_structure() {
    let a = accentor();
    let out = a.accent_text("В начале сотворил Бог небо и землю.");
    // Односложные без ударения в лексиконе («В», «и») и
    // пунктуация не тронуты.
    assert!(out.starts_with('В'));
    assert!(out.contains("Бог")); // односложное — без ударения
    assert!(out.contains(" и "));
    assert!(out.ends_with('.'));
    assert!(out.contains("сотвори́л"));
    assert!(out.contains("не́бо"));
    assert!(out.contains("зе́млю"));
    // Ни одного «+» — ударение только через U+0301.
    assert!(!out.contains('+'));
}

#[test]
fn case_preserved() {
    let a = accentor();
    let out = a.accent_text("Начале");
    assert!(out.starts_with("Нача́ле"), "got {out}");
    // Заглавная буква переносится и для лексикона/ё.
    assert_eq!(a.accent_text("Землю"), "Зе́млю");
}

#[test]
fn already_accented_untouched() {
    let a = accentor();
    let s = "за́мок и замо́к";
    assert_eq!(a.accent_text(s), s);
}

#[test]
fn yo_dictionary() {
    let a = accentor();
    // «еще» есть в словаре yo_words → «ещё», без нейросети.
    assert_eq!(a.accent_text("еще"), "ещё");
    assert_eq!(a.accent_text("Еще"), "Ещё");
    // Слово с «ё» нейросеть не трогает.
    assert_eq!(a.accent_text("ещё"), "ещё");
}

#[test]
fn hyphens_and_punctuation() {
    let a = accentor();
    // Дефис внутри слова и прочая пунктуация сохраняются.
    let out = a.accent_text("по-русски, северо-запад;");
    assert!(out.ends_with(";") && out.contains(','));
    assert_eq!(out.matches('-').count(), 2);
}
