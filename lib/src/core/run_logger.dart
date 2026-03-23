import 'dart:convert';
import 'dart:io';

class RunLogger {
  RunLogger({required this.debugEnabled, required String logFilePath})
    : _sink = File(logFilePath).openWrite(mode: FileMode.append);

  final bool debugEnabled;
  final IOSink _sink;

  void info(String message, {Map<String, Object?> context = const {}}) {
    _log('INFO', message, context: context);
  }

  void warn(String message, {Map<String, Object?> context = const {}}) {
    _log('WARN', message, context: context);
  }

  void error(String message, {Map<String, Object?> context = const {}}) {
    _log('ERROR', message, context: context, alwaysConsole: true);
  }

  void debug(String message, {Map<String, Object?> context = const {}}) {
    _log('DEBUG', message, context: context, consoleOnlyWhenDebug: true);
  }

  void _log(
    String level,
    String message, {
    required Map<String, Object?> context,
    bool alwaysConsole = false,
    bool consoleOnlyWhenDebug = false,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final payload = <String, Object?>{
      'ts': now,
      'level': level,
      'message': message,
      if (context.isNotEmpty) 'context': context,
    };
    _sink.writeln(jsonEncode(payload));

    if (alwaysConsole || (!consoleOnlyWhenDebug && level != 'DEBUG')) {
      stdout.writeln('[$level] $message');
      if (debugEnabled && context.isNotEmpty) {
        stdout.writeln('        ${jsonEncode(context)}');
      }
      return;
    }

    if (consoleOnlyWhenDebug && debugEnabled) {
      stdout.writeln('[$level] $message');
      if (context.isNotEmpty) {
        stdout.writeln('        ${jsonEncode(context)}');
      }
    }
  }

  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}
