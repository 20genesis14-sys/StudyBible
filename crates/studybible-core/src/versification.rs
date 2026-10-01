//! Версификации — данные в формате Paratext `.vrs` (`data/versification/`).
//!
//! Соответствия в `.vrs` описывают переход «эта версификация → org». Стихи 0 — надписания.
//! Неравные диапазоны (`PSA 89:2-6 = PSA 90:1-6`) сопоставляются по порядку,
//! лишние стихи длинной стороны относятся к последнему стиху короткой (открытый вопрос № 8).

use std::collections::{BTreeSet, HashMap};
use std::fmt;
use std::sync::OnceLock;

use crate::book::BookCode;

#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct VerseKey {
    pub book: BookCode,
    pub chapter: u16,
    pub verse: u16,
}

impl VerseKey {
    pub fn new(book: BookCode, chapter: u16, verse: u16) -> Self {
        Self {
            book,
            chapter,
            verse,
        }
    }

    /// `GEN 1:1`; буквенный сегмент (`1:1a`) отбрасывается.
    pub fn parse(s: &str) -> Option<Self> {
        let (book, cv) = s.trim().split_once(' ')?;
        let (c, v) = cv.trim().split_once(':')?;
        let v: String = v.chars().take_while(char::is_ascii_digit).collect();
        Some(Self {
            book: BookCode::new(book)?,
            chapter: c.parse().ok()?,
            verse: v.parse().ok()?,
        })
    }
}

impl fmt::Debug for VerseKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}:{}", self.book, self.chapter, self.verse)
    }
}

#[derive(Debug)]
pub struct Versification {
    name: String,
    chapters: HashMap<BookCode, Vec<u16>>,
    to_org: HashMap<VerseKey, Vec<VerseKey>>,
    from_org: HashMap<VerseKey, Vec<VerseKey>>,
    /// Строки-соответствия, которые не удалось разобрать (содержимое для аудита).
    skipped: Vec<String>,
}

/// Встроенные версификации Paratext.
pub const BUILTIN: [&str; 6] = ["org", "eng", "lxx", "vul", "rso", "rsc"];

impl Versification {
    pub fn builtin(name: &str) -> Option<&'static Versification> {
        macro_rules! vrs {
            ($n:literal) => {{
                static V: OnceLock<Versification> = OnceLock::new();
                V.get_or_init(|| {
                    Versification::parse(
                        $n,
                        include_str!(concat!("../../../data/versification/", $n, ".vrs")),
                    )
                    .expect(concat!($n, ".vrs"))
                })
            }};
        }
        Some(match name {
            "org" => vrs!("org"),
            "eng" => vrs!("eng"),
            "lxx" => vrs!("lxx"),
            "vul" => vrs!("vul"),
            "rso" => vrs!("rso"),
            "rsc" => vrs!("rsc"),
            _ => return None,
        })
    }

    pub fn parse(name: &str, text: &str) -> Result<Self, String> {
        let mut v = Self {
            name: name.into(),
            chapters: HashMap::new(),
            to_org: HashMap::new(),
            from_org: HashMap::new(),
            skipped: vec![],
        };
        for (n, raw) in text.lines().enumerate() {
            let line = raw.split('#').next().unwrap_or("").trim();
            if !line.starts_with(|c: char| c.is_ascii_uppercase() || c.is_ascii_digit()) {
                continue;
            }
            let err = || format!("{name}.vrs:{}: {raw}", n + 1);
            if let Some((lhs, rhs)) = line.split_once('=') {
                // Искажённое соответствие (напр. `DAG 3:52-23` в vul.vrs) пропускаем
                // и записываем — хуже, чем падение всей версификации.
                let (l, r) = match (expand(lhs), expand(rhs)) {
                    (Some(l), Some(r)) => (l, r),
                    _ => {
                        v.skipped.push(err());
                        continue;
                    }
                };
                for i in 0..l.len().max(r.len()) {
                    let (a, b) = (l[i.min(l.len() - 1)], r[i.min(r.len() - 1)]);
                    push_unique(v.to_org.entry(a).or_default(), b);
                    push_unique(v.from_org.entry(b).or_default(), a);
                }
            } else {
                let mut parts = line.split_whitespace();
                let book = parts.next().and_then(BookCode::new).ok_or_else(err)?;
                let sizes = parts
                    .map(|p| p.split_once(':').and_then(|(_, v)| v.parse().ok()))
                    .collect::<Option<Vec<u16>>>()
                    .ok_or_else(err)?;
                v.chapters.insert(book, sizes);
            }
        }
        Ok(v)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Пропущенные при разборе строки-соответствия (для аудита источника).
    pub fn skipped(&self) -> &[String] {
        &self.skipped
    }

    pub fn chapter_count(&self, book: BookCode) -> Option<u16> {
        self.chapters.get(&book).map(|c| c.len() as u16)
    }

    pub fn last_verse(&self, book: BookCode, chapter: u16) -> Option<u16> {
        let i = usize::from(chapter).checked_sub(1)?;
        self.chapters.get(&book)?.get(i).copied()
    }

    pub fn has_book(&self, book: BookCode) -> bool {
        self.chapters.contains_key(&book)
    }

    pub fn contains(&self, k: VerseKey) -> bool {
        self.last_verse(k.book, k.chapter)
            .is_some_and(|max| (1..=max).contains(&k.verse))
    }

    /// Стихи org, соответствующие стиху этой версификации (без соответствия — тот же номер).
    pub fn to_org(&self, k: VerseKey) -> Vec<VerseKey> {
        self.to_org.get(&k).cloned().unwrap_or_else(|| vec![k])
    }

    /// Стихи этой версификации, соответствующие стиху org.
    pub fn from_org(&self, k: VerseKey) -> Vec<VerseKey> {
        if let Some(v) = self.from_org.get(&k) {
            return v.clone();
        }
        if self.to_org.contains_key(&k) {
            vec![]
        } else {
            vec![k]
        }
    }

    /// Перевод стиха между версификациями через org.
    pub fn convert(&self, to: &Versification, k: VerseKey) -> Vec<VerseKey> {
        let set: BTreeSet<VerseKey> = self
            .to_org(k)
            .into_iter()
            .flat_map(|o| to.from_org(o))
            .collect();
        set.into_iter().collect()
    }
}

fn push_unique(v: &mut Vec<VerseKey>, k: VerseKey) {
    if !v.contains(&k) {
        v.push(k);
    }
}

/// `BOOK c:v` или `BOOK c:v-w` → стихи по порядку.
fn expand(side: &str) -> Option<Vec<VerseKey>> {
    let side = side.trim();
    match side.split_once('-') {
        None => Some(vec![VerseKey::parse(side)?]),
        Some((start, end)) => {
            let s = VerseKey::parse(start)?;
            let end: u16 = end
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .ok()?;
            (s.verse <= end).then(|| {
                (s.verse..=end)
                    .map(|verse| VerseKey { verse, ..s })
                    .collect()
            })
        }
    }
}
