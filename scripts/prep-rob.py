#!/usr/bin/env python3
"""Предобработка USFM ru_rob: снятие \zaln-s/\zaln-e, перенос x-strong на \w."""
import re, sys, pathlib

SRC = pathlib.Path(sys.argv[1])
DST = pathlib.Path.home() / 'work/bible-data/StudyBible-data/sources/ru_rob'
DST.mkdir(parents=True, exist_ok=True)

STRONG = re.compile(r'x-strong="([^"]*)"')
NUM = re.compile(r'[HG]\d+')
MARKER = re.compile(r'[A-Za-z0-9+*]')
WS = ' \n\r\t'

def convert(src):
    n = len(src)
    out = []
    stack = []
    moved = dropped = 0
    i = src.find('\\')
    if i < 0:
        return src, 0, 0
    out.append(src[:i])
    while i < n:
        # i указывает на '\'
        j = i + 1
        while j < n and MARKER.match(src, j):
            j += 1
        marker = src[i + 1:j]
        b = j
        if not marker.endswith('*'):
            if b < n and src[b] in WS:
                b += 1
            if b < n and src[b] == '\n':
                b += 1
        k = src.find('\\', b)
        if k < 0:
            k = n
        body = src[b:k]

        if marker == 'zaln':
            if body.startswith('-s'):
                sm = STRONG.search(body)
                nums = NUM.findall(sm.group(1)) if sm else []
                stack.append(nums[0] if nums else '')
            elif body.startswith('-e'):
                if stack:
                    stack.pop()
            # обёртку сбрасываем
        elif marker == 'w':
            word = body.split('|', 1)[0]
            if stack and stack[-1]:
                out.append('\\w %s|strong="%s"' % (word, stack[-1]))
                moved += 1
            else:
                out.append('\\w %s' % word)
                dropped += 1
        else:
            out.append(src[i:k])
        i = k
    return ''.join(out), moved, dropped

for f in sorted(SRC.glob('*.usfm')):
    conv, moved, dropped = convert(f.read_text(encoding='utf-8'))
    (DST / f.name).write_text(conv, encoding='utf-8')
    print(f'{f.name}: strong→w {moved}, w без стронга {dropped}')
print('готово')
