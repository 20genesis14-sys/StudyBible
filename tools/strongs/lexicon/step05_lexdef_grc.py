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
        defs, doms, meanings = [], [], []
        for bf in e.get('BaseForms') or []:
            for m in bf.get('LEXMeanings') or []:
                m_doms = []
                for src_d in (m.get('LEXDomains') or []) + (m.get('LEXSubDomains') or []):
                    dn = (src_d.get('Domain') or '').strip()
                    if dn and dn not in m_doms:
                        m_doms.append(dn)
                doms.extend(d for d in m_doms if d not in doms)
                m_words = set()
                m_exact = set()
                for s in m.get('LEXSenses') or []:
                    if s.get('LanguageCode') != 'en':
                        continue
                    d = s.get('DefinitionShort') or s.get('DefinitionLong') or ''
                    gls = s.get('Glosses') or []
                    gl = '; '.join(gls)
                    for g_item in gls:
                        m_exact.add(g_item.strip().lower())
                    for gw in re.findall(r'[a-z]+', gl.lower()):
                        if len(gw) >= 3:
                            m_words.add(gw)
                    if d or gl:
                        body = (d + (' — ' + gl if gl else '')).strip(' —')
                        pref = ('[%s] ' % '; '.join(m_doms)) if m_doms else ''
                        defs.append(pref + body)
                if m_doms:
                    meanings.append((m_doms, m_exact, m_words))
        for b in bases:
            if b:
                cur = by_base.setdefault(b, {'defs': [], 'doms': [], 'meanings': []})
                cur['defs'].extend(defs)
                for d in doms:
                    if d not in cur['doms']:
                        cur['doms'].append(d)
                cur['meanings'].extend(meanings)
    # UBS повторяет одно значение в нескольких BaseForms — дедупликация
    for u in by_base.values():
        u['defs'] = list(dict.fromkeys(u['defs']))
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

    # 2) UBS SDGNT — по базе; домены → sense_domain с отбором по глоссу dStrong
    ubs = load_ubs_greek()
    for base, u in ubs.items():
        for d in u['defs']:
            add(base, 'en', d, 'ubs-sdgnt', 'CC BY-SA 4.0')
    for k in keys:
        if k.startswith('G') and base_of(k) in ubs:
            u = ubs[base_of(k)]
            k_gloss = ((lmap.get(k) or {}).get('gloss') or
                       ((core.get(k) or {}).get('glosses') or [''])[0]).lower()
            k_words = {w for w in re.findall(r'[a-z]+', k_gloss) if len(w) >= 3}
            matched_doms = []
            if k_gloss and len(u.get('meanings', [])) > 1:
                for m_doms, m_exact, _m_words in u['meanings']:
                    if k_gloss in m_exact:
                        for d in m_doms:
                            if d not in matched_doms:
                                matched_doms.append(d)
                if not matched_doms and k_words:
                    for m_doms, _m_exact, m_words in u['meanings']:
                        if k_words & m_words:
                            for d in m_doms:
                                if d not in matched_doms:
                                    matched_doms.append(d)
            seen = matched_doms if matched_doms else list(u['doms'])
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
