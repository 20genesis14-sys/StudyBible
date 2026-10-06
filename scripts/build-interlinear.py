#!/usr/bin/env python3
"""Сборка .sb-модуля из подстрочника формата int-en (markdown с парами gloss/greek).

Вход: каталог text/ с файлами NN-slug.md, где каждый стих — блок:
    Matt 1:1
      gloss: <английская дословная строка>
      greek: <греческая строка>
      pairs: <слово>/ <слово> | <слово>/<слово> | …

Выход: модуль .sb, где текст стиха — gloss, а каждое слово gloss —
спан style='w' с attrs gr="<греческое слово>". В приложении такие модули
в режиме сравнения рисуются подстрочником «перевод над оригиналом».
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

VERSE_RE = re.compile(r'^\S+ (\d+):(\d+)\s*$')
FIELD_RE = re.compile(r'^\s{2}(gloss|greek|pairs):\s?(.*)$')


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
    db.executescript('''
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE books (code TEXT PRIMARY KEY, ord INTEGER NOT NULL,
                            title TEXT NOT NULL DEFAULT '');
        CREATE TABLE book_headers (book TEXT NOT NULL, marker TEXT NOT NULL,
                                   text TEXT NOT NULL,
                                   PRIMARY KEY (book, marker));
        CREATE TABLE blocks (book TEXT NOT NULL, chapter INTEGER NOT NULL,
                             seq INTEGER NOT NULL, marker TEXT NOT NULL DEFAULT '',
                             PRIMARY KEY (book, chapter, seq));
        CREATE TABLE spans (book TEXT NOT NULL, chapter INTEGER NOT NULL,
                            block INTEGER NOT NULL, seq INTEGER NOT NULL,
                            kind TEXT NOT NULL, num INTEGER, style TEXT NOT NULL DEFAULT '',
                            attrs TEXT NOT NULL DEFAULT '', caller TEXT NOT NULL DEFAULT '',
                            text TEXT NOT NULL DEFAULT '',
                            PRIMARY KEY (book, chapter, block, seq));
        CREATE TABLE verses (book TEXT NOT NULL, chapter INTEGER NOT NULL,
                             verse INTEGER NOT NULL, text TEXT NOT NULL,
                             PRIMARY KEY (book, chapter, verse));
    ''')
    book_titles = {
        'MAT': 'Matthew', 'MRK': 'Mark', 'LUK': 'Luke', 'JHN': 'John',
        'ACT': 'Acts', 'ROM': 'Romans', '1CO': '1 Corinthians',
        '2CO': '2 Corinthians', 'GAL': 'Galatians', 'EPH': 'Ephesians',
        'PHP': 'Philippians', 'COL': 'Colossians', '1TH': '1 Thessalonians',
        '2TH': '2 Thessalonians', '1TI': '1 Timothy', '2TI': '2 Timothy',
        'TIT': 'Titus', 'PHM': 'Philemon', 'HEB': 'Hebrews', 'JAS': 'James',
        '1PE': '1 Peter', '2PE': '2 Peter', '1JN': '1 John', '2JN': '2 John',
        '3JN': '3 John', 'JUD': 'Jude', 'REV': 'Revelation',
    }
    digest = hashlib.sha256()
    n_verses = n_words = 0
    for f in sorted(src.glob('*.md')):
        slug = f.stem.split('-', 1)[1]
        code = BOOKS.get(slug)
        if code is None:
            print('пропуск (неизвестная книга):', f.name)
            continue
        digest.update(f.read_bytes())
        verses = parse_book(f)
        if not verses:
            continue
        db.execute('INSERT INTO books VALUES (?,?,?)',
                   (code, int(f.stem.split('-', 1)[0]), book_titles[code]))
        chapters = {}
        for (ch, v), (gloss, greek, pairs) in sorted(verses.items()):
            chapters.setdefault(ch, []).append(v)
            n_verses += 1
            seq_in_ch = len(chapters[ch]) - 1
            db.execute('INSERT INTO blocks VALUES (?,?,?,?)',
                       (code, ch, seq_in_ch, 'p'))
            db.execute('INSERT INTO verses VALUES (?,?,?,?)',
                       (code, ch, v, gloss))
            db.execute('INSERT INTO spans VALUES (?,?,?,?,?,?,?,?,?,?)',
                       (code, ch, seq_in_ch, 0, 'v', v, '', '', '', ''))
            for i, (en, gr) in enumerate(pairs, 1):
                attrs = 'gr="%s"' % esc(gr) if gr else ''
                db.execute('INSERT INTO spans VALUES (?,?,?,?,?,?,?,?,?,?)',
                           (code, ch, seq_in_ch, i, 't', None, 'w', attrs, '',
                            en + ' '))
                n_words += 1
    meta = {
        'format_version': '1', 'id': mod_id, 'title': title,
        'language': 'en', 'direction': 'ltr', 'versification': 'eng',
        'name_profile': 'en', 'book_order': 'syn', 'version': '1.0.0',
        'license': 'личный модуль пользователя; не распространять',
        'attribution': 'int_E. → int-en (gloss/greek/pairs)',
        'source': 'int-en', 'content_hash': digest.hexdigest(),
        'required': '', 'interlinear': '1',
    }
    db.executemany('INSERT INTO meta VALUES (?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.close()
    print('%s: %d стихов, %d слов-пар → %s' % (mod_id, n_verses, n_words, dst))


if __name__ == '__main__':
    src = pathlib.Path(sys.argv[1])
    dst = pathlib.Path(sys.argv[2])
    mod_id = sys.argv[3] if len(sys.argv) > 3 else dst.stem
    title = sys.argv[4] if len(sys.argv) > 4 else mod_id
    if dst.exists():
        dst.unlink()
    build(src, dst, mod_id, title)
