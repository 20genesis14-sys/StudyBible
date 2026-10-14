"""Замер D: расхождения исходных текстов и соглашений нумерации.

Для каждой пары (стих, классический номер) эталона:
  found          — номер есть среди слов STEPBible того издания, с
                   которого сделан перевод (НЗ: KJV → TR «K», BSB/ESV → NA «N»;
                   ВЗ — все слова);
  other_edition  — номер есть в стихе, но только у слов другого издания
                   (настоящее расхождение исходных текстов);
  form_alias     — эталон пользуется «номером формы» (G2076 «он есть»),
                   а STEPBible — номером леммы (G1510); связь берётся из
                   TBESH/TBESG («= a Form of», «= a Spelling of»);
  absent         — номера нет нигде в стихе.
"""
import collections
import re

import common as C


def alias_map():
    amap = {}
    for name in ('TBESH', 'TBESG'):
        p = next((C.STEP / 'Lexicons').glob(f'{name}*.txt'))
        for line in open(p, encoding='utf-8-sig'):
            c = line.rstrip('\n').split('\t')
            if len(c) < 3 or not re.match(r'[HG]\d', c[0]):
                continue
            if re.search(r'= a (Form|Spelling) of', c[1]):
                a, b = C.classic(c[0]), C.classic(c[2])
                if a and b and a != b:
                    amap[a] = b
    return amap


def edition_ok(w, ed):
    if w.key[0] < 40 or ed is None:
        return True
    t = w.type.upper()
    return ed in t


def measure(gold, step, amap, ed):
    cnt = collections.Counter()
    absent = collections.Counter()
    other = collections.Counter()
    for key, items in gold.items():
        words = list(step.get(key) or [])
        if key[0] == 19 and key[2] == 1 and (19, key[1], 0) in step:
            words = list(step[(19, key[1], 0)]) + words
        if not words:
            continue
        mine, alls = set(), set()
        for w in words:
            cs = set(w.classics())
            alls |= cs
            if edition_ok(w, ed):
                mine |= cs
        nums = set()
        for it in items:
            v = it[1]
            nums.update(v if isinstance(v, list) else ([v] if v else []))
        nt = 'NT' if C.is_nt(key[0]) else 'OT'
        for n in nums:
            if n in mine:
                r = 'found'
            elif amap.get(n) in mine:
                r = 'form_alias'
            elif n in alls or amap.get(n) in alls:
                r = 'other_edition'
                other[n] += 1
            else:
                r = 'absent'
                absent[n] += 1
            cnt[(nt, r)] += 1
    res = {}
    for t in ('OT', 'NT'):
        tot = sum(v for (tt, _), v in cnt.items() if tt == t)
        res[t] = {r: C.pct(cnt[(t, r)], tot) for r in ('found', 'form_alias', 'other_edition', 'absent')}
        res[t]['pairs'] = tot
    res['top_absent'] = absent.most_common(20)
    res['top_other_edition'] = other.most_common(15)
    return res


def main():
    step = C.load_step()
    amap = alias_map()
    out = {}
    for name, loader, ed in [('BSB tables', C.load_bsb_tables, 'N'), ('KJV', C.load_kjv, 'K'),
                             ('ESV/TTESV', C.load_esv, 'N')]:
        out[name] = measure(loader(), step, amap, ed)
    lines = ['# Замер D — расхождения исходных текстов и нумерации', '',
             f'Связей «форма → лемма» из TBESH/TBESG: {len(amap)}.', '',
             '| Эталон | Завет | пар | есть в своём издании | номер формы → лемма | только в другом издании | нет в стихе |',
             '|---|---|---|---|---|---|---|']
    for name, r in out.items():
        for t in ('OT', 'NT'):
            x = r[t]
            lines.append(f"| {name} | {t} | {x['pairs']} | {x['found']} % | {x['form_alias']} % | "
                         f"{x['other_edition']} % | {x['absent']} % |")
    lines += ['', 'Чаще всего нет в стихе (номер: пар):', '']
    for name, r in out.items():
        lines.append(f"- {name}: " + ', '.join(f'{n} ({c})' for n, c in r['top_absent'][:12]))
    lines += ['', 'Только в другом издании:', '']
    for name, r in out.items():
        lines.append(f"- {name}: " + ', '.join(f'{n} ({c})' for n, c in r['top_other_edition'][:10]))
    C.write_report('D_textual_basis', out, '\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
