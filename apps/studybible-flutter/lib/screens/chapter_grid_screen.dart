import 'package:flutter/material.dart';

import '../l10n.dart';
import '../data.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'reading_screen.dart';
import '../routes.dart';

/// Сетка глав книги + прогресс чтения (галочка + полоса + «продолжить»).
class ChapterGridScreen extends StatefulWidget {
  const ChapterGridScreen({super.key, required this.bookCode});
  final String bookCode;

  @override
  State<ChapterGridScreen> createState() => _ChapterGridScreenState();
}

class _ChapterGridScreenState extends State<ChapterGridScreen> {
  ModuleDoc? _module;

  @override
  void initState() {
    super.initState();
    loadModule(mainModuleId()).then((m) {
      if (mounted) setState(() => _module = m);
    });
  }

  int get _chapterCount {
    final book = _module?.bookByCode(widget.bookCode);
    return book?.chapters ?? 1;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = appThemeOf(context);
    final wide = MediaQuery.of(context).size.width >= 700;
    // Книга может быть вне каталога 66 (неканонические в модуле).
    final group = kBookGroup[widget.bookCode] ?? BookGroup.other;
    final color = groupColor(group, theme);
    final title =
        _module?.bookByCode(widget.bookCode)?.title ??
        kShortName[widget.bookCode] ??
        widget.bookCode;
    final n = _chapterCount;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            ListenableBuilder(
              listenable: progress,
              builder: (_, _) => Text(
                '${progress.readCount(widget.bookCode)}/$n',
                style: TextStyle(fontSize: 13, color: p.muted),
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: ListenableBuilder(
            listenable: progress,
            builder: (_, _) => LinearProgressIndicator(
              value: n > 0 ? progress.readCount(widget.bookCode) / n : 0,
              minHeight: 3,
              backgroundColor: p.edge,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 1000 : double.infinity),
          child: ListenableBuilder(
            listenable: progress,
            builder: (context, _) => GridView.builder(
              padding: EdgeInsets.all(wide ? 40 : 16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: wide ? 10 : 6,
                mainAxisSpacing: wide ? 12 : 10,
                crossAxisSpacing: wide ? 12 : 10,
              ),
              itemCount: n,
              itemBuilder: (context, i) => _ChapterTile(
                bookCode: widget.bookCode,
                chapter: i + 1,
                groupColor: color,
                onOpen: () => _openChapter(i + 1),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openChapter(int chapter) {
    final verseCount = _module?.verseCount(widget.bookCode, chapter) ?? 0;
    if (settings.versePickerEnabled && verseCount > 0) {
      showModalBottomSheet(
        context: context,
        builder: (ctx) => _VersePicker(
          bookCode: widget.bookCode,
          chapter: chapter,
          verseCount: verseCount,
          onPick: (v) {
            Navigator.pop(ctx);
            _go(chapter, v);
          },
        ),
      );
    } else {
      _go(chapter, null);
    }
  }

  void _go(int chapter, int? verse) => Navigator.of(context).push(
    fastRoute(
      ReadingScreen(bookCode: widget.bookCode, chapter: chapter, verse: verse),
    ),
  );
}

class _ChapterTile extends StatelessWidget {
  final String bookCode;
  final int chapter;
  final Color groupColor;
  final VoidCallback onOpen;

  const _ChapterTile({
    required this.bookCode,
    required this.chapter,
    required this.groupColor,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final read = progress.isRead(bookCode, chapter);
    final current = progress.lastPosition == '$bookCode:$chapter';

    return Material(
      color: p.card,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onOpen,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: current
                  ? p.accent
                  : read
                  ? groupColor
                  : p.edge,
              width: current ? 2 : 1,
            ),
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  '$chapter',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 15,
                    color: p.ink,
                  ),
                ),
              ),
              if (read)
                Positioned(
                  top: 4,
                  left: current ? 4 : null,
                  right: current ? null : 4,
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: groupColor,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      size: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
              if (current)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(Icons.bookmark, size: 16, color: p.accent),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VersePicker extends StatelessWidget {
  final String bookCode;
  final int chapter;
  final int verseCount;
  final ValueChanged<int> onPick;

  const _VersePicker({
    required this.bookCode,
    required this.chapter,
    required this.verseCount,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr(
                '${kShortName[bookCode] ?? bookCode} $chapter — стих',
                '${kShortName[bookCode] ?? bookCode} $chapter — verse',
              ),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: p.ink,
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: GridView.builder(
                shrinkWrap: true,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                ),
                itemCount: verseCount,
                itemBuilder: (context, i) => Material(
                  color: p.card,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onPick(i + 1),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: p.edge),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(fontSize: 13, color: p.ink),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
