"""T6: TIPNR → имена → lex-name.json.

Формат: секции '$=====PERSON(s)/PLACE/OTHER'; блок сущности:
  'UnifiedName@Ref=uStrong \t Description \t Parents \t Siblings \t
   Partners \t Offspring \t Tribe \t #Summary'
  затем строки '- Named\tName@Ref\tdStrong«eStrong=word\t…'

Выход lex-name.json: {dStrong: {name, ustrong, cat, desc, ref}}
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

TIPNR = C.STEP / 'Proper Nouns' / \
    'TIPNR - Translators Individualised Proper Names with all References - STEPBible.org CC BY.txt'

BLOCK = re.compile(r'^(\S+@[^\t=]+)=([HG]\d+[A-Za-z]?)\t')
NAMED = re.compile(r'^[–-]\s*Named\s+(\S+@\S+)\s*\t([HG]\d+[A-Za-z]?)')
SECT = re.compile(r'^\$=+\s*(PERSON|PLACE|OTHER)')


def main():
    names = {}
    cur_cat = ''
    cur = None
    n_blocks = 0
    for line in open(TIPNR, encoding='utf-8-sig'):
        line = line.rstrip('\n')
        m = SECT.match(line)
        if m:
            cur_cat = m.group(1)
            continue
        m = BLOCK.match(line)
        if m and cur_cat:
            c = line.split('\t')
            cur = dict(name=m.group(1).split('@')[0],
                       ustrong=m.group(2), cat=cur_cat,
                       desc=(c[1].strip() if len(c) > 1 else ''),
                       ref=m.group(1).split('@', 1)[1])
            names.setdefault('__blocks__', []).append(cur)
            n_blocks += 1
            continue
        m = NAMED.match(line)
        if m and cur is not None:
            d = m.group(2)
            names[d] = dict(name=cur['name'], ustrong=cur['ustrong'],
                            cat=cur['cat'], desc=cur['desc'], ref=cur['ref'])

    blocks = names.pop('__blocks__', [])
    C.write_json('lex-name.json', names)

    cats = {}
    for v in names.values():
        cats[v['cat']] = cats.get(v['cat'], 0) + 1
    core = C.read_json('lex-core.json')
    in_text = sum(1 for k in names if k in core)

    rpt = f"""# T6: TIPNR

- Блоков сущностей: {n_blocks}
- dStrong с именем: {len(names)} {cats}
- Из них встречаются в тексте: {in_text}

Примеры:
{chr(10).join('- `%s` %s' % (k, names[k]) for k in ['G2264G', 'G2264H', 'G2424G'] if k in names)}
"""
    (C.WORK / 'report-t6.md').write_text(rpt, encoding='utf-8')
    print(rpt)


if __name__ == '__main__':
    main()
