"""Слой engbsb-strongs v2: dStrong через Clear manual alignments.

Цепочка: BSB-токен →(Clear WLCM/SBLGNT-BSB-manual)→ MACULA id →
(mid→спан step-orig)→ dStrong. Слова-группы (len(target)>1) — flag 'grp'.
Кросс-проверка: классический номер старого слоя bsb-strongs.sb против
базы dStrong → flag 'diff' + misses-отчёт.

Выход: work/strongs/layers/engbsb-strongs.sb (kind=layer,
features=strongs, target=engbsb, tokenizer=w1).
"""
import collections
import difflib
import csv
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lexicon'))
import common as C  # noqa: E402

csv.field_size_limit(2**31 - 1)

CLEAR = C.SRC / 'clear-alignments' / 'data'
ORIG = C.DATA / 'work' / 'strongs' / 'orig'
WORK = C.DATA / 'work' / 'strongs' / 'layers'
OLD = C.DATA / 'work' / 'strongs' / 'lexicon' / 'bsb-strongs.sb'
BSB = C.DATA / 'modules' / 'engbsb.sb'
DST = WORK / 'engbsb-strongs.sb'

USFM = {i + 1: u for i, (u, _s, _e) in enumerate(C.BOOKS)}
BOOK_ID = {u: i + 1 for i, (u, _s, _e) in enumerate(C.BOOKS)}
NONALNUM = re.compile(r'[^0-9A-Za-z]+')


def norm(s):
    return NONALNUM.sub('', s).casefold()


PUNCT_STRONG = {'H9014', 'H9015', 'H9016', 'H9017', 'H9018'}

FUNC_MAP = {
    'H9001': {'and', 'then', 'so', 'now', 'but', 'when', 'that'},
    'H9002': {'and', 'also', 'but', 'or', 'nor', 'so', 'then', 'now', 'yet',
              'for', 'both', 'even'},
    'H9003': {'in', 'on', 'with', 'by', 'at', 'among', 'into', 'through',
              'for', 'when', 'while', 'against', 'upon', 'within', 'over',
              'during', 'as', 'of', 'from', 'to'},
    'H9004': {'as', 'like', 'according', 'when', 'about', 'so', 'than'},
    'H9005': {'to', 'for', 'of', 'at', 'into', 'by', 'in', 'as', 'toward',
              'on', 'about', 'against', 'from', 'with', 'until', 'before'},
    'H9006': {'from', 'out', 'than', 'of', 'since', 'above', 'more',
              'because', 'without', 'away', 'by', 'at', 'on', 'after',
              'among'},
    'H9007': {'which', 'that', 'who', 'whom', 'whose', 'what', 'where',
              'when', 'because', 'for'},
    'H9008': {'whether', 'if'},
    'H9009': {'the', 'this', 'that', 'these', 'those', 'who', 'which', 'a',
              'an', 'each', 'every', 'o'},
    'H9010': {'the', 'this', 'that'},
    'H9011': {'to', 'toward', 'into', 'ward', 'at', 'on', 'in'},
    'H9020': {'my', 'me', 'i', 'mine', 'myself', 's'},
    'H9021': {'your', 'you', 'yours', 'yourself'},
    'H9022': {'your', 'you', 'yours', 'yourself'},
    'H9023': {'his', 'him', 'he', 'himself', 'its', 'it', 'itself', 's'},
    'H9024': {'her', 'hers', 'she', 'herself', 'its', 'it', 's'},
    'H9025': {'our', 'us', 'we', 'ours', 'ourselves'},
    'H9026': {'your', 'you', 'yours', 'yourselves'},
    'H9027': {'your', 'you', 'yours', 'yourselves'},
    'H9028': {'their', 'them', 'they', 'theirs', 'themselves'},
    'H9029': {'their', 'them', 'they', 'theirs', 'themselves'},
    'H9030': {'me', 'my', 'i', 'myself'},
    'H9031': {'you', 'your', 'yourself'},
    'H9032': {'you', 'your', 'yourself'},
    'H9033': {'him', 'his', 'he', 'it', 'its', 'himself', 'there'},
    'H9034': {'her', 'she', 'it', 'its', 'herself'},
    'H9035': {'us', 'our', 'we', 'ourselves'},
    'H9036': {'you', 'your', 'yourselves'},
    'H9037': {'you', 'your', 'yourselves'},
    'H9038': {'them', 'their', 'they', 'themselves', 'those'},
    'H9039': {'them', 'their', 'they', 'themselves'},
    'H9040': {'i', 'me', 'my'},
    'H9041': {'you', 'your'},
    'H9042': {'you', 'your'},
    'H9043': {'he', 'him', 'his', 'it'},
    'H9044': {'she', 'her', 'it'},
    'H9045': {'we', 'us', 'our'},
    'H9046': {'you', 'your'},
    'H9047': {'you', 'your'},
    'H9048': {'they', 'them', 'their'},
    'H9049': {'they', 'them', 'their'},
    'G3588': {'the', 'who', 'which', 'that', 'what', 'he', 'she', 'those',
              'his', 'your', 'our', 'their', 'my', 'o'},
}

AUX_ENG = {
    'the', 'a', 'an', 'of', 'to', 'in', 'for', 'with', 'on', 'by', 'from',
    'at', 'into', 'unto', 'upon', 'out', 'up', 'about', 'over', 'and', 'or',
    'but', 'now', 'so', 'then', 'was', 'were', 'is', 'are', 'be', 'been',
    'am', 'has', 'have', 'had', 'will', 'shall', 'would', 'should', 'may',
    'might', 'can', 'could', 'did', 'do', 'does', 'let', 'there', 'it',
    'he', 'she', 'they', 'we', 'you', 'i', 'his', 'her', 'their', 'our',
    'your', 'my', 'its', 'o', 's',
}


def is_func_code(s):
    return s in FUNC_MAP or s == 'H0853' or s.startswith(('H9', 'G9'))


def order_lex_first(codes):
    """Ставит знаменательные коды dStrong впереди служебных морфем H9xxx / H0853 / G3588."""
    lex = [s for s in codes if not is_func_code(s)]
    aff = [s for s in codes if is_func_code(s)]
    return lex + aff


def stem_simple(w):
    w = norm(w)
    if len(w) <= 3:
        return w
    for suf in ('ing', 'ed', 'es', 's'):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[:-len(suf)]
    return w


def split_group(strongs, w_list, words, st_gloss=None):
    """Распределить strongs внутри фразовой группы по словам w_list
    и назначить каждому слову роль ('head' или 'aux').
    Возвращает {w_idx: ([strongs], role)}."""
    if not w_list:
        return {}
    wnorms = {w: norm(words[w]) for w in w_list}
    if len(w_list) == 1:
        w = w_list[0]
        all_func = bool(strongs) and all(
            s in FUNC_MAP or s == 'H0853' for s in strongs)
        role = 'aux' if (all_func or (wnorms[w] in AUX_ENG and not strongs)) \
            else 'head'
        ordered = order_lex_first(strongs) if role == 'head' else list(strongs)
        return {w: (ordered, role)}

    matched_s = set()
    w_affix = {w: [] for w in w_list}
    for s in strongs:
        allowed = FUNC_MAP.get(s)
        if not allowed:
            continue
        for w in w_list:
            if wnorms[w] in allowed and s not in w_affix[w]:
                w_affix[w].append(s)
                matched_s.add(s)
    lex_s = [s for s in strongs if s not in matched_s]
    if not lex_s or lex_s == ['H0853']:
        lex_s = list(strongs)
        w_affix = {w: [] for w in w_list}
    else:
        unmatched_func = [s for s in strongs
                          if s in FUNC_MAP and s not in matched_s]
        if unmatched_func:
            lex_s = [s for s in strongs if s not in matched_s]
    lex_s = order_lex_first(lex_s)

    non_affix_w = [w for w in w_list if not w_affix[w]]
    if not non_affix_w:
        non_affix_w = [w_list[-1]]
        w_affix[w_list[-1]] = []
    head_w = [w for w in non_affix_w if wnorms[w] not in AUX_ENG]
    if not head_w:
        head_w = [non_affix_w[-1]]
    head_set = set(head_w)

    # Если в группе несколько head-слов и несколько знаменательных кодов,
    # распределяем знаменательные коды по совпадению со словарным/контекстным глоссом
    pure_lex = [s for s in lex_s if not is_func_code(s)]
    head_alloc = {}
    if st_gloss and len(head_w) >= 2 and len(pure_lex) >= 2:
        for w in head_w:
            wn = wnorms[w]
            wst = stem_simple(wn)
            hits = []
            for s in pure_lex:
                gtoks = st_gloss.get(s, set())
                if wn in gtoks or (len(wst) >= 3 and any(stem_simple(gt) == wst for gt in gtoks)):
                    hits.append(s)
            if len(hits) == 1:
                head_alloc[w] = hits

    out = {}
    for w in w_list:
        if w in head_set:
            out[w] = (head_alloc.get(w, list(lex_s)), 'head')
        elif w_affix[w]:
            out[w] = (list(w_affix[w]), 'aux')
        else:
            out[w] = (list(lex_s), 'aux')
    return out


def load_mid_index():
    """mid → (wid, strong); масоретский word-ключ (sb,sc,sv,NN) →
    ([wids], [strongs]); orig_v: (eb,ec,ev) → [spans]."""
    idx = {}
    by_wid = collections.defaultdict(lambda: ([], []))
    orig_v = {}
    with open(ORIG / 'orig-words.jsonl', encoding='utf-8') as f:
        for line in f:
            d = json.loads(line)
            ebcv = (d['b'], d['c'], d['v'])
            orig_v[ebcv] = d['w']
            for w in d['w']:
                st = w['strong'] if w['strong'] not in PUNCT_STRONG else ''
                if w.get('mid'):
                    idx[w['mid']] = (w['wid'], st)
                sbcv = tuple(w.get('sbcv') or ebcv)
                m2 = re.search(r'#(\d+)$', w.get('swid') or w['wid'])
                if m2:
                    key = (*sbcv, int(m2.group(1)))
                    wids, sts = by_wid[key]
                    if w['wid'] not in wids:
                        wids.append(w['wid'])
                    if st and st not in sts:
                        sts.append(st)
    return idx, by_wid, orig_v


def mid_word_key(mid):
    """o010010020061 → (1,1,2,'06'); n40001011013 → (40,1,11,'13')."""
    if not mid or mid[0] not in 'on':
        return None
    try:
        return (int(mid[1:3]), int(mid[3:6]), int(mid[6:9]),
                int(mid[9:12]))
    except ValueError:
        return None


def load_targets():
    """bcv → {token_id: text} — только слова (exclude пуст)."""
    idx, excl = {}, set()
    for name in ('ot_BSB.tsv', 'nt_BSB.tsv'):
        with open(CLEAR / 'eng' / 'targets' / 'BSB' / name,
                  encoding='utf-8') as f:
            for r in csv.DictReader(f, delimiter='\t'):
                tid = r['id']
                bcv = (int(tid[:2]), int(tid[2:5]), int(tid[5:8]))
                if r.get('exclude') == 'y':
                    excl.add(tid)
                else:
                    idx.setdefault(bcv, {})[tid] = r['text']
    return idx, excl


def load_alignments():
    """bcv → [(src_ids, tgt_ids, src_label)]."""
    out = collections.defaultdict(list)
    for name, lab in (('WLCM-BSB-manual.json', 'clear-manual'),
                      ('SBLGNT-BSB-manual.json', 'clear-manual')):
        d = json.load(open(CLEAR / 'eng' / 'alignments' / 'BSB' / name,
                           encoding='utf-8'))
        for r in d['records']:
            for t in r['target']:
                bcv = (int(t[:2]), int(t[2:5]), int(t[5:8]))
                out[bcv].append((r['source'], r['target'], lab))
                break
    # BGNT-BSB-manual — добор стихов НЗ вне SBLGNT (напр. Рим 16:25-27)
    d = json.load(open(CLEAR / 'eng' / 'alignments' / 'BSB' /
                       'BGNT-BSB-manual.json', encoding='utf-8'))
    bgnt_v = collections.defaultdict(list)
    for r in d['records']:
        tgts = [t[:11] for t in r['target']]
        for t in tgts:
            bcv = (int(t[:2]), int(t[2:5]), int(t[5:8]))
            bgnt_v[bcv].append((r['source'], tgts, 'clear-bgnt'))
            break
    for bcv, recs in bgnt_v.items():
        if bcv not in out:
            out[bcv] = recs
    return out


def fallback_unaligned_verse(bcv, words, bsb_tab, orig_v):
    """Фолбэк для 134 стихов без выравнивания в Clear (PSA *:0 и NEH 7:68)
    через bsb_tables.tsv + морфемы step-orig того же стиха."""
    out = {}  # w_idx → (strongs, refs, flags, src)
    ow = list(orig_v.get(bcv, []))
    if bcv[0] == 19 and bcv[2] == 0:
        ow += orig_v.get((19, bcv[1], 1), [])[:4]
    if not ow:
        return out
    wid_sts = collections.OrderedDict()
    by_base = collections.defaultdict(list)
    for w in ow:
        st = w['strong'] if w['strong'] not in PUNCT_STRONG else ''
        if st:
            wid_sts.setdefault(w['wid'], [])
            if st not in wid_sts[w['wid']]:
                wid_sts[w['wid']].append(st)
            cl = C.classic(st)
            if cl and w['wid'] not in by_base[cl]:
                by_base[cl].append(w['wid'])

    if bcv == (16, 7, 68):
        # Neh 7:68: '[They had 736 horses, 245 mules]' -> слова R в step-orig
        wids = list(wid_sts.keys())
        # #1401 horses/their, #1402..#1405 736, #1406 mules/their, #1407..#16 245
        for wi, wtxt in enumerate(words):
            wn = norm(wtxt)
            if wn in ('they', 'had', 'horses'):
                ws = [u for u in wids if u.endswith('#1401')]
            elif wn == '736':
                ws = [u for u in wids if any(
                    u.endswith(s) for s in ('#1402', '#1403', '#1404', '#1405'))]
            elif wn == '245':
                ws = [u for u in wids if any(
                    u.endswith(s) for s in ('#1407', '#15', '#16'))]
            elif wn == 'mules':
                ws = [u for u in wids if u.endswith('#1406')]
            else:
                ws = []
            ss = [s for u in ws for s in wid_sts.get(u, [])]
            if ss:
                out[wi] = (ss, ws, {'bsb-fb'}, 'bsb-tables+step-orig')
        return out

    # Надписания псалмов: в bsb_tables они лежат в начале стиха 1
    rows = bsb_tab.get((bcv[0], bcv[1], 1 if bcv[2] == 0 else bcv[2]), [])
    tab_tokens = []
    for ri, (phrase, cl_num, _) in enumerate(rows):
        pw = [norm(x) for x in phrase.split() if norm(x)]
        for x in pw:
            tab_tokens.append((x, cl_num, ri))
        if len(tab_tokens) >= len(words) + 8:
            break
    t_norms = [x for x, _, _ in tab_tokens]
    w_norms = [norm(x) for x in words]
    sm = difflib.SequenceMatcher(None, t_norms, w_norms, autojunk=False)
    t2w = {}
    pi = pj = 0
    for i1, j1, n in sm.get_matching_blocks():
        if i1 - pi == j1 - pj and (i1 - pi) > 0:
            for k in range(i1 - pi):
                t2w[pi + k] = pj + k
        for k in range(n):
            t2w[i1 + k] = j1 + k
        pi, pj = i1 + n, j1 + n
    row_groups = collections.OrderedDict()
    for ti, wi in sorted(t2w.items()):
        _, cl, ri = tab_tokens[ti]
        row_groups.setdefault(ri, (cl, []))[1].append(wi)
    for _ri, (cl, w_list) in row_groups.items():
        wids = by_base.get(cl, []) if cl else []
        if not wids and any(norm(words[w]) == 'him' for w in w_list):
            wids = [u for u, ss in wid_sts.items() if 'H9023' in ss]
        ss = []
        for u in wids:
            for s in wid_sts.get(u, []):
                if s not in ss:
                    ss.append(s)
        if ss:
            alloc = split_group(ss, w_list, words)
            for wi, (w_ss, role) in alloc.items():
                ff = {'bsb-fb', role}
                if len(w_list) > 1:
                    ff.add('grp')
                out[wi] = (w_ss, wids, ff, 'bsb-tables+step-orig')
    return out


def load_w1():
    """bcv → [words] из studybible tokenize."""
    idx = {}
    with open(WORK / 'bsb-words.jsonl', encoding='utf-8') as f:
        for line in f:
            if not line.strip() or '"_meta"' in line:
                continue
            d = json.loads(line)
            idx[(BOOK_ID[d['book']], d['chapter'], d['verse'])] = d['words']
    return idx


def map_tokens(tgts, w1_words):
    """token_id → [w1-индексы] через SequenceMatcher по норм. тексту."""
    ids = sorted(tgts)
    ctexts = [norm(tgts[i]) for i in ids]
    wtexts = [norm(w) for w in w1_words]
    sm = difflib.SequenceMatcher(None, ctexts, wtexts, autojunk=False)
    out = {}
    blocks = sm.get_matching_blocks()
    prev_i = prev_j = 0
    for (i1, j1, n) in blocks + [(len(ctexts), len(wtexts), 0)]:
        # разрешаем разрывы: токен↔токены (man's↔man+s, Ellasar—four↔2 слова)
        ci, wj = prev_i, prev_j
        while ci < i1 and wj < j1:
            if ctexts[ci] == wtexts[wj]:
                out[ids[ci]] = [wj]
                ci += 1
                wj += 1
                continue
            c2 = ctexts[ci] + (ctexts[ci + 1] if ci + 1 < i1 else '')
            c3 = c2 + (ctexts[ci + 2] if ci + 2 < i1 else '')
            w2 = wtexts[wj] + (wtexts[wj + 1] if wj + 1 < j1 else '')
            w3 = w2 + (wtexts[wj + 2] if wj + 2 < j1 else '')
            if ci + 2 <= i1 and c2 == wtexts[wj]:
                for k in (ci, ci + 1):
                    out[ids[k]] = [wj]
                ci += 2
                wj += 1
            elif ci + 3 <= i1 and c3 == wtexts[wj]:
                for k in range(ci, ci + 3):
                    out[ids[k]] = [wj]
                ci += 3
                wj += 1
            elif wj + 2 <= j1 and ctexts[ci] == w2:
                out[ids[ci]] = [wj, wj + 1]
                ci += 1
                wj += 2
            elif wj + 3 <= j1 and ctexts[ci] == w3:
                out[ids[ci]] = [wj, wj + 1, wj + 2]
                ci += 1
                wj += 3
            else:
                ci += 1
        for k in range(n):
            out[ids[i1 + k]] = [j1 + k]
        prev_i, prev_j = i1 + n, j1 + n
    return out


def main():
    mid_idx, wid_idx, orig_v = load_mid_index()
    tgt_idx, excl = load_targets()
    align = load_alignments()
    bsb_tab = C.meas.load_bsb_tables()
    w1 = load_w1()

    # кросс-канал: старый слой (классические номера) для сверки
    old = {}
    if OLD.exists():
        odb = sqlite3.connect(OLD)
        for b, c, v, w, s in odb.execute(
                'select book_id,chapter,verse,word,strong from links'):
            old[(b, c, v, w)] = s
        odb.close()

    stats = collections.Counter()
    diffs = []
    unmapped_log = []
    links = {}          # (b,c,v,word) → [strongs, refs, flags, srcs]
    for bcv, words in w1.items():
        recs = align.get(bcv)
        if not recs:
            fb_links = fallback_unaligned_verse(bcv, words, bsb_tab, orig_v)
            if fb_links:
                stats['verse_bsb_fb'] += 1
                for wi in range(len(words)):
                    key = (bcv[0], bcv[1], bcv[2], wi)
                    if wi in fb_links:
                        ss, rr, ff, src_lab = fb_links[wi]
                        links[key] = [ss, rr, set(ff), {src_lab}]
                        stats['link_bsb_fb'] += 1
                    else:
                        links[key] = [[], [], {'added', 'aux'}, {'w1-added'}]
                        stats['link_added'] += 1
            else:
                stats['verse_no_align'] += 1
            continue
        # токены стиха
        tgts = tgt_idx.get(bcv) or {}
        t2w = map_tokens(tgts, words)
        stats['tok_mapped'] += len(t2w)
        stats['tok_unmapped'] += len(tgts) - len(t2w)
        if len(tgts) - len(t2w) and len(unmapped_log) < 2000:
            left = [tgts[i] for i in tgts if i not in t2w]
            unmapped_log.append((bcv, left, words))
        ow = orig_v.get(bcv, [])
        st_gloss = collections.defaultdict(set)
        wid_to_sts = collections.defaultdict(set)
        for w_o in ow:
            st_o = w_o.get('strong') or ''
            wid_o = w_o.get('wid') or ''
            if st_o:
                for gt in re.findall(r'[A-Za-z]+', (w_o.get('gloss') or '').lower()):
                    if len(gt) >= 2:
                        st_gloss[st_o].add(gt)
                if wid_o:
                    wid_to_sts[wid_o].add(st_o)
        for src_ids, tgt_ids, src_lab in recs:
            strongs, refs, fb = [], [], False
            for sid in src_ids:
                hit = mid_idx.get(sid)
                if hit:
                    wid, st = hit
                    if wid and wid not in refs:
                        refs.append(wid)
                    if st and st not in strongs:
                        strongs.append(st)
                else:
                    stats['mid_missing'] += 1
                    wk = mid_word_key(sid)
                    wids, ws = wid_idx.get(wk, ([], []))
                    if ws:
                        fb = True
                        stats['mid_wid_fb'] += 1
                        for st in ws:
                            if st not in strongs:
                                strongs.append(st)
                        for u in wids:
                            if u not in refs:
                                refs.append(u)
                    else:
                        stats['mid_unresolved'] += 1
            w_list = []
            for tid in tgt_ids:
                if tid in excl:
                    continue
                ws_mapped = t2w.get(tid)
                if not ws_mapped:
                    stats['tgt_no_word'] += 1
                    continue
                for w in ws_mapped:
                    if w not in w_list:
                        w_list.append(w)
            multi = len(w_list) > 1
            alloc = split_group(strongs, w_list, words, st_gloss)
            for w, (w_strongs, role) in alloc.items():
                key = (bcv[0], bcv[1], bcv[2], w)
                L = links.setdefault(key, [[], [], set(), set()])
                for s in w_strongs:
                    if s not in L[0]:
                        L[0].append(s)
                # Приоритет wid, содержащих коды w_strongs этого слова
                w_st_set = set(w_strongs)
                matched_refs = [r_ for r_ in refs if wid_to_sts.get(r_, set()) & w_st_set]
                other_refs = [r_ for r_ in refs if r_ not in matched_refs]
                for r_ in (matched_refs + other_refs):
                    if r_ not in L[1]:
                        L[1].append(r_)
                if role == 'head':
                    L[2].discard('aux')
                    L[2].add('head')
                    L[0][:] = order_lex_first(L[0])
                elif 'head' not in L[2]:
                    L[2].add('aux')
                if L[0] and len(L[1]) > 1:
                    primary_s = L[0][0]
                    L[1].sort(key=lambda rw: 0 if primary_s in wid_to_sts.get(rw, set()) else (1 if wid_to_sts.get(rw, set()) & set(L[0]) else 2))
                if multi:
                    L[2].add('grp')
                if fb:
                    L[2].add('wid')
                if not w_strongs:
                    L[2].add('unresolved')
                L[3].add(src_lab)
                stats['link'] += 1

        # Добор слов w1 стиха, не попавших в Clear (редакционные отличия или added)
        for wi in range(len(words)):
            key = (bcv[0], bcv[1], bcv[2], wi)
            if key in links:
                continue
            os_ = old.get(key)
            ss, rr = [], []
            if os_:
                for cl in os_.split():
                    for w_orig in ow:
                        st = (w_orig['strong']
                              if w_orig['strong'] not in PUNCT_STRONG else '')
                        if st and C.classic(st) == C.classic(cl):
                            if st not in ss:
                                ss.append(st)
                            if w_orig['wid'] not in rr:
                                rr.append(w_orig['wid'])
            role = 'aux' if norm(words[wi]) in AUX_ENG else 'head'
            if ss:
                if role == 'head':
                    ss = order_lex_first(ss)
                links[key] = [ss, rr, {'bsb-fb', role},
                              {'bsb-tables+step-orig'}]
                stats['link_bsb_fb_word'] += 1
            else:
                links[key] = [[], [], {'added', 'aux'}, {'w1-added'}]
                stats['link_added'] += 1

    # Сверка со старым слоем: разделяем сдвиг внутри стиха (diff-shift)
    # и настоящее лексическое расхождение (diff)
    num_re = re.compile(r'^[HG]|[A-Za-z]$')
    verse_bases = collections.defaultdict(set)
    for (b, c, v, _w), (ss, _rr, _ff, _srcs) in links.items():
        for s in ss:
            verse_bases[(b, c, v)].add(int(num_re.sub('', s)))
    for key, (ss, rr, ff, srcs) in links.items():
        if 'unresolved' in ff and not ss:
            # Фолбэк через классический номер bsb_tables + морфемы стиха step-orig
            os_ = old.get(key)
            if os_:
                ow = orig_v.get((key[0], key[1], key[2]), [])
                for cl in os_.split():
                    for w in ow:
                        st = w['strong'] if w['strong'] not in PUNCT_STRONG else ''
                        if st and C.classic(st) == C.classic(cl):
                            if st not in ss:
                                ss.append(st)
                            if w['wid'] not in rr:
                                rr.append(w['wid'])
                    if not ss:
                        ss.append(cl)
                if ss:
                    if 'head' in ff:
                        ss[:] = order_lex_first(ss)
                    ff.discard('unresolved')
                    ff.add('bsb-fb')
                    srcs.add('bsb-tables+step-orig')
                    stats['unresolved_recovered'] += 1
                    continue
            continue
        ff.discard('unresolved')
        os_ = old.get(key)
        if os_ and ss:
            base = {int(num_re.sub('', s)) for s in ss}
            oset = {int(num_re.sub('', s)) for s in os_.split()}
            if not (oset <= base):
                vb = verse_bases[(key[0], key[1], key[2])]
                if oset <= vb:
                    ff.add('diff-shift')
                    stats['strong_diff_shift'] += 1
                else:
                    ff.add('diff')
                    diffs.append((key, os_, ' '.join(ss)))
                    stats['strong_diff'] += 1

    # запись
    if DST.exists():
        DST.unlink()
    db = sqlite3.connect(DST)
    db.execute('PRAGMA application_id = 0x53424D31')
    db.executescript('''
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(book_id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL,
                   ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book_id INTEGER NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book_id, marker));
CREATE TABLE blocks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book_id, chapter, seq));
CREATE TABLE spans(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   verse INTEGER, start INTEGER, len INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, block, seq));
CREATE TABLE verses(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE tokens(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    seq INTEGER NOT NULL, surface TEXT NOT NULL DEFAULT '',
                    lemma TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                    morph TEXT NOT NULL DEFAULT '', gloss TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(book_id, chapter, verse, seq));
CREATE TABLE alignment(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                       token_seq INTEGER NOT NULL, block INTEGER NOT NULL, span INTEGER NOT NULL,
                       PRIMARY KEY(book_id, chapter, verse, token_seq));
CREATE TABLE variants(id INTEGER PRIMARY KEY,
                      book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                      token_from INTEGER NOT NULL, token_to INTEGER NOT NULL);
CREATE TABLE readings(id INTEGER PRIMARY KEY, variant_id INTEGER NOT NULL,
                      seq INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '',
                      is_base INTEGER NOT NULL DEFAULT 0);
CREATE TABLE witnesses(reading_id INTEGER NOT NULL, siglum TEXT NOT NULL,
                       PRIMARY KEY(reading_id, siglum));
CREATE TABLE entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
                     norm TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '');
CREATE INDEX entries_norm ON entries(norm);
CREATE TABLE marks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                   seq INTEGER NOT NULL, offset_ms INTEGER NOT NULL,
                   dur_ms INTEGER, text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, seq));
CREATE TABLE span_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                       block INTEGER NOT NULL, blob BLOB NOT NULL,
                       PRIMARY KEY(book_id, chapter, block));
CREATE TABLE token_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE align_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE xrefs_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE links(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                   verse INTEGER NOT NULL, word INTEGER NOT NULL,
                   ref TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                   conf INTEGER NOT NULL DEFAULT 0,
                   flags TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, word));
''')

    for (b, c, v, w), (ss, rr, ff, srcs) in links.items():
        conf = (4 if 'unresolved' in ff else
                8 if 'wid' in ff else
                9 if ('bsb-fb' in ff or 'added' in ff) else 10)
        db.execute('INSERT INTO links VALUES (?,?,?,?,?,?,?,?,?)',
                   (b, c, v, w, ' '.join(rr), ' '.join(ss), conf,
                    ','.join(sorted(ff)), '+'.join(sorted(srcs))))
    meta = {
        'format_version': '1', 'id': 'engbsb-strongs',
        'title': 'BSB Strong layer (dStrong, Clear manual)',
        'language': 'en', 'direction': 'ltr', 'versification': 'eng',
        'name_profile': 'en', 'book_order': 'syn', 'version': '0.4.0',
        'license': 'CC BY 4.0',
        'attribution': 'Clear Bible WLCM/SBLGNT-BSB manual alignments '
                       '(CC BY 4.0); dStrong via step-orig (STEPBible '
                       'CC BY 4.0)',
        'source': 'clear-manual',
        'kind': 'layer', 'features': 'strongs',
        'target_id': 'engbsb',
        'tokenizer': 'w1',
        'required': '', 'content_hash': '',
    }
    th = json.loads(open(WORK / 'bsb-words.jsonl', encoding='utf-8')
                    .readline())['_meta']['target_hash']
    meta['target_hash'] = th
    meta['content_hash'] = hashlib.sha256(
        json.dumps(sorted(str(k) for k in links)).encode()).hexdigest()
    db.executemany('INSERT INTO meta VALUES (?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.close()

    stats['links_total'] = len(links)
    stats['diff_total'] = len(diffs)
    with open(WORK / 'engbsb-strongs.diffs.tsv', 'w',
              encoding='utf-8') as f:
        for k, os_, ns in diffs:
            f.write('%s\t%s\t%s\n' % ('.'.join(map(str, k)), os_, ns))
    (WORK / 'stats-bsb-layer.json').write_text(
        json.dumps(dict(stats), ensure_ascii=False, indent=1),
        encoding='utf-8')
    with open(WORK / 'unmapped.tsv', 'w', encoding='utf-8') as f:
        for bcv, left, words in unmapped_log:
            f.write('%s\t%s\t%s\n'
                    % (bcv, '|'.join(left), '|'.join(words)))
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
