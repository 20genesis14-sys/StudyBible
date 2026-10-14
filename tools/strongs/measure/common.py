"""Общие загрузчики для замеров фазы 1 трека «Расширенный Стронг» (ADR 0025).

Только стандартная библиотека. Пути берутся из STUDYBIBLE_DATA
(по умолчанию D:\\StudyBible-data); отчёты пишутся в
STUDYBIBLE_DATA/work/strongs/measure/.

Ключ стиха везде — (book, chapter, verse), book = 1..66 в порядке
протестантского канона (как BB в идентификаторах Clear/MACULA).
"""
import collections
import csv
import json
import os
import re
import sqlite3
from pathlib import Path

csv.field_size_limit(2**31 - 1)

DATA = Path(os.environ.get('STUDYBIBLE_DATA', r'D:\StudyBible-data'))
SRC = DATA / 'sources' / 'strongs'
WORK = DATA / 'work' / 'strongs' / 'measure'
STEP = SRC / 'stepbible'

# Порядок книг: USFM-код, аббревиатура STEPBible, английское имя (BSB tables).
BOOKS = [
    ('GEN', 'Gen', 'Genesis'), ('EXO', 'Exo', 'Exodus'), ('LEV', 'Lev', 'Leviticus'),
    ('NUM', 'Num', 'Numbers'), ('DEU', 'Deu', 'Deuteronomy'), ('JOS', 'Jos', 'Joshua'),
    ('JDG', 'Jdg', 'Judges'), ('RUT', 'Rut', 'Ruth'), ('1SA', '1Sa', '1 Samuel'),
    ('2SA', '2Sa', '2 Samuel'), ('1KI', '1Ki', '1 Kings'), ('2KI', '2Ki', '2 Kings'),
    ('1CH', '1Ch', '1 Chronicles'), ('2CH', '2Ch', '2 Chronicles'), ('EZR', 'Ezr', 'Ezra'),
    ('NEH', 'Neh', 'Nehemiah'), ('EST', 'Est', 'Esther'), ('JOB', 'Job', 'Job'),
    ('PSA', 'Psa', 'Psalm'), ('PRO', 'Pro', 'Proverbs'), ('ECC', 'Ecc', 'Ecclesiastes'),
    ('SNG', 'Sng', 'Song of Solomon'), ('ISA', 'Isa', 'Isaiah'), ('JER', 'Jer', 'Jeremiah'),
    ('LAM', 'Lam', 'Lamentations'), ('EZK', 'Ezk', 'Ezekiel'), ('DAN', 'Dan', 'Daniel'),
    ('HOS', 'Hos', 'Hosea'), ('JOL', 'Jol', 'Joel'), ('AMO', 'Amo', 'Amos'),
    ('OBA', 'Oba', 'Obadiah'), ('JON', 'Jon', 'Jonah'), ('MIC', 'Mic', 'Micah'),
    ('NAM', 'Nam', 'Nahum'), ('HAB', 'Hab', 'Habakkuk'), ('ZEP', 'Zep', 'Zephaniah'),
    ('HAG', 'Hag', 'Haggai'), ('ZEC', 'Zec', 'Zechariah'), ('MAL', 'Mal', 'Malachi'),
    ('MAT', 'Mat', 'Matthew'), ('MRK', 'Mrk', 'Mark'), ('LUK', 'Luk', 'Luke'),
    ('JHN', 'Jhn', 'John'), ('ACT', 'Act', 'Acts'), ('ROM', 'Rom', 'Romans'),
    ('1CO', '1Co', '1 Corinthians'), ('2CO', '2Co', '2 Corinthians'), ('GAL', 'Gal', 'Galatians'),
    ('EPH', 'Eph', 'Ephesians'), ('PHP', 'Php', 'Philippians'), ('COL', 'Col', 'Colossians'),
    ('1TH', '1Th', '1 Thessalonians'), ('2TH', '2Th', '2 Thessalonians'), ('1TI', '1Ti', '1 Timothy'),
    ('2TI', '2Ti', '2 Timothy'), ('TIT', 'Tit', 'Titus'), ('PHM', 'Phm', 'Philemon'),
    ('HEB', 'Heb', 'Hebrews'), ('JAS', 'Jas', 'James'), ('1PE', '1Pe', '1 Peter'),
    ('2PE', '2Pe', '2 Peter'), ('1JN', '1Jn', '1 John'), ('2JN', '2Jn', '2 John'),
    ('3JN', '3Jn', '3 John'), ('JUD', 'Jud', 'Jude'), ('REV', 'Rev', 'Revelation'),
]
USFM = {u: i + 1 for i, (u, _, _) in enumerate(BOOKS)}
STEPAB = {s: i + 1 for i, (_, s, _) in enumerate(BOOKS)}
ENGNAME = {e: i + 1 for i, (_, _, e) in enumerate(BOOKS)}

# Отложенные книги (ADR 0025 §8): (book, chapter_from, chapter_to) — включительно.
HELD_OUT = [(8, 1, 999), (32, 1, 999), (15, 1, 999), (19, 1, 41), (23, 40, 55),
            (41, 1, 999), (50, 1, 999), (59, 1, 999), (66, 1, 5)]


def held_out(key):
    b, c = key[0], key[1]
    return any(b == hb and lo <= c <= hi for hb, lo, hi in HELD_OUT)


def is_nt(book):
    return book >= 40


# ---------- номера Стронга ----------

NUM = re.compile(r'([HG])0*(\d+)([A-Za-z]?)')


def classic(tag):
    """'H7225G' → 'H7225'; 'G0976' → 'G976'. Морфемы H9xxx и греческие
    номера за пределами словаря Стронга (> 5624) → None."""
    m = NUM.match(tag or '')
    if not m:
        return None
    p, n = m.group(1), int(m.group(2))
    if (p == 'H' and (n == 0 or n > 8674)) or (p == 'G' and (n == 0 or n > 5624)):
        return None
    return f'{p}{n}'


def norm_classic(raw, prefix):
    """Номер из эталона без префикса или с ним ('07225', 'H0430', '976') → 'H7225'."""
    raw = raw.strip()
    if not raw:
        return None
    if raw[0] in 'HG':
        return classic(raw)
    digits = re.match(r'\d+', raw)
    return classic(prefix + digits.group(0)) if digits else None


# ---------- STEPBible TAHOT / TAGNT ----------

REF = re.compile(
    r'^([1-3]?[A-Z][a-z]{1,2})\.(\d+)\.(\d+)(?:[\(\[\{]([\d.]+)[\)\]\}])?#(\d+)=(\S+)'
)


def parse_src_bcv(book, ch, vs, heb_ref):
    """(book, eng_ch, eng_vs, '32.1') -> (book, 32, 1)."""
    if heb_ref and '.' in heb_ref:
        hc, hv = heb_ref.split('.', 1)
        if hc.isdigit() and hv.isdigit():
            return (book, int(hc), int(hv))
    return (book, ch, vs)


def step_bcv_maps(testament='both'):
    """Двусторонние карты (eng_bcv -> src_bcv, src_bcv -> eng_bcv) из TAHOT/TAGNT."""
    eng2src, src2eng = {}, {}
    files = []
    if testament in ('both', 'ot'):
        files += _step_files('TAHOT')
    if testament in ('both', 'nt'):
        files += _step_files('TAGNT')
    for path in files:
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                m = REF.match(line)
                if not m:
                    continue
                book = STEPAB.get(m.group(1))
                if not book:
                    continue
                ebcv = (book, int(m.group(2)), int(m.group(3)))
                sbcv = parse_src_bcv(book, ebcv[1], ebcv[2], m.group(4))
                eng2src[ebcv] = sbcv
                src2eng.setdefault(sbcv, ebcv)
    return eng2src, src2eng


class Word:
    __slots__ = ('key', 'addr', 'no', 'type', 'text', 'gloss', 'tags', 'root', 'grammar',
                 'editions', 'submeaning', 'entities', 'sstrong', 'heb_ref')

    def classics(self):
        """Классические номера слова: корень и (для иврита) все морфемы со своим номером."""
        out = []
        for t in self.tags:
            c = classic(t)
            if c and c not in out:
                out.append(c)
        if self.sstrong:
            c = classic(self.sstrong)
            if c and c not in out:
                out.append(c)
        return out


def _step_files(prefix):
    d = STEP / 'Translators Amalgamated OT+NT'
    return sorted(p for p in d.iterdir() if p.name.startswith(prefix))


ENTITY = re.compile(r'([^=»{}/\\|]+@[A-Za-z0-9.\-]+)')


def load_step(testament='both'):
    """{(book, ch, v): [Word…]} из TAHOT (ВЗ) и/или TAGNT (НЗ), английская нумерация."""
    verses = collections.defaultdict(list)
    files = []
    if testament in ('both', 'ot'):
        files += [('H', p) for p in _step_files('TAHOT')]
    if testament in ('both', 'nt'):
        files += [('G', p) for p in _step_files('TAGNT')]
    for lang, path in files:
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                m = REF.match(line)
                if not m:
                    continue
                book = STEPAB.get(m.group(1))
                if not book:
                    continue
                c = line.rstrip('\n').split('\t')
                w = Word()
                w.key = (book, int(m.group(2)), int(m.group(3)))
                w.heb_ref = m.group(4)
                w.no = int(m.group(5))
                w.addr = c[0].split('=')[0]
                w.type = m.group(6)
                w.text = c[1]
                if lang == 'H':
                    w.gloss = c[3]
                    w.tags = re.findall(r'H\d{4,5}[A-Z]?', c[4].split('\\')[0])
                    rm = re.search(r'\{(H\d{4,5}[A-Z]?)\}', c[4])
                    w.root = rm.group(1) if rm else (w.tags[0] if w.tags else None)
                    w.grammar = c[5]
                    w.editions = ''
                    exp = c[11] if len(c) > 11 else ''
                    sub = re.search(r'\{[^}]*»([^}]*)\}', exp)
                    w.submeaning = sub.group(1) if sub else ''
                    w.sstrong = None
                    w.entities = ENTITY.findall(exp)
                else:
                    w.gloss = c[2]
                    ds = c[3].split('=')[0].strip()
                    w.tags = re.findall(r'G\d{4,5}[A-Z]?', ds)
                    w.root = w.tags[0] if w.tags else None
                    w.grammar = c[3].split('=', 1)[1].strip() if '=' in c[3] else ''
                    w.editions = c[5] if len(c) > 5 else ''
                    w.submeaning = c[9] if len(c) > 9 else ''
                    ss = re.match(r'G\d+', c[11]) if len(c) > 11 else None
                    w.sstrong = ss.group(0) if ss else None
                    w.entities = ENTITY.findall(w.submeaning)
                verses[w.key].append(w)
    return verses


def step_verse_classics(words, edition=None):
    """Множество классических номеров стиха; edition='TR' — только слова с K в типе (TAGNT)."""
    out = set()
    for w in words:
        if edition == 'TR' and w.key[0] >= 40 and 'K' not in w.type.upper():
            continue
        out.update(w.classics())
    return out


# ---------- эталоны ----------

def load_bsb_tables():
    """{key: [(english_phrase, classic or None, original_word)]} в порядке BSB."""
    verses = collections.defaultdict(list)
    cur = None
    with open(SRC / 'bsb' / 'bsb_tables.tsv', encoding='utf-8-sig') as f:
        r = csv.reader(f, delimiter='\t', quoting=csv.QUOTE_NONE)
        next(r)
        for row in r:
            if len(row) < 19:
                continue
            if row[12].strip():
                m = re.match(r'(.+?) (\d+):(\d+)$', row[12].strip())
                if m and m.group(1) in ENGNAME:
                    cur = (ENGNAME[m.group(1)], int(m.group(2)), int(m.group(3)))
            if cur is None:
                continue
            eng = row[18].strip()
            sh, sg = row[10].strip(), row[11].strip()
            num = norm_classic(sh, 'H') if sh else (norm_classic(sg, 'G') if sg else None)
            if eng or row[5].strip():
                verses[cur].append((eng, num, row[5].strip()))
    return verses


USFM_W = re.compile(r'\\\+?w ([^|\\]*)\|strong="([^"]+)"\\\+?w\*')


def load_kjv():
    """{key: [(word, classic)]} — только размеченные слова KJV (eBible eng-kjv2006)."""
    verses = collections.defaultdict(list)
    d = DATA / 'sources' / 'eng-kjv2006'
    for p in sorted(d.glob('*.usfm')):
        text = open(p, encoding='utf-8-sig').read()
        m = re.search(r'\\id (\w+)', text)
        book = USFM.get(m.group(1)) if m else None
        if not book:
            continue
        for cm in re.finditer(r'\\c (\d+)(.*?)(?=\\c \d+|\Z)', text, re.S):
            ch = int(cm.group(1))
            for vm in re.finditer(r'\\v (\d+) (.*?)(?=\\v \d+ |\Z)', cm.group(2), re.S):
                key = (book, ch, int(vm.group(1)))
                for w, s in USFM_W.findall(vm.group(2)):
                    verses[key].append((w, norm_classic(s, 'H' if book < 40 else 'G')))
    return verses


ESV_ABBR = {'Joh': 'JHN', 'Mar': 'MRK', 'Rth': 'RUT', 'Son': 'SNG', 'Eze': 'EZK', 'Joe': 'JOL',
            'php': 'PHP', '1Jo': '1JN', '2Jo': '2JN', '3Jo': '3JN', 'Jud': 'JUD', 'Nah': 'NAM',
            'Psa': 'PSA', 'Pro': 'PRO', 'Ecc': 'ECC', 'Mat': 'MAT', 'Luk': 'LUK', 'Act': 'ACT',
            'Jdg': 'JDG', 'Jos': 'JOS', 'Phm': 'PHM', 'Jas': 'JAS'}


def load_esv():
    """{key: [(word, [classic…])]} — все слова ESV 2016 + TTESV (локальная копия)."""
    verses = collections.defaultdict(list)
    db = sqlite3.connect(f"file:{(SRC / 'esv' / 'esv2016_strongs_step.sqlite').as_posix()}?mode=ro", uri=True)
    order = [a for (a,) in db.execute('select book_abbr from verses group by book_abbr order by min(id)')]
    bookno = {a: i + 1 for i, a in enumerate(order)}
    for a, ch, v, word, st in db.execute(
            'select v.book_abbr, v.chapter, v.verse, w.word, w.strongs from words w '
            'join verses v on v.id = w.verse_id order by w.verse_id, w.seq'):
        b = bookno[a]
        nums = [n for n in (norm_classic(x, 'H' if b < 40 else 'G') for x in (st or '').split(',')) if n]
        verses[(b, ch, v)].append((word, nums))
    return verses


def load_clear(lang, version, source):
    """Ручная разметка Clear: (records, tokens{id: (text, is_punct)})."""
    d = SRC / 'clear-alignments' / 'data' / lang
    canon = 'nt' if source in ('SBLGNT', 'BGNT') else 'ot'
    tokens = {}
    with open(d / 'targets' / version / f'{canon}_{version}.tsv', encoding='utf-8') as f:
        for line in f:
            c = line.rstrip('\n').split('\t')
            if c[0] == 'id' or len(c) < 3:
                continue
            punct = (len(c) > 4 and c[4] == 'y') or not any(ch.isalnum() for ch in c[2])
            tokens[c[0]] = (c[2], punct)
    js = next((d / 'alignments' / version).glob(f'{source}-{version}-*.json'))
    recs = json.load(open(js, encoding='utf-8'))['records']
    for r in recs:
        if 'target' in r:
            r['target'] = [t[:11] if len(t) == 12 and t[:11] in tokens else t
                           for t in r['target']]
    return recs, tokens


def load_macula(testament):
    """{xml:id: row dict} MACULA (иврит WLC или греческий SBLGNT)."""
    p = (SRC / 'macula-hebrew' / 'WLC' / 'tsv' / 'macula-hebrew.tsv') if testament == 'ot' else \
        (SRC / 'macula-greek' / 'SBLGNT' / 'tsv' / 'macula-greek-SBLGNT.tsv')
    out = {}
    with open(p, encoding='utf-8') as f:
        for row in csv.DictReader(f, delimiter='\t', quoting=csv.QUOTE_NONE):
            out[row['xml:id']] = row
    return out


# Внутренние коды Groves Center в macula-hebrew.tsv для неотделяемых
# приставок и местоименных суффиксов (в STEPBible это H9xxx, в классическом
# словаре Стронга номеров не имеют; без фильтра '0871a' превращается в H871
# «Афарим», '1886a' — в H1886 «Дафан», '2050b' — в H2050 «разрушение»).
GROVES_AFFIX_CODES = {
    '0001a', '0001b', '0871a', '0871b', '1886a', '1886b', '1886c', '1886d',
    '1886f', '1886g', '1886h', '1886i', '1886j', '1886j|2050b', '1896b',
    '1930a', '1952a', '1958a', '1958b', '2004', '2004a', '2050b', '2050c',
    '2050d', '2967a', '2967b', '3509a', '3509b', '3509c', '3509d', '3509e',
    '3561a', '3641b', '3654a', '3807a', '3807b', '3807z', '3963a', '4993b',
    '4993c', '4996b', '5089a', '5105a', '5105b', '5204a', '5204b', '7578a',
}


def macula_classic(row, testament):
    raw = (row.get('strongnumberx') if testament == 'ot' else row.get('strong')) or ''
    if testament == 'ot' and raw.strip() in GROVES_AFFIX_CODES:
        return None
    return norm_classic(re.sub(r'[^0-9]', '', raw), 'H' if testament == 'ot' else 'G')


# ---------- отчёты ----------

FUNCTION_WORDS = set('''the a an of and to in that for is was be it he his him they them their i you your we
our us my me she her its this these those with as by on at from or but not so then there which who whom
what when all shall will have has had were are been do did said s 's unto upon thou thee thy ye hath'''.split())


def write_report(name, data, summary_md):
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / f'{name}.json').write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding='utf-8')
    (WORK / f'{name}.md').write_text(summary_md, encoding='utf-8')
    print(summary_md)


def pct(a, b):
    return round(100.0 * a / b, 1) if b else 0.0
