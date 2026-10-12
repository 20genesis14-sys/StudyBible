//! Автоударения для нейробэкенда чтения вслух (ADR 0017): модель
//! RUAccent nn_accent на tract через `studybible-accent`. Модель и
//! словари приходят из ассетов приложения — нативный код не трогает ФС.

use std::sync::{Mutex, OnceLock};

use anyhow::Result;
use studybible_accent::Accentor;

/// Глобальный акцентор: модель грузится один раз на процесс
/// (инициализация идёт из `prepare` нейробэкенда).
static ACCENTOR: OnceLock<Mutex<Accentor>> = OnceLock::new();

/// Инициализировать акцентор байтами модели и содержимым словарей
/// (`accent.onnx`, `vocab.txt`, `yo_words.tsv`, `lexicon.tsv`).
pub fn accent_init(model: Vec<u8>, vocab: String, yo: String, lexicon: String) -> Result<()> {
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
