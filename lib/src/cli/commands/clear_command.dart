import 'dart:io';
import 'dart:math';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/mattermost_client.dart';
import '../../core/models.dart';
import '../../core/profile_store.dart';
import '../../core/rate_limiter.dart';
import '../../core/run_logger.dart';
import '../support.dart';

class ClearCommand extends Command<int> {
  ClearCommand() {
    argParser
      ..addOption('server', help: 'Mattermost server URL.')
      ..addOption('user', help: 'Login id (used with --password).')
      ..addOption('password', help: 'Password (used with --user).')
      ..addFlag(
        'password-stdin',
        negatable: false,
        help: 'Read password from stdin pipe.',
      )
      ..addOption('token', help: 'Use existing token instead of login.')
      ..addOption('rate', defaultsTo: '4', help: 'Maximum requests per second.')
      ..addOption(
        'retries',
        defaultsTo: '6',
        help: 'Maximum attempts per API operation.',
      )
      ..addOption(
        'page-size',
        defaultsTo: '200',
        help: 'Page size for listing emojis (max 200).',
      )
      ..addFlag(
        'debug',
        defaultsTo: false,
        negatable: false,
        help: 'Enable verbose debug output.',
      )
      ..addFlag(
        'dry-run',
        defaultsTo: false,
        negatable: false,
        help: 'List how many emojis would be deleted without deleting.',
      )
      ..addFlag(
        'yes',
        defaultsTo: false,
        negatable: false,
        help: 'Required safety confirmation to actually delete emojis.',
      );
  }

  @override
  String get name => 'clear';

  @override
  String get description =>
      'Delete all custom emojis from the target Mattermost server.';

  final Random _random = Random.secure();

  @override
  Future<int> run() async {
    final debug = argResults?['debug'] as bool? ?? false;
    final dryRun = argResults?['dry-run'] as bool? ?? false;
    final yes = argResults?['yes'] as bool? ?? false;
    if (!dryRun && !yes) {
      throw UsageException(
        'Refusing destructive action. Re-run with --yes to delete ALL custom emojis.',
        usage,
      );
    }

    final retries = _parsePositiveInt(
      argResults?['retries'] as String?,
      optionName: 'retries',
    );
    final rate = _parsePositiveDouble(
      argResults?['rate'] as String?,
      optionName: 'rate',
    );
    final pageSize = _parsePageSize(
      argResults?['page-size'] as String?,
      optionName: 'page-size',
    );

    final auth = await _resolveAuthContext();
    final rootDir = Directory(appRootPath());
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
    }
    final logsDir = Directory(p.join(rootDir.path, 'logs'));
    if (!await logsDir.exists()) {
      await logsDir.create(recursive: true);
    }

    final runId = 'clear_${DateTime.now().toUtc().millisecondsSinceEpoch}';
    final logger = RunLogger(
      debugEnabled: debug,
      logFilePath: p.join(logsDir.path, '$runId.jsonl'),
    );

    MattermostClient? client;
    try {
      logger.info(
        'Clear command started',
        context: <String, Object?>{
          'server': auth.server,
          'user_id': auth.userId,
          'dry_run': dryRun,
          'retries': retries,
          'rate': rate,
          'page_size': pageSize,
        },
      );

      final limiter = AdaptiveRateLimiter(
        maxRequestsPerSecond: rate,
        logger: logger,
      );
      client = MattermostClient(
        baseUrl: auth.server,
        token: auth.token,
        rateLimiter: limiter,
        logger: logger,
      );

      final emojis = await _listAllCustomEmojis(
        client: client,
        retries: retries,
        pageSize: pageSize,
        logger: logger,
      );

      stdout.writeln('Found ${emojis.length} custom emojis on server.');
      if (emojis.isEmpty) {
        return 0;
      }

      if (dryRun) {
        logger.info('Dry run completed. No emojis deleted.');
        return 0;
      }

      var deleted = 0;
      var alreadyDeleted = 0;
      var failed = 0;
      for (var i = 0; i < emojis.length; i++) {
        final emoji = emojis[i];
        final result = await _deleteEmojiWithRetries(
          client: client,
          emoji: emoji,
          retries: retries,
          logger: logger,
        );

        switch (result) {
          case _DeleteResult.deleted:
            deleted += 1;
          case _DeleteResult.alreadyDeleted:
            alreadyDeleted += 1;
          case _DeleteResult.failed:
            failed += 1;
        }

        stdout.writeln(
          '[${i + 1}/${emojis.length}] ${emoji.name}: ${result.name}',
        );
      }

      logger.info(
        'Clear command finished',
        context: <String, Object?>{
          'total_found': emojis.length,
          'deleted': deleted,
          'already_deleted': alreadyDeleted,
          'failed': failed,
        },
      );
      stdout.writeln(
        'Finished. total=${emojis.length} deleted=$deleted '
        'already_deleted=$alreadyDeleted failed=$failed',
      );
      return failed > 0 ? 2 : 0;
    } finally {
      client?.close();
      await logger.close();
    }
  }

  Future<List<CustomEmoji>> _listAllCustomEmojis({
    required MattermostClient client,
    required int retries,
    required int pageSize,
    required RunLogger logger,
  }) async {
    final emojis = <CustomEmoji>[];
    var page = 0;
    while (true) {
      final batch = await _withRetries<List<CustomEmoji>>(
        retries: retries,
        operationName: 'list-emoji-page-$page',
        logger: logger,
        execute: () =>
            client.listCustomEmojisPage(page: page, perPage: pageSize),
      );
      if (batch.isEmpty) {
        break;
      }
      emojis.addAll(batch);
      if (batch.length < pageSize) {
        break;
      }
      page += 1;
    }
    return emojis;
  }

  Future<_DeleteResult> _deleteEmojiWithRetries({
    required MattermostClient client,
    required CustomEmoji emoji,
    required int retries,
    required RunLogger logger,
  }) async {
    for (var attempt = 1; attempt <= retries; attempt++) {
      try {
        final deleted = await client.deleteCustomEmoji(emoji.id);
        if (deleted) {
          logger.info(
            'Deleted emoji',
            context: <String, Object?>{
              'emoji_id': emoji.id,
              'emoji_name': emoji.name,
              'attempt': attempt,
            },
          );
          return _DeleteResult.deleted;
        }
        logger.warn(
          'Emoji already deleted',
          context: <String, Object?>{
            'emoji_id': emoji.id,
            'emoji_name': emoji.name,
            'attempt': attempt,
          },
        );
        return _DeleteResult.alreadyDeleted;
      } on MattermostApiException catch (error) {
        final shouldRetry = error.retryable && attempt < retries;
        if (!shouldRetry) {
          logger.error(
            'Failed deleting emoji',
            context: <String, Object?>{
              'emoji_id': emoji.id,
              'emoji_name': emoji.name,
              'status_code': error.statusCode,
              'message': error.message,
              'attempt': attempt,
              if (error.requestId != null) 'request_id': error.requestId,
            },
          );
          return _DeleteResult.failed;
        }

        final wait = _backoffDelay(
          attempt: attempt,
          apiSuggestedDelay: error.retryAfter,
        );
        logger.warn(
          'Retryable delete failure, retrying',
          context: <String, Object?>{
            'emoji_id': emoji.id,
            'emoji_name': emoji.name,
            'status_code': error.statusCode,
            'message': error.message,
            'attempt': attempt,
            'wait_ms': wait.inMilliseconds,
          },
        );
        await Future<void>.delayed(wait);
      } catch (error) {
        if (attempt >= retries) {
          logger.error(
            'Unexpected error deleting emoji',
            context: <String, Object?>{
              'emoji_id': emoji.id,
              'emoji_name': emoji.name,
              'error': '$error',
              'attempt': attempt,
            },
          );
          return _DeleteResult.failed;
        }
        final wait = _backoffDelay(attempt: attempt);
        logger.warn(
          'Unexpected delete error, retrying',
          context: <String, Object?>{
            'emoji_id': emoji.id,
            'emoji_name': emoji.name,
            'error': '$error',
            'attempt': attempt,
            'wait_ms': wait.inMilliseconds,
          },
        );
        await Future<void>.delayed(wait);
      }
    }

    return _DeleteResult.failed;
  }

  Future<T> _withRetries<T>({
    required int retries,
    required String operationName,
    required RunLogger logger,
    required Future<T> Function() execute,
  }) async {
    for (var attempt = 1; attempt <= retries; attempt++) {
      try {
        return await execute();
      } on MattermostApiException catch (error) {
        final shouldRetry = error.retryable && attempt < retries;
        if (!shouldRetry) {
          rethrow;
        }
        final wait = _backoffDelay(
          attempt: attempt,
          apiSuggestedDelay: error.retryAfter,
        );
        logger.warn(
          'Retryable API error',
          context: <String, Object?>{
            'operation': operationName,
            'status_code': error.statusCode,
            'message': error.message,
            'attempt': attempt,
            'wait_ms': wait.inMilliseconds,
          },
        );
        await Future<void>.delayed(wait);
      } catch (error) {
        if (attempt >= retries) {
          rethrow;
        }
        final wait = _backoffDelay(attempt: attempt);
        logger.warn(
          'Retryable unexpected error',
          context: <String, Object?>{
            'operation': operationName,
            'error': '$error',
            'attempt': attempt,
            'wait_ms': wait.inMilliseconds,
          },
        );
        await Future<void>.delayed(wait);
      }
    }

    throw StateError('Retries exhausted for operation: $operationName');
  }

  Duration _backoffDelay({required int attempt, Duration? apiSuggestedDelay}) {
    final exponential = Duration(
      milliseconds: min(30000, 500 * (1 << (attempt - 1))),
    );
    final jitter = Duration(milliseconds: _random.nextInt(250));
    final candidate = exponential + jitter;
    if (apiSuggestedDelay != null && apiSuggestedDelay > candidate) {
      return apiSuggestedDelay + jitter;
    }
    return candidate;
  }

  Future<_AuthContext> _resolveAuthContext() async {
    final serverArg = argResults?['server'] as String?;
    final tokenArg = argResults?['token'] as String?;
    final userArg = argResults?['user'] as String?;

    if (serverArg != null &&
        serverArg.isNotEmpty &&
        tokenArg != null &&
        tokenArg.isNotEmpty) {
      final probeClient = MattermostClient(baseUrl: serverArg, token: tokenArg);
      try {
        final userId = await probeClient.getCurrentUserId();
        return _AuthContext(server: serverArg, token: tokenArg, userId: userId);
      } finally {
        probeClient.close();
      }
    }

    if (serverArg != null &&
        serverArg.isNotEmpty &&
        userArg != null &&
        userArg.isNotEmpty) {
      final password = await _resolvePassword();
      final login = await MattermostClient.login(
        baseUrl: serverArg,
        loginId: userArg,
        password: password,
      );
      return _AuthContext(
        server: serverArg,
        token: login.token,
        userId: login.userId,
      );
    }

    final profileStore = ProfileStore(rootDirPath: appRootPath());
    final profile = await profileStore.load();
    if (profile == null) {
      throw UsageException(
        'No profile found. Provide --server/--user/--password or run `mmemoji login`.',
        usage,
      );
    }
    return _AuthContext(
      server: profile.server,
      token: profile.token,
      userId: profile.userId,
    );
  }

  Future<String> _resolvePassword() async {
    final inline = argResults?['password'] as String?;
    if (inline != null && inline.isNotEmpty) {
      return inline;
    }
    final fromStdin = argResults?['password-stdin'] as bool? ?? false;
    if (fromStdin) {
      return readPasswordFromStdinPipe();
    }
    return readPasswordFromStdinPrompt();
  }

  int _parsePositiveInt(String? raw, {required String optionName}) {
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed <= 0) {
      throw UsageException('Invalid --$optionName: $raw', usage);
    }
    return parsed;
  }

  int _parsePageSize(String? raw, {required String optionName}) {
    final parsed = _parsePositiveInt(raw, optionName: optionName);
    if (parsed > 200) {
      throw UsageException('--$optionName must be <= 200', usage);
    }
    return parsed;
  }

  double _parsePositiveDouble(String? raw, {required String optionName}) {
    final parsed = double.tryParse(raw ?? '');
    if (parsed == null || parsed <= 0) {
      throw UsageException('Invalid --$optionName: $raw', usage);
    }
    return parsed;
  }
}

enum _DeleteResult { deleted, alreadyDeleted, failed }

class _AuthContext {
  const _AuthContext({
    required this.server,
    required this.token,
    required this.userId,
  });

  final String server;
  final String token;
  final String userId;
}
