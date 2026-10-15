"""T1: инвентарь dStrong из TAHOT/TAGNT → скелет lex.

На выходе work/strongs/lexicon/:
  lex-core.json   — {dStrong: {lang, count, top_form, glosses, senses, morphs}}
  morph-codes.json — все коды морфологии, встреченные в тексте
  report.md       — сводка покрытия

Поля словаря lex-core (по строке lex из спека):
  lang 'hbo'|'grc', count — употреблений, top_form — самая частая
  словарная форма (иврит без огласовок — из expanded-тегов; греч. —
  из «Dictionary form»), glosses/senses — частотные списки,
  morphs — коды морфологии, увиденные у этого номера.
"""
import collections
import re
import sys

sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import common as C  # noqa: E402

STEP = C.STEP / 'Translators Amalgamated OT+NT'

REF = C.meas.REF
# сегмент расширенного тега: CODE=HEB=TRANS (TRANS может нести »label и @entity, включая строчные a..z)
SEG = re.compile(r'([HG]\d{3,5}[A-Za-z]?)=([^={}»|]*)=([^{}]*)')
# 'first:1_beginning' / 'land:2_country;_planet' → '1_beginning'
SENSE = re.compile(r':?(\d+_\S+)')


def strip_vocal(h):
    """иврит без огласовок/кантиляции: оставляем буквы א-ת и финальные."""
    return ''.join(ch for ch in h if 'א' <= ch <= 'ת' or ch == 'ף' or ch == 'ץ'
                   or ch == 'ם' or ch == 'ן' or ch == 'ך')


class Inv(dict):
    def __missing__(self, k):
        v = dict(lang='hbo' if k.startswith('H') else 'grc', count=0,
                 forms=collections.Counter(), glosses=collections.Counter(),
                 senses=collections.Counter(), morphs=collections.Counter(),
                 editions=set())
        self[k] = v
        return v


def parse_tahot(inv, morphs):
    for path in sorted(STEP.glob('TAHOT*')):
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                m = REF.match(line)
                if not m or m.group(1) not in C.STEPAB:
                    continue
                c = line.rstrip('\n').split('\t')
                # коды морфологии — по морфемам; ' + G…' — ссылка на
                # сочетаемое слово (conjoin), не часть кода
                for code in re.split(r'[/\\+]', c[5].strip()):
                    code = code.strip()
                    if code and not re.fullmatch(r'[GH]?\d+', code) \
                            and not code.startswith((' ', '-')):
                        morphs.add(code)
                exp = c[11] if len(c) > 11 else ''
                for code, heb, trans in SEG.findall(exp):
                    e = inv[code]
                    e['count'] += 1
                    if heb:
                        e['forms'][strip_vocal(heb)] += 1
                    if '»' in trans:
                        trans, sub = trans.split('»', 1)
                        lab = SENSE.search(sub.split('|')[0])
                        if lab:
                            e['senses'][lab.group(1)] += 1
                    # глосс морфемы — до первого разделителя сегментов
                    g = re.split(r'[/\\]', trans)[0].strip(' :/')
                    if g and g != '-':
                        e['glosses'][g] += 1


def parse_tagnt(inv, morphs):
    for path in sorted(STEP.glob('TAGNT*')):
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                m = REF.match(line)
                if not m or m.group(1) not in C.STEPAB:
                    continue
                c = line.rstrip('\n').split('\t')
                ds = c[3].split('=')
                codes = re.findall(r'G\d{4,5}[A-Z]?', ds[0])
                code = codes[0] if codes else None
                gram = ds[1].strip() if len(ds) > 1 else ''
                # 'CODE + G1234' — прилеплен номер сочетаемого слова
                gparts = [p.strip() for p in gram.split(' + ')
                          if p.strip() and not re.fullmatch(r'[HG]\d+', p.strip())]
                morphs.update(gparts)
                if not code:
                    continue
                e = inv[code]
                e['count'] += 1
                for p in gparts:
                    e['morphs'][p] += 1
                # колонка 4: 'Ἰησοῦς=Jesus/Joshua' — словарная форма + глосс
                dg = (c[4] if len(c) > 4 else '').split('=', 1)
                if len(dg) == 2:
                    e['forms'][dg[0].strip()] += 1
                    if dg[1].strip():
                        e['glosses'][dg[1].strip()] += 1
                sub = c[9] if len(c) > 9 else ''
                for part in sub.split('|'):
                    if '»' in part:
                        lab = SENSE.search(part)
                        if lab:
                            e['senses'][lab.group(1)] += 1
                for ed in (c[5] if len(c) > 5 else '').split('+'):
                    ed = ed.strip()
                    if ed:
                        e['editions'].add(ed)


def main():
    inv, morphs = Inv(), set()
    parse_tahot(inv, morphs)
    parse_tagnt(inv, morphs)

    out = {}
    for k, e in inv.items():
        out[k] = dict(
            lang=e['lang'], count=e['count'],
            top_form=e['forms'].most_common(1)[0][0] if e['forms'] else '',
            glosses=[g for g, _ in e['glosses'].most_common(5)],
            senses=[[s, n] for s, n in e['senses'].most_common()],
            morphs=[m for m, _ in e['morphs'].most_common(5)],
            editions=sorted(e['editions']))

    heb = [k for k in out if k.startswith('H')]
    grc = [k for k in out if k.startswith('G')]
    C.write_json('lex-core.json', out)
    C.write_json('morph-codes.json', sorted(morphs))

    r = f"""# T1: инвентарь dStrong

- Всего уточнённых номеров: **{len(out)}** (иврит {len(heb)}, греч. {len(grc)})
- Кодов морфологии: **{len(morphs)}**
- С меткой значения (`»`): {sum(1 for e in out.values() if e['senses'])}
- Из них H9xxx (морфемы): {sum(1 for k in heb if 9000 <= int(k[1:5]) if k[1:5].isdigit())}

Примеры:
{chr(10).join('- `%s` ×%d форма %r глоссы %s метки %s' % (k, out[k]['count'], out[k]['top_form'], out[k]['glosses'][:3], out[k]['senses'][:3]) for k in ['H7225G', 'H1254A', 'H0430G', 'H9003', 'G2424G', 'G3056'] if k in out)}
"""
    (C.WORK / 'report-t1.md').write_text(r, encoding='utf-8')
    print(r)


if __name__ == '__main__':
    main()
