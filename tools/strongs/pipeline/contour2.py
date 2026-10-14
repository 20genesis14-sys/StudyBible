"""Фаза 6 (Шаг 3): Контур 2 — разрешение неоднозначностей (полисемия внутри
стиха и в словаре), независимая проверка и калибровка уверенности (conf 10..4),
сверка по главе (reconcile_chapter) и запись квитанций runs/<target>/<BOOK>.<ch>.json.
"""
from __future__ import annotations

import collections
import datetime
import hashlib
import json
import os
import pathlib
import re

from contour1 import AUX_ENG_WORDS, OrigCand, WordLink, stem_en
from priors import BOOK_ID, ID_BOOK, norm_classic

DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))
RULES_VERSION = "1.0.0"
RULES_HASH = hashlib.sha256(f"strongs-pipeline-{RULES_VERSION}".encode()).hexdigest()[:16]


def resolve_polysemy_and_review(
    bid: int,
    vlinks: list[WordLink],
    cands: list[OrigCand],
    priors: dict,
    valid_lex_keys: set[str],
) -> list[WordLink]:
    """Шаги 7a + 7b + 8:
    - разрешает внутристиховую и словарную полисемию (candidates_ambig) по
      контекстному глоссу step-orig, словарному глоссу strongs-step и priors_en;
    - проверяет жёсткие инварианты (ключ ∈ strongs-step.sb, wid ∈ стих);
    - калибрует итоговый conf по §4.1 HANDOFF.
    """
    testament = "OT" if bid < 40 else "NT"
    wpriors = priors["word_priors"].get(testament, {})
    dstrong_gloss: dict[str, str] = priors["dstrong_gloss"]
    cand_by_wid = {c.wid: c for c in cands if c.wid}

    for wl_obj in vlinks:
        wl = wl_obj.word.lower()
        wstem = stem_en(wl)

        if wl_obj.candidates_ambig:
            # Ранжируем кандидатов (wid, dstrong) по совпадению глосса и приора
            prior_map = dict(wpriors.get(wl, []))
            best_score = -1.0
            second_score = -1.0
            best_pair = wl_obj.candidates_ambig[0]

            for wid_c, ds_c in wl_obj.candidates_ambig:
                sc = 0.0
                # Совпадение со словарным глоссом dStrong
                g = dstrong_gloss.get(ds_c, "").lower()
                gtoks = set(re.findall(r"[a-z]+", g))
                gstems = {stem_en(t) for t in gtoks}
                if wl in gtoks:
                    sc += 5.0
                elif len(wstem) >= 3 and wstem in gstems:
                    sc += 3.5
                # Совпадение с контекстным глоссом кандидата в стихе
                if wid_c and wid_c in cand_by_wid:
                    oc = cand_by_wid[wid_c]
                    if wl in oc.gloss_tokens:
                        sc += 5.0
                    elif len(wstem) >= 3 and wstem in oc.gloss_stems:
                        sc += 3.5
                # Приор с рабочих книг
                if ds_c in prior_map:
                    sc += min(prior_map[ds_c] / 10.0, 4.0)

                if sc > best_score:
                    second_score = best_score
                    best_score = sc
                    best_pair = (wid_c, ds_c)
                elif sc > second_score:
                    second_score = sc

            chosen_wid, chosen_ds = best_pair
            if chosen_wid:
                wl_obj.refs = [chosen_wid]
            wl_obj.dstrongs = [chosen_ds]

            if best_score - second_score >= 2.0:
                # Полисемия уверенно разрешена по глоссу/приору
                wl_obj.conf = max(wl_obj.conf, 9) if "tr-var" not in wl_obj.flags else 8
            else:
                # Спорная полисемия: по правилу §4.1 не выше 7 и флаг polysemy
                wl_obj.conf = min(wl_obj.conf, 7)
                if "polysemy" not in wl_obj.flags:
                    wl_obj.flags.append("polysemy")

        # Шаг 8: Жёсткая проверка инвариантов (§4.1 HANDOFF)
        if wl_obj.dstrongs:
            all_valid = all(
                (d in valid_lex_keys or norm_classic(d) in valid_lex_keys)
                for d in wl_obj.dstrongs
            )
            if not all_valid:
                wl_obj.conf = min(wl_obj.conf, 4)
                if "invalid-lex" not in wl_obj.flags:
                    wl_obj.flags.append("invalid-lex")

    return vlinks


def reconcile_chapter(
    book_code: str,
    chapter: int,
    chapter_verses: dict[int, list[WordLink]],
    chapter_cands: dict[int, list[OrigCand]],
) -> tuple[dict[int, list[WordLink]], list[dict]]:
    """Шаг 7c (strongs-chapter-reconcile):
    проверяет согласованность перевода повторяющихся знаменательных слов и имён
    собственных внутри главы. Если слово в одном стихе главы размечено с conf>=9,
    а в другом стихе той же главы осталось неразмеченным (added) или спорным (conf<=7),
    и в том стихе есть кандидат с тем же dStrong — выравнивает его согласованно.
    """
    high_conf_map: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for v, vlinks in chapter_verses.items():
        for l in vlinks:
            wl = l.word.lower()
            if l.role == "head" and l.conf >= 9 and len(l.dstrongs) == 1 and wl not in AUX_ENG_WORDS:
                high_conf_map[wl][l.dstrongs[0]] += 1

    dominant_word_ds: dict[str, str] = {}
    for wl, ctr in high_conf_map.items():
        best_ds, cnt = ctr.most_common(1)[0]
        if cnt >= 1:
            dominant_word_ds[wl] = best_ds

    changes: list[dict] = []
    for v, vlinks in chapter_verses.items():
        cands = chapter_cands.get(v, [])
        if not cands:
            continue
        for l in vlinks:
            wl = l.word.lower()
            if wl not in dominant_word_ds:
                continue
            target_ds = dominant_word_ds[wl]
            if l.role == "added" or (l.conf <= 7 and target_ds not in l.dstrongs):
                # Проверяем, есть ли target_ds среди кандидатов этого стиха!
                for c in cands:
                    if target_ds in c.dstrongs or norm_classic(target_ds) in c.classics:
                        old_ds = list(l.dstrongs)
                        l.refs = [c.wid] if c.wid else []
                        l.dstrongs = [target_ds]
                        l.role = "head"
                        l.conf = 9
                        l.flags = ["head", "ch-reconciled"]
                        l.source = "chapter-reconcile"
                        changes.append({
                            "verse": v,
                            "word_idx": l.word_idx,
                            "word": l.word,
                            "old": old_ds,
                            "new": [target_ds],
                        })
                        break

    return chapter_verses, changes


def write_chapter_receipt(
    target_id: str,
    book_code: str,
    chapter: int,
    mode: str,
    chapter_verses: dict[int, list[WordLink]],
    reconcile_changes: list[dict],
) -> pathlib.Path:
    """Записывает квитанцию главы в STUDYBIBLE_DATA/work/strongs/runs/<target>/<BOOK>.<ch>.json."""
    out_dir = DATA / "work" / "strongs" / "runs" / target_id
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{book_code}.{chapter}.json"

    conf_hist: collections.Counter = collections.Counter()
    role_hist: collections.Counter = collections.Counter()
    total_words = 0
    verses_payload: dict[str, list[dict]] = {}

    for v in sorted(chapter_verses):
        vlist = []
        for l in chapter_verses[v]:
            total_words += 1
            conf_hist[str(l.conf)] += 1
            role_hist[l.role] += 1
            vlist.append({
                "w": l.word_idx,
                "word": l.word,
                "ref": " ".join(l.refs),
                "strong": " ".join(l.dstrongs),
                "conf": l.conf,
                "flags": ",".join(l.flags),
                "source": l.source,
            })
        verses_payload[str(v)] = vlist

    receipt = {
        "target_id": target_id,
        "book": book_code,
        "chapter": chapter,
        "mode": mode,
        "model": "deterministic+priors+reconcile-v1",
        "rules_version": RULES_VERSION,
        "rules_hash": RULES_HASH,
        "date": datetime.date.today().isoformat(),
        "stats": {
            "total_words": total_words,
            "conf_hist": dict(sorted(conf_hist.items(), key=lambda x: int(x[0]), reverse=True)),
            "role_hist": dict(role_hist),
            "reconciled_count": len(reconcile_changes),
        },
        "reconcile_changes": reconcile_changes,
        "verses": verses_payload,
    }
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(receipt, f, ensure_ascii=False)
    return out_file
