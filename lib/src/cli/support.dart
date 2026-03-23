import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String appRootPath() => p.join(Directory.current.path, '.mmemoji');

Future<String> readPasswordFromStdinPrompt() async {
  stdout.write('Password: ');
  final password = stdin.readLineSync();
  if (password == null || password.isEmpty) {
    throw const FormatException('Password must not be empty.');
  }
  return password;
}

Future<String> readPasswordFromStdinPipe() async {
  final content = await stdin.transform(utf8.decoder).join();
  final password = content.trim();
  if (password.isEmpty) {
    throw const FormatException('Password from stdin is empty.');
  }
  return password;
}
