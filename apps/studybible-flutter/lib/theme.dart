/// Темы и палитра групп книг.
///
/// Три темы прототипа:
///  - [AppTheme.light] — светлая «бумажная»;
///  - [AppTheme.dark]  — тёмная «для глаз» (серый, не чёрный фон — меньше
///    контрастных ореолов при чтении);
///  - [AppTheme.amoled] — чистый чёрный фон для OLED-экранов (экономия
///    заряда; пиксели текста «светятся» на выключенном фоне).
///
/// В архитектуре заложено расширение: сепия и тёплые темы добавляются новым
/// значением enum + набором цветов ниже — больше ничего менять не нужно.
library;

import 'package:flutter/material.dart';

enum AppTheme { light, dark, amoled }

/// Группы книг канона (цветовые акценты сетки).
enum BookGroup {
  torah('Пятикнижие'),
  hist('Исторические'),
  poet('Поэтические'),
  majp('Большие пророки'),
  minp('Малые пророки'),
  gosp('Евангелия'),
  acts('Деяния'),
  paul('Послания Павла'),
  cath('Соборные послания'),
  rev('Откровение'),
  // Книги модуля вне каталога 66 (второканонические и пр.).
  other('Неканонические');

  final String label;
  const BookGroup(this.label);
}

/// Цвета групп: светлая тема — насыщенные (белый текст, контраст >= 4.5:1),
/// тёмная — осветлённые варианты тех же оттенков (читаемо на тёмном фоне).
const Map<BookGroup, int> _groupLight = {
  BookGroup.torah: 0xFF4338CA,
  BookGroup.hist: 0xFF047857,
  BookGroup.poet: 0xFFB45309,
  BookGroup.majp: 0xFF6D28D9,
  BookGroup.minp: 0xFF9F1239,
  BookGroup.gosp: 0xFF1D4ED8,
  BookGroup.acts: 0xFF0E7490,
  BookGroup.paul: 0xFFC2410C,
  BookGroup.cath: 0xFF3F6212,
  BookGroup.rev: 0xFF334155,
  BookGroup.other: 0xFF78716C,
};

const Map<BookGroup, int> _groupDark = {
  BookGroup.torah: 0xFF7C74E4,
  BookGroup.hist: 0xFF2FA583,
  BookGroup.poet: 0xFFD98A34,
  BookGroup.majp: 0xFF9A6BE8,
  BookGroup.minp: 0xFFCE4F72,
  BookGroup.gosp: 0xFF5B83EC,
  BookGroup.acts: 0xFF3CA6BE,
  BookGroup.paul: 0xFFE07B4A,
  BookGroup.cath: 0xFF7C9A3E,
  BookGroup.rev: 0xFF7A8BA3,
  BookGroup.other: 0xFFA8A29E,
};

Color groupColor(BookGroup g, AppTheme t) {
  final c = Color((t == AppTheme.light ? _groupLight : _groupDark)[g]!);
  // ADR 0015: насыщенность плиток сетки снижена на ~18 % — цвета
  // групп остаются различимы, но не кричат над бумагой.
  final h = HSLColor.fromColor(c);
  return h.withSaturation((h.saturation * 0.82).clamp(0.0, 1.0)).toColor();
}

/// Набор цветов темы, которого нет в стандартной ColorScheme.
class Palette {
  final Color background; // фон «бумаги»
  final Color card; // плитки, панели
  final Color edge; // тонкие рамки
  final Color ink; // основной текст
  final Color muted; // вторичный текст
  final Color accent; // акцент UI
  final Color jesus; // слова Иисуса (wj)
  final Color onAccent; // текст на акценте

  const Palette({
    required this.background,
    required this.card,
    required this.edge,
    required this.ink,
    required this.muted,
    required this.accent,
    required this.jesus,
    required this.onAccent,
  });

  /// Светлая «книга и киноварь» (ADR 0015): тёплая бумага с уклоном
  /// в сепию, тёплая тушь, единственный акцент — киноварь.
  static const light = Palette(
    background: Color(0xFFF3EDDE),
    card: Color(0xFFFBF6EA),
    edge: Color(0xFFE3D8C2),
    ink: Color(0xFF2B2520),
    muted: Color(0xFF7C6F5E),
    accent: Color(0xFF9E2A20),
    jesus: Color(0xFF8E2318),
    onAccent: Color(0xFFFAF3E6),
  );

  /// Тёмная «для глаз»: тёплый серый фон, текст не чисто-белый;
  /// киноварь осветлена, чтобы не теряться на тёмном.
  static const dark = Palette(
    background: Color(0xFF232326),
    card: Color(0xFF2E2E33),
    edge: Color(0xFF3F3F46),
    ink: Color(0xFFE8E6E0),
    muted: Color(0xFF9CA0A8),
    accent: Color(0xFFE0705C),
    jesus: Color(0xFFEF6A5A),
    onAccent: Color(0xFF101014),
  );

  /// AMOLED: чистый чёрный — выключенные пиксели.
  static const amoled = Palette(
    background: Color(0xFF000000),
    card: Color(0xFF0D0D0F),
    edge: Color(0xFF26262B),
    ink: Color(0xFFE8E6E0),
    muted: Color(0xFF8E9299),
    accent: Color(0xFFE0705C),
    jesus: Color(0xFFEF6A5A),
    onAccent: Color(0xFF101014),
  );

  /// Интерполяция палитр — нужна AnimatedTheme при плавной смене
  /// темы: цвета «перетекают», а не переключаются скачком.
  Palette lerp(Palette other, double t) => Palette(
    background: Color.lerp(background, other.background, t)!,
    card: Color.lerp(card, other.card, t)!,
    edge: Color.lerp(edge, other.edge, t)!,
    ink: Color.lerp(ink, other.ink, t)!,
    muted: Color.lerp(muted, other.muted, t)!,
    accent: Color.lerp(accent, other.accent, t)!,
    jesus: Color.lerp(jesus, other.jesus, t)!,
    onAccent: Color.lerp(onAccent, other.onAccent, t)!,
  );

  static Palette of(AppTheme t) => switch (t) {
    AppTheme.light => light,
    AppTheme.dark => dark,
    AppTheme.amoled => amoled,
  };
}

/// Набор темы в ThemeData: палитра + текущий AppTheme.
/// Через ThemeExtension виджеты автоматически перестраиваются
/// при смене темы (зависимость через Theme.of).
class AppThemeExtension extends ThemeExtension<AppThemeExtension> {
  final AppTheme appTheme;
  final Palette palette;

  const AppThemeExtension(this.appTheme, this.palette);

  @override
  AppThemeExtension copyWith({AppTheme? appTheme, Palette? palette}) =>
      AppThemeExtension(appTheme ?? this.appTheme, palette ?? this.palette);

  @override
  AppThemeExtension lerp(AppThemeExtension? other, double t) {
    if (other == null) return this;
    return AppThemeExtension(
      t < 0.5 ? appTheme : other.appTheme,
      palette.lerp(other.palette, t),
    );
  }
}

ThemeData buildThemeData(AppTheme t) {
  final p = Palette.of(t);
  return ThemeData(
    useMaterial3: true,
    extensions: [AppThemeExtension(t, p)],
    brightness: t == AppTheme.light ? Brightness.light : Brightness.dark,
    scaffoldBackgroundColor: p.background,
    fontFamily: 'Roboto',
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: t == AppTheme.light ? Brightness.light : Brightness.dark,
      surface: p.card,
      primary: p.accent,
      onSurface: p.ink,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      foregroundColor: p.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.background,
      indicatorColor: p.accent.withValues(alpha: 0.15),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 10, color: p.muted),
      ),
    ),
    dividerColor: p.edge,
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: p.ink),
      bodyMedium: TextStyle(color: p.ink),
      bodySmall: TextStyle(color: p.muted),
      titleLarge: TextStyle(color: p.ink),
      titleMedium: TextStyle(color: p.ink),
      labelSmall: TextStyle(color: p.muted),
    ),
  );
}

/// Доступ к палитре и теме из контекста.
extension PaletteX on BuildContext {
  Palette get palette => Theme.of(this).extension<AppThemeExtension>()!.palette;
}

AppTheme appThemeOf(BuildContext context) =>
    Theme.of(context).extension<AppThemeExtension>()!.appTheme;
