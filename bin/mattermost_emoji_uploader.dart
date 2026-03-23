import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mattermost_emoji_uploader/src/cli/command_runner.dart';

Future<void> main(List<String> arguments) async {
  final runner = EmojiCommandRunner();
  try {
    final exitCode = await runner.run(arguments) ?? 0;
    exit(exitCode);
  } on UsageException catch (error) {
    stderr.writeln(error);
    exit(64);
  } catch (error, stackTrace) {
    stderr.writeln('Fatal error: $error');
    stderr.writeln(stackTrace);
    exit(1);
  }
}
