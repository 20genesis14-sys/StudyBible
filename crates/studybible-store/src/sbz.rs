//! Контейнер `.sbz` (ADR 0016, п. 6): файл `.sb`, сжатый внешним
//! кодеком, только для передачи. Заголовок: `magic "SBZ1"` (4 байта)
//! + `codec_id` (1 байт) + payload. Кодеки: `0` = zstd (обязателен),
//! `1` = brotli, `2` = xz (зарезервирован); прочие — на будущее.
//!
//! Код здесь — только распаковка (пакует `studybible module pack`).

/// Сигнатура файла `.sbz`.
pub const MAGIC: &[u8; 4] = b"SBZ1";

/// Длина заголовка: magic + байт кодека.
pub const HEADER_LEN: usize = 5;

/// Кодек сжатия из заголовка `.sbz`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Codec {
    /// zstd — обязателен для читателя.
    Zstd,
    /// Brotli.
    Brotli,
    /// xz/LZMA — зарезервирован, распаковки пока нет.
    Xz,
    /// Будущий кодек: распаковки нет, код сообщаем как есть.
    Reserved(u8),
}

impl Codec {
    pub fn from_id(id: u8) -> Self {
        match id {
            0 => Self::Zstd,
            1 => Self::Brotli,
            2 => Self::Xz,
            other => Self::Reserved(other),
        }
    }

    pub fn id(self) -> u8 {
        match self {
            Self::Zstd => 0,
            Self::Brotli => 1,
            Self::Xz => 2,
            Self::Reserved(n) => n,
        }
    }

    /// Имя кодека для сообщений об ошибках.
    pub fn name(self) -> &'static str {
        match self {
            Self::Zstd => "zstd",
            Self::Brotli => "brotli",
            Self::Xz => "xz",
            Self::Reserved(_) => "неизвестный",
        }
    }
}

/// Ошибка распаковки `.sbz`.
#[derive(Debug)]
pub enum SbzError {
    /// Файл короче заголовка или не `.sbz`.
    NotSbz,
    /// Кодек не поддерживается этой сборкой читателя.
    UnsupportedCodec(Codec),
    /// Кодек есть, но данные битые.
    Corrupt(&'static str, String),
}

impl std::fmt::Display for SbzError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotSbz => write!(f, "не файл .sbz (нет сигнатуры SBZ1)"),
            Self::UnsupportedCodec(c) => {
                write!(f, "кодек {} (id {}) не поддерживается", c.name(), c.id())
            }
            Self::Corrupt(c, e) => write!(f, "повреждённый поток {c}: {e}"),
        }
    }
}

impl std::error::Error for SbzError {}

/// `true`, если байты похожи на `.sbz` (проверка по сигнатуре).
pub fn is_sbz(bytes: &[u8]) -> bool {
    bytes.starts_with(MAGIC)
}

/// Распаковать `.sbz` → содержимое `.sb` (SQLite).
pub fn unpack(bytes: &[u8]) -> Result<Vec<u8>, SbzError> {
    if bytes.len() < HEADER_LEN || !is_sbz(bytes) {
        return Err(SbzError::NotSbz);
    }
    let codec = Codec::from_id(bytes[4]);
    let payload = &bytes[HEADER_LEN..];
    match codec {
        Codec::Zstd => {
            let mut out = Vec::new();
            let mut dec = ruzstd::decoding::StreamingDecoder::new(payload)
                .map_err(|e| SbzError::Corrupt("zstd", e.to_string()))?;
            std::io::copy(&mut dec, &mut out)
                .map_err(|e| SbzError::Corrupt("zstd", e.to_string()))?;
            Ok(out)
        }
        Codec::Brotli => {
            let mut out = Vec::new();
            let mut dec = brotli_decompressor::Decompressor::new(payload, 4096);
            std::io::copy(&mut dec, &mut out)
                .map_err(|e| SbzError::Corrupt("brotli", e.to_string()))?;
            Ok(out)
        }
        other => Err(SbzError::UnsupportedCodec(other)),
    }
}
