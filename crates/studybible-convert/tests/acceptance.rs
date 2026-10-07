//! Приёмка на реальных данных (ADR 0016): модули, собранные новыми
//! конвертерами, против ранее собранных в STUDYBIBLE_DATA.
//! SKIPPED, если файлов нет (источники вне репозитория).

use rusqlite::Connection;

#[derive(Default, Debug)]
struct Counts {
    books: i64,
    verses: i64,
    strongs: i64,
    notes: i64,
}

fn counts(p: &std::path::Path) -> Option<Counts> {
    let raw = std::fs::read(p).ok()?;
    // `.sbz` — распаковать во временный `.sb` (tmp объявлен первым —
    // удаляется после закрытия соединения).
    let tmp;
    let c = if raw.starts_with(studybible_store::sbz::MAGIC) {
        let bytes = studybible_store::sbz::unpack(&raw).ok()?;
        tmp = tempfile::NamedTempFile::new().ok()?;
        std::fs::write(tmp.path(), bytes).ok()?;
        Connection::open(tmp.path()).ok()?
    } else {
        Connection::open(p).ok()?
    };
    let q = |s: &str| c.query_row(s, [], |r| r.get::<_, i64>(0)).unwrap_or(0);
    Some(Counts {
        books: q("SELECT count(*) FROM books"),
        verses: q("SELECT count(*) FROM verses"),
        strongs: q("SELECT count(*) FROM spans WHERE attrs LIKE '%strong=%'"),
        notes: q("SELECT count(*) FROM spans WHERE kind IN ('f','n','x')"),
    })
}

fn cmp(new: &std::path::Path, old: &std::path::Path) -> Option<(Counts, Counts)> {
    let n = counts(std::path::Path::new(new))?;
    let o = counts(std::path::Path::new(old))?;
    Some((n, o))
}

#[test]
fn rstplus_vs_legacy() {
    let tmp = std::env::temp_dir().join("sb-accept");
    let Some((n, o)) = cmp(
        &tmp.join("rstplus-new.sb"),
        std::path::Path::new(r"D:\StudyBible-data\modules\rstplus.sbz"),
    ) else {
        eprintln!("SKIPPED: нет собранного rstplus-new.sb или исходного rstplus.sbz");
        return;
    };
    eprintln!("rstplus legacy: {o:?}\nrstplus new:    {n:?}");
    let _legacy_notes_includes_xrefs = o.notes;
    let _new_footnotes = n.notes;
    assert_eq!(n.books, o.books, "число книг");
    assert_eq!(n.verses, o.verses, "число стихов");
    // Стронг: -230 (-0,07 %) — в старом конвертере номера внутри
    // сносок/заголовков тоже шли в strong-атрибуты; сносок 108 — как
    // в описании источника; у старого модуля kind='x' считал и
    // параллельные места (~29 тыс.), потому notes не сравниваем.
    assert!(
        (n.strongs - o.strongs).abs() <= 300,
        "Стронг: {n:?} vs {o:?}"
    );
}

#[test]
fn henry_vs_legacy() {
    let tmp = std::env::temp_dir().join("sb-accept");
    let Some((n, o)) = cmp(
        &tmp.join("comm-henry-new.sb"),
        std::path::Path::new(r"D:\StudyBible-data\modules\comm-henry.sbz"),
    ) else {
        eprintln!("SKIPPED: нет собранного comm-henry-new.sb или исходного comm-henry.sbz");
        return;
    };
    eprintln!("henry legacy: {o:?}\nhenry new:    {n:?}");
    assert_eq!(n.books, o.books, "число книг");
    // +39 записей (~0,9 %): старый gen_henry.py терял секции с
    // нестандартной разметкой маркеров; новый их подбирает, а
    // повторные маркеры на один стих склеивает (Екк 5:17, Дан 4:31).
    assert!(
        (n.verses - o.verses).abs() <= 50,
        "комментарии: {n:?} vs {o:?}"
    );
}
