"""T2: TBESH/TBESG → карта eStrong/dStrong/uStrong, связи, lex_base.

Колонки: eStrong | dStrong ('H0001H = a Part of') | uStrong-or-related |
слово | транслитерация | morph | gloss | Meaning(пропускаем — OLB).

При связи (' = a Part of' и т.п.) в колонке uStrong стоит список
связанных номеров → related. Meaning не выносим (лицензия OLB).

Выход work/strongs/lexicon/lex-map.json:
  {dStrong: {e, u, base, rel, related[], lemma, xlit, pos, gloss}}
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

LEX = C.STEP / 'Lexicons'
# eStrong бывает со строчной буквой ('H0122a') — приводим к верхнему
DSTR = re.compile(r'([HG]\d{4,5}[A-Za-z]?)')
REL = re.compile(r'=\s*(.*)$')


def up(code):
    return code[:-1].upper() + code[-1] if code and code[-1].islower() else code


def parse(fname):
    rows = {}
    n_rel = {}
    with open(LEX / fname, encoding='utf-8-sig') as f:
        for line in f:
            c = line.rstrip('\n').split('\t')
            if len(c) < 8 or not DSTR.fullmatch(c[0].strip()):
                continue
            e, ds, us = up(c[0].strip()), c[1].strip(), c[2].strip()
            m = REL.search(ds)
            rel = m.group(1).strip() if m else ''
            dsm = DSTR.search(ds)
            if not dsm:
                continue
            d = up(dsm.group(1))
            related = [up(x) for x in re.findall(r'[HG]\d{4,5}[A-Za-z]?', us)
                       if up(x) != d]
            u = '' if rel else up(us.split(',')[0].strip())
            rows[d] = dict(
                e=e, u=u, base=C.classic(d), rel=rel, related=related,
                lemma=c[3].strip(), xlit=c[4].strip(), pos=c[5].strip(),
                gloss=c[6].strip())
            if rel:
                n_rel[rel] = n_rel.get(rel, 0) + 1
    return rows, n_rel


def main():
    heb, relh = parse(
        'TBESH - Translators Brief lexicon of Extended Strongs for Hebrew - STEPBible.org CC BY.txt')
    grc, relg = parse(
        'TBESG - Translators Brief lexicon of Extended Strongs for Greek - STEPBible.org CC BY.txt')
    rows = {**heb, **grc}
    C.write_json('lex-map.json', rows)

    # проверка против инвентаря T1; коды текста без записи в TBESH/G
    # разрешаем через уникальный базовый номер
    core = C.read_json('lex-core.json')
    base_ix = {}
    for d, r in rows.items():
        if r['base']:
            base_ix.setdefault(r['base'], []).append(d)
    alias, missing, ambiguous = {}, [], []
    for k in sorted(core):
        if k in rows:
            continue
        cand = base_ix.get(C.classic(k) or k, [])
        if len(cand) == 1:
            alias[k] = cand[0]
        elif cand:
            # 1) точное совпадение с главным кандидатом (k+'G' или по глоссу)
            g0 = (core[k].get('glosses') or [''])[0]
            exact = [c for c in cand if rows[c]['u'] and rows[c]['gloss'] == g0]
            if len(exact) == 1:
                alias[k] = exact[0]
            elif k + 'G' in cand:
                alias[k] = k + 'G'
            else:
                alias[k] = cand[0]
        else:
            missing.append(k)
    extra = sorted(k for k in rows if k not in core)
    C.write_json('lex-alias.json', alias)

    base_map = {}
    for d, r in rows.items():
        base_map.setdefault(r['base'], []).append(d)

    rpt = f"""# T2: TBESH/TBESG

- Записей: **{len(rows)}** (иврит {len(heb)}, греч. {len(grc)})
- Базовых номеров: {len(base_map)}
- Связи (иврит): {relh}
- Связи (греч.): {relg}
- dStrong текста без записи в TBESH/G: **{len(missing) + len(ambiguous) + len(alias)}**
  - однозначный алиас по базе: {len(alias)}
  - неоднозначные (несколько буквенных у базы): {len(ambiguous)} {ambiguous[:15]}
  - без кандидатов: {len(missing)} {missing[:40]}
- В TBESH/G, но не встречается в тексте: {len(extra)} (запас для LXX/вариантов)

Примеры:
{chr(10).join('- `%s` %s' % (k, rows[k]) for k in ['H1254A', 'H0001H', 'G2424H', 'G2424I', 'H9003'] if k in rows)}
"""
    (C.WORK / 'report-t2.md').write_text(rpt, encoding='utf-8')
    print(rpt)


if __name__ == '__main__':
    main()
