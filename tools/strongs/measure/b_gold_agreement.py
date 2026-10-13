"""Замер B: согласие эталонов между собой — потолок качества для порога.

1. Пословно на одном тексте (BSB): BSB tables ↔ ручная разметка BSB от
   Clear (WLCM / SBLGNT). Слова двух источников сопоставляются по тексту
   (difflib), затем сравниваются классические номера. Отдельно —
   значимые/служебные слова, ВЗ/НЗ.
2. По стиху (разные тексты): множества классических номеров стиха у
   BSB tables, Clear BSB, KJV, ESV/TTESV — средняя доля номеров A,
   найденных в B (и обратно).
"""
import collections
import difflib
import re

import common as C

TOK = re.compile(r"[A-Za-z0-9’']+")


def bsb_tables_words(bsbt):
    out = {}
    for key, rows in bsbt.items():
        ws = []
        for eng, num, _ in rows:
            for t in TOK.findall(eng):
                ws.append((t.lower().replace('’', "'"), num))
        out[key] = ws
    return out


def clear_bsb_words():
    out = collections.defaultdict(list)
    for testament, src in (('ot', 'WLCM'), ('nt', 'SBLGNT')):
        recs, tokens = C.load_clear('eng', 'BSB', src)
        mac = C.load_macula(testament)
        num = {}
        for k, r in mac.items():
            num[k] = C.macula_classic(r, testament)
        tnum = collections.defaultdict(set)
        for rec in recs:
            ns = set()
            for s in rec['source']:
                n = num.get(s) or num.get(s[:-1]) or num.get(s + '1')
                if n:
                    ns.add(n)
            for t in rec['target']:
                tnum[t] |= ns
        for tid in sorted(tokens):
            text, p = tokens[tid]
            if p:
                continue
            key = (int(tid[0:2]), int(tid[2:5]), int(tid[5:8]))
            for t in TOK.findall(text):
                out[key].append((t.lower().replace('’', "'"), tnum.get(tid, set())))
    return out


def word_level(a, b):
    stat = collections.defaultdict(collections.Counter)
    for key in a.keys() & b.keys():
        wa, wb = a[key], b[key]
        sm = difflib.SequenceMatcher(None, [w for w, _ in wa], [w for w, _ in wb], autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag != 'equal':
                continue
            for i, j in zip(range(i1, i2), range(j1, j2)):
                word, na = wa[i]
                nb = wb[j][1]
                cls = ('NT' if C.is_nt(key[0]) else 'OT') + '/' + (
                    'function' if word in C.FUNCTION_WORDS else 'content')
                s = stat[cls]
                s['words'] += 1
                if not na and not nb:
                    s['both_untagged'] += 1
                elif na and na in nb:
                    s['agree'] += 1
                elif na and nb:
                    s['differ'] += 1
                elif na:
                    s['only_bsbtables'] += 1
                else:
                    s['only_clear'] += 1
    res = {}
    for cls, s in sorted(stat.items()):
        for k in ('agree', 'differ', 'only_bsbtables', 'only_clear', 'both_untagged'):
            s[k] += 0
        tagged = s['agree'] + s['differ'] + s['only_bsbtables'] + s['only_clear']
        res[cls] = dict(s, tagged=tagged, agree_pct_of_tagged=C.pct(s['agree'], tagged))
    return res


def verse_sets(gold):
    out = {}
    for key, items in gold.items():
        s = set()
        for it in items:
            v = it[1]
            if isinstance(v, (list, set)):
                s |= set(v)
            elif v:
                s.add(v)
        if s:
            out[key] = s
    return out


def pair(a, b):
    ra, rb, n = 0.0, 0.0, 0
    for key in a.keys() & b.keys():
        sa, sb = a[key], b[key]
        ra += len(sa & sb) / len(sa)
        rb += len(sa & sb) / len(sb)
        n += 1
    return {'verses': n, 'A_in_B_pct': C.pct(ra, n), 'B_in_A_pct': C.pct(rb, n)}


def main():
    bsbt = C.load_bsb_tables()
    a = bsb_tables_words(bsbt)
    b = clear_bsb_words()
    wl = word_level(a, b)
    sets = {'BSB tables': verse_sets(bsbt), 'Clear BSB': verse_sets(b),
            'KJV': verse_sets(C.load_kjv()), 'ESV/TTESV': verse_sets(C.load_esv())}
    names = list(sets)
    pairs = {f'{x} ↔ {y}': pair(sets[x], sets[y]) for i, x in enumerate(names) for y in names[i + 1:]}
    lines = ['# Замер B — согласие эталонов', '',
             '## Пословно: BSB tables ↔ Clear BSB (один текст BSB)', '',
             '| Класс | слов сопоставлено | размечено хоть в одном | совпало | разные номера | только BSB tables | только Clear | согласие |',
             '|---|---|---|---|---|---|---|---|']
    for cls, s in wl.items():
        lines.append(f"| {cls} | {s['words']} | {s['tagged']} | {s['agree']} | {s['differ']} | "
                     f"{s['only_bsbtables']} | {s['only_clear']} | {s['agree_pct_of_tagged']} % |")
    lines += ['', '## По стиху: доля номеров A, найденных в стихе B', '',
              '| Пара A ↔ B | стихов | A в B | B в A |', '|---|---|---|---|']
    for k, r in pairs.items():
        lines.append(f"| {k} | {r['verses']} | {r['A_in_B_pct']} % | {r['B_in_A_pct']} % |")
    C.write_report('B_gold_agreement', {'word_level_bsb': wl, 'verse_sets': pairs}, '\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
