//! Инъекция перекрёстных ссылок OpenBible (`cross_references.txt`, CC-BY)
//! в готовый модуль .sb: на каждый стих — спан `x` (caller '+') с топ-N
//! ссылок в аббревиатурах профиля модуля. Координаты источника — 'eng',
//! переводятся в версификацию модуля через `Versification::convert`.
//!
//! Использование:
//!   inject_xrefs <модуль.sb> <cross_references.txt> <ru|en> [top N]

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;

use rusqlite::Connection;
use studybible_core::book::{BookCatalog, BookCode, NameProfile};
use studybible_core::versification::{VerseKey, Versification};
use studybible_store::Module;

const TOP_N: usize = 8;

/// «Gen.1.1» → VerseKey (англ. версификация источника OpenBible).
fn parse_ref(s: &str, cat: &BookCatalog) -> Option<VerseKey> {
    let (book, cv) = s.trim().split_once('.')?;
    let code = cat.by_osis(book)?.code;
    let (c, v) = cv.split_once('.')?;
    Some(VerseKey::new(code, c.parse().ok()?, v.parse().ok()?))
}

/// «Ps.148.4-Ps.148.5» или «Isa.40.28» → пара (начало, конец).
fn parse_to(s: &str, cat: &BookCatalog) -> Option<(VerseKey, VerseKey)> {
    let mut parts = s.trim().splitn(2, '-');
    let a = parse_ref(parts.next()?, cat)?;
    let b = match parts.next() {
        Some(t) => parse_ref(t, cat)?,
        None => a,
    };
    Some((a, b))
}

/// Текст ссылки в аббревиатурах профиля: «Пс 104:30», «Ин 1:1-3»,
/// «Быт 1:26-31», «Ос 4:6 – Ил 2:28» (переход через главу/книгу).
fn fmt_ref(a: VerseKey, b: VerseKey, cat: &BookCatalog, profile: NameProfile) -> String {
    let ab = |k: &VerseKey| cat.by_code(k.book).map(|x| x.abbr(profile)).unwrap_or("");
    if a.book == b.book && a.chapter == b.chapter {
        if a.verse == b.verse {
            format!("{} {}:{}", ab(&a), a.chapter, a.verse)
        } else {
            format!("{} {}:{}-{}", ab(&a), a.chapter, a.verse, b.verse)
        }
    } else if a.book == b.book {
        format!(
            "{} {}:{}-{}:{}",
            ab(&a),
            a.chapter,
            a.verse,
            b.chapter,
            b.verse
        )
    } else {
        format!(
            "{} {}:{} \u{2013} {} {}:{}",
            ab(&a),
            a.chapter,
            a.verse,
            ab(&b),
            b.chapter,
            b.verse
        )
    }
}

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        return Err("inject_xrefs <модуль.sb> <cross_references.txt> <ru|en> [top N]".into());
    }
    let path = Path::new(&args[0]);
    let top: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(TOP_N);
    // Языковой профиль аббревиатур: явный аргумент ru|en,
    // иначе — name_profile модуля.
    let profile_of = |s: &str| match s {
        "ru" | "syn" => Some(NameProfile::Synodal),
        "en" => Some(NameProfile::English),
        _ => None,
    };
    let arg_profile = profile_of(&args[2]);

    let m = Module::open(path).map_err(|e| e.to_string())?;
    let profile = arg_profile
        .or_else(|| profile_of(&m.meta().name_profile))
        .ok_or_else(|| format!("профиль '{}' неизвестен", m.meta().name_profile))?;
    let mod_v = Versification::builtin(&m.meta().versification)
        .ok_or_else(|| format!("нет версификации '{}'", m.meta().versification))?;
    let eng_v = Versification::builtin("eng").unwrap();
    let cat = BookCatalog::builtin();
    let in_module: BTreeSet<String> = m
        .books()
        .map_err(|e| e.to_string())?
        .iter()
        .map(|(c, _)| c.as_str().to_string())
        .collect();

    // Ссылки из файла: from → [(to_start, to_end, votes)].
    let text = std::fs::read_to_string(&args[1]).map_err(|e| format!("{}: {e}", args[1]))?;
    let mut refs: BTreeMap<VerseKey, Vec<(VerseKey, VerseKey, i64)>> = BTreeMap::new();
    for line in text.lines().skip(1) {
        let mut it = line.split('\t');
        let (Some(f), Some(t), Some(v)) = (it.next(), it.next(), it.next()) else {
            continue;
        };
        let (Some(fk), Some((ta, tb)), Ok(votes)) =
            (parse_ref(f, cat), parse_to(t, cat), v.trim().parse())
        else {
            continue;
        };
        refs.entry(fk).or_default().push((ta, tb, votes));
    }

    // Кандидаты на вставку: координаты версификации модуля → текст ссылки.
    let mut xref: HashMap<(BookCode, u16, u16), String> = HashMap::new();
    for (fk, mut lst) in refs {
        lst.sort_by_key(|a| std::cmp::Reverse(a.2));
        let texts: Vec<String> = lst
            .iter()
            .take(top)
            .filter_map(|(ta, tb, _)| {
                // Концы диапазона в версификацию модуля.
                let ca = eng_v.convert(mod_v, *ta).first().copied()?;
                let cb = eng_v.convert(mod_v, *tb).first().copied()?;
                Some(fmt_ref(ca, cb, cat, profile))
            })
            .collect();
        if texts.is_empty() {
            continue;
        }
        for mk in eng_v.convert(mod_v, fk) {
            // Книга цели должна быть в модуле.
            if !in_module.contains(mk.book.as_str()) {
                continue;
            }
            xref.insert((mk.book, mk.chapter, mk.verse), texts.join("; "));
        }
    }

    // Модуль открыт read-only — пишем отдельным соединением.
    let mut conn = Connection::open(path).map_err(|e| format!("{e}"))?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    // Код → book_id (схема 1.1: в spans числовой book_id, а не код).
    let book_ids: HashMap<String, i64> = {
        let mut st = tx
            .prepare("SELECT code, book_id FROM books")
            .map_err(|e| e.to_string())?;
        st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<_>>()
            .map_err(|e| e.to_string())?
    };
    // ADR 0022: в упакованном модуле `t`-спаны лежат в `span_pack` —
    // позиции ищем по расшифрованным элементам блока, а вставку делаем
    // перенумерацией блока.
    let has_pack: bool = tx
        .query_row(
            "SELECT count(*) FROM (SELECT 1 FROM span_pack LIMIT 1)",
            [],
            |r| r.get::<_, i64>(0),
        )
        .map(|n| n > 0)
        .unwrap_or(false);
    let mut n_ins = 0u64;
    for ((book, ch, v), txt) in &xref {
        let Some(&bid) = book_ids.get(book.as_str()) else {
            continue;
        };
        if has_pack {
            n_ins += inject_packed(&tx, bid, *ch, *v, txt)? as u64;
            continue;
        }
        // Первый спан стиха: у непустых стихов спаны несут verse=?, у
        // пустых — единственная строка kind='v' с num=? (verse NULL).
        let (block, vseq): (i64, i64) = match tx.query_row(
            "SELECT block, seq FROM spans
             WHERE book_id=?1 AND chapter=?2
               AND (verse=?3 OR (kind='v' AND num=?3))
             ORDER BY block, seq LIMIT 1",
            rusqlite::params![bid, ch, v],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ) {
            Ok(x) => x,
            Err(_) => continue,
        };
        // Граница вставки — перед первым спаном следующего стиха в этом
        // же блоке или в конец блока.
        let next_vseq: Option<i64> = tx
            .query_row(
                "SELECT MIN(seq) FROM spans
                 WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq>?4
                   AND (verse>?5 OR (kind='v' AND num>?5))",
                rusqlite::params![bid, ch, block, vseq, v],
                |r| r.get(0),
            )
            .map_err(|e| e.to_string())?;
        let at: i64 = next_vseq.unwrap_or_else(|| {
            tx.query_row(
                "SELECT MAX(seq)+1 FROM spans WHERE book_id=?1 AND chapter=?2 AND block=?3",
                rusqlite::params![bid, ch, block],
                |r| r.get(0),
            )
            .unwrap_or(vseq + 1)
        });
        // Сдвиг seq двумя фазами: PK-конфликт, если трогать +1 напрямую.
        tx.execute(
            "UPDATE spans SET seq=seq+1000000 WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq>=?4",
            rusqlite::params![bid, ch, block, at],
        )
        .and_then(|_| {
            tx.execute(
                "UPDATE spans SET seq=seq-999999 WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq>=?4+1000000",
                rusqlite::params![bid, ch, block, at],
            )
        })
        .map_err(|e| e.to_string())?;
        // verse=NULL: позиция задаётся seq, иначе после v-маркера пустого
        // стиха читатель синтезировал бы второй маркер того же стиха.
        tx.execute(
            "INSERT INTO spans (book_id,chapter,block,seq,kind,num,verse,start,len,style,attrs,caller,text) \
             VALUES (?1,?2,?3,?4,'x',NULL,NULL,NULL,NULL,'','','+',?5)",
            rusqlite::params![bid, ch, block, at, txt],
        )
        .map_err(|e| e.to_string())?;
        n_ins += 1;
    }
    tx.commit().map_err(|e| e.to_string())?;
    // Ссылки — часть потока чтения: content_hash обязан их покрывать
    // (spec/05 С-12). Пересчитываем по читаемому потоку и пишем в meta.
    let hash = m.compute_content_hash().map_err(|e| e.to_string())?;
    conn.execute(
        "UPDATE meta SET value=?1 WHERE key='content_hash'",
        rusqlite::params![hash],
    )
    .map_err(|e| e.to_string())?;
    println!(
        "{}: вставлено {n_ins} ссылок-x (top {top}), хэш пересчитан",
        m.meta().id
    );
    Ok(())
}

/// Элемент потока блока упакованного модуля (ADR 0022): строка `spans`
/// либо `t`-спан из блоба `span_pack`.
enum PackedItem {
    /// Построчный спан (f/x/v/…) — обновляем seq по старому ключу.
    Row { seq: i64 },
    /// `t`-спан — уходит обратно в переписанный блоб.
    T(studybible_store::pack::PackedSpan),
}

impl PackedItem {
    /// Привязка к стиху: `verse` у t/f/x, `num` у маркера `v`.
    fn verse_key(&self, row_verse: Option<i64>, row_num: Option<i64>) -> Option<i64> {
        match self {
            PackedItem::T(t) => t.verse.map(i64::from),
            _ => row_verse.or(row_num),
        }
    }
}

/// Вставка `x` в упакованный модуль: элементы блока сливаются по `seq`,
/// `x` встаёт перед первым элементом следующего стиха, затем весь блок
/// перенумеровывается и `span_pack` переписывается. Возвращает 1/0.
fn inject_packed(
    tx: &rusqlite::Transaction,
    bid: i64,
    ch: u16,
    v: u16,
    txt: &str,
) -> Result<u32, String> {
    let blocks: Vec<i64> = {
        let mut st = tx
            .prepare("SELECT seq FROM blocks WHERE book_id=?1 AND chapter=?2 ORDER BY seq")
            .map_err(|e| e.to_string())?;
        st.query_map(rusqlite::params![bid, ch], |r| r.get(0))
            .map_err(|e| e.to_string())?
            .collect::<rusqlite::Result<_>>()
            .map_err(|e| e.to_string())?
    };
    for block in blocks {
        // Собираем элементы блока: построчные спаны + t из блоба.
        let mut items: Vec<(PackedItem, Option<i64>, Option<i64>)> = Vec::new();
        {
            let mut st = tx
                .prepare(
                    "SELECT seq, kind, num, verse FROM spans
                     WHERE book_id=?1 AND chapter=?2 AND block=?3",
                )
                .map_err(|e| e.to_string())?;
            let rows = st
                .query_map(rusqlite::params![bid, ch, block], |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, Option<i64>>(2)?,
                        r.get::<_, Option<i64>>(3)?,
                    ))
                })
                .map_err(|e| e.to_string())?;
            for r in rows {
                let (seq, _kind, num, verse) = r.map_err(|e| e.to_string())?;
                items.push((PackedItem::Row { seq }, verse, num));
            }
        }
        let blob: Option<Vec<u8>> = tx
            .query_row(
                "SELECT blob FROM span_pack WHERE book_id=?1 AND chapter=?2 AND block=?3",
                rusqlite::params![bid, ch, block],
                |r| r.get(0),
            )
            .ok();
        if let Some(blob) = blob {
            for e in studybible_store::pack::decode_spans(&blob).map_err(|e| e.to_string())? {
                items.push((PackedItem::T(e), None, None));
            }
        }
        items.sort_by_key(|(it, _, _)| match it {
            PackedItem::Row { seq } => *seq,
            PackedItem::T(t) => i64::from(t.seq),
        });
        // Блок содержит стих?
        if !items
            .iter()
            .any(|(it, rv, rn)| it.verse_key(*rv, *rn) == Some(i64::from(v)))
        {
            continue;
        }
        // Позиция — перед первым элементом следующего стиха.
        let at = items
            .iter()
            .position(|(it, rv, rn)| it.verse_key(*rv, *rn).is_some_and(|k| k > i64::from(v)))
            .unwrap_or(items.len());
        items.insert(
            at,
            (
                PackedItem::Row { seq: -1 }, // новая строка x
                None,
                None,
            ),
        );
        // Перенумеровываем и переписываем: строки — UPDATE по старому
        // seq (с фазой-сдвигом от PK-конфликтов), t — новый блоб.
        tx.execute(
            "UPDATE spans SET seq=seq+1000000
             WHERE book_id=?1 AND chapter=?2 AND block=?3",
            rusqlite::params![bid, ch, block],
        )
        .map_err(|e| e.to_string())?;
        let mut pack: Vec<studybible_store::pack::PackedSpan> = Vec::new();
        for (new_seq, (it, _rv, _rn)) in items.iter().enumerate() {
            match it {
                PackedItem::Row { seq: -1 } => {
                    tx.execute(
                        "INSERT INTO spans (book_id,chapter,block,seq,kind,num,verse,start,len,style,attrs,caller,text) \
                         VALUES (?1,?2,?3,?4,'x',NULL,NULL,NULL,NULL,'','','+',?5)",
                        rusqlite::params![bid, ch, block, new_seq as i64, txt],
                    )
                    .map_err(|e| e.to_string())?;
                }
                PackedItem::Row { seq: old } => {
                    tx.execute(
                        "UPDATE spans SET seq=?5
                         WHERE book_id=?1 AND chapter=?2 AND block=?3 AND seq=?4+1000000",
                        rusqlite::params![bid, ch, block, old, new_seq as i64],
                    )
                    .map_err(|e| e.to_string())?;
                }
                PackedItem::T(t) => {
                    let mut t = t.clone();
                    t.seq = new_seq as u16;
                    pack.push(t);
                }
            }
        }
        if pack.is_empty() {
            tx.execute(
                "DELETE FROM span_pack WHERE book_id=?1 AND chapter=?2 AND block=?3",
                rusqlite::params![bid, ch, block],
            )
            .map_err(|e| e.to_string())?;
        } else {
            tx.execute(
                "INSERT OR REPLACE INTO span_pack VALUES(?1,?2,?3,?4)",
                rusqlite::params![bid, ch, block, studybible_store::pack::encode_spans(&pack)],
            )
            .map_err(|e| e.to_string())?;
        }
        return Ok(1);
    }
    Ok(0)
}
