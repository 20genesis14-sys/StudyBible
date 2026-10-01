//! Испытательные наборы Этапа 0: согласованность данных профилей, ссылок и версификаций.
//!
//! Проверки по файлам репозитория выполняются всегда. Проверки по текстам Библии
//! требуют каталога `STUDYBIBLE_DATA` (по умолчанию `../StudyBible-data`) и
//! пропускаются с сообщением, если его нет.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn data(rel: &str) -> PathBuf {
    repo().join("data").join(rel)
}

fn texts_dir() -> Option<PathBuf> {
    let dir = std::env::var_os("STUDYBIBLE_DATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo().join("../StudyBible-data"))
        .join("sources");
    if dir.is_dir() {
        Some(dir)
    } else {
        eprintln!("SKIPPED: нет каталога текстов {}", dir.display());
        None
    }
}

type Row = HashMap<String, String>;

fn read_tsv(path: &Path) -> Vec<Row> {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let header: Vec<&str> = lines.next().expect("пустой TSV").split('\t').collect();
    lines
        .map(|l| {
            let cells: Vec<&str> = l.split('\t').collect();
            assert_eq!(cells.len(), header.len(), "{}: {l}", path.display());
            header
                .iter()
                .map(|h| h.to_string())
                .zip(cells.iter().map(|c| c.to_string()))
                .collect()
        })
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct VerseRef {
    book: String,
    chapter: u32,
    verse: u32,
}

impl VerseRef {
    fn parse(s: &str) -> Self {
        let (book, cv) = s
            .trim()
            .split_once(' ')
            .unwrap_or_else(|| panic!("ссылка: {s}"));
        let (c, v) = cv.split_once(':').unwrap_or_else(|| panic!("ссылка: {s}"));
        let v: String = v.chars().take_while(char::is_ascii_digit).collect();
        Self {
            book: book.into(),
            chapter: c.parse().unwrap(),
            verse: v.parse().unwrap(),
        }
    }
}

/// Файл версификации Paratext (.vrs): размеры глав и соответствия «эта версификация → org».
struct Vrs {
    chapters: HashMap<String, Vec<u32>>,
    map: BTreeMap<VerseRef, BTreeSet<VerseRef>>,
}

impl Vrs {
    fn load(name: &str) -> Self {
        let text = fs::read_to_string(data(&format!("versification/{name}.vrs"))).unwrap();
        let mut chapters = HashMap::new();
        let mut map: BTreeMap<VerseRef, BTreeSet<VerseRef>> = BTreeMap::new();
        for line in text.lines() {
            let line = line.split('#').next().unwrap().trim();
            if !line.starts_with(|c: char| c.is_ascii_uppercase() || c.is_ascii_digit()) {
                continue;
            }
            if let Some((lhs, rhs)) = line.split_once('=') {
                // Допущение: стихи сопоставляются по порядку, лишние стихи длинной стороны
                // относятся к последнему стиху короткой (1→N, N→1, `89:2-6 = 90:1-6`).
                let (l, r) = (expand(lhs), expand(rhs));
                for i in 0..l.len().max(r.len()) {
                    let (x, y) = (&l[i.min(l.len() - 1)], &r[i.min(r.len() - 1)]);
                    map.entry(x.clone()).or_default().insert(y.clone());
                }
            } else {
                let mut parts = line.split_whitespace();
                let book = parts.next().unwrap().to_string();
                let sizes = parts
                    .map(|p| p.split_once(':').unwrap().1.parse().unwrap())
                    .collect();
                chapters.insert(book, sizes);
            }
        }
        Self { chapters, map }
    }

    fn to_org(&self, r: &VerseRef) -> BTreeSet<VerseRef> {
        self.map
            .get(r)
            .cloned()
            .unwrap_or_else(|| BTreeSet::from([r.clone()]))
    }

    fn contains(&self, r: &VerseRef) -> bool {
        self.chapters
            .get(&r.book)
            .and_then(|c| c.get(r.chapter as usize - 1))
            .is_some_and(|&max| (1..=max).contains(&r.verse))
    }
}

/// `BOOK c:v` или `BOOK c:v-w` → список стихов.
fn expand(side: &str) -> Vec<VerseRef> {
    let side = side.trim();
    match side.split_once('-') {
        None => vec![VerseRef::parse(side)],
        Some((start, end)) => {
            let s = VerseRef::parse(start);
            let end: u32 = end
                .chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .unwrap();
            (s.verse..=end)
                .map(|verse| VerseRef { verse, ..s.clone() })
                .collect()
        }
    }
}

struct Books {
    rows: Vec<Row>,
}

impl Books {
    fn load() -> Self {
        Self {
            rows: read_tsv(&data("profiles/books.tsv")),
        }
    }

    fn by(&self, col: &str, value: &str) -> Option<&Row> {
        self.rows.iter().find(|r| r[col] == value)
    }

    fn usfm(&self, osis: &str) -> String {
        self.by("osis", osis)
            .unwrap_or_else(|| panic!("нет OSIS {osis}"))["usfm"]
            .clone()
    }
}

/// USFM-тексты одного перевода: книга → содержимое файла.
fn load_usfm(dir: &Path, id: &str) -> HashMap<String, String> {
    fs::read_dir(dir.join(id))
        .unwrap()
        .filter_map(|e| {
            let p = e.unwrap().path();
            (p.extension()? == "usfm").then_some(p)
        })
        .map(|p| {
            let t = fs::read_to_string(&p).unwrap();
            let book = t.split_whitespace().nth(1).unwrap().to_string();
            (book, t)
        })
        .collect()
}

/// Текст стиха без разметки USFM (слова со Стронгом, сноски, маркеры).
fn verse_text(usfm: &HashMap<String, String>, r: &VerseRef) -> String {
    let book = &usfm[&r.book];
    let chapter = split_marker(book, "\\c ")
        .remove(&r.chapter)
        .unwrap_or_default();
    let verse = split_marker(&chapter, "\\v ")
        .remove(&r.verse)
        .unwrap_or_default();
    plain(&verse)
}

fn split_marker(text: &str, marker: &str) -> HashMap<u32, String> {
    text.split(marker)
        .skip(1)
        .filter_map(|part| {
            let n: String = part.chars().take_while(char::is_ascii_digit).collect();
            Some((n.parse().ok()?, part[n.len()..].to_string()))
        })
        .collect()
}

fn plain(usfm: &str) -> String {
    let mut no_attrs = String::new();
    let mut rest = usfm;
    while let Some(i) = rest.find('|') {
        no_attrs.push_str(&rest[..i]);
        rest = rest[i..].find('\\').map_or("", |j| &rest[i + j..]);
    }
    no_attrs.push_str(rest);

    let mut out = String::new();
    let mut rest = no_attrs.as_str();
    while let Some(i) = rest.find('\\') {
        out.push_str(&rest[..i]);
        rest = &rest[i + 1..];
        let tag: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '+' || *c == '*')
            .collect();
        rest = &rest[tag.len()..];
        if tag == "f" || tag == "x" {
            let close = format!("\\{tag}*");
            rest = rest.find(&close).map_or("", |j| &rest[j + close.len()..]);
        }
    }
    out.push_str(rest);
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Количество стихов в главах перевода (по максимальному номеру стиха).
fn chapter_sizes(book: &str) -> Vec<u32> {
    let mut chapters: Vec<(u32, u32)> = split_marker(book, "\\c ")
        .into_iter()
        .map(|(c, text)| {
            (
                c,
                split_marker(&text, "\\v ").into_keys().max().unwrap_or(0),
            )
        })
        .collect();
    chapters.sort();
    chapters.into_iter().map(|(_, v)| v).collect()
}

#[test]
fn books_profile_matches_user_list() {
    let books = Books::load();
    let md = fs::read_to_string(data("canon/canon-66-knig.md")).unwrap();
    let mut seen = 0;
    for line in md
        .lines()
        .filter(|l| l.starts_with("| ") && l[2..].starts_with(|c: char| c.is_ascii_digit()))
    {
        let c: Vec<&str> = line.trim_matches('|').split('|').map(str::trim).collect();
        let row = books
            .by("order_list", c[0])
            .unwrap_or_else(|| panic!("нет книги № {}", c[0]));
        assert_eq!(row["canon"], "canonical", "{line}");
        assert_eq!(
            (
                row["abbr_alt"].as_str(),
                row["name_alt"].as_str(),
                row["name_syn"].as_str()
            ),
            (c[1], c[2], c[3]),
            "{line}"
        );
        seen += 1;
    }
    assert_eq!(seen, 66);

    let count = |canon: &str| books.rows.iter().filter(|r| r["canon"] == canon).count();
    assert_eq!((count("canonical"), count("noncanonical")), (66, 12));
    for col in ["osis", "usfm"] {
        let set: BTreeSet<_> = books.rows.iter().map(|r| &r[col]).collect();
        assert_eq!(set.len(), books.rows.len(), "{col} не уникальны");
    }
    let syn: BTreeSet<u32> = books
        .rows
        .iter()
        .filter_map(|r| r["order_syn"].parse().ok())
        .collect();
    assert_eq!(syn, (1..=77).collect(), "синодальный порядок 1..77");
}

#[test]
fn noncanonical_entries_exist_in_rso() {
    let books = Books::load();
    let rso = Vrs::load("rso");
    for row in read_tsv(&data("profiles/noncanonical.tsv")) {
        assert_eq!(row["versification"], "rso");
        match row["kind"].as_str() {
            "book" => {
                let b = books
                    .by("usfm", &row["ref"])
                    .unwrap_or_else(|| panic!("нет {}", row["ref"]));
                assert_eq!(b["canon"], "noncanonical", "{}", row["ref"]);
                assert!(
                    rso.chapters.contains_key(&row["ref"]),
                    "в rso нет {}",
                    row["ref"]
                );
            }
            "range" => {
                let (start, end) = row["ref"].split_once('-').unwrap();
                let s = VerseRef::parse(start);
                let e = VerseRef::parse(&format!("{} {end}", s.book));
                assert!(
                    rso.contains(&s) && rso.contains(&e),
                    "в rso нет {}",
                    row["ref"]
                );
            }
            "todo" => {}
            k => panic!("неизвестный вид {k}"),
        }
    }
}

#[test]
fn references_fixture_is_consistent() {
    let books = Books::load();
    let vrs: HashMap<&str, Vrs> = ["rsc", "rso", "eng"]
        .into_iter()
        .map(|n| (n, Vrs::load(n)))
        .collect();
    for row in read_tsv(&data("tests/references.tsv")) {
        let input = &row["input"];
        let mut token: String = input
            .chars()
            .take_while(|c| !c.is_whitespace() || input.starts_with(|d: char| d.is_ascii_digit()))
            .collect();
        token = token.replace([' ', '.'], "");
        let digits = token.chars().take_while(char::is_ascii_digit).count();
        let book_token: String = token
            .chars()
            .take(digits)
            .chain(token.chars().skip(digits).take_while(|c| c.is_alphabetic()))
            .collect();

        let col = match row["names"].as_str() {
            "syn" => "abbr_syn",
            "alt" => "abbr_alt",
            "en" => "abbr_en",
            n => panic!("профиль {n}"),
        };
        let book = books
            .by(col, &book_token)
            .unwrap_or_else(|| panic!("{input}: нет сокращения «{book_token}» в {col}"));
        let expect_book = row["expect"].split(['.', '-']).next().unwrap();
        assert_eq!(book["osis"], expect_book, "{input}");

        if row["expect_org"] == "-" || row["expect"].contains('-') {
            continue;
        }
        let parts: Vec<&str> = row["expect"].split('.').collect();
        let org: Vec<&str> = row["expect_org"].split('.').collect();
        let v = &vrs[row["versification"].as_str()];
        let src = VerseRef {
            book: books.usfm(parts[0]),
            chapter: parts[1].parse().unwrap(),
            verse: parts.get(2).map_or(1, |s| s.parse().unwrap()),
        };
        let mapped = v.to_org(&src);
        let got = mapped.first().unwrap();
        assert_eq!(got.book, books.usfm(org[0]), "{input}");
        assert_eq!(got.chapter.to_string(), org[1], "{input}");
        if let Some(verse) = org.get(2) {
            assert!(
                mapped.iter().any(|m| m.verse.to_string() == *verse),
                "{input}: {mapped:?}"
            );
        }
    }
}

fn versification_cases() -> Vec<(Row, VerseRef, BTreeSet<VerseRef>, VerseRef)> {
    read_tsv(&data("tests/versification.tsv"))
        .into_iter()
        .map(|r| {
            let src = VerseRef::parse(&r["src_ref"]);
            let org = r["org_refs"].split(',').map(VerseRef::parse).collect();
            let kjv = VerseRef::parse(&r["kjv_ref"]);
            (r, src, org, kjv)
        })
        .collect()
}

#[test]
fn versification_fixture_matches_vrs() {
    let eng = Vrs::load("eng");
    let vrs: HashMap<&str, Vrs> = ["rsc", "rso"]
        .into_iter()
        .map(|n| (n, Vrs::load(n)))
        .collect();
    for (row, src, org, kjv) in versification_cases() {
        let v = &vrs[row["versification"].as_str()];
        assert!(
            v.contains(&src),
            "{}: нет в {}",
            row["src_ref"],
            row["versification"]
        );
        assert_eq!(v.to_org(&src), org, "{} → org", row["src_ref"]);
        assert!(
            !eng.to_org(&kjv).is_disjoint(&org),
            "KJV {} не совпадает с org {:?}",
            row["kjv_ref"],
            org
        );
    }
}

#[test]
fn versification_fixture_matches_texts() {
    let Some(dir) = texts_dir() else { return };
    let syn = load_usfm(&dir, "russyn");
    let kjv = load_usfm(&dir, "eng-kjv2006");
    for (row, src, _, kjv_ref) in versification_cases() {
        let s = verse_text(&syn, &src);
        assert!(
            s.starts_with(&row["src_words"]),
            "russyn {}: «{s}»",
            row["src_ref"]
        );
        let k = verse_text(&kjv, &kjv_ref);
        let k = k.trim_start_matches(['¶', ' ']);
        assert!(
            k.starts_with(&row["kjv_words"]),
            "KJV {}: «{k}»",
            row["kjv_ref"]
        );
    }
}

/// eBible russyn следует rsc, кроме Нав 24 и Притч 4, 13, где стоят вставки из Септуагинты по rso.
#[test]
fn russyn_follows_rsc_except_lxx_insertions() {
    let Some(dir) = texts_dir() else { return };
    let (rsc, rso) = (Vrs::load("rsc"), Vrs::load("rso"));
    let mut deviations = BTreeSet::new();
    for (book, text) in load_usfm(&dir, "russyn") {
        let mine = chapter_sizes(&text);
        let reference = &rsc.chapters[&book];
        assert_eq!(mine.len(), reference.len(), "{book}: число глав");
        for (i, (m, r)) in mine.iter().zip(reference).enumerate() {
            if m != r {
                assert_eq!(
                    *m,
                    rso.chapters[&book][i],
                    "{book} {}: не rsc и не rso",
                    i + 1
                );
                deviations.insert((book.clone(), i as u32 + 1));
            }
        }
    }
    let expected = [("JOS", 24), ("PRO", 4), ("PRO", 13)].map(|(b, c)| (b.to_string(), c));
    assert_eq!(deviations, BTreeSet::from(expected));
}
