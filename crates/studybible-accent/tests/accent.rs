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

#[test]
fn empty_and_non_cyrillic() {
    let a = accentor();
    // Пустая строка, пробелы и текст без кириллицы — без изменений.
    assert_eq!(a.accent_text(""), "");
    assert_eq!(a.accent_text("   "), "   ");
    assert_eq!(a.accent_text("hello world"), "hello world");
    assert_eq!(a.accent_text("12345"), "12345");
    assert_eq!(a.accent_word("abc"), "abc");
    // Пунктуаторы без букв не «слово».
    assert_eq!(a.accent_text("--"), "--");
    assert_eq!(a.accent_text("…?!"), "…?!");
}

#[test]
fn monosyllables_get_no_accent() {
    let a = accentor();
    // Односложные слова речь произносит и так — ударение рубит фразу.
    let s = "и во над же Бог";
    assert_eq!(a.accent_text(s), s);
    assert_eq!(a.accent_text("В"), "В");
    // Безгласные и дефисы-одиночки — тоже.
    assert_eq!(a.accent_text("ь - -ъ"), "ь - -ъ");
}

#[test]
fn hyphenated_words() {
    let a = accentor();
    // Дефисное слово — одно слово, ударение одно.
    let out = a.accent_text("по-человечески");
    assert_eq!(out, "по-челове́чески");
    assert_eq!(out.matches('\u{0301}').count(), 1);
    // Ведущий/замыкающий дефис — не часть слова, сохраняется.
    let out = a.accent_text("-небо-");
    assert_eq!(out, "-не́бо-");
}

#[test]
fn all_caps_preserved() {
    let a = accentor();
    // Слово ЗАГЛАВНЫМИ не должно «опускаться» в Title Case
    // ни нейросетью, ни словарями (ё/лексикон).
    assert_eq!(a.accent_text("НАЧАЛЕ"), "НАЧА́ЛЕ");
    assert_eq!(a.accent_text("ЗЕМЛЮ"), "ЗЕ́МЛЮ");
    assert_eq!(a.accent_text("ЕЩЕ"), "ЕЩЁ");
}

#[test]
fn apostrophes_and_mixed_scripts() {
    let a = accentor();
    // Апострофы (') — граница слов, сохраняются.
    let out = a.accent_text("д’Артаньян");
    assert_eq!(out, "д’Артанья́н");
    // Гибрид кириллица+латиница: латинская часть не трогается,
    // кириллический кусок ударяется как отдельное слово.
    assert_eq!(a.accent_text("юниcode"), "ю́ниcode");
    // «текст» — слово без уверенного ответа модели: возвращается
    // как есть, латиница рядом не мешает.
    assert_eq!(a.accent_text("текст"), "текст");
    // Нейросеть не нашла ударения (оценка ниже порога) — слово
    // возвращается как есть, без паники.
    assert_eq!(a.accent_text("О'кей"), "О'кей");
}

#[test]
fn network_path_outside_lexicon() {
    let a = accentor();
    // Слова вне лексикона идут в нейросеть: ударение одно, на гласной.
    let out = a.accent_text("сверхъестественный");
    assert_eq!(out.matches('\u{0301}').count(), 1);
    assert!(out.contains("есте\u{0301}ственный"), "got {out}");
}

#[test]
fn overlong_word_untouched() {
    let a = accentor();
    // Слова длиннее max_length модели (40) не отправляются в инференс.
    let s = "оченьдлинноесловокотороенепомещаетсявсороксимволовмодели";
    assert!(s.chars().count() > 40);
    assert_eq!(a.accent_word(s), s);
}
