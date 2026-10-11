//! Текстовый селектор куска стиха (userdata, схема 4).
//!
//! Привязка частичного выделения — по контенту, а не по позиции:
//! селектор `{exact, pre, post}` переживает обновление модуля и смену
//! движка рендера. Сопоставление идёт по нормализованному тексту
//! (буквы/цифры + схлопнутые пробелы): знаки препинания, надстрочные
//! метки сносок и переносы строк не мешают найти фрагмент.
//!
//! Диапазоны возвращаются в **байтовых** смещениях исходной строки —
//! пересчёт в единицы платформы (UTF-16, графемы) делается на стороне
//! вызова, чтобы ядро не зависело от конкретного представления.

/// Диапазон (начало, конец) в байтовых смещениях `text`.
pub type ByteRange = (usize, usize);

/// Нормализация для сопоставления: оставляем буквы, цифры и пробельные
/// символы (схлопнутые до одного пробела), всё остальное — знаки
/// препинания, метки сносок `°`, надстрочные буквы-выноски — выбрасываем.
/// Возвращает нормализованные символы и карту `нормализованный индекс →
/// (байтовое начало, длина)` в исходной строке.
fn normalized(s: &str) -> (Vec<char>, Vec<(usize, usize)>) {
    let mut chars = Vec::new();
    let mut map = Vec::new();
    let mut prev_ws = true; // пробел в начале не пишем
    for (i, c) in s.char_indices() {
        if c.is_whitespace() {
            if prev_ws {
                continue;
            }
            chars.push(' ');
            map.push((i, c.len_utf8()));
            prev_ws = true;
        } else if c.is_alphanumeric() {
            chars.push(c);
            map.push((i, c.len_utf8()));
            prev_ws = false;
        } else {
            // Знак препинания/служебная метка — пропускаем; пробельное
            // состояние не трогаем (слова не склеиваются сами по себе).
        }
    }
    // Хвостовой пробел не нужен.
    if chars.last() == Some(&' ') {
        chars.pop();
        map.pop();
    }
    (chars, map)
}

/// Все вхождения селектора в `text`: `exact` — дословный фрагмент,
/// `pre`/`post` — контекст до и после (нормализуются так же; пустые
/// не проверяются). Неоднозначность разрешается контекстом; если он
/// не помог, возвращаются все вхождения — красим всё, что совпало.
pub fn find_frag(text: &str, exact: &str, pre: &str, post: &str) -> Vec<ByteRange> {
    let (tchars, tmap) = normalized(text);
    let (echars, _) = normalized(exact);
    let (pchars, _) = normalized(pre);
    let (qchars, _) = normalized(post);
    let n = echars.len();
    if n == 0 || tchars.len() < n {
        return Vec::new();
    }
    let starts_with = |at: usize| tchars[at..at + n] == echars[..];
    let is_ws = |c: char| c == ' ';
    let pre_ok = |at: usize| {
        if pchars.is_empty() {
            return true;
        }
        // Контекст сравниваем вплотную к фрагменту — без разделительных
        // пробелов между ними.
        let mut e = at;
        while e > 0 && is_ws(tchars[e - 1]) {
            e -= 1;
        }
        e >= pchars.len() && tchars[e - pchars.len()..e] == pchars[..]
    };
    let post_ok = |at: usize| {
        if qchars.is_empty() {
            return true;
        }
        let mut s = at + n;
        while s < tchars.len() && is_ws(tchars[s]) {
            s += 1;
        }
        tchars.len() - s >= qchars.len() && tchars[s..s + qchars.len()] == qchars[..]
    };
    let mut out = Vec::new();
    for at in 0..=tchars.len() - n {
        if starts_with(at) && pre_ok(at) && post_ok(at) {
            let lo = tmap[at].0;
            let hi = tmap[at + n - 1].0 + tmap[at + n - 1].1;
            out.push((lo, hi));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sel(t: &str, r: ByteRange) -> &str {
        &t[r.0..r.1]
    }

    #[test]
    fn находит_единственное_вхождение() {
        let t = "И сказал Илия Елисею: останься здесь, ибо Господь посылает меня.";
        let r = find_frag(t, "останься здесь", "", "");
        assert_eq!(r.len(), 1);
        assert_eq!(sel(t, r[0]), "останься здесь");
    }

    #[test]
    fn контекст_различает_повторы() {
        let t = "жив Господь и жива душа твоя, жив Господь!";
        let all = find_frag(t, "жив Господь", "", "");
        assert_eq!(all.len(), 2);
        let first = find_frag(t, "жив Господь", "", "и жива душа");
        assert_eq!(first.len(), 1);
        assert_eq!(sel(t, first[0]), "жив Господь");
    }

    #[test]
    fn препинание_и_метки_не_мешают() {
        let t = "сказал: жив° Господь и жива душа твоя!";
        let r = find_frag(t, "жив Господь", "сказал", "и жива");
        assert_eq!(r.len(), 1);
        assert_eq!(sel(t, r[0]), "жив° Господь");
    }

    #[test]
    fn часть_слова_совпадает() {
        // Выделение с середины слова — норма для частичного выделения.
        let t = "остананься здесь";
        let r = find_frag(t, "нанься", "", "");
        assert_eq!(r.len(), 1);
        assert_eq!(sel(t, r[0]), "нанься");
    }

    #[test]
    fn пустой_exact_ничего_не_даёт() {
        assert!(find_frag("текст", "", "a", "b").is_empty());
        assert!(find_frag("", "что-то", "", "").is_empty());
    }
}
