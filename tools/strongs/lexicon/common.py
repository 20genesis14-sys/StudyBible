"""Общие загрузчики фазы 2 — лексикон strongs-step (ADR 0025).

Переиспользует парсеры фазы 1 (tools/strongs/measure/common.py):
load_step() читает TAHOT/TAGNT в Word-объекты. Все входы —
STUDYBIBLE_DATA/sources/strongs, результаты — work/strongs/lexicon.
Только стандартная библиотека.
"""
import importlib.util
import json
import os
import sys
from pathlib import Path

# грузим common.py фазы 1 по пути (имя 'common' — наше, self-import иначе)
_spec = importlib.util.spec_from_file_location(
    'meas_common', Path(__file__).resolve().parent.parent / 'measure' / 'common.py')
meas = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(meas)

DATA = meas.DATA
SRC = meas.SRC
STEP = meas.STEP
WORK = DATA / 'work' / 'strongs' / 'lexicon'

BOOKS, USFM, STEPAB, ENGNAME = meas.BOOKS, meas.USFM, meas.STEPAB, meas.ENGNAME
load_step = meas.load_step
classic = meas.classic
norm_classic = meas.norm_classic
is_nt = meas.is_nt
pct = meas.pct


def write_json(name, data):
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / name).write_text(json.dumps(data, ensure_ascii=False, indent=1),
                            encoding='utf-8')


def read_json(name):
    return json.loads((WORK / name).read_text(encoding='utf-8'))
