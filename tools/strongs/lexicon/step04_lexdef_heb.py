"""T4: определения иврита/арамейского → lex_def.

Слои (def_source / def_license):
  ubs-sdbh      CC BY-SA 4.0  — совр. краткие определения + домены → sense_domain
  oshb-bdb      CC BY 4.0     — OSHB BDB через AugIndex→LexicalIndex→BDB
  bdb-hebrew-aq CC0           — Aquifer BDB (по первому strongs-number + alignments)
  bdb-full      public domain — полный BDB (DictBDB.json, по базовому номеру)
  bdb-aramaic   CC0           — арамейская часть BDB (по alignments → TAHOT)

Выход: lex-def.json {key: [row…]}, lex-domain.json {key: "d1; d2"}.
"""
import collections
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

SRC = C.SRC
OSHB = SRC / 'oshb-lexicon'
UBSD = SRC / 'ubs-dictionaries' / 'dictionaries' / 'hebrew' / 'JSON'
NS = '{http://openscriptures.github.com/morphhb/namespace}'
SKIP = {'status', 'note'}

TAG = re.compile(r'<[^>]+>')
WS = re.compile(r'\s+')


def strip_html(s):
    s = TAG.sub(' ', s)
    return WS.sub(' ', html.unescape(s)).strip()


def bdb_text(el):
    """<entry> → текст с пронумерованными <sense n>."""
    out = []

    def walk(node):
        tag = node.tag.replace(NS, '') if isinstance(node.tag, str) else ''
        if tag in SKIP:
            return
        if tag == 'sense':
            out.append(' %s) ' % node.get('n', ''))
        if node.text:
            out.append(node.text)
        for ch in node:
            walk(ch)
            if ch.tail:
                out.append(ch.tail)
    walk(el)
    return WS.sub(' ', ''.join(out)).strip()


def load_oshb():
    aug2id = {}
    for _, e in ET.iterparse(str(OSHB / 'AugIndex.xml'), events=('end',)):
        if e.tag == NS + 'w':
            aug2id[e.get('aug')] = e.text.strip()
            e.clear()
    li = {}
    for _, e in ET.iterparse(str(OSHB / 'LexicalIndex.xml'), events=('end',)):
        if e.tag == NS + 'entry':
            xref = e.find(NS + 'xref')
            li[e.get('id')] = (xref.get('bdb') if xref is not None else None)
            e.clear()
    bdb = {}
    for _, e in ET.iterparse(str(OSHB / 'BrownDriverBriggs.xml'), events=('end',)):
        if e.tag == NS + 'entry':
            t = bdb_text(e)
            if t:
                bdb[e.get('id')] = t
            e.clear()
    return aug2id, li, bdb


def load_bdb_full():
    raw = json.load(open(SRC / 'bdb-full' / 'DictBDB.json', encoding='utf-8'))
    return {x['top']: strip_html(x['def']) for x in raw if x['top'].startswith('H')}


def load_ubs_hebrew():
    """StrongCodes→base; LEXMeanings→(defs, domains)."""
    by_base = {}
    raw = json.load(open(UBSD / 'UBSHebrewDic-v0.9.3-en.JSON', encoding='utf-8'))
    for e in raw:
        bases = {C.classic(s) for s in e.get('StrongCodes', [])
                 if s.startswith('H')}
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


def load_aquifer(zipname, tag):
    """content_id → (title, text); first strongs-number → базовый номер."""
    items = {}
    zf = zipfile.ZipFile(SRC / zipname / 'English-json.zip')
    for nm in zf.namelist():
        if not nm.endswith('.json'):
            continue
        data = json.loads(zf.read(nm))
        if not isinstance(data, list):
            continue
        for it in data:
            if not isinstance(it, dict):
                continue
            raw = re.sub(r'<style[^>]*>.*?</style>', ' ',
                         it.get('content', ''), flags=re.S)
            txt = strip_html(raw)
            if len(txt) < 30:
                continue
            m = re.search(r'class="strongs-number"[^>]*>([\d,–\s-]+)<',
                          it.get('content', ''))
            sn = m.group(1).split(',')[0].split('–')[0].strip() if m else ''
            items[it['content_id']] = dict(
                title=it.get('title', ''), text=txt, strong=sn,
                refs=it.get('associations'))
    return items


def tahot_tokens():
    """BCVWWW → {dStrong}: для связывания aquifer-alignments."""
    import collections
    tok = collections.defaultdict(set)
    step = C.STEP / 'Translators Amalgamated OT+NT'
    ref = re.compile(r'^([1-3]?[A-Z][a-z]{1,2})\.(\d+)\.(\d+)#(\d+)=')
    for path in step.glob('TAHOT*'):
        for line in open(path, encoding='utf-8-sig'):
            m = ref.match(line)
            if not m or m.group(1) not in C.STEPAB:
                continue
            c = line.split('\t')
            if len(c) < 5:
                continue
            codes = set(re.findall(r'H\d{4,5}[A-Z]?', c[4]))
            bnum = C.STEPAB.get(m.group(1), 0)
            key = '%02d%03d%03d%03d' % (bnum, int(m.group(2)),
                                        int(m.group(3)), int(m.group(4)))
            tok[key] |= codes
    return tok


def aquifer_alignments(zipname, tok):
    """content_id → {dStrong} по записям вида '010010010011|word|' → cid."""
    out = {}
    try:
        zf = zipfile.ZipFile(SRC / zipname / 'English-alignments.zip')
    except FileNotFoundError:
        return out
    for nm in zf.namelist():
        if not nm.endswith('.json'):
            continue
        data = json.loads(zf.read(nm))
        for g in data.get('groups', []):
            for r in g.get('records', []):
                refs = r.get('references', [])
                if len(refs) < 2:
                    continue
                srcs, tgts = refs[0], refs[1]
                cids = [t for t in tgts if str(t).startswith('BDB')]
                for s in srcs:
                    wid = str(s).split('|')[0][:11]
                    for cid in cids:
                        out.setdefault(cid, set()).update(tok.get(wid, ()))
    return out


def main():
    lmap = C.read_json('lex-map.json')
    core = C.read_json('lex-core.json')
    keys = sorted(set(core) | set(lmap))
    defs = {k: [] for k in keys}

    def add(k, lang, d, src, lic, conf=10, flags=''):
        d = d.strip()
        if d:
            defs.setdefault(k, []).append(
                dict(lang=lang, def_=d, def_source=src, def_license=lic,
                     conf=conf, flags=flags))

    # 1) OSHB BDB — по eStrong→aug→entry→bdb
    aug2id, li, bdb = load_oshb()
    n_oshb = 0
    for k in keys:
        if not k.startswith('H'):
            continue
        e = (lmap.get(k) or {}).get('e', '')
        aug = e[1:].lower() if e else ''
        ent = li.get(aug2id.get(aug, ''), None)
        if ent:
            add(k, 'en', bdb.get(ent, ''), 'oshb-bdb', 'CC BY 4.0')
            n_oshb += 1

    # базовые ресурсы пишем под ключом базы ('H430'), а не дублируем
    # на все буквенные варианты — join через lex_base
    def base_of(k):
        return (lmap.get(k) or {}).get('base') or C.classic(k) or k

    # 2) bdb-full — по базовому номеру
    bfull = load_bdb_full()
    for base, txt in bfull.items():
        add(base, 'en', txt, 'bdb-full', 'public domain')

    # 3) UBS SDBH — по базовому номеру; домены → sense_domain у каждого dStrong
    ubs = load_ubs_hebrew()
    dom = {}
    for base, u in ubs.items():
        seen = []
        for d in u['doms']:
            if d not in seen:
                seen.append(d)
        for d in u['defs']:
            add(base, 'en', ('[%s] ' % '; '.join(seen) if seen else '') + d,
                'ubs-sdbh', 'CC BY-SA 4.0')
    for k in keys:
        if k.startswith('H') and base_of(k) in ubs:
            u = ubs[base_of(k)]
            seen = []
            for d in u['doms']:
                if d not in seen:
                    seen.append(d)
            if seen:
                dom[k] = '; '.join(seen)

    # 4) aquifer hebrew — статьи под базой (первый strongs-number);
    #    alignments добавляют базы слов, у которых нет метки
    tok = tahot_tokens()
    aq = load_aquifer('bdb-hebrew-aq', 'heb')
    al = aquifer_alignments('bdb-hebrew-aq', tok)
    n_aq = 0
    # основной ключ — первый strongs-number в HTML; alignments — только
    # для статей без метки, и там это списки кандидатов → берём самую
    # частую базу среди привязанных токенов
    for cid, it in aq.items():
        bases = set()
        if it['strong'].isdigit():
            bases.add('H' + it['strong'])
        elif cid in al:
            cnt = collections.Counter(
                base_of(k) for k in al[cid] if k.startswith('H'))
            if cnt:
                bases.add(cnt.most_common(1)[0][0])
        for b in bases:
            add(b, 'en', it['text'][:6000], 'bdb-hebrew-aq', 'CC0')
            n_aq += 1

    # 5) aquifer aramaic — alignments → самая частая база слова
    aqa = load_aquifer('bdb-aramaic', 'arc')
    ala = aquifer_alignments('bdb-aramaic', tok)
    n_ar = 0
    for cid, it in aqa.items():
        cnt = collections.Counter(
            base_of(k) for k in ala.get(cid, ()) if k.startswith('H'))
        if cnt:
            add(cnt.most_common(1)[0][0], 'en', it['text'][:6000],
                'bdb-aramaic', 'CC0')
            n_ar += 1

    # снимаем служебное поле имени ключа 'def_' → 'def'
    for rows in defs.values():
        for r in rows:
            r['def'] = r.pop('def_')

    C.write_json('lex-def.json', {k: v for k, v in defs.items() if v})
    C.write_json('lex-domain.json', dom)

    cov = sum(1 for k in keys if k.startswith('H')
              and (defs.get(k) or defs.get(base_of(k))))
    total = sum(len(v) for v in defs.values())
    rpt = f"""# T4: определения иврит/арамейский

Гранулярность: буквенно-точные слои — под dStrong, базовые — под базой
(join через lex_base).

- OSHB BDB: {n_oshb} ключей (статей {len(bdb)}, индекс {len(li)})
- bdb-full: {len(bfull)} базовых статей
- UBS SDBH: {len(ubs)} базовых записей, домены у {len(dom)} dStrong
- bdb-hebrew-aq: {n_aq} строк lex_def (статей {len(aq)}, align-linked {len(al)})
- bdb-aramaic: {n_ar} строк lex_def (статей {len(aqa)}, align-linked {len(ala)})
- Всего строк lex_def (пока только иврит): {total}
- Иврит-ключей с ≥1 определением (self или base): **{cov} / {sum(1 for k in keys if k.startswith('H'))}**
"""
    (C.WORK / 'report-t4.md').write_text(rpt, encoding='utf-8')
    print(rpt)


if __name__ == '__main__':
    main()
