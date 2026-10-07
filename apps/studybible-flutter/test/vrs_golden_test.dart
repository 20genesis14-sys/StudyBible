/// Паритет версификаций Dart↔Rust по всем строкам `.vrs`: эталон
/// `data/tests/vrs_golden.json` генерирует Rust-ядро
/// (`VRS_GOLDEN=write cargo test -p studybible-core --test vrs_golden`),
/// здесь `vrs_parser.dart` по тем же `.vrs` из `data/versification/`
/// обязан воспроизвести идентичные to_org/from_org/convert.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:studybible/vrs_parser.dart';

/// Корень репозитория: тест запускается из apps/studybible-flutter.
final _vrsDir = Directory('../../data/versification');
final _golden = File('../../data/tests/vrs_golden.json');

String _fmt(VerseKey k) => '${k.book} ${k.chapter}:${k.verse}';

/// Развернуть сторону соответствия — зеркало `_expand` порта и
/// `expand()` ядра (нужно только перечислить стихи строки).
List<VerseKey>? _expandSide(String side) {
  final s = side.trim();
  final dash = s.indexOf('-');
  if (dash < 0) {
    final k = VerseKey.parse(s);
    return k == null ? null : [k];
  }
  final start = VerseKey.parse(s.substring(0, dash));
  final digits = StringBuffer();
  for (final c in s.substring(dash + 1).codeUnits) {
    if (c >= 0x30 && c <= 0x39) {
      digits.writeCharCode(c);
    } else {
      break;
    }
  }
  final end = int.tryParse(digits.toString());
  if (start == null || end == null || start.verse > end) return null;
  return [
    for (var v = start.verse; v <= end; v++)
      VerseKey(start.book, start.chapter, v),
  ];
}

void main() {
  final golden = jsonDecode(_golden.readAsStringSync()) as Map<String, dynamic>;
  final vrsJson = golden['vrs'] as Map<String, dynamic>;

  test('файлы эталона и .vrs на месте', () {
    expect(_golden.existsSync(), isTrue, reason: _golden.path);
    expect(vrsJson.keys, ['org', 'eng', 'lxx', 'vul', 'rso', 'rsc']);
    for (final n in vrsJson.keys) {
      expect(File('${_vrsDir.path}/$n.vrs').existsSync(), isTrue, reason: n);
    }
  });

  for (final name in vrsJson.keys) {
    test('$name: to_org/from_org/skipped по всем строкам-соответствиям', () {
      final text = File('${_vrsDir.path}/$name.vrs').readAsStringSync();
      final v = Versification.parse(name, text);
      final exp = vrsJson[name] as Map<String, dynamic>;

      expect(v.skipped, exp['skipped'], reason: 'skipped $name');

      final toOrg = <String, List<String>>{};
      final fromOrg = <String, List<String>>{};
      for (final raw in text.split('\n')) {
        final line = raw.split('#').first.trim();
        final eq = line.indexOf('=');
        if (eq < 0) continue;
        for (final k in _expandSide(line.substring(0, eq)) ?? const []) {
          toOrg[_fmt(k)] = [for (final p in v.toOrg(k)) _fmt(p)];
        }
        for (final k in _expandSide(line.substring(eq + 1)) ?? const []) {
          fromOrg[_fmt(k)] = [for (final p in v.fromOrg(k)) _fmt(p)];
        }
      }

      final expTo = (exp['to_org'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as List).cast<String>()));
      final expFrom = (exp['from_org'] as Map<String, dynamic>)
          .map((k, v) => MapEntry(k, (v as List).cast<String>()));

      // Расхождение показываем первым отличающимся ключом.
      expect(toOrg.keys.toSet(), expTo.keys.toSet(), reason: '$name to_org keys');
      expect(
        fromOrg.keys.toSet(),
        expFrom.keys.toSet(),
        reason: '$name from_org keys',
      );
      for (final e in toOrg.entries) {
        expect(e.value, expTo[e.key], reason: '$name to_org ${e.key}');
      }
      for (final e in fromOrg.entries) {
        expect(e.value, expFrom[e.key], reason: '$name from_org ${e.key}');
      }
    });
  }

  test('cross-конверсии из эталона воспроизводятся', () {
    final loaded = <String, Versification>{};
    for (final name in vrsJson.keys) {
      loaded[name] = Versification.parse(
        name,
        File('${_vrsDir.path}/$name.vrs').readAsStringSync(),
      );
    }
    for (final q in golden['cross'] as List) {
      final from = loaded[q['from'] as String]!;
      final to = loaded[q['to'] as String]!;
      final key = VerseKey.parse(q['key'] as String)!;
      final got = [for (final p in from.convert(to, key)) _fmt(p)];
      expect(
        got,
        (q['result'] as List).cast<String>(),
        reason: '${q['from']}→${q['to']} ${q['key']}',
      );
    }
  });
}
