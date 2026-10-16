"""Фаза 8.5-fix: починка слоя rusb-strongs — «перепосадка» записей Aquifer.

Выявлено: в Russian-alignments.zip (Clear-Bible RUSSYN, process='manual')
надёжна source-сторона (какие mid/strong покрыты в стихе и как сгруппированы),
но target-позиции систематически сдвинуты в стихах с переупорядоченными
словами (~50 % семантических промахов против russyn-проекции).

Ремонт: для каждой записи (ds_set, заявленная позиция) целевое слово стиха
ищется заново среди w1-токенов rusb:
  - лексический приор: форма/стем слова в priors_ru (corpus rlob/rob/russyn);
  - служебный приор: слово в FUNC_RU_TO_CODES и ds — соответствующий код;
  - штраф за расстояние от заявленной позиции;
  - жадное назначение по убыванию score, одно слово — одна запись;
  - fallback: запись без кандидата возвращается на заявленную позицию
    (conf 6, source 'rsb-aq-pos') или отбрасывается.

Оценка: согласие с russyn-strongs на стихах с идентичной токенизацией.
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
OUT = DATA / "work" / "strongs" / "layers" / "rusb-strongs.sb"

TOKEN_RE = re.compile(r"\w+(?:-\w+)*|[^\w\s-]")
WORD_RE = re.compile(r"\w")

# веса скоринга
W_LEX = 10.0   # точная форма в приорах (по счётчику)
W_STEM = 6.0   # стем в приорах
W_FUNC = 5.0   # служебное слово совместимо с кодом
DIST_PEN = 0.15  # за каждую позицию от заявленной


def load_priors_ru() -> tuple[dict, dict]:
    p = json.loads(
        (DATA / "work" / "strongs" / "pipeline" / "priors_ru.json").read_text(encoding="utf-8")
    )
    word_forms: dict[str, dict[str, int]] = collections.defaultdict(dict)
    stem_forms: dict[str, set[str]] = collections.defaultdict(set)
    for bucket in ("dstrong_modern_ru", "dstrong_synodal_ru"):
        for d, lst in p[bucket].items():
            for w, cnt in lst:
                word_forms[d][w] = max(word_forms[d].get(w, 0), cnt)
                stem_forms[d].add(stem_ru(w))
    return word_forms, stem_forms


def reseat_verse(
    words: list[str],
    recs: list[tuple[list[str], int]],  # (ds_list, claimed widx)
    word_forms: dict,
    stem_forms: dict,
) -> list[tuple[int, list[str], float, str]]:
    """Возвращает [(widx, ds_list, score, how)] — назначение записей на слова."""
    n = len(words)
    norm = [norm_ru(w) for w in words]
    stems = [stem_ru(w) for w in words]

    def score(i: int, ds: list[str], claimed: int) -> tuple[float, str]:
        s = 0.0
        how = ""
        for d in ds:
            wf = word_forms.get(d, {})
            if norm[i] in wf:
                s = max(s, W_LEX + min(wf[norm[i]], 500) / 500)
                how = "lex"
            elif stems[i] and stems[i] in stem_forms.get(d, ()):
                s = max(s, W_STEM)
                how = "stem"
            # служебные слова ищем только рядом с заявкой: частицы мало
            # перемещаются, а «и» матчится ко всему
            if abs(i - claimed) <= 4 and norm[i] in FUNC_RU_TO_CODES and (
                d in FUNC_RU_TO_CODES[norm[i]] or d.startswith("H9")
            ):
                if s < W_FUNC:
                    s, how = W_FUNC, "func"
        s -= DIST_PEN * abs(i - claimed)
        return s, how

    # все пары (запись, слово) — жадное назначение
    cand: list[tuple[float, int, int, str]] = []
    for j, (ds, claimed) in enumerate(recs):
        for i in range(n):
            s, how = score(i, ds, claimed)
            if s > 0:
                cand.append((s, j, i, how))
    cand.sort(reverse=True)
    used_w: set[int] = set()
    used_r: set[int] = set()
    out: list[tuple[int, list[str], float, str]] = []
    for s, j, i, how in cand:
        if j in used_r or i in used_w:
            continue
        used_r.add(j)
        used_w.add(i)
        out.append((i, recs[j][0], s, how))
    # Неназначенные записи НЕ садим на заявленную позицию: заявка верна лишь
    # в ~42 % случаев — позиционная посадка без лексических доказательств
    # вносит шум (disjoint ~50 %). Такие записи считаем unmapped.
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
    word_forms, stem_forms = load_priors_ru()

    # позиция Aquifer -> w_idx
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

    # записи по стихам
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

    # перепосадка
    links: dict[tuple, dict] = {}
    how_cnt = collections.Counter()
    for k, recs in verse_recs.items():
        if k not in rusb_verses:
            continue
        words = rusb_verses[k][0]
        for widx, ds, s, how in reseat_verse(words, recs, word_forms, stem_forms):
            how_cnt[how] += 1
            slot = links.setdefault((k[0], k[1], k[2], widx), {"ds": [], "how": "lex"})
            for d in ds:
                if d not in slot["ds"]:
                    slot["ds"].append(d)

    conf_of = {"lex": 10, "stem": 9, "func": 8, "pos": 6}
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

    # оценка: согласие с russyn на стихах с идентичной норм-формой токенов
    syn_db = sqlite3.connect(RUSSYN_LINKS)
    L1 = {
        (b, c, v, w): s
        for b, c, v, w, s in syn_db.execute(
            "SELECT book_id,chapter,verse,word,strong FROM links"
        )
    }
    syn_db.close()
    L2 = {(b, c, v, w): s for (b, c, v, w, _r, s, _c, _f, _s) in [
        (r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]) for r in rows]}

    same = inter = disjoint = 0
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
                sa, sb = set(a.split()), set(b.split())
                if sa == sb:
                    same += 1
                elif sa & sb:
                    inter += 1
                else:
                    disjoint += 1

    rep = {
        "records": n_rec,
        "miss_mid": miss_mid,
        "links": len(rows),
        "assign_how": dict(how_cnt),
        "agree_same": same,
        "agree_intersect": inter,
        "agree_disjoint": disjoint,
        "elapsed_s": round(time.time() - t0, 1),
    }
    rep["agree_pct"] = round(100 * (same + inter) / max(1, same + inter + disjoint), 2)
    (OUT.with_suffix(".reseat-report.json")).write_text(
        json.dumps(rep, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print(json.dumps(rep, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
