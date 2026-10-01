//! Консольная оболочка StudyBible: сборка и проверка модулей.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use studybible_convert::usfm;
use studybible_core::BookCode;
use studybible_store::{Meta, Module, ModuleWriter};

const USAGE: &str = "studybible — консольная оболочка StudyBible

  studybible module build [--defs data/modules.json] [--data <корень данных>] [--out <папка>]
  studybible module info <файл.sb>
  studybible module verse <файл.sb> <КОД> <глава:стих>

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
