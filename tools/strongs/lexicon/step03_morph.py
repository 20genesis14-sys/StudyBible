"""T3: TEHMC/TEGMC → таблица morph.

Две секции в каждом файле:
  BRIEF — 'CODE\texample\tmeaning' (лексиконные коды, как в TBESH Morph)
  FULL  — блоки: 'CODE\tFunction=...' + 3 строки с табом
          (expansion, explanation, example), разделитель '$'

Выход morph.json: {code: {lang, kind, short, long, example}}
и отчёт покрытия всех кодов, увиденных в TAHOT/TAGNT (morph-codes.json).
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

MC = C.STEP / 'Morphology codes'


def parse(fname, lang):
    brief, full = {}, {}
    sec = None
    lines = open(MC / fname, encoding='utf-8-sig').read().splitlines()
    i = 0
    while i < len(lines):
        ln = lines[i].rstrip('\n')
        if 'BRIEF LEXICAL MORPHOLOGY' in ln or ln.startswith('BRIEF MORPHOLOGY'):
            sec = 'brief'
        elif 'FULL MORPHOLOGY CODES' in ln:
            sec = 'full'
        elif sec == 'brief':
            c = ln.split('\t')
            if len(c) >= 3 and c[0].strip() and not c[0].startswith(('#', '=')):
                brief[c[0].strip()] = (c[2].strip(), c[1].strip())
        elif sec == 'full' and ln and ln[0] not in ' \t=$' and '=' in ln:
            code = ln.split('\t')[0].strip()
            if code and not code.startswith('('):
                cont = []
                j = i + 1
                while j < len(lines) and len(cont) < 3 \
                        and lines[j].startswith('\t'):
                    cont.append(lines[j].strip())
                    j += 1
                if cont:
                    full[code] = (
                        ln.split('\t', 1)[1].strip(),
                        cont[0] if len(cont) > 0 else '',
                        cont[1] if len(cont) > 1 else '',
                        cont[2] if len(cont) > 2 else '')
        i += 1
    return brief, full


def main():
    bh, fh = parse(
        'TEHMC - Translators Expansion of Hebrew Morphology Codes - STEPBible.org CC BY.txt', 'hbo')
    bg, fg = parse(
        'TEGMC - Translators Expansion of Greek Morphhology Codes - STEPBible.org CC BY.txt', 'grc')

    out = {}
    for code, (mean, ex) in bh.items():
        out[code] = dict(lang='hbo', kind='brief', short=mean, long='', example=ex)
    for code, (mean, ex) in bg.items():
        out[code] = dict(lang='grc', kind='brief', short=mean, long='', example=ex)
    for code, (f, exp, expl, ex) in fh.items():
        out[code] = dict(lang='hbo', kind='full', short=exp, long=expl, example=ex,
                         funcs=f)
    for code, (f, exp, expl, ex) in fg.items():
        out[code] = dict(lang='grc', kind='full', short=exp, long=expl, example=ex,
                         funcs=f)
    seen = set(C.read_json('morph-codes.json'))
    # в тексте у продолжения морфемы опущена языковая буква
    # ('HC/Vqu3mp' → HC + Vqu3mp) — дублируем запись под виденным кодом
    via_prefix = {}
    for code in sorted(seen - set(out)):
        for pref in ('H', 'A'):
            if pref + code in out:
                r = dict(out[pref + code])
                r['funcs'] = r.get('funcs', '') + \
                    f' [text writes {code}: lang letter inherited]'
                out[code] = r
                via_prefix[code] = pref + code
                break
    covered = seen & set(out)
    missing = sorted(seen - set(out))
    C.write_json('morph.json', out)

    rpt = f"""# T3: морфология

- Кратких кодов: иврит {len(bh)}, греч. {len(bg)}
- Полных кодов: иврит {len(fh)}, греч. {len(fg)}
- Добавлено алиасов по унаследованной языковой букве: {len(via_prefix)}
- Всего в morph: **{len(out)}**
- Кодов увидено в тексте (T1): {len(seen)}, покрыто: **{len(covered)}** ({C.pct(len(covered), len(seen))})
- Не покрыто: **{len(missing)}** {missing[:60]}
"""
    (C.WORK / 'report-t3.md').write_text(rpt, encoding='utf-8')
    print(rpt)


if __name__ == '__main__':
    main()
