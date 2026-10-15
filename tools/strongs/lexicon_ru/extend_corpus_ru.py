"""Расширение corpus-ru: добор статистики для ключей без ru-определений.

build_ru_layers.py собирает corpus-приоры только из head-ссылок conf>=9.
Ключи, живущие в ссылках conf=7..8 (редкие/менее уверенные слова) или только
в aux-ролях, остаются без corpus-ru статей вообще. Этот пост-билд шаг
добирает для них статистику по head-ссылкам conf>=8 и пишет строки
def_source='corpus-ru' с conf=8 (ниже стандартных 10 — сигнал слабой
эмпирической базы) прямо в собранный strongs-step-ru.sb.

Запускать после build_lexicon_ru.py. Идемпотентно: сначала удаляет
ранее добавленные строки (conf=8), затем пересчитывает.
"""

import collections
import json
import sqlite3
import sys
from pathlib import Path

DATA = Path("D:/StudyBible-data")
REPO = Path("D:/StudyBible")
LEX_SB = DATA / "work" / "strongs" / "lexicon" / "strongs-step-ru.sb"
LAYERS = DATA / "work" / "strongs" / "layers"
MODULES = DATA / "modules"

sys.path.insert(0, str(REPO / "tools" / "strongs" / "pipeline"))
from build_ru_layers import AUX_RU_WORDS, norm_ru, tokenize_module  # noqa: E402

MIN_CONF = 8
ROW_CONF = 8


def missing_ru_keys(db: sqlite3.Connection) -> set[str]:
    """Ключи lex, у которых нет ru-строки lex_def ни на самом ключе, ни на базе."""
    base_of = dict(db.execute("SELECT key, base FROM lex"))
    have_ru = {k for (k,) in db.execute("SELECT DISTINCT key FROM lex_def WHERE lang='ru'")}
    return {k for k, b in base_of.items() if k not in have_ru and (b or "") not in have_ru}


def scan_layer(layer_sb: Path, module_sb: Path, missing: set[str], weight: int) -> dict[str, collections.Counter]:
    """key -> Counter(norm_ru-форма -> вес) по head-ссылкам conf>=MIN_CONF."""
    _meta, verses = tokenize_module(module_sb)
    word_at = {
        (bid, ch, v, i): w
        for (bid, ch, v), (ws, _sp) in verses.items()
        for i, w in enumerate(ws)
    }
    out: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    con = sqlite3.connect(layer_sb)
    for bid, ch, v, widx, strong, conf, flags in con.execute(
        "SELECT book_id, chapter, verse, word, strong, conf, flags FROM links"
    ):
        if conf < MIN_CONF or "head" not in flags:
            continue
        keys = [k for k in strong.split() if k in missing and not k.startswith("H9")]
        if not keys:
            continue
        w = word_at.get((bid, ch, v, widx))
        if not w:
            continue
        wn = norm_ru(w)
        if wn in AUX_RU_WORDS or len(wn) < 2:
            continue
        for k in keys:
            out[k][wn] += weight
    con.close()
    return out


def def_text(modern: collections.Counter, synodal: collections.Counter) -> str:
    parts = []
    if modern:
        parts.append(
            "Современные переводы (RLOB / РОБ): "
            + ", ".join(f"{w} ({c})" for w, c in modern.most_common(6))
            + "."
        )
    if synodal:
        parts.append(
            "Синодальный перевод: "
            + ", ".join(f"{w} ({c})" for w, c in synodal.most_common(6))
            + "."
        )
    return "\n".join(parts)


def main() -> None:
    con = sqlite3.connect(LEX_SB)
    con.execute("DELETE FROM lex_def WHERE def_source='corpus-ru' AND conf=?", (ROW_CONF,))
    missing = missing_ru_keys(con)
    print(f"missing ru-def keys: {len(missing)}")

    modern = scan_layer(LAYERS / "ru_rlob-strongs.sb", MODULES / "ru_rlob.sb", missing, 2)
    for k, ctr in scan_layer(LAYERS / "ru_rob-strongs.sb", MODULES / "ru_rob.sb", missing, 1).items():
        modern.setdefault(k, collections.Counter()).update(ctr)
    syn = scan_layer(LAYERS / "russyn-strongs.sb", MODULES / "russyn.sb", missing, 1)

    got = [k for k in missing if modern.get(k) or syn.get(k)]
    still = [k for k in missing if k not in got]
    print(f"corpus-ru добрано: {len(got)}; всё ещё пусто: {len(still)}")

    con.executemany(
        "INSERT INTO lex_def(key, lang, def, def_source, def_license, conf, flags, review)"
        " VALUES(?, 'ru', ?, 'corpus-ru', 'CC BY-SA 4.0', ?, '', 'auto')",
        [(k, def_text(modern.get(k, collections.Counter()), syn.get(k, collections.Counter())), ROW_CONF) for k in got],
    )
    con.commit()
    con.close()

    print("still-empty sample:", sorted(still)[:15])
    out = DATA / "work" / "strongs" / "lexicon" / "corpus-ru-extended.json"
    out.write_text(
        json.dumps(
            {
                "min_conf": MIN_CONF,
                "row_conf": ROW_CONF,
                "missing_before": len(missing),
                "filled": len(got),
                "still_empty": sorted(still),
            },
            ensure_ascii=False,
            indent=1,
        ),
        encoding="utf-8",
    )
    print("report:", out)


if __name__ == "__main__":
    main()
