"""Фаза 8 (Шаг 2 / 8.3): Построение русских приоров priors_ru.json и сборка
трёх накладных слоёв dStrong для русских переводов:
  1. russyn-strongs.sb / .sbz (для Синодального перевода russyn.sb, 66 книг)
  2. ru_rlob-strongs.sb / .sbz (для Русской дословной открытой Библии ru_rlob.sb, 31 книга)
  3. ru_rob-strongs.sb / .sbz (для Русской открытой Библии ru_rob.sb, все 66 книг)
"""
from __future__ import annotations

import collections
import difflib
import hashlib
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import time
import zipfile

from build_layer import SCHEMA_SQL, load_valid_lex_keys, write_layer_sb
from contour1 import OrigCand, parse_attrs
from priors import BOOK_ID, ID_BOOK, norm_classic

REPO = pathlib.Path(__file__).resolve().parents[3]
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))

AUX_RU_WORDS = {
    "в", "во", "на", "над", "под", "за", "из", "изо", "от", "ото", "с", "со",
    "к", "ко", "у", "о", "об", "обо", "по", "при", "про", "без", "безо",
    "для", "до", "через", "чрез", "пред", "предо", "перед", "передо", "между",
    "меж", "среди", "средь", "около", "вокруг", "против", "ради", "сквозь",
    "и", "а", "но", "да", "или", "либо", "ни", "не", "же", "ж", "бы", "б",
    "ли", "ль", "то", "как", "так", "что", "чтобы", "чтоб", "если", "когда",
    "ибо", "потому", "посему", "оттого", "затем", "хотя", "пусть", "пускай",
    "вот", "се", "это", "то", "сей", "сия", "сие", "сии", "сего", "сему",
    "сим", "сих", "тот", "та", "те", "того", "тому", "тем", "тех", "этот",
    "эта", "эти", "этого", "этому", "этим", "этих", "оный", "оная", "оное",
    "я", "меня", "мне", "мною", "мной", "мы", "нас", "нам", "нами",
    "ты", "тебя", "тебе", "тобою", "тобой", "вы", "вас", "вам", "вами",
    "он", "его", "него", "ему", "нему", "им", "ним", "нем", "она", "ее",
    "её", "нее", "неё", "ей", "ней", "ею", "нею", "оно", "они", "их", "них",
    "ими", "ними", "себя", "себе", "собою", "собой",
    "мой", "моя", "мое", "моё", "мои", "моего", "моей", "моему", "моим",
    "моих", "моими", "твой", "твоя", "твое", "твоё", "твои", "твоего",
    "твоей", "твоему", "твоим", "твоих", "твоими", "свой", "своя", "свое",
    "своё", "свои", "своего", "своей", "своему", "своим", "своих", "своими",
    "наш", "наша", "наше", "наши", "нашего", "нашей", "нашему", "нашим",
    "наших", "нашими", "ваш", "ваша", "ваше", "ваши", "вашего", "вашей",
    "вашему", "вашим", "ваших", "вашими",
    "кто", "кого", "кому", "кем", "чем", "चём", "который", "которая",
    "которое", "которые", "которого", "которой", "которому", "которым",
    "которых", "которыми", "чей", "чья", "чье", "чьи",
    "был", "была", "было", "были", "будет", "будут", "буду", "будешь",
    "будем", "будете", "будь", "будьте", "есть", "суть", "быть",
}

FUNC_RU_TO_CODES: dict[str, list[str]] = {
    "и": ["H9002", "G2532", "G1161", "G5037", "H0853"],
    "а": ["H9002", "G1161", "G2532"],
    "же": ["G1161", "H9002", "G3767"],
    "но": ["G0235", "G1161", "H3588", "H9002"],
    "в": ["H9003", "G1722", "G1519"],
    "во": ["H9003", "G1722", "G1519"],
    "на": ["H5921", "H9003", "G1909", "G1519"],
    "над": ["H5921", "G1909", "G5228"],
    "к": ["H9005", "H0413", "G4314", "G1519"],
    "ко": ["H9005", "H0413", "G4314", "G1519"],
    "для": ["H9005", "G1519", "G5228"],
    "по": ["H9005", "H9004", "G2596"],
    "у": ["H9005", "G4314", "G3844"],
    "от": ["H9006", "H4480", "G0575", "G1537"],
    "ото": ["H9006", "H4480", "G0575"],
    "из": ["H9006", "H4480", "G1537", "G0575"],
    "изо": ["H9006", "H4480", "G1537"],
    "с": ["H0854", "H5973", "H9003", "G3326", "G4862"],
    "со": ["H0854", "H5973", "H9003", "G3326", "G4862"],
    "как": ["H9004", "G5613", "G2531"],
    "не": ["H3808", "H0408", "G3756", "G3361"],
    "ни": ["H3808", "G3761", "G3366"],
    "что": ["H3588", "H9007", "H0834", "G3754", "G3739"],
    "чтобы": ["H9005", "G2443", "G3704"],
    "который": ["H0834", "H9007", "G3739", "G3588"],
    "которая": ["H0834", "H9007", "G3739", "G3588"],
    "которое": ["H0834", "H9007", "G3739", "G3588"],
    "которые": ["H0834", "H9007", "G3739", "G3588"],
    "ибо": ["H3588", "G1063", "G3754"],
    "мой": ["H9020", "G1473", "G3450", "G1699"],
    "моя": ["H9020", "G1473", "G3450", "G1699"],
    "мое": ["H9020", "G1473", "G3450", "G1699"],
    "мои": ["H9020", "G1473", "G3450", "G1699"],
    "мне": ["H9020", "H9032", "G1473", "G3427"],
    "меня": ["H9020", "H9032", "G1473", "G3165"],
    "твой": ["H9022", "G4771", "G4675"],
    "твоя": ["H9022", "G4771", "G4675"],
    "твое": ["H9022", "G4771", "G4675"],
    "твои": ["H9022", "G4771", "G4675"],
    "тебе": ["H9022", "G4771", "G4671"],
    "тебя": ["H9022", "G4771", "G4571"],
    "его": ["H9023", "H9036", "G0846"],
    "ему": ["H9023", "G0846"],
    "им": ["H9025", "H9023", "G0846"],
    "их": ["H9025", "H9038", "G0846"],
    "они": ["H1992", "G0846"],
    "мы": ["H0587", "G2249", "G1473"],
    "нас": ["H9021", "H9033", "G2248", "G1473"],
    "нам": ["H9021", "G2254", "G1473"],
    "вы": ["H0859", "G5210", "G4771"],
    "вас": ["H9027", "G5209", "G5216", "G4771"],
    "вам": ["H9027", "G5213", "G4771"],
}

_RU_ENDINGS = (
    "иями", "ями", "ами", "ого", "его", "ому", "ему", "ыми", "ими",
    "ать", "ять", "ить", "еть", "уть", "ють", "ают", "яют", "или", "али", "ели",
    "ешь", "ишь", "ете", "ите", "вши", "ющий", "ащий", "ящий", "вший",
    "ость", "ение", "ание", "ою", "ею", "ой", "ей", "ом", "ем", "ам", "ям",
    "ах", "ях", "ов", "ев", "ий", "ый", "ая", "яя", "ое", "ее", "ые", "ие",
    "ал", "ял", "ил", "ел", "ла", "ло", "ли", "ть", "ти", "ся", "сь",
    "а", "я", "о", "е", "ы", "и", "у", "ю", "ь",
)


def norm_ru(w: str) -> str:
    return w.lower().replace("ё", "е").strip()


def stem_ru(w: str) -> str:
    wl = norm_ru(w)
    if len(wl) <= 3:
        return wl
    for end in _RU_ENDINGS:
        if wl.endswith(end) and len(wl) - len(end) >= 3:
            return wl[: -len(end)]
    return wl


def load_orig_with_mid() -> tuple[
    dict[tuple[int, int, int], list[OrigCand]],
    dict[str, tuple[str, list[str]]],
]:
    """Загружает step-orig.sb:
    1) по (book_id, chapter, verse) -> [OrigCand]
    2) по mid ('o010010010012') -> (wid, [dStrong])
    """
    db = sqlite3.connect(DATA / "work" / "strongs" / "orig" / "step-orig.sb")
    verses: dict[tuple[int, int, int], list[OrigCand]] = collections.defaultdict(list)
    mid_map: dict[str, tuple[str, list[str]]] = {}
    for bid, ch, v, seq, text, attrs in db.execute(
        "SELECT book_id, chapter, verse, seq, text, spans.attrs "
        "FROM spans WHERE style='w' ORDER BY book_id, chapter, seq"
    ):
        ad = parse_attrs(attrs)
        wid = ad.get("wid", "")
        st_raw = ad.get("strong", "")
        ds_list = [x for x in st_raw.split() if x]
        cl_list = []
        for d in ds_list:
            c = norm_classic(d)
            if c and c not in cl_list:
                cl_list.append(c)
        for m in ad.get("mid", "").split():
            if m:
                mid_map[m] = (wid, ds_list)
        lst = verses[(bid, ch, v)]
        lst.append(
            OrigCand(
                wid=wid,
                surface=text,
                dstrongs=ds_list,
                classics=cl_list,
                gloss=ad.get("gr", ""),
                gloss_tokens=set(),
                gloss_stems=set(),
                morph=ad.get("morph", ""),
                sns=ad.get("sns", ""),
                eid=ad.get("eid", ""),
                pos_idx=len(lst),
            )
        )
    return verses, mid_map


def build_rsc_to_eng(verse_map: dict) -> dict[tuple[int, int, int], list[tuple[int, int, int]]]:
    """Строит обратное отображение координат rsc -> список координат eng в step-orig."""
    rsc_to_eng: dict[tuple[int, int, int], list[tuple[int, int, int]]] = collections.defaultdict(list)
    for eng_ref, rsc_list in verse_map.get("eng_to_rsc", {}).items():
        m_e = re.match(r"^([A-Z0-9]+)\.(\d+)\.(\d+)$", eng_ref)
        if not m_e:
            continue
        ebid = BOOK_ID.get(m_e.group(1))
        if not ebid:
            continue
        ech, ev = int(m_e.group(2)), int(m_e.group(3))
        for rsc_ref in rsc_list:
            m_r = re.match(r"^([A-Z0-9]+)\.(\d+)\.(\d+)$", rsc_ref)
            if not m_r:
                continue
            rbid = BOOK_ID.get(m_r.group(1))
            if rbid:
                rch, rv = int(m_r.group(2)), int(m_r.group(3))
                if (ebid, ech, ev) not in rsc_to_eng[(rbid, rch, rv)]:
                    rsc_to_eng[(rbid, rch, rv)].append((ebid, ech, ev))
    return rsc_to_eng


def get_orig_cands_for_verse(
    orig_index: dict[tuple[int, int, int], list[OrigCand]],
    rsc_to_eng: dict[tuple[int, int, int], list[tuple[int, int, int]]],
    versification: str,
    bid: int,
    ch: int,
    v: int,
) -> list[OrigCand]:
    if versification == "rsc":
        targets = rsc_to_eng.get((bid, ch, v), [(bid, ch, v)])
    else:
        targets = [(bid, ch, v)]
    out: list[OrigCand] = []
    for tbid, tch, tv in targets:
        # В Псалмах стих 1 в Синодальном часто включает надписание стиха 0 из step-orig
        if tbid == 19 and tv == 1 and (19, tch, 0) in orig_index:
            out.extend(orig_index[(19, tch, 0)])
        out.extend(orig_index.get((tbid, tch, tv), []))
    if not out and (bid, ch, v) in orig_index:
        out = list(orig_index[(bid, ch, v)])
    # Перенумеруем pos_idx по порядку
    res: list[OrigCand] = []
    for idx, c in enumerate(out):
        cp = OrigCand(
            wid=c.wid,
            surface=c.surface,
            dstrongs=c.dstrongs,
            classics=c.classics,
            gloss=c.gloss,
            gloss_tokens=c.gloss_tokens,
            gloss_stems=c.gloss_stems,
            morph=c.morph,
            sns=c.sns,
            eid=c.eid,
            pos_idx=idx,
        )
        res.append(cp)
    return res


def tokenize_module(module_sb: pathlib.Path) -> tuple[dict, dict[tuple[int, int, int], tuple[list[str], list[dict]]]]:
    cli = REPO / "target" / "debug" / "studybible.exe"
    proc = subprocess.Popen(
        [str(cli), "tokenize", "--with-spans", str(module_sb)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )
    assert proc.stdout is not None
    meta: dict = {}
    verses: dict[tuple[int, int, int], tuple[list[str], list[dict]]] = {}
    for line in proc.stdout:
        d = json.loads(line)
        if "_meta" in d:
            meta = d["_meta"]
            continue
        bid = BOOK_ID[d["book"]]
        ch = int(d["chapter"])
        v = int(d["verse"])
        verses[(bid, ch, v)] = (d["words"], d.get("word_spans", []))
    proc.wait()
    return meta, verses


def lexical_only(ds_list: list[str]) -> list[str]:
    lex = [d for d in ds_list if not d.startswith("H9") and d not in ("H0853", "G3588")]
    return lex if lex else ds_list


def align_tagged_ru_verse(
    words: list[str],
    wspans: list[dict],
    cands: list[OrigCand],
    amap: dict[str, str],
    classic_to_ds: dict[str, list[str]],
    word_priors_ru: dict[str, collections.Counter],
    stem_priors_ru: dict[str, collections.Counter],
) -> list[tuple[int, str, str, int, str, str]]:
    """Выравнивает стих русского модуля со встроенными strong-атрибутами (ru_rlob, ru_rob, rsts-проекция),
    поднимая классические номера до dStrong и wid стиха step-orig и расщепляя фразовые группы на head/aux.
    Возвращает список (word_idx, ref_str, strong_str, conf, flags_str, source_str).
    """
    N = max(len(words), 1)
    M = max(len(cands), 1)

    cl_in_verse: dict[str, list[tuple[OrigCand, str]]] = collections.defaultdict(list)
    for c in cands:
        for d in c.dstrongs:
            cl = norm_classic(d)
            if cl:
                cl_in_verse[cl].append((c, d))

    out: list[tuple[int, str, str, int, str, str] | None] = [None] * len(words)
    used_cands: set[int] = set()

    # Проход 1: слова с явными кодами strong в wspans
    for i, (w, sp) in enumerate(zip(words, wspans)):
        wl = norm_ru(w)
        style = sp.get("style", "")
        attrs = parse_attrs(sp.get("attrs", ""))
        st_raw = attrs.get("strong", "").strip()
        if not st_raw and style == "add":
            out[i] = (i, "", "", 10, "added,aux", "w1-add-tag")
            continue
        if not st_raw:
            continue

        raw_tokens = [x.strip() for x in st_raw.split() if x.strip() and x.strip() != "H0"]
        if not raw_tokens:
            continue

        is_aux_word = wl in AUX_RU_WORDS
        # Если это служебное слово внутри фразовой группы (напр., 'В' с 'H9003 H7225'),
        # оставляем на нём только служебную морфему; а если знаменательное — убираем H9xxx!
        if is_aux_word:
            func_matches = FUNC_RU_TO_CODES.get(wl, [])
            filtered = [t for t in raw_tokens if t in func_matches or norm_classic(t) in func_matches or t.startswith("H9")]
            if filtered:
                raw_tokens = filtered[:1]
        elif len(raw_tokens) > 1:
            non_func = [t for t in raw_tokens if not t.startswith("H9") and norm_classic(t) not in ("H0853", "G3588")]
            if non_func:
                raw_tokens = non_func

        resolved_ds: list[str] = []
        resolved_refs: list[str] = []
        conf = 10
        flags = ["aux" if is_aux_word else "head"]

        for rt in raw_tokens:
            cl = norm_classic(rt)
            if not cl:
                continue
            hits = cl_in_verse.get(cl, [])
            if not hits and cl in amap:
                hits = cl_in_verse.get(amap[cl], [])
                if hits and "form-alias" not in flags:
                    flags.append("form-alias")
                    conf = min(conf, 9)

            if hits:
                best_c, best_d = min(
                    hits,
                    key=lambda pair: abs((i / N) - (pair[0].pos_idx / M)),
                )
                used_cands.add(best_c.pos_idx)
                if best_c.wid and best_c.wid not in resolved_refs:
                    resolved_refs.append(best_c.wid)
                if not is_aux_word and best_d.startswith("H9"):
                    lex_c = lexical_only(best_c.dstrongs)
                    best_d = lex_c[0] if lex_c else best_d
                if best_d not in resolved_ds:
                    resolved_ds.append(best_d)
                # Фиксируем наблюдение в русских приорах
                if not is_aux_word and not best_d.startswith("H9"):
                    word_priors_ru[wl][best_d] += 3
                    stem_priors_ru[stem_ru(wl)][best_d] += 2
            else:
                target_cl = amap.get(cl, cl)
                cand_ds = classic_to_ds.get(target_cl, []) or classic_to_ds.get(cl, [])
                if not cand_ds:
                    continue
                chosen = cand_ds[0]
                if chosen not in resolved_ds:
                    resolved_ds.append(chosen)
                conf = min(conf, 8)
                if not is_aux_word and not chosen.startswith("H9"):
                    word_priors_ru[wl][chosen] += 1
                    stem_priors_ru[stem_ru(wl)][chosen] += 1

        if resolved_ds:
            out[i] = (
                i,
                " ".join(resolved_refs),
                " ".join(resolved_ds),
                conf,
                ",".join(flags),
                "ru-zaln-lift",
            )

    # Проход 2: неразмеченные слова стиха (служебные морфемы + приоры против кандидатов стиха)
    _fill_untagged_ru_words(words, out, cands, used_cands, word_priors_ru, stem_priors_ru)
    return [x for x in out if x is not None]


def _fill_untagged_ru_words(
    words: list[str],
    out: list[tuple[int, str, str, int, str, str] | None],
    cands: list[OrigCand],
    used_cands: set[int],
    word_priors_ru: dict[str, collections.Counter],
    stem_priors_ru: dict[str, collections.Counter],
) -> None:
    N = max(len(words), 1)
    M = max(len(cands), 1)

    # Сначала знаменательные слова по русским приорам word_priors_ru / stem_priors_ru против кандидатов стиха
    scored: list[tuple[float, int, int, str]] = []
    for i, w in enumerate(words):
        if out[i] is not None:
            continue
        wl = norm_ru(w)
        if wl in AUX_RU_WORDS:
            continue
        ws = stem_ru(wl)
        w_ctr = word_priors_ru.get(wl, collections.Counter())
        s_ctr = stem_priors_ru.get(ws, collections.Counter())
        for j, c in enumerate(cands):
            lex_ds = lexical_only(c.dstrongs)
            for d in lex_ds:
                cl = norm_classic(d) or d
                sc = 0.0
                if d in w_ctr:
                    sc += 6.0 + min(w_ctr[d] / 5.0, 4.0)
                elif cl in w_ctr:
                    sc += 5.0
                if d in s_ctr:
                    sc += 3.5 + min(s_ctr[d] / 10.0, 2.5)
                elif cl in s_ctr:
                    sc += 2.5
                if sc > 0:
                    pos_pen = 1.5 * abs((i / N) - (c.pos_idx / M))
                    free_bonus = 1.5 if j not in used_cands else 0.0
                    scored.append((sc + free_bonus - pos_pen, i, j, d))

    scored.sort(key=lambda x: x[0], reverse=True)
    for sc, i, j, best_d in scored:
        if out[i] is not None:
            continue
        if j in used_cands and sc < 7.5:
            continue
        used_cands.add(j)
        c = cands[j]
        conf = 9 if sc >= 7.0 else 8
        out[i] = (i, c.wid, best_d, conf, "head", "ru-prior-verse")

    # Остаточное позиционное сопоставление свободных знаменательных слов и кандидатов
    rem_words = [i for i, w in enumerate(words) if out[i] is None and norm_ru(w) not in AUX_RU_WORDS]
    rem_cands = [
        j
        for j, c in enumerate(cands)
        if j not in used_cands and any(not d.startswith("H9") and d not in ("H0853", "G3588") for d in c.dstrongs)
    ]
    for i in rem_words:
        if not rem_cands:
            break
        best_j = min(rem_cands, key=lambda j: abs((i / N) - (cands[j].pos_idx / M)))
        if abs((i / N) - (cands[best_j].pos_idx / M)) <= 0.35:
            rem_cands.remove(best_j)
            used_cands.add(best_j)
            c = cands[best_j]
            best_d = lexical_only(c.dstrongs)[0]
            out[i] = (i, c.wid, best_d, 7, "head", "ru-pos-match")

    # Теперь служебные слова (в, и, на, к, от, мой, его, не...)
    for i, w in enumerate(words):
        if out[i] is not None:
            continue
        wl = norm_ru(w)
        func_codes = FUNC_RU_TO_CODES.get(wl, [])
        if func_codes and cands:
            matches: list[tuple[OrigCand, str]] = []
            for c in cands:
                for d in c.dstrongs:
                    if d in func_codes or norm_classic(d) in func_codes:
                        matches.append((c, d))
            if matches:
                best_c, best_d = min(matches, key=lambda p: abs((i / N) - (p[0].pos_idx / M)))
                out[i] = (i, best_c.wid, best_d, 9, "aux", "ru-step-func")
                continue

        # Аналитическая группа со следующим/предыдущим словом
        if wl in AUX_RU_WORDS:
            neighbor = None
            for delta in (1, -1, 2, -2):
                k = i + delta
                if 0 <= k < len(words) and out[k] is not None and out[k][2]:
                    neighbor = out[k]
                    break
            if neighbor is not None:
                out[i] = (i, neighbor[1], neighbor[2].split()[0], 8, "aux,grp", "ru-analytic-grp")
                continue

        out[i] = (i, "", "", 8 if wl in AUX_RU_WORDS else 7, "added,aux", "ru-added")


def main() -> None:
    t0 = time.time()
    priors_en = json.loads((DATA / "work" / "strongs" / "pipeline" / "priors_en.json").read_text(encoding="utf-8"))
    amap = priors_en["form_alias"]
    classic_to_ds = priors_en["classic_to_dstrongs"]
    verse_map = json.loads((DATA / "work" / "strongs" / "measure" / "verse_map.json").read_text(encoding="utf-8"))
    rsc_to_eng = build_rsc_to_eng(verse_map)
    orig_index, _mid_map = load_orig_with_mid()

    word_priors_ru: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    stem_priors_ru: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)

    # 1. Сначала собираем слой ru_rlob-strongs.sb (31 книга, версификация eng) и накапливаем современные русские приоры
    print("Building ru_rlob-strongs.sb ...")
    rlob_meta, rlob_verses = tokenize_module(DATA / "modules" / "ru_rlob.sb")
    rlob_rows: list[tuple[int, int, int, int, str, str, int, str, str]] = []
    for (bid, ch, v), (words, wspans) in sorted(rlob_verses.items()):
        cands = get_orig_cands_for_verse(orig_index, rsc_to_eng, "eng", bid, ch, v)
        vlinks = align_tagged_ru_verse(words, wspans, cands, amap, classic_to_ds, word_priors_ru, stem_priors_ru)
        for w_idx, ref_s, st_s, conf, fl_s, src_s in vlinks:
            rlob_rows.append((bid, ch, v, w_idx, ref_s, st_s, conf, fl_s, src_s))

    rlob_out = DATA / "work" / "strongs" / "layers" / "ru_rlob-strongs.sb"
    write_layer_sb(
        rlob_out,
        target_id=rlob_meta["target_id"],
        target_hash=rlob_meta["target_hash"],
        tokenizer=rlob_meta["tokenizer"],
        versification=rlob_meta["versification"],
        mode="zaln-dstrong",
        rows=rlob_rows,
    )
    print(f"  ru_rlob-strongs.sb: {len(rlob_rows)} links")

    # 2. Загружаем классическую разметку rsts.sb для проекции на Синодальный (russyn.sb) и пополнения приоров ВЗ
    print("Tokenizing rsts.sb & russyn.sb ...")
    _rsts_meta, rsts_verses = tokenize_module(DATA / "modules" / "rsts.sb")
    russyn_meta, russyn_verses = tokenize_module(DATA / "modules" / "russyn.sb")

    # Прогоняем rsts для накопления русских приоров ВЗ/НЗ и строим слой russyn-strongs.sb
    russyn_rows: list[tuple[int, int, int, int, str, str, int, str, str]] = []
    russyn_verse_links: dict[tuple[int, int, int], list[tuple[str, str, str]]] = {}

    for (bid, ch, v), (syn_words, syn_spans) in sorted(russyn_verses.items()):
        cands = get_orig_cands_for_verse(orig_index, rsc_to_eng, "rsc", bid, ch, v)
        # Проецируем атрибуты strong из rsts.sb на слова russyn.sb через SequenceMatcher
        proj_spans = [{"style": sp.get("style", ""), "attrs": sp.get("attrs", "")} for sp in syn_spans]
        if (bid, ch, v) in rsts_verses:
            r_words, r_spans = rsts_verses[(bid, ch, v)]
            sm = difflib.SequenceMatcher(
                None,
                [norm_ru(w) for w in r_words],
                [norm_ru(w) for w in syn_words],
                autojunk=False,
            )
            for tag, i1, i2, j1, j2 in sm.get_opcodes():
                if tag == "equal":
                    for ia, jb in zip(range(i1, i2), range(j1, j2)):
                        if r_spans[ia].get("attrs"):
                            proj_spans[jb]["attrs"] = r_spans[ia]["attrs"]
                            proj_spans[jb]["style"] = r_spans[ia].get("style", "w")
                elif tag == "replace" and (i2 - i1) == (j2 - j1):
                    for ia, jb in zip(range(i1, i2), range(j1, j2)):
                        if stem_ru(r_words[ia]) == stem_ru(syn_words[jb]) and r_spans[ia].get("attrs"):
                            proj_spans[jb]["attrs"] = r_spans[ia]["attrs"]
                            proj_spans[jb]["style"] = r_spans[ia].get("style", "w")

        vlinks = align_tagged_ru_verse(syn_words, proj_spans, cands, amap, classic_to_ds, word_priors_ru, stem_priors_ru)
        v_summary = []
        for w_idx, ref_s, st_s, conf, fl_s, src_s in vlinks:
            russyn_rows.append((bid, ch, v, w_idx, ref_s, st_s, conf, fl_s, src_s))
            v_summary.append((syn_words[w_idx], ref_s, st_s))
        russyn_verse_links[(bid, ch, v)] = v_summary

    russyn_out = DATA / "work" / "strongs" / "layers" / "russyn-strongs.sb"
    write_layer_sb(
        russyn_out,
        target_id=russyn_meta["target_id"],
        target_hash=russyn_meta["target_hash"],
        tokenizer=russyn_meta["tokenizer"],
        versification=russyn_meta["versification"],
        mode="synodal-dstrong",
        rows=russyn_rows,
    )
    print(f"  russyn-strongs.sb: {len(russyn_rows)} links")

    # 3. Теперь собираем полный слой ru_rob-strongs.sb (все 66 книг: 23 книги со своим \zaln + 43 книги через приоры и кандидатов стиха!)
    print("Building ru_rob-strongs.sb ...")
    rob_meta, rob_verses = tokenize_module(DATA / "modules" / "ru_rob.sb")
    rob_rows: list[tuple[int, int, int, int, str, str, int, str, str]] = []
    for (bid, ch, v), (words, wspans) in sorted(rob_verses.items()):
        cands = get_orig_cands_for_verse(orig_index, rsc_to_eng, "rsc", bid, ch, v)
        vlinks = align_tagged_ru_verse(words, wspans, cands, amap, classic_to_ds, word_priors_ru, stem_priors_ru)
        for w_idx, ref_s, st_s, conf, fl_s, src_s in vlinks:
            rob_rows.append((bid, ch, v, w_idx, ref_s, st_s, conf, fl_s, src_s))

    rob_out = DATA / "work" / "strongs" / "layers" / "ru_rob-strongs.sb"
    write_layer_sb(
        rob_out,
        target_id=rob_meta["target_id"],
        target_hash=rob_meta["target_hash"],
        tokenizer=rob_meta["tokenizer"],
        versification=rob_meta["versification"],
        mode="rob-dstrong",
        rows=rob_rows,
    )
    print(f"  ru_rob-strongs.sb: {len(rob_rows)} links")

    # 4. Сохраняем русские эквиваленты каждого dStrong (современные из ru_rlob/ru_rob и синодальные из russyn)
    # для следующего шага — генерации современного словаря strongs-step-ru.sb!
    dstrong_to_modern_ru: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    dstrong_to_synodal_ru: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)

    for (bid, ch, v), (words, _) in rlob_verses.items():
        pass
    # Собираем прямо из построенных строк слоёв
    rlob_word_map = {(bid, ch, v, idx): w for (bid, ch, v), (ws, _) in rlob_verses.items() for idx, w in enumerate(ws)}
    for bid, ch, v, w_idx, _ref, st_s, _conf, fl_s, _src in rlob_rows:
        if "head" in fl_s and st_s:
            w = norm_ru(rlob_word_map[(bid, ch, v, w_idx)])
            if w not in AUX_RU_WORDS and len(w) >= 2:
                for d in st_s.split():
                    if not d.startswith("H9"):
                        dstrong_to_modern_ru[d][w] += 2

    rob_word_map = {(bid, ch, v, idx): w for (bid, ch, v), (ws, _) in rob_verses.items() for idx, w in enumerate(ws)}
    for bid, ch, v, w_idx, _ref, st_s, conf, fl_s, _src in rob_rows:
        if "head" in fl_s and st_s and conf >= 9:
            w = norm_ru(rob_word_map[(bid, ch, v, w_idx)])
            if w not in AUX_RU_WORDS and len(w) >= 2:
                for d in st_s.split():
                    if not d.startswith("H9"):
                        dstrong_to_modern_ru[d][w] += 1

    syn_word_map = {(bid, ch, v, idx): w for (bid, ch, v), (ws, _) in russyn_verses.items() for idx, w in enumerate(ws)}
    for bid, ch, v, w_idx, _ref, st_s, conf, fl_s, _src in russyn_rows:
        if "head" in fl_s and st_s and conf >= 9:
            w = norm_ru(syn_word_map[(bid, ch, v, w_idx)])
            if w not in AUX_RU_WORDS and len(w) >= 2:
                for d in st_s.split():
                    if not d.startswith("H9"):
                        dstrong_to_synodal_ru[d][w] += 1

    priors_ru_path = DATA / "work" / "strongs" / "pipeline" / "priors_ru.json"
    priors_ru_path.write_text(
        json.dumps(
            {
                "dstrong_modern_ru": {k: ctr.most_common(8) for k, ctr in dstrong_to_modern_ru.items()},
                "dstrong_synodal_ru": {k: ctr.most_common(8) for k, ctr in dstrong_to_synodal_ru.items()},
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    print(
        f"Saved {priors_ru_path} in {time.time() - t0:.1f}s: "
        f"modern dStrong={len(dstrong_to_modern_ru)}, synodal dStrong={len(dstrong_to_synodal_ru)}"
    )
    cli = REPO / "target" / "debug" / "studybible.exe"
    import shutil
    for lay_p in (rlob_out, russyn_out, rob_out):
        subprocess.run([str(cli), "module", "check", str(lay_p)], check=True)
        subprocess.run([str(cli), "module", "pack", str(lay_p)], check=True)
        shutil.copy2(lay_p.with_suffix(".sbz"), DATA / "modules" / f"{lay_p.stem}.sbz")


if __name__ == "__main__":
    main()
