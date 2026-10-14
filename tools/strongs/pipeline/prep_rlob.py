"""Фаза 8 (Шаг 1): Предобработка USFM3 ru_rlob (снятие обёрток \\zaln-s / \\zaln-e
и перенос всех номеров x-strong, включая ивритские приставки b:/l:/k:/m:/c:/d:,
в атрибуты \\w ...|strong="..."\\w*) и сборка модуля ru_rlob.sb / ru_rlob.sbz.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import zipfile

REPO = pathlib.Path(__file__).resolve().parents[3]
DATA = pathlib.Path(os.environ.get("STUDYBIBLE_DATA", r"D:\StudyBible-data"))

W_TAG = re.compile(r"\\w\s+([^|\\]+)(?:\|[^\\]*?)?\\w\*")
XSTRONG = re.compile(r'x-strong="([^"]+)"')
NUM_RE = re.compile(r"[HG]\d+[A-Za-z]?")
PREF_MAP = {
    "b": "H9003",
    "l": "H9005",
    "k": "H9004",
    "m": "H9006",
    "c": "H9002",
    "d": "H9009",
    "s": "H9007",
}
TOKEN_RE = re.compile(r"(\\zaln-s\s*\|[^\\]*?\\\*|\\zaln-e\\\*|\\w\s+[^\\]*?\\w\*)")


def parse_xstrong(raw: str) -> list[str]:
    out: list[str] = []
    for part in raw.split():
        for sub in part.split(":"):
            sub = sub.strip()
            if sub in PREF_MAP:
                if PREF_MAP[sub] not in out:
                    out.append(PREF_MAP[sub])
            else:
                m = NUM_RE.search(sub)
                if m:
                    code = m.group(0).upper()
                    # Нормализация 5-значных кодов UGNT unfoldingWord (G15100 -> G1510)
                    mg = re.match(r"^G(\d{5})$", code)
                    if mg and int(mg.group(1)) > 5624 and code.endswith("0"):
                        code = f"G{int(mg.group(1)) // 10:04d}"
                    if code not in out:
                        out.append(code)
    return out


def convert_usfm(text: str) -> str:
    parts = TOKEN_RE.split(text)
    stack: list[list[str]] = []
    out: list[str] = []
    for p in parts:
        if p.startswith("\\zaln-s"):
            m = XSTRONG.search(p)
            codes = parse_xstrong(m.group(1)) if m else []
            stack.append(codes)
        elif p.startswith("\\zaln-e"):
            if stack:
                stack.pop()
        elif p.startswith("\\w "):
            mw = W_TAG.match(p)
            word = mw.group(1).strip() if mw else p[3:-3].split("|")[0].strip()
            active: list[str] = []
            for s in stack:
                for c in s:
                    if c not in active:
                        active.append(c)
            if active:
                st_attrs = " ".join(f'strong="{c}"' for c in active)
                out.append(f"\\w {word}|{st_attrs}\\w*")
            else:
                out.append(word)
        else:
            out.append(p)
    return "".join(out)


def main() -> None:
    door_dir = DATA / "sources" / "strongs" / "door43-ru"
    dst_usfm = DATA / "sources" / "ru_rlob"
    dst_usfm.mkdir(parents=True, exist_ok=True)
    for old in dst_usfm.glob("*.usfm"):
        old.unlink()

    with zipfile.ZipFile(door_dir / "ru_rlob.zip") as z:
        count = 0
        for n in sorted(z.namelist()):
            if not n.endswith(".usfm"):
                continue
            raw = z.read(n).decode("utf-8")
            conv = convert_usfm(raw)
            fname = pathlib.Path(n).name
            (dst_usfm / fname).write_text(conv, encoding="utf-8")
            count += 1
        print(f"Converted {count} USFM files into {dst_usfm}")

    defs_file = DATA / "work" / "strongs" / "pipeline" / "ru_rlob_def.json"
    defs_file.parent.mkdir(parents=True, exist_ok=True)
    defs_file.write_text(
        json.dumps(
            {
                "modules": [
                    {
                        "id": "ru_rlob",
                        "source": "ru_rlob",
                        "title": "Русская дословная открытая Библия (RLOB, Стронг)",
                        "language": "ru",
                        "direction": "ltr",
                        "versification": "eng",
                        "name_profile": "syn",
                        "book_order": "syn",
                        "version": "13.0.0",
                        "license": "CC BY-SA 4.0",
                        "attribution": "TextTree / Door43 (ru_rlob v13.0, CC BY-SA 4.0)",
                        "format": "usfm",
                        "sbz": "both",
                    }
                ]
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    cli = REPO / "target" / "debug" / "studybible.exe"
    subprocess.run(
        [
            str(cli),
            "module",
            "build",
            "--defs",
            str(defs_file),
            "--data",
            str(DATA),
            "--out",
            str(DATA / "modules"),
        ],
        check=True,
    )
    subprocess.run([str(cli), "module", "check", str(DATA / "modules" / "ru_rlob.sb")], check=True)


if __name__ == "__main__":
    main()
