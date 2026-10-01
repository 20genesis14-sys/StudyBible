//! Консольная оболочка StudyBible: сборка и проверка модулей.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use studybible_convert::usfm;
use studybible_core::text::Span;
use studybible_core::{BookCatalog, BookCode, NameProfile, Versification, reference};
use studybible_store::{Meta, Module, ModuleWriter, SearchIndex};

const USAGE: &str = "studybible — консольная оболочка StudyBible

  studybible module build [--defs data/modules.json] [--data <корень данных>] [--out <папка>]
  studybible module info <файл.sb>
  studybible module verse <файл.sb> <КОД> <глава:стих>
  studybible read <файл.sb> \"<ссылка>\"          — глава или диапазон («Быт 1», «Ин 3:16-18»)
  studybible search <файл.sb> \"<запрос>\" [--cache <файл>] [--limit N]

Корень данных: флаг --data, переменная STUDYBIBLE_DATA или ..\\StudyBible-data.";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("module") => match args.get(1).map(String::as_str) {
            Some("build") => run(build(&args[2..])),
            Some("info") => run(info(&args[2..])),
            Some("verse") => run(verse(&args[2..])),
            _ => usage(),
        },
        Some("read") => run(read(&args[1..])),
        Some("search") => run(search(&args[1..])),
        Some("--version") | None => {
            println!("StudyBible {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        _ => usage(),
    }
}

fn usage() -> ExitCode {
    eprintln!("{USAGE}");
    ExitCode::FAILURE
}

fn run(r: Result<(), String>) -> ExitCode {
    match r {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ошибка: {e}");
            ExitCode::FAILURE
        }
    }
}

fn flag(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn positional(args: &[String]) -> Vec<&str> {
    let mut out = Vec::new();
    let mut skip = false;
    for a in args {
        if skip {
            skip = false;
            continue;
        }
        if a.starts_with("--") {
            skip = true;
        } else {
            out.push(a.as_str());
        }
    }
    out
}

fn data_root(args: &[String]) -> Result<PathBuf, String> {
    let root = flag(args, "--data")
        .or_else(|| std::env::var("STUDYBIBLE_DATA").ok())
        .unwrap_or_else(|| "..\\StudyBible-data".into());
    let root = PathBuf::from(root);
    if root.join("sources").is_dir() {
        Ok(root)
    } else {
        Err(format!(
            "корень данных без папки sources: {}",
            root.display()
        ))
    }
}

fn build(args: &[String]) -> Result<(), String> {
    let data = data_root(args)?;
    let defs = flag(args, "--defs").unwrap_or_else(|| "data\\modules.json".into());
    let out = flag(args, "--out")
        .map(PathBuf::from)
        .unwrap_or_else(|| data.join("modules"));
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;

    let text = std::fs::read_to_string(&defs).map_err(|e| format!("{defs}: {e}"))?;
    let json: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("{defs}: {e}"))?;
    let modules = json
        .get("modules")
        .and_then(|m| m.as_array())
        .ok_or_else(|| format!("{defs}: нет «modules»"))?;

    for m in modules {
        let meta = meta_from(m)?;
        let src = data.join("sources").join(&meta.source);
        let file = out.join(format!("{}.sb", meta.id));
        let stats = build_module(&src, &file, &meta)?;
        println!(
            "{}: {} книг, {} глав, {} стихов → {}",
            meta.id,
            stats.books,
            stats.chapters,
            stats.verses,
            file.display()
        );
    }
    Ok(())
}

fn meta_from(v: &serde_json::Value) -> Result<Meta, String> {
    let get = |k: &str| {
        v.get(k)
            .and_then(|x| x.as_str())
            .unwrap_or_default()
            .to_string()
    };
    for k in ["id", "source", "title", "language", "versification"] {
        if get(k).is_empty() {
            return Err(format!("modules.json: нет «{k}»"));
        }
    }
    Ok(Meta {
        id: get("id"),
        source: get("source"),
        title: get("title"),
        language: get("language"),
        direction: if get("direction").is_empty() {
            "ltr".into()
        } else {
            get("direction")
        },
        versification: get("versification"),
        name_profile: get("name_profile"),
        book_order: get("book_order"),
        version: get("version"),
        license: get("license"),
        attribution: get("attribution"),
        ..Meta::default()
    })
}

#[derive(Default)]
struct Stats {
    books: usize,
    chapters: usize,
    verses: usize,
}

fn build_module(src: &Path, out: &Path, meta: &Meta) -> Result<Stats, String> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(src)
        .map_err(|e| format!("{}: {e}", src.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "usfm"))
        .collect();
    files.sort();
    if files.is_empty() {
        return Err(format!("{}: нет *.usfm", src.display()));
    }

    let mut stats = Stats::default();
    let mut w = ModuleWriter::create(out, meta).map_err(|e| e.to_string())?;
    for (ord, f) in files.iter().enumerate() {
        let text = std::fs::read_to_string(f).map_err(|e| format!("{}: {e}", f.display()))?;
        let book = usfm::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?;
        let title = ["toc1", "h", "mt1"]
            .iter()
            .find_map(|k| book.header.get(*k))
            .cloned()
            .unwrap_or_default();
        w.add_book(book.code, ord as u16 + 1, &title, &book.header)
            .map_err(|e| e.to_string())?;
        stats.books += 1;
        stats.chapters += book.chapters.len();
        let mut chapters = book.chapters;
        chapters.sort_by_key(|c| c.number);
        for ch in &chapters {
            stats.verses += ch.verse_texts().len();
            w.add_chapter(book.code, ch).map_err(|e| e.to_string())?;
        }
    }
    w.finish().map_err(|e| e.to_string())?;
    Ok(stats)
}

fn module_arg(args: &[String]) -> Result<PathBuf, String> {
    positional(args)
        .first()
        .map(PathBuf::from)
        .ok_or_else(|| "нужен файл модуля".to_string())
}

fn info(args: &[String]) -> Result<(), String> {
    let m = Module::open(&module_arg(args)?).map_err(|e| e.to_string())?;
    let meta = m.meta();
    println!("id: {}", meta.id);
    println!("title: {}", meta.title);
    println!("language: {}", meta.language);
    println!("versification: {}", meta.versification);
    println!("version: {}", meta.version);
    println!("license: {}", meta.license);
    println!("source: {}", meta.source);
    println!("content_hash: {}", meta.content_hash);
    println!("books: {}", m.books().map_err(|e| e.to_string())?.len());
    Ok(())
}

fn verse(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let file = PathBuf::from(pos.first().ok_or("нужен файл модуля")?);
    let book = pos.get(1).ok_or("нужен код книги")?;
    let (ch, v) = pos
        .get(2)
        .and_then(|s| s.split_once(':'))
        .ok_or("нужна координата <глава:стих>")?;
    let (ch, v): (u16, u16) = (
        ch.parse().map_err(|_| "глава не число")?,
        v.parse().map_err(|_| "стих не число")?,
    );
    let m = Module::open(&file).map_err(|e| e.to_string())?;
    let code = BookCode::new(book).ok_or_else(|| format!("код книги «{book}»"))?;
    match m.verse_text(code, ch, v).map_err(|e| e.to_string())? {
        Some(t) => {
            println!("{t}");
            Ok(())
        }
        None => Err(format!("{book} {ch}:{v}: стиха нет")),
    }
}

fn profile(meta: &Meta) -> NameProfile {
    match meta.name_profile.as_str() {
        "alt" => NameProfile::Alt,
        "en" => NameProfile::English,
        _ => NameProfile::Synodal,
    }
}

/// Текст заголовка/надписания: просто склейка текстовых промежутков.
fn starts_punct(s: &str) -> bool {
    s.starts_with([' ', ',', '.', ';', ':', '!', '?', ')', '»', '”'])
}

fn block_text(b: &studybible_core::text::Block) -> String {
    let mut s = String::new();
    for span in &b.spans {
        if let Span::Text { text, .. } = span {
            if !s.is_empty() && !s.ends_with(' ') && !starts_punct(text) {
                s.push(' ');
            }
            s.push_str(text);
        }
    }
    s
}

fn read(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let file = PathBuf::from(pos.first().ok_or("нужен файл модуля")?);
    let input = pos.get(1..).unwrap_or(&[]).join(" ");
    let m = Module::open(&file).map_err(|e| e.to_string())?;
    let catalog = BookCatalog::builtin();
    let versif = Versification::builtin(m.meta().versification.as_str())
        .ok_or_else(|| format!("неизвестная версификация «{}»", m.meta().versification))?;
    let r = reference::parse(input.as_str(), profile(m.meta()), versif, catalog)
        .map_err(|e| e.to_string())?;

    let first = r.start.chapter.unwrap_or(1);
    let last = r.end.and_then(|e| e.chapter).unwrap_or(first);
    let name = catalog
        .by_code(r.start.book)
        .map(|b| b.name(profile(m.meta())).to_string())
        .unwrap_or_else(|| r.start.book.to_string());
    for n in first..=last {
        let Some(ch) = m.chapter(r.start.book, n).map_err(|e| e.to_string())? else {
            return Err(format!("{name} {n}: главы нет"));
        };
        println!("=== {name} {n} ===");
        let lo = if n == first {
            r.start.verse.unwrap_or(1)
        } else {
            1
        };
        let hi = if n == last {
            r.end.and_then(|e| e.verse).unwrap_or(u16::MAX)
        } else {
            u16::MAX
        };
        let mut line = String::new();
        let mut visible = false;
        for b in &ch.blocks {
            match b.kind() {
                studybible_core::text::BlockKind::Heading => {
                    println!("  [{}]", block_text(b));
                }
                studybible_core::text::BlockKind::Blank => println!(),
                _ => {
                    for s in &b.spans {
                        match s {
                            Span::Verse(v) => {
                                if !line.is_empty() {
                                    println!("  {line}");
                                    line.clear();
                                }
                                visible = lo <= *v && *v <= hi;
                                if visible {
                                    line = format!("{v}. ");
                                }
                            }
                            Span::Text { text, .. } if visible => {
                                if !line.is_empty() && !line.ends_with(' ') && !starts_punct(text) {
                                    line.push(' ');
                                }
                                line.push_str(text);
                            }
                            _ => {}
                        }
                    }
                    if !line.is_empty() {
                        println!("  {line}");
                        line.clear();
                    }
                }
            }
        }
        if !line.is_empty() {
            println!("  {line}");
        }
    }
    Ok(())
}

fn search(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let file = PathBuf::from(pos.first().ok_or("нужен файл модуля")?);
    let query = pos.get(1..).unwrap_or(&[]).join(" ");
    let cache = flag(args, "--cache")
        .map(PathBuf::from)
        .unwrap_or_else(|| file.with_extension("idx"));
    let limit: usize = flag(args, "--limit")
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);
    let m = Module::open(&file).map_err(|e| e.to_string())?;
    let idx = SearchIndex::open(&cache, &m).map_err(|e| e.to_string())?;
    let prof = profile(m.meta());
    let catalog = BookCatalog::builtin();
    for hit in idx.search(&query, limit).map_err(|e| e.to_string())? {
        let name = catalog
            .by_code(hit.book)
            .map(|b| b.abbr(prof).to_string())
            .unwrap_or_else(|| hit.book.to_string());
        let text = m
            .verse_text(hit.book, hit.chapter, hit.verse)
            .map_err(|e| e.to_string())?
            .unwrap_or_else(|| hit.snippet.clone());
        println!("{name} {}:{}  {text}", hit.chapter, hit.verse);
    }
    Ok(())
}
