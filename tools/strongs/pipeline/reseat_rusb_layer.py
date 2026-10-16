"""Фаза 8.5-fix: rusb-strongs — «перепосадка» записей Aquifer, v2.

v1 (жадная посадка): 96.44 % согласия с russyn на идентичных стихах.

v2 — меры точности:
  1. DP-монотонное назначение: записи идут в порядке source-слов
     стиха; целевые позиции в основном монотонны → LCS-подобный DP
     с пропуском записи (цена GAP) вместо жадного перебора.
  2. Полные списки форм: priors_ru (top-8) + corpus-ru из
     strongs-step-ru.sb (полные «слово (частота)» списки обоих
     корпусов) → шире покрытие редких форм.
  3. POS-совместимость: служебные коды (H9xxx/H0853/G3588/предлоги)
     садятся только на служебные слова; знаменательные — на контент.
  4. Бутстрэп: формы, уверенно назначенные (lex) в проходе 1,
     добавляются в приоры перед проходом 2 (EM-стиль).
  5. Оценка: согласие с russyn на идентичных токенах + доля
     самосогласованных связей (форма ∈ priors[ds]).
"""

import collections
import json
import math
import pathlib
import re
import sqlite3
import sys
import time
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from build_layer import write_layer_sb  # noqa: E402
from build_ru_layers import (  # noqa: E402
    AUX_RU_WORDS,
    FUNC_RU_TO_CODES,
    load_orig_with_mid,
    norm_ru,
    stem_ru,
    tokenize_module,
)
from priors import ID_BOOK  # noqa: E402

DATA = pathlib.Path(r"D:/StudyBible-data")
ALIGN_ZIP = DATA / "sources" / "strongs" / "rsb-aquifer" / "Russian-alignments.zip"
RUSB_SB = DATA / "work" / "strongs" / "layers" / "rusb.sb"
RUSSYN_SB = DATA / "modules" / "russyn.sb"
RUSSYN_LINKS = DATA / "work" / "strongs" / "layers" / "russyn-strongs.sb"
LEX_RU_SB = DATA / "work" / "strongs" / "lexicon" / "strongs-step-ru.sb"
OUT = DATA / "work" / "strongs" / "layers" / "rusb-strongs.sb"

TOKEN_RE = re.compile(r"\w+(?:-\w+)*|[^\w\s-]")
WORD_RE = re.compile(r"\w")
FUNC_CODES = {"H0853", "G3588"}

W_LEX = 10.0
W_STEM = 6.0
W_FUNC = 5.0
W_POS = 1.5
DIST_PEN = 0.10
GAP_COST = 1.2


def load_priors() -> tuple[dict[str, dict[str, float]], dict[str, set[str]]]:
    """dstrong -> {форма: вес}; dstrong -> {стемы}."""
    word_forms: dict[str, dict[str, float]] = collections.defaultdict(dict)
    p = json.loads(
        (DATA / "work" / "strongs" / "pipeline" / "priors_ru.json").read_text(encoding="utf-8")
    )
    for bucket in ("dstrong_modern_ru", "dstrong_synodal_ru"):
        for d, lst in p[bucket].items():
            for w, cnt in lst:
                word_forms[d][w] = max(word_forms[d].get(w, 0.0), float(cnt))
    # corpus-ru опробован и отвергнут: полные списки форм (в т.ч. хвост
    # частот) несут ошибки исходных слоёв → согласие падает с 96.4 до 92.7 %.
    # Чистые top-8 приоры priors_ru точнее.
    stem_forms: dict[str, set[str]] = {
        d: {stem_ru(w) for w in forms} for d, forms in word_forms.items()
    }
    return word_forms, stem_forms


def _score(
    i: int, ds: list[str], claimed: int,
    norm: list[str], stems: list[str], is_aux: list[bool],
    word_forms: dict, stem_forms: dict,
) -> tuple[float, str]:
    s = 0.0
    how = ""
    for d in ds:
        wf = word_forms.get(d)
        if wf:
            cnt = wf.get(norm[i])
            if cnt:
                s = max(s, W_LEX + min(math.log1p(cnt), 6.0) / 6.0)
                how = "lex"
            # aux-слова не stem-матчим: «пред» ~ «предал» даёт ложный стем
            elif not is_aux[i] and norm[i] not in FUNC_RU_TO_CODES \
                    and stems[i] in stem_forms.get(d, ()):
                if s < W_STEM:
                    s, how = W_STEM, "stem"
        # служебные коды — только на служебные слова и недалеко от заявки
        if abs(i - claimed) <= 4 and norm[i] in FUNC_RU_TO_CODES and (
            d in FUNC_RU_TO_CODES[norm[i]] or d.startswith("H9")
        ):
            if s < W_FUNC:
                s, how = W_FUNC, "func"
    s -= DIST_PEN * abs(i - claimed)
    return s, how


def reseat_verse(
    words: list[str],
    recs: list[tuple[list[str], int]],
    word_forms: dict,
    stem_forms: dict,
) -> list[tuple[int, int, list[str], float, str]]:
    """Жадное назначение записей на слова стиха (исходная заявка → claimed)."""
    n = len(words)
    m = len(recs)
    if not n or not m:
        return []
    norm = [norm_ru(w) for w in words]
    stems = [stem_ru(w) for w in words]
    is_aux = [w in AUX_RU_WORDS for w in norm]

    # жадное назначение всех пар (запись, слово) по убыванию score:
    # монотонный DP проверен и отвергнут — порядок записей следует
    # порядку исходного текста, а русский порядок слов системно
    # переупорядочен → монотония теряет ~1.5 п.п. точности.
    cand: list[tuple[float, int, int, str]] = []
    for j, (ds, claimed) in enumerate(recs):
        for i in range(n):
            s, how = _score(i, ds, claimed, norm, stems, is_aux, word_forms, stem_forms)
            if s > 0:
                cand.append((s, j, i, how))
    cand.sort(reverse=True)
    used_w: set[int] = set()
    used_r: set[int] = set()
    out: list[tuple[int, int, list[str], float, str]] = []
    for s, j, i, how in cand:
        if j in used_r or i in used_w:
            continue
        used_r.add(j)
        used_w.add(i)
        out.append((i, recs[j][1], recs[j][0], s, how))
    return out


def main() -> None:
    t0 = time.time()
    _orig_index, mid_map = load_orig_with_mid()
    meta, rusb_verses = tokenize_module(RUSB_SB)
    _syn_meta, syn_verses = tokenize_module(RUSSYN_SB)
    db = sqlite3.connect(RUSB_SB)
    vtext = {
        (b, c, v): t
        for b, c, v, t in db.execute("SELECT book_id,chapter,verse,text FROM verses")
    }
    db.close()
    word_forms, stem_forms = load_priors()

    pos2w: dict[tuple, list[int | None]] = {}
    for k, txt in vtext.items():
        wnum = -1
        p2w: list[int | None] = []
        for tok in TOKEN_RE.findall(txt):
            if WORD_RE.match(tok):
                wnum += 1
                p2w.append(wnum)
            else:
                p2w.append(None)
        pos2w[k] = p2w

    verse_recs: dict[tuple, list[tuple[list[str], int]]] = collections.defaultdict(list)
    miss_mid = 0
    n_rec = 0
    z = zipfile.ZipFile(ALIGN_ZIP)
    for fn in sorted(z.namelist()):
        if not re.match(r"alignments/\d+\.alignment\.json$", fn):
            continue
        for rec in json.loads(z.read(fn))["records"]:
            n_rec += 1
            ds: list[str] = []
            for s in rec["source"]:
                hit = mid_map.get(s.split("|")[0])
                if hit:
                    for kk in hit[1]:
                        if kk not in ds:
                            ds.append(kk)
                else:
                    miss_mid += 1
            if not ds:
                continue
            for t in rec["target"]:
                tid = t.split("|")[0]
                k = (int(tid[:2]), int(tid[2:5]), int(tid[5:8]))
                p = int(tid[8:11]) - 1
                p2w = pos2w.get(k)
                widx = p2w[p] if p2w and p < len(p2w) else None
                if widx is not None:
                    verse_recs[k].append((ds, widx))

    def run_pass(wf, sf):
        links: dict[tuple, dict] = {}
        how_cnt = collections.Counter()
        for k, recs in verse_recs.items():
            if k not in rusb_verses:
                continue
            words = rusb_verses[k][0]
            for widx, claimed, ds, s, how in reseat_verse(words, recs, wf, sf):
                how_cnt[how] += 1
                slot = links.setdefault(
                    (k[0], k[1], k[2], widx),
                    {"ds": [], "how": how, "claimed_hit": widx == claimed},
                )
                slot["claimed_hit"] = slot["claimed_hit"] or (widx == claimed)
                for d in ds:
                    if d not in slot["ds"]:
                        slot["ds"].append(d)
        return links, how_cnt

    # бутстрэп-второй проход опробован и отвергнут: единичные
    # наблюдения — самоусиливающийся шум (−3.7 п.п.).
    links, how_cnt = run_pass(word_forms, stem_forms)
    how1 = how_cnt
    boot = 0

    conf_of = {"lex": 10, "stem": 9, "func": 8}
    rows = []
    for (bid, ch, v, widx), slot in sorted(links.items()):
        ref = f"{ID_BOOK[bid].title()}.{ch}.{v}#{widx + 1:02d}"
        rows.append(
            (
                bid, ch, v, widx, ref, " ".join(slot["ds"]),
                conf_of.get(slot["how"], 7), "head", "rsb-aq-reseat",
            )
        )

    write_layer_sb(
        OUT, "rusb", meta["target_hash"], meta["tokenizer"], meta["versification"],
        "aquifer-reseat", rows,
        meta_overrides={
            "title": "rusb — dStrong alignment layer (Aquifer reseated)",
            "license": "CC BY-SA 4.0",
            "attribution": (
                "Clear-Bible Alignments RUSSYN (CC BY-SA 4.0) reseated by "
                "StudyBible priors; RSB text CC0"
            ),
        },
    )

    # оценка vs russyn
    syn_db = sqlite3.connect(RUSSYN_LINKS)
    L1 = {
        (b, c, v, w): (s, fl)
        for b, c, v, w, s, fl in syn_db.execute(
            "SELECT book_id,chapter,verse,word,strong,flags FROM links"
        )
    }
    syn_db.close()
    L2 = {(r[0], r[1], r[2], r[3]): (r[5], r[7]) for r in rows}

    same = inter = disjoint = 0
    disj_ex: list = []
    for k, (ws, _sp) in syn_verses.items():
        ws2 = rusb_verses.get(k, (None,))[0]
        if ws2 is None or len(ws2) != len(ws):
            continue
        if [norm_ru(x) for x in ws] != [norm_ru(x) for x in ws2]:
            continue
        for w in range(len(ws)):
            a = L1.get((k[0], k[1], k[2], w))
            b = L2.get((k[0], k[1], k[2], w))
            if a and b:
                sa, sb = set(a[0].split()), set(b[0].split())
                if sa == sb:
                    same += 1
                elif sa & sb:
                    inter += 1
                else:
                    disjoint += 1
                    if len(disj_ex) < 60:
                        disj_ex.append([k[0], k[1], k[2], w, ws[w], a[0], b[0]])

    rep = {
        "records": n_rec,
        "miss_mid": miss_mid,
        "links": len(rows),
        "pass1_how": dict(how1),
        "bootstrap_added": boot,
        "assign_how": dict(how_cnt),
        "agree_same": same,
        "agree_intersect": inter,
        "agree_disjoint": disjoint,
        "agree_pct": round(100 * (same + inter) / max(1, same + inter + disjoint), 2),
        "disjoint_examples": disj_ex,
        "elapsed_s": round(time.time() - t0, 1),
    }
    (OUT.with_suffix(".reseat-report.json")).write_text(
        json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(json.dumps({k: v for k, v in rep.items() if k != "disjoint_examples"}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
