import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'models.dart';
import 'run_logger.dart';

enum DedupeMode { first, last, error }

List<EmojiSpec> parseEmojiSource({
  required String sourcePath,
  required DedupeMode dedupeMode,
  RunLogger? logger,
}) {
  final sourceFile = File(sourcePath);
  if (!sourceFile.existsSync()) {
    throw FileSystemException('Source file not found', sourcePath);
  }

  final parsed = loadYaml(sourceFile.readAsStringSync());
  if (parsed is! YamlMap || parsed['emojis'] is! YamlList) {
    throw const FormatException(
      'Invalid source YAML. Expected top-level key "emojis".',
    );
  }

  final emojis = parsed['emojis'] as YamlList;
  final byName = <String, EmojiSpec>{};
  final duplicates = <String, int>{};

  for (final raw in emojis) {
    if (raw is! YamlMap) {
      continue;
    }
    final name = (raw['name'] ?? '').toString().trim();
    final src = (raw['src'] ?? '').toString().trim();
    if (name.isEmpty || src.isEmpty) {
      continue;
    }

    final resolvedSrc = _resolveSrc(sourcePath: sourcePath, src: src);
    final candidate = EmojiSpec(name: name, src: resolvedSrc);

    if (!byName.containsKey(name)) {
      byName[name] = candidate;
      continue;
    }

    duplicates[name] = (duplicates[name] ?? 1) + 1;
    switch (dedupeMode) {
      case DedupeMode.first:
        break;
      case DedupeMode.last:
        byName[name] = candidate;
        break;
      case DedupeMode.error:
        throw FormatException('Duplicate emoji name found: $name');
    }
  }

  if (duplicates.isNotEmpty) {
    logger?.warn(
      'Duplicate emoji names detected in source',
      context: <String, Object?>{
        'duplicates': duplicates,
        'mode': dedupeMode.name,
      },
    );
  }

  return byName.values.toList(growable: false);
}

String _resolveSrc({required String sourcePath, required String src}) {
  final uri = Uri.tryParse(src);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return src;
  }

  final sourceDir = p.dirname(p.normalize(sourcePath));
  if (p.isAbsolute(src)) {
    return p.normalize(src);
  }
  return p.normalize(p.join(sourceDir, src));
}
