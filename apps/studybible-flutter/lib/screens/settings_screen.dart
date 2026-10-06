import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../state.dart';
import '../theme.dart';

/// Настройки прототипа: темы, шрифт, вёрстка, колонка, выбор стиха.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 700;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final p = context.palette;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 760 : double.infinity),
            child: ListView(
              padding: EdgeInsets.all(wide ? 32 : 16),
              children: [
                _section(p, tr('Оформление', 'Appearance')),
                _themePicker(p),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _futureTheme(p, tr('Сепия', 'Sepia'))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _futureTheme(p, tr('Тёплые тона', 'Warm tones')),
                    ),
                  ],
                ),
                _section(p, tr('Язык', 'Language')),
                _card(
                  p,
                  _row(
                    p,
                    tr('Язык интерфейса', 'Interface language'),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'ru', label: Text('Русский')),
                        ButtonSegment(value: 'en', label: Text('English')),
                      ],
                      selected: {settings.lang},
                      onSelectionChanged: (s) =>
                          settings.update(() => settings.lang = s.first),
                    ),
                  ),
                ),
                _section(p, tr('Шрифт', 'Typeface')),
                Card(
                  color: p.card,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: p.edge),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _labeled(
                          p,
                          tr('Шрифт текста', 'Reading font'),
                          SegmentedButton<ReadingFont>(
                            segments: [
                              ButtonSegment(
                                value: ReadingFont.literata,
                                label: Text('Literata'),
                              ),
                              ButtonSegment(
                                value: ReadingFont.gentium,
                                label: Text('Gentium'),
                              ),
                              ButtonSegment(
                                value: ReadingFont.ptSerif,
                                label: Text('PT Serif'),
                              ),
                              ButtonSegment(
                                value: ReadingFont.system,
                                label: Text(tr('Системный', 'System')),
                              ),
                            ],
                            selected: {settings.readingFont},
                            onSelectionChanged: (s) => settings.update(
                              () => settings.readingFont = s.first,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Text(
                              tr('Размер шрифта', 'Font size'),
                              style: TextStyle(color: p.ink),
                            ),
                            const Spacer(),
                            Text(
                              'x${settings.fontScale.toStringAsFixed(2)}',
                              style: TextStyle(color: p.muted, fontSize: 13),
                            ),
                          ],
                        ),
                        Slider(
                          value: settings.fontScale,
                          min: 0.8,
                          max: 1.6,
                          divisions: 8,
                          onChanged: (v) =>
                              settings.update(() => settings.fontScale = v),
                        ),
                        Text(
                          tr(
                            'Блаженны нищие духом, ибо их есть Царство Небесное.',
                            'Blessed are the poor in spirit, for theirs is the kingdom of heaven.',
                          ),
                          style: TextStyle(
                            fontFamily: readingFontFamily(settings.readingFont),
                            fontSize: 17 * settings.fontScale,
                            color: p.ink,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _section(p, tr('Чтение', 'Reading')),
                _card(
                  p,
                  Column(
                    children: [
                      _row(
                        p,
                        tr('Вёрстка текста', 'Text layout'),
                        SegmentedButton<LayoutMode>(
                          segments: [
                            ButtonSegment(
                              value: LayoutMode.paragraphs,
                              label: Text(tr('Абзацы', 'Paragraphs')),
                            ),
                            ButtonSegment(
                              value: LayoutMode.versePerLine,
                              label: Text(tr('По стихам', 'By verse')),
                            ),
                            ButtonSegment(
                              value: LayoutMode.book,
                              label: Text(tr('Книга', 'Book')),
                            ),
                          ],
                          selected: {settings.layoutMode},
                          onSelectionChanged: (s) => settings.update(
                            () => settings.layoutMode = s.first,
                          ),
                        ),
                      ),
                      _row(
                        p,
                        tr(
                          'Ширина колонки (десктоп)',
                          'Column width (desktop)',
                        ),
                        SegmentedButton<ColumnWidth>(
                          segments: [
                            ButtonSegment(
                              value: ColumnWidth.reading,
                              label: Text(tr('Чтение', 'Reading')),
                            ),
                            ButtonSegment(
                              value: ColumnWidth.full,
                              label: Text(tr('Вся ширина', 'Full width')),
                            ),
                          ],
                          selected: {settings.columnWidth},
                          onSelectionChanged: (s) => settings.update(
                            () => settings.columnWidth = s.first,
                          ),
                        ),
                      ),
                      _row(
                        p,
                        tr(
                          'Полные имена книг в сетке',
                          'Full book names in grid',
                        ),
                        Switch(
                          value: settings.bookFullNames,
                          onChanged: (v) => settings.update(
                            () => settings.bookFullNames = v,
                          ),
                        ),
                      ),
                      _row(
                        p,
                        tr(
                          'Выбор стиха при выборе главы',
                          'Verse picker after choosing chapter',
                        ),
                        Switch(
                          value: settings.versePickerEnabled,
                          onChanged: (v) => settings.update(
                            () => settings.versePickerEnabled = v,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _section(p, tr('Основной перевод', 'Default translation')),
                _card(
                  p,
                  // Открывается по умолчанию при запуске приложения
                  // и в новых переходах без явного moduleId.
                  ListenableBuilder(
                    listenable: settings,
                    builder: (context, _) => Column(
                      children: [
                        for (final e in kModules.entries)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.menu_book_outlined,
                              size: 18,
                            ),
                            title: Text(e.value),
                            trailing: e.key == settings.defaultModule
                                ? Icon(Icons.check, color: p.accent, size: 18)
                                : null,
                            onTap: () => settings.update(
                              () => settings.defaultModule = e.key,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _section(
                  p,
                  tr(
                    'Перевод параллельных мест',
                    'Cross-reference translation',
                  ),
                ),
                _card(
                  p,
                  // Тексты стихов в карточках сносок/«°» — из этого
                  // перевода; по умолчанию — из основного.
                  ListenableBuilder(
                    listenable: settings,
                    builder: (context, _) => Column(
                      children: [
                        ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.star_outline,
                            size: 18,
                          ),
                          title: Text(
                            tr(
                              'Как основной перевод',
                              'Same as default translation',
                            ),
                          ),
                          trailing: settings.xrefModule.isEmpty
                              ? Icon(Icons.check, color: p.accent, size: 18)
                              : null,
                          onTap: () => settings.update(
                            () => settings.xrefModule = '',
                          ),
                        ),
                        for (final e in kModules.entries)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.menu_book_outlined,
                              size: 18,
                            ),
                            title: Text(e.value),
                            trailing: e.key == settings.xrefModule
                                ? Icon(Icons.check, color: p.accent, size: 18)
                                : null,
                            onTap: () => settings.update(
                              () => settings.xrefModule = e.key,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _section(p, tr('Прогресс', 'Progress')),
                _card(
                  p,
                  ListenableBuilder(
                    listenable: progress,
                    builder: (context, _) => ListTile(
                      title: Text(
                        tr(
                          'Прочитано глав: ${progress.read.length}',
                          'Chapters read: ${progress.read.length}',
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: progress.read.isEmpty
                            ? null
                            : progress.reset,
                        child: Text(tr('Сбросить', 'Reset')),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    tr(
                      'Учебная Библия · прототип UI · ядро Rust',
                      'Study Bible · UI prototype · Rust core',
                    ),
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _section(Palette p, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 0, 8),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: p.muted,
        letterSpacing: 0.8,
      ),
    ),
  );

  Widget _card(Palette p, Widget child) => Card(
    color: p.card,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: p.edge),
    ),
    child: child,
  );

  Widget _row(Palette p, String label, Widget control) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: _labeled(p, label, control, padding: EdgeInsets.zero),
  );

  /// Подпись + контрол: на узких экранах контрол уходит под подпись
  /// и умещается в горизонтальную прокрутку вместо переполнения.
  Widget _labeled(
    Palette p,
    String label,
    Widget control, {
    EdgeInsets? padding,
  }) {
    final inner = LayoutBuilder(
      builder: (_, c) {
        final narrow = c.maxWidth < 400;
        final ctrl = narrow
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: control,
              )
            : control;
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 14, color: p.ink)),
              const SizedBox(height: 8),
              ctrl,
            ],
          );
        }
        return Row(
          children: [
            Expanded(
              child: Text(label, style: TextStyle(fontSize: 14, color: p.ink)),
            ),
            ctrl,
          ],
        );
      },
    );
    return padding != null ? Padding(padding: padding, child: inner) : inner;
  }

  Widget _themePicker(Palette p) {
    Widget card(AppTheme t, String label) {
      final tp = Palette.of(t);
      final sel = settings.theme == t;
      return Expanded(
        child: GestureDetector(
          onTap: () => settings.update(() => settings.theme = t),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tp.card,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: sel ? p.accent : p.edge,
                width: sel ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: tp.background,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: tp.edge),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Аа',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: tp.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (sel)
                      Icon(Icons.check_circle, size: 14, color: p.accent),
                    if (sel) const SizedBox(width: 4),
                    Text(label, style: TextStyle(fontSize: 12, color: tp.ink)),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        card(AppTheme.light, tr('Светлая', 'Light')),
        const SizedBox(width: 12),
        card(AppTheme.dark, tr('Тёмная', 'Dark')),
        const SizedBox(width: 12),
        card(AppTheme.amoled, 'AMOLED'),
      ],
    );
  }

  Widget _futureTheme(Palette p, String label) => Opacity(
    opacity: 0.45,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.edge),
      ),
      alignment: Alignment.center,
      child: Text(
        '$label · ${tr('скоро', 'soon')}',
        style: TextStyle(fontSize: 12, color: p.muted),
      ),
    ),
  );
}
