"""Применение LLM-батча ru-определений к собранному strongs-step-ru.sb.

Читает артефакт work/strongs/lexicon/llm-batch-ru-out.json вида
{key: {"src": "llm-en2ru"|"llm-gen", "defs": [str, ...]}} и пишет строки
lex_def: conf=8 для переводов en→ru (якорёны на en-дефы), conf=7 для
генерации из структурных полей. review='auto'. Идемпотентно: сначала
удаляет свои строки (def_source llm-en2ru/llm-gen), затем вставляет.

Отсутствие файла артефакта — не ошибка (батч ещё не делался): выходим тихо.
"""

import json
import sqlite3
from pathlib import Path

DATA = Path("D:/StudyBible-data")
LEX_SB = DATA / "work" / "strongs" / "lexicon" / "strongs-step-ru.sb"
BATCH = DATA / "work" / "strongs" / "lexicon" / "llm-batch-ru-out.json"


def main() -> None:
    if not BATCH.exists():
        return
    out = json.loads(BATCH.read_text(encoding="utf-8"))
    con = sqlite3.connect(LEX_SB)
    con.execute("DELETE FROM lex_def WHERE def_source IN ('llm-en2ru','llm-gen')")
    rows = [
        (k, "ru", d, e["src"], "CC BY-SA 4.0", 8 if e["src"] == "llm-en2ru" else 7, "", "auto")
        for k, e in out.items()
        for d in e["defs"]
    ]
    con.executemany("INSERT INTO lex_def VALUES (?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()
    print(f"apply_llm_defs: {len(rows)} строк из {BATCH.name}")


if __name__ == "__main__":
    main()
