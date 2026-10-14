"""Замер A: какую долю классических номеров эталонов можно однозначно
превратить в уточнённый номер (dStrong) по стиху TAHOT/TAGNT.

Для каждой пары (стих, классический номер) эталона считаем, сколько
разных dStrong в том же стихе STEPBible имеют эту основу:
  unique  — ровно один dStrong → уточнение без модели;
  multi   — несколько разных dStrong с этой основой → нужен выбор;
  none    — в стихе STEPBible такого номера нет (расхождение текста,
            другой номер у эталона, другая нумерация стиха).
"""
import collections

import common as C


def step_index(step):
    idx = {}
    for key, words in step.items():
        m = collections.defaultdict(set)
        for w in words:
            direct = {}
            for t in w.tags:
                c = C.classic(t)
                if c:
                    direct.setdefault(c, t)
            for c, t in direct.items():
                m[c].add(t)
            # греческий dStrong > 5624 (варианты NASB и др.): основа — из sStrong
            sc = C.classic(w.sstrong) if w.sstrong else None
            if sc and sc not in direct:
                m[sc].add(w.root)
        idx[key] = m
    return idx


def measure(name, gold, idx):
    cnt = collections.Counter()
    by_t = collections.defaultdict(collections.Counter)
    multi_ex = collections.Counter()
    for key, items in gold.items():
        m = dict(idx.get(key) or {})
        if key[0] == 19 and key[2] == 1 and (19, key[1], 0) in idx:
            for k0, v0 in idx[(19, key[1], 0)].items():
                m[k0] = set(m.get(k0, set())) | v0
        nums = set()
        for it in items:
            v = it[1]
            nums.update(v if isinstance(v, list) else ([v] if v else []))
        for n in nums:
            ds = m.get(n, set()) if m else set()
            r = 'none' if not ds else ('unique' if len(ds) == 1 else 'multi')
            cnt[r] += 1
            by_t['NT' if C.is_nt(key[0]) else 'OT'][r] += 1
            if r == 'multi':
                multi_ex[n] += 1
    tot = sum(cnt.values())
    res = {k: {'n': v, 'pct': C.pct(v, tot)} for k, v in cnt.items()}
    res['total'] = tot
    res['by_testament'] = {t: {k: C.pct(v, sum(c.values())) for k, v in c.items()} for t, c in by_t.items()}
    res['top_multi'] = multi_ex.most_common(25)
    return res


def main():
    step = C.load_step()
    idx = step_index(step)
    out = {}
    for name, loader in [('BSB tables', C.load_bsb_tables), ('KJV', C.load_kjv), ('ESV/TTESV', C.load_esv)]:
        out[name] = measure(name, loader(), idx)
    lines = ['# Замер A — однозначность «классический номер → уточнённый»', '',
             '| Эталон | пар (стих, номер) | однозначно | несколько dStrong | нет в стихе STEPBible |',
             '|---|---|---|---|---|']
    for name, r in out.items():
        g = lambda k: f"{r.get(k, {}).get('pct', 0)} %"
        lines.append(f"| {name} | {r['total']} | {g('unique')} | {g('multi')} | {g('none')} |")
    lines += ['', 'По заветам (доли, %):', '']
    for name, r in out.items():
        lines.append(f"- {name}: " + '; '.join(f"{t}: {d}" for t, d in sorted(r['by_testament'].items())))
    lines += ['', 'Чаще всего несколько dStrong (номер: число пар):', '']
    for name, r in out.items():
        lines.append(f"- {name}: " + ', '.join(f'{n} ({c})' for n, c in r['top_multi'][:12]))
    C.write_report('A_resolvability', out, '\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
