import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

String appRootPath() => p.join(Directory.current.path, '.mmemoji');

Future<String> readPasswordFromStdinPrompt() async {
  if (!stdin.hasTerminal) {
    throw const FormatException(
      'No interactive terminal available. Use --password-stdin instead.',
    );
  }

  stdout.write('Password: ');
  final previousEchoMode = stdin.echoMode;
  final previousLineMode = stdin.lineMode;

  try {
    stdin.echoMode = false;
    stdin.lineMode = true;

    final password = stdin.readLineSync();
    stdout.writeln();

    if (password == null || password.isEmpty) {
      throw const FormatException('Password must not be empty.');
    }
    return password;
  } finally {
    stdin.echoMode = previousEchoMode;
    stdin.lineMode = previousLineMode;
  }
}

Future<String> readPasswordFromStdinPipe() async {
  final content = await stdin.transform(utf8.decoder).join();
  final password = content.trim();
  if (password.isEmpty) {
    throw const FormatException('Password from stdin is empty.');
  }
  return password;
}
