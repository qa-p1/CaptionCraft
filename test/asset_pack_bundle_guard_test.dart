import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'optional asset packs are never declared as Flutter bundle assets',
    () async {
      final pubspec = File('pubspec.yaml');
      expect(await pubspec.exists(), isTrue);
      final contents = await pubspec.readAsString();
      final normalizedContents = contents.replaceAll('\\', '/').toLowerCase();

      expect(normalizedContents, isNot(contains('tool/asset_pack_staging')));
      expect(normalizedContents, isNot(contains('tool/asset_pack_dist')));

      final assetEntries = _flutterAssetEntries(contents);
      expect(_forbiddenBundleReason('assets/fonts/licenses/'), isNull);
      expect(
        _forbiddenBundleReason('assets/sfx/'),
        'local downloadable pack directory',
      );
      expect(
        _forbiddenBundleReason('assets/sound-effects/'),
        'local downloadable pack directory',
      );
      for (final entry in assetEntries) {
        expect(
          _forbiddenBundleReason(entry),
          isNull,
          reason: 'Forbidden Flutter asset declaration: $entry',
        );
      }
    },
  );
}

List<String> _flutterAssetEntries(String pubspec) {
  final lines = const LineSplitter().convert(pubspec);
  var insideFlutter = false;
  int? flutterIndent;
  int? assetsIndent;
  final entries = <String>[];

  for (final line in lines) {
    final code = line.split('#').first.trimRight();
    if (code.trim().isEmpty) continue;
    final indent = code.length - code.trimLeft().length;
    final trimmed = code.trim();

    if (!insideFlutter) {
      if (trimmed == 'flutter:') {
        insideFlutter = true;
        flutterIndent = indent;
      }
      continue;
    }

    if (assetsIndent == null) {
      if (indent <= flutterIndent!) {
        insideFlutter = false;
        continue;
      }
      if (trimmed == 'assets:') assetsIndent = indent;
      continue;
    }

    if (indent <= assetsIndent) break;
    if (!trimmed.startsWith('- ')) continue;
    entries.add(_unquote(trimmed.substring(2).trim()));
  }

  return entries;
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith("'") && value.endsWith("'")) ||
          (value.startsWith('"') && value.endsWith('"')))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

String? _forbiddenBundleReason(String value) {
  final path = value.trim().replaceAll('\\', '/').toLowerCase();
  if (path == 'assets' || path == 'assets/') {
    return 'broad assets/ inclusion';
  }
  if (path.contains('tool/asset_pack_staging') ||
      path.contains('tool/asset_pack_dist')) {
    return 'asset-pack build output';
  }
  final segments = path.split('/').where((segment) => segment.isNotEmpty);
  if (segments.any(
    const {
      'background',
      'background-videos',
      'overlay',
      'overlays',
      'sfx',
      'sound-effects',
      'sound_effects',
    }.contains,
  )) {
    return 'local downloadable pack directory';
  }
  if (path.contains('.zip') &&
      (path.contains('*') || path.contains('?') || path.contains('['))) {
    return 'ZIP wildcard';
  }
  return null;
}
