//! Разбор ссылок вида `Ин 3:16`, `1 Кор. 3:16-18`, `Мф 5–7`, `Пс 22` с учётом
//! профиля названий и версификации.

use std::fmt;

use crate::book::{BookCatalog, BookCode, NameProfile};
use crate::versification::{VerseKey, Versification};

/// Точка ссылки: книга, затем необязательные глава и стих.
#[derive(Copy, Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Point {
    pub book: BookCode,
    pub chapter: Option<u16>,
    pub verse: Option<u16>,
}

impl Point {
    fn key(&self) -> Option<VerseKey> {
        Some(VerseKey::new(self.book, self.chapter?, self.verse?))
    }
}

/// Ссылка в конкретной версификации: точка или диапазон.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reference {
    pub versification: String,
    pub start: Point,
    pub end: Option<Point>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    Empty,
    UnknownBook(String),
    BookNotInVersification(String),
    Syntax(String),
    OutOfRange(String),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(f, "пустая ссылка"),
            Self::UnknownBook(b) => write!(f, "неизвестная книга «{b}»"),
            Self::BookNotInVersification(b) => write!(f, "книги {b} нет в версификации"),
            Self::Syntax(s) => write!(f, "не удалось разобрать «{s}»"),
            Self::OutOfRange(s) => write!(f, "нет такого места: {s}"),
        }
    }
}

impl std::error::Error for ParseError {}

const DASHES: [char; 3] = ['-', '–', '—'];

pub fn parse(
    input: &str,
    profile: NameProfile,
    versification: &Versification,
    catalog: &BookCatalog,
) -> Result<Reference, ParseError> {
    let input = input.trim();
    if input.is_empty() {
        return Err(ParseError::Empty);
    }
    // Название книги: необязательные ведущие цифры, затем всё до первой цифры.
    let lead = input
        .find(|c: char| !c.is_ascii_digit() && !c.is_whitespace())
        .unwrap_or(input.len());
    let split = input[lead..]
        .find(|c: char| c.is_ascii_digit())
        .map_or(input.len(), |i| lead + i);
    let (name, rest) = input.split_at(split);
    let name = name.trim().trim_end_matches('.');
    let book = catalog
        .lookup(profile, name)
        .ok_or_else(|| ParseError::UnknownBook(name.into()))?
        .code;
    if !versification.has_book(book) {
        return Err(ParseError::BookNotInVersification(name.into()));
    }
    let single_chapter = versification.chapter_count(book) == Some(1);
    let syntax = || ParseError::Syntax(input.into());

    let rest: String = rest.chars().filter(|c| !c.is_whitespace()).collect();
    let point = |chapter, verse| Point {
        book,
        chapter,
        verse,
    };
    if rest.is_empty() {
        return Ok(Reference {
            versification: versification.name().into(),
            start: point(None, None),
            end: None,
        });
    }
    let (first, second) = match rest.split_once(DASHES) {
        Some((a, b)) => (a, Some(b)),
        None => (rest.as_str(), None),
    };
    let (c, v) = chapter_verse(first).ok_or_else(syntax)?;
    let (c, v) = if single_chapter && v.is_none() {
        (1, Some(c))
    } else {
        (c, v)
    };
    let start = point(Some(c), v);
    let end = match second {
        None => None,
        Some(s) => {
            let (a, b) = chapter_verse(s).ok_or_else(syntax)?;
            Some(match (v, b) {
                (Some(_), None) => point(Some(c), Some(a)),
                (_, Some(b)) => point(Some(a), Some(b)),
                (None, None) => point(Some(a), None),
            })
        }
    };
    if end.is_some_and(|e| e < start) {
        return Err(syntax());
    }
    for p in std::iter::once(start).chain(end) {
        let ok = match (p.chapter, p.verse) {
            (Some(c), None) => versification.last_verse(book, c).is_some(),
            (Some(_), Some(_)) => p.key().is_some_and(|k| versification.contains(k)),
            _ => true,
        };
        if !ok {
            return Err(ParseError::OutOfRange(input.into()));
        }
    }
    Ok(Reference {
        versification: versification.name().into(),
        start,
        end,
    })
}

fn chapter_verse(s: &str) -> Option<(u16, Option<u16>)> {
    match s.split_once([':', '.']) {
        Some((c, v)) => Some((c.parse().ok()?, Some(v.parse().ok()?))),
        None => Some((s.parse().ok()?, None)),
    }
}

impl Reference {
    /// Та же ссылка в версификации `to` (через org). Глава без стиха переводится по первому стиху.
    pub fn convert(&self, from: &Versification, to: &Versification) -> Option<Reference> {
        let map_point = |p: Point, last: bool| -> Option<Point> {
            let Some(chapter) = p.chapter else {
                return Some(p);
            };
            let verse = p.verse.unwrap_or(1);
            let keys = from.convert(to, VerseKey::new(p.book, chapter, verse));
            let k = if last { keys.last() } else { keys.first() }?;
            Some(Point {
                book: k.book,
                chapter: Some(k.chapter),
                verse: p.verse.map(|_| k.verse),
            })
        };
        let start = map_point(self.start, false)?;
        let end = match self.end {
            Some(e) => Some(map_point(e, true)?),
            None if self.start.verse.is_some() => {
                let last = map_point(self.start, true)?;
                (last != start).then_some(last)
            }
            None => None,
        };
        Some(Reference {
            versification: to.name().into(),
            start,
            end,
        })
    }

    /// Включительные границы стиха в главе `chapter`.
    ///
    /// Глава считается уже входящей в ссылку. `open` подставляется, когда стих
    /// не назван: для чтения это 1, для озвучивания надписания — 0.
    /// Точка со стихом («Быт 1:1») — только этот стих. Глава без стиха и книга
    /// целиком — до конца главы. У книги целиком `start.chapter` пуст, поэтому
    /// каждую главу считают отдельно.
    pub fn verse_bounds(&self, chapter: u16, open: u16) -> (u16, u16) {
        let first = self.start.chapter.unwrap_or(chapter);
        let last = self.end.and_then(|e| e.chapter).unwrap_or(first);
        let lo = if chapter == first {
            self.start.verse.unwrap_or(open)
        } else {
            open
        };
        let hi = if chapter != last {
            u16::MAX
        } else if let Some(end) = self.end {
            end.verse.unwrap_or(u16::MAX)
        } else {
            self.start.verse.unwrap_or(u16::MAX)
        };
        (lo, hi)
    }

    /// Запись OSIS: `John.3.16`, `John.3.16-John.3.18`, `Ps.22`, `Ruth`.
    pub fn osis(&self, catalog: &BookCatalog) -> String {
        let one = |p: Point| {
            let mut s = catalog
                .by_code(p.book)
                .map_or(p.book.as_str().to_string(), |b| b.osis.to_string());
            for n in [p.chapter, p.verse].into_iter().flatten() {
                s.push('.');
                s.push_str(&n.to_string());
            }
            s
        };
        match self.end {
            Some(e) => format!("{}-{}", one(self.start), one(e)),
            None => one(self.start),
        }
    }
}
