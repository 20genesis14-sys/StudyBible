"""Фаза 8 (Шаг 4 / 8.4): Пополнение графа знаний `knowledge.sb` синодальными
(`kind='synodal'`) и современными (`kind='biblical'`) русскими формами имён
из слоёв `russyn-strongs.sb` и `ru_rlob-strongs.sb` и словаря `strongs-step-ru.sb`.
"""
from __future__ import annotations

import collections
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "tools" / "strongs" / "pipeline"))
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))

from build_ru_layers import AUX_RU_WORDS, tokenize_module  # noqa: E402
from priors import norm_classic  # noqa: E402


def collect_layer_capitalized_names(
    module_sb: pathlib.Path,
    layer_sb: pathlib.Path,
) -> dict[str, collections.Counter]:
    """Возвращает {dStrong_or_classic: Counter({СловоСЗаглавной: count})}."""
    _meta, verses = tokenize_module(module_sb)
    word_by_coord: dict[tuple[int, int, int, int], str] = {}
    for (bid, ch, v), (ws, _) in verses.items():
        for idx, w in enumerate(ws):
            # Берём слова с заглавной буквы, не стоящие на позиции 0 в стихе (чтобы отсечь обычные слова в начале предложения)
            if idx > 0 and len(w) >= 3 and w[0].isupper() and w.lower() not in AUX_RU_WORDS:
                word_by_coord[(bid, ch, v, idx)] = w

    lay_db = sqlite3.connect(layer_sb)
    out: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for bid, ch, v, w_idx, st_s, conf in lay_db.execute(
        "SELECT book_id, chapter, verse, word, strong, conf FROM links WHERE strong != '' AND conf >= 9"
    ):
        w = word_by_coord.get((bid, ch, v, w_idx))
        if not w:
            continue
        for d in st_s.split():
            if d.startswith("H9") or d in ("H0853", "G3588"):
                continue
            out[d][w] += 1
            cl = norm_classic(d)
            if cl:
                out[cl][w] += 1
    return out


def pick_nominative_ru(ctr: collections.Counter) -> str | None:
    """Выбирает наиболее вероятную начальную форму имени (предпочитая именительный падеж без косвенных окончаний -а/-у/-ом/-е при наличии основы)."""
    if not ctr:
        return None
    top = ctr.most_common(6)
    candidates = [w for w, c in top if c >= max(1, top[0][1] // 4)]
    # Если среди частых форм есть форма без косвенных падежных окончаний (-ом, -ем, -ам, -ям, -ах, -ях, -у, -ю), предпочитаем её
    obl_endings = ("ом", "ем", "ою", "ею", "ам", "ям", "ами", "ями", "ах", "ях", "ов", "ев")
    clean = [w for w in candidates if not w.lower().endswith(obl_endings)]
    return clean[0] if clean else candidates[0]


def main() -> None:
    syn_names = collect_layer_capitalized_names(
        DATA / "modules" / "russyn.sb",
        DATA / "work" / "strongs" / "layers" / "russyn-strongs.sb",
    )
    rlob_names = collect_layer_capitalized_names(
        DATA / "modules" / "ru_rlob.sb",
        DATA / "work" / "strongs" / "layers" / "ru_rlob-strongs.sb",
    )

    know_sb = DATA / "work" / "strongs" / "knowledge" / "knowledge.sb"
    db = sqlite3.connect(know_sb)

    existing: set[tuple[str, str]] = set()
    for eid, nm in db.execute("SELECT entity_id, name FROM entity_names WHERE lang IN ('ru', 'rus')"):
        existing.add((eid, nm.lower()))

    new_rows: list[tuple[str, str, str, str]] = []
    for eid, st_raw in db.execute("SELECT id, strongs FROM entities WHERE strongs != ''"):
        codes = re.findall(r"[HG]\d+[A-Za-z]?", st_raw)
        syn_ctr: collections.Counter = collections.Counter()
        mod_ctr: collections.Counter = collections.Counter()
        for c in codes:
            cl = norm_classic(c) or c
            syn_ctr.update(syn_names.get(c, {}))
            syn_ctr.update(syn_names.get(cl, {}))
            mod_ctr.update(rlob_names.get(c, {}))
            mod_ctr.update(rlob_names.get(cl, {}))

        syn_form = pick_nominative_ru(syn_ctr)
        if syn_form and (eid, syn_form.lower()) not in existing:
            existing.add((eid, syn_form.lower()))
            new_rows.append((eid, syn_form, "ru", "synodal"))

        mod_form = pick_nominative_ru(mod_ctr)
        if mod_form and (eid, mod_form.lower()) not in existing:
            existing.add((eid, mod_form.lower()))
            new_rows.append((eid, mod_form, "ru", "biblical"))

    if new_rows:
        db.executemany("INSERT OR IGNORE INTO entity_names VALUES (?,?,?,?)", new_rows)
        db.commit()
    db.execute("ANALYZE")
    db.commit()
    db.close()

    cli = REPO / "target" / "debug" / "studybible.exe"
    subprocess.run([str(cli), "module", "check", str(know_sb)], check=True)
    subprocess.run([str(cli), "module", "pack", str(know_sb)], check=True)
    sbz_src = know_sb.with_suffix(".sbz")
    sbz_dst = DATA / "modules" / "knowledge.sbz"
    sbz_dst.write_bytes(sbz_src.read_bytes())
    print(f"Added {len(new_rows)} Russian entity names into {know_sb} & updated {sbz_dst}")


if __name__ == "__main__":
    main()
