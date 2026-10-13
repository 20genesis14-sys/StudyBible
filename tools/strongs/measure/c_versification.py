"""Замер C: нумерация стихов.

1. TAHOT: сколько стихов в английской нумерации имеют другую еврейскую.
2. Состав стихов (все в `eng`): STEPBible vs BSB tables vs KJV vs ESV —
   какие стихи есть у одних и нет у других.
3. `eng` ↔ `rsc` (Синодальный) через `org` по файлам
   data/versification/*.vrs (формат libpalaso: «REF = ORG_REF»):
   сколько стихов меняют номер и сколько соответствий не один-к-одному.
"""
import collections
import re
from pathlib import Path

import common as C

VRS_DIR = Path(__file__).resolve().parents[3] / 'data' / 'versification'
R = re.compile(r'(\w{3}) (\d+):(\d+)(?:-(\d+))?')


def parse_vrs(name):
    """{(book, ch, v) в этой версификации: [(book, ch, v) в org]} — только явные соответствия."""
    m = collections.defaultdict(list)
    for line in open(VRS_DIR / f'{name}.vrs', encoding='utf-8'):
        line = line.split('#')[0].strip()
        if '=' not in line:
            continue
        left, right = (s.strip() for s in line.split('=', 1))
        a, b = R.match(left), R.match(right)
        if not a or not b or a.group(1) not in C.USFM or b.group(1) not in C.USFM:
            continue
        ba, ca, va1 = C.USFM[a.group(1)], int(a.group(2)), int(a.group(3))
        va2 = int(a.group(4) or va1)
        bb, cb, vb1 = C.USFM[b.group(1)], int(b.group(2)), int(b.group(3))
        vb2 = int(b.group(4) or vb1)
        la, lb = va2 - va1 + 1, vb2 - vb1 + 1
        for i in range(max(la, lb)):
            src = (ba, ca, va1 + min(i, la - 1))
            dst = (bb, cb, vb1 + min(i, lb - 1))
            if dst not in m[src]:
                m[src].append(dst)
    return m


def main():
    step = C.load_step()
    heb_diff = collections.Counter()
    for key, words in step.items():
        if any(w.heb_ref for w in words):
            heb_diff[C.BOOKS[key[0] - 1][0]] += 1
    inv = {'STEPBible': set(step), 'BSB tables': set(C.load_bsb_tables()),
           'KJV': set(C.load_kjv()), 'ESV': set(C.load_esv())}
    allv = set().union(*inv.values())
    missing = {}
    for n, s in inv.items():
        miss = sorted(allv - s)
        missing[n] = {'count': len(miss),
                      'examples': ['%s %d:%d' % (C.BOOKS[b - 1][0], c, v) for b, c, v in miss[:25]]}

    eng, rsc = parse_vrs('eng'), parse_vrs('rsc')
    org_to_rsc = collections.defaultdict(list)
    for r, os_ in rsc.items():
        for o in os_:
            org_to_rsc[o].append(r)
    changed = non11 = 0
    examples = []
    for key in sorted(inv['STEPBible']):
        orgs = eng.get(key, [key])
        targets = []
        for o in orgs:
            targets += org_to_rsc.get(o, [o])
        targets = sorted(set(targets))
        if targets != [key]:
            changed += 1
            if len(targets) != 1 or len(orgs) != 1:
                non11 += 1
                if len(examples) < 30:
                    examples.append('%s %d:%d → %s' % (C.BOOKS[key[0] - 1][0], key[1], key[2],
                                                       ', '.join('%d:%d' % (c, v) for _, c, v in targets)))
    res = {'tahot_verses_with_hebrew_ref': dict(heb_diff), 'verse_inventory_missing': missing,
           'eng_to_rsc': {'verses_changed': changed, 'not_one_to_one': non11, 'examples': examples}}
    lines = ['# Замер C — нумерация стихов', '',
             f"TAHOT: стихов, где еврейская нумерация отличается от английской: {sum(heb_diff.values())} "
             f"(по книгам: {', '.join(f'{b} {n}' for b, n in heb_diff.most_common(12))}).", '',
             '## Состав стихов (нумерация eng)', '', '| Источник | нет стихов из общего набора | примеры |', '|---|---|---|']
    for n, r in missing.items():
        lines.append(f"| {n} | {r['count']} | {'; '.join(r['examples'][:10])} |")
    lines += ['', '## eng → rsc (через org)', '',
              f"Стихов меняют номер: {changed}; соответствие не один-к-одному: {non11}.", '',
              'Примеры не один-к-одному: ' + '; '.join(examples[:15])]
    C.write_report('C_versification', res, '\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
