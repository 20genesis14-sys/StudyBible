"""Фаза 6 (Шаг 2): Контур 1 — детерминированное и словарно-статистическое
сопоставление слов перевода (w1) с кандидатами стиха из step-orig.sb.

Поддерживает два режима:
  1. mode='assisted' (Режим Б): использует встроенные классические номера
     Стронга и теги \\add целевого модуля (например, eng-kjv2006.sb),
     поднимая их до dStrong и wid стиха step-orig.sb + размечая служебные слова.
  2. mode='blind' (Режим В — для «голых» переводов и честного теста Фазы 7
     на отложенных книгах): видит ТОЛЬКО голые слова w1 целевого перевода
     и выравнивает их с кандидатами стиха step-orig.sb, используя глоссы
     step-orig/strongs-step и вероятностный словарь priors_en.json
     (построенный строго на рабочих книгах).
"""
from __future__ import annotations

import collections
import dataclasses
import json
import os
import pathlib
import re
import sqlite3

from priors import BOOK_ID, ID_BOOK, norm_classic, norm_dstrong

DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))

AUX_ENG_WORDS = {
    "a", "an", "the", "in", "into", "unto", "to", "for", "of", "from", "out",
    "on", "upon", "with", "by", "as", "like", "at", "over", "under", "between",
    "among", "before", "after", "through", "against", "about", "concerning",
    "and", "or", "but", "nor", "so", "then", "yet", "for", "that", "which",
    "who", "whom", "whose", "what", "when", "where", "while", "if", "though",
    "because", "since", "until", "till", "lest", "whether",
    "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves",
    "you", "your", "yours", "yourself", "yourselves", "thou", "thee", "thy",
    "thine", "thyself", "ye", "he", "him", "his", "himself", "she", "her",
    "hers", "herself", "it", "its", "itself", "they", "them", "their", "theirs",
    "themselves", "this", "that", "these", "those",
    "is", "am", "are", "was", "were", "be", "been", "being", "have", "has",
    "had", "having", "do", "does", "did", "shall", "will", "would", "should",
    "may", "might", "can", "could", "must", "let", "not", "no", "nor", "there",
    "here", "now", "thus", "o", "oh", "s",
}

# Прямые соответствия английских служебных слов служебным кодам H9xxx / греческим частицам
FUNC_ENG_TO_CODES: dict[str, list[str]] = {
    "and": ["H9002", "G2532", "G1161", "G5037"],
    "in": ["H9003", "G1722", "H0854"],
    "into": ["H9003", "H0413", "G1519"],
    "as": ["H9004", "G5613", "G2531"],
    "like": ["H9004", "G5613"],
    "to": ["H9005", "H0413", "G1519", "G4314", "H9001"],
    "unto": ["H9005", "H0413", "G1519", "G4314"],
    "for": ["H9005", "H3588", "G1063", "G3754", "G1519"],
    "of": ["H9005", "G3588", "H0853"],
    "from": ["H9006", "H4480", "G0575", "G1537"],
    "out": ["H9006", "H4480", "G1537"],
    "than": ["H9006", "H4480", "G2228"],
    "the": ["H9009", "G3588", "H9015"],
    "that": ["H9007", "H0834", "H3588", "G3754", "G2443", "G3739"],
    "which": ["H9007", "H0834", "G3739", "G3588"],
    "who": ["H9007", "H0834", "G3739", "G3588"],
    "whom": ["H9007", "H0834", "G3739"],
    "whose": ["H0834", "G3739"],
    "with": ["H0854", "H5973", "H9003", "G3326", "G4862", "G1722"],
    "upon": ["H5921", "H9003", "G1909"],
    "on": ["H5921", "H9003", "G1909"],
    "by": ["H9003", "H5921", "G5259", "G1223", "G1722"],
    "not": ["H3808", "H0408", "G3756", "G3361"],
    "my": ["H9020", "G1473", "G3450"],
    "me": ["H9020", "H9032", "G1473", "G3165"],
    "our": ["H9021", "G1473", "G2257"],
    "us": ["H9021", "H9033", "G1473", "G2248"],
    "your": ["H9022", "H9027", "G4771", "G5216"],
    "thy": ["H9022", "G4771", "G4675"],
    "thee": ["H9022", "H9034", "G4771", "G4571"],
    "you": ["H9022", "H9027", "H0859", "G4771", "G5210", "G5209"],
    "ye": ["H0859", "G4771", "G5210"],
    "his": ["H9023", "G0846", "G0848"],
    "him": ["H9023", "H9036", "G0846"],
    "s": ["H9023", "G3588"],
    "her": ["H9024", "G0846"],
    "their": ["H9025", "H9026", "G0846"],
    "them": ["H9025", "H9038", "H0853", "G0846"],
    "it": ["H9023", "H9024", "H9036", "G0846"],
}


def stem_en(w: str) -> str:
    """Простая нормализация английской словоформы для сопоставления с глоссом."""
    wl = w.lower()
    if len(wl) <= 3:
        return wl
    # Архаичные окончания KJV (-eth, -est)
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


@dataclasses.dataclass
class OrigCand:
    wid: str
    surface: str
    dstrongs: list[str]
    classics: list[str]
    gloss: str
    gloss_tokens: set[str]
    gloss_stems: set[str]
    morph: str
    sns: str
    eid: str
    pos_idx: int


@dataclasses.dataclass
class WordLink:
    word_idx: int
    word: str
    refs: list[str]
    dstrongs: list[str]
    role: str  # 'head' | 'aux' | 'added'
    conf: int
    flags: list[str]
    source: str
    candidates_ambig: list[tuple[str, str]] = dataclasses.field(default_factory=list)


_ATTR_RE = re.compile(r'(\w+)="([^"]*)"')


def parse_attrs(attrs: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for k, v in _ATTR_RE.findall(attrs):
        if k in out and v:
            out[k] = f"{out[k]} {v}"
        else:
            out[k] = v
    return out


def load_orig_Index() -> dict[tuple[int, int, int], list[OrigCand]]:
    """Загружает все спаны step-orig.sb по (book_id, chapter, verse) вместе с английским глоссом из tokens."""
    db = sqlite3.connect(DATA / "work" / "strongs" / "orig" / "step-orig.sb")
    verses: dict[tuple[int, int, int], list[OrigCand]] = collections.defaultdict(list)
    for bid, ch, v, seq, surf, t_gloss, attrs in db.execute(
        "SELECT s.book_id, s.chapter, s.verse, s.seq, t.surface, t.gloss, s.attrs "
        "FROM spans s "
        "LEFT JOIN tokens t ON t.book_id=s.book_id AND t.chapter=s.chapter AND t.verse=s.verse AND t.seq=s.seq "
        "WHERE s.style='w' ORDER BY s.book_id, s.chapter, s.block, s.seq"
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
        gl = t_gloss or ""
        gtoks = {t.lower() for t in re.findall(r"[A-Za-z]+", gl) if len(t) >= 2}
        gstems = {stem_en(t) for t in gtoks}
        lst = verses[(bid, ch, v)]
        lst.append(
            OrigCand(
                wid=wid,
                surface=surf or ad.get("gr", ""),
                dstrongs=ds_list,
                classics=cl_list,
                gloss=gl,
                gloss_tokens=gtoks,
                gloss_stems=gstems,
                morph=ad.get("morph", ""),
                sns=ad.get("sns", ""),
                eid=ad.get("eid", ""),
                pos_idx=len(lst),
            )
        )
    return verses


def get_verse_candidates(
    orig_index: dict[tuple[int, int, int], list[OrigCand]],
    verse_map: dict,
    bid: int,
    ch: int,
    v: int,
) -> list[OrigCand]:
    """Возвращает кандидатов стиха из step-orig.sb (с учётом надписаний Псалмов и сдвигов стихов)."""
    cands = list(orig_index.get((bid, ch, v), []))
    # В Псалмах KJV надписание часто включено в стих 1, а в step-orig лежит в стихе 0
    if bid == 19 and v == 1 and (19, ch, 0) in orig_index:
        cands = list(orig_index[(19, ch, 0)]) + cands
    # Если стих пуст или сдвинут по версификации, проверим соседний стих
    if not cands:
        bk = ID_BOOK.get(bid, "")
        mapped = verse_map.get("eng_to_mt", {}).get(f"{bk}.{ch}.{v}")
        if mapped:
            m = re.match(r"^([A-Z0-9]+)\.(\d+)\.(\d+)$", mapped)
            if m:
                mbid = BOOK_ID.get(m.group(1), bid)
                cands = list(orig_index.get((mbid, int(m.group(2)), int(m.group(3))), []))
    return cands


def lexical_dstrongs(ds_list: list[str]) -> list[str]:
    """Отделяет знаменательные dStrong от служебных H9xxx / H0853 / G3588."""
    lex = [d for d in ds_list if not d.startswith("H9") and not d.startswith("H0853") and not d.startswith("G3588")]
    return lex if lex else ds_list


def order_lexical_first(ds_list: list[str]) -> list[str]:
    """Ставит знаменательные dStrong перед служебными приставками H9xxx / H0853 / G3588."""
    lex = [d for d in ds_list if not d.startswith("H9") and not d.startswith("H0853") and not d.startswith("G3588")]
    aff = [d for d in ds_list if d.startswith("H9") or d.startswith("H0853") or d.startswith("G3588")]
    return lex + aff


def align_verse_assisted(
    bid: int,
    words: list[str],
    word_spans: list[dict[str, str]],
    cands: list[OrigCand],
    priors: dict,
) -> list[WordLink]:
    """Контур 1Б: разметка стиха, у которого есть классические номера Стронга и/или \\add (напр., KJV)."""
    amap: dict[str, str] = priors["form_alias"]
    classic_to_ds: dict[str, list[str]] = priors["classic_to_dstrongs"]
    dstrong_gloss: dict[str, str] = priors["dstrong_gloss"]

    # Индекс: classic -> список (OrigCand, конкретный dStrong)
    cl_in_verse: dict[str, list[tuple[OrigCand, str]]] = collections.defaultdict(list)
    for c in cands:
        for d in c.dstrongs:
            cl = norm_classic(d)
            if cl:
                cl_in_verse[cl].append((c, d))

    links: list[WordLink | None] = [None] * len(words)
    N = max(len(words), 1)
    M = max(len(cands), 1)

    # Проход 1: слова с явными атрибутами strong="..." или style="add"
    for i, (w, sp) in enumerate(zip(words, word_spans)):
        style = sp.get("style", "")
        attrs = parse_attrs(sp.get("attrs", ""))
        st_raw = attrs.get("strong", "").strip()
        wl = w.lower()

        if not st_raw and style == "add":
            links[i] = WordLink(
                word_idx=i,
                word=w,
                refs=[],
                dstrongs=[],
                role="added",
                conf=10,
                flags=["added", "aux"],
                source="w1-add-tag",
            )
            continue

        if not st_raw:
            continue

        raw_codes = [norm_classic(x) for x in st_raw.split() if norm_classic(x)]
        if not raw_codes:
            continue

        resolved_ds: list[str] = []
        resolved_refs: list[str] = []
        ambig_pairs: list[tuple[str, str]] = []
        flags: list[str] = []
        conf = 10
        source = "classic-lift"

        for rc in raw_codes:
            hits = cl_in_verse.get(rc, [])
            used_alias = False
            if not hits and rc in amap:
                hits = cl_in_verse.get(amap[rc], [])
                if hits:
                    used_alias = True

            if hits:
                # Уникальные dStrong среди кандидатов стиха
                uniq_ds = list(dict.fromkeys(d for _, d in hits))
                # Выбираем кандидата, ближайшего по относительной позиции и глоссу
                best_cand, best_d = min(
                    hits,
                    key=lambda pair: (
                        0 if (wl in pair[0].gloss_tokens or stem_en(wl) in pair[0].gloss_stems) else 1,
                        abs((i / N) - (pair[0].pos_idx / M)),
                    ),
                )
                if best_cand.wid and best_cand.wid not in resolved_refs:
                    resolved_refs.append(best_cand.wid)
                if len(uniq_ds) == 1:
                    if best_d not in resolved_ds:
                        resolved_ds.append(best_d)
                    if used_alias:
                        conf = min(conf, 9)
                        if "form-alias" not in flags:
                            flags.append("form-alias")
                else:
                    # Несколько разных dStrong одного корня в одном стихе -> передаём в Контур 2
                    if best_d not in resolved_ds:
                        resolved_ds.append(best_d)
                    for c_cand, d_cand in hits:
                        ambig_pairs.append((c_cand.wid, d_cand))
                    conf = min(conf, 8)
            else:
                # Номера нет в step-orig стиха (вариант TR или сдвиг нумерации)
                target_cl = amap.get(rc, rc)
                cand_ds = classic_to_ds.get(target_cl, []) or classic_to_ds.get(rc, [])
                if len(cand_ds) == 1:
                    if cand_ds[0] not in resolved_ds:
                        resolved_ds.append(cand_ds[0])
                    conf = min(conf, 8)
                    source = "tr-lex-lift"
                    if "tr-var" not in flags:
                        flags.append("tr-var")
                elif len(cand_ds) > 1:
                    for d_cand in cand_ds:
                        ambig_pairs.append(("", d_cand))
                    resolved_ds.append(cand_ds[0])
                    conf = min(conf, 7)
                    source = "tr-lex-ambig"
                    if "tr-var" not in flags:
                        flags.append("tr-var")
                else:
                    resolved_ds.append(rc)
                    conf = min(conf, 6)
                    source = "classic-raw"

        role = "aux" if (wl in AUX_ENG_WORDS and all(d.startswith("H9") or d in ("H0853", "G3588") for d in resolved_ds)) else "head"
        if role == "head":
            resolved_ds = order_lexical_first(resolved_ds)
        if role not in flags:
            flags.insert(0, role)
        links[i] = WordLink(
            word_idx=i,
            word=w,
            refs=resolved_refs,
            dstrongs=resolved_ds,
            role=role,
            conf=conf,
            flags=flags,
            source=source,
            candidates_ambig=ambig_pairs,
        )

    # Проход 2: неразмеченные слова (в KJV это служебные слова: In, the, of, and, his, was, shall...)
    _fill_untagged_words(bid, words, links, cands, priors)
    return [l for l in links if l is not None]


def _fill_untagged_words(
    bid: int,
    words: list[str],
    links: list[WordLink | None],
    cands: list[OrigCand],
    priors: dict,
    used_cands: set[int] | None = None,
) -> None:
    """Привязывает неразмеченные служебные и аналитические слова стиха."""
    if used_cands is None:
        used_cands = set()
    N = max(len(words), 1)
    M = max(len(cands), 1)
    testament = "OT" if bid < 40 else "NT"
    wpriors = priors["word_priors"].get(testament, {})

    for i, w in enumerate(words):
        if links[i] is not None:
            continue
        wl = w.lower()
        wstem = stem_en(wl)

        # 1. Проверяем служебную морфему в кандидатах стиха (напр., H9003 для 'In', H9009/G3588 для 'the')
        func_codes = FUNC_ENG_TO_CODES.get(wl, [])
        best_func: tuple[OrigCand, str] | None = None
        if func_codes and cands:
            matches: list[tuple[OrigCand, str]] = []
            for c in cands:
                for d in c.dstrongs:
                    if d in func_codes or norm_classic(d) in func_codes:
                        matches.append((c, d))
            if matches:
                best_func = min(
                    matches,
                    key=lambda pair: abs((i / N) - (pair[0].pos_idx / M)),
                )
        if best_func is not None:
            cand, dcode = best_func
            links[i] = WordLink(
                word_idx=i,
                word=w,
                refs=[cand.wid] if cand.wid else [],
                dstrongs=[dcode],
                role="aux",
                conf=9,
                flags=["aux"],
                source="step-func",
            )
            continue

        # 2. Проверяем прямое совпадение глосса с кандидатом в стихе
        gloss_hits: list[OrigCand] = []
        for c in cands:
            if wl in c.gloss_tokens or (len(wstem) >= 3 and wstem in c.gloss_stems):
                gloss_hits.append(c)
        if gloss_hits:
            best_c = min(
                gloss_hits,
                key=lambda c: (1 if c.pos_idx in used_cands else 0, abs((i / N) - (c.pos_idx / M))),
            )
            used_cands.add(best_c.pos_idx)
            ds = lexical_dstrongs(best_c.dstrongs) if wl not in AUX_ENG_WORDS else best_c.dstrongs[:1]
            role = "aux" if wl in AUX_ENG_WORDS else "head"
            links[i] = WordLink(
                word_idx=i,
                word=w,
                refs=[best_c.wid] if best_c.wid else [],
                dstrongs=ds,
                role=role,
                conf=9,
                flags=[role],
                source="step-gloss",
            )
            continue

        # 3. Проверяем вероятностный словарь priors_en.json против кандидатов стиха
        prior_list = wpriors.get(wl, [])
        if prior_list and cands:
            prior_map = {code: cnt for code, cnt in prior_list}
            cand_matches: list[tuple[int, int, OrigCand, str]] = []
            for c in cands:
                if wl not in AUX_ENG_WORDS and c.pos_idx in used_cands:
                    continue
                check_ds = lexical_dstrongs(c.dstrongs) if wl not in AUX_ENG_WORDS else c.dstrongs
                for d in check_ds:
                    if d in prior_map:
                        free_bonus = 1 if c.pos_idx not in used_cands else 0
                        cand_matches.append((free_bonus, prior_map[d], c, d))
            if cand_matches:
                _, _, best_c, best_d = max(
                    cand_matches,
                    key=lambda item: (item[0], item[1], -abs((i / N) - (item[2].pos_idx / M))),
                )
                used_cands.add(best_c.pos_idx)
                role = "aux" if wl in AUX_ENG_WORDS else "head"
                links[i] = WordLink(
                    word_idx=i,
                    word=w,
                    refs=[best_c.wid] if best_c.wid else [],
                    dstrongs=[best_d],
                    role=role,
                    conf=8,
                    flags=[role],
                    source="prior-verse",
                )
                continue

        # 4. Если это служебное/аналитическое слово (the, was, shall, of, to), привязываем к соседнему head-слову как aux,grp
        neighbor: WordLink | None = None
        for delta in (1, -1, 2, -2):
            j = i + delta
            if 0 <= j < len(words) and links[j] is not None and links[j].dstrongs:
                neighbor = links[j]
                break
        if neighbor is not None and wl in AUX_ENG_WORDS:
            links[i] = WordLink(
                word_idx=i,
                word=w,
                refs=list(neighbor.refs),
                dstrongs=list(neighbor.dstrongs[:1]),
                role="aux",
                conf=8,
                flags=["aux", "grp"],
                source="analytic-grp",
            )
            continue

        # 5. Иначе помечаем как вставленное по смыслу (added)
        links[i] = WordLink(
            word_idx=i,
            word=w,
            refs=[],
            dstrongs=[],
            role="added",
            conf=7 if wl not in AUX_ENG_WORDS else 8,
            flags=["added", "aux"],
            source="unmatched-added",
        )


def align_verse_blind(
    bid: int,
    words: list[str],
    cands: list[OrigCand],
    priors: dict,
) -> list[WordLink]:
    """Контур 1В (слепой режим без входных номеров Стронга):
    выравнивает голые слова w1 со словами стиха step-orig.sb по глоссам
    step-orig, словарю strongs-step и вероятностям priors_en.json (с рабочих книг).
    """
    N = max(len(words), 1)
    M = max(len(cands), 1)
    testament = "OT" if bid < 40 else "NT"
    wpriors = priors["word_priors"].get(testament, {})
    clpriors = priors.get("classic_priors", {}).get(testament, {})
    dstrong_gloss: dict[str, str] = priors["dstrong_gloss"]

    links: list[WordLink | None] = [None] * len(words)
    used_cands: set[int] = set()

    # Предварительно токенизируем словарные глоссы кандидатов
    cand_lex_tokens: list[set[str]] = []
    cand_lex_stems: list[set[str]] = []
    for c in cands:
        ltoks: set[str] = set()
        for d in c.dstrongs:
            g = dstrong_gloss.get(d, "")
            for t in re.findall(r"[A-Za-z]+", g.lower()):
                if len(t) >= 2:
                    ltoks.add(t)
        cand_lex_tokens.append(ltoks)
        cand_lex_stems.append({stem_en(t) for t in ltoks})

    # Шаг 1: Выравниваем знаменательные слова (not in AUX_ENG_WORDS) по суммарному скору
    scored_pairs: list[tuple[float, int, int, str, str]] = []
    for i, w in enumerate(words):
        wl = w.lower()
        if wl in AUX_ENG_WORDS:
            continue
        wstem = stem_en(wl)
        prior_map: dict[str, int] = {}
        for k, v in wpriors.get(f"#{wstem}", []):
            prior_map[k] = prior_map.get(k, 0) + v
        for k, v in wpriors.get(wl, []):
            prior_map[k] = prior_map.get(k, 0) + v * 2
        prior_total = sum(prior_map.values()) or 1

        cl_map: dict[str, int] = {}
        for k, v in clpriors.get(f"#{wstem}", []):
            cl_map[k] = cl_map.get(k, 0) + v
        for k, v in clpriors.get(wl, []):
            cl_map[k] = cl_map.get(k, 0) + v * 2
        cl_total = sum(cl_map.values()) or 1

        for j, c in enumerate(cands):
            lex_ds = lexical_dstrongs(c.dstrongs)
            best_d = lex_ds[0] if lex_ds else (c.dstrongs[0] if c.dstrongs else "")
            if not best_d:
                continue
            score = 0.0
            src_tag = "blind-gloss"
            # Сигнал 1: точное совпадение со словом контекстного глосса step-orig
            if wl in c.gloss_tokens:
                score += 6.5
            elif len(wstem) >= 3 and wstem in c.gloss_stems:
                score += 5.0
            elif len(wl) >= 4 and any(t.startswith(wl[:4]) or wl.startswith(t[:4]) for t in c.gloss_tokens if len(t) >= 4):
                score += 3.5
            # Сигнал 2: совпадение со словарным глоссом strongs-step
            if wl in cand_lex_tokens[j]:
                score += 4.5
            elif len(wstem) >= 3 and wstem in cand_lex_stems[j]:
                score += 3.2
            # Сигнал 3: приор dStrong и classic с рабочих книг (только знаменательные корни lex_ds!)
            best_p = 0
            for d in lex_ds:
                if d in prior_map and prior_map[d] > best_p:
                    best_p = prior_map[d]
                    best_d = d
            if best_p > 0:
                score += 6.0 * (best_p / prior_total) + min(best_p / 15.0, 3.5)
                src_tag = "blind-prior"
            best_clp = 0
            for d in lex_ds:
                cl_code = norm_classic(d)
                if cl_code and cl_code in cl_map and cl_map[cl_code] > best_clp:
                    best_clp = cl_map[cl_code]
                    best_d = d
            if best_clp > 0:
                score += 4.5 * (best_clp / cl_total) + min(best_clp / 20.0, 2.5)
                if src_tag == "blind-gloss":
                    src_tag = "blind-cl-prior"
            # Сигнал 4: совпадение имени собственного по eid или заглавной букве
            if c.eid and w[0].isupper():
                eid_low = c.eid.lower()
                if wl in eid_low or (len(wl) >= 4 and wl[:4] in eid_low):
                    score += 8.0
                    src_tag = "blind-eid"
                elif i > 0:
                    score += 2.5

            if score >= 1.4:
                pos_pen = 1.4 * abs((i / N) - (c.pos_idx / M))
                scored_pairs.append((score - pos_pen, i, j, best_d, src_tag))

    scored_pairs.sort(key=lambda x: x[0], reverse=True)
    for sc, i, j, best_d, src_tag in scored_pairs:
        if links[i] is not None:
            continue
        c = cands[j]
        if j in used_cands and sc < 7.5:
            continue
        used_cands.add(j)
        conf = 10 if sc >= 8.5 else (9 if sc >= 4.8 else 8)
        links[i] = WordLink(
            word_idx=i,
            word=words[i],
            refs=[c.wid] if c.wid else [],
            dstrongs=[best_d],
            role="head",
            conf=conf,
            flags=["head"],
            source=src_tag,
        )

    # Шаг 2: Остаточное монотонное сопоставление оставшихся знаменательных слов
    # со свободными знаменательными кандидатами стиха (по позиции и части речи)
    rem_words = [i for i, w in enumerate(words) if links[i] is None and w.lower() not in AUX_ENG_WORDS]
    rem_cands = [
        j
        for j, c in enumerate(cands)
        if j not in used_cands
        and any(not d.startswith("H9") and d not in ("H0853", "G3588") for d in c.dstrongs)
    ]
    for i in rem_words:
        if not rem_cands:
            break
        best_j = min(rem_cands, key=lambda j: abs((i / N) - (cands[j].pos_idx / M)))
        if abs((i / N) - (cands[best_j].pos_idx / M)) <= 0.32:
            rem_cands.remove(best_j)
            used_cands.add(best_j)
            c = cands[best_j]
            lex_ds = lexical_dstrongs(c.dstrongs)
            best_d = lex_ds[0] if lex_ds else c.dstrongs[0]
            links[i] = WordLink(
                word_idx=i,
                word=words[i],
                refs=[c.wid] if c.wid else [],
                dstrongs=[best_d],
                role="head",
                conf=7,
                flags=["head"],
                source="blind-pos",
            )

    # Шаг 3: Заполняем служебные и оставшиеся слова
    _fill_untagged_words(bid, words, links, cands, priors, used_cands)
    return [l for l in links if l is not None]
