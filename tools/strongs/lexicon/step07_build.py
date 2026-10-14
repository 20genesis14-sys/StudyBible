"""T7–T9: сборка strongs-step.sb.

lex:      dStrong + поля TBESH/TAGNT/TIPNR (T1,T2,T6)
lex_def:  определения по слоям (T4,T5); базовые слои — под ключом базы
lex_base: base → dStrong
morph:    TEHMC/TEGMC (T3)
entries:  карточка для интерфейса (headword/norm/text)
meta:     kind=dictionary, смешанные лицензии — def_license построчно
"""
import hashlib
import re
import sqlite3
import sys
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common as C  # noqa: E402

OUT = C.WORK / 'strongs-step.sb'
VER = '0.2.1'

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books (book_id INTEGER PRIMARY KEY,
                    code TEXT UNIQUE NOT NULL,
                    ord INTEGER NOT NULL,
                    title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers (book_id INTEGER NOT NULL,
                           marker TEXT NOT NULL,
                           text TEXT NOT NULL,
                           PRIMARY KEY (book_id, marker));
CREATE TABLE blocks (book_id INTEGER NOT NULL,
                     chapter INTEGER NOT NULL,
                     seq INTEGER NOT NULL,
                     marker TEXT NOT NULL DEFAULT '',
                     PRIMARY KEY (book_id, chapter, seq));
CREATE TABLE spans (book_id INTEGER NOT NULL,
                    chapter INTEGER NOT NULL,
                    block INTEGER NOT NULL,
                    seq INTEGER NOT NULL,
                    kind TEXT NOT NULL, num INTEGER,
                    verse INTEGER, start INTEGER, len INTEGER,
                    style TEXT NOT NULL DEFAULT '',
                    attrs TEXT NOT NULL DEFAULT '',
                    caller TEXT NOT NULL DEFAULT '',
                    text TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (book_id, chapter, block, seq));
CREATE TABLE verses (book_id INTEGER NOT NULL,
                     chapter INTEGER NOT NULL,
                     verse INTEGER NOT NULL,
                     text TEXT NOT NULL,
                     PRIMARY KEY (book_id, chapter, verse));
CREATE TABLE tokens (book_id INTEGER NOT NULL,
                     chapter INTEGER NOT NULL,
                     verse INTEGER NOT NULL,
                     seq INTEGER NOT NULL,
                     surface TEXT NOT NULL DEFAULT '',
                     lemma TEXT NOT NULL DEFAULT '',
                     strong TEXT NOT NULL DEFAULT '',
                     morph TEXT NOT NULL DEFAULT '',
                     gloss TEXT NOT NULL DEFAULT '',
                     PRIMARY KEY (book_id, chapter, verse, seq));
CREATE TABLE alignment (book_id INTEGER NOT NULL,
                        chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL,
                        token_seq INTEGER NOT NULL,
                        block INTEGER NOT NULL,
                        span INTEGER NOT NULL,
                        PRIMARY KEY (book_id, chapter, verse, token_seq));
CREATE TABLE entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
                     norm TEXT NOT NULL DEFAULT '',
                     text TEXT NOT NULL DEFAULT '');
CREATE INDEX entries_norm ON entries(norm);
-- ADR 0025: расширенный лексикон Стронга
CREATE TABLE lex(key TEXT PRIMARY KEY, estrong TEXT, base TEXT,
                 lang TEXT, lemma TEXT, xlit TEXT, pos TEXT, gloss TEXT,
                 sense_label TEXT, sense_domain TEXT,
                 relation TEXT, related TEXT, ustrong TEXT,
                 source TEXT, conf INTEGER, flags TEXT, review TEXT);
CREATE INDEX lex_base_idx ON lex(base);
CREATE TABLE lex_def(key TEXT, lang TEXT, def TEXT,
                     def_source TEXT, def_license TEXT,
                     conf INTEGER, flags TEXT, review TEXT);
CREATE INDEX lex_def_key ON lex_def(key);
CREATE TABLE lex_base(base TEXT NOT NULL, key TEXT NOT NULL);
CREATE INDEX lex_base_base ON lex_base(base);
CREATE TABLE morph(code TEXT PRIMARY KEY, lang TEXT,
                   short TEXT, long TEXT, conf INTEGER);
"""

EMPTY_HASH = hashlib.sha256(b'').hexdigest()


def norm(s):
    """нормализация для поиска: минускл без диакритики."""
    s = unicodedata.normalize('NFD', s)
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn')
    return s.lower().strip()


def main():
    core = C.read_json('lex-core.json')
    lmap = C.read_json('lex-map.json')
    alias = C.read_json('lex-alias.json')
    defs = C.read_json('lex-def.json')
    doms = C.read_json('lex-domain.json')
    names = C.read_json('lex-name.json')
    morph = C.read_json('morph.json')

    keys = sorted(set(core) | set(lmap), key=lambda k: (k[0],
                  int(re.sub(r'\D', '', k) or 0), k))
    ambig = {}  # неоднозначные соответствия текста→лексикон (T2)
    base_ix = {}
    for d, r in lmap.items():
        if r['base']:
            base_ix.setdefault(r['base'], []).append(d)
    for k in keys:
        if k not in lmap and k not in alias:
            cand = base_ix.get(C.classic(k) or '', [])
            if len(cand) > 1:
                ambig[k] = cand

    if OUT.exists():
        OUT.unlink()
    db = sqlite3.connect(OUT)
    db.execute('PRAGMA application_id = 0x53424D31')
    db.executescript(SCHEMA)

    # ---------- lex ----------
    n_rev = 0
    for k in keys:
        m = lmap.get(k) or lmap.get(alias.get(k, ''), {})
        c = core.get(k, {})
        nm = names.get(k, {})
        flags, review = [], []
        if not m:
            flags.append('no-tbesh')
            if ambig.get(k):
                flags.append('ambiguous-base')
                review.append('кандидаты TBESH: ' + ', '.join(ambig[k]))
            conf = 5
            n_rev += 1
        else:
            conf = 10
        if not c:
            flags.append('not-in-text')  # LXX-запас TBESH/G
        senses = c.get('senses') or []
        sl = senses[0][0] if senses else ''
        if len(senses) > 1:
            sl = ';'.join(s for s, _ in senses[:4])
        lemma = m.get('lemma', '') or c.get('top_form', '')
        if nm:
            review.append('%s %s (%s)' % (nm['cat'], nm['name'], nm['ref']))
        db.execute(
            'INSERT INTO lex VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
            (k, m.get('e', ''), m.get('base') or C.classic(k) or k,
             'en', lemma.lstrip('/'), m.get('xlit', ''),
             m.get('pos', ''), m.get('gloss', '') or
             (c.get('glosses') or [''])[0] or '(no STEP gloss)',
             sl, doms.get(k, ''),
             m.get('rel', ''), ';'.join(m.get('related', [])),
             m.get('u', ''), 'stepbible', conf,
             ','.join(flags), ' | '.join(review)))

    # ---------- lex_base ----------
    for k in keys:
        b = (lmap.get(k) or {}).get('base') or C.classic(k)
        if b:
            db.execute('INSERT INTO lex_base VALUES(?,?)', (b, k))
        else:
            db.execute('INSERT INTO lex_base VALUES(?,?)', (k, k))

    # ---------- lex_def ----------
    n_def = 0
    for k in sorted(defs, key=lambda x: (x[0], int(re.sub(r'\D', '', x) or 0), x)):
        for r in defs[k]:
            db.execute(
                'INSERT INTO lex_def VALUES(?,?,?,?,?,?,?,?)',
                (k, r['lang'], r['def'], r['def_source'], r['def_license'],
                 r['conf'], r['flags'], r.get('review', '')))
            n_def += 1

    # ---------- morph ----------
    for code, r in morph.items():
        long_ = r.get('long', '')
        if r.get('funcs'):
            long_ = (r['funcs'] + ' — ' + long_).strip(' —')
        if r.get('example'):
            long_ += '  ' + r['example']
        db.execute('INSERT INTO morph VALUES(?,?,?,?,?)',
                   (code, r['lang'], r['short'], long_.strip(), 10))

    # ---------- entries ----------
    SRC_RU = {'ubs-sdbh': 'UBS', 'ubs-sdgnt': 'UBS', 'oshb-bdb': 'BDB(OS)',
              'bdb-full': 'BDB', 'bdb-hebrew-aq': 'BDB(Aq)',
              'bdb-aramaic': 'BDB-Aram', 'abbott-smith': 'AS',
              'gloss-only': ''}
    # представитель базы: лемма первого dStrong с леммой ('G'-вариант вперёд)
    rep = {}
    for k in keys:
        m = lmap.get(k) or lmap.get(alias.get(k, ''), {})
        lem = (m.get('lemma', '') or core.get(k, {}).get('top_form', '')).lstrip('/')
        b = m.get('base') or C.classic(k)
        if lem and b:
            if b not in rep or (k.endswith('G') and not rep[b][1]):
                rep[b] = (lem, k.endswith('G'))
    ord_ = 0
    entry_keys = list(keys) + sorted(set(defs) - set(keys))
    for k in entry_keys:
        m = lmap.get(k) or lmap.get(alias.get(k, ''), {})
        c = core.get(k, {})
        nm = names.get(k, {})
        lemma = (m.get('lemma', '') or c.get('top_form', '')).lstrip('/')
        headword = lemma or (rep.get(k, ('',))[0]) or k
        if not headword:
            headword = k
        parts = ['%s  %s' % (k, m.get('pos', ''))]
        if m.get('xlit'):
            parts.append(m['xlit'])
        gloss = m.get('gloss', '') or (c.get('glosses') or [''])[0]
        if gloss:
            parts.append(gloss)
        if m.get('rel'):
            parts.append('(%s %s)' % (m['rel'], '; '.join(m.get('related', []))))
        if nm:
            parts.append('%s: %s — %s' % (nm['cat'].title(), nm['name'], nm['desc']))
        if doms.get(k):
            parts.append('domains: ' + doms[k])
        text = [headword + '  ' + ' · '.join(p for p in parts if p)]
        for r in defs.get(k, []):
            tag = SRC_RU.get(r['def_source'], r['def_source'])
            text.append('[%s] %s' % (tag, r['def']) if tag else r['def'])
        if not defs.get(k) and gloss:
            text.append(gloss)
        db.execute('INSERT INTO entries VALUES(?,?,?,?)',
                   (ord_, headword, norm(headword + ' ' + k), '\n'.join(text)))
        ord_ += 1

    # ---------- meta ----------
    meta = {
        'format_version': '1', 'id': 'strongs-step',
        'title': "STEP Strong's lexicon (extended)", 'language': 'en',
        'direction': 'ltr', 'versification': 'eng', 'name_profile': 'en',
        'book_order': 'syn', 'version': VER,
        'license': 'mixed: CC BY 4.0 (STEP/OSHB), CC BY-SA 4.0 (UBS), '
                   'CC0/PD (BDB, AS); см. lex_def.def_license',
        'attribution': 'STEPBible.org CC BY 4.0 (TAHOT/TAGNT/TBESH/TBESG/'
                       'TEHMC/TEGMC/TIPNR, modified: restructured); '
                       'OpenScriptures Hebrew Lexicon CC BY 4.0; '
                       'UBS dictionaries CC BY-SA 4.0; '
                       'BibleAquifer BDB lexicons CC0; '
                       'Abbott-Smith & BDB — public domain',
        'source': 'stepbible+oshb+ubs+aquifer+abbott-smith+bdb-full',
        'content_hash': EMPTY_HASH,
        'required': '', 'kind': 'dictionary',
        'features': 'entries,lex,lex_def,lex_base,morph', 'rights': '',
        'sources': json_sources(),
    }
    db.executemany('INSERT INTO meta VALUES(?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.close()

    size = OUT.stat().st_size / 1e6
    print('strongs-step.sb: %.1f MB, lex=%d lex_def=%d entries=%d morph=%d'
          % (size, len(keys), n_def, ord_, len(morph)))
    print('требуют review:', n_rev)


def json_sources():
    import json
    return json.dumps([
        {'id': 'stepbible', 'license': 'CC BY 4.0',
         'note': 'TAHOT, TAGNT, TBESH, TBESG, TEHMC, TEGMC, TIPNR; '
                 'данные реструктурированы, изменений нет'},
        {'id': 'oshb-lexicon', 'license': 'CC BY 4.0',
         'note': 'HebrewLexicon (AugIndex/LexicalIndex/BDB)'},
        {'id': 'ubs-dictionaries', 'license': 'CC BY-SA 4.0',
         'note': 'UBSHebrewDic, UBSGreekNTDic; домены в lex.sense_domain'},
        {'id': 'bdb-hebrew-aq', 'license': 'CC0',
         'note': 'BibleAquifer BDB Hebrew'},
        {'id': 'bdb-aramaic', 'license': 'CC0',
         'note': 'BibleAquifer BDB Aramaic'},
        {'id': 'bdb-full', 'license': 'public domain',
         'note': 'eliranwong unabridged BDB (форматирование)'},
        {'id': 'abbott-smith', 'license': 'public domain',
         'note': 'Abbott-Smith Manual Greek Lexicon (1922), TEI'},
    ], ensure_ascii=False)


if __name__ == '__main__':
    import json  # noqa
    main()
