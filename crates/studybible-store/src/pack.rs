//! Varint-упаковка разметки в блобы (ADR 0022): `t`-спаны блока,
//! токены и alignment стиха — вместо миллиона мелких строк SQLite.
//!
//! Устройство блоба: LEB128-varint'ы — число строк пула, строки с
//! длиной (UTF-8), число записей, затем записи. Пул строк на блоб:
//! `style`/`attrs` и формы слов повторяются массово.

use crate::module::{ModuleError, Result};

/// `t`-спан внутри блоба `span_pack` (позиция `seq` в блоке).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PackedSpan {
    pub seq: u16,
    /// Номер стиха; `None` — заголовочный/вводный текст.
    pub verse: Option<u16>,
    /// Срез `verses.text`; `None` — у спанов с собственным `text`.
    pub start: Option<u32>,
    pub len: Option<u32>,
    pub style: String,
    pub attrs: String,
    /// Собственный текст (заголовочные спаны); у привязанных — пусто.
    pub text: String,
}

/// Токен стиха внутри блоба `token_pack`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PackedToken {
    pub seq: u16,
    pub surface: String,
    pub lemma: String,
    pub strong: String,
    pub morph: String,
    pub gloss: String,
}

/// Запись alignment стиха внутри блоба `align_pack`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PackedAlign {
    pub token_seq: u16,
    pub block: u16,
    pub span: u16,
}

fn wvarint(buf: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            buf.push(b);
            return;
        }
        buf.push(b | 0x80);
    }
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    fn rvarint(&mut self) -> Result<u64> {
        let mut v: u64 = 0;
        let mut shift = 0;
        loop {
            let b = *self
                .buf
                .get(self.pos)
                .ok_or_else(|| ModuleError::BadFormat("pack: обрезанный блоб".into()))?;
            self.pos += 1;
            if shift == 63 && b > 1 {
                return Err(ModuleError::BadFormat("pack: varint > 64 бит".into()));
            }
            v |= ((b & 0x7f) as u64) << shift;
            if b & 0x80 == 0 {
                return Ok(v);
            }
            shift += 7;
        }
    }
    fn rbyte(&mut self) -> Result<u8> {
        let b = *self
            .buf
            .get(self.pos)
            .ok_or_else(|| ModuleError::BadFormat("pack: обрезанный блоб".into()))?;
        self.pos += 1;
        Ok(b)
    }
    fn pool(&mut self) -> Result<Vec<&'a str>> {
        let n = self.rvarint()? as usize;
        if n > 1_000_000 {
            return Err(ModuleError::BadFormat("pack: пул строк раздут".into()));
        }
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            let len = self.rvarint()? as usize;
            let end = self.pos.saturating_add(len);
            if end > self.buf.len() {
                return Err(ModuleError::BadFormat(
                    "pack: строка за концом блоба".into(),
                ));
            }
            let s = std::str::from_utf8(&self.buf[self.pos..end])
                .map_err(|_| ModuleError::BadFormat("pack: строка не UTF-8".into()))?;
            self.pos = end;
            out.push(s);
        }
        Ok(out)
    }
    fn entries(&mut self) -> Result<usize> {
        Ok(self.rvarint()? as usize)
    }
}

fn pool_get(pool: &[&str], i: u64) -> Result<String> {
    pool.get(i as usize)
        .map(|s| s.to_string())
        .ok_or_else(|| ModuleError::BadFormat(format!("pack: индекс пула {i}")))
}

/// Пул строк: собирает уникальные, выдаёт индекс.
struct Pool {
    list: Vec<String>,
    index: std::collections::HashMap<String, u64>,
}

impl Pool {
    fn new() -> Self {
        Self {
            list: Vec::new(),
            index: std::collections::HashMap::new(),
        }
    }
    fn idx(&mut self, s: &str) -> u64 {
        if let Some(&i) = self.index.get(s) {
            return i;
        }
        let i = self.list.len() as u64;
        self.list.push(s.to_string());
        self.index.insert(s.to_string(), i);
        i
    }
    fn write(&self, buf: &mut Vec<u8>) {
        wvarint(buf, self.list.len() as u64);
        for s in &self.list {
            wvarint(buf, s.len() as u64);
            buf.extend_from_slice(s.as_bytes());
        }
    }
}

const V_VERSE: u8 = 1;
const V_SLICE: u8 = 2;
const V_TEXT: u8 = 4;

/// Упаковать `t`-спаны одного блока.
pub fn encode_spans(entries: &[PackedSpan]) -> Vec<u8> {
    let mut pool = Pool::new();
    for e in entries {
        pool.idx(&e.style);
        pool.idx(&e.attrs);
        pool.idx(&e.text);
    }
    let mut buf = Vec::new();
    pool.write(&mut buf);
    wvarint(&mut buf, entries.len() as u64);
    // Повторный проход по пулу — индексы уже стабильны.
    let find = |pool: &Pool, s: &str| pool.index[s];
    for e in entries {
        let mut flags = 0u8;
        if e.verse.is_some() {
            flags |= V_VERSE;
        }
        if e.start.is_some() && e.len.is_some() {
            flags |= V_SLICE;
        }
        if !e.text.is_empty() {
            flags |= V_TEXT;
        }
        buf.push(flags);
        wvarint(&mut buf, e.seq as u64);
        if let Some(v) = e.verse {
            wvarint(&mut buf, v as u64);
        }
        if let (Some(st), Some(ln)) = (e.start, e.len) {
            wvarint(&mut buf, st as u64);
            wvarint(&mut buf, ln as u64);
        }
        wvarint(&mut buf, find(&pool, &e.style));
        wvarint(&mut buf, find(&pool, &e.attrs));
        if flags & V_TEXT != 0 {
            wvarint(&mut buf, find(&pool, &e.text));
        }
    }
    buf
}

/// Распаковать `t`-спаны блока. Порядок = порядок записи (`seq`).
pub fn decode_spans(blob: &[u8]) -> Result<Vec<PackedSpan>> {
    let mut r = Reader::new(blob);
    let pool = r.pool()?;
    let n = r.entries()?;
    if n > 100_000 {
        return Err(ModuleError::BadFormat("pack: записей раздуто".into()));
    }
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let flags = r.rbyte()?;
        let seq = r.rvarint()? as u16;
        let verse = (flags & V_VERSE != 0)
            .then(|| r.rvarint().map(|v| v as u16))
            .transpose()?;
        let (start, len) = if flags & V_SLICE != 0 {
            (Some(r.rvarint()? as u32), Some(r.rvarint()? as u32))
        } else {
            (None, None)
        };
        let style = pool_get(&pool, r.rvarint()?)?;
        let attrs = pool_get(&pool, r.rvarint()?)?;
        let text = if flags & V_TEXT != 0 {
            pool_get(&pool, r.rvarint()?)?
        } else {
            String::new()
        };
        out.push(PackedSpan {
            seq,
            verse,
            start,
            len,
            style,
            attrs,
            text,
        });
    }
    Ok(out)
}

/// Упаковать токены одного стиха.
pub fn encode_tokens(entries: &[PackedToken]) -> Vec<u8> {
    let mut pool = Pool::new();
    for e in entries {
        pool.idx(&e.surface);
        pool.idx(&e.lemma);
        pool.idx(&e.strong);
        pool.idx(&e.morph);
        pool.idx(&e.gloss);
    }
    let mut buf = Vec::new();
    pool.write(&mut buf);
    wvarint(&mut buf, entries.len() as u64);
    let find = |pool: &Pool, s: &str| pool.index[s];
    for e in entries {
        wvarint(&mut buf, e.seq as u64);
        wvarint(&mut buf, find(&pool, &e.surface));
        wvarint(&mut buf, find(&pool, &e.lemma));
        wvarint(&mut buf, find(&pool, &e.strong));
        wvarint(&mut buf, find(&pool, &e.morph));
        wvarint(&mut buf, find(&pool, &e.gloss));
    }
    buf
}

/// Распаковать токены стиха.
pub fn decode_tokens(blob: &[u8]) -> Result<Vec<PackedToken>> {
    let mut r = Reader::new(blob);
    let pool = r.pool()?;
    let n = r.entries()?;
    if n > 100_000 {
        return Err(ModuleError::BadFormat("pack: записей раздуто".into()));
    }
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        out.push(PackedToken {
            seq: r.rvarint()? as u16,
            surface: pool_get(&pool, r.rvarint()?)?,
            lemma: pool_get(&pool, r.rvarint()?)?,
            strong: pool_get(&pool, r.rvarint()?)?,
            morph: pool_get(&pool, r.rvarint()?)?,
            gloss: pool_get(&pool, r.rvarint()?)?,
        });
    }
    Ok(out)
}

/// Упаковать alignment одного стиха.
pub fn encode_align(entries: &[PackedAlign]) -> Vec<u8> {
    let mut buf = Vec::new();
    wvarint(&mut buf, 0); // пул пуст — только числа
    wvarint(&mut buf, entries.len() as u64);
    for e in entries {
        wvarint(&mut buf, e.token_seq as u64);
        wvarint(&mut buf, e.block as u64);
        wvarint(&mut buf, e.span as u64);
    }
    buf
}

/// Распаковать alignment стиха.
pub fn decode_align(blob: &[u8]) -> Result<Vec<PackedAlign>> {
    let mut r = Reader::new(blob);
    r.pool()?;
    let n = r.entries()?;
    if n > 100_000 {
        return Err(ModuleError::BadFormat("pack: записей раздуто".into()));
    }
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        out.push(PackedAlign {
            token_seq: r.rvarint()? as u16,
            block: r.rvarint()? as u16,
            span: r.rvarint()? as u16,
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_roundtrip() {
        let entries = vec![
            PackedSpan {
                seq: 2,
                verse: Some(1),
                start: Some(0),
                len: Some(11),
                style: "w".into(),
                attrs: "strong=\"H7225\"".into(),
                text: String::new(),
            },
            PackedSpan {
                seq: 5,
                verse: None,
                start: None,
                len: None,
                style: String::new(),
                attrs: String::new(),
                text: "Вступление".into(),
            },
        ];
        let blob = encode_spans(&entries);
        assert_eq!(decode_spans(&blob).unwrap(), entries);
    }

    #[test]
    fn tokens_roundtrip() {
        let entries = vec![
            PackedToken {
                seq: 0,
                surface: "In".into(),
                lemma: String::new(),
                strong: String::new(),
                morph: String::new(),
                gloss: String::new(),
            },
            PackedToken {
                seq: 1,
                surface: "beginning".into(),
                lemma: "resheet".into(),
                strong: "H7225".into(),
                morph: "N".into(),
                gloss: "beginning".into(),
            },
        ];
        assert_eq!(decode_tokens(&encode_tokens(&entries)).unwrap(), entries);
    }

    #[test]
    fn align_roundtrip() {
        let entries = vec![
            PackedAlign {
                token_seq: 0,
                block: 0,
                span: 2,
            },
            PackedAlign {
                token_seq: 4,
                block: 1,
                span: 300,
            },
        ];
        assert_eq!(decode_align(&encode_align(&entries)).unwrap(), entries);
    }

    #[test]
    fn rejects_truncated() {
        assert!(decode_spans(&[0x80]).is_err());
        assert!(decode_tokens(&[]).is_err());
        assert!(decode_align(&[1, 0]).is_err());
    }

    #[test]
    fn empty_blobs() {
        assert!(decode_spans(&encode_spans(&[])).unwrap().is_empty());
        assert!(decode_tokens(&encode_tokens(&[])).unwrap().is_empty());
        assert!(decode_align(&encode_align(&[])).unwrap().is_empty());
    }
}
