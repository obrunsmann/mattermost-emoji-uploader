import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

class StateStore {
  StateStore({required this.dbPath}) : _db = sqlite3.open(dbPath) {
    _migrate();
  }

  final String dbPath;
  final Database _db;
  final Random _random = Random.secure();

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS runs (
        run_id TEXT PRIMARY KEY,
        source_path TEXT NOT NULL,
        status TEXT NOT NULL,
        options_json TEXT,
        started_at TEXT NOT NULL,
        ended_at TEXT
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS items (
        run_id TEXT NOT NULL,
        name TEXT NOT NULL,
        src TEXT NOT NULL,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        local_path TEXT,
        content_sha256 TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (run_id, name)
      );
    ''');

    _db.execute('''
      CREATE TABLE IF NOT EXISTS attempts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id TEXT NOT NULL,
        name TEXT NOT NULL,
        attempt_no INTEGER NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        status TEXT NOT NULL,
        http_status INTEGER,
        request_id TEXT,
        error TEXT
      );
    ''');
  }

  String createRun({
    required String sourcePath,
    required Map<String, Object?> options,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final runId =
        'run_${DateTime.now().toUtc().millisecondsSinceEpoch}_${_random.nextInt(1 << 32).toRadixString(16)}';

    _db.execute(
      '''
      INSERT INTO runs (run_id, source_path, status, options_json, started_at)
      VALUES (?, ?, 'running', ?, ?)
      ''',
      <Object?>[runId, sourcePath, jsonEncode(options), now],
    );
    return runId;
  }

  void seedRunItems(String runId, List<EmojiSpec> specs) {
    final now = DateTime.now().toUtc().toIso8601String();
    final stmt = _db.prepare('''
      INSERT OR IGNORE INTO items (
        run_id, name, src, status, attempts, updated_at
      ) VALUES (?, ?, ?, 'planned', 0, ?)
    ''');

    try {
      for (final spec in specs) {
        stmt.execute(<Object?>[runId, spec.name, spec.src, now]);
      }
    } finally {
      stmt.dispose();
    }
  }

  RunRecord? getRun(String runId) {
    final result = _db.select(
      'SELECT run_id, source_path, status FROM runs WHERE run_id = ?',
      <Object?>[runId],
    );
    if (result.isEmpty) {
      return null;
    }
    final row = result.first;
    return RunRecord(
      runId: row['run_id'] as String,
      sourcePath: row['source_path'] as String,
      status: row['status'] as String,
    );
  }

  RunRecord? findLatestOpenRun({required String sourcePath}) {
    final result = _db.select(
      '''
      SELECT run_id, source_path, status
      FROM runs
      WHERE source_path = ?
        AND status IN ('running', 'finished_with_errors')
      ORDER BY started_at DESC
      LIMIT 1
      ''',
      <Object?>[sourcePath],
    );
    if (result.isEmpty) {
      return null;
    }
    final row = result.first;
    return RunRecord(
      runId: row['run_id'] as String,
      sourcePath: row['source_path'] as String,
      status: row['status'] as String,
    );
  }

  void markRunAsRunning(String runId) {
    _db.execute('UPDATE runs SET status = ? WHERE run_id = ?', <Object?>[
      'running',
      runId,
    ]);
  }

  List<UploadItem> loadPendingItems(String runId) {
    final result = _db.select(
      '''
      SELECT run_id, name, src, status, attempts, last_error, local_path, content_sha256
      FROM items
      WHERE run_id = ?
        AND status IN ('planned', 'retryable_failed')
      ORDER BY name ASC
      ''',
      <Object?>[runId],
    );

    return result
        .map(
          (row) => UploadItem(
            runId: row['run_id'] as String,
            name: row['name'] as String,
            src: row['src'] as String,
            status: itemStatusFromDb(row['status'] as String),
            attempts: row['attempts'] as int,
            lastError: row['last_error'] as String?,
            localPath: row['local_path'] as String?,
            contentSha256: row['content_sha256'] as String?,
          ),
        )
        .toList(growable: false);
  }

  void setItemStatus({
    required String runId,
    required String name,
    required ItemStatus status,
    required int attempts,
    String? lastError,
    String? localPath,
    String? contentSha256,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      UPDATE items
      SET status = ?,
          attempts = ?,
          last_error = ?,
          local_path = COALESCE(?, local_path),
          content_sha256 = COALESCE(?, content_sha256),
          updated_at = ?
      WHERE run_id = ? AND name = ?
      ''',
      <Object?>[
        itemStatusToDb(status),
        attempts,
        lastError,
        localPath,
        contentSha256,
        now,
        runId,
        name,
      ],
    );
  }

  int beginAttempt({
    required String runId,
    required String name,
    required int attemptNo,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      INSERT INTO attempts (run_id, name, attempt_no, started_at, status)
      VALUES (?, ?, ?, ?, 'started')
      ''',
      <Object?>[runId, name, attemptNo, now],
    );

    final idResult = _db.select('SELECT last_insert_rowid() AS id');
    return (idResult.first['id'] as int);
  }

  void finishAttempt({
    required int attemptId,
    required String status,
    int? httpStatus,
    String? requestId,
    String? error,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      UPDATE attempts
      SET ended_at = ?,
          status = ?,
          http_status = ?,
          request_id = ?,
          error = ?
      WHERE id = ?
      ''',
      <Object?>[now, status, httpStatus, requestId, error, attemptId],
    );
  }

  UploadSummary summarize(String runId) {
    final totalResult = _db.select(
      'SELECT COUNT(*) AS c FROM items WHERE run_id = ?',
      <Object?>[runId],
    );
    final uploadedResult = _db.select(
      "SELECT COUNT(*) AS c FROM items WHERE run_id = ? AND status = 'uploaded'",
      <Object?>[runId],
    );
    final skippedResult = _db.select(
      "SELECT COUNT(*) AS c FROM items WHERE run_id = ? AND status = 'exists_skipped'",
      <Object?>[runId],
    );
    final retryableResult = _db.select(
      "SELECT COUNT(*) AS c FROM items WHERE run_id = ? AND status = 'retryable_failed'",
      <Object?>[runId],
    );
    final permanentResult = _db.select(
      "SELECT COUNT(*) AS c FROM items WHERE run_id = ? AND status = 'permanent_failed'",
      <Object?>[runId],
    );

    return UploadSummary(
      runId: runId,
      total: totalResult.first['c'] as int,
      uploaded: uploadedResult.first['c'] as int,
      skippedExisting: skippedResult.first['c'] as int,
      retryableFailed: retryableResult.first['c'] as int,
      permanentFailed: permanentResult.first['c'] as int,
    );
  }

  void markRunFinished({required String runId, required bool hasFailures}) {
    final now = DateTime.now().toUtc().toIso8601String();
    final status = hasFailures ? 'finished_with_errors' : 'finished';
    _db.execute(
      '''
      UPDATE runs
      SET status = ?,
          ended_at = ?
      WHERE run_id = ?
      ''',
      <Object?>[status, now, runId],
    );
  }

  void dispose() {
    _db.dispose();
  }
}
