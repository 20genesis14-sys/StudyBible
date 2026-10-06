//! `module pack`/`module check` и распаковка `.sbz` (ADR 0016, п. 6–7).

use std::process::Command;

use studybible_store::sbz::{self, Codec, SbzError};
use studybible_store::{Meta, ModuleWriter};

fn make_module(path: &std::path::Path) {
    let meta = Meta {
        id: "t".into(),
        language: "ru".into(),
        versification: "rsc".into(),
        ..Meta::default()
    };
    let mut w = ModuleWriter::create(path, &meta).unwrap();
    let code = studybible_core::BookCode::new("GEN").unwrap();
    w.add_book(code, 1, "Бытие", &Default::default()).unwrap();
    let ch = studybible_convert::usfm::parse("\\id GEN\n\\c 1\n\\v 1 Текст.\n").unwrap();
    for c in &ch.chapters {
        w.add_chapter(code, c).unwrap();
    }
    w.finish().unwrap();
}

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_studybible"))
}

#[test]
fn pack_zstd_and_brotli_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let sb = dir.path().join("m.sb");
    make_module(&sb);
    let raw = std::fs::read(&sb).unwrap();
    assert!(raw.starts_with(b"SQLite format 3"));

    for codec in ["zstd", "brotli"] {
        let sbz_path = dir.path().join(format!("m-{codec}.sbz"));
        let st = cli()
            .args([
                "module",
                "pack",
                sb.to_str().unwrap(),
                "--codec",
                codec,
                "--out",
                sbz_path.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(
            st.status.success(),
            "{codec}: {}",
            String::from_utf8_lossy(&st.stderr)
        );

        let packed = std::fs::read(&sbz_path).unwrap();
        assert!(packed.starts_with(sbz::MAGIC));
        assert_eq!(Codec::from_id(packed[4]).name(), codec);
        assert!(packed.len() < raw.len() + sbz::HEADER_LEN);

        // Распаковка возвращает ровно исходный .sb.
        assert_eq!(sbz::unpack(&packed).unwrap(), raw);
    }
}

#[test]
fn check_accepts_sbz_and_rejects_junk() {
    let dir = tempfile::tempdir().unwrap();
    let sb = dir.path().join("m.sb");
    make_module(&sb);

    // check по .sb — ок.
    let st = cli()
        .args(["module", "check", sb.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        st.status.success(),
        "{}",
        String::from_utf8_lossy(&st.stderr)
    );

    // Запаковать и проверить .sbz — ок.
    let sbz_path = dir.path().join("m.sbz");
    let st = cli()
        .args(["module", "pack", sb.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(st.status.success());
    let sbz_path = if sbz_path.exists() {
        sbz_path
    } else {
        sb.with_extension("sbz")
    };
    let st = cli()
        .args(["module", "check", sbz_path.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        st.status.success(),
        "{}",
        String::from_utf8_lossy(&st.stderr)
    );

    // Мусор — понятная ошибка.
    let junk = dir.path().join("junk.sbz");
    std::fs::write(&junk, b"SBZ1\x09garbage").unwrap();
    let st = cli()
        .args(["module", "check", junk.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(!st.status.success());
    let err = String::from_utf8_lossy(&st.stderr);
    assert!(err.contains("кодек"), "{err}");
}

#[test]
fn unpack_rejects_unknown_codec() {
    let mut bytes = b"SBZ1".to_vec();
    bytes.push(9); // зарезервированный кодек
    bytes.extend_from_slice(b"payload");
    match sbz::unpack(&bytes) {
        Err(SbzError::UnsupportedCodec(c)) => assert_eq!(c.id(), 9),
        other => panic!("ожидался UnsupportedCodec, получено {other:?}"),
    }
    assert!(matches!(sbz::unpack(b"not-sbz"), Err(SbzError::NotSbz)));
}
