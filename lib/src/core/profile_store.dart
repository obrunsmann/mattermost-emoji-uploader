import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

class ProfileStore {
  ProfileStore({required this.rootDirPath});

  final String rootDirPath;

  String get profilePath => p.join(rootDirPath, 'profile.json');

  Future<void> ensureRootDir() async {
    final dir = Directory(rootDirPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }

  Future<Profile?> load() async {
    final file = File(profilePath);
    if (!await file.exists()) {
      return null;
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Invalid profile format');
    }
    return Profile.fromJson(decoded);
  }

  Future<void> save(Profile profile) async {
    await ensureRootDir();
    final file = File(profilePath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(profile.toJson()),
    );
  }
}
