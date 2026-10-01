//! Нормализация текста для поиска (ADR 0006).

use unicode_normalization::UnicodeNormalization;

/// Уровень «точная форма»: регистр, `ё`=`е`, ударения и мягкие переносы,
/// дореформенные `ѣ` `і` `ѳ` `ѵ`, огласовки и теамим (через NFD).
/// Стемминг и словарные нормализации — отдельные уровни, здесь их нет.
pub fn for_search(s: &str) -> String {
    // `й` разлагается в `и`+бреве, но для поиска «мой» и «мои» — разные формы:
    // прячем `й` за символ частной области перед NFD и возвращаем после.
    let mut out = String::with_capacity(s.len());
    for c in s.replace(['й', 'Й'], "\u{e001}").nfd() {
        match c {
            '\u{ad}' => {}
            '\u{e001}' => out.push('й'),
            'ё' | 'Ё' => out.push('е'),
            'ѣ' | 'Ѣ' => out.push('е'),
            'і' | 'І' => out.push('и'),
            'ѳ' | 'Ѳ' => out.push('ф'),
            'ѵ' | 'Ѵ' => out.push('и'),
            c if is_combining(c) => {}
            c => out.extend(c.to_lowercase()),
        }
    }
    out
}

/// Диакритика и знаки кантилляции (Unicode-категория Mn по диапазонам).
fn is_combining(c: char) -> bool {
    matches!(c as u32,
        0x0300..=0x036F | 0x0483..=0x0489 | 0x0591..=0x05BD | 0x05BF
        | 0x05C1..=0x05C2 | 0x05C4..=0x05C5 | 0x05C7 | 0x0610..=0x061A
        | 0x064B..=0x065F | 0x0670 | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF
        | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}
