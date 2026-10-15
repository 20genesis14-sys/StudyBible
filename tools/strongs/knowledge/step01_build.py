"""Фаза 3b: ACAI (+step-orig eid/mid, lex-name, Aquifer) → knowledge.sb.

Схема — ADR 0024 §2. Сущность = запись ACAI primary_id; неосновные
записи (id≠primary_id) дают имена-формы. Источники:
  entities    — ACAI (type→карта, subtype=*_type, desc eng, md-статья,
                geocoordinates, lemmas, strongs через eid→step-orig
                и eid→lex-name)
  entity_names— canonical/alias/localized/original/biblical(ru-статьи)
  relationships— father/mother/partner/offspring/sibling/member_of/
                subregion_of/nearby/associated/born_in/died_in/
                origin_person/possibly_same
  verse_mentions — references + referents (mid→BCV) + eid (name)
Координаты — BookCode (USFM) в нумерации eng, seg=0.
"""
import collections
import glob
import hashlib
import json
import re
import sqlite3
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lexicon'))
import common as C  # noqa: E402

ACAI = C.SRC / 'acai'
ORIG = C.DATA / 'work' / 'strongs' / 'orig'
WORK = C.DATA / 'work' / 'strongs' / 'knowledge'
DST = WORK / 'knowledge.sb'

USFM = {i + 1: u for i, (u, _s, _e) in enumerate(C.BOOKS)}

TYPE_MAP = dict(people='person', places='place', groups='group',
                deities='deity', fauna='creature', flora='plant',
                realia='object', keyterms='concept')
SUBTYPE_KEY = dict(deities='deity_type', fauna='fauna_type',
                   flora='flora_type', realia='realia_type',
                   keyterms='keyterm_type', groups='group_type')
MENTION_PRIORITY = ['name', 'explicit', 'subject', 'pronoun',
                    'speech', 'reference']
GEO_ORDER = ('obi', 'biblica-maps', 'recogito', 'vizbible')

SCHEMA = (Path(__file__).resolve().parent.parent / 'orig'
          / 'step03_build.py').read_text(encoding='utf-8')
SCHEMA = SCHEMA[SCHEMA.index('SCHEMA = """') + 12:]
SCHEMA = SCHEMA[:SCHEMA.index('"""')]

CUSTOM = """
CREATE TABLE entities(id TEXT PRIMARY KEY, type TEXT NOT NULL,
                      subtype TEXT NOT NULL DEFAULT '', name TEXT NOT NULL,
                      name_original TEXT NOT NULL DEFAULT '',
                      strongs TEXT NOT NULL DEFAULT '',
                      short_description TEXT NOT NULL DEFAULT '',
                      article TEXT NOT NULL DEFAULT '',
                      metadata TEXT NOT NULL DEFAULT '',
                      image_path TEXT NOT NULL DEFAULT '',
                      source TEXT NOT NULL DEFAULT '');
CREATE INDEX entities_type ON entities(type);
CREATE TABLE entity_names(entity_id TEXT NOT NULL, name TEXT NOT NULL,
                          lang TEXT NOT NULL DEFAULT 'eng',
                          kind TEXT NOT NULL DEFAULT 'alias');
CREATE INDEX entity_names_name ON entity_names(name);
CREATE INDEX entity_names_ent ON entity_names(entity_id);
CREATE TABLE relationships(id INTEGER PRIMARY KEY,
                           from_entity_id TEXT NOT NULL,
                           to_entity_id TEXT NOT NULL,
                           relation_type TEXT NOT NULL,
                           book TEXT, chapter INTEGER, verse INTEGER,
                           seg INTEGER,
                           description TEXT NOT NULL DEFAULT '',
                           weight REAL, source TEXT NOT NULL DEFAULT '');
CREATE INDEX rel_from ON relationships(from_entity_id);
CREATE INDEX rel_to ON relationships(to_entity_id);
CREATE TABLE verse_mentions(book TEXT NOT NULL, chapter INTEGER NOT NULL,
                            verse INTEGER NOT NULL, seg INTEGER NOT NULL,
                            entity_id TEXT NOT NULL,
                            mention_type TEXT NOT NULL,
                            context TEXT NOT NULL DEFAULT '',
                            source TEXT NOT NULL DEFAULT '',
                            PRIMARY KEY(book, chapter, verse, seg, entity_id));
CREATE INDEX vm_entity ON verse_mentions(entity_id);
CREATE TABLE type_hierarchy(parent_type TEXT NOT NULL,
                            child_type TEXT NOT NULL,
                            PRIMARY KEY(parent_type, child_type));
CREATE TABLE media(id INTEGER PRIMARY KEY, entity_id TEXT,
                   type TEXT NOT NULL DEFAULT '', rel_path TEXT NOT NULL DEFAULT '',
                   caption TEXT NOT NULL DEFAULT '', order_idx INTEGER);
"""

# ---------------- загрузка индексов ----------------

def orig_indices():
    """Индексы из step-orig (orig-words.jsonl):
      eids: eid → {'s': {strong}, 'bcv': {(eng_b,eng_c,eng_v)}}
      mid2bcv: mid → (eng_b, eng_c, eng_v)
      swid2bcv: (src_b, src_c, src_v, wnum_int) → (eng_b, eng_c, eng_v)
      sbcv2bcvs: (src_b, src_c, src_v) → [(eng_b, eng_c, eng_v), ...]
    """
    eids = collections.defaultdict(lambda: {'s': set(), 'bcv': set()})
    mid2bcv = {}
    swid2bcv = {}
    sbcv2bcvs = collections.defaultdict(list)
    with open(ORIG / 'orig-words.jsonl', encoding='utf-8') as f:
        for line in f:
            d = json.loads(line)
            ebcv = (d['b'], d['c'], d['v'])
            for w in d['w']:
                sbcv = tuple(w.get('sbcv') or ebcv)
                if ebcv not in sbcv2bcvs[sbcv]:
                    sbcv2bcvs[sbcv].append(ebcv)
                if w.get('mid'):
                    mid2bcv[w['mid']] = ebcv
                m = re.search(r'#(\d+)$', w.get('swid') or w['wid'])
                if m:
                    swid2bcv[(*sbcv, int(m.group(1)))] = ebcv
                eid = w.get('eid')
                if eid:
                    e = eids[norm_eid(eid)]
                    if w['strong']:
                        e['s'].add(w['strong'])
                    e['bcv'].add(ebcv)
    return eids, mid2bcv, swid2bcv, sbcv2bcvs


def load_ubs_handbooks():
    """'fauna:2.2' / 'flora:...' / 'realia:...' → (title, markdown)."""
    out = {}
    for d in ('ubs-fauna', 'ubs-flora', 'ubs-realia'):
        p = C.SRC / d / 'English-md.zip'
        if not p.exists():
            continue
        z = zipfile.ZipFile(p)
        for n in z.namelist():
            if not n.endswith('.md'):
                continue
            txt = z.read(n).decode('utf-8')
            parts = re.split(
                r'(?=^#{1,4}\s+.*?\(id:\s*[A-Za-z]+:[\d.]+\))',
                txt, flags=re.M)
            for part in parts:
                m = re.match(
                    r'^#{1,4}\s+(.*?)\s*\(id:\s*([A-Za-z]+:[\d.]+)\)', part)
                if m:
                    out[m.group(2).lower()] = (
                        m.group(1).strip(), part.strip()[:20000])
    return out


def lexname_index():
    """(name_lower, ref) → dStrong из lex-name.json (TIPNR)."""
    idx = {}
    for key, v in json.loads(
            (C.WORK / 'lex-name.json').read_text(encoding='utf-8')).items():
        idx[(v['name'].lower(), v['ref'])] = key
    return idx


HEB_CONS = re.compile(r'[^א-תףץםןך]')
HEB_CANT = re.compile(r'[\u0591-\u05af\u05bd\u05bf\u05c0\u05c3-\u05c6]')


def norm_heb_vocal(s):
    import unicodedata
    s = unicodedata.normalize('NFC', s)
    s = HEB_CANT.sub('', s)
    # Нормализуем порядок холам-вав (ו + холам)
    s = s.replace('\u05b9\u05d5', '\u05d5\u05b9')
    return ''.join(ch for ch in s if '\u05b0' <= ch <= '\u05ea')


def norm_grc(s):
    import unicodedata
    return ''.join(ch for ch in unicodedata.normalize('NFD', s)
                   if unicodedata.category(ch) != 'Mn').casefold()


def form_strongs_index():
    """Возвращает (cons_idx, vocal_idx, lex_meta):
    - cons_idx: согласная форма (иврит) или нижний регистр без диакритики (греч.) → [dStrong]
    - vocal_idx: огласованная форма иврита (без кантилляции) → [dStrong]
    - lex_meta: dStrong → (pos, gloss_lower) из lex-map.json + lex-core.json."""
    cons_idx = collections.defaultdict(list)
    vocal_idx = collections.defaultdict(list)
    lex_meta = {}
    lmap = json.loads((C.WORK / 'lex-map.json').read_text(encoding='utf-8'))
    core = json.loads((C.WORK / 'lex-core.json').read_text(encoding='utf-8'))
    for key, r in lmap.items():
        pos = r.get('pos') or ''
        gl = (r.get('gloss') or '').lower()
        lex_meta[key] = (pos, gl)
        lem = (r.get('lemma') or '').lstrip('/')
        if lem and key.startswith('H') and key in core:
            vf = norm_heb_vocal(lem)
            if vf and key not in vocal_idx[vf]:
                vocal_idx[vf].append(key)
            cf = HEB_CONS.sub('', lem)
            if cf and key not in cons_idx[cf]:
                cons_idx[cf].append(key)
    for key, v in core.items():
        if key not in lex_meta:
            gl0 = ((v.get('glosses') or [''])[0]).lower()
            lex_meta[key] = ('', gl0)
        f = v.get('top_form') or ''
        if not f:
            continue
        k_norm = norm_grc(f) if key.startswith('G') else f
        if key not in cons_idx[k_norm]:
            cons_idx[k_norm].append(key)
    return cons_idx, vocal_idx, lex_meta


def load_zip_index(path, idkey):
    """zip aquifer-json → {idkey: rec} + {'title.lower()': rec}."""
    by_id, by_title = {}, {}
    if not path.exists():
        return by_id, by_title
    z = zipfile.ZipFile(path)
    for n in z.namelist():
        if 'metadata' in n:
            continue
        for r in json.loads(z.read(n)):
            if not isinstance(r, dict):
                continue
            rid = str(r.get(idkey) or '')
            if rid:
                by_id[rid] = r
            t = (r.get('title') or '').strip().lower()
            if t:
                by_title.setdefault(t, r)
    return by_id, by_title


# ---------------- разбор полей ACAI ----------------

def norm_eid(eid):
    """`A|B@FirstRef-End` → `B@FirstRef`: идентичность сущности —
    каноническое имя + ссылка первого упоминания (конец диапазона
    в разных источниках различается)."""
    base = eid.split('|')[-1]
    if '@' not in base:
        return base
    name, rng = base.split('@', 1)
    return name + '@' + rng.split('-', 1)[0]


def canon_eids(alt):
    """tipnr-варианты → нормализованные eid."""
    return {norm_eid(t) for t in (alt.get('tipnr') or [])}


def geo(meta):
    g = meta.get('geocoordinates') or {}
    for src in GEO_ORDER:
        if src in g and g[src].get('lat'):
            return {'lat': float(g[src]['lat']), 'lon': float(g[src]['lon']),
                    'geo_src': src}
    return {}


def bcv_of_ref(ref8):
    """'01011026' → (1,11,26)."""
    return int(ref8[:2]), int(ref8[2:5]), int(ref8[5:8])


def mid_bcv(mid):
    """'o010110260071'/'n40001001001' → (b,c,v)."""
    return int(mid[1:3]), int(mid[3:6]), int(mid[6:9])


def main():
    eids, mid2bcv, swid2bcv, sbcv2bcvs = orig_indices()
    ubs_md = load_ubs_handbooks()
    lexnames = lexname_index()
    forms, vocal_forms, lex_meta = form_strongs_index()
    aqui = {}
    for key, fname, idk in (
            ('biblica', 'biblica-keyterms', 'content_id'),
            ('fia', 'fia-keyterms', 'index_reference'),
            ('obd', 'aquifer-obd', 'index_reference')):
        aqui[key] = {}
        for lang in ('English', 'Russian'):
            bi, bt = load_zip_index(
                C.SRC / fname / f'{lang}-json.zip', idk)
            aqui[key][lang] = (bi, bt)

    entities, names, rels = {}, set(), []
    id2prim = {}
    mentions = {}   # (bc,c,v,seg,eid) → [types, ctx, src]
    eid2ent = collections.defaultdict(set)
    stats = collections.Counter()

    def resolve_mid_bcv(mid):
        """MACULA id → английский (b, c, v)."""
        if mid in mid2bcv:
            return mid2bcv[mid]
        sb, sc, sv = int(mid[1:3]), int(mid[3:6]), int(mid[6:9])
        wn = int(mid[9:12]) if len(mid) >= 12 and mid[9:12].isdigit() else 0
        if (sb, sc, sv, wn) in swid2bcv:
            return swid2bcv[(sb, sc, sv, wn)]
        cands = sbcv2bcvs.get((sb, sc, sv))
        return cands[0] if cands else (sb, sc, sv)

    def mention(b, c, v, eid, mtype, ctx='', src='ACAI'):
        key = (USFM.get(b, ''), c, v, 0, eid)
        if not key[0]:
            stats['mention_bad_book'] += 1
            return
        m = mentions.setdefault(key, [set(), '', ''])
        m[0].add(mtype)
        if ctx and not m[1]:
            m[1] = ctx
        m[2] = src if mtype == 'name' else (m[2] or src)

    for path in sorted(glob.glob(str(ACAI / '*' / 'json' / '*.json'))):
        acai_type = Path(path).parent.parent.name
        d = json.load(open(path, encoding='utf-8'))
        eid_ent = d.get('primary_id') or d['id']
        id2prim[d['id']] = eid_ent
        stats['records'] += 1
        if d['id'] != eid_ent:
            # неосновная форма — только имя-алиас
            lab = (d.get('localizations') or {}).get('eng', {}) \
                .get('preferred_label') or d['id'].split(':')[-1]
            names.add((eid_ent, lab, 'eng', 'alias'))
            stats['nonprimary'] += 1
            continue

        loc = d.get('localizations') or {}
        eng = loc.get('eng', {})
        name = eng.get('preferred_label') or eid_ent.split(':')[-1]
        alt = d.get('alternate_sources') or {}
        typ = TYPE_MAP.get(acai_type, acai_type)
        sub = d.get(SUBTYPE_KEY.get(acai_type, ''), '')
        if acai_type == 'places':
            pt = (d.get('place_types') or {}).get('acai') or []
            sub = pt[0] if pt else ''
        elif acai_type == 'people':
            sub = ','.join(d.get('roles') or [])

        ce = canon_eids(alt)
        for e in ce:
            eid2ent[e].add(eid_ent)

        # strongs: канал 1 — eid в step-orig; канал 2 — lex-name
        strongs = set()
        for e in ce:
            if e in eids:
                # служебные морфемы H9xxx/G9xxx (префиксы, пунктуация)
                # не являются лексической идентичностью сущности
                strongs |= {s for s in eids[e]['s']
                            if not re.match(r'[HG]9\d{3}\b', s)}
                for b, c, v in eids[e]['bcv']:
                    mention(b, c, v, eid_ent, 'name', e, 'STEPBible')
            if '@' not in e:
                continue
            nm, rng = e.rsplit('@', 1)
            start = rng.split('-', 1)[0]
            key = lexnames.get((nm.lower(), start))
            if key:
                strongs.add(key)
                stats['lexname_hit'] += 1

        # канал 3 — леммы (для сущностей без eid-канала: флора/фауна/
        # реалия/термины); приоритет огласованной формы + фильтр части речи (POS)
        if not strongs:
            ent_words = {
                w for w in re.findall(r'[a-z]+', name.lower())
                if len(w) >= 3 and w not in ('the', 'and', 'for', 'act', 'state', 'event')
            }
            for lg, vs in (d.get('lemmas') or {}).items():
                for lem in vs:
                    if lg == 'el':
                        raw_cand = list(forms.get(norm_grc(lem), []))
                    else:
                        vf = norm_heb_vocal(lem)
                        raw_cand = list(vocal_forms.get(vf, [])) or list(forms.get(HEB_CONS.sub('', lem), []))
                    # Отсекаем имена собственные (N:N-*-P/L/T) у нарицательных сущностей и глаголы у предметов/животных/растений
                    cand = []
                    for ck in raw_cand:
                        pos, gl = lex_meta.get(ck, ('', ''))
                        if typ in ('creature', 'plant', 'object', 'concept'):
                            if pos.startswith('N:') or 'Proper' in pos or pos.endswith(('-P', '-L', '-T')):
                                continue
                        if typ in ('creature', 'plant', 'object') and ':V' in pos:
                            continue
                        cand.append(ck)
                    if len(cand) > 1 and ent_words:
                        gl_matched = [
                            ck for ck in cand
                            if ent_words & set(re.findall(r'[a-z]+', lex_meta.get(ck, ('', ''))[1]))
                        ]
                        if gl_matched:
                            cand = gl_matched
                    if cand and len(cand) <= 3:
                        strongs.update(cand)
                        stats['lemma_hit'] += 1

        names.add((eid_ent, name, 'eng', 'canonical'))
        for a in eng.get('alternate_labels') or []:
            names.add((eid_ent, a, 'eng', 'alias'))
        for r in d.get('referred_to_as') or []:
            names.add((eid_ent, r.split(':')[-1], 'eng', 'alias'))
        for lang, l in loc.items():
            if lang == 'eng':
                continue
            pl = l.get('preferred_label')
            if pl:
                names.add((eid_ent, pl, lang, 'localized'))
        lemmas = d.get('lemmas') or {}
        name_orig = ' / '.join(v for vs in lemmas.values() for v in vs)
        for lg, vs in lemmas.items():
            for v in vs:
                names.add((eid_ent, v, 'he' if lg == 'he' else 'gr',
                           'original'))

        # статьи Aquifer: ссылки вида '132189|Abraham|Biblica…'
        articles = {}
        for link in alt.get('aquifer') or []:
            parts = link.split('|')
            if len(parts) != 3:
                continue
            aid, aidx, asrc = parts
            akey = 'biblica' if asrc.startswith('Biblica') else \
                'fia' if asrc == 'FIAKeyTerms' else None
            if not akey:
                continue
            for lang, lkey in (('English', 'eng'), ('Russian', 'rus')):
                bi, bt = aqui[akey][lang]
                rec = bi.get(aid) or bt.get(aidx.lower())
                if rec:
                    articles.setdefault(lkey, []).append(dict(
                        src=asrc, title=rec.get('title', ''),
                        content=rec.get('content', '')[:20000]))
                    if lkey == 'rus' and rec.get('title'):
                        names.add((eid_ent, rec['title'], 'rus',
                                   'biblical'))
                    stats['aqui_join'] += 1

        # OBD по index_reference (eng-slug = имя сущности)
        for lang, lkey in (('English', 'eng'), ('Russian', 'rus')):
            _bi, bt = aqui['obd'][lang]
            rec = bt.get(name.lower()) or \
                bt.get(name.lower().replace(' ', '-'))
            if rec:
                articles.setdefault(lkey, []).append(dict(
                    src='AquiferOpenBibleDictionary',
                    title=rec.get('title', ''),
                    content=rec.get('content', '')[:20000]))
                if lkey == 'rus' and rec.get('title'):
                    names.add((eid_ent, rec['title'], 'rus', 'biblical'))
                stats['obd_join'] += 1

        mdp = ACAI / acai_type / 'md' / (d['id'].split(':')[-1] + '.md')
        article = mdp.read_text(encoding='utf-8') if mdp.exists() else ''

        # UBS Handbooks (fauna / flora / realia) — CC BY-SA 4.0
        for ukey, usrc in (('ubsfauna', 'UBSFauna'),
                           ('ubsflora', 'UBSFlora'),
                           ('ubsrealia', 'UBSRealia')):
            for uid in alt.get(ukey) or []:
                u_norm = uid.lower()
                hit = ubs_md.get(u_norm) or ubs_md.get(
                    '.'.join(u_norm.split('.')[:2]))
                if hit:
                    utitle, utxt = hit
                    articles.setdefault('eng', []).append(
                        dict(src=usrc, title=utitle, content=utxt))
                    if not article:
                        article = utxt
                    stats['ubs_join'] += 1

        desc = ''
        for dd in eng.get('descriptions') or []:
            if dd.get('description'):
                desc = dd['description']
                break

        meta = {k: d[k] for k in (
            'gender', 'roles', 'tribe', 'group_type', 'group_origin',
            'deity_type', 'fauna_type', 'flora_type', 'realia_type',
            'keyterm_type', 'place_types', 'non_biblical',
            'only_mentioned_in_apocrypha', 'mentioned_in_bible',
            'is_artifact', 'is_person', 'added_entry', 'ubsdbh',
            'ubsdgnt', 'lemmas', 'alternate_sources', 'key_references')
            if k in d}
        meta.update(geo(d))
        if articles:
            meta['articles'] = articles

        entities[eid_ent] = dict(
            type=typ, subtype=sub, name=name, name_original=name_orig,
            strongs=' '.join(sorted(strongs)),
            short_description=desc, article=article,
            metadata=json.dumps(meta, ensure_ascii=False),
            source='ACAI')

        for (refkey, rtype) in (
                ('father', 'father'), ('mother', 'mother'),
                ('tribe', 'member_of'), ('tribal_area', 'tribal_area'),
                ('group_origin', 'origin_person')):
            v = d.get(refkey)
            if v:
                rels.append((eid_ent, v, rtype))
        for (refkey, rtype) in (
                ('partners', 'partner'), ('offspring', 'offspring'),
                ('siblings', 'sibling'), ('subregion_of', 'subregion_of'),
                ('nearby_places', 'nearby'),
                ('associated_places', 'associated'),
                ('possibly_same_as', 'possibly_same')):
            for v in d.get(refkey) or []:
                rels.append((eid_ent, v, rtype))
        for k, vs in (d.get('related_places') or {}).items():
            rt = 'born_in' if k == 'birth_place' else \
                'died_in' if k == 'death_place' else k
            for v in vs:
                rels.append((eid_ent, v, rt))

        resolved_sbcvs = set()
        for e in ce:
            if e in eids:
                for eb, ec, ev in eids[e]['bcv']:
                    resolved_sbcvs.add((eb, ec, ev))
        for (fk, mt) in (('explicit_instances', 'explicit'),
                         ('pronominal_referents', 'pronoun'),
                         ('subject_referents', 'subject')):
            for _ed, mids in (d.get(fk) or {}).items():
                for grp in mids:
                    for mid in grp:
                        if mid and mid[0] in 'on':
                            resolved_sbcvs.add(mid_bcv(mid))
                            b, c, v = resolve_mid_bcv(mid)
                            mention(b, c, v, eid_ent, mt, mid)
        for _ed, sp in (d.get('speeches') or {}).items():
            for s in sp:
                for mid in s.get('words') or []:
                    if mid and mid[0] in 'on':
                        resolved_sbcvs.add(mid_bcv(mid))
                        b, c, v = resolve_mid_bcv(mid)
                        mention(b, c, v, eid_ent, 'speech')
        for ref8 in d.get('references') or []:
            sbcv = bcv_of_ref(ref8)
            if sbcv in resolved_sbcvs:
                continue
            cands = sbcv2bcvs.get(sbcv)
            b, c, v = cands[0] if cands else sbcv
            mention(b, c, v, eid_ent, 'reference')

    # ---------------- запись модуля ----------------
    WORK.mkdir(parents=True, exist_ok=True)
    if DST.exists():
        DST.unlink()
    db = sqlite3.connect(DST)
    db.execute('PRAGMA application_id = 0x53424D31')
    db.executescript(SCHEMA)
    db.executescript(CUSTOM)

    for eid_ent, e in entities.items():
        db.execute('INSERT INTO entities VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   (eid_ent, e['type'], e['subtype'], e['name'],
                    e['name_original'], e['strongs'],
                    e['short_description'], e['article'], e['metadata'],
                    '', e['source']))
    stats['entities'] = len(entities)
    db.executemany('INSERT INTO entity_names VALUES (?,?,?,?)',
                   sorted(names))
    stats['names'] = len(names)
    norm_rels = set()
    for f_, raw_t, rt in rels:
        for part in str(raw_t).split(';'):
            t_ = part.strip()
            if not t_:
                continue
            t_ = id2prim.get(t_) or id2prim.get(t_.split('.')[0]) or t_
            if f_ != t_:
                norm_rels.add((f_, t_, rt))
    for i, (f_, t_, rt) in enumerate(sorted(norm_rels)):
        if t_ in entities:
            db.execute('INSERT INTO relationships(id,from_entity_id,'
                       'to_entity_id,relation_type,book,chapter,verse,'
                       'seg,description,weight,source)'
                       ' VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                       (i, f_, t_, rt, None, None, None, None, '',
                        None, 'ACAI'))
            stats['rels'] += 1
        else:
            stats['rel_dangling'] += 1
    for (bc, c, v, seg, eid), (types, ctx, src) in mentions.items():
        best = next((t for t in MENTION_PRIORITY if t in types), 'reference')
        db.execute('INSERT INTO verse_mentions VALUES (?,?,?,?,?,?,?,?)',
                   (bc, c, v, seg, eid, best, ctx, src or 'ACAI'))
    stats['mentions'] = len(mentions)
    for ch in sorted(set(TYPE_MAP.values())):
        db.execute('INSERT INTO type_hierarchy VALUES (?,?)',
                   ('entity', ch))
    db.execute('INSERT INTO type_hierarchy VALUES (?,?)',
               ('person', 'deity'))

    digest = hashlib.sha256(
        json.dumps(sorted(entities), ensure_ascii=False).encode('utf-8'))
    meta = {
        'format_version': '1', 'id': 'knowledge',
        'title': 'Biblical knowledge graph (ACAI)',
        'language': 'en', 'direction': 'ltr', 'versification': 'eng',
        'name_profile': 'en', 'book_order': 'syn', 'version': '0.2.0',
        'license': 'CC BY-SA 4.0',
        'attribution': 'ACAI (c) Mission Mutual 2025, CC BY-SA 4.0; '
                       'STEPBible TAHOT/TAGNT eid crosswalk; Aquifer '
                       'OBD/FIA/Biblica key terms; UBS Fauna/Flora/Realia',
        'source': 'acai',
        'kind': 'knowledge',
        'features': 'knowledge',
        'required': '', 'content_hash': digest.hexdigest(),
    }
    db.executemany('INSERT INTO meta VALUES (?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()

    # статистика
    types_c = collections.Counter(e['type'] for e in entities.values())
    stats['types'] = dict(types_c)
    stats['with_strongs'] = sum(1 for e in entities.values()
                                if e['strongs'])
    stats['with_geo'] = sum(1 for e in entities.values()
                            if '"lat"' in e['metadata'])
    stats['eid_hit'] = sum(1 for s in eid2ent.values() if s)
    stats['eid_total'] = len(eid2ent)
    (WORK / 'stats.json').write_text(
        json.dumps(dict(stats), ensure_ascii=False, indent=1),
        encoding='utf-8')
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))
    db.close()


if __name__ == '__main__':
    main()
