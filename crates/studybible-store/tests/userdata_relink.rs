//! Перепривязка записей к модулям (вопрос №12, этап Б):
//! миграция схемы 1→2, метаполя, `UserData::relink`.

use studybible_convert::usfm;
use studybible_core::BookCode;
use studybible_core::versification::{VerseKey, Versification};
use studybible_store::{Anchor, Bind, Kind, Meta, Module, ModuleWriter, UserData, canon_range};

const SRC: &str = "\\id GEN\n\\h Бытие\n\\toc1 Бытие\n\
\\c 1\n\\p\n\\v 1 Первый стих.\n\\v 2 Второй стих.\n\\v 3 Третий стих.\n\\v 4 Четвёртый стих.\n";

// «Обновлённая» редакция: стих 1 изменён и сдвинут на позицию 2.
const SRC2: &str = "\\id GEN\n\\h Бытие\n\\toc1 Бытие\n\
\\c 1\n\\p\n\\v 1 Первый стих (испр).\n\\v 2 Второй стих.\n\\v 3 Третий стих.\n\\v 4 Четвёртый стих.\n\\v 5 Пятый стих.\n";

fn meta(id: &str) -> Meta {
    Meta {
        id: id.into(),
        language: "ru".into(),
        versification: "rsc".into(),
        ..Meta::default()
    }
}

fn build(path: &std::path::Path, id: &str, src: &str) {
    let b = usfm::parse(src).unwrap();
    let mut w = ModuleWriter::create(path, &meta(id)).unwrap();
    w.add_book(b.code, 1, "Бытие", &b.header).unwrap();
    for ch in &b.chapters {
        w.add_chapter(b.code, ch).unwrap();
    }
    w.finish().unwrap();
}

fn anchor() -> Anchor<'static> {
    Anchor {
        module: "m1",
        book: BookCode::new("GEN").unwrap(),
        chapter: 1,
        verse: 1,
    }
}

/// Bind с canon, как пишут мост/CLI: vrs+hash модуля и org-диапазон якоря.
fn bind(m: &Module) -> Bind {
    let meta = m.meta();
    let (from, to) = Versification::builtin(&meta.versification)
        .and_then(|v| canon_range(v, VerseKey::new(anchor().book, 1, 1)))
        .map(|(f, t)| (Some(f), Some(t)))
        .unwrap_or_default();
    Bind {
        vrs: meta.versification.clone(),
        module_ver: meta.content_hash.clone(),
        canon_from: from,
        canon_to: to,
    }
}

#[test]
fn fresh_when_meta_matches() {
    let dir = tempfile::tempdir().unwrap();
    let mp = dir.path().join("m1.sb");
    build(&mp, "m1", SRC);
    let m = Module::open(&mp).unwrap();
    let meta = m.meta();
    let ver = meta.content_hash.clone();

    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    ud.add_ex(Kind::Note, anchor(), "заметка", "Первый стих.", &bind(&m))
        .unwrap();
    let _ = ver;

    let s = ud
        .relink(|id| (id == "m1").then(|| Module::open(&mp).unwrap()))
        .unwrap();
    assert_eq!(s.fresh, 1);
    assert!(s.orphaned.is_empty());
}

#[test]
fn relink_moves_to_nearby_verse() {
    let dir = tempfile::tempdir().unwrap();
    let mp1 = dir.path().join("old.sb");
    build(&mp1, "m1", SRC);
    let old = Module::open(&mp1).unwrap();

    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    let id = ud
        .add_ex(
            Kind::Note,
            anchor(),
            "заметка",
            "Второй стих.", // запись висела на стихе 1 с этим контекстом
            &bind(&old),
        )
        .unwrap();

    // Модуль обновился: у стиха 1 другой текст, «Второй стих.» уехал на v=2…
    // нет — в SRC2 «Второй стих.» остался на v=2, якорь v=1 не совпадёт.
    let mp2 = dir.path().join("new.sb");
    build(&mp2, "m1", SRC2);
    let s = ud.relink(|_| Some(Module::open(&mp2).unwrap())).unwrap();
    assert_eq!(s.moved, 1, "{s:?}");
    assert!(s.orphaned.is_empty());

    let e = ud
        .entries(Kind::Note, None)
        .unwrap()
        .into_iter()
        .find(|e| e.id == id)
        .unwrap();
    assert_eq!(e.verse, 2);
    assert_eq!(e.vrs, "rsc");
    assert_eq!(e.rev, 2, "переезд поднял ревизию для синхронизации");
}

#[test]
fn orphan_when_context_gone() {
    let dir = tempfile::tempdir().unwrap();
    let mp1 = dir.path().join("old.sb");
    build(&mp1, "m1", SRC);
    let old = Module::open(&mp1).unwrap();

    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    let id = ud
        .add_ex(
            Kind::Note,
            anchor(),
            "",
            "Такого текста нет нигде",
            &bind(&old),
        )
        .unwrap();

    let mp2 = dir.path().join("new.sb");
    build(&mp2, "m1", SRC2);
    let s = ud.relink(|_| Some(Module::open(&mp2).unwrap())).unwrap();
    assert_eq!(s.orphaned, vec![id.clone()]);
    // Запись не тронута.
    let e = ud
        .entries(Kind::Note, None)
        .unwrap()
        .into_iter()
        .find(|e| e.id == id)
        .unwrap();
    assert_eq!(e.verse, 1);
    assert_eq!(e.rev, 1);
}

#[test]
fn backfills_context_and_meta_when_empty() {
    // Записи старой схемы/CLI без контекста: мета пустая — получают
    // мету текущего модуля и фрагмент якорного стиха.
    let dir = tempfile::tempdir().unwrap();
    let mp = dir.path().join("m1.sb");
    build(&mp, "m1", SRC);
    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    let id = ud.add(Kind::Note, anchor(), "старая", "").unwrap();

    let s = ud.relink(|_| Some(Module::open(&mp).unwrap())).unwrap();
    assert_eq!(s.stamped, 1);
    let e = ud
        .entries(Kind::Note, None)
        .unwrap()
        .into_iter()
        .find(|e| e.id == id)
        .unwrap();
    assert_eq!(e.vrs, "rsc");
    assert!(!e.module_ver.is_empty());
    assert_eq!(e.context, "Первый стих.");
}

#[test]
fn skips_missing_module_and_progress() {
    let dir = tempfile::tempdir().unwrap();
    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    let mut a = anchor();
    a.module = "absent";
    ud.add(Kind::Note, a, "x", "y").unwrap();
    let mut p = anchor();
    p.module = "*";
    ud.add(Kind::Highlight, p, "read", "").unwrap();

    let s = ud.relink(|_| None).unwrap();
    assert_eq!(s.checked, 0);
    assert_eq!(s.skipped, 1);
}

#[test]
fn foreign_entries_by_canon() {
    // Запись модуля m2 находится из m1 по org-координате; записи
    // неустановленного модуля и служебные отфильтровываются.
    let dir = tempfile::tempdir().unwrap();
    let mp2 = dir.path().join("m2.sb");
    build(&mp2, "m2", SRC);
    let m2 = Module::open(&mp2).unwrap();

    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    let mut a2 = anchor();
    a2.module = "m2";
    let b = bind(&m2);
    ud.add_ex(Kind::Note, a2, "чужая", "Первый стих.", &b)
        .unwrap();
    // Запись к неустановленному модулю — не показываем.
    let mut ax = anchor();
    ax.module = "absent";
    ud.add_ex(Kind::Note, ax, "нет модуля", "x", &b).unwrap();
    // Своя запись — в чужой список не попадает.
    let mp1 = dir.path().join("m1.sb");
    build(&mp1, "m1", SRC);
    let m1 = Module::open(&mp1).unwrap();
    ud.add_ex(Kind::Note, anchor(), "своя", "y", &bind(&m1))
        .unwrap();

    let org = Versification::builtin("rsc")
        .unwrap()
        .to_org(VerseKey::new(anchor().book, 1, 1));
    let list = ud.entries_foreign("m1", &org, |id| id == "m2").unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0].module, "m2");
    assert_eq!(list[0].text, "чужая");
}

#[test]
fn relink_backfills_canon_when_meta_matches() {
    // Мета совпадает, но канон пуст (запись этапа Б) — не «свежая»,
    // доштамповываем канонический диапазон.
    let dir = tempfile::tempdir().unwrap();
    let mp = dir.path().join("m1.sb");
    build(&mp, "m1", SRC);
    let m = Module::open(&mp).unwrap();

    let ud = UserData::open(&dir.path().join("u.db")).unwrap();
    let b = Bind {
        vrs: "rsc".into(),
        module_ver: m.meta().content_hash.clone(),
        canon_from: None,
        canon_to: None,
    };
    let id = ud
        .add_ex(Kind::Note, anchor(), "заметка", "Первый стих.", &b)
        .unwrap();

    let s = ud
        .relink(|_| Some(Module::open(&mp).unwrap()))
        .unwrap();
    assert_eq!(s.stamped, 1, "{s:?}");
    assert_eq!(s.fresh, 0);
    let e = ud
        .entries(Kind::Note, None)
        .unwrap()
        .into_iter()
        .find(|e| e.id == id)
        .unwrap();
    assert_eq!(e.canon_book, "GEN");
    assert_eq!((e.canon_ch1, e.canon_v1), (1, 1));
}

#[test]
fn migrates_schema_1() {
    // База схемы 1 открывается: колонки vrs/module_ver появляются.
    let dir = tempfile::tempdir().unwrap();
    let p = dir.path().join("u.db");
    {
        let c = rusqlite::Connection::open(&p).unwrap();
        c.execute_batch(
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO meta VALUES('schema','1');
             CREATE TABLE entries(
               id TEXT PRIMARY KEY, module TEXT NOT NULL, kind TEXT NOT NULL,
               book TEXT NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
               text TEXT NOT NULL DEFAULT '', context TEXT NOT NULL DEFAULT '',
               created INTEGER NOT NULL, updated INTEGER NOT NULL,
               deleted INTEGER NOT NULL DEFAULT 0,
               device TEXT NOT NULL DEFAULT '', rev INTEGER NOT NULL DEFAULT 1);",
        )
        .unwrap();
    }
    let ud = UserData::open(&p).unwrap();
    let id = ud.add(Kind::Note, anchor(), "миграция", "").unwrap();
    let e = ud
        .entries(Kind::Note, None)
        .unwrap()
        .into_iter()
        .find(|e| e.id == id)
        .unwrap();
    assert_eq!(e.vrs, "");
    assert_eq!(e.module_ver, "");
}
