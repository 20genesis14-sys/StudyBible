"""T2+T3: TAHOT/TAGNT → поток морфем step-orig (ADR 0025 §3).

Выход work/strongs/orig/orig-words.jsonl — по строке на стих:
{"b":1,"c":1,"v":1,"w":[{"gr","gloss","strong","morph","lemma","wid",
 "typ","ed","sns","eid","conj"} ...]} — w = спан-морфема.

TAHOT: морфемы делятся '/' и '\\' (постпозитивные: пунктуация).
Колонки: 0 ref=typ, 1 form, 2 translit, 3 gloss, 4 dStrongs,
5 grammar, 6/7 variants, 8 root+inst, 9 alt, 10 conjoin, 11 expanded.
TAGNT: 0 ref=typ(N/K/O), 1 form (translit), 2 eng, 3 dS=gram,
4 lemma=gloss, 5 editions, 6/7 variants, 8 spanish, 9 sub-meaning
(сущность »Name@Range и метка |N_sense), 10 conjoin, 11 sStrong, 12 alt.
"""
import collections
import json
import re
import sys

sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent.parent / 'lexicon'))
import common as C  # noqa: E402

STEP = C.STEP / 'Translators Amalgamated OT+NT'
WORK = C.DATA / 'work' / 'strongs' / 'orig'

REF = re.compile(
    r'^([1-3]?[A-Z][a-z]{1,2})\.(\d+)\.(\d+)(?:\([\d.]+\))?#(\d+)=(\S+)')
# сегмент расширенного тега: CODE=LEMMA=TRANS
SEG = re.compile(r'([HG]\d{3,5}[A-Z]?)=([^={}»|]*)=([^{}]*)')
# метка значения: 'first:1_beginning' или 'to do/make|1_do/work'
SENSE = re.compile(r'(\d+_[A-Za-z0-9_/()&.\' -]+)')
# сущность »Name@Range (range: Book.ch.vs-Book|Book.ch.vs-Book.ch.vs)
ENT = re.compile(r'([\w\' .|]+?)@([1-3]?[A-Z][a-z]{1,2}\.\d+\.\d+'
                r'(?:-[1-3]?[A-Z][a-z]{1,2}(?:\.\d+\.\d+)?)?)')


def sense_of(trans):
    m = SENSE.search(trans)
    return m.group(1) if m else ''


def entity_of(trans):
    m = ENT.search(trans)
    if not m:
        return ''
    names = m.group(1).split('»')[-1].split('|')
    return names[-1].strip() + '@' + m.group(2)


def clean_gloss(g):
    """' : beginning»first:1_beginning' → 'beginning'."""
    g = g.split('»')[0].split('@')[0].split('|')[0]
    return g.strip(' :')


def split_segs(s):
    """'H9003/{H7225G}\\H9016' → (['H9003','{H7225G}'], ['H9016'])."""
    main, _, post = s.partition('\\')
    return ([p for p in main.split('/') if p], [p for p in post.split('/') if p])


def parse_tahot(verses):
    n_lines = n_gloss_mismatch = 0
    for path in sorted(STEP.glob('TAHOT*')):
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                m = REF.match(line)
                if not m or m.group(1) not in C.STEPAB:
                    continue
                n_lines += 1
                book = C.STEPAB[m.group(1)]
                ch, vs, wnum, typ = (int(m.group(2)), int(m.group(3)),
                                     m.group(4), m.group(5))
                c = line.rstrip('\n').split('\t')
                c += [''] * (13 - len(c))
                wid = '%s.%d.%d#%s' % (m.group(1), ch, vs, wnum)

                # морфемы из expanded-тегов — там и лемма, и глосс морфемы
                segs = []
                for code, lemma, trans in SEG.findall(c[11]):
                    segs.append(dict(
                        strong=code, lemma=lemma, gloss=clean_gloss(trans),
                        sns=sense_of(trans), eid=entity_of(trans)))
                # формы/морфология/номера из своих колонок — по сегментам
                forms = [p for p in re.split(r'[/\\]', c[1].strip()) if p]
                morphs = [p.strip() for p in re.split(r'[/\\]', c[5].strip())
                          if p.strip()]
                dsegs_m, dsegs_p = split_segs(c[4].strip())
                # сегмент может быть '{H2657H}+' — код берём regex
                dsts = []
                for s in dsegs_m + dsegs_p:
                    mm = re.search(r'[HG]\d{3,5}[A-Z]?', s)
                    dsts.append(mm.group(0) if mm else '')
                gloss_parts = c[3].split('/')

                n_all = len(dsts)
                if len(segs) != n_all:
                    segs = segs[:n_all] or [dict(strong='', lemma='',
                                                 gloss='', sns='', eid='')]
                for i in range(n_all):
                    seg = segs[i] if i < len(segs) else dict(
                        strong=dsts[i], lemma='', gloss='', sns='', eid='')
                    if i < len(dsegs_m) and i < len(gloss_parts):
                        # контекстный глосс колонки 3 — приоритетнее
                        cg = clean_gloss(gloss_parts[i])
                        if cg:
                            seg['gloss'] = cg
                        elif not seg['gloss']:
                            n_gloss_mismatch += 1
                    w = dict(gr=forms[i] if i < len(forms) else '',
                             gloss=seg['gloss'], strong=dsts[i],
                             morph=morphs[i] if i < len(morphs) else '',
                             lemma=seg['lemma'], wid=wid, typ=typ,
                             ed='', sns=seg['sns'], eid=seg['eid'],
                             conj=c[10].strip()
                                 if '»' in c[10] or ':' in c[10]
                                 else '')
                    verses[(book, ch, vs)].append(w)
    return n_lines, n_gloss_mismatch


def parse_tagnt(verses):
    n_lines = 0
    for path in sorted(STEP.glob('TAGNT*')):
        with open(path, encoding='utf-8-sig') as f:
            for line in f:
                m = REF.match(line)
                if not m or m.group(1) not in C.STEPAB:
                    continue
                n_lines += 1
                book = C.STEPAB[m.group(1)]
                ch, vs, wnum, typ = (int(m.group(2)), int(m.group(3)),
                                     m.group(4), m.group(5))
                c = line.rstrip('\n').split('\t')
                c += [''] * (14 - len(c))
                wid = '%s.%d.%d#%s' % (m.group(1), ch, vs, wnum)

                form = re.sub(r'\s*\([^()]*\)\s*$', '', c[1].strip())
                ds = c[3].split('=')
                codes = re.findall(r'G\d{4,5}[A-Z]?', ds[0])
                lemma = c[4].split('=', 1)[0].strip()
                sub = c[9]
                w = dict(gr=form, gloss=c[2].strip(),
                         strong=codes[0] if codes else '',
                         morph=ds[1].strip() if len(ds) > 1 else '',
                         lemma=lemma, wid=wid, typ=typ,
                         ed=c[5].strip(), sns=sense_of(sub),
                         eid=entity_of(sub),
                         conj=c[10].strip()
                             if '»' in c[10] or ':' in c[10] else '')
                verses[(book, ch, vs)].append(w)
    return n_lines


def main():
    verses = collections.defaultdict(list)
    nh, miss = parse_tahot(verses)
    ng = parse_tagnt(verses)

    WORK.mkdir(parents=True, exist_ok=True)
    n_spans = 0
    with open(WORK / 'orig-words.jsonl', 'w', encoding='utf-8') as out:
        for (b, c, v) in sorted(verses):
            ws = verses[(b, c, v)]
            n_spans += len(ws)
            out.write(json.dumps(dict(b=b, c=c, v=v, w=ws),
                                 ensure_ascii=False) + '\n')

    stats = dict(
        verses=len(verses), spans=n_spans,
        tahot_rows=nh, tagnt_rows=ng, gloss_fallbacks=miss,
        heb_spans=sum(len(v) for k, v in verses.items() if k[0] < 40),
        grc_spans=sum(len(v) for k, v in verses.items() if k[0] >= 40),
        with_eid=sum(1 for ws in verses.values()
                     for w in ws if w['eid']),
        with_sns=sum(1 for ws in verses.values()
                     for w in ws if w['sns']))
    (WORK / 'stats-parse.json').write_text(
        json.dumps(stats, ensure_ascii=False, indent=1), encoding='utf-8')
    print(json.dumps(stats, ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
