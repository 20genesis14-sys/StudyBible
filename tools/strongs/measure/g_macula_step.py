"""Замер G: пословное соответствие MACULA ↔ TAHOT/TAGNT.

ВЗ: слова MACULA (WLC, еврейская нумерация, слово = WWW в id, части P
объединяются) против слов TAHOT того же еврейского стиха. Совпадение —
пересечение классических номеров слова (у TAHOT приставки H9xxx номера не
имеют, у MACULA имеют — поэтому сравниваем множества). Сопоставление
жадное, по порядку, с заглядыванием вперёд на 3 слова.

НЗ: слова MACULA SBLGNT против слов TAGNT, у которых в editions есть SBL,
по порядку и классическому номеру.
"""
import collections
import re

import common as C

LOOK = 3


def greedy(a, b):
    """a, b — списки (id, set_of_classics). Возвращает [(ia, ib)] — по номеру."""
    pairs, j = [], 0
    for i, (_, sa) in enumerate(a):
        for k in range(j, min(j + LOOK + 1, len(b))):
            if sa & b[k][1]:
                pairs.append((i, k))
                j = k + 1
                break
    return pairs


def fill_gaps(pairs, na, nb):
    """Пары по позиции в промежутках между совпадениями, если длины промежутков равны."""
    out = []
    prev = (-1, -1)
    for p in pairs + [(na, nb)]:
        ga, gb = p[0] - prev[0] - 1, p[1] - prev[1] - 1
        if ga == gb and ga > 0:
            out += [(prev[0] + 1 + d, prev[1] + 1 + d) for d in range(ga)]
        prev = p
    return out


def ot():
    mac = C.load_macula('ot')
    mv = collections.defaultdict(lambda: collections.OrderedDict())
    for xid, r in mac.items():
        m = re.match(r'(\w+) (\d+):(\d+)', r['ref'])
        key = (C.USFM[m.group(1)], int(m.group(2)), int(m.group(3)))
        wid = xid[:12]
        mv[key].setdefault(wid, set())
        n = C.macula_classic(r, 'ot')
        if n:
            mv[key][wid].add(n)
    step = C.load_step('ot')
    sv = collections.defaultdict(list)
    for key, words in step.items():
        for w in words:
            if w.heb_ref:
                hc, hv = (int(x) for x in w.heb_ref.split('.'))
                hk = (key[0], hc, hv)
            else:
                hk = key
            sv[hk].append((w.addr, set(w.classics())))
    return compare(mv, sv, 'OT')


def nt():
    mac = C.load_macula('nt')
    mv = collections.defaultdict(list)
    for xid, r in mac.items():
        key = (int(xid[1:3]), int(xid[3:6]), int(xid[6:9]))
        n = C.macula_classic(r, 'nt')
        mv[key].append((xid, {n} if n else set()))
    step = C.load_step('nt')
    sv = collections.defaultdict(list)
    for key, words in step.items():
        for w in words:
            if 'SBL' in w.editions:
                sv[key].append((w.addr, set(w.classics())))
    return compare({k: collections.OrderedDict(v) for k, v in mv.items()}, sv, 'NT')


def compare(mv, sv, label):
    mac_words = step_words = matched = by_pos = 0
    no_verse = 0
    unmatched = collections.Counter()
    for key, words in mv.items():
        a = list(words.items())
        mac_words += len(a)
        b = sv.get(key)
        if not b:
            no_verse += len(a)
            continue
        step_words += len(b)
        p = greedy(a, b)
        g = fill_gaps(p, len(a), len(b))
        matched += len(p)
        by_pos += len(g)
        got = {i for i, _ in p} | {i for i, _ in g}
        for i, (wid, s) in enumerate(a):
            if i not in got:
                unmatched[','.join(sorted(s)) or '—'] += 1
    return {'testament': label, 'macula_words_with_strong': mac_words, 'step_words_in_same_verses': step_words,
            'matched': matched, 'matched_by_position': by_pos,
            'matched_total_pct': C.pct(matched + by_pos, mac_words),
            'matched_pct_of_macula': C.pct(matched, mac_words),
            'macula_words_in_verses_missing_in_step': no_verse, 'top_unmatched': unmatched.most_common(15)}


def main():
    res = [ot(), nt()]
    lines = ['# Замер G — соответствие слов MACULA ↔ TAHOT/TAGNT', '',
             '| Завет | слов MACULA | по номеру | по позиции в промежутке | всего | слов в стихах, которых нет в STEPBible |',
             '|---|---|---|---|---|---|']
    for r in res:
        lines.append(f"| {r['testament']} | {r['macula_words_with_strong']} | {r['matched']} "
                     f"({r['matched_pct_of_macula']} %) | {r['matched_by_position']} | "
                     f"{r['matched_total_pct']} % | {r['macula_words_in_verses_missing_in_step']} |")
    lines += ['', 'Чаще всего не сопоставлены (номера MACULA: число):', '']
    for r in res:
        lines.append(f"- {r['testament']}: " + ', '.join(f'{n} ({c})' for n, c in r['top_unmatched'][:12]))
    C.write_report('G_macula_step', res, '\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
