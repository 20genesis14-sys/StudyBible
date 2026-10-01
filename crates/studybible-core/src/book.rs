//! Книги, канон и профили названий. Данные — `data/profiles/books.tsv`.

use std::collections::HashMap;
use std::fmt;
use std::sync::OnceLock;

/// Код книги Paratext/USFM (`GEN`, `1SA`, `PS2`…). Используется в версификациях.
#[derive(Copy, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BookCode([u8; 3]);

impl BookCode {
    pub fn new(code: &str) -> Option<Self> {
        let b = code.as_bytes();
        (b.len() == 3
            && b.iter()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()))
        .then(|| Self([b[0], b[1], b[2]]))
    }

    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.0).expect("ASCII")
    }
}

impl fmt::Debug for BookCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl fmt::Display for BookCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Профиль названий и сокращений книг.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Hash)]
pub enum NameProfile {
    /// Альтернативный профиль.
    Alt,
    /// Синодальный перевод.
    Synodal,
    English,
}

impl NameProfile {
    pub const ALL: [NameProfile; 3] = [Self::Alt, Self::Synodal, Self::English];

    fn index(self) -> usize {
        self as usize
    }
}

/// Порядок книг.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum BookOrder {
    /// Порядок основного списка канона (66 книг).
    List,
    /// Порядок синодального издания (77 книг).
    Synodal,
}

#[derive(Clone, Debug)]
pub struct Book {
    pub osis: &'static str,
    pub code: BookCode,
    pub canonical: bool,
    pub order_list: Option<u16>,
    pub order_syn: Option<u16>,
    names: [(&'static str, &'static str); 3],
}

impl Book {
    /// Полное название в профиле; пустое, если в профиле книги нет.
    pub fn name(&self, profile: NameProfile) -> &'static str {
        self.names[profile.index()].0
    }

    pub fn abbr(&self, profile: NameProfile) -> &'static str {
        self.names[profile.index()].1
    }

    pub fn order(&self, order: BookOrder) -> Option<u16> {
        match order {
            BookOrder::List => self.order_list,
            BookOrder::Synodal => self.order_syn,
        }
    }
}

#[derive(Debug)]
pub struct BookCatalog {
    books: Vec<Book>,
    by_code: HashMap<BookCode, usize>,
    by_osis: HashMap<&'static str, usize>,
    by_name: HashMap<(NameProfile, String), usize>,
}

/// Ключ поиска названия: регистр, пробелы, точки и `ё` не различаются.
pub(crate) fn name_key(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace() && *c != '.')
        .flat_map(char::to_lowercase)
        .map(|c| if c == 'ё' { 'е' } else { c })
        .collect()
}

impl BookCatalog {
    /// Встроенный каталог из `data/profiles/books.tsv`.
    pub fn builtin() -> &'static BookCatalog {
        static CATALOG: OnceLock<BookCatalog> = OnceLock::new();
        CATALOG.get_or_init(|| {
            Self::parse(include_str!("../../../data/profiles/books.tsv")).expect("books.tsv")
        })
    }

    pub fn parse(tsv: &'static str) -> Result<Self, String> {
        let mut lines = tsv.lines().filter(|l| !l.trim().is_empty());
        let header: Vec<&str> = lines.next().ok_or("пустой файл")?.split('\t').collect();
        let col = |name: &str| {
            header
                .iter()
                .position(|h| *h == name)
                .ok_or(format!("нет столбца {name}"))
        };
        let c = [
            col("osis")?,
            col("usfm")?,
            col("canon")?,
            col("order_list")?,
            col("order_syn")?,
            col("name_alt")?,
            col("abbr_alt")?,
            col("name_syn")?,
            col("abbr_syn")?,
            col("name_en")?,
            col("abbr_en")?,
        ];
        let mut cat = Self {
            books: vec![],
            by_code: HashMap::new(),
            by_osis: HashMap::new(),
            by_name: HashMap::new(),
        };
        for line in lines {
            let f: Vec<&'static str> = line.split('\t').collect();
            let get = |i: usize| f.get(c[i]).copied().unwrap_or("");
            let num = |i: usize| get(i).parse().ok();
            let code = BookCode::new(get(1)).ok_or(format!("код книги: {line}"))?;
            let book = Book {
                osis: get(0),
                code,
                canonical: match get(2) {
                    "canonical" => true,
                    "noncanonical" => false,
                    other => return Err(format!("canon: {other}")),
                },
                order_list: num(3),
                order_syn: num(4),
                names: [(get(5), get(6)), (get(7), get(8)), (get(9), get(10))],
            };
            let i = cat.books.len();
            if cat.by_code.insert(code, i).is_some() || cat.by_osis.insert(book.osis, i).is_some() {
                return Err(format!("повтор книги: {line}"));
            }
            for p in NameProfile::ALL {
                for s in [book.name(p), book.abbr(p)]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                {
                    if let Some(prev) = cat
                        .by_name
                        .insert((p, name_key(s)), i)
                        .filter(|&prev| prev != i)
                    {
                        return Err(format!(
                            "неоднозначное название «{s}» в {p:?}: {} и {}",
                            cat.books[prev].osis, book.osis
                        ));
                    }
                }
            }
            cat.books.push(book);
        }
        Ok(cat)
    }

    pub fn books(&self) -> &[Book] {
        &self.books
    }

    pub fn by_code(&self, code: BookCode) -> Option<&Book> {
        self.by_code.get(&code).map(|&i| &self.books[i])
    }

    pub fn by_osis(&self, osis: &str) -> Option<&Book> {
        self.by_osis.get(osis).map(|&i| &self.books[i])
    }

    /// Книга по названию или сокращению профиля; коды OSIS и USFM принимаются в любом профиле.
    pub fn lookup(&self, profile: NameProfile, name: &str) -> Option<&Book> {
        let key = name_key(name);
        self.by_name
            .get(&(profile, key.clone()))
            .map(|&i| &self.books[i])
            .or_else(|| {
                self.books
                    .iter()
                    .find(|b| name_key(b.osis) == key || name_key(b.code.as_str()) == key)
            })
    }

    /// Книги в заданном порядке; книги без места в этом порядке не попадают.
    pub fn ordered(&self, order: BookOrder) -> Vec<&Book> {
        let mut v: Vec<&Book> = self
            .books
            .iter()
            .filter(|b| b.order(order).is_some())
            .collect();
        v.sort_by_key(|b| b.order(order));
        v
    }
}
