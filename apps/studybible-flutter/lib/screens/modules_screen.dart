/// Раздел «Модули»: список загруженных модулей текста и словарь Стронга.
///
/// Словарь — Open Scriptures (CC-BY-SA / PD, см. lib/lexicon.dart):
/// поиск по номеру («H3117», «G3056»), лемме и определению.
library;

import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../lexicon.dart';
import '../state.dart';
import '../theme.dart';
import 'dict_screen.dart';
import '../import_module_stub.dart'
    if (dart.library.io) '../import_module_io.dart';

class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key, this.pushed = false});

  /// true — экран открыт поверх другого (с главной): нужен AppBar
  /// с кнопкой «назад», иначе вернуться нечем.
  final bool pushed;

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  final _search = TextEditingController();
  Map<String, LexiconEntry> _dict = {};
  List<MapEntry<String, LexiconEntry>> _hits = const [];
  String _expanded = '';

  @override
  void initState() {
    super.initState();
    lexicon().then((d) {
      if (mounted) setState(() => _dict = d);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _runSearch(String q) => setState(() => _hits = lexiconSearch(_dict, q));

  /// Импорт .sb-модуля из файла: копия в каталог модулей + перескан.
  Future<void> _import() async {
    final result = await importSbModule();
    if (!mounted) return;
    if (result == null) return;
    await rescanModules();
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // --- Модули текста ---
        Row(
          children: [
            Expanded(
              child: Text(
                tr('Модули текста', 'Text modules'),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: p.ink,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: Text(tr('Импорт .sb', 'Import .sb')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final e in installedModules.entries)
          Card(
            color: p.card,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: p.edge),
            ),
            child: ListTile(
              leading: Icon(Icons.menu_book_outlined, color: p.accent),
              // Словарный модуль открывает экран словаря (ADR 0016).
              onTap: () async {
                final doc = await loadModule(e.key);
                if (!context.mounted || doc.kind != 'dictionary') return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DictScreen(moduleId: e.key),
                  ),
                );
              },
              title: Text(e.value, style: TextStyle(color: p.ink)),
              subtitle: Text(
                [
                  // ADR 0016: метка из таблицы или из kind/features
                  // уже загруженного документа.
                  ?moduleTag(e.key),
                  'id: ${e.key}',
                ].join('  ·  '),
                style: TextStyle(fontSize: 12, color: p.muted),
              ),
            ),
          ),
        const SizedBox(height: 24),

        // --- Словарь Стронга ---
        Row(
          children: [
            Text(
              tr('Словарь Стронга', "Strong's lexicon"),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              tr('${_dict.length} статей', '${_dict.length} entries'),
              style: TextStyle(fontSize: 12, color: p.muted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          tr(
            'James Strong, 1890/1894 — общественное достояние; сборка Open Scriptures (CC-BY-SA).${lexiconHasRussian ? '\nРусские определения: Ю. А. Цыганков, «Библия для всех», 2005 (локальные данные).' : ''}',
            'James Strong, 1890/1894 — public domain; compiled by Open Scriptures (CC-BY-SA).${lexiconHasRussian ? '\nRussian definitions: Yu. A. Tsygankov, «The Bible for All», 2005 (local data).' : ''}',
          ),
          style: TextStyle(fontSize: 11, color: p.muted, height: 1.35),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _search,
          onChanged: _runSearch,
          style: TextStyle(color: p.ink),
          decoration: InputDecoration(
            hintText: tr(
              'H3117, G3056, лемма или слово…',
              'H3117, G3056, lemma or word…',
            ),
            hintStyle: TextStyle(color: p.muted),
            prefixIcon: Icon(Icons.search, color: p.muted, size: 20),
            filled: true,
            fillColor: p.card,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.edge),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: p.edge),
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (final h in _hits) _entryCard(context, p, h),
      ],
    );
    if (!widget.pushed) return body;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Модули', 'Modules'))),
      body: body,
    );
  }

  Widget _entryCard(
    BuildContext context,
    Palette p,
    MapEntry<String, LexiconEntry> h,
  ) {
    final open = _expanded == h.key;
    final e = h.value;
    return Card(
      color: p.card,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: p.edge),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          _expanded = open ? '' : h.key;
          if (!open) history.touchDict(h.key, e.lemma);
        }),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      h.key,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [
                        e.lemma,
                        e.xlit,
                        e.pron,
                      ].where((s) => s.isNotEmpty).join('  ·  '),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: p.muted,
                  ),
                ],
              ),
              if (!open && e.expl.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    e.expl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: p.muted,
                      height: 1.35,
                    ),
                  ),
                ),
              if (open) ...[
                if (e.pos.isNotEmpty)
                  _line(p, tr('Часть речи', 'Part of speech'), e.pos),
                if (e.defs.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    tr('Определения', 'Definitions'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.muted,
                    ),
                  ),
                  for (final d in e.defs)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '• $d',
                        style: TextStyle(
                          fontSize: 13,
                          color: p.ink,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
                if (e.deriv.isNotEmpty)
                  _line(p, tr('Происхождение', 'Derivation'), e.deriv),
                if (e.expl.isNotEmpty)
                  _line(p, tr('Определение', 'Definition'), e.expl),
                if (e.kjv.isNotEmpty) _line(p, tr('В KJV', 'In KJV'), e.kjv),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(Palette p, String label, String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: p.muted,
          ),
        ),
        Text(text, style: TextStyle(fontSize: 13, color: p.ink, height: 1.35)),
      ],
    ),
  );
}
