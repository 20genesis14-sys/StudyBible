//! Пользовательская база: записи, надгробия, круговая проверка zip.

use studybible_core::BookCode;
use studybible_store::{Anchor, Kind, UserData};

#[test]
fn userdata_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("u.db");
    let at = |c: u16, v: u16| Anchor {
        module: "russyn",
        book: BookCode::new("GEN").unwrap(),
        chapter: c,
        verse: v,
    };

    let db = UserData::open(&db_path).unwrap();
    let note = db
        .add(Kind::Note, at(1, 1), "Первый стих", "В начале")
        .unwrap();
    let mark = db.add(Kind::Mark, at(22, 14), "Иегова-ире", "").unwrap();
    db.add(Kind::Highlight, at(1, 3), "yellow", "").unwrap();

    assert_eq!(db.entries(Kind::Note, None).unwrap().len(), 1);
    assert_eq!(db.entries(Kind::Mark, None).unwrap().len(), 1);
    assert_eq!(db.entries(Kind::Highlight, None).unwrap().len(), 1);

    // Удаление — надгробие: записи нет в списке, но она едет в экспорт.
    assert!(db.remove(&mark).unwrap());
    assert!(db.entries(Kind::Mark, None).unwrap().is_empty());

    let zip = dir.path().join("export.zip");
    let n = db.export_zip(&zip).unwrap();
    assert_eq!(n, 3, "надгробие тоже экспортируется");

    // Импорт в чистую базу: две живые записи и надгробие.
    let db2_path = dir.path().join("u2.db");
    let db2 = UserData::open(&db2_path).unwrap();
    let st = db2.import_zip(&zip).unwrap();
    assert_eq!(st.added, 3);
    let notes = db2.entries(Kind::Note, None).unwrap();
    assert_eq!(notes[0].text, "Первый стих");
    assert_eq!(notes[0].context, "В начале");
    assert!(db2.entries(Kind::Mark, None).unwrap().is_empty());

    // Повторный импорт ничего не дублирует.
    let st = db2.import_zip(&zip).unwrap();
    assert_eq!(st.skipped, 3);

    // «Побеждает свежее»: правка в другой базе (миллисекунды новее) приезжает с архивом.
    let db3_path = dir.path().join("u3.db");
    let db3 = UserData::open(&db3_path).unwrap();
    db3.import_zip(&zip).unwrap();
    db3.update(&note, "правка позже").unwrap();
    let zip2 = dir.path().join("export2.zip");
    db3.export_zip(&zip2).unwrap();
    let st = db2.import_zip(&zip2).unwrap();
    assert_eq!(st.updated, 1);
    let notes2 = db2.entries(Kind::Note, None).unwrap();
    assert_eq!(notes2[0].text, "правка позже");

    // Обратный импорт первого архива не откатывает свежую правку.
    let st = db2.import_zip(&zip).unwrap();
    assert_eq!(
        db2.entries(Kind::Note, None).unwrap()[0].text,
        "правка позже"
    );
    assert_eq!(st.skipped, 3);

    // Повторный remove по несуществующему id — false, не паника.
    assert!(!db.remove("нет-такого").unwrap());
}
