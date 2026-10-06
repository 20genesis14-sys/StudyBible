//! Автоударения для нейробэкенда чтения вслух (ADR 0017): модель
//! RUAccent nn_accent на tract через `studybible-accent`. Модель и
//! словари приходят из ассетов приложения (словари — gzip) —
//! нативный код не трогает ФС.

use std::io::Read;
use std::sync::{Mutex, OnceLock};

use anyhow::{Context, Result};
use studybible_accent::Accentor;

/// Глобальный акцентор: модель грузится один раз на процесс
/// (инициализация идёт из `prepare` нейробэкенда).
static ACCENTOR: OnceLock<Mutex<Accentor>> = OnceLock::new();

fn gunzip(bytes: &[u8], what: &str) -> Result<String> {
    let mut s = String::new();
    flate2::read::GzDecoder::new(bytes)
        .read_to_string(&mut s)
        .with_context(|| format!("не распаковывается {what}"))?;
    Ok(s)
}

/// Инициализировать акцентор байтами модели и словарей
/// (`accent.onnx`, `vocab.txt`, `yo_words.tsv.gz`, `lexicon.tsv.gz`).
pub fn accent_init(
    model: Vec<u8>,
    vocab: String,
    yo_gz: Vec<u8>,
    lexicon_gz: Vec<u8>,
) -> Result<()> {
    let yo = gunzip(&yo_gz, "yo_words.tsv.gz")?;
    let lexicon = gunzip(&lexicon_gz, "lexicon.tsv.gz")?;
    let a = Accentor::new(&model, &vocab, Some(&yo), Some(&lexicon))?;
    if let Some(slot) = ACCENTOR.get() {
        // Повторная инициализация — заменяем; отравленный мьютекс
        // не паника: восстанавливаем данные и кладём новые.
        match slot.lock() {
            Ok(mut g) => *g = a,
            Err(e) => *e.into_inner() = a,
        }
    } else {
        let _ = ACCENTOR.set(Mutex::new(a));
    }
    Ok(())
}

/// Текст с ударениями U+0301 и ё по словарю. Без инициализации
/// (ассеты не загрузились) или при ошибке — текст как есть.
pub async fn accent_text(text: String) -> String {
    let Some(slot) = ACCENTOR.get() else {
        return text;
    };
    match slot.lock() {
        Ok(a) => a.accent_text(&text),
        Err(e) => e.into_inner().accent_text(&text),
    }
}
