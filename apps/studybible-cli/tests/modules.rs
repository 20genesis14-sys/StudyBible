//! Сборка модулей из настоящих источников и проверка результата.
//! Пропускается с пометкой SKIPPED, если каталога данных нет.

use std::path::{Path, PathBuf};
use std::process::Command;

use studybible_core::BookCode;
use studybible_core::text::Span;
use studybible_store::Module;

fn data_root() -> Option<PathBuf> {
    let root = std::env::var("STUDYBIBLE_DATA")
        .map(PathBuf::from)
        .unwrap_or_else(|_| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../StudyBible-data"));
    root.join("sources/russyn").is_dir().then_some(root)
}

fn build_all(data: &Path, out: &Path) {
    let defs = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data/modules.json");
    let status = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args([
            "module",
            "build",
            "--defs",
            defs.to_str().expect("путь"),
            "--data",
            data.to_str().expect("путь"),
            "--out",
            out.to_str().expect("путь"),
        ])
        .status()
        .expect("запуск studybible");
    assert!(status.success(), "module build завершился с ошибкой");
}

fn verse(m: &Module, book: &str, ch: u16, v: u16) -> Option<String> {
    m.verse_text(BookCode::new(book).unwrap(), ch, v).unwrap()
}

fn verses_count(m: &Module) -> i64 {
    m.conn()
        .query_row("SELECT count(*) FROM verses", [], |r| r.get(0))
        .unwrap()
}

/// Маркеры стихов внутри блоков-заголовков теряются из текста стихов — их быть не должно.
fn orphan_verses(m: &Module) -> i64 {
    m.conn()
        .query_row(
            "SELECT count(*) FROM spans s \
             JOIN blocks b ON b.book=s.book AND b.chapter=s.chapter AND b.seq=s.block \
             WHERE s.kind='v' AND b.marker IN \
             ('s','s1','s2','s3','ms','ms1','ms2','mr','r','sr','sp','cl','qa','sd',\
              'is','is1','is2','iis','imt','imt1','imte','mt','mt1','mt2','mt3','ih')",
            [],
            |r| r.get(0),
        )
        .unwrap()
}

#[test]
fn build_three_modules() {
    let Some(data) = data_root() else {
        eprintln!("SKIPPED: нет каталога данных");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    build_all(&data, dir.path());

    // Синодальный.
    let syn = Module::open(&dir.path().join("russyn.sb")).unwrap();
    assert_eq!(syn.meta().language, "ru");
    assert_eq!(syn.meta().versification, "rsc");
    assert_eq!(syn.books().unwrap().len(), 66);
    assert_eq!(
        verse(&syn, "GEN", 1, 1).as_deref(),
        Some("В начале сотворил Бог небо и землю.")
    );
    // «Иегова» во всех трёх ожидаемых местах.
    let iehova = ["GEN;22;14", "EXO;17;15", "JDG;6;24"]
        .iter()
        .filter(|s| {
            let (b, cv) = s.split_once(';').unwrap();
            let (c, v) = cv.split_once(';').unwrap();
            verse(&syn, b, c.parse().unwrap(), v.parse().unwrap())
                .is_some_and(|t| t.contains("Иегова"))
        })
        .count();
    assert_eq!(iehova, 3, "«Иегова» во всех трёх местах");
    assert!(verses_count(&syn) > 31_000);
    assert_eq!(orphan_verses(&syn), 0);

    // WEB: 66 книг + FRT + GLO.
    let web = Module::open(&dir.path().join("engwebp.sb")).unwrap();
    assert_eq!(web.meta().language, "en");
    assert_eq!(web.books().unwrap().len(), 68);
    assert_eq!(
        verse(&web, "GEN", 1, 1).as_deref(),
        Some("In the beginning, God created the heavens and the earth.")
    );
    assert_eq!(orphan_verses(&web), 0);

    // KJV со Стронгом.
    let kjv = Module::open(&dir.path().join("eng-kjv2006.sb")).unwrap();
    assert_eq!(kjv.books().unwrap().len(), 66);
    assert_eq!(
        verse(&kjv, "GEN", 1, 1).as_deref(),
        Some("In the beginning God created the heaven and the earth.")
    );
    let ch = kjv
        .chapter(BookCode::new("GEN").unwrap(), 1)
        .unwrap()
        .unwrap();
    let has_strongs = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .any(|s| matches!(s, Span::Text { attrs, .. } if attrs.contains("strong=")));
    assert!(has_strongs, "в KJV должны быть атрибуты Стронга");
    assert_eq!(orphan_verses(&kjv), 0);
}

#[test]
fn cli_info_and_verse() {
    let Some(data) = data_root() else {
        eprintln!("SKIPPED: нет каталога данных");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    build_all(&data, dir.path());
    let file = dir.path().join("russyn.sb");

    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args(["module", "info", file.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("russyn"));

    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args(["module", "verse", file.to_str().unwrap(), "GEN", "1:3"])
        .output()
        .unwrap();
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("свет"));

    // Стих за пределами главы — ошибка, не паника.
    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args(["module", "verse", file.to_str().unwrap(), "GEN", "1:99"])
        .output()
        .unwrap();
    assert!(!out.status.success());
}

#[test]
fn cli_read_and_search() {
    let Some(data) = data_root() else {
        eprintln!("SKIPPED: нет каталога данных");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    build_all(&data, dir.path());
    let syn = dir.path().join("russyn.sb");

    // Чтение диапазона с русским именем книги.
    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args(["read", syn.to_str().unwrap(), "Быт 1:1-3"])
        .output()
        .unwrap();
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("Бытие 1"));
    assert!(text.contains("1.  В начале сотворил Бог"));
    assert!(text.contains("3. И сказал Бог: да будет свет. И стал свет."));
    assert!(
        !text.contains("4. И увидел"),
        "стих 4 за пределами диапазона"
    );

    // Поиск: ё = е, регистр безразличен.
    let idx = dir.path().join("syn.idx");
    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args([
            "search",
            syn.to_str().unwrap(),
            "ИЕГОВА",
            "--cache",
            idx.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let hits = String::from_utf8_lossy(&out.stdout);
    assert!(hits.contains("Быт 22:14"));
    assert!(hits.contains("Суд 6:24"));

    // Поиск по нескольким словам — пересечение.
    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args([
            "search",
            syn.to_str().unwrap(),
            "пастырь мой",
            "--cache",
            idx.to_str().unwrap(),
            "--limit",
            "3",
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let hits = String::from_utf8_lossy(&out.stdout);
    assert!(hits.contains("Пс 22:1"));

    // Кэш переиспользуется, а не перестраивается.
    let mtime1 = std::fs::metadata(&idx).unwrap().modified().unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args([
            "search",
            syn.to_str().unwrap(),
            "свет",
            "--cache",
            idx.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(out.status.success());
    let mtime2 = std::fs::metadata(&idx).unwrap().modified().unwrap();
    assert_eq!(mtime1, mtime2, "индекс не должен перестраиваться");
}
