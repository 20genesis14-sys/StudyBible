"""Привязка mid (MACULA token id) к спанам step-orig.

ВЗ: WLCM.tsv — id 'o'+BBCCCVVVWWWP (морфема = слово+часть).
НЗ: SBLGNT.tsv — id 'n'+BBCCCVVVWWW (слово, без части).

Правило: постихово считаем слова TAHOT/TAGNT (у TAGNT — только слова
с изданием SBL) и токены источника; если количества равны — назначаем
позиционно и проверяем совпадение форм (без огласовок/пунктуации).
Несовпавшие стихи — без mid, в отчёт. Итог — stats-macula.json.
"""
import collections
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
                   if 'א' <= ch <= 'ת' or ch in 'ףץםןך' or ch == '־')


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


def load_sblgnt():
    words = collections.defaultdict(list)
    with open(SRC / 'SBLGNT.tsv', encoding='utf-8') as f:
        next(f)
        for line in f:
            c = line.rstrip('\n').split('\t')
            if len(c) < 3 or not c[0].startswith('n'):
                continue
            tid = c[0]
            b, ch, v = int(tid[1:3]), int(tid[3:6]), int(tid[6:9])
            words[(b, ch, v)].append((tid, c[2]))
    return {bcv: ws for bcv, ws in words.items()}


def word_groups(spans):
    """спаны → [(wid, [span,...]), ...] в порядке wid."""
    groups = collections.OrderedDict()
    for w in spans:
        groups.setdefault(w['wid'], []).append(w)
    return list(groups.items())


def assign_ot(verse, wlcm, stats):
    ws = verse['w']
    bcv = (verse['b'], verse['c'], verse['v'])
    groups = word_groups(ws)
    src = wlcm.get(bcv, [])
    if len(groups) != len(src):
        stats['ot_count_mismatch'] += 1
        stats['ot_mismatch_words'] += abs(len(groups) - len(src))
        return
    stats['ot_verses_aligned'] += 1
    for (wid, gs), (www, parts, sforms) in zip(groups, src):
        tform = norm_heb(''.join(g['gr'] for g in gs))
        sform = norm_heb(''.join(sforms))
        if tform != sform:
            stats['ot_form_mismatch'] += 1
            continue
        if len(gs) != len(parts):
            # пунктуационные морфемы (׃ и т.п.) в WLCM отсутствуют —
            # повторная попытка без них
            gs = [g for g in gs if norm_heb(g['gr'])]
        if len(gs) != len(parts):
            stats['ot_part_mismatch'] += 1
            continue
        for g, p in zip(gs, parts):
            g['mid'] = 'o%02d%03d%03d%03d%s' % (bcv[0], bcv[1], bcv[2],
                                                www, p)
            stats['ot_mid'] += 1


def assign_nt(verse, sbl, stats):
    ws = [w for w in verse['w'] if 'SBL' in w['ed'].split('+')]
    bcv = (verse['b'], verse['c'], verse['v'])
    src = sbl.get(bcv, [])
    if len(ws) != len(src):
        stats['nt_count_mismatch'] += 1
        return
    stats['nt_verses_aligned'] += 1
    for w, (tid, sform) in zip(ws, src):
        if norm_grc(w['gr']) != norm_grc(sform):
            stats['nt_form_mismatch'] += 1
            continue
        w['mid'] = tid
        stats['nt_mid'] += 1


def main():
    wlcm = load_wlcm()
    sbl = load_sblgnt()
    stats = collections.Counter()
    verses = []
    with open(WORK / 'orig-words.jsonl', encoding='utf-8') as f:
        for line in f:
            verses.append(json.loads(line))
    for verse in verses:
        if verse['b'] < 40:
            stats['ot_verses'] += 1
            assign_ot(verse, wlcm, stats)
        else:
            stats['nt_verses'] += 1
            assign_nt(verse, sbl, stats)
    with open(WORK / 'orig-words.jsonl', 'w', encoding='utf-8') as out:
        for v in verses:
            out.write(json.dumps(v, ensure_ascii=False) + '\n')
    (WORK / 'stats-macula.json').write_text(
        json.dumps(dict(stats), ensure_ascii=False, indent=1),
        encoding='utf-8')
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
