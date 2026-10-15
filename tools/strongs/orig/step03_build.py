"""T4: orig-words.jsonl → step-orig.sb (схема v1, ADR 0025 §3).

Один 'p'-блок на стих; спан на морфему: style 'w', text — глосс,
attrs gr/strong/morph/lemma/wid (+typ/ed/sns/eid/conj/mid).
tokens.surface=gr, tokens.gloss=text — как token_of читает.
Хэш потока — как у ModuleWriter/build-interlinear.py.
"""
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lexicon'))
import common as C  # noqa: E402

WORK = C.DATA / 'work' / 'strongs' / 'orig'
DST = WORK / 'step-orig.sb'

SCHEMA = """
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE books(book_id INTEGER PRIMARY KEY, code TEXT UNIQUE NOT NULL,
                   ord INTEGER NOT NULL, title TEXT NOT NULL DEFAULT '');
CREATE TABLE book_headers(book_id INTEGER NOT NULL, marker TEXT NOT NULL, text TEXT NOT NULL,
                          PRIMARY KEY(book_id, marker));
CREATE TABLE blocks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, seq INTEGER NOT NULL,
                    marker TEXT NOT NULL DEFAULT '', PRIMARY KEY(book_id, chapter, seq));
CREATE TABLE spans(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, block INTEGER NOT NULL,
                   seq INTEGER NOT NULL, kind TEXT NOT NULL, num INTEGER,
                   verse INTEGER, start INTEGER, len INTEGER,
                   style TEXT NOT NULL DEFAULT '', attrs TEXT NOT NULL DEFAULT '',
                   caller TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, block, seq));
CREATE TABLE verses(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    text TEXT NOT NULL, PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE tokens(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                    seq INTEGER NOT NULL, surface TEXT NOT NULL DEFAULT '',
                    lemma TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                    morph TEXT NOT NULL DEFAULT '', gloss TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY(book_id, chapter, verse, seq));
CREATE TABLE alignment(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                       token_seq INTEGER NOT NULL, block INTEGER NOT NULL, span INTEGER NOT NULL,
                       PRIMARY KEY(book_id, chapter, verse, token_seq));
CREATE TABLE variants(id INTEGER PRIMARY KEY,
                      book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                      token_from INTEGER NOT NULL, token_to INTEGER NOT NULL);
CREATE TABLE readings(id INTEGER PRIMARY KEY, variant_id INTEGER NOT NULL,
                      seq INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '',
                      is_base INTEGER NOT NULL DEFAULT 0);
CREATE TABLE witnesses(reading_id INTEGER NOT NULL, siglum TEXT NOT NULL,
                       PRIMARY KEY(reading_id, siglum));
CREATE TABLE entries(ord INTEGER PRIMARY KEY, headword TEXT NOT NULL,
                     norm TEXT NOT NULL DEFAULT '', text TEXT NOT NULL DEFAULT '');
CREATE INDEX entries_norm ON entries(norm);
CREATE TABLE marks(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL, verse INTEGER NOT NULL,
                   seq INTEGER NOT NULL, offset_ms INTEGER NOT NULL,
                   dur_ms INTEGER, text TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, seq));
CREATE TABLE span_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                       block INTEGER NOT NULL, blob BLOB NOT NULL,
                       PRIMARY KEY(book_id, chapter, block));
CREATE TABLE token_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE align_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE xrefs_pack(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                        verse INTEGER NOT NULL, blob BLOB NOT NULL,
                        PRIMARY KEY(book_id, chapter, verse));
CREATE TABLE links(book_id INTEGER NOT NULL, chapter INTEGER NOT NULL,
                   verse INTEGER NOT NULL, word INTEGER NOT NULL,
                   ref TEXT NOT NULL DEFAULT '', strong TEXT NOT NULL DEFAULT '',
                   conf INTEGER NOT NULL DEFAULT 0,
                   flags TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(book_id, chapter, verse, word));
"""

NO_LEAD = (' ', ',', '.', ';', ':', '!', '?', '׃', '־', '—', '–')
LETTER_HEB = re.compile(r'[א-תףץםןך]')
LETTER_GRC = re.compile(r'[Ͱ-Ͽἀ-῿]')


def esc(s):
    return s.replace('"', "'")


def pure_punct(form, is_nt):
    """Форма без единой буквы (׃, тире, одиночная пунктуация)."""
    f = form.strip()
    if not f:
        return True
    pat = LETTER_GRC if is_nt else LETTER_HEB
    return not pat.search(f)


def attrs_of(w):
    parts = []
    for k in ('gr', 'strong', 'morph', 'lemma', 'wid', 'typ', 'ed',
              'sns', 'eid', 'conj', 'mid'):
        v = w.get(k) or ''
        if v:
            parts.append('%s="%s"' % (k, esc(v)))
    return ' '.join(parts)


def build():
    if DST.exists():
        DST.unlink()
    db = sqlite3.connect(DST)
    db.execute('PRAGMA application_id = 0x53424D31')
    db.executescript(SCHEMA)

    digest = hashlib.sha256()
    n_verses = n_spans = 0
    cur = None            # (book, ch)
    block_seq = 0
    span_rows = tok_rows = al_rows = None

    def flush_chapter():
        nonlocal span_rows, tok_rows, al_rows
        if span_rows:
            db.executemany(
                'INSERT INTO spans VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
                span_rows)
        if tok_rows:
            db.executemany('INSERT INTO tokens VALUES (?,?,?,?,?,?,?,?,?)',
                           tok_rows)
        if al_rows:
            db.executemany('INSERT INTO alignment VALUES (?,?,?,?,?,?)',
                           al_rows)
        span_rows, tok_rows, al_rows = [], [], []

    span_rows, tok_rows, al_rows = [], [], []
    books_seen = set()
    for line in open(WORK / 'orig-words.jsonl', encoding='utf-8'):
        d = json.loads(line)
        b, ch, v = d['b'], d['c'], d['v']
        is_nt = b >= 40
        if (b, ch) != cur:
            flush_chapter()
            cur = (b, ch)
            block_seq = 0
        if b not in books_seen:
            books_seen.add(b)
            usfm, _step, name = C.BOOKS[b - 1]
            db.execute('INSERT INTO books VALUES (?,?,?,?)',
                       (b, usfm, b, name))
        block = block_seq
        block_seq += 1
        db.execute('INSERT INTO blocks VALUES (?,?,?,?)',
                   (b, ch, block, 'p'))
        digest.update(('%s %d %d %s\x00' % (C.BOOKS[b - 1][0], ch, block,
                                           'p')).encode('utf-8'))

        buf = ''
        seq = 0
        for w in d['w']:
            text = w['gloss']
            if not text or pure_punct(w['gr'], is_nt):
                text = w['gr'].strip() or text or '·'
            if buf and not buf.endswith(' ') \
                    and not text.startswith(NO_LEAD):
                buf += ' '
            start = len(buf.encode('utf-8'))
            buf += text
            ln = len(text.encode('utf-8'))
            attrs = attrs_of(w)
            span_rows.append((b, ch, block, seq, 't', None, v, start,
                              ln, 'w', attrs, '', ''))
            tok_rows.append((b, ch, v, seq, w['gr'], w['lemma'],
                             w['strong'], w['morph'], text))
            al_rows.append((b, ch, v, seq, block, seq))
            digest.update(('t%s\x01%s\x01%s\x00'
                           % ('w', attrs, text)).encode('utf-8'))
            seq += 1
            n_spans += 1
        if buf and not buf.endswith(' '):
            buf += ' '
        db.execute('INSERT INTO verses VALUES (?,?,?,?)', (b, ch, v, buf))
        n_verses += 1
    flush_chapter()

    meta = {
        'format_version': '1', 'id': 'step-orig',
        'title': 'STEP original text (TAHOT/TAGNT)',
        'language': 'en', 'direction': 'ltr', 'versification': 'eng',
        'name_profile': 'en', 'book_order': 'syn', 'version': '0.2.0',
        'license': 'CC BY 4.0',
        'attribution': 'STEPBible TAHOT/TAGNT (c) Tyndale House, '
                       'Cambridge; MACULA token ids (Clear Bible)',
        'source': 'stepbible',
        'kind': 'interlinear', 'features': 'tokens,alignment',
        'required': '', 'content_hash': digest.hexdigest(),
    }
    db.executemany('INSERT INTO meta VALUES (?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.close()
    print('%d стихов, %d морфем-спанов -> %s' % (n_verses, n_spans, DST))


if __name__ == '__main__':
    if DST.exists():
        DST.unlink()
    build()
