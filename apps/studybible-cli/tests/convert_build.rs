//! Сквозные тесты конвертеров: синтетические источники MyBible/BibleQuote
//! в temp-каталоге → `studybible module build` по временному modules.json →
//! проверка готовых .sb через `Module::open` и `module check`.
//! Без сети и реальных данных — все входы создаются тестом.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use rusqlite::Connection;
use studybible_core::BookCode;
use studybible_core::text::Span;
use studybible_store::Module;

fn cli(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_studybible"))
        .args(args)
        .output()
        .expect("запуск studybible")
}

/// Корень данных temp: sources/ + defs modules.json + out/.
struct Fixture {
    _dir: tempfile::TempDir,
    data: PathBuf,
    defs: PathBuf,
    out: PathBuf,
}

fn fixture(modules_json: &str) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(data.join("sources")).unwrap();
    let defs = dir.path().join("modules.json");
    std::fs::write(&defs, format!("{{\"modules\": {modules_json}}}")).unwrap();
    let out = dir.path().join("out");
    Fixture {
        _dir: dir,
        data,
        defs,
        out,
    }
}

impl Fixture {
    fn sources(&self) -> PathBuf {
        self.data.join("sources")
    }

    fn build(&self) {
        let o = cli(&[
            "module",
            "build",
            "--defs",
            self.defs.to_str().unwrap(),
            "--data",
            self.data.to_str().unwrap(),
            "--out",
            self.out.to_str().unwrap(),
        ]);
        assert!(
            o.status.success(),
            "module build: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    }

    /// Проверить собранный модуль (по умолчанию build выдаёт .sbz).
    fn check(&self, id: &str) {
        let f = self.out.join(format!("{id}.sbz"));
        assert!(f.is_file(), "{id}: нет {}", f.display());
        let o = cli(&["module", "check", f.to_str().unwrap()]);
        assert!(
            o.status.success(),
            "module check {id}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    }

    /// Открыть .sbz: распаковать во временный .sb рядом и открыть его.
    fn open(&self, id: &str) -> Module {
        let bytes = std::fs::read(self.out.join(format!("{id}.sbz"))).unwrap();
        let raw = studybible_store::sbz::unpack(&bytes).unwrap();
        let tmp = self.out.join(format!("{id}.unpacked.sb"));
        std::fs::write(&tmp, raw).unwrap();
        Module::open(&tmp).unwrap()
    }
}

/// База MyBible-Библии: info + books + verses (+stories).
fn mybible_bible(path: &Path) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE info(name TEXT, value TEXT);
         CREATE TABLE books(book_number INT, short_name TEXT, long_name TEXT);
         CREATE TABLE verses(book_number INT, chapter INT, verse INT, text TEXT);
         INSERT INTO info VALUES('description','Тестовая Библия'),('language','ru');
         INSERT INTO books VALUES(10,'Быт','Бытие'),(500,'Ин','Евангелие от Иоанна');
         INSERT INTO verses VALUES
          (10,1,1,'В начале сотворил Бог небо и землю.'),
          (10,1,2,'Земля же была пуста.'),
          (10,2,1,'Так совершены небо и земля.'),
          (500,1,1,'В начале было Слово.'),
          (500,3,16,'Ибо так возлюбил Бог мир.');",
    )
    .unwrap();
}

/// База комментариев MyBible рядом с Библией.
fn mybible_comm(path: &Path) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE commentaries(book_number INT, chapter_number_from INT,
          verse_number_from INT, chapter_number_to INT, verse_number_to INT,
          marker TEXT, text TEXT);
         INSERT INTO commentaries VALUES(10,1,1,1,2,'','Комментарий к Быт 1:1-2.'),
                                       (500,3,16,3,16,'','Толкование Ин 3:16.');",
    )
    .unwrap();
}

/// Словарь MyBible рядом с Библией.
fn mybible_dict(path: &Path) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE dictionary(topic TEXT, definition TEXT);
         INSERT INTO dictionary VALUES('Аарон','первый первосвященник'),
                                      ('Бог','<i>Творец</i> вселенной');",
    )
    .unwrap();
}

/// bibleqt.ini + htm книга (UTF-8 — валидный вход; cp1251 проверяют
/// юнит-тесты конвертера).
fn bq_files(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(
        dir.join("bibleqt.ini"),
        "BibleName = Тестовый модуль\nBible = Y\nChapterSign = <h4>\n\
         VerseSign = <sup>\nBookQty = 2\n\n\
         [Бытие]\nPathName = gen.htm\nFullName = Бытие\nShortName = Быт\nChapterQty = 2\n\n\
         [От Иоанна]\nPathName = jhn.htm\nFullName = Евангелие от Иоанна\n\
         ShortName = Ин\nChapterQty = 1\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("gen.htm"),
        "<h4>Глава 1</h4>\n<sup>1</sup>В начале сотворил Бог.\n<sup>2</sup>Пустота.\n\
         <h4>Глава 2</h4>\n<sup>1</sup>Завершение.\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("jhn.htm"),
        "<h4>Глава 1</h4>\n<sup>1</sup>В начале было Слово.\n",
    )
    .unwrap();
}

/// Те же файлы модуля — в .zip-архиве.
fn bq_zip(path: &Path) {
    let inner = tempfile::tempdir().unwrap();
    bq_files(inner.path());
    let f = std::fs::File::create(path).unwrap();
    let mut z = zip::ZipWriter::new(f);
    let opt = zip::write::SimpleFileOptions::default();
    for name in ["bibleqt.ini", "gen.htm", "jhn.htm"] {
        z.start_file(name, opt).unwrap();
        z.write_all(&std::fs::read(inner.path().join(name)).unwrap())
            .unwrap();
    }
    z.finish().unwrap();
}

fn verse(m: &Module, book: &str, ch: u16, v: u16) -> Option<String> {
    m.verse_text(BookCode::new(book).unwrap(), ch, v).unwrap()
}

/// MyBible: *.SQLite3, *.commentaries.SQLite3 и *.dictionary.SQLite3
/// в одном каталоге → три разных модуля по kind (Библия / комментарии /
/// словарь); файлы соседних ролей не должны перетекать.
#[test]
fn mybible_routes_by_kind() {
    let fx = fixture(
        r#"[
          {"id":"mb-bible","source":"myb","title":"Библия","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"mybible"},
          {"id":"mb-comm","source":"myb","title":"Комментарии","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"mybible",
           "kind":"commentary"},
          {"id":"mb-dict","source":"myb","title":"Словарь","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"mybible",
           "kind":"dictionary"}
        ]"#,
    );
    let src = fx.sources().join("myb");
    std::fs::create_dir_all(&src).unwrap();
    mybible_bible(&src.join("t.SQLite3"));
    mybible_comm(&src.join("t.commentaries.SQLite3"));
    mybible_dict(&src.join("t.dictionary.SQLite3"));
    fx.build();

    // Библия: стихи на месте, kind=bible.
    let b = fx.open("mb-bible");
    assert_eq!(b.meta().kind, "bible");
    assert_eq!(b.books().unwrap().len(), 2);
    assert_eq!(
        verse(&b, "GEN", 1, 1).as_deref(),
        Some("В начале сотворил Бог небо и землю.")
    );
    assert!(verse(&b, "JHN", 3, 16).unwrap().contains("возлюбил"));
    fx.check("mb-bible");

    // Комментарий: kind=commentary, запись привязана к первому стиху
    // диапазона — в модули Библии/словаря не попала.
    let c = fx.open("mb-comm");
    assert_eq!(c.meta().kind, "commentary");
    assert_eq!(c.books().unwrap().len(), 2);
    assert!(
        c.verse_text(BookCode::new("GEN").unwrap(), 1, 1)
            .unwrap()
            .unwrap()
            .contains("Комментарий")
    );
    // В «комментариях» не текст Библии, а текст толкования.
    let ch = c
        .chapter(BookCode::new("JHN").unwrap(), 3)
        .unwrap()
        .unwrap();
    let plain: String = ch
        .blocks
        .iter()
        .flat_map(|b| &b.spans)
        .filter_map(|s| match s {
            Span::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert!(plain.contains("Толкование"));
    assert!(!plain.contains("возлюбил"));
    fx.check("mb-comm");

    // Словарь: kind=dictionary, статьи по entries.
    let d = fx.open("mb-dict");
    assert_eq!(d.meta().kind, "dictionary");
    assert_eq!(d.entries_count().unwrap(), 2);
    let heads: Vec<String> = d
        .entries(0, 10, "")
        .unwrap()
        .into_iter()
        .map(|(_, h)| h)
        .collect();
    assert_eq!(heads, ["Аарон", "Бог"]);
    let (_, text) = d.entry(1).unwrap().unwrap();
    assert!(text.contains("первосвященник"));
    // У словаря нет книг.
    assert_eq!(d.books().unwrap().len(), 0);
    fx.check("mb-dict");
}

/// BibleQuote по каталогу с bibleqt.ini и по .zip-архиву — два модуля.
#[test]
fn biblequote_dir_and_zip() {
    let fx = fixture(
        r#"[
          {"id":"bq-dir","source":"bqdir","title":"BQ каталог","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"biblequote"},
          {"id":"bq-zip","source":"bqzip","title":"BQ архив","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"biblequote"}
        ]"#,
    );
    bq_files(&fx.sources().join("bqdir"));
    std::fs::create_dir_all(fx.sources().join("bqzip")).unwrap();
    bq_zip(&fx.sources().join("bqzip/mod.zip"));
    fx.build();

    for id in ["bq-dir", "bq-zip"] {
        let m = fx.open(id);
        assert_eq!(m.meta().kind, "bible", "{id}");
        assert_eq!(m.books().unwrap().len(), 2, "{id}");
        assert_eq!(
            verse(&m, "GEN", 1, 1).as_deref(),
            Some("В начале сотворил Бог."),
            "{id}"
        );
        assert_eq!(
            verse(&m, "GEN", 2, 1).as_deref(),
            Some("Завершение."),
            "{id}"
        );
        assert_eq!(
            verse(&m, "JHN", 1, 1).as_deref(),
            Some("В начале было Слово."),
            "{id}"
        );
        fx.check(id);
    }
}

/// Ошибка сборки одного модуля не останавливает остальные; итог —
/// ненулевой код и перечень несобранных в stderr.
#[test]
fn build_failure_lists_failed_module() {
    let fx = fixture(
        r#"[
          {"id":"ok","source":"bqdir","title":"Хороший","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"biblequote",
           "sbz":false},
          {"id":"bad","source":"nosuch","title":"Битый","language":"ru",
           "versification":"rsc","name_profile":"syn","format":"biblequote"}
        ]"#,
    );
    bq_files(&fx.sources().join("bqdir"));
    // sources/nosuch не создаём — сборка этого модуля упадёт.
    let o = cli(&[
        "module",
        "build",
        "--defs",
        fx.defs.to_str().unwrap(),
        "--data",
        fx.data.to_str().unwrap(),
        "--out",
        fx.out.to_str().unwrap(),
    ]);
    assert!(!o.status.success());
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(err.contains("bad"), "{err}");
    // Хороший модуль всё же собран — с "sbz": false в голый .sb.
    assert!(fx.out.join("ok.sb").is_file());
    assert!(!fx.out.join("ok.sbz").is_file());
}
