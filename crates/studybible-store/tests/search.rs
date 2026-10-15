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
fn operators_phrase_prefix_glob() {
    let dir = tempfile::tempdir().unwrap();
    let (_, m) = module(&dir, "a.sb", SRC);
    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();

    // Фраза — порядок слов важен.
    let hits = idx.search("\"начале сотворил\"", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 1);
    assert!(idx.search("\"сотворил начале\"", 10).unwrap().is_empty());
    // Незакрытая кавычка — всё до конца как фраза.
    assert_eq!(idx.search("\"да будет", 10).unwrap().len(), 1);

    // Префикс `w*`: «свет*» — «свет» в 1:3 (дважды — один стих).
    let hits = idx.search("свет*", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert!(hits.iter().all(|h| h.chapter == 1 && h.verse == 3));
    // Префикс + слово — AND.
    let hits = idx.search("св* стал", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 3);

    // `?` — односимвольный wildcard: «све?» → «свет», «земл?» → «земля»/«землю».
    let hits = idx.search("све?", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 3);
    assert!(hits[0].snippet.contains("[свет]"));
    let hits = idx.search("земл?", 10).unwrap();
    assert_eq!(hits.len(), 3); // «землю» (1:1), «земля» (2:1)… и «земля» в 1:2
    // Внутренняя `*` — тоже glob: «н*е» → «небо»/«небо.».
    let hits = idx.search("н*е", 10).unwrap();
    assert!(hits.iter().any(|h| h.verse == 1));
    // Glob AND слово.
    let hits = idx.search("земл? совершены", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].chapter, 2);
    // Glob без совпадений.
    assert!(idx.search("кот?", 10).unwrap().is_empty());
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

#[test]
fn search_notes_includes_external_layer() {
    let dir = tempfile::tempdir().unwrap();
    let (_, m) = module(&dir, "a.sb", SRC);
    let layer_path = dir.path().join("layer.sb");
    let gen_ = studybible_core::BookCode::new("GEN").unwrap();
    let mut w = ModuleWriter::create(
        &layer_path,
        &Meta {
            id: "openbible-xrefs".into(),
            versification: "eng".into(),
            kind: "layer".into(),
            ..Meta::default()
        },
    )
    .unwrap();
    w.add_book(gen_, 1, "Genesis", &Default::default()).unwrap();
    w.add_xref(gen_, 1, 3, 0, "2Cor 4:6").unwrap();
    w.finish().unwrap();
    let layer = Module::open(&layer_path).unwrap();

    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();
    assert!(idx.search_notes("2cor", 10).unwrap().is_empty());
    let hits = idx
        .search_notes_with_layer("2cor", 10, Some(&layer), "rsc")
        .unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].chapter, 1);
    assert_eq!(hits[0].verse, 3);
}

/// Обратный поиск Стронга: собственная разметка модуля
/// (`strong=` в спанах → `token_pack`) и слой `links` с пометкой
/// слова `w1` в сниппете.
#[test]
fn search_strong_native_and_layer() {
    let dir = tempfile::tempdir().unwrap();
    let src = "\\id GEN\n\\mt1 Бытие\n\\c 1\n\\p\n\
               \\v 1 \\w В|strong=\"H9003\"\\w* \\w начале|strong=\"H7225\"\\w* сотворил Бог небо и землю.\n\
               \\v 2 \\w Земля|strong=\"H0776\"\\w* же была безвидна.\n";
    let (_, m) = module(&dir, "a.sb", src);
    let idx = SearchIndex::open(&dir.path().join("a.idx"), &m).unwrap();

    // Нативная разметка: H7225 → стих 1; добивка нулями и регистр
    // не влияют на сравнение.
    for q in ["H7225", "h7225", "H07225"] {
        let hits = idx.search_strong(q, 10, None, &m).unwrap();
        assert_eq!(hits.len(), 1, "запрос {q}");
        assert_eq!(hits[0].chapter, 1);
        assert_eq!(hits[0].verse, 1);
    }
    let hits = idx.search_strong("H776", 10, None, &m).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 2);
    // Чужого номера и не-номера нет; ошибки нет.
    assert!(idx.search_strong("G3056", 10, None, &m).unwrap().is_empty());
    assert!(idx.search_strong("X1", 10, None, &m).unwrap().is_empty());
    // Слова Стронга в сниппете без слоя не помечаются.
    assert!(
        !idx.search_strong("H7225", 10, None, &m).unwrap()[0]
            .snippet
            .contains('[')
    );

    // Слой `links` (ADR 0025): совпавшие слова помечаются [ ] по w1.
    let gen_ = studybible_core::BookCode::new("GEN").unwrap();
    let lp = dir.path().join("lay.sb");
    let mut w = ModuleWriter::create(
        &lp,
        &Meta {
            id: "a-strongs".into(),
            kind: "layer".into(),
            ..Meta::default()
        },
    )
    .unwrap();
    w.add_book(gen_, 1, "Genesis", &Default::default()).unwrap();
    w.add_link(
        gen_,
        1,
        &studybible_store::Link {
            verse: 1,
            word: 2,
            strong: "H1254".into(),
            ..Default::default()
        },
    )
    .unwrap();
    w.add_link(
        gen_,
        1,
        &studybible_store::Link {
            verse: 2,
            word: 0,
            strong: "H0776".into(),
            ..Default::default()
        },
    )
    .unwrap();
    w.finish().unwrap();
    let layer = Module::open(&lp).unwrap();

    // Валидный слой замещает собственную разметку: H7225 модуля
    // через слой не находится, а H1254 — только из слоя.
    assert!(
        idx.search_strong("H7225", 10, Some(&layer), &m)
            .unwrap()
            .is_empty()
    );
    let hits = idx.search_strong("H1254", 10, Some(&layer), &m).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 1);
    assert!(
        hits[0].snippet.contains("[сотворил]"),
        "{}",
        hits[0].snippet
    );
    let hits = idx.search_strong("H0776", 10, Some(&layer), &m).unwrap();
    assert_eq!(hits[0].snippet, "[земля] же была безвидна");
    // Суффиксный запрос без точного совпадения — фолбэк на базовый
    // номер (слой хранит `H0776`, `H0776B` находит его же).
    let hits = idx.search_strong("H0776B", 10, Some(&layer), &m).unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].verse, 2);
}
