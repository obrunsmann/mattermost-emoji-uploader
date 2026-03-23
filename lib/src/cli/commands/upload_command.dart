import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/asset_fetcher.dart';
import '../../core/emoji_source_parser.dart';
import '../../core/mattermost_client.dart';
import '../../core/models.dart';
import '../../core/profile_store.dart';
import '../../core/rate_limiter.dart';
import '../../core/run_logger.dart';
import '../../core/state_store.dart';
import '../../core/upload_service.dart';
import '../support.dart';

class UploadCommand extends Command<int> {
  UploadCommand() {
    argParser
      ..addOption(
        'source',
        abbr: 's',
        help: 'YAML source file with emojis list.',
      )
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
        'concurrency',
        defaultsTo: '2',
        help: 'Number of parallel workers.',
      )
      ..addOption(
        'retries',
        defaultsTo: '6',
        help: 'Maximum attempts per emoji item.',
      )
      ..addFlag(
        'resume',
        defaultsTo: true,
        negatable: true,
        help: 'Resume latest run for this source file.',
      )
      ..addOption(
        'run-id',
        help: 'Explicit run id to resume. Overrides --resume lookup.',
      )
      ..addOption(
        'dedupe',
        defaultsTo: 'first',
        allowed: const <String>['first', 'last', 'error'],
        help: 'Duplicate handling in source file.',
      )
      ..addFlag(
        'skip-existing',
        defaultsTo: true,
        negatable: true,
        help: 'Skip emoji if it already exists on server.',
      )
      ..addFlag(
        'debug',
        defaultsTo: false,
        negatable: false,
        help: 'Enable verbose debug output.',
      );
  }

  @override
  String get name => 'upload';

  @override
  String get description =>
      'Upload emojis with retries, rate-limiting and persistent tracking.';

  @override
  Future<int> run() async {
    final sourceArg = argResults?['source'] as String?;
    if (sourceArg == null || sourceArg.trim().isEmpty) {
      throw UsageException('Missing required option: --source', usage);
    }

    final sourcePath = p.normalize(p.absolute(sourceArg));
    final debug = argResults?['debug'] as bool? ?? false;
    final concurrency = _parsePositiveInt(
      argResults?['concurrency'] as String?,
      optionName: 'concurrency',
    );
    final retries = _parsePositiveInt(
      argResults?['retries'] as String?,
      optionName: 'retries',
    );
    final rate = _parsePositiveDouble(
      argResults?['rate'] as String?,
      optionName: 'rate',
    );
    final dedupeMode = _parseDedupeMode(argResults?['dedupe'] as String?);
    final skipExisting = argResults?['skip-existing'] as bool? ?? true;
    final resume = argResults?['resume'] as bool? ?? true;
    final explicitRunId = argResults?['run-id'] as String?;

    final auth = await _resolveAuthContext();
    final rootDir = Directory(appRootPath());
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
    }

    final stateStore = StateStore(dbPath: p.join(rootDir.path, 'state.db'));
    RunLogger? logger;
    MattermostClient? client;
    AssetFetcher? assetFetcher;

    try {
      final resolvedRun = _resolveRun(
        stateStore: stateStore,
        sourcePath: sourcePath,
        explicitRunId: explicitRunId,
        resume: resume,
        dedupeMode: dedupeMode,
        options: <String, Object?>{
          'source': sourcePath,
          'rate': rate,
          'concurrency': concurrency,
          'retries': retries,
          'skip_existing': skipExisting,
          'dedupe': dedupeMode.name,
        },
      );

      final runId = resolvedRun.runId;
      final logsDir = Directory(p.join(rootDir.path, 'logs'));
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      logger = RunLogger(
        debugEnabled: debug,
        logFilePath: p.join(logsDir.path, 'run-$runId.jsonl'),
      );

      logger.info(
        'Upload command started',
        context: <String, Object?>{
          'run_id': runId,
          'server': auth.server,
          'user_id': auth.userId,
          'source': sourcePath,
          'resume': resolvedRun.resumed,
          if (auth.selectedTeamId != null)
            'selected_team_id': auth.selectedTeamId,
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
      assetFetcher = AssetFetcher(cacheRootPath: p.join(rootDir.path, 'cache'));

      final uploadService = UploadService(
        stateStore: stateStore,
        client: client,
        assetFetcher: assetFetcher,
        logger: logger,
        maxRetries: retries,
        concurrency: concurrency,
        skipExisting: skipExisting,
      );

      final summary = await uploadService.execute(
        runId: runId,
        creatorId: auth.userId,
      );
      await _writeReport(rootDir: rootDir.path, summary: summary);

      logger.info(
        'Run finished',
        context: <String, Object?>{
          'run_id': summary.runId,
          'total': summary.total,
          'uploaded': summary.uploaded,
          'skipped_existing': summary.skippedExisting,
          'retryable_failed': summary.retryableFailed,
          'permanent_failed': summary.permanentFailed,
        },
      );

      stdout.writeln('Run ${summary.runId} finished.');
      stdout.writeln(
        'total=${summary.total} uploaded=${summary.uploaded} '
        'skipped=${summary.skippedExisting} '
        'retryable_failed=${summary.retryableFailed} '
        'permanent_failed=${summary.permanentFailed}',
      );
      stdout.writeln(
        'Report: ${p.join(rootDir.path, 'reports', 'run-${summary.runId}.json')}',
      );

      final hasFailures =
          summary.retryableFailed > 0 || summary.permanentFailed > 0;
      return hasFailures ? 2 : 0;
    } finally {
      client?.close();
      assetFetcher?.close();
      await logger?.close();
      stateStore.dispose();
    }
  }

  _ResolvedRun _resolveRun({
    required StateStore stateStore,
    required String sourcePath,
    required String? explicitRunId,
    required bool resume,
    required DedupeMode dedupeMode,
    required Map<String, Object?> options,
  }) {
    if (explicitRunId != null && explicitRunId.isNotEmpty) {
      final run = stateStore.getRun(explicitRunId);
      if (run == null) {
        throw UsageException('Run id not found: $explicitRunId', usage);
      }
      if (p.normalize(run.sourcePath) != p.normalize(sourcePath)) {
        throw UsageException(
          'Run $explicitRunId belongs to different source: ${run.sourcePath}',
          usage,
        );
      }
      stateStore.markRunAsRunning(run.runId);
      return _ResolvedRun(runId: run.runId, resumed: true);
    }

    if (resume) {
      final latest = stateStore.findLatestOpenRun(sourcePath: sourcePath);
      if (latest != null) {
        stateStore.markRunAsRunning(latest.runId);
        return _ResolvedRun(runId: latest.runId, resumed: true);
      }
    }

    final specs = parseEmojiSource(
      sourcePath: sourcePath,
      dedupeMode: dedupeMode,
    );
    final runId = stateStore.createRun(
      sourcePath: sourcePath,
      options: options,
    );
    stateStore.seedRunItems(runId, specs);
    return _ResolvedRun(runId: runId, resumed: false);
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
      final password = await _resolvePasswordForUpload();
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
      selectedTeamId: profile.selectedTeamId,
    );
  }

  Future<String> _resolvePasswordForUpload() async {
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

  Future<void> _writeReport({
    required String rootDir,
    required UploadSummary summary,
  }) async {
    final reportDir = Directory(p.join(rootDir, 'reports'));
    if (!await reportDir.exists()) {
      await reportDir.create(recursive: true);
    }
    final file = File(p.join(reportDir.path, 'run-${summary.runId}.json'));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'run_id': summary.runId,
        'total': summary.total,
        'uploaded': summary.uploaded,
        'skipped_existing': summary.skippedExisting,
        'retryable_failed': summary.retryableFailed,
        'permanent_failed': summary.permanentFailed,
        'generated_at': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  int _parsePositiveInt(String? raw, {required String optionName}) {
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null || parsed <= 0) {
      throw UsageException('Invalid --$optionName: $raw', usage);
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

  DedupeMode _parseDedupeMode(String? raw) {
    switch (raw) {
      case 'first':
        return DedupeMode.first;
      case 'last':
        return DedupeMode.last;
      case 'error':
        return DedupeMode.error;
      default:
        throw UsageException('Invalid --dedupe: $raw', usage);
    }
  }
}

class _ResolvedRun {
  const _ResolvedRun({required this.runId, required this.resumed});

  final String runId;
  final bool resumed;
}

class _AuthContext {
  const _AuthContext({
    required this.server,
    required this.token,
    required this.userId,
    this.selectedTeamId,
  });

  final String server;
  final String token;
  final String userId;
  final String? selectedTeamId;
}
