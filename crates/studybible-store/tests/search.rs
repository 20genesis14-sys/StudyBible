//! Кэш-индекс FTS5: нормализация, пересечение слов, перестройка по хэшу.

use studybible_convert::usfm;
use studybible_store::{Meta, Module, ModuleWriter, SearchIndex};

const SRC: &str = "\\id GEN\n\\mt1 Бытие\n\
\\c 1\n\\p\n\
\\v 1 В начале сотворил Бог небо и землю.\n\
\\v 2 Земля же была безвидна и пуста.\n\
\\v 3 И сказал Бог: да будет свет. И стал свет.\n\
\\c 2\n\\v 1 Так совершены небо и земля.\n";

fn meta() -> Meta {
    Meta {
        id: "test".into(),
        language: "ru".into(),
        versification: "rsc".into(),
        ..Meta::default()
    }
}

fn module(dir: &tempfile::TempDir, name: &str, src: &str) -> (std::path::PathBuf, Module) {
    let path = dir.path().join(name);
    let b = usfm::parse(src).unwrap();
    let mut w = ModuleWriter::create(&path, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
    let m = Module::open(&path).unwrap();
    (path, m)
}

#[test]
fn basic_and_normalization() {
    let dir = tempfile::tempdir().unwrap();
    let (_, m) = module(&dir, "a.sb", SRC);
    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();

    // Регистр безразличен.
    let hits = idx.search("СВЕТ", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 3);
    assert!(hits[0].snippet.contains('['), "сниппет метит совпадение");

    // Два слова — пересечение.
    let hits = idx.search("небо землю", 10).unwrap();
    assert_eq!(hits.len(), 1); // только 1:1 — «небо и землю»; 2:1 имеет «земля» без «небо»
    assert_eq!(hits[0].chapter, 1);
    assert_eq!(hits[0].verse, 1);

    // Слова из разных стихов не сходятся в один ответ.
    let hits = idx.search("начале совершены", 10).unwrap();
    assert!(hits.is_empty());

    // Ничего не найдено.
    assert!(idx.search("мамба", 10).unwrap().is_empty());
    // Пустой запрос — пустой результат, не ошибка.
    assert!(idx.search("", 10).unwrap().is_empty());
    assert!(idx.search("   ", 10).unwrap().is_empty());
}

#[test]
fn limit_respected() {
    let dir = tempfile::tempdir().unwrap();
    let (_, m) = module(&dir, "a.sb", SRC);
    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();
    // «и» встречается в нескольких стихах.
    let all = idx.search("и", 100).unwrap();
    assert!(all.len() >= 3);
    let few = idx.search("и", 1).unwrap();
    assert_eq!(few.len(), 1);
}

#[test]
fn index_rebuilds_on_content_change() {
    let dir = tempfile::tempdir().unwrap();
    let idx_path = dir.path().join("m.idx");

    let (_, m1) = module(&dir, "m1.sb", SRC);
    {
        let idx = SearchIndex::open(&idx_path, &m1).unwrap();
        assert_eq!(idx.search("свет", 10).unwrap().len(), 1);
        assert!(idx.search("тьма", 10).unwrap().is_empty());
    }

    // Модуль с тем же id, но другим содержимым — другой хэш → перестройка.
    let (_, m2) = module(&dir, "m2.sb", &SRC.replace("свет", "тьма"));
    let idx = SearchIndex::open(&idx_path, &m2).unwrap();
    assert!(
        idx.search("свет", 10).unwrap().is_empty(),
        "старый индекс не очищен"
    );
    assert_eq!(idx.search("тьма", 10).unwrap().len(), 1);
}

#[test]
fn index_reused_when_same() {
    let dir = tempfile::tempdir().unwrap();
    let idx_path = dir.path().join("m.idx");
    let (_, m) = module(&dir, "m.sb", SRC);
    SearchIndex::open(&idx_path, &m).unwrap();
    let t1 = std::fs::metadata(&idx_path).unwrap().modified().unwrap();
    std::thread::sleep(std::time::Duration::from_millis(50));
    SearchIndex::open(&idx_path, &m).unwrap();
    let t2 = std::fs::metadata(&idx_path).unwrap().modified().unwrap();
    assert_eq!(
        t1, t2,
        "индекс не должен перестраиваться для того же модуля"
    );
}

/// Модуль со встроенной `fts` (ADR 0016 п. 11): поиск идёт по ней,
/// кэш-файл `.idx` вообще не создаётся.
#[test]
fn embedded_fts() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("emb.sb");
    let b = usfm::parse(SRC).unwrap();
    let mut w = ModuleWriter::create(&path, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.build_search_index().unwrap();
    w.finish().unwrap();

    let m = Module::open(&path).unwrap();
    assert!(m.has_search_index());
    let cache = dir.path().join("emb.idx");
    let idx = SearchIndex::open(&cache, &m).unwrap();
    let hits = idx.search("свет", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 3);
    assert!(!cache.exists(), "для модуля с fts кэш-индекс не создаётся");
}

/// Вопрос № 14: греческая конечная сигма и ивритские конечные формы
/// находятся запросом обычными буквами.
#[test]
fn final_forms_search() {
    let src = "\\id JHN\n\\mt1 Ин\n\\c 1\n\\p\n\
               \\v 1 ἐν ἀρχῇ ἦν ὁ λόγος\n\
               \\v 2 מֶלֶךְ שָׁלוֹם כָּל־הָאָרֶץ\n";
    let dir = tempfile::tempdir().unwrap();
    let (_, m) = module(&dir, "a.sb", src);
    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();
    // «λογοσ»/«λογος»/«ΛΟΓΟΣ» — один и тот же запрос.
    for q in ["λογοσ", "λογος", "ΛΟΓΟΣ"] {
        let hits = idx.search(q, 10).unwrap();
        assert_eq!(hits.len(), 1, "запрос {q}");
        assert_eq!(hits[0].verse, 1);
    }
    // Конечная буква ך в тексте, в запросе — обычная כ.
    let hits = idx.search("מלך", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 2);
    // Маккеф делит слова: «כל הארצ» = два слова, AND в одном стихе.
    let hits = idx.search("כל הארצ", 10).unwrap();
    assert_eq!(hits.len(), 1);
}

/// Старый кэш с ключом другой версии нормализации перестраивается.
#[test]
fn cache_rebuilds_on_norm_version_change() {
    let dir = tempfile::tempdir().unwrap();
    let idx_path = dir.path().join("m.idx");
    let (_, m) = module(&dir, "m.sb", SRC);
    SearchIndex::open(&idx_path, &m).unwrap();
    // Подменяем версию в ключе кэша на старую («:1»).
    {
        let conn = rusqlite::Connection::open(&idx_path).unwrap();
        conn.execute(
            "UPDATE meta SET value = replace(value, ':2', ':1') WHERE key='module'",
            [],
        )
        .unwrap();
    }
    SearchIndex::open(&idx_path, &m).unwrap();
    let conn = rusqlite::Connection::open(&idx_path).unwrap();
    let key: String = conn
        .query_row("SELECT value FROM meta WHERE key='module'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(key.ends_with(":2"), "кэш не перестроен: {key}");
}

/// Модуль со встроенной `fts` старой версии нормализации — читатель
/// игнорирует её и строит кэш `.idx`.
#[test]
fn embedded_fts_old_version_falls_back() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("emb.sb");
    let b = usfm::parse(SRC).unwrap();
    let mut w = ModuleWriter::create(&path, &meta()).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.build_search_index().unwrap();
    w.finish().unwrap();
    // Откатываем маркер на старую версию — как у модулей, собранных
    // до расширения нормализации (ключа вообще не было).
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute("UPDATE meta SET value='1' WHERE key='norm_version'", [])
            .unwrap();
    }
    let m = Module::open(&path).unwrap();
    assert!(m.has_search_index());
    let cache = dir.path().join("emb.idx");
    let idx = SearchIndex::open(&cache, &m).unwrap();
    assert_eq!(idx.search("свет", 10).unwrap().len(), 1);
    assert!(cache.exists(), "старый fts должен откатываться на кэш");
}

#[test]
fn query_quoting() {
    let dir = tempfile::tempdir().unwrap();
    let (_, m) = module(&dir, "a.sb", SRC);
    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();
    // Спецсимволы запроса не ломают FTS5.
    assert!(idx.search("\"", 10).unwrap().is_empty());
    assert!(idx.search("AND OR NOT", 10).is_ok());
    assert!(idx.search("(небо)", 10).is_ok());
    assert!(idx.search("небо*", 10).is_ok());
}
