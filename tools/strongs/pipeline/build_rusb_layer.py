"""Фаза 8.5: сборка слоя rusb-strongs.sb из ручных выравниваний Aquifer.

Источник: sources/strongs/rsb-aquifer/Russian-alignments.zip
  (Clear-Bible/Alignments → RUSSYN; ВЗ: WLCM, НЗ: SBLGNT; CC BY-SA 4.0;
   records process='manual' — ручная пословная разметка).
Целевой модуль: sources/rusb/*.usfm → work/strongs/layers/rusb.sb
  (обновлённая редакция Синодального перевода, CC0).

Формат записи: {"source": ["o010010010012|форм", "n..."], "target":
["01001001002|слово"]}. source-id = mid морфемы step-orig.sb; target-id =
BB CC VVV WWW — позиция в токенизации Aquifer, где токены = слова И
пунктуация (`,` `.` `:` `[` `]` и т.п. считаются токенами, `—` нет,
дефисные слова вида `Иегова-ире` — один токен). Поток реконструируется
из verses.text модуля и сопоставляется с w1-токенами по счёту слов.

Каждой целевой позиции ставится объединение dStrong всех source-mid записи.
Мультитаргетные записи → flags 'head,grp'. conf=10 (ручная разметка).
Промахи mid и словом-позиции протоколируются в report-rusb-layer.json.
"""

import collections
import json
import pathlib
import re
import sqlite3
import sys
import time
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from build_layer import write_layer_sb  # noqa: E402
from build_ru_layers import load_orig_with_mid, norm_ru, tokenize_module  # noqa: E402
from priors import ID_BOOK  # noqa: E402

DATA = pathlib.Path(r"D:/StudyBible-data")
ALIGN_ZIP = DATA / "sources" / "strongs" / "rsb-aquifer" / "Russian-alignments.zip"
RUSB_SB = DATA / "work" / "strongs" / "layers" / "rusb.sb"
OUT = DATA / "work" / "strongs" / "layers" / "rusb-strongs.sb"

TOKEN_RE = re.compile(r"\w+(?:-\w+)*|[^\w\s-]")
WORD_RE = re.compile(r"\w")


def aq_stream(text: str) -> list[str]:
    """Токенизация Aquifer: слова (дефисные слитно) + пунктуация по символу."""
    return TOKEN_RE.findall(text)


def main() -> None:
    t0 = time.time()
    _orig_index, mid_map = load_orig_with_mid()
    meta, verses = tokenize_module(RUSB_SB)
    db = sqlite3.connect(RUSB_SB)
    vtext = {
        (b, c, v): t
        for b, c, v, t in db.execute("SELECT book_id,chapter,verse,text FROM verses")
    }
    db.close()

    # Реконструкция потока Aquifer и маппинг позиции -> w_idx.
    # pos2w[k][pos] = (w_idx | None, токен); проверка: последовательность
    # слов потока должна совпадать с w1-словами стиха.
    pos2w: dict[tuple, list[tuple[int | None, str]]] = {}
    seq_mismatch: list[tuple] = []
    for k, txt in vtext.items():
        wnum = -1
        seq: list[str] = []
        p2w: list[tuple[int | None, str]] = []
        for tok in aq_stream(txt):
            if WORD_RE.match(tok):
                wnum += 1
                seq.append(norm_ru(tok))
                p2w.append((wnum, tok))
            else:
                p2w.append((None, tok))
        pos2w[k] = p2w
        if k in verses and seq != [norm_ru(w) for w in verses[k][0]]:
            seq_mismatch.append(k)

    z = zipfile.ZipFile(ALIGN_ZIP)
    links: dict[tuple, dict] = {}
    miss_mid = collections.Counter()
    word_mismatch = collections.Counter()
    n_rec = n_oor = n_punct = n_nods = 0

    for fn in sorted(z.namelist()):
        if not re.match(r"alignments/\d+\.alignment\.json$", fn):
            continue
        for rec in json.loads(z.read(fn))["records"]:
            n_rec += 1
            ds: list[str] = []
            for s in rec["source"]:
                mid = s.split("|")[0]
                hit = mid_map.get(mid)
                if hit:
                    for kk in hit[1]:
                        if kk not in ds:
                            ds.append(kk)
                else:
                    miss_mid[mid] += 1
            if not ds:
                n_nods += 1
                continue
            grp = len(rec["target"]) > 1
            for t in rec["target"]:
                tid, w = t.split("|")
                k = (int(tid[:2]), int(tid[2:5]), int(tid[5:8]))
                p = int(tid[8:11]) - 1
                p2w = pos2w.get(k)
                if p2w is None or p >= len(p2w):
                    n_oor += 1
                    continue
                widx, tok = p2w[p]
                if widx is None:
                    n_punct += 1
                    continue
                if norm_ru(tok) != norm_ru(w):
                    word_mismatch[f"{tid}|{tok}!={w}"] += 1
                    continue
                slot = links.setdefault((k[0], k[1], k[2], widx), {"ds": [], "grp": False})
                for kk in ds:
                    if kk not in slot["ds"]:
                        slot["ds"].append(kk)
                slot["grp"] = slot["grp"] or grp

    rows = []
    for (bid, ch, v, widx), slot in sorted(links.items()):
        ref = f"{ID_BOOK[bid].title()}.{ch}.{v}#{widx + 1:02d}"
        flags = "head,grp" if slot["grp"] else "head"
        rows.append(
            (bid, ch, v, widx, ref, " ".join(slot["ds"]), 10, flags, "rsb-aq-manual")
        )

    write_layer_sb(
        OUT,
        target_id="rusb",
        target_hash=meta["target_hash"],
        tokenizer=meta["tokenizer"],
        versification=meta["versification"],
        mode="aquifer-manual",
        rows=rows,
        meta_overrides={
            "title": "rusb — dStrong alignment layer (Aquifer manual)",
            "license": "CC BY-SA 4.0",
            "attribution": (
                "Clear-Bible Alignments / Aquifer RUSSYN manual alignments "
                "(CC BY-SA 4.0); RSB text CC0; StudyBible Strong's Pipeline"
            ),
        },
    )

    report = {
        "records": n_rec,
        "records_no_dstrong": n_nods,
        "links": len(rows),
        "miss_mid_tokens": sum(miss_mid.values()),
        "miss_mid_uniq": len(miss_mid),
        "miss_mid_sample": sorted(miss_mid)[:20],
        "tgt_out_of_range": n_oor,
        "tgt_at_punct": n_punct,
        "word_mismatch": dict(word_mismatch),
        "verse_seq_mismatch": seq_mismatch,
        "elapsed_s": round(time.time() - t0, 1),
    }
    rep = OUT.with_suffix(".report.json")
    rep.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
