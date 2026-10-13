"""Слой engbsb-strongs v2: dStrong через Clear manual alignments.

Цепочка: BSB-токен →(Clear WLCM/SBLGNT-BSB-manual)→ MACULA id →
(mid→спан step-orig)→ dStrong. Слова-группы (len(target)>1) — flag 'grp'.
Кросс-проверка: классический номер старого слоя bsb-strongs.sb против
базы dStrong → flag 'diff' + misses-отчёт.

Выход: work/strongs/layers/engbsb-strongs.sb (kind=layer,
features=strongs, target=engbsb, tokenizer=w1).
"""
import collections
import difflib
import csv
import hashlib
import json
import re
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'lexicon'))
import common as C  # noqa: E402

csv.field_size_limit(2**31 - 1)

CLEAR = C.SRC / 'clear-alignments' / 'data'
ORIG = C.DATA / 'work' / 'strongs' / 'orig'
WORK = C.DATA / 'work' / 'strongs' / 'layers'
OLD = C.DATA / 'work' / 'strongs' / 'lexicon' / 'bsb-strongs.sb'
BSB = C.DATA / 'modules' / 'engbsb.sb'
DST = WORK / 'engbsb-strongs.sb'

USFM = {i + 1: u for i, (u, _s, _e) in enumerate(C.BOOKS)}
BOOK_ID = {u: i + 1 for i, (u, _s, _e) in enumerate(C.BOOKS)}
NONALNUM = re.compile(r'[^0-9A-Za-z]+')


def norm(s):
    return NONALNUM.sub('', s).casefold()


def load_mid_index():
    """mid → (wid, strong); word-ключ (b,c,v,NN) → [strongs] — запасной
    уровень для макеф-пар и текстуальных расхождений."""
    idx = {}
    by_wid = collections.defaultdict(list)
    with open(ORIG / 'orig-words.jsonl', encoding='utf-8') as f:
        for line in f:
            d = json.loads(line)
            for w in d['w']:
                if w.get('mid'):
                    idx[w['mid']] = (w['wid'], w['strong'])
                m2 = re.match(r'.*\.(\d+)\.(\d+)#(\d+)$', w['wid'])
                if m2:
                    key = (d['b'], d['c'], d['v'], int(m2.group(3)))
                    if w['strong'] and w['strong'] not in by_wid[key]:
                        by_wid[key].append(w['strong'])
    return idx, by_wid


def mid_word_key(mid):
    """o010010020061 → (1,1,2,'06'); n40001011013 → (40,1,11,'13')."""
    if not mid or mid[0] not in 'on':
        return None
    try:
        return (int(mid[1:3]), int(mid[3:6]), int(mid[6:9]),
                int(mid[9:12]))
    except ValueError:
        return None


def load_targets():
    """bcv → {token_id: text} — только слова (exclude пуст)."""
    idx, excl = {}, set()
    for name in ('ot_BSB.tsv', 'nt_BSB.tsv'):
        with open(CLEAR / 'eng' / 'targets' / 'BSB' / name,
                  encoding='utf-8') as f:
            for r in csv.DictReader(f, delimiter='\t'):
                tid = r['id']
                bcv = (int(tid[:2]), int(tid[2:5]), int(tid[5:8]))
                if r.get('exclude') == 'y':
                    excl.add(tid)
                else:
                    idx.setdefault(bcv, {})[tid] = r['text']
    return idx, excl


def load_alignments():
    """bcv → [(src_ids, tgt_ids)]."""
    out = collections.defaultdict(list)
    for name in ('WLCM-BSB-manual.json', 'SBLGNT-BSB-manual.json'):
        d = json.load(open(CLEAR / 'eng' / 'alignments' / 'BSB' / name,
                           encoding='utf-8'))
        for r in d['records']:
            for t in r['target']:
                bcv = (int(t[:2]), int(t[2:5]), int(t[5:8]))
                out[bcv].append((r['source'], r['target']))
                break  # все target одного стиха — достаточно одного
    return out


def load_w1():
    """bcv → [words] из studybible tokenize."""
    idx = {}
    with open(WORK / 'bsb-words.jsonl', encoding='utf-8') as f:
        for line in f:
            if not line.strip() or '"_meta"' in line:
                continue
            d = json.loads(line)
            idx[(BOOK_ID[d['book']], d['chapter'], d['verse'])] = d['words']
    return idx


def map_tokens(tgts, w1_words):
    """token_id → w1-индекс через SequenceMatcher по норм. тексту."""
    # порядок = порядок id (BBBCCCVVVWWW)
    ids = sorted(tgts)
    ctexts = [norm(tgts[i]) for i in ids]
    wtexts = [norm(w) for w in w1_words]
    sm = difflib.SequenceMatcher(None, ctexts, wtexts, autojunk=False)
    out = {}
    blocks = sm.get_matching_blocks()
    prev_i = prev_j = 0
    for (i1, j1, n) in blocks + [(len(ctexts), len(wtexts), 0)]:
        # разрешаем разрывы: токен↔токены (man's↔man+s, Ellasar—four↔2 слова)
        ci, wj = prev_i, prev_j
        while ci < i1 and wj < j1:
            if ctexts[ci] == wtexts[wj]:
                out[ids[ci]] = wj
                ci += 1
                wj += 1
                continue
            c2 = ctexts[ci] + (ctexts[ci + 1] if ci + 1 < i1 else '')
            c3 = c2 + (ctexts[ci + 2] if ci + 2 < i1 else '')
            w2 = wtexts[wj] + (wtexts[wj + 1] if wj + 1 < j1 else '')
            w3 = w2 + (wtexts[wj + 2] if wj + 2 < j1 else '')
            if ci + 2 <= i1 and c2 == wtexts[wj]:
                for k in (ci, ci + 1):
                    out[ids[k]] = wj
                ci += 2
                wj += 1
            elif ci + 3 <= i1 and c3 == wtexts[wj]:
                for k in range(ci, ci + 3):
                    out[ids[k]] = wj
                ci += 3
                wj += 1
            elif wj + 2 <= j1 and ctexts[ci] == w2:
                out[ids[ci]] = wj
                ci += 1
                wj += 2
            elif wj + 3 <= j1 and ctexts[ci] == w3:
                out[ids[ci]] = wj
                ci += 1
                wj += 3
            else:
                ci += 1
        for k in range(n):
            out[ids[i1 + k]] = j1 + k
        prev_i, prev_j = i1 + n, j1 + n
    return out


def main():
    mid_idx, wid_idx = load_mid_index()
    tgt_idx, excl = load_targets()
    align = load_alignments()
    w1 = load_w1()

    # кросс-канал: старый слой (классические номера) для сверки
    old = {}
    if OLD.exists():
        odb = sqlite3.connect(OLD)
        for b, c, v, w, s in odb.execute(
                'select book_id,chapter,verse,word,strong from links'):
            old[(b, c, v, w)] = s
        odb.close()

    stats = collections.Counter()
    diffs = []
    unmapped_log = []
    links = {}          # (b,c,v,word) → [strongs, refs, flags, srcs]
    for bcv, words in w1.items():
        recs = align.get(bcv)
        if not recs:
            stats['verse_no_align'] += 1
            continue
        # токены стиха
        tgts = tgt_idx.get(bcv) or {}
        t2w = map_tokens(tgts, words)
        stats['tok_mapped'] += len(t2w)
        stats['tok_unmapped'] += len(tgts) - len(t2w)
        if len(tgts) - len(t2w) and len(unmapped_log) < 2000:
            left = [tgts[i] for i in tgts if i not in t2w]
            unmapped_log.append((bcv, left, words))
        for src_ids, tgt_ids in recs:
            strongs, refs, fb = [], [], False
            for sid in src_ids:
                hit = mid_idx.get(sid)
                if hit:
                    wid, st = hit
                    refs.append(wid)
                    if st and st not in strongs:
                        strongs.append(st)
                else:
                    stats['mid_missing'] += 1
                    wk = mid_word_key(sid)
                    ws = wid_idx.get(wk)
                    if ws:
                        fb = True
                        stats['mid_wid_fb'] += 1
                        for st in ws:
                            if st not in strongs:
                                strongs.append(st)
                        refs.append(sid)
                    else:
                        stats['mid_unresolved'] += 1
            multi = len(tgt_ids) > 1
            for tid in tgt_ids:
                if tid in excl:
                    continue
                w = t2w.get(tid)
                if w is None:
                    stats['tgt_no_word'] += 1
                    continue
                key = (bcv[0], bcv[1], bcv[2], w)
                L = links.setdefault(key, [[], [], set(), set()])
                for s in strongs:
                    if s not in L[0]:
                        L[0].append(s)
                for r_ in refs:
                    if r_ not in L[1]:
                        L[1].append(r_)
                if multi:
                    L[2].add('grp')
                if fb:
                    L[2].add('wid')
                if not strongs:
                    L[2].add('unresolved')
                L[3].add('clear-manual')
                stats['link'] += 1
                # сверка со старым слоем
                os_ = old.get(key)
                if os_ and strongs:
                    num = re.compile(r'^[HG]|[A-Z]$')
                    base = {int(num.sub('', s)) for s in strongs}
                    oset = {int(num.sub('', s)) for s in os_.split()}
                    if not oset <= base:
                        diffs.append((key, os_, ' '.join(strongs)))
                        L[2].add('diff')
                        stats['strong_diff'] += 1

    # запись
    if DST.exists():
        DST.unlink()
    db = sqlite3.connect(DST)
    db.execute('PRAGMA application_id = 0x53424D31')
    db.executescript('''
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
''')

    for (b, c, v, w), (ss, rr, ff, srcs) in links.items():
        conf = 4 if 'unresolved' in ff else 8 if 'wid' in ff else 10
        db.execute('INSERT INTO links VALUES (?,?,?,?,?,?,?,?,?)',
                   (b, c, v, w, ' '.join(rr), ' '.join(ss), conf,
                    ','.join(sorted(ff)), '+'.join(sorted(srcs))))
    meta = {
        'format_version': '1', 'id': 'engbsb-strongs',
        'title': 'BSB Strong layer (dStrong, Clear manual)',
        'language': 'en', 'direction': 'ltr', 'versification': 'eng',
        'name_profile': 'en', 'book_order': 'syn', 'version': '0.2.0',
        'license': 'CC BY 4.0',
        'attribution': 'Clear Bible WLCM/SBLGNT-BSB manual alignments '
                       '(CC BY 4.0); dStrong via step-orig (STEPBible '
                       'CC BY 4.0)',
        'source': 'clear-manual',
        'kind': 'layer', 'features': 'strongs',
        'target_id': 'engbsb',
        'tokenizer': 'w1',
        'required': '', 'content_hash': '',
    }
    th = json.loads(open(WORK / 'bsb-words.jsonl', encoding='utf-8')
                    .readline())['_meta']['target_hash']
    meta['target_hash'] = th
    meta['content_hash'] = hashlib.sha256(
        json.dumps(sorted(str(k) for k in links)).encode()).hexdigest()
    db.executemany('INSERT INTO meta VALUES (?,?)', meta.items())
    db.commit()
    db.execute('ANALYZE')
    db.commit()
    db.close()

    stats['links_total'] = len(links)
    stats['diff_total'] = len(diffs)
    with open(WORK / 'engbsb-strongs.diffs.tsv', 'w',
              encoding='utf-8') as f:
        for k, os_, ns in diffs:
            f.write('%s\t%s\t%s\n' % ('.'.join(map(str, k)), os_, ns))
    (WORK / 'stats-bsb-layer.json').write_text(
        json.dumps(dict(stats), ensure_ascii=False, indent=1),
        encoding='utf-8')
    with open(WORK / 'unmapped.tsv', 'w', encoding='utf-8') as f:
        for bcv, left, words in unmapped_log:
            f.write('%s\t%s\t%s\n'
                    % (bcv, '|'.join(left), '|'.join(words)))
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
