//! Консольная оболочка StudyBible: сборка и проверка модулей.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

mod speech;

use speech::TtsSpeech;
use studybible_convert::{osis, usfm, zefania};
use studybible_core::speech::Speech;
use studybible_core::text::Span;
use studybible_core::{BookCatalog, BookCode, NameProfile, Versification, reference};
use studybible_store::{Kind, Meta, Module, ModuleWriter, SearchIndex, UserData};

const USAGE: &str = "studybible — консольная оболочка StudyBible

  studybible module build [--defs data/modules.json] [--data <корень данных>] [--out <папка>]
  studybible module info <файл.sb>
  studybible module verse <файл.sb> <КОД> <глава:стих>
  studybible read <файл.sb> \"<ссылка>\"          — глава или диапазон («Быт 1», «Ин 3:16-18»)
  studybible search <файл.sb> \"<запрос>\" [--cache <файл>] [--limit N]
  studybible user add note|mark|hl <модуль> <КОД> <гл:ст> [текст...] [--db <файл>]
  studybible user list [note|mark|hl] [--db <файл>]
  studybible user del <id> [--db <файл>]
  studybible user export <файл.zip> [--db <файл>]
  studybible user import <файл.zip> [--db <файл>]
  studybible say <файл.sb> \"<ссылка>\"            — прочитать вслух (системный синтезатор)

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
        Some("user") => run(user(&args[1..])),
        Some("say") => run(say(&args[1..])),
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
        // Формат исходного текста: usfm (по умолчанию) или osis.
        let format = m.get("format").and_then(|f| f.as_str()).unwrap_or("usfm");
        let src = data.join("sources").join(&meta.source);
        let file = out.join(format!("{}.sb", meta.id));
        let stats = build_module(&src, &file, &meta, format)?;
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
    // Список возможностей: строка "a,b" или массив ["a","b"].
    let list = |k: &str| -> Vec<String> {
        match v.get(k) {
            Some(serde_json::Value::String(s)) => s
                .split(',')
                .filter(|x| !x.trim().is_empty())
                .map(|x| x.trim().to_string())
                .collect(),
            Some(serde_json::Value::Array(a)) => a
                .iter()
                .filter_map(|x| x.as_str().map(String::from))
                .collect(),
            _ => vec![],
        }
    };
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
        kind: get("kind"),
        features: list("features"),
        rights: list("rights"),
        ..Meta::default()
    })
}

#[derive(Default)]
struct Stats {
    books: usize,
    chapters: usize,
    verses: usize,
}

fn build_module(src: &Path, out: &Path, meta: &Meta, format: &str) -> Result<Stats, String> {
    let exts: &[&str] = match format {
        "usfm" => &["usfm"],
        "osis" => &["osis", "xml"],
        "zefania" => &["xml"],
        other => return Err(format!("modules.json: неизвестный format «{other}»")),
    };
    let mut files: Vec<PathBuf> = std::fs::read_dir(src)
        .map_err(|e| format!("{}: {e}", src.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension()
                .is_some_and(|x| exts.contains(&x.to_str().unwrap_or("")))
        })
        .collect();
    files.sort();
    if files.is_empty() {
        return Err(format!(
            "{}: нет файлов источника ({})",
            src.display(),
            exts.iter()
                .map(|e| format!("*.{e}"))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    let mut stats = Stats::default();
    let mut w = ModuleWriter::create(out, meta).map_err(|e| e.to_string())?;
    // Автоопределение возможностей по содержимому (ADR 0016): автору
    // не нужно знать, что внутри — конвертер помечает сам.
    let mut has_strongs = false;
    let mut has_morph = false;
    let mut has_gloss_pairs = false; // спаны с gr="…" — пары подстрочника
    let mut ord = 0u16;
    for f in files.iter() {
        let text = std::fs::read_to_string(f).map_err(|e| format!("{}: {e}", f.display()))?;
        // OSIS/Zefania-файл может нести несколько книг, USFM — одну.
        let books = match format {
            "osis" => osis::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?,
            "zefania" => {
                zefania::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?
            }
            _ => vec![usfm::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?],
        };
        for book in books {
            ord += 1;
            let title = ["toc1", "h", "mt1"]
                .iter()
                .find_map(|k| book.header.get(*k))
                .cloned()
                .unwrap_or_default();
            w.add_book(book.code, ord, &title, &book.header)
                .map_err(|e| e.to_string())?;
            stats.books += 1;
            stats.chapters += book.chapters.len();
            let mut chapters = book.chapters;
            chapters.sort_by_key(|c| c.number);
            for ch in &chapters {
                stats.verses += ch.verse_texts().len();
                if !(has_strongs && has_morph && has_gloss_pairs) {
                    for b in &ch.blocks {
                        for s in &b.spans {
                            if let Span::Text { attrs, .. } = s {
                                has_strongs |= attrs.contains("strong=");
                                has_morph |= attrs.contains("morph=");
                                has_gloss_pairs |= attrs.contains("gr=");
                            }
                        }
                    }
                }
                w.add_chapter(book.code, ch).map_err(|e| e.to_string())?;
            }
        }
    }
    // Дозаписать определённые возможности и тип модуля.
    let mut features = meta.features.clone();
    for f in [
        (has_strongs, "strongs"),
        (has_morph, "morph"),
        (has_gloss_pairs, "alignment"),
        (w.tokens_written() > 0, "tokens"),
    ] {
        if f.0 && !features.iter().any(|x| x == f.1) {
            features.push(f.1.into());
        }
    }
    if !features.is_empty() {
        w.set_meta("features", &features.join(","))
            .map_err(|e| e.to_string())?;
    }
    // kind: из modules.json; иначе interlinear при глосс-парах, иначе bible.
    let kind = if meta.kind.is_empty() {
        if has_gloss_pairs { "interlinear" } else { "bible" }
    } else {
        meta.kind.as_str()
    };
    w.set_meta("kind", kind).map_err(|e| e.to_string())?;
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
    println!("kind: {}", meta.kind);
    println!("features: {}", meta.features.join(","));
    println!("rights: {}", meta.rights.join(","));
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

    // Глава не задана («Быт») — читаем всю книгу.
    let first = r.start.chapter.unwrap_or(1);
    let last = if r.start.chapter.is_none() {
        versif.chapter_count(r.start.book).unwrap_or(first)
    } else {
        r.end.and_then(|e| e.chapter).unwrap_or(first)
    };
    let name = catalog
        .by_code(r.start.book)
        .map(|b| b.name(profile(m.meta())).to_string())
        .unwrap_or_else(|| r.start.book.to_string());
    for n in first..=last {
        let Some(ch) = m.chapter(r.start.book, n).map_err(|e| e.to_string())? else {
            return Err(format!("{name} {n}: главы нет"));
        };
        println!("=== {name} {n} ===");
        let (lo, hi) = r.verse_bounds(n, 1);
        let mut line = String::new();
        let mut visible = false;
        // Стихи идут по порядку — после верхней границы печатать нечего.
        'blocks: for b in &ch.blocks {
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
                                if *v > hi {
                                    break 'blocks;
                                }
                                visible = lo <= *v;
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

fn user_db(args: &[String]) -> Result<UserData, String> {
    let path = flag(args, "--db").map(PathBuf::from).unwrap_or_else(|| {
        data_root(&[])
            .map(|d| d.join("userdata.db"))
            .unwrap_or_default()
    });
    UserData::open(&path).map_err(|e| e.to_string())
}

fn user(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    match pos.first() {
        Some(&"add") => {
            let kind = pos
                .get(1)
                .and_then(|k| Kind::parse(k))
                .ok_or("вид: note|mark|hl")?;
            let module = pos.get(2).ok_or("нужен id модуля")?;
            let book = pos
                .get(3)
                .and_then(|b| BookCode::new(b))
                .ok_or("нужен код книги")?;
            let (ch, v) = pos
                .get(4)
                .and_then(|s| s.split_once(':'))
                .ok_or("нужна координата <глава:стих>")?;
            let (ch, v): (u16, u16) = (
                ch.parse().map_err(|_| "глава не число")?,
                v.parse().map_err(|_| "стих не число")?,
            );
            let text = pos.get(5..).unwrap_or(&[]).join(" ");
            let anchor = studybible_store::Anchor {
                module,
                book,
                chapter: ch,
                verse: v,
            };
            let id = user_db(args)?
                .add(kind, anchor, &text, "")
                .map_err(|e| e.to_string())?;
            println!("{id}");
            Ok(())
        }
        Some(&"list") => {
            let db = user_db(args)?;
            let filter = pos.get(1).and_then(|k| Kind::parse(k));
            for kind in filter.map_or_else(
                || vec![Kind::Mark, Kind::Highlight, Kind::Note],
                |k| vec![k],
            ) {
                for e in db.entries(kind, None).map_err(|e| e.to_string())? {
                    println!(
                        "{} {} {} {}:{}:{}  {}",
                        kind.as_str(),
                        e.id,
                        e.module,
                        e.book,
                        e.chapter,
                        e.verse,
                        e.text
                    );
                }
            }
            Ok(())
        }
        Some(&"del") => {
            let id = pos.get(1).ok_or("нужен id")?;
            if user_db(args)?.remove(id).map_err(|e| e.to_string())? {
                println!("удалено {id}");
                Ok(())
            } else {
                Err(format!("записи {id} нет"))
            }
        }
        Some(&"export") => {
            let file = pos.get(1).ok_or("нужен файл zip")?;
            let n = user_db(args)?
                .export_zip(Path::new(file))
                .map_err(|e| e.to_string())?;
            println!("экспортировано записей: {n}");
            Ok(())
        }
        Some(&"import") => {
            let file = pos.get(1).ok_or("нужен файл zip")?;
            let s = user_db(args)?
                .import_zip(Path::new(file))
                .map_err(|e| e.to_string())?;
            println!(
                "добавлено {}, обновлено {}, пропущено {}",
                s.added, s.updated, s.skipped
            );
            Ok(())
        }
        _ => Err("user: add|list|del|export|import".into()),
    }
}

/// Глава/диапазон вслух: «Бытие, глава 1. …»; надписание входит, если стих не задан.
fn say(args: &[String]) -> Result<(), String> {
    let pos = positional(args);
    let file = PathBuf::from(pos.first().ok_or("нужен файл модуля")?);
    let input = pos.get(1..).unwrap_or(&[]).join(" ");
    let m = Module::open(&file).map_err(|e| e.to_string())?;
    let catalog = BookCatalog::builtin();
    let versif = Versification::builtin(m.meta().versification.as_str())
        .ok_or_else(|| format!("неизвестная версификация «{}»", m.meta().versification))?;
    let prof = profile(m.meta());
    let r = reference::parse(input.as_str(), prof, versif, catalog).map_err(|e| e.to_string())?;
    let name = catalog
        .by_code(r.start.book)
        .map(|b| b.name(prof).to_string())
        .unwrap_or_else(|| r.start.book.to_string());

    // Глава не задана («Быт») — читаем всю книгу.
    let first = r.start.chapter.unwrap_or(1);
    let last = if r.start.chapter.is_none() {
        versif.chapter_count(r.start.book).unwrap_or(first)
    } else {
        r.end.and_then(|e| e.chapter).unwrap_or(first)
    };
    let mut text = String::new();
    for n in first..=last {
        let ch = m
            .chapter(r.start.book, n)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("{name} {n}: главы нет"))?;
        let (lo, hi) = r.verse_bounds(n, 0);
        if !text.is_empty() {
            text.push(' ');
        }
        text.push_str(&format!("{name}, глава {n}."));
        let t = studybible_core::speech::speakable(&ch, lo, hi);
        if !t.is_empty() {
            text.push(' ');
            text.push_str(&t);
        }
    }
    if text.is_empty() {
        return Err("нет текста для озвучивания".into());
    }
    let mut tts = TtsSpeech::new().map_err(|e| e.to_string())?;
    tts.say(&text, true).map_err(|e| e.to_string())?;
    while tts.speaking() {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    Ok(())
}
