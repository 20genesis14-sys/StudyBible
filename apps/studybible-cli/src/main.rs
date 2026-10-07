//! Консольная оболочка StudyBible: сборка и проверка модулей.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

mod speech;

use rusqlite::params;
use speech::TtsSpeech;
use studybible_convert::{biblequote, , mybible, osis, tsv, usfm, zefania};
use studybible_core::speech::Speech;
use studybible_core::text::Span;
use studybible_core::{BookCatalog, BookCode, NameProfile, Versification, reference};
use studybible_store::{Kind, Meta, Module, ModuleWriter, SearchIndex, UserData};

const USAGE: &str = "studybible — консольная оболочка StudyBible

  studybible module build [--defs data/modules.json] [--data <корень данных>] [--out <папка>]
                                       — форматы источников: usfm, osis, zefania, tsv,
                                         entries, , mybible (*.SQLite3),
                                         biblequote (каталог с bibleqt.ini или .zip)
                                       — результат: .sbz (zstd); «sbz»: false → голый .sb,
                                         «both» → .sb + .sbz (веб-раздача)
  studybible module info <файл.sb>
  studybible module verse <файл.sb> <КОД> <глава:стих>
  studybible module check <файл.sb|.sbz>              — проверить модуль
  studybible module rehash <файл.sb>                  — пересчитать content_hash после правок .sb
  studybible module index <файл.sb>                 — встроить FTS5-индекс (таблица `fts`) в готовый .sb
                                        без пересборки из источника; обновляет features,
                                        norm_version и content_hash
  studybible module pack <файл.sb> [--codec zstd|brotli] [--out <файл.sbz>]
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
            Some("check") => run(check(&args[2..])),
            Some("rehash") => run(rehash(&args[2..])),
            Some("index") => run(index(&args[2..])),
            Some("pack") => run(pack(&args[2..])),
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

    // Ошибка одного модуля не останавливает остальные — в конце отчёт.
    let mut failed = Vec::new();
    for m in modules {
        let step = (|| -> Result<String, String> {
            let meta = meta_from(m)?;
            // Формат исходного текста: usfm (по умолчанию) или osis.
            let format = m.get("format").and_then(|f| f.as_str()).unwrap_or("usfm");
            let src = data.join("sources").join(&meta.source);
            let file = out.join(format!("{}.sb", meta.id));
            // Необязательный TSV аппарата рядом с источником (ADR 0016).
            let variants = m
                .get("variants")
                .and_then(|x| x.as_str())
                .map(|v| src.join(v));
            // Необязательный TSV меток времени (ADR 0016 п. 12).
            let marks = m.get("marks").and_then(|x| x.as_str()).map(|v| src.join(v));
            let stats = build_module(
                &src,
                &file,
                &meta,
                format,
                variants.as_deref(),
                marks.as_deref(),
                m.get("fts").and_then(|x| x.as_bool()).unwrap_or(false),
            )?;
            // По умолчанию результат — сжатый .sbz. Режимы ключа «sbz»
            // в defs: false → только .sb (веб-раздача), "both" → .sb + .sbz,
            // отсутствие/true → только .sbz (промежуточный .sb удаляется).
            let target = match m.get("sbz") {
                Some(serde_json::Value::Bool(false)) => file,
                other => {
                    let z = pack_file(&file, "zstd", None)?;
                    if !matches!(other, Some(serde_json::Value::String(s)) if s == "both") {
                        std::fs::remove_file(&file).map_err(|e| e.to_string())?;
                    }
                    z
                }
            };
            Ok(format!(
                "{}: {} книг, {} глав, {} стихов → {}",
                meta.id,
                stats.books,
                stats.chapters,
                stats.verses,
                target.display()
            ))
        })();
        match step {
            Ok(line) => println!("{line}"),
            Err(e) => {
                let id = m.get("id").and_then(|x| x.as_str()).unwrap_or("?");
                eprintln!("ошибка {id}: {e}");
                failed.push(id.to_string());
            }
        }
    }
    if !failed.is_empty() {
        return Err(format!("не собраны: {}", failed.join(", ")));
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

fn build_module(
    src: &Path,
    out: &Path,
    meta: &Meta,
    format: &str,
    variants: Option<&Path>,
    marks: Option<&Path>,
    want_fts: bool,
) -> Result<Stats, String> {
    let exts: &[&str] = match format {
        "usfm" => &["usfm"],
        "osis" => &["osis", "xml"],
        "zefania" => &["xml"],
        "tsv" => &["tsv"],
        "entries" => &["tsv"], // словарь: TSV «заголовок → текст» (ADR 0016)
        "" => &[""], // пакет  (ADR 0016)
        "mybible" => &["sqlite3"], // *.SQLite3 MyBible (ADR 0016 п. 14)
        // bibleqt.ini в каталоге источника либо .zip модуля.
        "biblequote" => &["ini", "zip"],
        other => return Err(format!("modules.json: неизвестный format «{other}»")),
    };
    let mut files: Vec<PathBuf> = std::fs::read_dir(src)
        .map_err(|e| format!("{}: {e}", src.display()))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension()
                .is_some_and(|x| exts.contains(&x.to_str().unwrap_or("").to_lowercase().as_str()))
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

    // Модуль-словарь: без книг и глав, весь контент — статьи entries
    // (формат TSV «entries» или MyBible *.dictionary.SQLite3).
    if format == "entries" || meta.kind == "dictionary" {
        let tmp = out.with_file_name(format!(
            "{}.building",
            out.file_name().unwrap_or_default().to_string_lossy()
        ));
        let _ = std::fs::remove_file(&tmp);
        let w = ModuleWriter::create(&tmp, meta).map_err(|e| e.to_string())?;
        let mut ord = 0u32;
        for f in files.iter() {
            // MyBible-словарь — только *.dictionary.SQLite3: лежащие рядом
            // Библия и комментарии (*.SQLite3, *.commentaries.SQLite3) —
            // чужие роли, не вход входа словаря.
            if format == "mybible"
                && !f
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("")
                    .to_lowercase()
                    .contains(".dictionary.")
            {
                continue;
            }
            let list = if format == "mybible" {
                mybible::parse_dictionary_file(f)
                    .map_err(|e| format!("{}: {}", f.display(), e.0))?
            } else {
                let text =
                    std::fs::read_to_string(f).map_err(|e| format!("{}: {e}", f.display()))?;
                tsv::parse_entries(&text).map_err(|e| format!("{}: {}", f.display(), e.0))?
            };
            for e in list {
                ord += 1;
                w.add_entry(ord, &e.headword, &e.norm, &e.text)
                    .map_err(|e| e.to_string())?;
            }
        }
        let mut features = meta.features.clone();
        if !features.iter().any(|x| x == "entries") {
            features.push("entries".into());
        }
        w.set_meta("features", &features.join(","))
            .map_err(|e| e.to_string())?;
        let kind = if meta.kind.is_empty() {
            "dictionary"
        } else {
            meta.kind.as_str()
        };
        w.set_meta("kind", kind).map_err(|e| e.to_string())?;
        stats.verses = ord as usize; // статей
        w.finish().map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, out).map_err(|e| format!("{}: {e}", out.display()))?;
        return Ok(stats);
    }

    // Пишем во временный файл и переименовываем в конце — неудачная
    // сборка не трогает готовый модуль, повторная сборка перезаписывает.
    let tmp = out.with_file_name(format!(
        "{}.building",
        out.file_name().unwrap_or_default().to_string_lossy()
    ));
    let _ = std::fs::remove_file(&tmp);
    let mut w = ModuleWriter::create(&tmp, meta).map_err(|e| e.to_string())?;
    // Автоопределение возможностей по содержимому (ADR 0016): автору
    // не нужно знать, что внутри — конвертер помечает сам.
    let mut has_strongs = false;
    let mut has_morph = false;
    let mut has_gloss_pairs = false; // спаны с gr="…" — пары подстрочника
    let mut ord = 0u16;
    // BibleQuote: каталог с bibleqt.ini разбирается один раз, хотя
    // файлов-источников может быть несколько.
    let mut bq_done: std::collections::BTreeSet<PathBuf> = std::collections::BTreeSet::new();
    for f in files.iter() {
        // MyBible: сопутствующие файлы (*.commentaries./ *.dictionary.SQLite3)
        // — отдельные модули; в чужой роли пропускаем.
        if format == "mybible" {
            let name = f
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_lowercase();
            let is_comm = name.contains(".commentaries.");
            let is_dict = name.contains(".dictionary.");
            let want = match meta.kind.as_str() {
                "commentary" => is_comm,
                "dictionary" => is_dict,
                _ => !is_comm && !is_dict,
            };
            if !want {
                continue;
            }
        }
        //  — бинарный пакет (ZIP+SQLite), читается по пути, не текстом.
        // kind="commentary" → модуль комментариев из VerseCommentary (ADR 0016 п. 13).
        let books = if format == "" {
            if meta.kind == "commentary" {
                ::parse_commentary_file(f).map_err(|e| format!("{}: {}", f.display(), e.0))?
            } else {
                ::parse_file(f).map_err(|e| format!("{}: {}", f.display(), e.0))?
            }
        } else if format == "mybible" {
            // *.SQLite3 MyBible; kind="commentary" → *.commentaries.SQLite3
            // (kind="dictionary" обработан веткой entries выше).
            if meta.kind == "commentary" {
                mybible::parse_commentary_file(f)
                    .map_err(|e| format!("{}: {}", f.display(), e.0))?
            } else {
                mybible::parse_file(f).map_err(|e| format!("{}: {}", f.display(), e.0))?
            }
        } else if format == "biblequote" {
            // .zip модуля или bibleqt.ini в каталоге: для ini берём
            // каталог; один каталог разбирается один раз.
            let p = if f.extension().is_some_and(|x| x.eq_ignore_ascii_case("ini")) {
                f.parent().unwrap_or(f.as_path())
            } else {
                f.as_path()
            };
            if bq_done.contains(p) {
                vec![]
            } else {
                bq_done.insert(p.to_path_buf());
                if meta.kind == "commentary" {
                    biblequote::parse_commentary_dir(p)
                        .map_err(|e| format!("{}: {}", p.display(), e.0))?
                } else {
                    biblequote::parse_dir(p).map_err(|e| format!("{}: {}", p.display(), e.0))?
                }
            }
        } else {
            let text = std::fs::read_to_string(f).map_err(|e| format!("{}: {e}", f.display()))?;
            // OSIS/Zefania-файл может нести несколько книг, USFM — одну.
            match format {
                "osis" => osis::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?,
                "zefania" => zefania::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?,
                "tsv" => tsv::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?,
                _ => vec![usfm::parse(&text).map_err(|e| format!("{}: {e}", f.display()))?],
            }
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
        if has_gloss_pairs {
            "interlinear"
        } else {
            "bible"
        }
    } else {
        meta.kind.as_str()
    };
    w.set_meta("kind", kind).map_err(|e| e.to_string())?;

    // Аппарат вариантов из TSV (ADR 0016).
    if let Some(vf) = variants {
        let text = std::fs::read_to_string(vf).map_err(|e| format!("{}: {e}", vf.display()))?;
        let list = tsv::parse_variants(&text).map_err(|e| format!("{}: {}", vf.display(), e.0))?;
        for v in &list {
            let readings: Vec<studybible_store::Reading> = v
                .readings
                .iter()
                .map(|r| studybible_store::Reading {
                    text: r.text.clone(),
                    is_base: r.is_base,
                    witnesses: r.witnesses.clone(),
                })
                .collect();
            w.add_variant(
                v.book,
                v.chapter,
                v.verse,
                v.token_from,
                v.token_to,
                &readings,
            )
            .map_err(|e| e.to_string())?;
        }
        if !list.is_empty() && !features.iter().any(|x| x == "variants") {
            features.push("variants".into());
            w.set_meta("features", &features.join(","))
                .map_err(|e| e.to_string())?;
        }
    }

    // Метки времени из TSV (ADR 0016 п. 12).
    if let Some(mf) = marks {
        let text = std::fs::read_to_string(mf).map_err(|e| format!("{}: {e}", mf.display()))?;
        let list = tsv::parse_marks(&text).map_err(|e| format!("{}: {}", mf.display(), e.0))?;
        for m in &list {
            w.add_mark(
                m.book,
                m.chapter,
                &studybible_store::Mark {
                    verse: m.verse,
                    seq: m.seq,
                    offset_ms: m.offset_ms,
                    dur_ms: m.dur_ms,
                    text: m.text.clone(),
                },
            )
            .map_err(|e| e.to_string())?;
        }
        if !list.is_empty() && !features.iter().any(|x| x == "marks") {
            features.push("marks".into());
            w.set_meta("features", &features.join(","))
                .map_err(|e| e.to_string())?;
        }
    }

    // Встроенный индекс FTS5 по запросу автора (ADR 0016 п. 11).
    if want_fts {
        w.build_search_index().map_err(|e| e.to_string())?;
        if !features.iter().any(|x| x == "fts") {
            features.push("fts".into());
            w.set_meta("features", &features.join(","))
                .map_err(|e| e.to_string())?;
        }
    }
    w.finish().map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, out).map_err(|e| format!("{}: {e}", out.display()))?;
    Ok(stats)
}

fn module_arg(args: &[String]) -> Result<PathBuf, String> {
    positional(args)
        .first()
        .map(PathBuf::from)
        .ok_or_else(|| "нужен файл модуля".to_string())
}

fn info(args: &[String]) -> Result<(), String> {
    let path = module_arg(args)?;
    let opened = open_any(&path)?;
    let m = &opened.module;
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

/// Открыть `.sb` или `.sbz`: сжатый модуль распаковывается в память и
/// открывается `sqlite3_deserialize` — без файла на диске.
struct Opened {
    module: Module,
}

fn open_any(path: &Path) -> Result<Opened, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if studybible_store::sbz::is_sbz(&bytes) {
        let raw = studybible_store::sbz::unpack(&bytes)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        return Module::open_bytes(path, &raw)
            .map(|module| Opened { module })
            .map_err(|e| e.to_string());
    }
    Ok(Opened {
        module: Module::open(path).map_err(|e| e.to_string())?,
    })
}

/// `module check`: полная валидация (Module::open проверяет сигнатуру,
/// схему и required) + сводка для автора. Принимает `.sb` и `.sbz`.
fn check(args: &[String]) -> Result<(), String> {
    let file = module_arg(args)?;
    let opened = open_any(&file)?;
    let m = &opened.module;
    let meta = m.meta();
    println!("{}: модуль в порядке", file.display());
    println!("  id: {} · {}", meta.id, meta.title);
    if !meta.kind.is_empty() {
        println!("  kind: {}", meta.kind);
    }
    if !meta.features.is_empty() {
        println!("  features: {}", meta.features.join(", "));
    }
    if !meta.rights.is_empty() {
        println!("  rights: {}", meta.rights.join(", "));
    }
    println!("  книг: {}", m.books().map_err(|e| e.to_string())?.len());
    for w in lint(m) {
        println!("  ! {w}");
    }
    Ok(())
}

/// Семантические предупреждения `module check` (мягкая политика,
/// spec/05 «Семантика»): структура валидна, но есть несоответствия,
/// о которых автору модуля стоит знать.
fn lint(m: &Module) -> Vec<String> {
    let conn = m.conn();
    let meta = m.meta();
    let mut out = Vec::new();

    // Число строк в таблице; таблицы может не быть (необязательные) — 0.
    let count = |table: &str| -> i64 {
        let has: bool = conn
            .query_row(
                "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name=?1",
                params![table],
                |r| r.get(0),
            )
            .unwrap_or(false);
        if !has {
            return 0;
        }
        conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
            .unwrap_or(0)
    };

    // Неизвестный kind (spec/05 С-8) — читается как bible, но автору
    // лучше знать.
    const KINDS: [&str; 6] = [
        "bible",
        "interlinear",
        "commentary",
        "dictionary",
        "layer",
        "critical",
    ];
    if !meta.kind.is_empty() && !KINDS.contains(&meta.kind.as_str()) {
        out.push(format!(
            "неизвестный kind «{}» — читатели покажут как bible",
            meta.kind
        ));
    }

    // Число спанов с данным ключом в attrs (`strong="…"`, `morph="…"`).
    let attr_count = |key: &str| -> i64 {
        conn.query_row(
            "SELECT count(*) FROM spans WHERE attrs LIKE ?1 ESCAPE '\\'",
            params![format!("%{key}=\"%")],
            |r| r.get(0),
        )
        .unwrap_or(0)
    };
    // features: заявленное, но без данных — слой не покажется (С-9).
    // strongs/morph живут в spans.attrs или в tokens — старые модули
    // без таблицы tokens держат их в атрибутах спанов.
    let data = |f: &str| -> i64 {
        match f {
            "strongs" => count("tokens").max(attr_count("strong")),
            "morph" => count("tokens").max(attr_count("morph")),
            "tokens" => count("tokens"),
            "alignment" => count("alignment"),
            "variants" => count("variants"),
            "entries" => count("entries"),
            "marks" => count("marks"),
            "fts" => {
                if m.has_search_index() {
                    1
                } else {
                    0
                }
            }
            _ => -1,
        }
    };
    for f in &meta.features {
        if f.starts_with("x-") {
            continue;
        }
        match data(f) {
            -1 => out.push(format!("неизвестная feature «{f}» — игнорируется")),
            0 => out.push(format!("feature «{f}» заявлена, но данных нет")),
            _ => {}
        }
    }

    // Лишние маркеры 'v': у стиха уже есть текстовые спаны — читатель
    // синтезирует границу сам, маркер дублирует её (С-4).
    let dup_v: i64 = conn
        .query_row(
            "SELECT count(*) FROM spans v
             WHERE v.kind='v' AND EXISTS(
               SELECT 1 FROM spans t
               WHERE t.book_id=v.book_id AND t.chapter=v.chapter
                 AND t.kind='t' AND t.verse=v.num)",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);
    if dup_v > 0 {
        out.push(format!("{dup_v} маркеров 'v' у стихов с текстом — лишние"));
    }

    // Неубывание номеров стихов в главе — только bible/interlinear (С-4).
    if matches!(meta.kind.as_str(), "" | "bible" | "interlinear") {
        let bad: i64 = conn
            .query_row(
                "SELECT count(*) FROM (
                   SELECT verse, lag(verse) OVER (
                     PARTITION BY book_id, chapter
                     ORDER BY book_id, chapter, block, seq) prev
                   FROM spans WHERE verse IS NOT NULL AND verse > 0
                 ) WHERE verse < prev",
                [],
                |r| r.get(0),
            )
            .unwrap_or(0);
        if bad > 0 {
            out.push(format!(
                "{bad} спанов со стихом ниже предыдущего — неубывание нарушено"
            ));
        }
    }

    // bible/commentary без стихов — возможно, собрано не то.
    let verses = count("verses");
    if verses == 0 && matches!(meta.kind.as_str(), "" | "bible" | "interlinear") {
        out.push("пустой verses у текстового модуля".into());
    }
    out
}

/// Упаковать `.sb` → `.sbz`. Возвращает путь к готовому файлу.
fn pack_file(src: &Path, codec: &str, out: Option<PathBuf>) -> Result<PathBuf, String> {
    let (id, name): (u8, &str) = match codec {
        "zstd" => (0, "zstd"),
        "brotli" => (1, "brotli"),
        other => return Err(format!("неизвестный кодек «{other}» (zstd|brotli)")),
    };
    let out = out.unwrap_or_else(|| src.with_extension("sbz"));
    let raw = std::fs::read(src).map_err(|e| format!("{}: {e}", src.display()))?;
    // Пакуем только валидный модуль — иначе ошибка всплывёт у получателя.
    Module::open(src).map_err(|e| format!("{}: {e}", src.display()))?;
    let mut file = Vec::with_capacity(5);
    file.extend_from_slice(studybible_store::sbz::MAGIC);
    file.push(id);
    let body = match name {
        "zstd" => {
            zstd::stream::encode_all(std::io::Cursor::new(&raw), 19).map_err(|e| e.to_string())?
        }
        _ => {
            let mut buf = Vec::new();
            brotli::CompressorWriter::new(&mut buf, 4096, 11, 22)
                .write_all(&raw)
                .map_err(|e| e.to_string())?;
            buf
        }
    };
    file.extend_from_slice(&body);
    std::fs::write(&out, &file).map_err(|e| format!("{}: {e}", out.display()))?;
    println!(
        "{} → {} ({} · {:.0}% от размера)",
        src.display(),
        out.display(),
        name,
        body.len() as f64 * 100.0 / raw.len().max(1) as f64
    );
    Ok(out)
}

/// `module pack`: `.sb` → `.sbz` (zstd по умолчанию, brotli по флагу).
/// Пересчёт meta.content_hash по читаемому потоку (spec/05 С-12) —
/// для модулей, правленых после сборки (inject_xrefs и т. п.).
/// Работает только с распакованным .sb на диске.
fn rehash(args: &[String]) -> Result<(), String> {
    let path = module_arg(args)?;
    let m = Module::open(&path).map_err(|e| e.to_string())?;
    let hash = m.compute_content_hash().map_err(|e| e.to_string())?;
    if m.meta().content_hash == hash {
        println!("{}: хэш уже актуален", m.meta().id);
        return Ok(());
    }
    rusqlite::Connection::open(&path)
        .map_err(|e| e.to_string())?
        .execute(
            "UPDATE meta SET value=?1 WHERE key='content_hash'",
            params![hash],
        )
        .map_err(|e| e.to_string())?;
    println!("{}: хэш обновлён → {}", m.meta().id, hash);
    Ok(())
}

/// `module index`: встроить FTS5-индекс в существующий .sb —
/// та же схема и нормализация, что у встроенного при сборке
/// (`ModuleWriter::build_search_index`); после вставки — features
/// и norm_version в meta и пересчёт content_hash (вопрос № 11).
fn index(args: &[String]) -> Result<(), String> {
    let path = module_arg(args)?;
    if studybible_store::sbz::is_sbz(
        &std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?,
    ) {
        return Err("индекс встраивается в .sb; .sbz пересоберите (module pack)".into());
    }
    let conn = rusqlite::Connection::open(&path).map_err(|e| e.to_string())?;
    let has: i64 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master
              WHERE name='fts' AND sql LIKE '%VIRTUAL TABLE%'",
            [],
            |r| r.get(0),
        )
        .map_err(|e| e.to_string())?;
    if has > 0 {
        println!("{}: индекс уже встроен", path.display());
        return Ok(());
    }
    conn.execute_batch(
        "CREATE VIRTUAL TABLE fts USING fts5(
             book UNINDEXED, chapter UNINDEXED, verse UNINDEXED, norm,
             tokenize='unicode61');",
    )
    .map_err(|e| e.to_string())?;
    let mut n = 0usize;
    {
        let mut rd = conn
            .prepare(
                "SELECT b.code, v.chapter, v.verse, v.text FROM verses v
                 JOIN books b ON b.book_id = v.book_id",
            )
            .map_err(|e| e.to_string())?;
        let mut ins = conn
            .prepare_cached("INSERT INTO fts VALUES(?1, ?2, ?3, ?4)")
            .map_err(|e| e.to_string())?;
        let rows = rd
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, u16>(1)?,
                    r.get::<_, u16>(2)?,
                    r.get::<_, String>(3)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for row in rows {
            let (book, ch, v, text) = row.map_err(|e| e.to_string())?;
            ins.execute(params![
                book,
                ch,
                v,
                studybible_core::normalize::for_search(&studybible_core::text::collapse_spaces(
                    &text
                ))
            ])
            .map_err(|e| e.to_string())?;
            n += 1;
        }
    }
    let mut features: String = conn
        .query_row("SELECT value FROM meta WHERE key='features'", [], |r| {
            r.get(0)
        })
        .unwrap_or_default();
    if !features.split(',').any(|f| f.trim() == "fts") {
        if !features.is_empty() {
            features.push(',');
        }
        features.push_str("fts");
        conn.execute(
            "INSERT OR REPLACE INTO meta VALUES('features', ?1)",
            params![features],
        )
        .map_err(|e| e.to_string())?;
    }
    conn.execute(
        "INSERT OR REPLACE INTO meta VALUES('norm_version', ?1)",
        params![studybible_store::search::TOKENIZER_VERSION],
    )
    .map_err(|e| e.to_string())?;
    drop(conn);
    // Пересчёт хэша — тот же путь, что у `module rehash`.
    let m = Module::open(&path).map_err(|e| e.to_string())?;
    let hash = m.compute_content_hash().map_err(|e| e.to_string())?;
    rusqlite::Connection::open(&path)
        .map_err(|e| e.to_string())?
        .execute(
            "UPDATE meta SET value=?1 WHERE key='content_hash'",
            params![hash],
        )
        .map_err(|e| e.to_string())?;
    println!("{}: встроен индекс fts ({} стихов)", path.display(), n);
    Ok(())
}

fn pack(args: &[String]) -> Result<(), String> {
    let src = module_arg(args)?;
    let codec = flag(args, "--codec").unwrap_or_else(|| "zstd".into());
    let out = flag(args, "--out").map(PathBuf::from);
    pack_file(&src, &codec, out)?;
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
    let opened = open_any(&file)?;
    let m = &opened.module;
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
    let opened = open_any(&file)?;
    let m = &opened.module;
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
    let opened = open_any(&file)?;
    let m = &opened.module;
    let idx = SearchIndex::open(&cache, m).map_err(|e| e.to_string())?;
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
    let opened = open_any(&file)?;
    let m = &opened.module;
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
