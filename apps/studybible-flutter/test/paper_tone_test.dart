/// Тесты оттенков бумаги светлой темы (DECISIONS 18.10.2026):
/// applyPaperTone меняет только фон/плитку/рамку светлой палитры,
/// тёмные темы не трогает; в настройках по умолчанию — тон 0.
library;

import 'package:flutter/material.dart' show Color;

import 'package:flutter_test/flutter_test.dart';

import 'package:studybible/state.dart';
import 'package:studybible/theme.dart';

void main() {
  group('applyPaperTone', () {
    test('тон 0 равен базовой светлой палитре (все 8 цветов)', () {
      final p = applyPaperTone(Palette.of(AppTheme.light), AppTheme.light, 0);
      expect(p.background, Palette.light.background);
      expect(p.card, Palette.light.card);
      expect(p.edge, Palette.light.edge);
      expect(p.ink, Palette.light.ink);
      expect(p.muted, Palette.light.muted);
      expect(p.accent, Palette.light.accent);
      expect(p.jesus, Palette.light.jesus);
      expect(p.onAccent, Palette.light.onAccent);
    });

    test('тон 1 «Светлая»: фон/плитка/рамка заменены, остальное общее', () {
      final base = Palette.of(AppTheme.light);
      final p = applyPaperTone(base, AppTheme.light, 1);
      expect(p.background, const Color(0xFFF7F4EC));
      expect(p.card, const Color(0xFFFCFBF4));
      expect(p.edge, const Color(0xFFE7E0D2));
      expect(p.ink, base.ink);
      expect(p.muted, base.muted);
      expect(p.accent, base.accent);
      expect(p.jesus, base.jesus);
      expect(p.onAccent, base.onAccent);
    });

    test('тон 2 «Сепия»: фон/плитка/рамка заменены, остальное общее', () {
      final base = Palette.of(AppTheme.light);
      final p = applyPaperTone(base, AppTheme.light, 2);
      expect(p.background, const Color(0xFFEDE3CB));
      expect(p.card, const Color(0xFFF4ECD9));
      expect(p.edge, const Color(0xFFDCD0B4));
      expect(p.ink, base.ink);
      expect(p.muted, base.muted);
      expect(p.accent, base.accent);
      expect(p.jesus, base.jesus);
      expect(p.onAccent, base.onAccent);
    });

    test('тон вне диапазона зажимается в крайний (clamp)', () {
      // Ниже нуля — тон 0; выше последнего — последний тон.
      for (final tone in [-99, -1]) {
        final p = applyPaperTone(
          Palette.of(AppTheme.light),
          AppTheme.light,
          tone,
        );
        expect(p.background, Palette.light.background, reason: 'tone=$tone');
        expect(p.card, Palette.light.card, reason: 'tone=$tone');
        expect(p.edge, Palette.light.edge, reason: 'tone=$tone');
      }
      final last = kPaperTones.length - 1;
      for (final tone in [3, 100]) {
        final p = applyPaperTone(
          Palette.of(AppTheme.light),
          AppTheme.light,
          tone,
        );
        expect(
          p.background,
          kPaperTones[last].background,
          reason: 'tone=$tone',
        );
        expect(p.card, kPaperTones[last].card, reason: 'tone=$tone');
        expect(p.edge, kPaperTones[last].edge, reason: 'tone=$tone');
      }
    });

    test('тёмные темы не меняются ни при каком тоне', () {
      for (final t in [AppTheme.dark, AppTheme.amoled]) {
        for (final tone in [-1, 0, 1, 2, 7]) {
          expect(
            applyPaperTone(Palette.of(t), t, tone),
            same(Palette.of(t)),
            reason: '$t tone=$tone',
          );
        }
      }
    });
  });

  group('buildThemeData', () {
    test('paperTone меняет фон ThemeData только у светлой темы', () {
      expect(
        buildThemeData(AppTheme.light, paperTone: 2).scaffoldBackgroundColor,
        const Color(0xFFEDE3CB),
      );
      // По умолчанию (тон 0) — базовая светлая палитра.
      expect(
        buildThemeData(AppTheme.light).scaffoldBackgroundColor,
        Palette.light.background,
      );
      // Тёмные темы: тон игнорируется.
      expect(
        buildThemeData(AppTheme.dark, paperTone: 2).scaffoldBackgroundColor,
        Palette.dark.background,
      );
      expect(
        buildThemeData(AppTheme.amoled, paperTone: 2).scaffoldBackgroundColor,
        Palette.amoled.background,
      );
    });
  });

  group('Settings.paperTone', () {
    test('по умолчанию — 0 («Классическая»)', () {
      // Конструктор моста не трогает — это делает load().
      expect(Settings().paperTone, 0);
    });
  });
}
