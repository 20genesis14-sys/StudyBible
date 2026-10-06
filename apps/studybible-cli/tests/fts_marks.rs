//! Сборка модуля с опциями ADR 0016 п. 11–12: `"fts": true` даёт
//! встроенный индекс FTS5 внутри .sb (поиск без .idx), `"marks"` —
//! TSV меток времени.

use std::process::Command;

use studybible_core::BookCode;
use studybible_store::{Module, SearchIndex};

#[test]
fn build_module_with_fts_and_marks() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let src = data.join("sources").join("mini");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(
        src.join("01gen.usfm"),
        "\\id GEN\n\\h Бытие\n\\c 1\n\\p\n\
         \\v 1 В начале сотворил Бог небо и землю.\n\
         \\v 2 Земля же была безвидна и пуста.\n",
    )
    .unwrap();
    std::fs::write(
        src.join("audio.tsv"),
        "GEN 1:1\t0\t1200\tВ\nGEN 1:1\t1200\t\tначале\nGEN 1:2\t5400\t900\tЗемля\n",
    )
    .unwrap();
    let defs = dir.path().join("defs.json");
    std::fs::write(
        &defs,
        r#"{"modules":[{
            "id":"mini","source":"mini","title":"Пробный",
            "language":"ru","direction":"ltr","versification":"rsc",
            "name_profile":"syn","format":"usfm",
            "fts":true,"marks":"audio.tsv"}]}"#,
    )
    .unwrap();
    let out = dir.path().join("out");
    let status = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args([
            "module",
            "build",
            "--defs",
            defs.to_str().unwrap(),
            "--data",
            data.to_str().unwrap(),
            "--out",
            out.to_str().unwrap(),
        ])
        .status()
        .unwrap();
    assert!(status.success());

    let path = out.join("mini.sb");
    let m = Module::open(&path).unwrap();
    assert!(m.meta().features.contains(&"fts".to_string()));
    assert!(m.meta().features.contains(&"marks".to_string()));
    assert!(m.has_search_index());

    // Поиск по встроенному индексу — .idx не создаётся.
    let cache = dir.path().join("mini.idx");
    let idx = SearchIndex::open(&cache, &m).unwrap();
    let hits = idx.search("сотворил", 10).unwrap();
    assert_eq!(hits.len(), 1);
    assert!(!cache.exists());

    // Метки прочитались.
    let marks = m.marks(BookCode::new("GEN").unwrap(), 1).unwrap();
    assert_eq!(marks.len(), 3);
    assert_eq!(marks[1].text, "начале");
    assert_eq!(marks[1].dur_ms, None);
}
