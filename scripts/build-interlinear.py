#!/usr/bin/env python3
"""Сборка .sb-модуля из подстрочника формата int-en (markdown с парами gloss/greek).

Вход: каталог text/ с файлами NN-slug.md, где каждый стих — блок:
    Matt 1:1
      gloss: <английская дословная строка>
      greek: <греческая строка>
      pairs: <слово>/ <слово> | <слово>/<слово> | …

Выход: модуль .sb компактной схемы v1, где текст стиха — gloss
(`verses.text`), каждое слово gloss — спан `t` style='w' с attrs
gr="<греческое слово>" и байтовым срезом (verse,start,len). Пары лежат
также в `tokens` (surface — слово оригинала, gloss — переводная) и
`alignment` (токен → его спан потока). В приложении такие модули в
режиме сравнения рисуются подстрочником «перевод над оригиналом».

Схема и хэш — точно как у ModuleWriter: content_hash = SHA-256
канонической сериализации потока (spec/05, правило С-12).
"""
import hashlib
import pathlib
import re
import sqlite3
import sys

BOOKS = {
    'matthew': 'MAT', 'mark': 'MRK', 'luke': 'LUK', 'john': 'JHN',
    'acts': 'ACT', 'romans': 'ROM', '1-corinthians': '1CO',
    '2-corinthians': '2CO', 'galatians': 'GAL', 'ephesians': 'EPH',
    'philippians': 'PHP', 'colossians': 'COL', '1-thessalonians': '1TH',
    '2-thessalonians': '2TH', '1-timothy': '1TI', '2-timothy': '2TI',
    'titus': 'TIT', 'philemon': 'PHM', 'hebrews': 'HEB', 'james': 'JAS',
    '1-peter': '1PE', '2-peter': '2PE', '1-john': '1JN', '2-john': '2JN',
    '3-john': '3JN', 'jude': 'JUD', 'revelation': 'REV',
}

BOOK_TITLES = {
    'MAT': 'Matthew', 'MRK': 'Mark', 'LUK': 'Luke', 'JHN': 'John',
    'ACT': 'Acts', 'ROM': 'Romans', '1CO': '1 Corinthians',
    '2CO': '2 Corinthians', 'GAL': 'Galatians', 'EPH': 'Ephesians',
    'PHP': 'Philippians', 'COL': 'Colossians', '1TH': '1 Thessalonians',
    '2TH': '2 Thessalonians', '1TI': '1 Timothy', '2TI': '2 Timothy',
    'TIT': 'Titus', 'PHM': 'Philemon', 'HEB': 'Hebrews', 'JAS': 'James',
    '1PE': '1 Peter', '2PE': '2 Peter', '1JN': '1 John', '2JN': '2 John',
    '3JN': '3 John', 'JUD': 'Jude', 'REV': 'Revelation',
}

VERSE_RE = re.compile(r'^\S+ (\d+):(\d+)\s*$')
FIELD_RE = re.compile(r'^\s{2}(gloss|greek|pairs):\s?(.*)$')
# Слова, перед которыми ModuleWriter не вставляет пробел.
NO_LEAD_SPACE = (' ', ',', '.', ';', ':', '!', '?')


def esc(s: str) -> str:
    return s.replace('"', "'")


def parse_book(path: pathlib.Path):
    """Стихи книги: {(chapter, verse): (gloss, greek, [(en, gr), ...])}"""
    verses = {}
    cur = None
    for line in path.read_text(encoding='utf-8').splitlines():
        m = VERSE_RE.match(line)
        if m:
            cur = (int(m.group(1)), int(m.group(2)))
            verses[cur] = {'gloss': '', 'greek': '', 'pairs': ''}
            continue
        if cur is None:
            continue
        f = FIELD_RE.match(line)
        if f:
            verses[cur][f.group(1)] = f.group(2).strip()
    out = {}
    for (ch, v), d in verses.items():
        pairs = []
        for tok in d['pairs'].split(' | '):
            tok = tok.strip()
            if not tok:
                continue
            if '/' in tok:
                en, gr = tok.rsplit('/', 1)
            else:
                en, gr = tok, ''
            pairs.append((en.strip(), gr.strip()))
        out[(ch, v)] = (d['gloss'], d['greek'], pairs)
    return out


def build(src: pathlib.Path, dst: pathlib.Path, mod_id: str, title: str):
    db = sqlite3.connect(dst)
    # Маркер формата .sb — studybible-store отвергает файл без него.
    db.execute('PRAGMA application_id = 0x53424D31')
    # Компактная схема v1 (docs/spec/05): книги адресуются book_id,
    # текст стиха единожды в verses.text, спаны — байтовые срезы.
    db.executescript('''
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
                                PRIMARY KEY (book_id, chapter, verse,
                                             token_seq));
    ''')

    digest = hashlib.sha256()
    n_verses = n_words = 0
    for f in sorted(src.glob('*.md')):
        slug = f.stem.split('-', 1)[1]
        code = BOOKS.get(slug)
        if code is None:
            print('пропуск (неизвестная книга):', f.name)
            continue
        book_id = int(f.stem.split('-', 1)[0])
        verses = parse_book(f)
        if not verses:
            continue
        db.execute('INSERT INTO books VALUES (?,?,?,?)',
                   (book_id, code, book_id, BOOK_TITLES[code]))
        chapters = sorted({ch for ch, _ in verses})
        for ch in chapters:
            vlist = sorted(v for (c, v) in verses if c == ch)
            seq_in_ch = 0
            for v in vlist:
                n_verses += 1
                gloss, _greek, pairs = verses[(ch, v)]
                block = seq_in_ch
                seq_in_ch += 1
                # Потоковый хэш (С-12): заголовок блока, затем спаны.
                digest.update(
                    ('%s %d %d %s\x00' % (code, ch, block, 'p'))
                    .encode('utf-8'))
                db.execute('INSERT INTO blocks VALUES (?,?,?,?)',
                           (book_id, ch, block, 'p'))

                # Собираем verses.text и срезы слов — как ModuleWriter:
                # пробел между словами, если не перед знаком препинания.
                buf = ''
                rows = []
                if not pairs:
                    # Стих без разметки — один спан на весь текст.
                    pairs = [(gloss, '')]
                tok_seq = 0
                for en, gr in pairs:
                    if (buf and not buf.endswith(' ')
                            and not en.startswith(NO_LEAD_SPACE)):
                        buf += ' '
                    start = len(buf.encode('utf-8'))
                    buf += en
                    ln = len(en.encode('utf-8'))
                    attrs = 'gr="%s"' % esc(gr) if gr else ''
                    rows.append((book_id, ch, block, tok_seq, 't', None,
                                 v, start, ln, 'w' if gr else '', attrs,
                                 '', ''))
                    db.execute(
                        'INSERT INTO tokens VALUES (?,?,?,?,?,?,?,?,?)',
                        (book_id, ch, v, tok_seq, gr, '', '', '', en))
                    db.execute(
                        'INSERT INTO alignment VALUES (?,?,?,?,?,?)',
                        (book_id, ch, v, tok_seq, block, tok_seq))
                    digest.update(('t%s\x01%s\x01%s\x00'
                                   % ('w' if gr else '', attrs, en))
                                  .encode('utf-8'))
                    n_words += 1
                    tok_seq += 1
                if buf and not buf.endswith(' '):
                    buf += ' '
                db.execute('INSERT INTO verses VALUES (?,?,?,?)',
                           (book_id, ch, v, buf))
                db.executemany('INSERT INTO spans VALUES '
                               '(?,?,?,?,?,?,?,?,?,?,?,?,?)', rows)
    meta = {
        'format_version': '1', 'id': mod_id, 'title': title,
        'language': 'en', 'direction': 'ltr', 'versification': 'eng',
        'name_profile': 'en', 'book_order': 'syn', 'version': '1.0.0',
        'license': 'личный модуль пользователя; не распространять',
        'attribution': 'int_E. → int-en (gloss/greek/pairs)',
        'source': 'int-en', 'content_hash': digest.hexdigest(),
        'required': '',
        # ADR 0016: тип, возможности и права (личный модуль —
        # не раздавать).
        'kind': 'interlinear', 'features': 'tokens,alignment',
        'rights': 'no-distribute,no-net,no-ai,no-plugins',
    }
    db.executemany('INSERT INTO meta VALUES (?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.close()
    print('%s: %d стихов, %d слов-пар -> %s' % (mod_id, n_verses, n_words, dst))


if __name__ == '__main__':
    src = pathlib.Path(sys.argv[1])
    dst = pathlib.Path(sys.argv[2])
    mod_id = sys.argv[3] if len(sys.argv) > 3 else dst.stem
    title = sys.argv[4] if len(sys.argv) > 4 else mod_id
    if dst.exists():
        dst.unlink()
    build(src, dst, mod_id, title)
