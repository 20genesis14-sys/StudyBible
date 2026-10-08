# StudyBible — сборка и тестирование Linux-версии (рецепт воспроизведения)

Дата прогона: 2026-10-08.

## 1. Окружение, на котором собиралось и тестировалось

| Компонент | Значение |
|---|---|
| ОС | Ubuntu 22.04.5 LTS (jammy), ядро Linux 6.8.0-1061-aws x86_64 |
| Десктоп | KDE Plasma, X11, дисплей 3200×2400 (Wayland не требуется) |
| glibc | 2.35 |
| Flutter SDK | 3.47.6 (framework rev 5fc346839b, Dart 3.13.5) — тот же, что в проекте |
| Rust | cargo/rustc 1.97.1 (нужен для native_toolchain_rust моста) |
| clang | 14.0.0 (из репозитория Ubuntu) |
| cmake | 3.22.1, ninja 1.10.1, pkg-config 0.29.2 |
| gtk | libgtk-3-dev 3.24.33 |
| gstreamer | libgstreamer1.0-dev 1.20.3, libgstreamer-plugins-base1.0-dev 1.20.1 (нужен audioplayers_linux) |
| прочие dev-пакеты | libblkid-dev 2.37.2, liblzma-dev 5.2.5, libstdc++-12-dev 12.3.0 |
| python3 | 3.10 (для скриптов замеров) |

## 2. Установка зависимостей (Ubuntu/Debian)

```bash
sudo apt-get update
sudo apt-get install -y cmake ninja-build clang pkg-config \
    libgtk-3-dev libblkid-dev liblzma-dev libstdc++-12-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

Также нужны: Flutter SDK 3.47.6 (распаковать, путь в PATH или вызывать напрямую) и установленный Rust toolchain (rustup, stable — у нас 1.97.1): Flutter-команда сама подтянет `native_toolchain_rust` и соберёт `libstudybible_flutter_bridge.so` крейтом.

## 3. Данные

```bash
export STUDYBIBLE_DATA=/path/to/StudyBible-data   # каталог с modules/*.sb и userdata.db
```

Модули лежат в `$STUDYBIBLE_DATA/modules/*.sb` (использовались russyn, -ru, int_en, comm-henry, oshb).

## 4. Сборка

```bash
cd StudyBible/apps/studybible-flutter
STUDYBIBLE_DATA=/path/to/StudyBible-data flutter build linux --release
```

Собранный бинарь: `build/linux/x64/release/intermediates_do_not_run/studybible`.
Стороны:
- `ninja install` в проекте жёстко ставит в `/usr/local` (без выбора префикса). Чтобы не трогать систему — собирайте бандл в каталог:
  ```bash
  cd build/linux/x64/release
  DESTDIR=$HOME/sb_linux ninja install
  # получаем $HOME/sb_linux/usr/local/{studybible, lib/, data/}
  ```

## 5. Запуск

```bash
cd $HOME/sb_linux/usr/local
DISPLAY=:0 STUDYBIBLE_DATA=/path/to/StudyBible-data LD_LIBRARY_PATH=lib ./studybible
```

Рендерер — Impeller (OpenGL ES через GTK). Предупреждения `dbind-WARNING AT-SPI` безобидны (нет a11y-шины).

Для профильных замеров вместо релиза:
```bash
cd StudyBible/apps/studybible-flutter
DISPLAY=:0 STUDYBIBLE_DATA=/path/to/StudyBible-data flutter run -d linux --profile
# в выводе будет "A Dart VM Service ... at: http://127.0.0.1:PORT/<token>/"
```

## 6. Как замерялось

- **Холодный старт**: запуск релизного бинаря, таймер до появления окна (`wmctrl -l`), 3 прогона → 0.64–0.65 с.
- **Кадры при скролле**: profile-режим, подключение к VM Service по WebSocket, подписка на поток `Timeline`, сбор пар b/e событий `Frame` (скрипт `tools/collect_frames.py <ws_url> <sec> <out>`). Скролл — `xdotool click 5/4` по центру окна (~1 клик колеса / 350 мс), всего ~80 событий скролла.
- **Поиск**: поле поиска → «милости» → Enter, время до отрисовки списка результатов.
- **Слабый CPU**: `cpulimit -p <pid> -l 30` (30% одного ядра) — наблюдение за отзывчивостью.
- Управление оконным UI: `wmctrl` (развёртывание), `xdotool` (клики/скролл; реальные координаты = координаты скриншота × 3.125 при дисплее 3200×2400).

## 7. Итоги (дублирует REPORT_linux.md)

| Метрика | Значение | Лимит |
|---|---|---|
| Холодный старт до окна | 0.64–0.65 с | — |
| Чтение Пс 118, скролл | кадр p50 10.0 мс, p90 19.8, max 34.8 (~60 fps) | плавность |
| Подстрочное сравнение (RUSSYN+OSHB) | p50 19.2 мс, p90 33.6, max 64.8 | ~30–50 fps при прыжках |
| Поиск «милости» | мгновенно | ≤200 мс |
| Слабый CPU (30% ядра) | UI теряет отзывчивость, без падений | — |

Все лимиты № 11/№ 22 соблюдены. Подстрочное сравнение — самый тяжёлый вид (та же причина: глава одним Column без виртуализации), на десктопе некритично.
