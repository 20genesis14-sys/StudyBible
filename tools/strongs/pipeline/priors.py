"""Фаза 6 (Шаг 1): Построение таблиц замен номеров форм (form_alias) и
вероятностного словаря соответствий P(dStrong | word, testament) строго
на РАБОЧИХ книгах (без отложенной выборки §4.2 HANDOFF).

Отложенные книги (held-out, §4.2):
  - RUT (вся), JON (вся), EZR (вся)
  - PSA 1..41, ISA 40..55
  - MRK (вся), PHP (вся), JAS (вся), REV 1..5
Ни один стих из отложенных книг не входит в priors_en.json.
"""
from __future__ import annotations

import collections
import json
import os
import pathlib
import re
import sqlite3
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[3]
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))
SRC = DATA / "sources" / "strongs"
STEP_LEX = SRC / "stepbible" / "Lexicons"
WORK_PIPE = DATA / "work" / "strongs" / "pipeline"

BOOKS_ORDER = [
    "GEN", "EXO", "LEV", "NUM", "DEU", "JOS", "JDG", "RUT", "1SA", "2SA",
    "1KI", "2KI", "1CH", "2CH", "EZR", "NEH", "EST", "JOB", "PSA", "PRO",
    "ECC", "SNG", "ISA", "JER", "LAM", "EZK", "DAN", "HOS", "JOL", "AMO",
    "OBA", "JON", "MIC", "NAM", "HAB", "ZEP", "HAG", "ZEC", "MAL",
    "MAT", "MRK", "LUK", "JHN", "ACT", "ROM", "1CO", "2CO", "GAL", "EPH",
    "PHP", "COL", "1TH", "2TH", "1TI", "2TI", "TIT", "PHM", "HEB", "JAS",
    "1PE", "2PE", "1JN", "2JN", "3JN", "JUD", "REV",
]
BOOK_ID = {c: i + 1 for i, c in enumerate(BOOKS_ORDER)}
ID_BOOK = {i + 1: c for i, c in enumerate(BOOKS_ORDER)}


def is_held_out(book_code: str, chapter: int) -> bool:
    """Возвращает True, если глава входит в отложенную выборку (§4.2 HANDOFF)."""
    if book_code in ("RUT", "JON", "EZR", "MRK", "PHP", "JAS"):
        return True
    if book_code == "PSA" and 1 <= chapter <= 41:
        return True
    if book_code == "ISA" and 40 <= chapter <= 55:
        return True
    if book_code == "REV" and 1 <= chapter <= 5:
        return True
    return False


def norm_classic(s: str) -> str | None:
    m = re.match(r"^([HG])0*(\d+)", s.strip())
    if not m:
        return None
    return f"{m.group(1)}{int(m.group(2)):04d}"


def norm_dstrong(s: str) -> str | None:
    m = re.match(r"^([HG])0*(\d+)([A-Za-z]?)$", s.strip())
    if not m:
        return None
    suf = m.group(3).upper()
    return f"{m.group(1)}{int(m.group(2)):04d}{suf}"


def build_form_alias() -> dict[str, str]:
    """Таблица замен номеров словоформ/орфографических вариантов на базовую лемму."""
    amap: dict[str, str] = {}
    for name in ("TBESH", "TBESG"):
        p = next(STEP_LEX.glob(f"{name}*.txt"))
        with open(p, encoding="utf-8-sig") as f:
            for line in f:
                c = line.rstrip("\n").split("\t")
                if len(c) < 3 or not re.match(r"^[HG]\d", c[0]):
                    continue
                if re.search(r"= a (Form|Spelling) of", c[1]):
                    a = norm_classic(c[0])
                    b = norm_classic(c[2])
                    if a and b and a != b:
                        amap[a] = b
    # Частые варианты KJV (например, H3069 -> H3068, G3588 и др. формы глаголов)
    extra = {
        "H3069": "H3068",  # YHWH (Elohim pointed) -> YHWH
        "G2076": "G1510",  # ἐστίν -> εἰμί
        "G2258": "G1510",  # ἦν -> εἰμί
        "G2071": "G1510",  # ἔσται -> εἰμί
        "G1526": "G1510",  # εἰσίν -> εἰμί
        "G2070": "G1510",  # ἐσμέν -> εἰμί
        "G2075": "G1510",  # ἐστέ -> εἰμί
        "G2077": "G1510",  # ἔστω -> εἰμί
        "G2252": "G1510",  # ἤμην -> εἰμί
        "G2277": "G1510",  # ἦτω -> εἰμί
        "G5607": "G1510",  # ὤν -> εἰμί
        "G2036": "G3004",  # εἶπον -> λέγω
        "G2046": "G3004",  # ἐρῶ -> λέγω
        "G1492": "G3708",  # εἴδω -> ὁράω
    }
    for k, v in extra.items():
        amap.setdefault(k, v)
    return amap


def stem_en(w: str) -> str:
    wl = w.lower()
    if len(wl) <= 3:
        return wl
    if wl.endswith("eth") and len(wl) > 5:
        wl = wl[:-3]
    elif wl.endswith("est") and len(wl) > 5:
        wl = wl[:-3]
    if wl.endswith("ies") and len(wl) > 4:
        return wl[:-3] + "y"
    if wl.endswith("ing") and len(wl) > 5:
        return wl[:-3]
    if wl.endswith("ed") and len(wl) > 4:
        return wl[:-2]
    if wl.endswith("es") and len(wl) > 4:
        return wl[:-2]
    if wl.endswith("s") and not wl.endswith("ss") and len(wl) > 3:
        return wl[:-1]
    return wl


def build_lex_indexes() -> tuple[dict[str, list[str]], dict[str, str]]:
    """Из strongs-step.sb строит:
    - classic_to_dstrongs: {H7225: [H7225G, H7225H, ...]}
    - dstrong_gloss: {H7225G: 'beginning | 1_beginning'}
    """
    db = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb")
    classic_to_ds: dict[str, list[str]] = collections.defaultdict(list)
    dstrong_gloss: dict[str, str] = {}
    for key, base, gloss, sl in db.execute("SELECT key, base, gloss, sense_label FROM lex ORDER BY key"):
        dstrong_gloss[key] = f"{gloss or ''} {sl or ''}".strip()
        cl = norm_classic(key)
        if cl and key not in classic_to_ds[cl]:
            classic_to_ds[cl].append(key)
        if base:
            bcl = norm_classic(base)
            if bcl and key not in classic_to_ds[bcl]:
                classic_to_ds[bcl].append(key)
    for base, key in db.execute("SELECT base, key FROM lex_base ORDER BY key"):
        bcl = norm_classic(base)
        if bcl and key not in classic_to_ds[bcl]:
            classic_to_ds[bcl].append(key)
    return dict(classic_to_ds), dstrong_gloss


def build_word_priors() -> tuple[dict[str, dict[str, list[tuple[str, int]]]], dict[str, dict[str, list[tuple[str, int]]]]]:
    """Строит счётчики:
      - word_priors: (testament -> word_or_stem -> [(dStrong, count), ...])
      - classic_priors: (testament -> word_or_stem -> [(classic, count), ...])
    строго на РАБОЧИХ книгах (все отложенные книги §4.2 исключены!).
    """
    counts: dict[str, dict[str, collections.Counter]] = {
        "OT": collections.defaultdict(collections.Counter),
        "NT": collections.defaultdict(collections.Counter),
    }
    cl_counts: dict[str, dict[str, collections.Counter]] = {
        "OT": collections.defaultdict(collections.Counter),
        "NT": collections.defaultdict(collections.Counter),
    }

    def add_obs(t: str, word: str, dcode: str, weight: int) -> None:
        wl = word.lower()
        st = stem_en(wl)
        counts[t][wl][dcode] += weight
        if st != wl and len(st) >= 3:
            counts[t][f"#{st}"][dcode] += max(1, weight // 2)
        cl = norm_classic(dcode)
        if cl:
            cl_counts[t][wl][cl] += weight
            if st != wl and len(st) >= 3:
                cl_counts[t][f"#{st}"][cl] += max(1, weight // 2)

    # 1. Из engbsb.sb + engbsb-strongs.sb (только рабочие книги!)
    cli = REPO / "target" / "debug" / "studybible.exe"
    bsb_sb = DATA / "modules" / "engbsb.sb"
    lay_sb = DATA / "work" / "strongs" / "layers" / "engbsb-strongs.sb"

    lay_db = sqlite3.connect(lay_sb)
    links_by_bcv: dict[tuple[int, int, int], dict[int, tuple[str, str]]] = collections.defaultdict(dict)
    for bid, ch, v, w, st, fl in lay_db.execute(
        "SELECT book_id, chapter, verse, word, strong, flags FROM links WHERE strong != ''"
    ):
        bk = ID_BOOK.get(bid, "")
        if is_held_out(bk, ch):
            continue
        links_by_bcv[(bid, ch, v)][w] = (st, fl or "")

    proc = subprocess.Popen(
        [str(cli), "tokenize", str(bsb_sb)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        d = json.loads(line)
        if "_meta" in d:
            continue
        bk = d["book"]
        ch = int(d["chapter"])
        v = int(d["verse"])
        if is_held_out(bk, ch):
            continue
        bid = BOOK_ID[bk]
        t = "OT" if bid < 40 else "NT"
        vlinks = links_by_bcv.get((bid, ch, v))
        if not vlinks:
            continue
        for idx, w in enumerate(d["words"]):
            info = vlinks.get(idx)
            if not info:
                continue
            st, fl = info
            codes = st.split()
            if "head" in fl:
                lex_codes = [c for c in codes if not c.startswith("H9") and c not in ("H0853", "G3588")]
                if lex_codes:
                    codes = lex_codes
            for code in codes:
                weight = 4 if "head" in fl else 1
                add_obs(t, w, code, weight)
    proc.wait()

    # 2. Из KJV (только рабочие книги!)
    kjv_sb = DATA / "modules" / "eng-kjv2006.sb"
    proc_k = subprocess.Popen(
        [str(cli), "tokenize", "--with-spans", str(kjv_sb)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    assert proc_k.stdout is not None
    for line in proc_k.stdout:
        d = json.loads(line)
        if "_meta" in d:
            continue
        bk = d["book"]
        ch = int(d["chapter"])
        if is_held_out(bk, ch):
            continue
        bid = BOOK_ID[bk]
        t = "OT" if bid < 40 else "NT"
        for w, sp in zip(d["words"], d.get("word_spans", [])):
            m = re.findall(r'strong="([^"]+)"', sp.get("attrs", ""))
            for raw in m:
                for tok in raw.split():
                    cl = norm_classic(tok)
                    if cl:
                        wl = w.lower()
                        cl_counts[t][wl][cl] += 2
    proc_k.wait()

    # 3. Из step-orig.sb (контекстные глоссы ТОЛЬКО на рабочих книгах!)
    orig_db = sqlite3.connect(DATA / "work" / "strongs" / "orig" / "step-orig.sb")
    for bid, ch, attrs in orig_db.execute("SELECT book_id, chapter, attrs FROM spans WHERE style='w'"):
        bk = ID_BOOK.get(bid, "")
        if is_held_out(bk, ch):
            continue
        t = "OT" if bid < 40 else "NT"
        m_st = re.search(r'strong="([^"]+)"', attrs)
        m_gr = re.search(r'gr="([^"]+)"', attrs)
        if not m_st or not m_gr:
            continue
        codes = [c for c in m_st.group(1).split() if not c.startswith("H9") and c not in ("H0853", "G3588")]
        if not codes:
            codes = m_st.group(1).split()[:1]
        for gtok in re.findall(r"[A-Za-z]+", m_gr.group(1)):
            if len(gtok) >= 2:
                for code in codes:
                    add_obs(t, gtok, code, 2)

    # 4. Словарные глоссы из strongs-step.sb (не зависят от книг)
    lex_db = sqlite3.connect(DATA / "work" / "strongs" / "lexicon" / "strongs-step.sb")
    for key, gloss, sl in lex_db.execute("SELECT key, gloss, sense_label FROM lex"):
        t = "OT" if key.startswith("H") else "NT"
        for tok in re.findall(r"[A-Za-z]+", f"{gloss or ''} {sl or ''}"):
            if len(tok) >= 2:
                add_obs(t, tok, key, 2)

    out_ds: dict[str, dict[str, list[tuple[str, int]]]] = {"OT": {}, "NT": {}}
    out_cl: dict[str, dict[str, list[tuple[str, int]]]] = {"OT": {}, "NT": {}}
    for t in ("OT", "NT"):
        for wl, ctr in counts[t].items():
            out_ds[t][wl] = ctr.most_common(25)
        for wl, ctr in cl_counts[t].items():
            out_cl[t][wl] = ctr.most_common(25)
    return out_ds, out_cl


def main() -> None:
    WORK_PIPE.mkdir(parents=True, exist_ok=True)
    amap = build_form_alias()
    classic_to_ds, dstrong_gloss = build_lex_indexes()
    word_priors, classic_priors = build_word_priors()

    payload = {
        "form_alias": amap,
        "classic_to_dstrongs": classic_to_ds,
        "dstrong_gloss": dstrong_gloss,
        "word_priors": word_priors,
        "classic_priors": classic_priors,
    }
    out_path = WORK_PIPE / "priors_en.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    print(
        f"Saved {out_path}: form_alias={len(amap)}, "
        f"classic_to_dstrongs={len(classic_to_ds)}, "
        f"OT words={len(word_priors['OT'])}, NT words={len(word_priors['NT'])}"
    )


if __name__ == "__main__":
    main()
