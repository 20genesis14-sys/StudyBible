"""Привязка mid (MACULA token id) к спанам step-orig.

ВЗ: WLCM.tsv — id 'o'+BBCCCVVVWWWP (морфема = слово+часть).
НЗ: SBLGNT.tsv — id 'n'+BBCCCVVVWWW (слово, без части).

Правило: постихово считаем слова TAHOT/TAGNT (у TAGNT — только слова
с изданием SBL) и токены источника; если количества равны — назначаем
позиционно и проверяем совпадение форм (без огласовок/пунктуации).
Несовпавшие стихи — без mid, в отчёт. Итог — stats-macula.json.
"""
import collections
import difflib
import json
import re
import sys
import unicodedata

sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent.parent / 'lexicon'))
import common as C  # noqa: E402

WORK = C.DATA / 'work' / 'strongs' / 'orig'
SRC = C.SRC / 'clear-alignments' / 'data' / 'sources'

PUNCT = re.compile(r'[.,;:!?׃׀—–\-()\[\]«»"\'’‘“”·\u037e\u0387⸀⸂⸃]')


def norm_grc(s):
    s = ''.join(ch for ch in unicodedata.normalize('NFD', s)
                if unicodedata.category(ch) != 'Mn')
    return PUNCT.sub('', s).casefold()


def norm_heb(s):
    return ''.join(ch for ch in s
                   if 'א' <= ch <= 'ת' or ch in 'ףץםןך')


def load_wlcm():
    """bcv → {www: [part_char,...]} упорядоченно; вернуть также формы."""
    words = collections.defaultdict(lambda: collections.defaultdict(list))
    forms = collections.defaultdict(dict)
    with open(SRC / 'WLCM.tsv', encoding='utf-8') as f:
        next(f)
        for line in f:
            c = line.rstrip('\n').split('\t')
            if len(c) < 3 or not c[0].startswith('o'):
                continue
            tid = c[0]
            b, ch, v, w, p = (int(tid[1:3]), int(tid[3:6]), int(tid[6:9]),
                              int(tid[9:12]), tid[12] if len(tid) > 12 else '0')
            words[(b, ch, v)][w].append(p)
            forms[(b, ch, v)].setdefault(w, []).append(c[2])
    out = {}
    for bcv, ws in words.items():
        out[bcv] = [(w, ws[w], forms[bcv][w]) for w in sorted(ws)]
    return out


def load_nt_tsv(fname):
    words = collections.defaultdict(list)
    with open(SRC / fname, encoding='utf-8') as f:
        next(f)
        for line in f:
            c = line.rstrip('\n').split('\t')
            if len(c) < 3 or not c[0].startswith('n'):
                continue
            tid = c[0]
            b, ch, v = int(tid[1:3]), int(tid[3:6]), int(tid[6:9])
            words[(b, ch, v)].append((tid, c[2].rstrip('*')))
    return {bcv: ws for bcv, ws in words.items()}


def word_groups(spans):
    """спаны → [(swid, [span,...]), ...] в порядке появления."""
    groups = collections.OrderedDict()
    for w in spans:
        groups.setdefault(w.get('swid') or w['wid'], []).append(w)
    return list(groups.items())


def has_heb_letter(s):
    return any('א' <= ch <= 'ת' or ch in 'ףץםןך' for ch in s)


def assign_ot_group(gs, bcv, www, parts, stats):
    """Назначить mid морфемам одного слова ВЗ."""
    if len(gs) != len(parts):
        gs = [g for g in gs if has_heb_letter(g['gr'])]
    if len(gs) != len(parts):
        stats['ot_part_mismatch'] += 1
        return False
    for g, p in zip(gs, parts):
        g['mid'] = 'o%02d%03d%03d%03d%s' % (bcv[0], bcv[1], bcv[2], www, p)
        stats['ot_mid'] += 1
    return True


def assign_ot_by_sbcv(sbcv, spans, wlcm, stats):
    groups = word_groups(spans)
    src = wlcm.get(sbcv, [])
    if not src:
        stats['ot_count_mismatch'] += 1
        return
    tforms = [norm_heb(''.join(g['gr'] for g in gs)) for _, gs in groups]
    sforms = [norm_heb(''.join(sf)) for _, _, sf in src]
    if len(groups) == len(src):
        stats['ot_verses_aligned'] += 1
    else:
        stats['ot_count_mismatch'] += 1
        stats['ot_mismatch_words'] += abs(len(groups) - len(src))

    sm = difflib.SequenceMatcher(None, tforms, sforms, autojunk=False)
    blocks = sm.get_matching_blocks()
    pi = pj = 0
    for i1, j1, n in blocks:
        # В разрывах 1-к-1 (Ketiv/Qere или орфография) проверяем число частей
        if i1 - pi == j1 - pj and (i1 - pi) > 0:
            for k in range(i1 - pi):
                _, gs = groups[pi + k]
                www, parts, _ = src[pj + k]
                if not assign_ot_group(gs, sbcv, www, parts, stats):
                    stats['ot_form_mismatch'] += 1
        elif i1 > pi:
            stats['ot_form_mismatch'] += (i1 - pi)
        for k in range(n):
            _, gs = groups[i1 + k]
            www, parts, _ = src[j1 + k]
            assign_ot_group(gs, sbcv, www, parts, stats)
        pi, pj = i1 + n, j1 + n


def assign_nt(verse, sbl, bgnt, stats):
    bcv = (verse['b'], verse['c'], verse['v'])
    ws = [w for w in verse['w'] if 'SBL' in w['ed'].split('+')]
    src = sbl.get(bcv, [])
    if src and ws:
        if len(ws) == len(src):
            stats['nt_verses_aligned'] += 1
        else:
            stats['nt_count_mismatch'] += 1
        tforms = [norm_grc(w['gr']) for w in ws]
        sforms = [norm_grc(sf) for _, sf in src]
        sm = difflib.SequenceMatcher(None, tforms, sforms, autojunk=False)
        pi = pj = 0
        for i1, j1, n in sm.get_matching_blocks():
            if i1 - pi == j1 - pj and (i1 - pi) > 0:
                for k in range(i1 - pi):
                    ws[pi + k]['mid'] = src[pj + k][0]
                    stats['nt_mid'] += 1
            for k in range(n):
                ws[i1 + k]['mid'] = src[j1 + k][0]
                stats['nt_mid'] += 1
            pi, pj = i1 + n, j1 + n
    # Добор из BGNT (Рим 16:25-27 и слова вне SBLGNT)
    bsrc = bgnt.get(bcv, [])
    if bsrc and any(not w.get('mid') for w in verse['w']):
        bws = [w for w in verse['w']
               if any(e in w['ed'].split('+') for e in ('Byz', 'TR', 'SBL', 'NA28'))]
        tforms = [norm_grc(w['gr']) for w in bws]
        sforms = [norm_grc(sf) for _, sf in bsrc]
        sm = difflib.SequenceMatcher(None, tforms, sforms, autojunk=False)
        for i1, j1, n in sm.get_matching_blocks():
            for k in range(n):
                if not bws[i1 + k].get('mid'):
                    bws[i1 + k]['mid'] = bsrc[j1 + k][0]
                    stats['nt_mid_bgnt'] += 1


def main():
    wlcm = load_wlcm()
    sbl = load_nt_tsv('SBLGNT.tsv')
    bgnt = load_nt_tsv('BGNT.tsv')
    stats = collections.Counter()
    verses = []
    ot_by_sbcv = collections.defaultdict(list)
    with open(WORK / 'orig-words.jsonl', encoding='utf-8') as f:
        for line in f:
            v = json.loads(line)
            verses.append(v)
            if v['b'] < 40:
                stats['ot_verses'] += 1
                for w in v['w']:
                    sbcv = tuple(w.get('sbcv') or (v['b'], v['c'], v['v']))
                    ot_by_sbcv[sbcv].append(w)
            else:
                stats['nt_verses'] += 1
                assign_nt(v, sbl, bgnt, stats)
    for sbcv, spans in ot_by_sbcv.items():
        assign_ot_by_sbcv(sbcv, spans, wlcm, stats)
    with open(WORK / 'orig-words.jsonl', 'w', encoding='utf-8') as out:
        for v in verses:
            out.write(json.dumps(v, ensure_ascii=False) + '\n')
    (WORK / 'stats-macula.json').write_text(
        json.dumps(dict(stats), ensure_ascii=False, indent=1),
        encoding='utf-8')
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
