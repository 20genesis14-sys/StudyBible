"""Замер E: источник значений для греческого подстрочника.

1. TAGNT «Sub-meaning»: сколько слов НЗ имеют значение, сколько лемм
   имеют ≥ 2 разных значения и какая доля словоупотреблений приходится
   на такие леммы (без имён собственных).
2. Уточнённые номера TAGNT с буквой (G4151G/H…): доля словоупотреблений.
3. MACULA SBLGNT: покрытие доменов Louw–Nida (`ln`) и сколько лемм
   имеют ≥ 2 разных домена.
"""
import collections
import re

import common as C


def main():
    step = C.load_step('nt')
    sub = collections.defaultdict(collections.Counter)
    numbered = collections.defaultdict(collections.Counter)
    tokens = with_sub = lettered = 0
    for words in step.values():
        for w in words:
            if not w.root or w.grammar.endswith(('-P', '-L', '-T')) or '@' in w.submeaning:
                continue
            tokens += 1
            lemma = C.classic(w.sstrong or w.root) or w.root
            if re.match(r'G\d{4}[A-Z]$', w.root):
                lettered += 1
            s = w.submeaning.split('»')[-1].strip()
            if s:
                with_sub += 1
                sub[lemma][s] += 1
            sm = re.search(r'\|(\d+_[^|]*)', w.submeaning)
            if sm:
                numbered[lemma][sm.group(1)] += 1
    multi = {l: c for l, c in sub.items() if len(c) >= 2}
    multi_tokens = sum(sum(c.values()) for c in multi.values())
    examples = {l: c.most_common(6) for l, c in sorted(multi.items(), key=lambda x: -sum(x[1].values()))[:15]}

    mac = C.load_macula('nt')
    ln_tok = ln_has = 0
    lnmap = collections.defaultdict(set)
    for r in mac.values():
        if r.get('class') == 'noun' and r.get('type') == 'proper':
            continue
        ln_tok += 1
        ln = (r.get('ln') or '').strip()
        if ln:
            ln_has += 1
            lnmap[r['lemma']].add(ln.split()[0])
    ln_multi = sum(1 for s in lnmap.values() if len(s) >= 2)
    num_tokens = sum(sum(c.values()) for c in numbered.values())
    num_multi = sum(1 for c in numbered.values() if len(c) >= 2)
    res = {'tagnt_numbered_sense_tokens_pct': C.pct(num_tokens, tokens),
           'tagnt_lemmas_with_numbered_senses': len(numbered), 'tagnt_lemmas_2plus_numbered': num_multi,
           'tagnt_tokens': tokens, 'tagnt_with_submeaning_pct': C.pct(with_sub, tokens),
           'tagnt_lemmas_with_2plus_submeanings': len(multi), 'tagnt_tokens_of_such_lemmas_pct': C.pct(multi_tokens, tokens),
           'tagnt_lettered_dstrong_tokens_pct': C.pct(lettered, tokens),
           'examples': examples,
           'macula_tokens': ln_tok, 'macula_ln_coverage_pct': C.pct(ln_has, ln_tok),
           'macula_lemmas': len(lnmap), 'macula_lemmas_2plus_ln': ln_multi}
    lines = ['# Замер E — значения для греческого подстрочника', '',
             f"- TAGNT (без имён): {tokens} словоупотреблений; «Sub-meaning» заполнено у {res['tagnt_with_submeaning_pct']} %.",
             f"- Но это в основном контекстный перевод формы (him / to him / of him). Настоящая "
             f"нумерованная метка значения (`слово|1_значение`, как в TAHOT) — у {res['tagnt_numbered_sense_tokens_pct']} % "
             f"словоупотреблений, {len(numbered)} лемм (с ≥ 2 значениями — {num_multi}).",
             f"- Лемм с ≥ 2 разными текстами «Sub-meaning»: {len(multi)}; на них приходится {res['tagnt_tokens_of_such_lemmas_pct']} % словоупотреблений.",
             f"- Уточнённых номеров с буквой: {res['tagnt_lettered_dstrong_tokens_pct']} % словоупотреблений.",
             f"- MACULA: домен Louw–Nida есть у {res['macula_ln_coverage_pct']} % словоупотреблений; "
             f"лемм {len(lnmap)}, из них с ≥ 2 доменами — {ln_multi}.", '',
             'Примеры лемм с несколькими значениями в TAGNT:', '']
    for l, c in examples.items():
        lines.append(f"- {l}: " + '; '.join(f'{s} ({n})' for s, n in c))
    C.write_report('E_greek_senses', res, '\n'.join(lines) + '\n')


if __name__ == '__main__':
    main()
