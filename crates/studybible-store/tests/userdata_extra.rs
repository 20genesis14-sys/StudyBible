//! Пользовательская база: ошибки импорта, фильтры, надгробия, ревизии.

use std::io::Write;

use studybible_core::BookCode;
use studybible_store::{Anchor, Kind, UserData, UserError};

fn anchor<'a>(module: &'a str, book: &'a str, ch: u16, v: u16) -> Anchor<'a> {
    Anchor {
        module,
        book: BookCode::new(book).unwrap(),
        chapter: ch,
        verse: v,
    }
}

#[test]
fn filters_and_lookup() {
    let dir = tempfile::tempdir().unwrap();
    let db = UserData::open(&dir.path().join("u.db")).unwrap();
    db.add(Kind::Note, anchor("syn", "GEN", 1, 1), "заметка", "ctx")
        .unwrap();
    db.add(Kind::Mark, anchor("syn", "EXO", 2, 3), "закладка", "")
        .unwrap();
    db.add(Kind::Highlight, anchor("kjv", "GEN", 1, 1), "yellow", "")
        .unwrap();

    // Фильтр по виду и по модулю.
    assert_eq!(db.entries(Kind::Note, None).unwrap().len(), 1);
    assert_eq!(db.entries(Kind::Mark, Some("syn")).unwrap().len(), 1);
    assert!(db.entries(Kind::Mark, Some("kjv")).unwrap().is_empty());
    assert_eq!(db.entries(Kind::Highlight, Some("kjv")).unwrap().len(), 1);
    assert_eq!(db.entries(Kind::Highlight, Some("syn")).unwrap().len(), 0);

    let e = &db.entries(Kind::Note, None).unwrap()[0];
    assert_eq!(e.context, "ctx");
    assert_eq!(e.rev, 1);
    assert_eq!(e.deleted, 0);
    assert!(!e.device.is_empty());
}

#[test]
fn update_and_revision() {
    let dir = tempfile::tempdir().unwrap();
    let db = UserData::open(&dir.path().join("u.db")).unwrap();
    let id = db
        .add(Kind::Note, anchor("syn", "GEN", 1, 1), "v1", "")
        .unwrap();
    assert!(db.update(&id, "v2").unwrap());
    let e = &db.entries(Kind::Note, None).unwrap()[0];
    assert_eq!(e.text, "v2");
    assert_eq!(e.rev, 2);

    // Обновление несуществующей записи — false, не ошибка.
    assert!(!db.update("неттакого", "x").unwrap());
    // Обновление удалённой — тоже false.
    db.remove(&id).unwrap();
    assert!(!db.update(&id, "v3").unwrap());
}

#[test]
fn tombstone_hides_but_keeps() {
    let dir = tempfile::tempdir().unwrap();
    let db = UserData::open(&dir.path().join("u.db")).unwrap();
    let id = db
        .add(Kind::Mark, anchor("syn", "GEN", 1, 1), "", "")
        .unwrap();
    assert!(db.remove(&id).unwrap());
    assert!(db.entries(Kind::Mark, None).unwrap().is_empty());
    // Надгробие видно в полном списке (экспорт) и считается записью.
    let exp = dir.path().join("e.zip");
    assert_eq!(db.export_zip(&exp).unwrap(), 1);
}

#[test]
fn tombstone_propagates_on_import() {
    let dir = tempfile::tempdir().unwrap();
    let db1 = UserData::open(&dir.path().join("a.db")).unwrap();
    let db2 = UserData::open(&dir.path().join("b.db")).unwrap();

    let id = db1
        .add(Kind::Note, anchor("syn", "GEN", 1, 1), "текст", "")
        .unwrap();
    let z1 = dir.path().join("1.zip");
    db1.export_zip(&z1).unwrap();
    db2.import_zip(&z1).unwrap();
    assert_eq!(db2.entries(Kind::Note, None).unwrap().len(), 1);

    // Удаляем во второй базе, импортируем обратно в первую — должно исчезнуть.
    std::thread::sleep(std::time::Duration::from_millis(5));
    db2.remove(&id).unwrap();
    let z2 = dir.path().join("2.zip");
    db2.export_zip(&z2).unwrap();
    let s = db1.import_zip(&z2).unwrap();
    assert_eq!(s.updated, 1, "надгробие обновило запись");
    assert!(db1.entries(Kind::Note, None).unwrap().is_empty());
}

#[test]
fn bad_imports() {
    let dir = tempfile::tempdir().unwrap();
    let db = UserData::open(&dir.path().join("u.db")).unwrap();

    // Не zip вообще.
    let bad = dir.path().join("not.zip");
    std::fs::write(&bad, b"plain text").unwrap();
    assert!(matches!(
        db.import_zip(&bad),
        Err(UserError::Zip(_)) | Err(UserError::BadFormat(_))
    ));

    // Zip без userdata.json.
    let empty = dir.path().join("empty.zip");
    {
        let f = std::fs::File::create(&empty).unwrap();
        let mut z = zip::ZipWriter::new(f);
        let o = zip::write::SimpleFileOptions::default();
        z.start_file("other.txt", o).unwrap();
        z.write_all(b"hi").unwrap();
        z.finish().unwrap();
    }
    assert!(matches!(
        db.import_zip(&empty),
        Err(UserError::BadFormat(_))
    ));

    // userdata.json с неверным format.
    let wrong = dir.path().join("wrong.zip");
    {
        let f = std::fs::File::create(&wrong).unwrap();
        let mut z = zip::ZipWriter::new(f);
        let o = zip::write::SimpleFileOptions::default();
        z.start_file("userdata.json", o).unwrap();
        z.write_all(br#"{"format":"other","version":"1","entries":[]}"#)
            .unwrap();
        z.finish().unwrap();
    }
    assert!(matches!(
        db.import_zip(&wrong),
        Err(UserError::BadFormat(_))
    ));

    // Невалидный JSON.
    let brok = dir.path().join("brok.zip");
    {
        let f = std::fs::File::create(&brok).unwrap();
        let mut z = zip::ZipWriter::new(f);
        let o = zip::write::SimpleFileOptions::default();
        z.start_file("userdata.json", o).unwrap();
        z.write_all(b"{oops").unwrap();
        z.finish().unwrap();
    }
    assert!(matches!(db.import_zip(&brok), Err(UserError::BadFormat(_))));
}

#[test]
fn reopen_same_db() {
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("u.db");
    let id = {
        let db = UserData::open(&p).unwrap();
        db.add(Kind::Note, anchor("syn", "GEN", 1, 1), "x", "")
            .unwrap()
    };
    // Повторное открытие: записи и device сохранились.
    let db = UserData::open(&p).unwrap();
    let e = db.entries(Kind::Note, None).unwrap();
    assert_eq!(e.len(), 1);
    assert_eq!(e[0].id, id);
}

#[test]
fn ids_unique_within_db() {
    let dir = tempfile::tempdir().unwrap();
    let db = UserData::open(&dir.path().join("u.db")).unwrap();
    let mut ids = std::collections::HashSet::new();
    for _ in 0..100 {
        let id = db
            .add(Kind::Mark, anchor("syn", "GEN", 1, 1), "", "")
            .unwrap();
        assert!(ids.insert(id), "id повторился");
    }
}
