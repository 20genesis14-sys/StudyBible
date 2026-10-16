"""Арбитраж конфликтов rusb-strongs (Aquifer reseat) vs russyn.

Для каждой позиции идентичного стиха с непересекающимися кодами выбирает
сторону по взвешенным уликам:
  supp   — слово в приорах кода (lex=2, stem=1, func=1, none=0);
  pos    — часть речи кода (lex.pos) совместима с русской частью речи;
  func   — для служебного слова код в FUNC_RU_TO_CODES;
  freq   — частота формы в приорах (тай-брейк);
  claim  — штраф, если A-сторона просто повторила исходную (порочную)
           заявку Aquifer: claimed_hit=True снижает доверие к A.

Отладка/калибровка: `--sample N` печатает N случайных решений с глоссами.
"""

import collections
import json
import pathlib
import re
import sqlite3
import sys
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from build_ru_layers import (  # noqa: E402
    AUX_RU_WORDS,
    FUNC_RU_TO_CODES,
    load_orig_with_mid,
    norm_ru,
    stem_ru,
    tokenize_module,
)
import reseat_rusb_layer as R  # noqa: E402

LEX_SB = R.DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb"

# --- POS нормализация ----------------------------------------------------
POS_CLASS = {
    "v": "V", "n": "N", "a": "A", "adv": "ADV", "prep": "PREP",
    "conj": "CONJ", "c": "CONJ", "prt": "PRT", "part": "PRT",
    "neg": "PRT", "inj": "PRT", "intj": "PRT", "relp": "R", "r": "R",
    "demp": "D", "d": "D", "perp": "P", "p": "P", "f": "P", "s": "P",
    "t": "T", "i": "I", "intg": "I", "cond": "COND", "x": "X",
    "q": "PRT", "k": "CONJ", "op": "SFX", "indp": "P",
}


def ds_classes(pos: str) -> set[str]:
    out = set()
    for alt in re.split(r"\s*/\s*|\s*\+\s*", pos):
        alt = alt.strip()
        if ":" not in alt:
            continue
        tag = alt.split(":", 1)[1].split("-")[0].strip().lower()
        if tag:
            out.add(POS_CLASS.get(tag, tag.upper()[:4]))
    if "A" in out and "nui" in pos.lower():
        out.add("NUM")
    return out


def load_lexpos() -> dict[str, set[str]]:
    db = sqlite3.connect(LEX_SB)
    m = {k: ds_classes(p or "") for k, p in db.execute("SELECT key,pos FROM lex")}
    db.close()
    return m


# --- Русская часть речи ---------------------------------------------------
RE_V_INF = re.compile(r"(ть|ти|чь)(ся)?$")
RE_V_PAST = re.compile(r"(л|ла|ло|ли|лся|лась|лось|лись)$")
RE_V_FIN = re.compile(
    r"(ает|яет|ует|ит|ет|ут|ют|ат|ят|ит|ем|им|ишь|ешь|ите|ете|аю|юю|ю|"
    r"ется|ится|утся|ются|ятся|атся|имся|ишься|ешься|итесь|етесь)$"
)
RE_V_BAD = re.compile(r"(ение|ание|ние|тие|ие|ия|мя|ость|есть|ство|ство|ота|"
                      r"ень|оль|ель|дь|ль|нь|ть|рь|вь|жь|шь|щь)$")
RE_ADJ = re.compile(
    r"(ый|ий|ой|ое|ее|ая|яя|ого|его|ому|ему|ым|им|ой|ых|их|ые|ие|ыми|ими|"
    r"ей|ую|юю|ем|ом|ей|им|яя|ьего|ьему|ьим|ьих|ьи|ьем|ью|ья|ье)$"
)
RE_NOUN = re.compile(r"(а|я|о|е|ы|и|ей|ов|ев|ей|ам|ям|ах|ях|ами|ями|ом|ем|у|ю|ей|ью|ь|й)$")
NUM_WORDS = {
    "один", "одна", "одно", "два", "две", "три", "четыре", "пять", "шесть",
    "семь", "восемь", "девять", "десять", "сто", "тысяча", "тысячи",
    "первый", "второй", "третий", "седьмой", "седьмого",
}
FUNC_POS = {  # грубое соответствие aux-слов классам оригинала
    "PREP", "CONJ", "PRT", "P", "R", "D", "T", "I", "COND", "X", "SFX", "N",
}


def ru_pos(word: str) -> set[str]:
    w = word.lower()
    if w in NUM_WORDS:
        return {"NUM"}
    if w in AUX_RU_WORDS or w in FUNC_RU_TO_CODES:
        return FUNC_POS
    if len(w) >= 4 and (RE_V_INF.search(w) or
                        (RE_V_FIN.search(w) and not RE_V_BAD.search(w))):
        return {"V"}
    if len(w) >= 4 and RE_V_PAST.search(w) and not RE_V_BAD.search(w):
        return {"V", "A"}  # причастия/прош. — неоднозначно
    if len(w) >= 4 and RE_ADJ.search(w):
        return {"A", "N"}
    return {"N", "A"}  # умолчание — имя/прил (знаменательное)


def supp_level(word: str, ds_list: list[str], wf, sf) -> int:
    nw = norm_ru(word)
    is_aux = nw in AUX_RU_WORDS or nw in FUNC_RU_TO_CODES
    lvl = 0
    for d in ds_list:
        if nw in wf.get(d, {}):
            lvl = max(lvl, 2)
        elif not is_aux and stem_ru(word) in sf.get(d, ()):
            lvl = max(lvl, 1)
    if lvl == 0 and nw in FUNC_RU_TO_CODES:
        if any(d in FUNC_RU_TO_CODES[nw] or d.startswith("H9") for d in ds_list):
            lvl = 1
    return lvl


def prior_count(word: str, ds_list: list[str], wf) -> float:
    nw = norm_ru(word)
    return max((wf.get(d, {}).get(nw, 0) for d in ds_list), default=0)


def arbitrate(word, dsR, dsA, wf, sf, lexpos, a_claimed):
    """→ ('R'|'A'|'TIE', detail)."""
    wcls = ru_pos(norm_ru(word))
    clsR = set().union(*(lexpos.get(d, set()) for d in dsR)) or {"?"}
    clsA = set().union(*(lexpos.get(d, set()) for d in dsA)) or {"?"}
    sR = supp_level(word, dsR, wf, sf)
    sA = supp_level(word, dsA, wf, sf)
    pmR = bool(clsR & wcls)
    pmA = bool(clsA & wcls)
    score = []
    score.append(4 * sR - 4 * sA)
    score.append(2 * int(pmR) - 2 * int(pmA))
    nw = norm_ru(word)
    fR = nw in FUNC_RU_TO_CODES and any(
        d in FUNC_RU_TO_CODES[nw] for d in dsR)
    fA = nw in FUNC_RU_TO_CODES and any(
        d in FUNC_RU_TO_CODES[nw] for d in dsA)
    score.append(2 * int(fR) - 2 * int(fA))
    # исходная заявка Aquifer подозрительна — небольшой бонус R;
    # если reseat слово переместил, лексическая улика сильнее заявки.
    score.append(0.5 if a_claimed else -0.5)
    cr, ca = prior_count(word, dsR, wf), prior_count(word, dsA, wf)
    score.append(0.5 if cr > ca else (-0.5 if ca > cr else 0.0))
    tot = sum(score)
    if tot > 0:
        return "R", dict(sR=sR, sA=sA, pmR=pmR, pmA=pmA, fR=fR, fA=fA,
                         claimed=a_claimed, tot=tot)
    if tot < 0:
        return "A", dict(sR=sR, sA=sA, pmR=pmR, pmA=pmA, fR=fR, fA=fA,
                         claimed=a_claimed, tot=tot)
    return "TIE", dict(sR=sR, sA=sA, pmR=pmR, pmA=pmA, tot=tot)


def main() -> None:
    import random
    args = [a for a in sys.argv[1:]]
    sample = int(args[0]) if args and args[0].isdigit() else 0
    build = "--build" in args
    _orig, mid_map = load_orig_with_mid()
    _m1, v1 = tokenize_module(R.RUSSYN_SB)
    _m2, v2 = tokenize_module(R.RUSB_SB)
    db = sqlite3.connect(R.RUSB_SB)
    vtext = {(b, c, v): t for b, c, v, t in
             db.execute("select book_id,chapter,verse,text from verses")}
    db.close()
    wf, sf = R.load_priors()
    lexpos = load_lexpos()

    pos2w = {}
    for k, txt in vtext.items():
        wnum, p2w = -1, []
        for tok in R.TOKEN_RE.findall(txt):
            if R.WORD_RE.match(tok):
                wnum += 1
                p2w.append(wnum)
            else:
                p2w.append(None)
        pos2w[k] = p2w

    verse_recs = collections.defaultdict(list)
    z = zipfile.ZipFile(R.ALIGN_ZIP)
    for fn in sorted(z.namelist()):
        if not re.match(r"alignments/\d+\.alignment\.json$", fn):
            continue
        for rec in json.loads(z.read(fn))["records"]:
            ds = []
            for s in rec["source"]:
                hit = mid_map.get(s.split("|")[0])
                if hit:
                    for kk in hit[1]:
                        if kk not in ds:
                            ds.append(kk)
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

    L2, CLAIM, HOW = {}, {}, {}
    for k, recs in verse_recs.items():
        if k not in v2:
            continue
        for widx, claimed, ds, s, how in R.reseat_verse(v2[k][0], recs, wf, sf):
            kk = (k[0], k[1], k[2], widx)
            L2.setdefault(kk, [])
            for d in ds:
                if d not in L2[kk]:
                    L2[kk].append(d)
            CLAIM[kk] = CLAIM.get(kk, False) or (claimed == widx)
            HOW.setdefault(kk, how)

    d1 = sqlite3.connect(R.RUSSYN_LINKS)
    L1 = {(b, c, v, w): (s, cf) for b, c, v, w, s, cf in
          d1.execute("select book_id,chapter,verse,word,strong,conf from links")}

    le = sqlite3.connect(LEX_SB)
    G = {k: (g, p) for k, g, p in le.execute("select key,gloss,pos from lex")}

    def gl(ds):
        return ";".join(f"{d}={G.get(d, ('?', '?'))[0]}/"
                        f"{G.get(d, ('?', '?'))[1]}" for d in ds)

    # ---- финальный слой-консенсус --------------------------------------
    from build_layer import write_layer_sb
    from priors import ID_BOOK
    meta_rusb = _m2
    identical: dict[tuple, list[str]] = {}
    for k, (ws, _sp) in v1.items():
        ws2 = v2.get(k, (None,))[0]
        if ws2 is None or len(ws2) != len(ws):
            continue
        if [norm_ru(x) for x in ws] == [norm_ru(x) for x in ws2]:
            identical[k] = ws2

    wins = collections.Counter()
    ex = []
    rows: dict[tuple, tuple] = {}
    conf_how = {"lex": 9, "stem": 8, "func": 8}
    for k, ws2 in identical.items():
        n = len(ws2)
        for w in range(n):
            kk = (k[0], k[1], k[2], w)
            a = L1.get(kk)
            b = L2.get(kk)
            if a and b:
                sa, sb = set(a[0].split()), set(b)
                if sa == sb or sa & sb:
                    ds = sorted(sa | sb)
                    rows[kk] = (" ".join(ds), 10, "head,consensus")
                else:
                    who, det = arbitrate(
                        ws2[w], a[0].split(), b, wf, sf, lexpos,
                        CLAIM.get(kk, False))
                    wins[who] += 1
                    if len(ex) < 400:
                        ex.append((k, ws2[w], a[0].split(), b, who, det))
                    if who == "R":
                        rows[kk] = (a[0], 9, "head,arb-r")
                    else:  # A и TIE: ds Aquifer — реальный mid стиха
                        rows[kk] = (" ".join(b), 8 if who == "TIE" else 9,
                                    "head,arb-a" if who == "A" else "head,arb-tie")
            elif a:
                rows[kk] = (a[0], min(a[1], 9), "head,russyn-fill")
            elif b:
                rows[kk] = (" ".join(b), conf_how.get(HOW.get(kk), 7),
                            "head,aq-only")
    # неидентичные стихи — только перепосаженный Aquifer
    for kk, ds in L2.items():
        if (kk[0], kk[1], kk[2]) in identical:
            continue
        rows.setdefault(
            kk,
            (" ".join(ds), conf_how.get(HOW.get(kk), 7), "head,aq-only"),
        )

    same = inter = disj = 0
    L2m = {k: v[0] for k, v in rows.items()}
    for k, ws2 in identical.items():
        for w in range(len(ws2)):
            a = L1.get((k[0], k[1], k[2], w))
            b = L2m.get((k[0], k[1], k[2], w))
            if a and b:
                sa, sb = set(a[0].split()), set(b.split())
                if sa == sb:
                    same += 1
                elif sa & sb:
                    inter += 1
                else:
                    disj += 1
    print("wins:", dict(wins))
    print(f"links={len(rows)} agree={same}+{inter}i disj={disj} "
          f"agree%={100 * (same + inter) / max(1, same + inter + disj):.2f}")

    if build:
        out_rows = []
        for (bid, ch, v, widx), (s, cf, fl) in sorted(rows.items()):
            ref = f"{ID_BOOK[bid].title()}.{ch}.{v}#{widx + 1:02d}"
            out_rows.append((bid, ch, v, widx, ref, s, cf, fl,
                            "consensus"))
        write_layer_sb(
            R.OUT, "rusb", meta_rusb["target_hash"], meta_rusb["tokenizer"],
            meta_rusb["versification"], "aquifer-consensus", out_rows,
            meta_overrides={
                "title": "rusb — dStrong layer (Aquifer reseat + russyn consensus)",
                "license": "CC BY-SA 4.0",
                "attribution": (
                    "Clear-Bible Alignments RUSSYN (CC BY-SA 4.0) reseated + "
                    "russyn arbitration; RSB text CC0"),
            })
        print("written", R.OUT)
    if sample:
        random.seed(11)
        random.shuffle(ex)
        for k, wd, ra, aa, who, det in ex[:sample]:
            print(f"{k} {wd!r} -> {who} R:{ra} [{gl(ra)}] A:{aa} "
                  f"[{gl(aa)}] {det}")


if __name__ == "__main__":
    main()
