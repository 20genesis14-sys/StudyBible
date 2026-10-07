//! Сборка словарного модуля (format="entries", ADR 0016):
//! TSV-источник → .sb с таблицей entries и meta kind=dictionary.

use std::process::Command;

use studybible_store::Module;

#[test]
fn build_dictionary_module() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let src = data.join("sources").join("mydict");
    std::fs::create_dir_all(&src).unwrap();
    std::fs::write(
        src.join("dict.tsv"),
        "# пробный словарь\nАвраам\tОтец множества.\tавраам\nАгарь\tСлужанка Сары.\n",
    )
    .unwrap();
    let defs = dir.path().join("defs.json");
    std::fs::write(
        &defs,
        r#"{"modules":[{
            "id":"mydict","source":"mydict","title":"Пробный словарь",
            "language":"ru","direction":"ltr","versification":"eng",
            "name_profile":"syn","format":"entries","sbz":false}]}"#,
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

    let m = Module::open(&out.join("mydict.sb")).unwrap();
    assert_eq!(m.meta().kind, "dictionary");
    assert!(m.meta().features.contains(&"entries".to_string()));
    assert_eq!(m.entries_count().unwrap(), 2);
    let list = m.entries(0, 10, "ав").unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].1, "Авраам");
    let (h, t) = m.entry(2).unwrap().unwrap();
    assert_eq!(h, "Агарь");
    assert!(t.contains("Сары"));
    // Старый модуль без entries открывается: entries — пусто, не ошибка.
    let plain = dir.path().join("plain.sb");
    {
        let meta = studybible_store::Meta {
            id: "plain".into(),
            title: "t".into(),
            language: "ru".into(),
            ..Default::default()
        };
        studybible_store::ModuleWriter::create(&plain, &meta)
            .unwrap()
            .finish()
            .unwrap();
    }
    let m = Module::open(&plain).unwrap();
    assert_eq!(m.entries_count().unwrap(), 0);
    assert!(m.entries(0, 10, "").unwrap().is_empty());
    assert!(m.entry(1).unwrap().is_none());
}
