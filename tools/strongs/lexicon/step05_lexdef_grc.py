"""T5: определения греческого → lex_def.

Слои:
  ubs-sdgnt    CC BY-SA 4.0  — совр. определения + домены → sense_domain
  abbott-smith public domain — полный AS TEI (по базовому номеру G####)

Базовые ресурсы — под ключом базы (join через lex_base), как в T4.
Дописывает в существующий lex-def.json / lex-domain.json.
"""
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

SRC = C.SRC
AS = SRC / 'abbott-smith' / 'abbott-smith.tei.xml'
UBSD = SRC / 'ubs-dictionaries' / 'dictionaries' / 'greek' / 'JSON'

WS = re.compile(r'\s+')


def as_text(el):
    """<entry> → текст: формы + пронумерованные значения."""
    out = []

    def walk(node, depth=0):
        tag = node.tag.split('}')[-1]
        if tag == 'sense' and depth:
            out.append(' %s ' % (node.get('n') or '•'))
        if node.text:
            out.append(node.text)
        for ch in node:
            walk(ch, depth + (1 if tag == 'sense' else 0))
            if ch.tail:
                out.append(ch.tail)
    for ch in el:
        walk(ch)
    return WS.sub(' ', ''.join(out)).strip()


def load_as():
    arts = {}
    for _, e in ET.iterparse(str(AS), events=('end',)):
        if e.tag.split('}')[-1] == 'entry' and e.get('n'):
            t = as_text(e)
            if t:
                # n="ἐγώ|G1473|G1691|…" — одна статья на все формы
                for num in re.findall(r'G(\d+)', e.get('n')):
                    arts['G' + str(int(num))] = t
            e.clear()
    return arts


def load_ubs_greek():
    by_base = {}
    raw = json.load(open(UBSD / 'UBSGreekNTDic-v1.1-en.JSON', encoding='utf-8'))
    for e in raw:
        bases = {C.classic(s) for s in e.get('StrongCodes', [])
                 if s.startswith('G')}
        defs, doms = [], []
        for bf in e.get('BaseForms') or []:
            for m in bf.get('LEXMeanings') or []:
                ds = {d.get('Domain', '') for d in m.get('LEXDomains') or []}
                ds |= {d.get('Domain', '') for d in m.get('LEXSubDomains') or []}
                doms.extend(sorted(ds - {''}))
                for s in m.get('LEXSenses') or []:
                    if s.get('LanguageCode') != 'en':
                        continue
                    d = s.get('DefinitionShort') or s.get('DefinitionLong') or ''
                    gl = '; '.join(s.get('Glosses') or [])
                    if d or gl:
                        defs.append((d + (' — ' + gl if gl else '')).strip(' —'))
        for b in bases:
            if b:
                cur = by_base.setdefault(b, {'defs': [], 'doms': []})
                cur['defs'].extend(defs)
                cur['doms'].extend(doms)
    return by_base


def main():
    lmap = C.read_json('lex-map.json')
    core = C.read_json('lex-core.json')
    keys = sorted(set(core) | set(lmap))
    defs = C.read_json('lex-def.json') if (C.WORK / 'lex-def.json').exists() else {}
    dom = C.read_json('lex-domain.json') if (C.WORK / 'lex-domain.json').exists() else {}
    # идемпотентность: старые греческие строки снимаем перед перезаписью
    defs = {k: v for k, v in defs.items()
            if not k.startswith('G')}
    dom = {k: v for k, v in dom.items() if not k.startswith('G')}

    def add(k, lang, d, src, lic, conf=10, flags=''):
        if d.strip():
            defs.setdefault(k, []).append(
                dict(lang=lang, def_=d.strip(), def_source=src,
                     def_license=lic, conf=conf, flags=flags))

    def base_of(k):
        return (lmap.get(k) or {}).get('base') or C.classic(k) or k

    # 1) Abbott-Smith — по базе
    arts = load_as()
    for base, txt in arts.items():
        add(base, 'en', txt, 'abbott-smith', 'public domain')

    # 2) UBS SDGNT — по базе; домены → sense_domain
    ubs = load_ubs_greek()
    for base, u in ubs.items():
        seen = []
        for d in u['doms']:
            if d not in seen:
                seen.append(d)
        for d in u['defs']:
            add(base, 'en', ('[%s] ' % '; '.join(seen) if seen else '') + d,
                'ubs-sdgnt', 'CC BY-SA 4.0')
    for k in keys:
        if k.startswith('G') and base_of(k) in ubs:
            seen = []
            for d in ubs[base_of(k)]['doms']:
                if d not in seen:
                    seen.append(d)
            if seen:
                dom[k] = '; '.join(seen)

    for rows in defs.values():
        for r in rows:
            if 'def_' in r:
                r['def'] = r.pop('def_')

    C.write_json('lex-def.json', defs)
    C.write_json('lex-domain.json', dom)

    cov = sum(1 for k in keys if k.startswith('G')
              and (defs.get(k) or defs.get(base_of(k))))
    rpt = f"""# T5: определения греческого

- Abbott-Smith: {len(arts)} базовых статей
- UBS SDGNT: {len(ubs)} базовых записей, домены у
  {sum(1 for k in dom if k.startswith('G'))} dStrong
- Всего строк lex_def: {sum(len(v) for v in defs.values())}
- Греч. ключей с ≥1 определением (self или base): **{cov} / {sum(1 for k in keys if k.startswith('G'))}**
"""
    (C.WORK / 'report-t5.md').write_text(rpt, encoding='utf-8')
    print(rpt)


if __name__ == '__main__':
    main()
