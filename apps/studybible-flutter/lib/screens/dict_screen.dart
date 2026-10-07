/// Экран словарного модуля (ADR 0016, kind=dictionary): список
/// заголовков с поиском по префиксу и карточка статьи.
library;

import 'package:flutter/material.dart';

import '../data.dart';
import '../l10n.dart';
import '../native_bridge.dart' show DictEntryInfo;
import '../native_bridge_stub.dart'
    if (dart.library.html) '../native_bridge_web.dart'
    if (dart.library.io) '../native_bridge_io.dart';
import '../theme.dart';

class DictScreen extends StatefulWidget {
  const DictScreen({super.key, required this.moduleId});

  /// id модуля-словаря (файл найден в каталоге данных).
  final String moduleId;

  @override
  State<DictScreen> createState() => _DictScreenState();
}

class _DictScreenState extends State<DictScreen> {
  final _search = TextEditingController();
  List<DictEntryInfo> _items = const [];
  bool _loading = true;
  String? _path;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _path = modulePathOf(widget.moduleId);
    _load('');
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(String prefix) async {
    final path = _path;
    if (path == null) {
      setState(() => _loading = false);
      return;
    }
    final req = ++_req;
    final list = await bridgeDictEntries(
      path,
      prefix: prefix.trim().toLowerCase(),
      limit: 300,
    );
    if (mounted && req == _req) {
      setState(() {
        _items = list;
        _loading = false;
      });
    }
  }

  Future<void> _open(DictEntryInfo e) async {
    final a = await bridgeDictEntry(_path!, e.ord);
    if (!mounted || a == null) return;
    final p = context.palette;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, c) => ListView(
          controller: c,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          children: [
            Text(
              a.headword,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              a.text,
              style: TextStyle(fontSize: 15, color: p.ink, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(moduleName(widget.moduleId))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              onChanged: _load,
              style: TextStyle(color: p.ink),
              decoration: InputDecoration(
                hintText: tr('Заголовок статьи…', 'Entry headword…'),
                hintStyle: TextStyle(color: p.muted),
                prefixIcon: Icon(Icons.search, color: p.muted, size: 20),
                filled: true,
                fillColor: p.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                ? Center(
                    child: Text(
                      tr('Нет статей', 'No entries'),
                      style: TextStyle(color: p.muted),
                    ),
                  )
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (context, i) {
                      final e = _items[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          e.headword,
                          style: TextStyle(color: p.ink),
                        ),
                        onTap: () => _open(e),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
