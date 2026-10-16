"""Фаза 6 (Шаг 3): Полный конвейер сборки накладного слоя {target}-strongs.sb
по главам с сохранением квитанций runs/<target>/<BOOK>.<ch>.json и упаковкой
через strongs_layer.exe.

Пример запуска для KJV (eng-kjv2006.sb):
  py -3 -X utf8 tools/strongs/pipeline/build_layer.py --module D:/StudyBible-data/modules/eng-kjv2006.sb
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import json
import os
import pathlib
import sqlite3
import subprocess
import time

from contour1 import (
    OrigCand,
    WordLink,
    align_verse_assisted,
    align_verse_blind,
    get_verse_candidates,
    load_orig_Index,
)
from contour2 import (
    RULES_HASH,
    reconcile_chapter,
    resolve_polysemy_and_review,
    write_chapter_receipt,
)
from priors import BOOK_ID, ID_BOOK, norm_classic

REPO = pathlib.Path(__file__).resolve().parents[3]
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))


def load_valid_lex_keys() -> set[str]:
    db = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb")
    keys = {r[0] for r in db.execute("SELECT key FROM lex")}
    for r in db.execute("SELECT base FROM lex_base"):
        keys.add(r[0])
        cl = norm_classic(r[0])
        if cl:
            keys.add(cl)
    return keys


SCHEMA_SQL = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(book_id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL,
                   ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book_id INTEGER NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book_id, marker));
CREATE TABLE blocks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book_id, chapter, seq));
CREATE TABLE spans(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   verse INTEGER, start INTEGER, len INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, block, seq));
CREATE TABLE verses(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE tokens(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    seq INTEGER NOT NULL, surface TEXT NOT NULL DEFAULT '',
                    lemma TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                    morph TEXT NOT NULL DEFAULT '', gloss TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(book_id, chapter, verse, seq));
CREATE TABLE alignment(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                       token_seq INTEGER NOT NULL, block INTEGER NOT NULL, span INTEGER NOT NULL,
                       PRIMARY KEY(book_id, chapter, verse, token_seq));
CREATE TABLE variants(id INTEGER PRIMARY KEY,
                      book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                      token_from INTEGER NOT NULL, token_to INTEGER NOT NULL);
CREATE TABLE readings(id INTEGER PRIMARY KEY, variant_id INTEGER NOT NULL,
                      seq INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '',
                      is_base INTEGER NOT NULL DEFAULT 0);
CREATE TABLE witnesses(reading_id INTEGER NOT NULL, siglum TEXT NOT NULL,
                       PRIMARY KEY(reading_id, siglum));
CREATE TABLE entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
                     norm TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '');
CREATE INDEX entries_norm ON entries(norm);
CREATE TABLE marks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                   seq INTEGER NOT NULL, offset_ms INTEGER NOT NULL,
                   dur_ms INTEGER, text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, seq));
CREATE TABLE span_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                       block INTEGER NOT NULL, blob BLOB NOT NULL,
                       PRIMARY KEY(book_id, chapter, block));
CREATE TABLE token_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE align_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE xrefs_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE links(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                   verse INTEGER NOT NULL, word INTEGER NOT NULL,
                   ref TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                   conf INTEGER NOT NULL DEFAULT 0,
                   flags TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, word));
"""


def write_layer_sb(
    out_sb: pathlib.Path,
    target_id: str,
    target_hash: str,
    tokenizer: str,
    versification: str,
    mode: str,
    rows: list[tuple[int, int, int, int, str, str, int, str, str]],
    meta_overrides: dict[str, str] | None = None,
) -> None:
    if out_sb.exists():
        out_sb.unlink()
    db = sqlite3.connect(out_sb)
    db.execute("PRAGMA application_id = 0x53424D31")
    db.executescript(SCHEMA_SQL)
    db.executemany("INSERT INTO links VALUES (?,?,?,?,?,?,?,?,?)", rows)
    chash = hashlib.sha256(f"{target_id}:{mode}:{len(rows)}".encode()).hexdigest()
    meta_rows = {
        "format_version": "1",
        "id": f"{target_id}-strongs",
        "title": f"{target_id} — dStrong alignment layer (STEPBible)",
        "language": "en",
        "direction": "ltr",
        "versification": versification,
        "name_profile": "en",
        "book_order": "syn",
        "version": "0.1.0",
        "license": "CC BY 4.0",
        "attribution": "STEP Bible (www.STEPBible.org, CC BY 4.0); StudyBible Strong's Pipeline v1.0",
        "source": f"strongs-pipeline-{mode}",
        "kind": "layer",
        "features": "strongs",
        "target_id": target_id,
        "target_hash": target_hash,
        "tokenizer": tokenizer,
        "required": "",
        "content_hash": chash,
    }
    if meta_overrides:
        meta_rows.update(meta_overrides)
    db.executemany("INSERT INTO meta VALUES (?,?)", meta_rows.items())
    db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.close()


def run_pipeline(
    module_path: pathlib.Path,
    mode: str = "assisted",
    out_sb: pathlib.Path | None = None,
    resume: bool = False,
) -> dict:
    t0 = time.time()
    cli = REPO / "target" / "debug" / "studybible.exe"

    priors = json.loads((DATA / "work" / "strongs" / "pipeline" / "priors_en.json").read_text(encoding="utf-8"))
    verse_map = json.loads((DATA / "work" / "strongs" / "measure" / "verse_map.json").read_text(encoding="utf-8"))
    orig_index = load_orig_Index()
    valid_lex_keys = load_valid_lex_keys()

    # Шаг 1: Токенизация целевого модуля через studybible tokenize --with-spans
    proc = subprocess.Popen(
        [str(cli), "tokenize", "--with-spans", str(module_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    assert proc.stdout is not None

    meta: dict = {}
    chapters_data: dict[tuple[str, int], list[tuple[int, list[str], list[dict]]]] = collections.defaultdict(list)
    for line in proc.stdout:
        d = json.loads(line)
        if "_meta" in d:
            meta = d["_meta"]
            continue
        bk = d["book"]
        ch = int(d["chapter"])
        v = int(d["verse"])
        chapters_data[(bk, ch)].append((v, d["words"], d.get("word_spans", [])))
    proc.wait()

    target_id = meta["target_id"]
    run_tag = target_id if mode == "assisted" else f"{target_id}-blind"
    if out_sb is None:
        out_sb = DATA / "work" / "strongs" / "layers" / f"{run_tag}-strongs.sb"
    out_sb.parent.mkdir(parents=True, exist_ok=True)
    jsonl_path = out_sb.with_suffix(".jsonl")

    total_words = 0
    conf_totals: collections.Counter = collections.Counter()
    role_totals: collections.Counter = collections.Counter()
    reconciled_total = 0
    db_rows: list[tuple[int, int, int, int, str, str, int, str, str]] = []

    for (bk, ch), vrows in chapters_data.items():
        bid = BOOK_ID[bk]
        receipt_file = DATA / "work" / "strongs" / "runs" / run_tag / f"{bk}.{ch}.json"
        if resume and receipt_file.exists():
            saved = json.loads(receipt_file.read_text(encoding="utf-8"))
            if saved.get("rules_hash") == RULES_HASH:
                reconciled_total += int(saved.get("stats", {}).get("reconciled_count", 0))
                for v_str, llist in saved["verses"].items():
                    v_int = int(v_str)
                    for item in llist:
                        total_words += 1
                        conf_totals[item["conf"]] += 1
                        for r in ("head", "aux", "added"):
                            if r in item["flags"].split(","):
                                role_totals[r] += 1
                                break
                        db_rows.append((
                            bid,
                            ch,
                            v_int,
                            int(item["w"]),
                            item["ref"],
                            item["strong"],
                            int(item["conf"]),
                            item["flags"],
                            item["source"],
                        ))
                continue

        chapter_verses: dict[int, list[WordLink]] = {}
        chapter_cands: dict[int, list[OrigCand]] = {}

        for v, words, wspans in vrows:
            cands = get_verse_candidates(orig_index, verse_map, bid, ch, v)
            chapter_cands[v] = cands
            if mode == "assisted":
                vlinks = align_verse_assisted(bid, words, wspans, cands, priors)
            else:
                vlinks = align_verse_blind(bid, words, cands, priors)
            vlinks = resolve_polysemy_and_review(bid, vlinks, cands, priors, valid_lex_keys)
            chapter_verses[v] = vlinks

        chapter_verses, rec_changes = reconcile_chapter(bk, ch, chapter_verses, chapter_cands)
        reconciled_total += len(rec_changes)
        write_chapter_receipt(run_tag, bk, ch, mode, chapter_verses, rec_changes)

        for v in sorted(chapter_verses):
            for l in chapter_verses[v]:
                total_words += 1
                conf_totals[l.conf] += 1
                role_totals[l.role] += 1
                db_rows.append((
                    bid,
                    ch,
                    v,
                    l.word_idx,
                    " ".join(l.refs),
                    " ".join(l.dstrongs),
                    l.conf,
                    ",".join(l.flags),
                    l.source,
                ))

    write_layer_sb(
        out_sb,
        target_id=meta["target_id"],
        target_hash=meta["target_hash"],
        tokenizer=meta["tokenizer"],
        versification=meta["versification"],
        mode=mode,
        rows=db_rows,
    )
    elapsed = time.time() - t0
    summary = {
        "target_id": target_id,
        "mode": mode,
        "out_sb": str(out_sb),
        "total_words": total_words,
        "conf_hist": dict(sorted(conf_totals.items(), reverse=True)),
        "role_hist": dict(role_totals),
        "reconciled_total": reconciled_total,
        "elapsed_sec": round(elapsed, 1),
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return summary


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--module", required=True, help="Path to target .sb module")
    ap.add_argument("--mode", choices=["assisted", "blind"], default="assisted")
    ap.add_argument("--out", default=None)
    ap.add_argument("--resume", action="store_true")
    args = ap.parse_args()
    run_pipeline(
        pathlib.Path(args.module),
        mode=args.mode,
        out_sb=pathlib.Path(args.out) if args.out else None,
        resume=args.resume,
    )


if __name__ == "__main__":
    main()
