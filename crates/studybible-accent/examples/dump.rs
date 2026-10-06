use std::io::Read;
use std::path::PathBuf;

use studybible_accent::Accentor;

fn gz(dir: &std::path::Path, name: &str) -> String {
    let mut s = String::new();
    flate2::read::GzDecoder::new(std::fs::File::open(dir.join(name)).unwrap())
        .read_to_string(&mut s)
        .unwrap();
    s
}

fn main() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../apps/studybible-flutter/assets/voice/ru");
    let model = std::fs::read(dir.join("accent.onnx")).unwrap();
    let vocab = std::fs::read_to_string(dir.join("vocab.txt")).unwrap();
    let yo = gz(&dir, "yo_words.tsv.gz");
    let lexicon = gz(&dir, "lexicon.tsv.gz");
    let a = Accentor::new(&model, &vocab, Some(&yo), Some(&lexicon)).unwrap();
    for w in [
        "замок",
        "сотворил",
        "землю",
        "было",
        "один",
        "пуста",
        "бездною",
        "хорош",
        "Вифлеем",
        "Иерусалим",
        "Авраам",
        "воскресение",
        "благословил",
        "пророчество",
        "еще",
        "ее",
    ] {
        println!("{w} -> {}", a.accent_text(w));
    }
    let text = "В начале сотворил Бог небо и землю. Земля же была безвидна и пуста, и тьма над бездною, и Дух Божий носился над водою. И сказал Бог: да будет свет. И стал свет. И увидел Бог свет, что он хорош, и отделил Бог свет от тьмы. И назвал Бог свет днем, а тьму ночью. И был вечер, и было утро: день один.";
    println!("{}", a.accent_text(text));
    let nt = "В начале было Слово, и Слово было у Бога, и Слово было Бог. Оно было в начале у Бога. Все через Него начало быть, и без Него ничто не начало быть, что начало быть.";
    println!("{}", a.accent_text(nt));
}
