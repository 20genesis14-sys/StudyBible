import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../theme.dart';

/// Экран «Лицензии»: список лицензий проекта и встроенных компонентов
/// без дублей — по одному разу на лицензию, со ссылкой на полный текст.
/// Полные тексты лицензий пакетов доступны через системную страницу
/// Flutter (последний пункт) — она работает офлайн.
class LicensesScreen extends StatelessWidget {
  const LicensesScreen({super.key});

  static const _items = <(String, String)>[
    (
      'SIL Open Font License 1.1',
      'https://openfontlicense.org',
    ),
    (
      'MIT License',
      'https://opensource.org/license/mit',
    ),
    (
      'Apache License 2.0',
      'https://www.apache.org/licenses/LICENSE-2.0',
    ),
    (
      'BSD 3-Clause License',
      'https://opensource.org/license/bsd-3-clause',
    ),
    (
      'SQLite — Public Domain',
      'https://www.sqlite.org/copyright.html',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: p.background,
          appBar: AppBar(
            backgroundColor: p.background,
            title: Text(
              tr('Лицензии', 'Licenses'),
              style: TextStyle(color: p.ink),
            ),
            iconTheme: IconThemeData(color: p.ink),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                    child: Text(
                      tr(
                        'Тексты лицензий открываются в браузере.',
                        'License texts open in the browser.',
                      ),
                      style: TextStyle(fontSize: 13, color: p.muted),
                    ),
                  ),
                  for (final (name, url) in _items)
                    ListTile(
                      title: Text(name, style: TextStyle(color: p.ink)),
                      subtitle: Text(
                        url,
                        style: TextStyle(fontSize: 12, color: p.muted),
                      ),
                      trailing: Icon(
                        Icons.open_in_new,
                        size: 16,
                        color: p.muted,
                      ),
                      onTap: () => launchUrl(Uri.parse(url)),
                    ),
                  const Divider(height: 32),
                  ListTile(
                    leading: Icon(Icons.article_outlined, color: p.muted),
                    title: Text(
                      tr(
                        'Лицензии компонентов приложения',
                        'Application component licenses',
                      ),
                      style: TextStyle(color: p.ink),
                    ),
                    subtitle: Text(
                      tr(
                        'Полные тексты, без интернета',
                        'Full texts, works offline',
                      ),
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: p.muted,
                    ),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: tr('Учебная Библия', 'Study Bible'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
