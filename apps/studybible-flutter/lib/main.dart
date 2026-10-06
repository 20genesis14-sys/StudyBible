import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'state.dart';
import 'theme.dart';
import 'screens/book_grid_screen.dart';
import 'screens/bookmarks_screen.dart';
import 'screens/home_screen.dart';
import 'screens/modules_screen.dart';
import 'screens/plan_screen.dart';
import 'tts_media.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // На вебе отключаем нативное меню правого клика — показываем своё
  // (пункты «Выделить ст. N» / «Заметка к ст. N» в SelectionArea).
  if (kIsWeb) BrowserContextMenu.disableContextMenu();
  // Медиа-сессия чтения вслух (на платформах без audio_service —
  // no-op). Ошибка здесь не должна мешать запуску приложения.
  try {
    await initReadAloud();
  } catch (_) {}
  runApp(const StudyBibleApp());
}

class StudyBibleApp extends StatelessWidget {
  const StudyBibleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'Учебная Библия',
          debugShowCheckedModeBanner: false,
          theme: buildThemeData(settings.theme),
          // Плавная смена темы: все цвета перетекают за ~200 мс
          // (раньше тема переключалась скачком и «дёргалась»).
          // builder оборачивает Navigator — затрагивает и открытые
          // поверх экраны (чтение, поиск, словарь).
          builder: (context, child) => AnimatedTheme(
            data: Theme.of(context),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: child!,
          ),
          home: const HomeShell(),
        );
      },
    );
  }
}

/// Каркас с нижней навигацией (мобильный) / верхней панелью (десктоп).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0; // «Главная» активна по умолчанию

  @override
  void initState() {
    super.initState();
    // Поднять сохранённые настройки и прогресс
    // (userdata.db через мост; на web — no-op).
    settings.load();
    progress.load();
  }

  // Нижняя навигация — вариант А (ADR 0015): настройки уехали
  // на шестерёнку Главной, «График» стал «План», модули — «Библиотека».
  static const _items = [
    (Icons.home_outlined, 'Главная', 'Home'),
    (Icons.menu_book_outlined, 'Библия', 'Bible'),
    (Icons.event_note_outlined, 'План', 'Plan'),
    (Icons.edit_note_outlined, 'Записи', 'Notes'),
    (Icons.library_books_outlined, 'Библиотека', 'Library'),
  ];

  @override
  Widget build(BuildContext context) {
    // Порог шире: на ~800-1000px панель заголовка с кнопками вкладок
    // не влезает по горизонтали — там показываем нижнюю навигацию.
    final wide = MediaQuery.of(context).size.width >= 1150;
    final tabs = [
      const HomeScreen(),
      const BookGridScreen(),
      const PlanScreen(),
      const BookmarksScreen(),
      const ModulesScreen(),
    ];
    return Scaffold(
      appBar: wide
          ? AppBar(
              titleSpacing: 24,
              title: Row(
                children: [
                  Text(
                    tr('Учебная Библия', 'Study Bible'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(width: 40),
                  for (var i = 0; i < _items.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TextButton(
                        onPressed: () => setState(() => _tab = i),
                        child: Text(
                          tr(_items[i].$2, _items[i].$3),
                          style: TextStyle(
                            color: i == _tab
                                ? context.palette.accent
                                : context.palette.muted,
                            fontWeight: i == _tab
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            )
          : null,
      // Edge-to-edge: вкладкам нужен отступ от строки состояния
      // (полноэкранные чтение/словарь идут поверх и остаются иммерсивными).
      // Между разделами — быстрый мягкий переход (~160 мс).
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: KeyedSubtree(key: ValueKey(_tab), child: tabs[_tab]),
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final (icon, ru, en) in _items)
                  NavigationDestination(icon: Icon(icon), label: tr(ru, en)),
              ],
            ),
    );
  }
}
