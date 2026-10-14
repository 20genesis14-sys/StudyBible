//! Чтение модулей .sb для Flutter через `studybible_store::Module`.
//!
//! Формат JSON намеренно повторяет выгрузку
//! `apps/studybible-cli/src/bin/export.rs` — Dart-сторона разбирает его
//! теми же моделями (`lib/models.dart`), что и предвыгруженные JSON-ассеты.

use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

use anyhow::{Context, Result, anyhow};
use serde_json::{Map, Value, json};
use studybible_core::text::{Block, BlockKind, Span};
use studybible_core::{BookCode, VerseKey, Versification};
use studybible_store::Module;

/// Модуль .sb, найденный в каталоге данных.
pub struct ModuleInfo {
    /// `meta.id` модуля — ключ выбора в UI (`russyn`, `engwebp`…).
    pub id: String,
    pub title: String,
    /// BCP 47 (`ru`, `en`, `he`, `grc`).
    pub language: String,
    /// Абсолютный путь к файлу .sb.
    pub path: String,
}

/// Открыть модуль `.sb` или `.sbz` (ADR 0016/0018): `.sb` читается файлом;
/// `.sbz` распаковывается в память и открывается `sqlite3_deserialize` —
/// распакованной копии на диске нет.
/// Открытые модули сессии: соединение SQLite держится один раз на
/// путь. Без кэша каждый вызов читал весь файл и открывал базу заново
/// — карточка с десятком параллельных делала десяток полных чтений
/// .sb с диска (долгие сноски).
static MODULES: LazyLock<Mutex<HashMap<PathBuf, Arc<Mutex<Module>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Путь к модулю-слою перекрёстных ссылок (ADR 0023); None — слой
/// отключён настройкой или файла нет. Задаётся при старте приложения
/// и при смене настройки `xrefLayer`.
static XREF_LAYER: LazyLock<Mutex<Option<PathBuf>>> = LazyLock::new(|| Mutex::new(None));

/// Включить/выключить общий слой параллельных мест (ADR 0023):
/// `path` — `.sb`/`.sbz` слоя; пустая строка — слой отключён.
pub fn xref_layer_set(path: String) {
    let mut g = XREF_LAYER.lock().unwrap_or_else(|e| e.into_inner());
    *g = (!path.is_empty()).then_some(PathBuf::from(path));
}

fn xref_layer_path() -> Option<PathBuf> {
    XREF_LAYER.lock().ok()?.clone()
}

/// Модуль из кэша соединений; при первом обращении — обычное открытие.
/// Блокировка модуля сериализует запросы к нему (запросы короткие).
pub(crate) fn open_cached(path: &Path) -> Result<Arc<Mutex<Module>>> {
    let key = path.to_path_buf();
    {
        let map = MODULES
            .lock()
            .map_err(|_| anyhow!("module cache poisoned"))?;
        if let Some(m) = map.get(&key) {
            return Ok(m.clone());
        }
    }
    let m = Arc::new(Mutex::new(open_any(path)?));
    MODULES
        .lock()
        .map_err(|_| anyhow!("module cache poisoned"))?
        .insert(key, m.clone());
    Ok(m)
}

/// Блокировка кэшированного модуля на время запроса.
pub(crate) fn lock_module(m: &Mutex<Module>) -> Result<std::sync::MutexGuard<'_, Module>> {
    m.lock().map_err(|_| anyhow!("module cache poisoned"))
}

pub(crate) fn open_any(path: &Path) -> Result<Module> {
    // Сниффинг .sbz по первым байтам заголовка — раньше ради этого
    // читался весь файл целиком.
    let mut head = [0u8; 4];
    let is_sbz = {
        let mut f =
            std::fs::File::open(path).with_context(|| format!("не читается {}", path.display()))?;
        f.read_exact(&mut head).is_ok() && studybible_store::sbz::is_sbz(&head)
    };
    if !is_sbz {
        return Ok(Module::open(path)?);
    }
    let bytes = std::fs::read(path).with_context(|| format!("не читается {}", path.display()))?;
    let raw = studybible_store::sbz::unpack(&bytes)
        .with_context(|| format!("{}: распаковка .sbz", path.display()))?;
    Ok(Module::open_bytes(path, &raw)?)
}

/// Сканировать каталог и вернуть модули .sb/.sbz, которые открываются.
/// Битые и посторонние файлы пропускаются — они не должны ронять UI.
pub async fn list_modules(dir: String) -> Result<Vec<ModuleInfo>> {
    let mut out = Vec::new();
    let entries = std::fs::read_dir(&dir).with_context(|| format!("не читается каталог {dir}"))?;
    for e in entries.flatten() {
        let path = e.path();
        let ext = path.extension().and_then(|s| s.to_str());
        // Устаревший кэш распаковки (`.sbz` теперь читается из памяти) —
        // подчищаем и в список не берём.
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if name.ends_with(".unpacked.sb") {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        if !matches!(ext, Some("sb") | Some("sbz")) {
            continue;
        }
        // Рядом лежит несжатый брат — .sbz пропускаем: открытие .sbz
        // для списка — полная распаковка zstd в память, это доминирует
        // во времени сканирования (12.10.2026, замер ~5 с на 16 .sbz).
        if ext == Some("sbz") {
            let sb = path.with_extension("sb");
            if sb.exists() {
                continue;
            }
        }
        if let Ok(m) = open_any(&path) {
            let meta = m.meta();
            // ADR 0023/0024: модули-слои и граф знаний в списках выбора
            // переводов не показываются.
            if meta.kind == "layer" || meta.kind == "knowledge" {
                continue;
            }
            out.push(ModuleInfo {
                id: meta.id.clone(),
                title: meta.title.clone(),
                language: meta.language.clone(),
                path: path.to_string_lossy().to_string(),
            });
        }
    }
    // Подхватываем собранные модули из соседнего work/strongs/, если их ещё
    // нет в каталоге modules/ (step-orig и strongs-step).
    if let Some(parent) = Path::new(&dir).parent() {
        for rel in [
            "work/strongs/orig/step-orig.sb",
            "work/strongs/lexicon/strongs-step.sb",
        ] {
            let p = parent.join(rel);
            if p.exists()
                && let Ok(m) = open_any(&p)
            {
                let meta = m.meta();
                if !out.iter().any(|x| x.id == meta.id) {
                    out.push(ModuleInfo {
                        id: meta.id.clone(),
                        title: meta.title.clone(),
                        language: meta.language.clone(),
                        path: p.to_string_lossy().to_string(),
                    });
                }
            }
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    Ok(out)
}

/// Книга в каталоге модуля (прямая передача через FRB без JSON).
pub struct BookDocInfo {
    pub code: String,
    pub title: String,
    pub chapters: i64,
}

/// Число стихов главы (`key` = `"GEN:1"`, `count` = 31).
pub struct VerseCountInfo {
    pub key: String,
    pub count: i64,
}

/// Типизированный документ модуля без глав (прямая передача через FRB).
pub struct ModuleDocInfo {
    pub id: String,
    pub title: String,
    pub language: String,
    pub versification: String,
    pub kind: String,
    pub features: Vec<String>,
    pub rights: Vec<String>,
    pub books: Vec<BookDocInfo>,
    pub verse_counts: Vec<VerseCountInfo>,
}

/// Спан главы (прямая передача через FRB без JSON).
pub struct SpanDocInfo {
    /// `"v"` (стих), `"t"` (текст), `"f"` / `"x"` (сноска/параллельное).
    pub kind: String,
    pub verse: i64,
    pub text: String,
    pub style: String,
    pub attrs: String,
    pub caller: String,
}

/// Блок главы (`kind` = `"p" | "q" | "h" | "d" | "b"`).
pub struct BlockDocInfo {
    pub kind: String,
    pub marker: String,
    pub spans: Vec<SpanDocInfo>,
}

/// Чтение варианта критического аппарата.
pub struct ReadingDocInfo {
    pub text: String,
    pub is_base: bool,
    pub witnesses: Vec<String>,
}

/// Вариант критического аппарата главы.
pub struct VariantDocInfo {
    pub verse: i64,
    pub token_from: i64,
    pub token_to: i64,
    pub readings: Vec<ReadingDocInfo>,
}

/// Типизированная глава модуля (прямая передача через FRB без JSON).
pub struct ChapterDocInfo {
    pub number: i64,
    pub blocks: Vec<BlockDocInfo>,
    pub variants: Vec<VariantDocInfo>,
    pub layer_mismatch: bool,
}

/// Типизированный документ модуля (без `serde_json` → `String` → `jsonDecode`).
pub async fn module_doc_typed(path: String) -> Result<ModuleDocInfo> {
    let m = open_cached(Path::new(&path))?;
    let m = lock_module(&m)?;
    let meta = m.meta();

    let mut chapter_counts: BTreeMap<String, i64> = BTreeMap::new();
    {
        let mut st = m
            .conn()
            .prepare("SELECT b.code, MAX(v.chapter) FROM verses v JOIN books b ON b.book_id=v.book_id GROUP BY v.book_id")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        for r in rows {
            let (b, c) = r?;
            chapter_counts.insert(b, c);
        }
    }

    let mut books = Vec::new();
    for (code, title) in m.books()? {
        books.push(BookDocInfo {
            code: code.as_str().to_string(),
            title,
            chapters: chapter_counts.get(code.as_str()).copied().unwrap_or(0),
        });
    }

    let mut verse_counts = Vec::new();
    {
        let mut st = m
            .conn()
            .prepare("SELECT b.code, v.chapter, MAX(v.verse) FROM verses v JOIN books b ON b.book_id=v.book_id GROUP BY v.book_id, v.chapter")?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;
        for r in rows {
            let (b, c, v) = r?;
            verse_counts.push(VerseCountInfo {
                key: format!("{b}:{c}"),
                count: v,
            });
        }
    }

    let mut features = meta.features.clone();
    if !features.iter().any(|f| f == "strongs")
        && find_strongs_layer(Path::new(&path), &meta.id).is_some()
    {
        features.push("strongs".into());
    }
    Ok(ModuleDocInfo {
        id: meta.id.clone(),
        title: meta.title.clone(),
        language: meta.language.clone(),
        versification: meta.versification.clone(),
        kind: meta.kind.clone(),
        features,
        rights: meta.rights.clone(),
        books,
        verse_counts,
    })
}

/// Документ модуля в формате export.rs, но без глав: `chapters` пуст —
/// их UI подтягивает лениво через [`chapter_doc`].
pub async fn module_doc(path: String) -> Result<String> {
    let m = open_cached(Path::new(&path))?;
    let m = lock_module(&m)?;
    let meta = m.meta();

    // Число глав по каждой книге.
    let mut chapter_counts: BTreeMap<String, i64> = BTreeMap::new();
    {
        let mut st = m
            .conn()
            .prepare("SELECT b.code, MAX(v.chapter) FROM verses v JOIN books b ON b.book_id=v.book_id GROUP BY v.book_id")?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        for r in rows {
            let (b, c) = r?;
            chapter_counts.insert(b, c);
        }
    }

    let mut books = Vec::new();
    for (code, title) in m.books()? {
        books.push(json!({
            "code": code.as_str(),
            "title": title,
            "chapters": chapter_counts.get(code.as_str()).copied().unwrap_or(0),
        }));
    }

    // Число стихов по каждой главе (для экрана выбора стиха).
    let mut verse_counts = Map::new();
    {
        let mut st = m
            .conn()
            .prepare("SELECT b.code, v.chapter, MAX(v.verse) FROM verses v JOIN books b ON b.book_id=v.book_id GROUP BY v.book_id, v.chapter")?;
        let rows = st.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;
        for r in rows {
            let (b, c, v) = r?;
            verse_counts.insert(format!("{b}:{c}"), Value::from(v));
        }
    }

    let mut features = meta.features.clone();
    if !features.iter().any(|f| f == "strongs")
        && find_strongs_layer(Path::new(&path), &meta.id).is_some()
    {
        features.push("strongs".into());
    }
    let doc = json!({
        "id": meta.id,
        "title": meta.title,
        "language": meta.language,
        "versification": meta.versification,
        // ADR 0016: тип и возможности модуля (пусто у старых .sb).
        "kind": meta.kind,
        "features": features,
        "rights": meta.rights,
        "books": books,
        "verse_counts": verse_counts,
        "chapters": {},
    });
    Ok(doc.to_string())
}

/// Найти файл накладного слоя Стронга `{id}-strongs.sb[z]` рядом с модулем
/// или в `../work/strongs/layers/`.
fn find_strongs_layer(module_path: &Path, module_id: &str) -> Option<PathBuf> {
    let dir = module_path.parent()?;
    for ext in ["sbz", "sb"] {
        let p = dir.join(format!("{module_id}-strongs.{ext}"));
        if p.exists() {
            return Some(p);
        }
    }
    let parent = dir.parent()?;
    for ext in ["sbz", "sb"] {
        let p = parent
            .join("work")
            .join("strongs")
            .join("layers")
            .join(format!("{module_id}-strongs.{ext}"));
        if p.exists() {
            return Some(p);
        }
    }
    None
}

/// Найти вспомогательный модуль (`strongs-step` или `knowledge`) в `modules/`
/// или `work/strongs/`.
fn find_aux_module(base_path: &Path, sub: &str, name: &str) -> Option<PathBuf> {
    let mut cur = Some(base_path);
    while let Some(p) = cur {
        for ext in ["sbz", "sb"] {
            let cand1 = p.join("modules").join(format!("{name}.{ext}"));
            if cand1.exists() {
                return Some(cand1);
            }
            let cand2 = p
                .join("work")
                .join("strongs")
                .join(sub)
                .join(format!("{name}.{ext}"));
            if cand2.exists() {
                return Some(cand2);
            }
            let cand3 = p.join(format!("{name}.{ext}"));
            if cand3.exists() {
                return Some(cand3);
            }
        }
        cur = p.parent();
    }
    None
}

/// Глава в формате export.rs: `{"n":..,"blocks":[..]}`.
/// `None`, если такой главы в модуле нет.
pub async fn chapter_doc(path: String, book: String, chapter: i64) -> Result<Option<String>> {
    if let Some(cmd) = book.strip_prefix('@') {
        return handle_special_query(Path::new(&path), cmd, chapter);
    }
    let m = open_cached(Path::new(&path))?;
    let m = lock_module(&m)?;
    let code = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let number = u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?;
    let Some(mut ch) = m.chapter(code, number)? else {
        return Ok(None);
    };
    // ADR 0023: у модуля без своих `x`-спанов подмешиваем ссылки общего
    // слоя — как виртуальные Note{x} в конце стихов. Ошибки слоя
    // (нет файла, битый) не должны ломать чтение.
    if !m.has_xrefs()
        && let Some(lp) = xref_layer_path()
        && let Ok(layer) = open_cached(&lp)
    {
        let layer = lock_module(&layer)?;
        let _ = inject_layer_xrefs(&mut ch, &layer, code, number, &m.meta().versification);
    }
    // ADR 0025: накладной слой `{id}-strongs.sb[z]` имеет приоритет над
    // встроенной разметкой модуля (например, в engbsb.sb теги eBible сдвинуты)
    // и применяется при совпадении target_id + target_hash + w1.
    let mut layer_mismatch = false;
    if let Some(lp) = find_strongs_layer(Path::new(&path), &m.meta().id)
        && let Ok(layer) = open_cached(&lp)
    {
        let layer = lock_module(&layer)?;
        let lmeta = layer.meta();
        let target_id = lmeta
            .extra
            .get("target_id")
            .map(String::as_str)
            .unwrap_or("");
        let target_hash = lmeta
            .extra
            .get("target_hash")
            .map(String::as_str)
            .unwrap_or("");
        let tokenizer = lmeta
            .extra
            .get("tokenizer")
            .map(String::as_str)
            .unwrap_or("");
        if target_id == m.meta().id
            && tokenizer == studybible_core::text::WORDS_VERSION
            && target_hash == m.meta().content_hash
        {
            let _ = inject_layer_strongs(&mut ch, &layer, code, number);
        } else if target_id == m.meta().id && !target_hash.is_empty() {
            layer_mismatch = true;
        }
    }
    let blocks: Vec<Value> = ch.blocks.iter().map(block_json).collect();
    // ADR 0016: критический аппарат главы, если таблица есть.
    let variants: Vec<Value> = m
        .variants(code, number)?
        .iter()
        .map(|v| {
            json!({
                "verse": v.verse,
                "from": v.token_from,
                "to": v.token_to,
                "readings": v.readings.iter().map(|r| json!({
                    "t": r.text,
                    "base": r.is_base,
                    "w": r.witnesses,
                })).collect::<Vec<_>>(),
            })
        })
        .collect();
    let mut out = json!({"n": ch.number, "blocks": blocks, "variants": variants});
    if layer_mismatch && let Some(obj) = out.as_object_mut() {
        obj.insert("layer_mismatch".into(), Value::Bool(true));
    }
    Ok(Some(out.to_string()))
}

/// Типизированная глава модуля (прямая передача через FRB без JSON).
pub async fn chapter_doc_typed(
    path: String,
    book: String,
    chapter: i64,
) -> Result<Option<ChapterDocInfo>> {
    let m = open_cached(Path::new(&path))?;
    let m = lock_module(&m)?;
    let code = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let number = u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?;
    let Some(mut ch) = m.chapter(code, number)? else {
        return Ok(None);
    };
    if !m.has_xrefs()
        && let Some(lp) = xref_layer_path()
        && let Ok(layer) = open_cached(&lp)
    {
        let layer = lock_module(&layer)?;
        let _ = inject_layer_xrefs(&mut ch, &layer, code, number, &m.meta().versification);
    }
    let mut layer_mismatch = false;
    if let Some(lp) = find_strongs_layer(Path::new(&path), &m.meta().id)
        && let Ok(layer) = open_cached(&lp)
    {
        let layer = lock_module(&layer)?;
        let lmeta = layer.meta();
        let target_id = lmeta
            .extra
            .get("target_id")
            .map(String::as_str)
            .unwrap_or("");
        let target_hash = lmeta
            .extra
            .get("target_hash")
            .map(String::as_str)
            .unwrap_or("");
        let tokenizer = lmeta
            .extra
            .get("tokenizer")
            .map(String::as_str)
            .unwrap_or("");
        if target_id == m.meta().id
            && tokenizer == studybible_core::text::WORDS_VERSION
            && target_hash == m.meta().content_hash
        {
            let _ = inject_layer_strongs(&mut ch, &layer, code, number);
        } else if target_id == m.meta().id && !target_hash.is_empty() {
            layer_mismatch = true;
        }
    }
    let blocks = ch.blocks.iter().map(block_info).collect();
    let variants = m
        .variants(code, number)?
        .iter()
        .map(|v| VariantDocInfo {
            verse: i64::from(v.verse),
            token_from: i64::from(v.token_from),
            token_to: i64::from(v.token_to),
            readings: v
                .readings
                .iter()
                .map(|r| ReadingDocInfo {
                    text: r.text.clone(),
                    is_base: r.is_base,
                    witnesses: r.witnesses.clone(),
                })
                .collect(),
        })
        .collect();
    Ok(Some(ChapterDocInfo {
        number: i64::from(ch.number),
        blocks,
        variants,
        layer_mismatch,
    }))
}

/// Подмешать `x`-ссылки слоя в главу модуля без своих параллельных
/// (ADR 0023): координаты слоя — `eng`, конвертируем в версификацию
/// модуля; вставка — спан `Note{x, caller='+'}` в конец стиха.
fn inject_layer_xrefs(
    ch: &mut studybible_core::text::Chapter,
    layer: &Module,
    book: BookCode,
    chapter: u16,
    to_vrs: &str,
) -> Result<()> {
    let rows = layer.xrefs(book, chapter)?;
    if rows.is_empty() {
        return Ok(());
    }
    let Some(eng) = Versification::builtin("eng") else {
        return Ok(());
    };
    let Some(dst) = Versification::builtin(to_vrs) else {
        return Ok(());
    };
    // Ссылки по стиху версификации модуля.
    let mut by_verse: BTreeMap<u16, Vec<String>> = BTreeMap::new();
    for (v, text) in rows {
        for mk in eng.convert(dst, VerseKey::new(book, chapter, v)) {
            if mk.book == book && mk.chapter == chapter {
                by_verse.entry(mk.verse).or_default().push(text.clone());
            }
        }
    }
    for (v, texts) in by_verse {
        inject_verse_note(ch, v, &texts.join("; "));
    }
    Ok(())
}

/// Наложить записи `links` слоя Стронга (`{id}-strongs.sb`) на текстовые
/// спаны главы по словам токенизатора `w1` (ADR 0025).
/// Побайтовая конкатенация текстов спанов стиха остаётся неизменной
/// (совместимо с TTS и частичными выделениями).
fn strip_strong_attrs(attrs: &str) -> String {
    attrs
        .split_whitespace()
        .filter(|p| {
            !p.starts_with("strong=\"")
                && !p.starts_with("morph=\"")
                && !p.starts_with("lemma=\"")
                && !p.starts_with("conf=\"")
                && !p.starts_with("flags=\"")
                && !p.starts_with("ref=\"")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn inject_layer_strongs(
    ch: &mut studybible_core::text::Chapter,
    layer: &Module,
    book: BookCode,
    chapter: u16,
) -> Result<()> {
    let rows = layer.links(book, chapter)?;
    if rows.is_empty() {
        return Ok(());
    }
    let mut by_vw: HashMap<(u16, u16), studybible_store::Link> = HashMap::with_capacity(rows.len());
    for l in rows {
        by_vw.insert((l.verse, l.word), l);
    }
    // Сквозной счётчик слов стиха по всем блокам главы (стих в поэзии
    // может тянуться через несколько блоков `q`).
    let mut verse_w_idx: HashMap<u16, u16> = HashMap::new();
    let mut cur_v: Option<u16> = None;
    for b in &mut ch.blocks {
        if matches!(b.kind(), BlockKind::Heading | BlockKind::Blank) {
            continue;
        }
        if b.kind() == BlockKind::Superscription && cur_v.is_none() {
            cur_v = Some(0);
        }
        // Шаг 1: снимаем старые встроенные strong-атрибуты и склеиваем
        // соседние текстовые спаны с одинаковым стилем внутри одного стиха.
        let raw_spans = std::mem::take(&mut b.spans);
        let mut merged: Vec<Span> = Vec::with_capacity(raw_spans.len());
        for s in raw_spans {
            match s {
                Span::Text { text, style, attrs } => {
                    let clean_style = if style == "w" { String::new() } else { style };
                    let clean_attrs = strip_strong_attrs(&attrs);
                    if let Some(Span::Text {
                        text: prev_t,
                        style: prev_s,
                        attrs: prev_a,
                    }) = merged.last_mut()
                        && *prev_s == clean_style
                        && *prev_a == clean_attrs
                    {
                        prev_t.push_str(&text);
                        continue;
                    }
                    merged.push(Span::Text {
                        text,
                        style: clean_style,
                        attrs: clean_attrs,
                    });
                }
                other => merged.push(other),
            }
        }

        // Шаг 2: режем склеенные текстовые спаны по словам токенизатора w1.
        let mut new_spans = Vec::with_capacity(merged.len() * 2);
        for s in merged {
            match s {
                Span::Verse(v) => {
                    cur_v = Some(v);
                    new_spans.push(Span::Verse(v));
                }
                Span::Text { text, style, attrs } => {
                    let Some(v) = cur_v else {
                        new_spans.push(Span::Text { text, style, attrs });
                        continue;
                    };
                    let w_idx = verse_w_idx.entry(v).or_insert(0);
                    split_span_by_w1(&text, &style, &attrs, v, w_idx, &by_vw, &mut new_spans);
                }
                other => new_spans.push(other),
            }
        }
        b.spans = new_spans;
    }
    Ok(())
}

/// Разрезать один текстовый спан по словам `w1` и обернуть размеченные слова
/// в спаны с атрибутами `strong`/`conf`/`flags`/`ref`.
fn split_span_by_w1(
    text: &str,
    style: &str,
    attrs: &str,
    verse: u16,
    w_idx: &mut u16,
    by_vw: &HashMap<(u16, u16), studybible_store::Link>,
    out: &mut Vec<Span>,
) {
    let bytes = text.as_bytes();
    let n = bytes.len();
    let mut pos = 0usize;
    let mut plain_start = 0usize;

    while pos < n {
        // Пропускаем пробелы
        while pos < n && text[pos..].chars().next().is_some_and(char::is_whitespace) {
            pos += text[pos..].chars().next().map_or(1, char::len_utf8);
        }
        if pos >= n {
            break;
        }
        let tok_start = pos;
        while pos < n
            && text[pos..]
                .chars()
                .next()
                .is_some_and(|c| !c.is_whitespace())
        {
            pos += text[pos..].chars().next().map_or(1, char::len_utf8);
        }
        let tok = &text[tok_start..pos];
        let trimmed_left = tok.trim_start_matches(|c: char| !c.is_alphanumeric());
        let core = trimmed_left.trim_end_matches(|c: char| !c.is_alphanumeric());
        if core.is_empty() {
            continue;
        }
        let cur_w = *w_idx;
        *w_idx = w_idx.saturating_add(1);
        let Some(link) = by_vw.get(&(verse, cur_w)) else {
            continue;
        };
        if link.strong.is_empty() || link.conf < 3 {
            continue;
        }
        let lead_len = tok.len() - trimmed_left.len();
        let w_start = tok_start + lead_len;
        let w_end = w_start + core.len();
        if w_start > plain_start {
            out.push(Span::Text {
                text: text[plain_start..w_start].to_string(),
                style: style.to_string(),
                attrs: attrs.to_string(),
            });
        }
        let mut w_attrs = attrs.to_string();
        if !w_attrs.is_empty() {
            w_attrs.push(' ');
        }
        w_attrs.push_str(&format!(
            "strong=\"{}\" conf=\"{}\" flags=\"{}\" ref=\"{}\"",
            link.strong.replace('"', "'"),
            link.conf,
            link.flags.replace('"', "'"),
            link.r#ref.replace('"', "'"),
        ));
        out.push(Span::Text {
            text: text[w_start..w_end].to_string(),
            style: if style.is_empty() {
                "w".into()
            } else {
                style.to_string()
            },
            attrs: w_attrs,
        });
        plain_start = w_end;
    }
    if plain_start < n {
        out.push(Span::Text {
            text: text[plain_start..n].to_string(),
            style: style.to_string(),
            attrs: attrs.to_string(),
        });
    }
}

/// Обработка служебных запросов `@lex:...`, `@entity:...`, `@dict_glosses:...`
/// через существующий ABI `chapter_doc` (без изменения `frb_generated`).
fn handle_special_query(base_path: &Path, cmd: &str, chapter: i64) -> Result<Option<String>> {
    if let Some(rest) = cmd.strip_prefix("lex:") {
        return query_lex_and_entity(base_path, rest);
    }
    if let Some(entity_id) = cmd.strip_prefix("entity:") {
        return query_entity_by_id(base_path, entity_id.trim());
    }
    if let Some(book_code) = cmd.strip_prefix("dict_glosses:") {
        return query_dict_glosses(base_path, book_code.trim(), chapter);
    }
    Ok(None)
}

fn extract_attr(attrs: &str, key: &str) -> Option<String> {
    let needle = format!("{key}=\"");
    let i = attrs.find(&needle)? + needle.len();
    let j = attrs[i..].find('"')? + i;
    Some(attrs[i..j].to_string())
}

fn norm_eid_key(eid: &str) -> String {
    let base = eid.rsplit('|').next().unwrap_or(eid);
    if let Some((name, rng)) = base.split_once('@') {
        let first_ref = rng.split('-').next().unwrap_or(rng);
        format!("{name}@{first_ref}")
    } else {
        base.to_string()
    }
}

fn parse_wid_book_ch(wid: &str) -> Option<(u16, i64)> {
    let mut parts = wid.split('.');
    let bk_str = parts.next()?;
    let ch_str = parts.next()?;
    let code = BookCode::new(&bk_str.to_ascii_uppercase())?;
    let bid = studybible_core::BookCatalog::builtin()
        .by_code(code)?
        .order_list?;
    let ch = ch_str.parse::<i64>().ok()?;
    Some((bid, ch))
}

fn find_lex_module(base_path: &Path, lang: &str) -> Option<PathBuf> {
    if lang != "en"
        && let Some(p) = find_aux_module(base_path, "lexicon", "strongs-step-ru")
    {
        return Some(p);
    }
    find_aux_module(base_path, "lexicon", "strongs-step")
        .or_else(|| find_aux_module(base_path, "lexicon", "strongs-step-ru"))
}

fn query_lex_and_entity(base_path: &Path, query: &str) -> Result<Option<String>> {
    let mut parts = query.split('|');
    let strong_raw = parts.next().unwrap_or("").trim();
    let mut morph_code = String::new();
    let mut eid_raw = String::new();
    let mut wid_raw = String::new();
    let mut sns_raw = String::new();
    let mut lang = String::new();
    for p in parts {
        if let Some(v) = p.strip_prefix("morph=") {
            morph_code = v.trim().to_string();
        } else if let Some(v) = p.strip_prefix("eid=") {
            eid_raw = v.trim().to_string();
        } else if let Some(v) = p.strip_prefix("ref=") {
            wid_raw = v.trim().to_string();
        } else if let Some(v) = p.strip_prefix("sns=") {
            sns_raw = v.trim().to_string();
        } else if let Some(v) = p.strip_prefix("lang=") {
            lang = v.trim().to_string();
        }
    }

    // Если передан wid (`Gen.1.1#03`), но нет eid/sns — проверим в step-orig.sb
    let first_wid = wid_raw.split_whitespace().next().unwrap_or("");
    if !first_wid.is_empty()
        && (eid_raw.is_empty() || sns_raw.is_empty())
        && let Some(orig_p) = find_aux_module(base_path, "orig", "step-orig")
        && let Ok(om) = open_cached(&orig_p)
        && let Ok(om) = lock_module(&om)
    {
        let pat = format!("%wid=\"{first_wid}\"%");
        let rows_vec: Vec<String> = if let Some((bid, ch_n)) = parse_wid_book_ch(first_wid) {
            let bid_s = bid.to_string();
            let ch_s = ch_n.to_string();
            om.conn()
                .prepare("SELECT attrs FROM spans WHERE book_id=CAST(?1 AS INTEGER) AND chapter=CAST(?2 AS INTEGER) AND attrs LIKE ?3 LIMIT 5")
                .and_then(|mut st| {
                    st.query_map([&bid_s, &ch_s, &pat], |r| r.get::<_, String>(0))
                        .map(|it| it.flatten().collect())
                })
                .unwrap_or_default()
        } else {
            om.conn()
                .prepare("SELECT attrs FROM spans WHERE attrs LIKE ?1 LIMIT 5")
                .and_then(|mut st| {
                    st.query_map([&pat], |r| r.get::<_, String>(0))
                        .map(|it| it.flatten().collect())
                })
                .unwrap_or_default()
        };
        for a in rows_vec {
            if eid_raw.is_empty()
                && let Some(e) = extract_attr(&a, "eid")
            {
                eid_raw = e;
            }
            if sns_raw.is_empty()
                && let Some(s) = extract_attr(&a, "sns")
            {
                sns_raw = s;
            }
            if morph_code.is_empty()
                && let Some(mc) = extract_attr(&a, "morph")
            {
                morph_code = mc;
            }
        }
    }

    let mut entries_json = Vec::new();
    let mut morph_json = Value::Null;
    if let Some(lex_p) = find_lex_module(base_path, &lang)
        && let Ok(lm) = open_cached(&lex_p)
        && let Ok(lm) = lock_module(&lm)
    {
        let conn = lm.conn();
        for code in strong_raw.split_whitespace() {
            let mut key = code.to_string();
            let row_opt = conn
                .query_row(
                    "SELECT key, estrong, base, lemma, xlit, pos, gloss, sense_label, sense_domain, relation, related, ustrong, conf
                     FROM lex WHERE key=?1",
                    [&key],
                    |r| {
                        Ok((
                            r.get::<_, String>(0)?,
                            r.get::<_, String>(1).unwrap_or_default(),
                            r.get::<_, String>(2).unwrap_or_default(),
                            r.get::<_, String>(3).unwrap_or_default(),
                            r.get::<_, String>(4).unwrap_or_default(),
                            r.get::<_, String>(5).unwrap_or_default(),
                            r.get::<_, String>(6).unwrap_or_default(),
                            r.get::<_, String>(7).unwrap_or_default(),
                            r.get::<_, String>(8).unwrap_or_default(),
                            r.get::<_, String>(9).unwrap_or_default(),
                            r.get::<_, String>(10).unwrap_or_default(),
                            r.get::<_, String>(11).unwrap_or_default(),
                            r.get::<_, i64>(12).unwrap_or(10),
                        ))
                    },
                )
                .ok()
                .or_else(|| {
                    // Поиск по базе через lex_base
                    let base_cand: String = conn
                        .query_row(
                            "SELECT key FROM lex_base WHERE base=?1 ORDER BY key LIMIT 1",
                            [&key],
                            |r| r.get(0),
                        )
                        .ok()?;
                    key = base_cand;
                    conn.query_row(
                        "SELECT key, estrong, base, lemma, xlit, pos, gloss, sense_label, sense_domain, relation, related, ustrong, conf
                         FROM lex WHERE key=?1",
                        [&key],
                        |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, String>(1).unwrap_or_default(),
                                r.get::<_, String>(2).unwrap_or_default(),
                                r.get::<_, String>(3).unwrap_or_default(),
                                r.get::<_, String>(4).unwrap_or_default(),
                                r.get::<_, String>(5).unwrap_or_default(),
                                r.get::<_, String>(6).unwrap_or_default(),
                                r.get::<_, String>(7).unwrap_or_default(),
                                r.get::<_, String>(8).unwrap_or_default(),
                                r.get::<_, String>(9).unwrap_or_default(),
                                r.get::<_, String>(10).unwrap_or_default(),
                                r.get::<_, String>(11).unwrap_or_default(),
                                r.get::<_, i64>(12).unwrap_or(10),
                            ))
                        },
                    )
                    .ok()
                });
            if let Some((
                k,
                estrong,
                base,
                lemma,
                xlit,
                pos,
                gloss,
                sl,
                sd,
                rel,
                related,
                ust,
                cf,
            )) = row_opt
            {
                let mut defs = Vec::new();
                if let Ok(mut st) = conn.prepare(
                    "SELECT def_source, def_license, def FROM lex_def WHERE key=?1 OR key=?2",
                ) && let Ok(rows) = st.query_map([&k, &base], |r| {
                    Ok((
                        r.get::<_, String>(0).unwrap_or_default(),
                        r.get::<_, String>(1).unwrap_or_default(),
                        r.get::<_, String>(2).unwrap_or_default(),
                    ))
                }) {
                    for (src, lic, d) in rows.flatten() {
                        defs.push(json!({"src": src, "lic": lic, "def": d}));
                    }
                }
                entries_json.push(json!({
                    "key": k,
                    "estrong": estrong,
                    "base": base,
                    "lemma": lemma,
                    "xlit": xlit,
                    "pos": pos,
                    "gloss": gloss,
                    "sense_label": sl,
                    "sense_domain": sd,
                    "relation": rel,
                    "related": related,
                    "ustrong": ust,
                    "conf": cf,
                    "defs": defs,
                }));
            }
        }
        if !morph_code.is_empty() {
            let mut mlist = Vec::new();
            for mc in morph_code.split_whitespace() {
                if let Ok((sh, lg)) =
                    conn.query_row("SELECT short, long FROM morph WHERE code=?1", [mc], |r| {
                        Ok((
                            r.get::<_, String>(0).unwrap_or_default(),
                            r.get::<_, String>(1).unwrap_or_default(),
                        ))
                    })
                {
                    mlist.push(json!({"code": mc, "short": sh, "long": lg}));
                }
            }
            if !mlist.is_empty() {
                morph_json = Value::Array(mlist);
            }
        }
    }

    let entity_json = find_entity_for_card(base_path, &eid_raw, strong_raw).unwrap_or(Value::Null);
    Ok(Some(
        json!({
            "entries": entries_json,
            "morph": morph_json,
            "context_sense": sns_raw,
            "wid": wid_raw,
            "entity": entity_json,
        })
        .to_string(),
    ))
}

fn find_entity_for_card(base_path: &Path, eid_raw: &str, strong_raw: &str) -> Result<Value> {
    let Some(kp) = find_aux_module(base_path, "knowledge", "knowledge") else {
        return Ok(Value::Null);
    };
    let km = open_cached(&kp)?;
    let km = lock_module(&km)?;
    let conn = km.conn();

    let mut ent_id: Option<String> = None;
    if !eid_raw.is_empty() {
        let ne = norm_eid_key(eid_raw);
        let pat = format!("%\"{ne}%");
        ent_id = conn
            .query_row(
                "SELECT id FROM entities WHERE metadata LIKE ?1 LIMIT 1",
                [&pat],
                |r| r.get(0),
            )
            .ok();
    }
    if ent_id.is_none() {
        for code in strong_raw.split_whitespace() {
            if code.starts_with("H9") || code.starts_with("G9") || code == "G3588" {
                continue;
            }
            let pat = format!("%{code}%");
            if let Ok(id) = conn.query_row(
                "SELECT id FROM entities WHERE (' ' || strongs || ' ') LIKE '% ' || ?1 || ' %' LIMIT 1",
                [code],
                |r| r.get::<_, String>(0),
            ) {
                ent_id = Some(id);
                break;
            }
            let _ = pat;
        }
    }
    let Some(id) = ent_id else {
        return Ok(Value::Null);
    };
    load_entity_json(&km, &id)
}

fn query_entity_by_id(base_path: &Path, entity_id: &str) -> Result<Option<String>> {
    let Some(kp) = find_aux_module(base_path, "knowledge", "knowledge") else {
        return Ok(None);
    };
    let km = open_cached(&kp)?;
    let km = lock_module(&km)?;
    let v = load_entity_json(&km, entity_id)?;
    if v.is_null() {
        Ok(None)
    } else {
        Ok(Some(v.to_string()))
    }
}

fn load_entity_json(km: &Module, entity_id: &str) -> Result<Value> {
    let conn = km.conn();
    let Ok((id, typ, sub, name, name_orig, strongs, desc, article, meta_str)) = conn.query_row(
        "SELECT id, type, subtype, name, name_original, strongs, short_description, article, metadata
         FROM entities WHERE id=?1",
        [entity_id],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1).unwrap_or_default(),
                r.get::<_, String>(2).unwrap_or_default(),
                r.get::<_, String>(3).unwrap_or_default(),
                r.get::<_, String>(4).unwrap_or_default(),
                r.get::<_, String>(5).unwrap_or_default(),
                r.get::<_, String>(6).unwrap_or_default(),
                r.get::<_, String>(7).unwrap_or_default(),
                r.get::<_, String>(8).unwrap_or_default(),
            ))
        },
    ) else {
        return Ok(Value::Null);
    };
    let mut names_ru = Vec::new();
    if let Ok(mut st) = conn.prepare(
        "SELECT DISTINCT name FROM entity_names WHERE entity_id=?1 AND lang IN ('ru', 'rus') LIMIT 10",
    ) && let Ok(rows) = st.query_map([&id], |r| r.get::<_, String>(0))
    {
        for n in rows.flatten() {
            names_ru.push(n);
        }
    }
    let mut rels = Vec::new();
    if let Ok(mut st) = conn.prepare(
        "SELECT r.relation_type, r.to_entity_id, e.name
         FROM relationships r JOIN entities e ON e.id = r.to_entity_id
         WHERE r.from_entity_id=?1 LIMIT 25",
    ) && let Ok(rows) = st.query_map([&id], |r| {
        Ok((
            r.get::<_, String>(0).unwrap_or_default(),
            r.get::<_, String>(1).unwrap_or_default(),
            r.get::<_, String>(2).unwrap_or_default(),
        ))
    }) {
        for (rt, tid, tname) in rows.flatten() {
            rels.push(json!({"type": rt, "id": tid, "name": tname}));
        }
    }
    let meta_val: Value = serde_json::from_str(&meta_str).unwrap_or(Value::Null);
    Ok(json!({
        "id": id,
        "type": typ,
        "subtype": sub,
        "name": name,
        "name_original": name_orig,
        "strongs": strongs,
        "short_description": desc,
        "article": article,
        "names_ru": names_ru,
        "relations": rels,
        "meta": meta_val,
    }))
}

fn query_dict_glosses(
    base_path: &Path,
    book_and_opts: &str,
    chapter: i64,
) -> Result<Option<String>> {
    let mut parts = book_and_opts.split('|');
    let book = parts.next().unwrap_or("").trim();
    let mut lang = String::new();
    for p in parts {
        if let Some(v) = p.strip_prefix("lang=") {
            lang = v.trim().to_string();
        }
    }
    let m = open_cached(base_path)?;
    let m = lock_module(&m)?;
    let code = BookCode::new(book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let number = u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?;
    let Some(ch) = m.chapter(code, number)? else {
        return Ok(None);
    };
    let mut strongs = std::collections::HashSet::new();
    let mut morphs = std::collections::HashSet::new();
    for b in &ch.blocks {
        for s in &b.spans {
            if let Span::Text { attrs, .. } = s {
                if let Some(st) = extract_attr(attrs, "strong") {
                    for p in st.split_whitespace() {
                        strongs.insert(p.to_string());
                    }
                }
                if let Some(mc) = extract_attr(attrs, "morph") {
                    for p in mc.split_whitespace() {
                        morphs.insert(p.to_string());
                    }
                }
            }
        }
    }
    let Some(lex_p) = find_lex_module(base_path, &lang) else {
        return Ok(None);
    };
    let lm = open_cached(&lex_p)?;
    let lm = lock_module(&lm)?;
    let conn = lm.conn();
    let mut gmap = Map::new();
    for k in strongs {
        if let Ok((gloss, pos)) =
            conn.query_row("SELECT gloss, pos FROM lex WHERE key=?1", [&k], |r| {
                Ok((
                    r.get::<_, String>(0).unwrap_or_default(),
                    r.get::<_, String>(1).unwrap_or_default(),
                ))
            })
        {
            gmap.insert(k, json!({"g": gloss, "p": pos}));
        }
    }
    let mut mmap = Map::new();
    for mc in morphs {
        if let Ok(sh) = conn.query_row("SELECT short FROM morph WHERE code=?1", [&mc], |r| {
            r.get::<_, String>(0)
        }) {
            mmap.insert(mc, Value::String(sh));
        }
    }
    Ok(Some(json!({"glosses": gmap, "morphs": mmap}).to_string()))
}

/// Вставить `x`-спан в конец стиха `v`: перед первым маркером
/// следующего стиха внутри блока либо в конец этого блока.
fn inject_verse_note(ch: &mut studybible_core::text::Chapter, v: u16, text: &str) {
    for b in &mut ch.blocks {
        let mut seen = false;
        let mut at = None;
        for (i, s) in b.spans.iter().enumerate() {
            if let Span::Verse(n) = s {
                if seen && *n != v {
                    at = Some(i);
                    break;
                }
                if *n == v {
                    seen = true;
                }
            }
        }
        if seen {
            let i = at.unwrap_or(b.spans.len());
            b.spans.insert(
                i,
                Span::Note {
                    kind: 'x',
                    caller: "+".into(),
                    text: text.into(),
                    attrs: "src=\"layer\"".into(),
                },
            );
            return;
        }
    }
}

// --- сериализация потока чтения (зеркало export.rs) ---

fn span_json(s: &Span) -> Value {
    match s {
        Span::Verse(n) => json!({"v": n}),
        Span::Text { text, style, attrs } => {
            json!({"t": text, "s": style, "a": attrs})
        }
        Span::Note {
            kind,
            caller,
            text,
            attrs,
        } => {
            json!({"n": kind.to_string(), "c": caller, "t": text, "a": attrs})
        }
    }
}

fn block_json(b: &Block) -> Value {
    let kind = match b.kind() {
        BlockKind::Paragraph => "p",
        BlockKind::Poetry => "q",
        BlockKind::Heading => "h",
        BlockKind::Superscription => "d",
        BlockKind::Blank => "b",
    };
    json!({
        "k": kind,
        "m": b.marker,
        "s": b.spans.iter().map(span_json).collect::<Vec<_>>(),
    })
}

fn span_info(s: &Span) -> SpanDocInfo {
    match s {
        Span::Verse(n) => SpanDocInfo {
            kind: "v".into(),
            verse: i64::from(*n),
            text: String::new(),
            style: String::new(),
            attrs: String::new(),
            caller: String::new(),
        },
        Span::Text { text, style, attrs } => SpanDocInfo {
            kind: "t".into(),
            verse: 0,
            text: text.clone(),
            style: style.clone(),
            attrs: attrs.clone(),
            caller: String::new(),
        },
        Span::Note {
            kind,
            caller,
            text,
            attrs,
        } => SpanDocInfo {
            kind: kind.to_string(),
            verse: 0,
            text: text.clone(),
            style: String::new(),
            attrs: attrs.clone(),
            caller: caller.clone(),
        },
    }
}

fn block_info(b: &Block) -> BlockDocInfo {
    let kind = match b.kind() {
        BlockKind::Paragraph => "p",
        BlockKind::Poetry => "q",
        BlockKind::Heading => "h",
        BlockKind::Superscription => "d",
        BlockKind::Blank => "b",
    };
    BlockDocInfo {
        kind: kind.into(),
        marker: b.marker.clone(),
        spans: b.spans.iter().map(span_info).collect(),
    }
}

// --- словарь (таблица entries, ADR 0016) ---

/// Заголовок словарной статьи для списка.
pub struct DictEntry {
    /// Порядок в словаре — ключ для `dict_entry`.
    pub ord: i64,
    pub headword: String,
}

/// Полная статья словаря.
pub struct DictArticle {
    pub ord: i64,
    pub headword: String,
    pub text: String,
}

/// Страница заголовков словаря (ord, headword) от `offset`,
/// фильтр по префиксу строчной формы `norm`.
pub async fn dict_entries(
    path: String,
    offset: i64,
    limit: i64,
    prefix: String,
) -> Result<Vec<DictEntry>> {
    let m = open_cached(Path::new(&path))?;
    let m = lock_module(&m)?;
    let list = m.entries(
        u64::try_from(offset).unwrap_or(0),
        u64::try_from(limit).unwrap_or(100),
        &prefix,
    )?;
    Ok(list
        .iter()
        .map(|(ord, headword)| DictEntry {
            ord: i64::from(*ord),
            headword: headword.clone(),
        })
        .collect())
}

/// Статья словаря по `ord`; `None` — нет такой.
pub async fn dict_entry(path: String, ord: i64) -> Result<Option<DictArticle>> {
    let m = open_cached(Path::new(&path))?;
    let m = lock_module(&m)?;
    let ord_u32 = u32::try_from(ord).map_err(|_| anyhow!("ord {ord}"))?;
    Ok(m.entry(ord_u32)?.map(|(headword, text)| DictArticle {
        ord,
        headword,
        text,
    }))
}

// --- версификации (сравнение переводов, ADR 0015/вопрос 8) ---

/// Координата стиха — результат конверсии между версификациями.
/// Книга возвращается тоже: часть отображений `.vrs` меняет её
/// (Даниил-греческий DAG↔DAN/SUS/BEL и т. п.).
pub struct CvPoint {
    pub book: String,
    pub chapter: i64,
    pub verse: i64,
}

/// Перевести стих между версификациями Paratext через org:
/// `from_vrs`/`to_vrs` — имена файлов (`rsc`, `eng`, `vul`, …).
/// Одинаковые версификации — короткий путь без разбора.
/// Пусто — стиху нет соответствия в целевой версификации.
pub async fn convert_verse(
    book: String,
    chapter: i64,
    verse: i64,
    from_vrs: String,
    to_vrs: String,
) -> Result<Vec<CvPoint>> {
    if from_vrs == to_vrs {
        return Ok(vec![CvPoint {
            book,
            chapter,
            verse,
        }]);
    }
    let code = BookCode::new(&book).ok_or_else(|| anyhow!("код книги {book}"))?;
    let from =
        Versification::builtin(&from_vrs).ok_or_else(|| anyhow!("версификация {from_vrs}"))?;
    let to = Versification::builtin(&to_vrs).ok_or_else(|| anyhow!("версификация {to_vrs}"))?;
    let k = VerseKey::new(
        code,
        u16::try_from(chapter).map_err(|_| anyhow!("глава {chapter}"))?,
        u16::try_from(verse).map_err(|_| anyhow!("стих {verse}"))?,
    );
    Ok(from
        .convert(to, k)
        .iter()
        .map(|p| CvPoint {
            book: p.book.as_str().to_string(),
            chapter: i64::from(p.chapter),
            verse: i64::from(p.verse),
        })
        .collect())
}

// --- поиск по FTS-индексу модуля ---

/// Результат поиска для UI (зеркало `store::search::Hit`).
pub struct SearchHitInfo {
    pub book: String,
    pub chapter: i64,
    pub verse: i64,
    /// Фрагмент текста с разметкой выделения совпадения.
    pub snippet: String,
}

/// Искать в модуле. `cache_path` — файл индекса рядом с модулем
/// (по соглашению CLI — `<module>.idx`); при несовпадении ключа
/// индекс перестраивается автоматически.
pub async fn module_search(
    module_path: String,
    cache_path: String,
    query: String,
    limit: i64,
) -> Result<Vec<SearchHitInfo>> {
    let m = open_cached(Path::new(&module_path))?;
    let m = lock_module(&m)?;
    let idx = studybible_store::SearchIndex::open(Path::new(&cache_path), &m)?;
    let hits = idx.search(&query, usize::try_from(limit).unwrap_or(usize::MAX))?;
    Ok(hits
        .iter()
        .map(|h| SearchHitInfo {
            book: h.book.to_string(),
            chapter: h.chapter.into(),
            verse: h.verse.into(),
            snippet: h.snippet.clone(),
        })
        .collect())
}

/// Искать по сноскам и параллельным местам модуля — те же
/// операторы запроса, что и `module_search` (фраза «…», `w*`, `?`).
/// Если у модуля нет собственных `x`-спанов и включён общий слой
/// `openbible-xrefs` (ADR 0023), поиск захватывает и ссылки слоя.
pub async fn module_notes_search(
    module_path: String,
    cache_path: String,
    query: String,
    limit: i64,
) -> Result<Vec<SearchHitInfo>> {
    let m = open_cached(Path::new(&module_path))?;
    let m = lock_module(&m)?;
    let idx = studybible_store::SearchIndex::open(Path::new(&cache_path), &m)?;
    let lim = usize::try_from(limit).unwrap_or(usize::MAX);
    let hits = if !m.has_xrefs()
        && let Some(lp) = xref_layer_path()
        && let Ok(layer_arc) = open_cached(&lp)
        && let Ok(layer) = lock_module(&layer_arc)
    {
        idx.search_notes_with_layer(&query, lim, Some(&layer), &m.meta().versification)?
    } else {
        idx.search_notes(&query, lim)?
    };
    Ok(hits
        .iter()
        .map(|h| SearchHitInfo {
            book: h.book.to_string(),
            chapter: h.chapter.into(),
            verse: h.verse.into(),
            snippet: h.snippet.clone(),
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use studybible_core::book::{BookCatalog, BookOrder, NameProfile};
    use studybible_store::{Meta, ModuleWriter};

    /// Слой ADR 0023: GEN 1:1, 1:2 (координаты eng).
    fn layer(dir: &Path) -> PathBuf {
        let p = dir.join("layer.sb");
        let mut w = ModuleWriter::create(
            &p,
            &Meta {
                id: "openbible-xrefs".into(),
                versification: "eng".into(),
                kind: "layer".into(),
                ..Meta::default()
            },
        )
        .unwrap();
        for b in BookCatalog::builtin().ordered(BookOrder::List) {
            w.add_book(
                b.code,
                b.order(BookOrder::List).unwrap(),
                b.name(NameProfile::English),
                &Default::default(),
            )
            .unwrap();
        }
        let gen_ = BookCode::new("GEN").unwrap();
        w.add_xref(gen_, 1, 1, 0, "Ps 33:6; John 1:1").unwrap();
        w.add_xref(gen_, 1, 2, 1, "2Cor 4:6").unwrap();
        let psa = BookCode::new("PSA").unwrap();
        let jhn = BookCode::new("JHN").unwrap();
        w.add_xref_targets(
            gen_,
            1,
            1,
            &[
                (VerseKey::new(psa, 33, 6), VerseKey::new(psa, 33, 6), 100),
                (VerseKey::new(jhn, 1, 1), VerseKey::new(jhn, 1, 3), 90),
            ],
        )
        .unwrap();
        w.finish().unwrap();
        p
    }

    fn chapter(src: &str) -> studybible_core::text::Chapter {
        studybible_convert::usfm::parse(src).unwrap().chapters[0].clone()
    }

    #[test]
    fn layer_notes_land_at_verse_ends() {
        let dir = tempfile::tempdir().unwrap();
        let layer = Module::open(&layer(dir.path())).unwrap();
        let mut ch = chapter("\\id GEN\n\\c 1\n\\p\n\\v 1 Первый.\n\\v 2 Второй.\n\\v 3 Третий.\n");
        inject_layer_xrefs(&mut ch, &layer, BookCode::new("GEN").unwrap(), 1, "rsc").unwrap();
        let spans = &ch.blocks[0].spans;
        // x-спан стиха 1 — перед маркером стиха 2, стиха 2 — перед 3.
        let v2 = spans
            .iter()
            .position(|s| matches!(s, Span::Verse(2)))
            .unwrap();
        assert!(matches!(spans[v2 - 1], Span::Note { kind: 'x', .. }));
        if let Span::Note { text, attrs, .. } = &spans[v2 - 1] {
            assert_eq!(text, "Ps 33:6; John 1:1");
            assert_eq!(attrs, "src=\"layer\"");
        }
        let v3 = spans
            .iter()
            .position(|s| matches!(s, Span::Verse(3)))
            .unwrap();
        assert!(matches!(spans[v3 - 1], Span::Note { kind: 'x', .. }));
        // Стих 3 без ссылки — ничего не добавлено.
        assert!(!matches!(spans.last(), Some(Span::Note { .. })));
    }

    #[test]
    fn layer_xref_targets_structured() {
        let dir = tempfile::tempdir().unwrap();
        let layer = Module::open(&layer(dir.path())).unwrap();
        assert!(layer.has_xref_targets());
        let t = layer
            .xref_targets(BookCode::new("GEN").unwrap(), 1)
            .unwrap();
        assert_eq!(t.len(), 2);
        assert_eq!(t[0].verse, 1);
        assert_eq!(t[0].to.book.as_str(), "PSA");
        assert_eq!((t[0].to.chapter, t[0].to.verse), (33, 6));
        assert!(t[0].end.is_none());
        assert_eq!(t[0].votes, 100);
        assert_eq!(t[1].to.book.as_str(), "JHN");
        assert_eq!(t[1].end.unwrap().verse, 3);
        // Стих без целей — пусто.
        assert!(
            layer
                .xref_targets(BookCode::new("GEN").unwrap(), 2)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn layer_miss_leaves_chapter_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let layer = Module::open(&layer(dir.path())).unwrap();
        // Глава без ссылок в слое.
        let mut ch = chapter("\\id GEN\n\\c 2\n\\p\n\\v 1 Раз.\n");
        inject_layer_xrefs(&mut ch, &layer, BookCode::new("GEN").unwrap(), 2, "rsc").unwrap();
        assert_eq!(ch.blocks[0].spans.len(), 2); // Verse + Text
    }

    #[test]
    fn layer_skips_verses_absent_in_module() {
        let dir = tempfile::tempdir().unwrap();
        let layer = Module::open(&layer(dir.path())).unwrap();
        // Ссылки на стихи, которых в этой главе нет, не вставляются.
        let mut ch = chapter("\\id GEN\n\\c 1\n\\p\n\\v 3 Только третий.\n");
        inject_layer_xrefs(&mut ch, &layer, BookCode::new("GEN").unwrap(), 1, "rsc").unwrap();
        assert_eq!(ch.blocks[0].spans.len(), 2);
    }
}
