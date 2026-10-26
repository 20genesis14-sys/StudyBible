//! Производные объекты модуля: индексы и вспомогательные таблицы.
//!
//! Они ускоряют поиск и **не меняют смысл данных**: `content_hash`
//! считается по потоку чтения (spec/05 С-12), поэтому добавление
//! индексов и таблицы `links_extra` не сдвигает привязку слоя к переводу
//! (`target_id`/`target_hash`/`tokenizer` остаются как были).
//!
//! Правило одно и то же для сборщика модулей (`ModuleWriter::finish`)
//! и для `studybible module reindex`: будущие слои быстры сразу, уже
//! собранные догоняются без пересборки из внешних источников.
//!
//! Зачем `links_extra`: индекс по `links.strong` покрывает только
//! **первый** номер в ячейке, а ячейки с несколькими номерами в слоях
//! есть (`russyn-strongs` 1.1 %, `ru_rob-strongs` 2.8 %) и вторые номера
//! там — обычные слова (`H3967`, `G1160`, `G1161`), а не только служебные.
//! Таблица хранит «вторые и последующие» номера отдельными строками,
//! поэтому поиск по ним идёт по индексу, а не сканом.
//!
//! Предусловие быстрого пути: коды Стронга в `links.strong` записаны
//! канонически — 4 знака + необязательная буква (`H0430`, `H1254A`),
//! как и требует ADR 0025. Неканоническая запись (`H430`) индексным
//! диапазоном не находится; для такого слоя вызывающий откатывается на
//! скан (см. `SearchIndex::search_strong_words`), поэтому результаты
//! остаются верными, теряется только скорость.

use rusqlite::{Connection, params};

use crate::module::ModuleError;

/// Вспомогательная таблица «вторые и последующие» номера Стронга ячейки
/// `links.strong` (ADR 0025). Заполняется из `links` — сборщиком или
/// `module reindex`, — поэтому внешние пайплайны её не знают.
pub const LINKS_EXTRA_SCHEMA: &str = "\
CREATE TABLE IF NOT EXISTS links_extra(
    strong TEXT NOT NULL,
    book_id INTEGER NOT NULL,
    chapter INTEGER NOT NULL,
    verse INTEGER NOT NULL,
    word INTEGER NOT NULL);
";

/// Имя индекса по `links.strong` (быстрый путь обратного поиска).
pub const LINKS_STRONG_INDEX: &str = "links_strong";
/// Имя индекса по `links_extra.strong`.
pub const LINKS_EXTRA_INDEX: &str = "links_extra_strong";

/// Создать недостающие производные объекты и вернуть список созданных
/// (для квитанции `module reindex` и логов сборки).
///
/// Идемпотентно: повторный вызов ничего не меняет. Объект считается
/// существующим, если у таблицы уже есть индекс с нужной **первой**
/// колонкой, — имя не важно (у `strongs` такой индекс называется
/// `lex_base_idx`, у `strongs` его не было вовсе).
pub fn ensure_search_indexes(conn: &Connection) -> Result<Vec<String>, ModuleError> {
    let mut created = Vec::new();

    // `links`: индекс по номеру + таблица «вторых» номеров.
    if rows(conn, "links")? > 0 {
        if !has_index_on_first_column(conn, "links", "strong")? {
            conn.execute_batch(&format!(
                "CREATE INDEX IF NOT EXISTS {LINKS_STRONG_INDEX} ON links(strong);"
            ))?;
            created.push(format!("index {LINKS_STRONG_INDEX}(links.strong)"));
        }
        conn.execute_batch(LINKS_EXTRA_SCHEMA)?;
        let filled = fill_links_extra(conn)?;
        if filled > 0 {
            created.push(format!("table links_extra ({filled} строк)"));
        }
        if !has_index_on_first_column(conn, "links_extra", "strong")? {
            conn.execute_batch(&format!(
                "CREATE INDEX IF NOT EXISTS {LINKS_EXTRA_INDEX} ON links_extra(strong);"
            ))?;
            created.push(format!("index {LINKS_EXTRA_INDEX}(links_extra.strong)"));
        }
    }

    // Лексикон: поиск статьи по базовому номеру (`lex.base`) и по
    // таблице `lex_base` — оба пути должны опираться на индекс.
    if rows(conn, "lex")? > 0 && !has_index_on_first_column(conn, "lex", "base")? {
        conn.execute_batch("CREATE INDEX IF NOT EXISTS lex_base_idx ON lex(base);")?;
        created.push("index lex_base_idx(lex.base)".into());
    }
    if rows(conn, "lex_base")? > 0 && !has_index_on_first_column(conn, "lex_base", "base")? {
        conn.execute_batch("CREATE INDEX IF NOT EXISTS lex_base_base ON lex_base(base);")?;
        created.push("index lex_base_base(lex_base.base)".into());
    }
    if rows(conn, "lex_def")? > 0 && !has_index_on_first_column(conn, "lex_def", "key")? {
        conn.execute_batch("CREATE INDEX IF NOT EXISTS lex_def_key ON lex_def(key);")?;
        created.push("index lex_def_key(lex_def.key)".into());
    }

    Ok(created)
}

/// Перезаполнить `links_extra` из `links`: по одной строке на каждый
/// номер, кроме первого в ячейке. Возвращает число строк.
fn fill_links_extra(conn: &Connection) -> Result<i64, ModuleError> {
    conn.execute_batch("DELETE FROM links_extra;")?;
    let mut read = conn.prepare(
        "SELECT book_id, chapter, verse, word, strong FROM links WHERE strong LIKE '% %'",
    )?;
    let rows: Vec<(i64, u16, u16, u16, String)> = read
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })?
        .collect::<Result<_, _>>()?;
    drop(read);
    let mut write = conn.prepare("INSERT INTO links_extra VALUES(?1, ?2, ?3, ?4, ?5)")?;
    let mut n = 0i64;
    for (book_id, chapter, verse, word, cell) in rows {
        for code in cell.split_whitespace().skip(1) {
            write.execute(params![code, book_id, chapter, verse, word])?;
            n += 1;
        }
    }
    Ok(n)
}

/// Число строк в таблице; 0 — таблицы нет.
fn rows(conn: &Connection, table: &str) -> Result<i64, ModuleError> {
    let exists: bool = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
        [table],
        |r| r.get(0),
    )?;
    if !exists {
        return Ok(0);
    }
    Ok(conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))?)
}

/// Есть ли у таблицы индекс (в том числе автоматический) с нужной
/// первой колонкой — то есть подходит ли он для `WHERE col = ?`.
fn has_index_on_first_column(
    conn: &Connection,
    table: &str,
    column: &str,
) -> Result<bool, ModuleError> {
    let mut list = conn.prepare(&format!("PRAGMA index_list({table})"))?;
    let names: Vec<String> = list
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<Result<_, _>>()?;
    drop(list);
    for name in names {
        let mut info = conn.prepare(&format!("PRAGMA index_info({name})"))?;
        let cols: Vec<String> = info
            .query_map([], |r| r.get::<_, String>(2))?
            .collect::<Result<_, _>>()?;
        if cols.first().map(String::as_str) == Some(column) {
            return Ok(true);
        }
    }
    Ok(false)
}
