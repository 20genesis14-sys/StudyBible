"""Замер F: пригодность ручных разметок Clear-Bible/Alignments.

1. Для каждого набора (язык/перевод/оригинал): доля размеченных
   идентификаторов, попадающих на знаки препинания, и идентификаторы,
   которых нет в списке слов. Пунктуация никогда не размечается, поэтому
   её доля > 1 % — признак сдвига идентификаторов.
2. Для RUSSYN (Синодальный): сверка с номерами RST+ (тот же текст с
   номерами Стронга): совпадает ли номер слова MACULA с номером RST+
   на указанном русском слове; если нет — где ближайшее слово с этим
   номером (сдвиг). Плюс доля «целых» стихов.

RST+ берётся из D:\\StudyBible-data\\modules\\rstplus.sb; импортёр MyBible
сейчас теряет часть номеров (ADR 0025) — оценка совпадений немного
занижена.
"""
import collections
import glob
import json
import os
import re
import sqlite3

import common as C


def set_stats():
    rows = []
    base = C.SRC / 'clear-alignments' / 'data'
    for js in sorted(glob.glob(str(base / '*' / 'alignments' / '*' / '*.json'))):
        parts = js.split(os.sep)
        lang, ver = parts[-4], parts[-2]
        src = os.path.basename(js).split('-')[0]
        try:
            recs, tokens = C.load_clear(lang, ver, src)
        except (StopIteration, FileNotFoundError, json.JSONDecodeError) as e:
            rows.append({'set': f'{lang}/{ver}/{src}', 'error': str(e)})
            continue
        words = sum(1 for t in tokens.values() if not t[1])
        al = {t for r in recs for t in r.get('target', [])}
        punct = sum(1 for t in al if tokens.get(t, ('', False))[1])
        miss = sum(1 for t in al if t not in tokens)
        rows.append({'set': f'{lang}/{ver}/{src}', 'aligned': len(al), 'words': words,
                     'coverage_pct': C.pct(len(al) - punct - miss, words),
                     'punct_pct': C.pct(punct, len(al)), 'missing': miss,
                     'verdict': 'ok' if punct <= len(al) * 0.01 and miss <= len(al) * 0.01 else 'BROKEN'})
    return rows


def rst_index():
    db = sqlite3.connect(f"file:{(C.DATA / 'modules' / 'rstplus.sb').as_posix()}?mode=ro", uri=True)
    ords = {b: o for b, o in db.execute('select book_id, ord from books')}
    rst = collections.defaultdict(list)
    for b, ch, v, surf, st in db.execute(
            'select book_id, chapter, verse, surface, strong from tokens order by book_id, chapter, verse, seq'):
        rst['%02d%03d%03d' % (ords[b], ch, v)].append(
            (re.sub(r'[^\w]', '', surf.lower()).replace('ё', 'е'),
             {C.classic(x) for x in st.split()} - {None}))
    return rst


def russyn(testament, rst):
    src = 'WLCM' if testament == 'ot' else 'SBLGNT'
    recs, tokens = C.load_clear('rus', 'RUSSYN', src)
    mac = C.load_macula(testament)
    mnum = {k: C.macula_classic(r, testament) for k, r in mac.items()}
    byverse = collections.defaultdict(list)
    for tid, (text, p) in tokens.items():
        byverse[tid[:8]].append((tid, re.sub(r'[^\w]', '', text.lower()).replace('ё', 'е'), p))

    cache = {}

    def word_nums(v):
        if v in cache:
            return cache[v]
        out, r, j = {}, rst.get(v, []), 0
        for tid, w, p in byverse[v]:
            if p:
                continue
            for k in range(j, min(j + 4, len(r))):
                if r[k][0] == w:
                    out[tid] = r[k][1]
                    j = k + 1
                    break
        cache[v] = out
        return out

    ok = bad = 0
    deltas = collections.Counter()
    verse_recs = collections.defaultdict(list)
    for rec in recs:
        t = rec['target'][0]
        v = t[:8]
        nums = {mnum.get(s) for s in rec['source']} - {None}
        if not nums:
            continue
        wn = word_nums(v)
        if t in wn and wn[t] & nums:
            ok += 1
            verse_recs[v].append(True)
        else:
            bad += 1
            verse_recs[v].append(False)
            cands = [int(i[-3:]) - int(t[-3:]) for i, s in wn.items() if s & nums]
            if len(cands) == 1:
                deltas[cands[0]] += 1
    perfect = sum(1 for v, xs in verse_recs.items() if sum(xs) >= 0.9 * len(xs))
    return {'records_checked': ok + bad, 'match_pct': C.pct(ok, ok + bad),
            'verses': len(verse_recs), 'verses_90pct_ok': perfect,
            'verses_90pct_ok_pct': C.pct(perfect, len(verse_recs)),
            'shift_of_mismatches': deltas.most_common(12)}


def main():
    sets = set_stats()
    rst = rst_index()
    rus = {t: russyn(t, rst) for t in ('ot', 'nt')}
    lines = ['# Замер F — ручные разметки Clear-Bible/Alignments', '',
             '## Наборы', '',
             '| Набор | размечено | слов | покрытие | на пунктуации | нет в списке слов | вывод |',
             '|---|---|---|---|---|---|---|']
    for r in sets:
        if 'error' in r:
            lines.append(f"| {r['set']} | — | — | — | — | — | ошибка: {r['error']} |")
        else:
            lines.append(f"| {r['set']} | {r['aligned']} | {r['words']} | {r['coverage_pct']} % | "
                         f"{r['punct_pct']} % | {r['missing']} | {r['verdict']} |")
    lines += ['', '## RUSSYN против RST+ (номер слова MACULA = номер RST+ на указанном слове)', '']
    for t, r in rus.items():
        lines.append(f"- {t.upper()}: проверено записей {r['records_checked']}, совпало {r['match_pct']} %; "
                     f"стихов с ≥ 90 % совпадений {r['verses_90pct_ok']} из {r['verses']} "
                     f"({r['verses_90pct_ok_pct']} %); сдвиг правильного слова относительно "
                     f"указанного (слов): {r['shift_of_mismatches']}")
    lines += ['', 'Вывод: идентификаторы русских слов в RUSSYN сдвинуты вперёд относительно '
              'опубликованного списка слов (правильное слово почти всегда на 1–6 позиций '
              'раньше); сдвиг растёт к концу стиха и не объясняется одной лишь пунктуацией. '
              'В таком виде набор непригоден ни как эталон, ни как источник слоя.', '']
    C.write_report('F_clear_alignments', {'sets': sets, 'russyn_vs_rstplus': rus}, '\n'.join(lines))


if __name__ == '__main__':
    main()
