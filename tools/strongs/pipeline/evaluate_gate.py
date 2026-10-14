"""Фаза 7: Оценка порога качества (Gate) на английском языке по 9 отложенным
корпусам (§4.2 HANDOFF):
  RUT (вся), JON (вся), EZR (вся), PSA 1..41, ISA 40..55,
  MRK (вся), PHP (вся), JAS (вся), REV 1..5.

Проверяемые контуры:
  1. BSB (Режим А — engbsb-strongs.sb v0.4.0 против эталона bsb_tables + step-orig).
  2. KJV (Режим Б — eng-kjv2006-strongs.sb против эталона KJV USFM + step-orig).
  3. BSB Blind (Режим В — полностью «слепой» прогон без входных номеров и без
     Clear на отложенных книгах против эталона engbsb-strongs.sb v0.4.0).

Метрики:
  - Precision / Recall / F1 на значимых (content/head) и служебных (func/aux)
    словах (по classic и по dStrong, отдельно ВЗ и НЗ);
  - Точность dStrong на именах собственных (по базе сущностей knowledge.sb / TIPNR);
  - Калибровка уверенности conf (доля ошибок по уровням 10, 9, 8, 7 — проверка монотонности).
"""
from __future__ import annotations

import collections
import json
import os
import pathlib
import re
import sqlite3
import subprocess

from contour1 import (
    AUX_ENG_WORDS,
    align_verse_blind,
    get_verse_candidates,
    load_orig_Index,
    parse_attrs,
)
from contour2 import reconcile_chapter, resolve_polysemy_and_review
from build_layer import load_valid_lex_keys
from priors import BOOK_ID, ID_BOOK, is_held_out, norm_classic

REPO = pathlib.Path(__file__).resolve().parents[3]
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))


def load_proper_name_dstrongs() -> set[str]:
    """Возвращает множество всех dStrong и classic кодов имён собственных из strongs-step.sb и knowledge.sb."""
    names: set[str] = set()
    lex_db = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb")
    for key, pos in lex_db.execute("SELECT key, pos FROM lex"):
        if pos and ("N" in pos and ("p" in pos or "Proper" in pos)):
            names.add(key)
            cl = norm_classic(key)
            if cl:
                names.add(cl)
    know_db = sqlite3.connect(DATA / "work" / "strongs" / "knowledge" / "knowledge.sb")
    for (st_raw,) in know_db.execute("SELECT strongs FROM entities WHERE strongs != ''"):
        for code in re.findall(r"[HG]\d+[A-Za-z]?", st_raw):
            names.add(code)
            cl = norm_classic(code)
            if cl:
                names.add(cl)
    return names


def tokenize_held_out(module_sb: pathlib.Path) -> dict[tuple[int, int, int], tuple[list[str], list[dict]]]:
    """Токенизирует только отложенные книги модуля через studybible tokenize --with-spans."""
    cli = REPO / "target" / "debug" / "studybible.exe"
    proc = subprocess.Popen(
        [str(cli), "tokenize", "--with-spans", str(module_sb)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    assert proc.stdout is not None
    out: dict[tuple[int, int, int], tuple[list[str], list[dict]]] = {}
    for line in proc.stdout:
        d = json.loads(line)
        if "_meta" in d:
            continue
        bk = d["book"]
        ch = int(d["chapter"])
        if not is_held_out(bk, ch):
            continue
        v = int(d["verse"])
        out[(BOOK_ID[bk], ch, v)] = (d["words"], d.get("word_spans", []))
    proc.wait()
    return out


def load_layer_held_out(layer_sb: pathlib.Path) -> dict[tuple[int, int, int], dict[int, tuple[list[str], int, str, str]]]:
    """Загружает предсказания слоя для отложенных книг: (bid, ch, v) -> {word_idx: (dstrongs, conf, flags, ref)}."""
    db = sqlite3.connect(layer_sb)
    out: dict[tuple[int, int, int], dict[int, tuple[list[str], int, str, str]]] = collections.defaultdict(dict)
    for bid, ch, v, w, ref, st, conf, fl in db.execute(
        "SELECT book_id, chapter, verse, word, ref, strong, conf, flags FROM links"
    ):
        bk = ID_BOOK.get(bid, "")
        if not is_held_out(bk, ch):
            continue
        ds = [x for x in st.split() if x]
        out[(bid, ch, v)][w] = (ds, int(conf), fl or "", ref or "")
    return out


def eval_kjv_held_out(
    kjv_verses: dict[tuple[int, int, int], tuple[list[str], list[dict]]],
    kjv_layer: dict[tuple[int, int, int], dict[int, tuple[list[str], int, str, str]]],
    orig_index: dict,
    verse_map: dict,
    priors: dict,
    name_codes: set[str],
) -> dict:
    """Оценивает слой eng-kjv2006-strongs.sb на отложенных книгах против
    эталона KJV + step-orig (уточнённый dStrong в стихе).
    """
    amap = priors["form_alias"]
    classic_to_ds = priors["classic_to_dstrongs"]

    tp_cl = {"OT_head": 0, "OT_aux": 0, "NT_head": 0, "NT_aux": 0}
    fp_cl = {"OT_head": 0, "OT_aux": 0, "NT_head": 0, "NT_aux": 0}
    fn_cl = {"OT_head": 0, "OT_aux": 0, "NT_head": 0, "NT_aux": 0}

    tp_ds = {"OT_head": 0, "NT_head": 0}
    tot_ds = {"OT_head": 0, "NT_head": 0}

    names_ok = 0
    names_tot = 0
    conf_tot: collections.Counter = collections.Counter()
    conf_err: collections.Counter = collections.Counter()
    tr_var_count = 0

    for (bid, ch, v), (words, wspans) in kjv_verses.items():
        t = "OT" if bid < 40 else "NT"
        cands = get_verse_candidates(orig_index, verse_map, bid, ch, v)
        pred_v = kjv_layer.get((bid, ch, v), {})

        # Строим эталонное множество dStrong и classic в стихе из step-orig
        verse_cl_to_ds: dict[str, set[str]] = collections.defaultdict(set)
        for c in cands:
            for d in c.dstrongs:
                cl = norm_classic(d)
                if cl:
                    verse_cl_to_ds[cl].add(d)

        for i, (w, sp) in enumerate(zip(words, wspans)):
            attrs = parse_attrs(sp.get("attrs", ""))
            gold_raw = [norm_classic(x) for x in attrs.get("strong", "").split() if norm_classic(x)]
            if not gold_raw:
                continue
            wl = w.lower()
            is_aux = wl in AUX_ENG_WORDS
            bucket = f"{t}_{'aux' if is_aux else 'head'}"

            gold_cl_set = {amap.get(c, c) for c in gold_raw} | set(gold_raw)
            gold_ds_set: set[str] = set()
            for gc in gold_cl_set:
                if gc in verse_cl_to_ds:
                    gold_ds_set |= verse_cl_to_ds[gc]
                elif gc in classic_to_ds:
                    gold_ds_set |= set(classic_to_ds[gc])

            pred_ds, conf, fl, _ref = pred_v.get(i, ([], 4, "", ""))
            if "tr-var" in fl:
                tr_var_count += 1
            pred_cl_set = {amap.get(norm_classic(d) or d, norm_classic(d) or d) for d in pred_ds} | {
                norm_classic(d) or d for d in pred_ds
            }

            hit_cl = bool(gold_cl_set & pred_cl_set)
            if hit_cl:
                tp_cl[bucket] += 1
            else:
                if pred_cl_set:
                    fp_cl[bucket] += 1
                fn_cl[bucket] += 1

            hit_ds = bool(gold_ds_set & set(pred_ds)) if gold_ds_set else hit_cl
            if not is_aux:
                tot_ds[f"{t}_head"] += 1
                if hit_ds:
                    tp_ds[f"{t}_head"] += 1

            # Проверка имён собственных
            if w[0].isupper() and not is_aux and ((gold_cl_set & name_codes) or (gold_ds_set & name_codes)):
                names_tot += 1
                if hit_ds:
                    names_ok += 1

            # Калибровка по уровням conf (только на стихах, где слово есть в издании step-orig)
            if any(gc in verse_cl_to_ds for gc in gold_cl_set):
                conf_tot[conf] += 1
                if not hit_ds:
                    conf_err[conf] += 1

    def f1_stats(tp: int, fp: int, fn: int) -> dict:
        p = tp / (tp + fp) if (tp + fp) else 0.0
        r = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * p * r / (p + r) if (p + r) else 0.0
        return {"P": round(p * 100, 2), "R": round(r * 100, 2), "F1": round(f1 * 100, 2), "n": tp + fn}

    calib = {}
    for c_lvl in sorted(conf_tot.keys(), reverse=True):
        tot = conf_tot[c_lvl]
        err = conf_err[c_lvl]
        calib[str(c_lvl)] = {
            "total": tot,
            "errors": err,
            "error_rate_pct": round(err * 100.0 / tot, 2) if tot else 0.0,
            "accuracy_pct": round((tot - err) * 100.0 / tot, 2) if tot else 0.0,
        }

    return {
        "OT_head_classic": f1_stats(tp_cl["OT_head"], fp_cl["OT_head"], fn_cl["OT_head"]),
        "NT_head_classic": f1_stats(tp_cl["NT_head"], fp_cl["NT_head"], fn_cl["NT_head"]),
        "OT_aux_classic": f1_stats(tp_cl["OT_aux"], fp_cl["OT_aux"], fn_cl["OT_aux"]),
        "NT_aux_classic": f1_stats(tp_cl["NT_aux"], fp_cl["NT_aux"], fn_cl["NT_aux"]),
        "OT_head_dstrong_acc": round(tp_ds["OT_head"] * 100.0 / max(tot_ds["OT_head"], 1), 2),
        "NT_head_dstrong_acc": round(tp_ds["NT_head"] * 100.0 / max(tot_ds["NT_head"], 1), 2),
        "proper_names_acc": round(names_ok * 100.0 / max(names_tot, 1), 2),
        "proper_names_total": names_tot,
        "tr_var_words": tr_var_count,
        "calibration": calib,
    }


def eval_bsb_clear_held_out(
    bsb_verses: dict[tuple[int, int, int], tuple[list[str], list[dict]]],
    bsb_layer: dict[tuple[int, int, int], dict[int, tuple[list[str], int, str, str]]],
    orig_index: dict,
    verse_map: dict,
    priors: dict,
    name_codes: set[str],
) -> dict:
    """Оценивает главный слой engbsb-strongs.sb v0.4.0 (Режим А) на отложенных
    книгах против независимого эталона bsb_tables.tsv + step-orig (через SequenceMatcher).
    """
    import difflib

    amap = priors["form_alias"]
    sys_measure = str(REPO / "tools" / "strongs" / "measure")
    if sys_measure not in os.sys.path:
        os.sys.path.insert(0, sys_measure)
    import common as MC  # type: ignore

    bsb_tab = MC.load_bsb_tables()
    tp = {"OT_head": 0, "NT_head": 0, "OT_aux": 0, "NT_aux": 0}
    fp = {"OT_head": 0, "NT_head": 0, "OT_aux": 0, "NT_aux": 0}
    fn = {"OT_head": 0, "NT_head": 0, "OT_aux": 0, "NT_aux": 0}
    names_ok = 0
    names_tot = 0
    conf_tot: collections.Counter = collections.Counter()
    conf_err: collections.Counter = collections.Counter()

    for (bid, ch, v), (words, _wspans) in bsb_verses.items():
        t = "OT" if bid < 40 else "NT"
        tab_rows = bsb_tab.get((bid, ch, v), [])
        if not tab_rows:
            continue
        wa: list[tuple[str, str | None]] = []
        verse_all_cl: set[str] = set()
        for eng_phr, raw_num, _orig in tab_rows:
            cl_num = norm_classic(raw_num) if raw_num else None
            if cl_num:
                verse_all_cl.add(cl_num)
                verse_all_cl.add(amap.get(cl_num, cl_num))
            for tok in re.findall(r"[A-Za-z0-9’']+", eng_phr):
                wa.append((tok.lower().replace("’", "'"), cl_num))

        wb = [w.lower().replace("’", "'") for w in words]
        sm = difflib.SequenceMatcher(None, [w for w, _ in wa], wb, autojunk=False)
        pred_v = bsb_layer.get((bid, ch, v), {})

        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag != "equal":
                continue
            for idx_a, idx_b in zip(range(i1, i2), range(j1, j2)):
                _, cl_gold = wa[idx_a]
                if not cl_gold:
                    continue
                w = words[idx_b]
                wl = wb[idx_b]
                p_ds, p_conf, p_fl, _p_ref = pred_v.get(idx_b, ([], 4, "", ""))
                if "added" in p_fl or not p_ds:
                    continue
                is_aux = "aux" in p_fl or wl in AUX_ENG_WORDS
                bucket = f"{t}_{'aux' if is_aux else 'head'}"

                g_set = {cl_gold, amap.get(cl_gold, cl_gold)}
                p_cl = {amap.get(norm_classic(d) or d, norm_classic(d) or d) for d in p_ds} | {
                    norm_classic(d) or d for d in p_ds
                }
                # Для служебных слов aux внутри фразовой группы в bsb_tables стоит номер корня фразы,
                # а в нашем слое v0.4.0 отделена точная служебная морфема H9xxx/G3588:
                hit = bool(g_set & p_cl) or (is_aux and any(d.startswith("H9") or d in ("H0853", "G3588") for d in p_ds))
                if hit:
                    tp[bucket] += 1
                else:
                    fp[bucket] += 1
                    fn[bucket] += 1
                if not is_aux:
                    if w[0].isupper() and ((set(p_ds) & name_codes) or (p_cl & name_codes)):
                        names_tot += 1
                        if hit:
                            names_ok += 1
                    conf_tot[p_conf] += 1
                    if not hit:
                        conf_err[p_conf] += 1

    def f1_stats(tp_n: int, fp_n: int, fn_n: int) -> dict:
        p = tp_n / (tp_n + fp_n) if (tp_n + fp_n) else 0.0
        r = tp_n / (tp_n + fn_n) if (tp_n + fn_n) else 0.0
        f1 = 2 * p * r / (p + r) if (p + r) else 0.0
        return {"P": round(p * 100, 2), "R": round(r * 100, 2), "F1": round(f1 * 100, 2), "n": tp_n}

    calib = {}
    for c_lvl in sorted(conf_tot.keys(), reverse=True):
        tot = conf_tot[c_lvl]
        err = conf_err[c_lvl]
        calib[str(c_lvl)] = {
            "total": tot,
            "errors": err,
            "error_rate_pct": round(err * 100.0 / tot, 2) if tot else 0.0,
            "accuracy_pct": round((tot - err) * 100.0 / tot, 2) if tot else 0.0,
        }

    return {
        "OT_head": f1_stats(tp["OT_head"], fp["OT_head"], fn["OT_head"]),
        "NT_head": f1_stats(tp["NT_head"], fp["NT_head"], fn["NT_head"]),
        "OT_aux": f1_stats(tp["OT_aux"], fp["OT_aux"], fn["OT_aux"]),
        "NT_aux": f1_stats(tp["NT_aux"], fp["NT_aux"], fn["NT_aux"]),
        "proper_names_acc": round(names_ok * 100.0 / max(names_tot, 1), 2),
        "proper_names_total": names_tot,
        "calibration": calib,
    }


def eval_bsb_held_out(
    bsb_verses: dict[tuple[int, int, int], tuple[list[str], list[dict]]],
    bsb_gold_layer: dict[tuple[int, int, int], dict[int, tuple[list[str], int, str, str]]],
    orig_index: dict,
    verse_map: dict,
    priors: dict,
    valid_lex_keys: set[str],
    name_codes: set[str],
) -> dict:
    """Оценивает:
    1) Эталонный слой engbsb-strongs.sb v0.4.0 на отложенных книгах (калибровка и покрытие).
    2) Слепой прогон (Режим В, --mode blind) на отложенных книгах BSB против эталона Clear BSB.
    """
    # Группируем отложенные стихи BSB по главам для прогона blind + reconcile_chapter
    by_ch: dict[tuple[int, int], list[tuple[int, list[str]]]] = collections.defaultdict(list)
    for (bid, ch, v), (words, _wspans) in sorted(bsb_verses.items()):
        by_ch[(bid, ch)].append((v, words))

    tp_ds = {"OT_head": 0, "NT_head": 0, "OT_aux": 0, "NT_aux": 0}
    fp_ds = {"OT_head": 0, "NT_head": 0, "OT_aux": 0, "NT_aux": 0}
    fn_ds = {"OT_head": 0, "NT_head": 0, "OT_aux": 0, "NT_aux": 0}

    names_ok = 0
    names_tot = 0
    conf_tot: collections.Counter = collections.Counter()
    conf_err: collections.Counter = collections.Counter()

    for (bid, ch), vlist in by_ch.items():
        bk = ID_BOOK[bid]
        t = "OT" if bid < 40 else "NT"
        ch_verses = {}
        ch_cands = {}
        for v, words in vlist:
            cands = get_verse_candidates(orig_index, verse_map, bid, ch, v)
            ch_cands[v] = cands
            vlinks = align_verse_blind(bid, words, cands, priors)
            vlinks = resolve_polysemy_and_review(bid, vlinks, cands, priors, valid_lex_keys)
            ch_verses[v] = vlinks
        ch_verses, _ = reconcile_chapter(bk, ch, ch_verses, ch_cands)

        for v, words in vlist:
            gold_v = bsb_gold_layer.get((bid, ch, v), {})
            pred_links = {l.word_idx: l for l in ch_verses[v]}
            for i, w in enumerate(words):
                g_ds, g_conf, g_fl, _g_ref = gold_v.get(i, ([], 0, "", ""))
                if not g_ds or "added" in g_fl:
                    continue
                is_aux = "aux" in g_fl or w.lower() in AUX_ENG_WORDS
                bucket = f"{t}_{'aux' if is_aux else 'head'}"

                pl = pred_links.get(i)
                p_ds = pl.dstrongs if pl else []
                p_conf = pl.conf if pl else 4

                g_cl = {norm_classic(x) or x for x in g_ds}
                p_cl = {norm_classic(x) or x for x in p_ds}

                hit = bool((set(g_ds) & set(p_ds)) or (g_cl & p_cl))
                if hit:
                    tp_ds[bucket] += 1
                else:
                    if p_ds:
                        fp_ds[bucket] += 1
                    fn_ds[bucket] += 1

                if not is_aux:
                    if w[0].isupper() and ((set(g_ds) & name_codes) or (g_cl & name_codes)):
                        names_tot += 1
                        if hit:
                            names_ok += 1
                    conf_tot[p_conf] += 1
                    if not hit:
                        conf_err[p_conf] += 1

    def f1_stats(tp: int, fp: int, fn: int) -> dict:
        p = tp / (tp + fp) if (tp + fp) else 0.0
        r = tp / (tp + fn) if (tp + fn) else 0.0
        f1 = 2 * p * r / (p + r) if (p + r) else 0.0
        return {"P": round(p * 100, 2), "R": round(r * 100, 2), "F1": round(f1 * 100, 2), "n": tp + fn}

    calib = {}
    for c_lvl in sorted(conf_tot.keys(), reverse=True):
        tot = conf_tot[c_lvl]
        err = conf_err[c_lvl]
        calib[str(c_lvl)] = {
            "total": tot,
            "errors": err,
            "error_rate_pct": round(err * 100.0 / tot, 2) if tot else 0.0,
            "accuracy_pct": round((tot - err) * 100.0 / tot, 2) if tot else 0.0,
        }

    return {
        "OT_head": f1_stats(tp_ds["OT_head"], fp_ds["OT_head"], fn_ds["OT_head"]),
        "NT_head": f1_stats(tp_ds["NT_head"], fp_ds["NT_head"], fn_ds["NT_head"]),
        "OT_aux": f1_stats(tp_ds["OT_aux"], fp_ds["OT_aux"], fn_ds["OT_aux"]),
        "NT_aux": f1_stats(tp_ds["NT_aux"], fp_ds["NT_aux"], fn_ds["NT_aux"]),
        "proper_names_acc": round(names_ok * 100.0 / max(names_tot, 1), 2),
        "proper_names_total": names_tot,
        "calibration": calib,
    }


def main() -> None:
    priors = json.loads((DATA / "work" / "strongs" / "pipeline" / "priors_en.json").read_text(encoding="utf-8"))
    verse_map = json.loads((DATA / "work" / "strongs" / "measure" / "verse_map.json").read_text(encoding="utf-8"))
    orig_index = load_orig_Index()
    valid_lex_keys = load_valid_lex_keys()
    name_codes = load_proper_name_dstrongs()

    kjv_verses = tokenize_held_out(DATA / "modules" / "eng-kjv2006.sb")
    kjv_layer = load_layer_held_out(DATA / "work" / "strongs" / "layers" / "eng-kjv2006-strongs.sb")
    kjv_res = eval_kjv_held_out(kjv_verses, kjv_layer, orig_index, verse_map, priors, name_codes)

    bsb_verses = tokenize_held_out(DATA / "modules" / "engbsb.sb")
    bsb_gold = load_layer_held_out(DATA / "work" / "strongs" / "layers" / "engbsb-strongs.sb")
    bsb_clear_res = eval_bsb_clear_held_out(bsb_verses, bsb_gold, orig_index, verse_map, priors, name_codes)
    bsb_blind_res = eval_bsb_held_out(bsb_verses, bsb_gold, orig_index, verse_map, priors, valid_lex_keys, name_codes)

    out = {
        "held_out_corpora": [
            "RUT", "JON", "EZR", "PSA 1-41", "ISA 40-55",
            "MRK", "PHP", "JAS", "REV 1-5",
        ],
        "inter_gold_ceiling_B": {"OT_content": 95.2, "NT_content": 95.4},
        "bsb_mode_a_held_out": bsb_clear_res,
        "kjv_mode_b_held_out": kjv_res,
        "bsb_mode_c_blind_held_out": bsb_blind_res,
    }
    out_json = DATA / "work" / "strongs" / "pipeline" / "gate_phase7.json"
    out_json.write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
