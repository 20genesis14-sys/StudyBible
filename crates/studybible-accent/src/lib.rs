//! Автоударения русского текста нейромоделью RUAccent `nn_accent`
//! (MIT, RoFormer по символам; ADR 0017 «Фронтенд языка»).
//!
//! Логика повторяет `ruaccent/accent_model.py` + `char_tokenizer.py`:
//! слово в нижнем регистре → `[bos]` + символы + `[eos]` (int64) →
//! logits по токенам → `STRESS_PRIMARY` с softmax-оценкой ≥ 0.55
//! ставит ударение на символ `text[i-1]` (сдвиг на служебный `[bos]`).
//! Ударение выводится как комбинирующий акцент U+0301 ПОСЛЕ ударной
//! гласной — «+» espeak-ng читает вслух.
//!
//! Крейт не трогает файловую систему: модель, словарь и список
//! ё-слов передаются байтами/строками (ассеты приложения).

use std::collections::HashMap;
use std::fmt;
use std::io::Cursor;
use std::sync::Arc;

use tract_onnx::prelude::*;

/// Комбинирующий акут — ударение после ударной буквы.
pub const ACCENT: char = '\u{0301}';

/// Порог softmax-оценки метки STRESS_PRIMARY (как в RUAccent).
const SCORE_MIN: f32 = 0.55;

/// Максимальная длина слова для модели (max_length из config.json).
const MAX_WORD_CHARS: usize = 40;

/// id метки STRESS_PRIMARY в id2label config.json nn_accent.
const LABEL_STRESS_PRIMARY: usize = 1;

/// Ошибки загрузки модели/словаря и инференса.
#[derive(Debug)]
pub enum AccentError {
    /// Ошибка tract при разборе/оптимизации/исполнении ONNX.
    Model(String),
    /// Словарь vocab.txt не содержит обязательных спецтокенов.
    Vocab(String),
}

impl fmt::Display for AccentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Model(e) => write!(f, "модель акцентуации: {e}"),
            Self::Vocab(e) => write!(f, "vocab.txt: {e}"),
        }
    }
}

impl std::error::Error for AccentError {}

impl From<tract_onnx::prelude::TractError> for AccentError {
    fn from(e: tract_onnx::prelude::TractError) -> Self {
        Self::Model(e.to_string())
    }
}

type Plan = Arc<TypedRunnableModel>;

/// Проставлятор ударений: модель ONNX + посимвольный словарь +
/// словарь ё-слов. Потокобезопасен (модель неизменяема после `new`).
pub struct Accentor {
    model: Plan,
    /// Символ → id токена (формат vocab.txt: токен на строке, id = номер).
    vocab: HashMap<String, i64>,
    bos: i64,
    eos: i64,
    unk: i64,
    /// Порядок входов модели: имена из графа ONNX
    /// (input_ids / attention_mask / token_type_ids).
    inputs: Vec<String>,
    /// Словарь ё: `без_ё` → `с_ё` (ё всегда ударная).
    yo: HashMap<String, String>,
    /// Лексикон: `слово` → `слово` с U+0301 (собран build_lexicon
    /// из словаря RUAccent по словоформам русских модулей).
    lexicon: HashMap<String, String>,
}

impl Accentor {
    /// Загрузить модель из байтов ONNX, словарь `vocab.txt`,
    /// необязательный словарь ё-слов (`без_ё<TAB>с_ё`) и лексикон
    /// ударений (`слово<TAB>с_ударением` с U+0301) — оба TSV.
    pub fn new(
        model_onnx: &[u8],
        vocab: &str,
        yo_words: Option<&str>,
        lexicon: Option<&str>,
    ) -> Result<Self, AccentError> {
        let mut vocab_map = HashMap::new();
        for (i, line) in vocab.lines().enumerate() {
            vocab_map.insert(line.trim_end_matches('\r').to_string(), i as i64);
        }
        let find = |tok: &str| {
            vocab_map
                .get(tok)
                .copied()
                .ok_or_else(|| AccentError::Vocab(format!("нет токена {tok}")))
        };
        let (bos, eos, unk) = (find("[bos]")?, find("[eos]")?, find("[unk]")?);

        let model = tract_onnx::onnx()
            .model_for_read(&mut Cursor::new(model_onnx))?
            .into_optimized()?
            .into_runnable()?;
        // Имена входов — у исходных узлов Source они повторяют сигнатуру
        // ONNX (input_ids, attention_mask, token_type_ids).
        let inputs = model
            .model()
            .input_outlets()?
            .iter()
            .map(|o| model.model().nodes()[o.node].name.to_string())
            .collect();

        let parse_tsv = |tsv: Option<&str>| {
            let mut m = HashMap::new();
            if let Some(tsv) = tsv {
                for line in tsv.lines() {
                    let Some((k, v)) = line.split_once('\t') else {
                        continue;
                    };
                    if !k.is_empty() && !v.is_empty() {
                        m.insert(k.to_string(), v.to_string());
                    }
                }
            }
            m
        };
        let yo = parse_tsv(yo_words);
        let lexicon = parse_tsv(lexicon);

        Ok(Self {
            model,
            vocab: vocab_map,
            bos,
            eos,
            unk,
            inputs,
            yo,
            lexicon,
        })
    }

    /// Ударения в одном слове: U+0301 после ударной гласной.
    /// Слово с уже проставленным U+0301, с «ё»/«Ё», с одной гласной
    /// или длиннее 40 символов возвращается без изменений.
    pub fn accent_word(&self, word: &str) -> String {
        if word.chars().any(|c| c == ACCENT || c == 'ё' || c == 'Ё')
            || word.chars().filter(|c| is_vowel(*c)).count() <= 1
            || word.chars().count() > MAX_WORD_CHARS
        {
            return word.to_string();
        }
        let chars: Vec<char> = word.chars().collect();
        // Токенизация как в CharTokenizer: lower-case, по символам,
        // неизвестные → [unk]; с обрамлением [bos]/[eos].
        let mut ids = Vec::with_capacity(chars.len() + 2);
        ids.push(self.bos);
        for c in word.to_lowercase().chars() {
            let key = c.to_string();
            ids.push(self.vocab.get(&key).copied().unwrap_or(self.unk));
        }
        ids.push(self.eos);
        let seq = ids.len();

        // Входы по именам графа: input_ids — id токенов, attention_mask
        // — единицы, token_type_ids — нули (все [1, seq], int64).
        let mut tensors = tvec![];
        for name in &self.inputs {
            let data = match name.as_str() {
                "input_ids" => ids.clone(),
                "attention_mask" => vec![1i64; seq],
                _ => vec![0i64; seq],
            };
            let Ok(t) = Tensor::from_shape(&[1, seq], &data) else {
                return word.to_string();
            };
            tensors.push(t.into());
        }
        let Ok(out) = self.model.run(tensors) else {
            return word.to_string();
        };
        // logits [1, seq, labels]: argmax + softmax-оценка по токену.
        let Ok(logits) = out[0].to_plain_array_view::<f32>() else {
            return word.to_string();
        };
        let shape = logits.shape();
        if shape.len() != 3 || shape[1] != seq || shape[2] <= LABEL_STRESS_PRIMARY {
            return word.to_string();
        }
        // Одно ударение на слово: из кандидатов STRESS_PRIMARY
        // с softmax-оценкой ≥ 0.55 берём позицию с максимальной
        // вероятностью; ставим только на гласную (согласная-победитель
        // → слово без ударения).
        let mut best: Option<(usize, f32)> = None;
        for i in 0..seq {
            let row = logits.index_axis(tract_ndarray::Axis(1), i);
            let row = row.index_axis(tract_ndarray::Axis(0), 0);
            let (argmax, max) =
                row.iter()
                    .enumerate()
                    .fold(
                        (0, f32::NEG_INFINITY),
                        |acc, (j, &v)| {
                            if v > acc.1 { (j, v) } else { acc }
                        },
                    );
            if argmax != LABEL_STRESS_PRIMARY || i == 0 {
                continue;
            }
            let sum: f32 = row.iter().map(|v| (v - max).exp()).sum();
            let score = (row[LABEL_STRESS_PRIMARY] - max).exp() / sum;
            if score >= SCORE_MIN && i - 1 < chars.len() && best.is_none_or(|(_, s)| score > s) {
                best = Some((i - 1, score));
            }
        }
        let Some((pos, _)) = best else {
            return word.to_string();
        };
        if !is_vowel(chars[pos]) {
            return word.to_string();
        }
        let mut out_text = String::with_capacity(word.len() + 2);
        for (i, c) in chars.iter().enumerate() {
            out_text.push(*c);
            if i == pos {
                out_text.push(ACCENT);
            }
        }
        out_text
    }

    /// Ударения в тексте: деление на слова (кириллица, дефис внутри),
    /// пунктуация/пробелы/регистр сохраняются. Порядок на слово:
    /// словарь ё → лексикон ударений → нейросеть.
    pub fn accent_text(&self, text: &str) -> String {
        let mut out = String::with_capacity(text.len() + 16);
        let mut word = String::new();
        let flush = |out: &mut String, word: &mut String| {
            if word.is_empty() {
                return;
            }
            // Ведущие/замыкающие дефисы — не часть слова.
            let lead = word.len() - word.trim_start_matches('-').len();
            let trail = word.len() - word.trim_end_matches('-').len();
            if lead + trail >= word.len() {
                out.push_str(word);
            } else {
                out.push_str(&word[..lead]);
                out.push_str(&self.accent_or_yo(&word[lead..word.len() - trail]));
                out.push_str(&word[word.len() - trail..]);
            }
            word.clear();
        };
        for c in text.chars() {
            if is_word_char(c) {
                word.push(c);
            } else {
                flush(&mut out, &mut word);
                out.push(c);
            }
        }
        flush(&mut out, &mut word);
        out
    }

    /// Одно слово: сначала словарь ё (ё всегда ударная), затем
    /// лексикон ударений, затем нейросеть (омографы и неохваченные).
    fn accent_or_yo(&self, word: &str) -> String {
        if word.is_empty() {
            return String::new();
        }
        if word.chars().any(|c| c == ACCENT || c == 'ё' || c == 'Ё') {
            return word.to_string();
        }
        let lower = word.to_lowercase();
        // Словарные подмены (ё, лексикон) переносят регистр: слово
        // целиком ЗАГЛАВНЫМИ — вся замена заглавными, иначе только
        // первая буква (Title Case).
        let dict_rep = |rep: &str| {
            if word.chars().any(|c| c.is_uppercase()) && !word.chars().any(|c| c.is_lowercase()) {
                return rep.to_uppercase();
            }
            let mut orig = word.chars();
            match (orig.next(), rep.chars().next()) {
                (Some(first), Some(rep_first)) if first.is_uppercase() => {
                    rep_first.to_uppercase().collect::<String>() + &rep[rep_first.len_utf8()..]
                }
                _ => rep.to_string(),
            }
        };
        if let Some(rep) = self.yo.get(&lower) {
            return dict_rep(rep);
        }
        // Односложные слова ударять не надо — речь становится
        // рубленой («же́», «на́д», «Бо́г»); лексикон их пропускает.
        if word.chars().filter(|c| is_vowel(*c)).count() <= 1 {
            return word.to_string();
        }
        if let Some(rep) = self.lexicon.get(&lower) {
            return dict_rep(rep);
        }
        self.accent_word(word)
    }
}

/// Буква слова: кириллица, дефис внутри слова, акцент U+0301 (чтобы
/// слово с готовым ударением не разваливалось на два).
fn is_word_char(c: char) -> bool {
    c == '-' || c == ACCENT || matches!(c, '\u{0400}'..='\u{04FF}')
}

fn is_vowel(c: char) -> bool {
    matches!(
        c.to_lowercase().next().unwrap_or(c),
        'а' | 'е' | 'ё' | 'и' | 'о' | 'у' | 'ы' | 'э' | 'ю' | 'я'
    )
}
