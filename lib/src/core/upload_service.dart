import 'dart:math';

import 'package:path/path.dart' as p;

import 'asset_fetcher.dart';
import 'async_mutex.dart';
import 'mattermost_client.dart';
import 'models.dart';
import 'run_logger.dart';
import 'state_store.dart';

class UploadService {
  UploadService({
    required this.stateStore,
    required this.client,
    required this.assetFetcher,
    required this.logger,
    required this.maxRetries,
    required this.concurrency,
    required this.skipExisting,
  });

  final StateStore stateStore;
  final MattermostClient client;
  final AssetFetcher assetFetcher;
  final RunLogger logger;
  final int maxRetries;
  final int concurrency;
  final bool skipExisting;
  final Random _random = Random.secure();

  Future<UploadSummary> execute({
    required String runId,
    required String creatorId,
  }) async {
    final items = stateStore.loadPendingItems(runId);
    if (items.isEmpty) {
      logger.info('No pending emojis to upload for run $runId.');
      final summary = stateStore.summarize(runId);
      stateStore.markRunFinished(
        runId: runId,
        hasFailures: summary.retryableFailed > 0 || summary.permanentFailed > 0,
      );
      return summary;
    }

    logger.info(
      'Starting upload run',
      context: <String, Object?>{
        'run_id': runId,
        'pending_items': items.length,
        'concurrency': concurrency,
        'max_retries': maxRetries,
        'skip_existing': skipExisting,
      },
    );

    final mutex = AsyncMutex();
    var index = 0;

    Future<UploadItem?> nextItem() {
      return mutex.protect(() {
        if (index >= items.length) {
          return null;
        }
        final item = items[index];
        index += 1;
        return item;
      });
    }

    final workers = List<Future<void>>.generate(concurrency, (workerIdx) async {
      while (true) {
        final item = await nextItem();
        if (item == null) {
          break;
        }
        await _processItem(
          item: item,
          creatorId: creatorId,
          workerIdx: workerIdx,
        );
      }
    });

    await Future.wait(workers);
    final summary = stateStore.summarize(runId);

    stateStore.markRunFinished(
      runId: runId,
      hasFailures: summary.retryableFailed > 0 || summary.permanentFailed > 0,
    );
    return summary;
  }

  Future<void> _processItem({
    required UploadItem item,
    required String creatorId,
    required int workerIdx,
  }) async {
    logger.debug(
      'Worker picked item',
      context: <String, Object?>{
        'worker': workerIdx,
        'emoji': item.name,
        'src': item.src,
        'attempts_already': item.attempts,
      },
    );

    for (var attempt = item.attempts + 1; attempt <= maxRetries; attempt++) {
      final attemptId = stateStore.beginAttempt(
        runId: item.runId,
        name: item.name,
        attemptNo: attempt,
      );

      try {
        if (skipExisting) {
          final exists = await client.emojiExists(item.name);
          if (exists) {
            stateStore.setItemStatus(
              runId: item.runId,
              name: item.name,
              status: ItemStatus.existsSkipped,
              attempts: attempt,
            );
            stateStore.finishAttempt(
              attemptId: attemptId,
              status: 'exists_skipped',
              httpStatus: 200,
            );
            logger.info('Skipped existing emoji: ${item.name}');
            return;
          }
        }

        final asset = await assetFetcher.fetch(
          runId: item.runId,
          spec: EmojiSpec(name: item.name, src: item.src),
          existingLocalPath: item.localPath,
        );
        stateStore.setItemStatus(
          runId: item.runId,
          name: item.name,
          status: ItemStatus.downloaded,
          attempts: attempt,
          localPath: asset.localPath,
          contentSha256: asset.sha256Hex,
        );

        await client.uploadEmoji(
          name: item.name,
          creatorId: creatorId,
          fileBytes: asset.bytes,
          fileName: p.basename(asset.fileName),
        );

        stateStore.setItemStatus(
          runId: item.runId,
          name: item.name,
          status: ItemStatus.uploaded,
          attempts: attempt,
          localPath: asset.localPath,
          contentSha256: asset.sha256Hex,
        );
        stateStore.finishAttempt(
          attemptId: attemptId,
          status: 'uploaded',
          httpStatus: 201,
        );
        logger.info(
          'Uploaded emoji',
          context: <String, Object?>{'emoji': item.name, 'attempt': attempt},
        );
        return;
      } on MattermostApiException catch (error) {
        final retryable = error.retryable;
        stateStore.finishAttempt(
          attemptId: attemptId,
          status: retryable ? 'retryable_failed' : 'permanent_failed',
          httpStatus: error.statusCode,
          requestId: error.requestId,
          error: error.message,
        );

        if (!retryable) {
          stateStore.setItemStatus(
            runId: item.runId,
            name: item.name,
            status: ItemStatus.permanentFailed,
            attempts: attempt,
            lastError: error.message,
          );
          logger.error(
            'Permanent API failure uploading ${item.name}',
            context: <String, Object?>{
              'status_code': error.statusCode,
              'message': error.message,
              if (error.requestId != null) 'request_id': error.requestId,
            },
          );
          return;
        }

        final wait = _backoffDelay(
          attempt,
          apiSuggestedDelay: error.retryAfter,
        );
        final exhausted = attempt >= maxRetries;
        stateStore.setItemStatus(
          runId: item.runId,
          name: item.name,
          status: ItemStatus.retryableFailed,
          attempts: attempt,
          lastError: error.message,
        );
        logger.warn(
          exhausted
              ? 'Retries exhausted for ${item.name}'
              : 'Retryable API failure for ${item.name}, retrying',
          context: <String, Object?>{
            'attempt': attempt,
            'status_code': error.statusCode,
            'message': error.message,
            'wait_ms': wait.inMilliseconds,
            'max_retries': maxRetries,
          },
        );
        if (exhausted) {
          return;
        }
        await Future<void>.delayed(wait);
      } on DownloadException catch (error) {
        stateStore.finishAttempt(
          attemptId: attemptId,
          status: error.retryable ? 'retryable_failed' : 'permanent_failed',
          httpStatus: error.httpStatus,
          error: error.message,
        );

        if (!error.retryable) {
          stateStore.setItemStatus(
            runId: item.runId,
            name: item.name,
            status: ItemStatus.permanentFailed,
            attempts: attempt,
            lastError: error.message,
          );
          logger.error(
            'Permanent download failure for ${item.name}: ${error.message}',
          );
          return;
        }

        final wait = _backoffDelay(attempt);
        final exhausted = attempt >= maxRetries;
        stateStore.setItemStatus(
          runId: item.runId,
          name: item.name,
          status: ItemStatus.retryableFailed,
          attempts: attempt,
          lastError: error.message,
        );
        logger.warn(
          exhausted
              ? 'Retries exhausted downloading ${item.name}'
              : 'Retryable download failure for ${item.name}, retrying',
          context: <String, Object?>{
            'attempt': attempt,
            'message': error.message,
            'wait_ms': wait.inMilliseconds,
          },
        );
        if (exhausted) {
          return;
        }
        await Future<void>.delayed(wait);
      } catch (error) {
        final message = 'Unexpected error: $error';
        stateStore.finishAttempt(
          attemptId: attemptId,
          status: 'retryable_failed',
          error: message,
        );
        final exhausted = attempt >= maxRetries;
        stateStore.setItemStatus(
          runId: item.runId,
          name: item.name,
          status: ItemStatus.retryableFailed,
          attempts: attempt,
          lastError: message,
        );
        if (exhausted) {
          logger.error(
            'Retries exhausted for unexpected error on ${item.name}',
            context: <String, Object?>{'error': '$error'},
          );
          return;
        }
        final wait = _backoffDelay(attempt);
        logger.warn(
          'Unexpected error on ${item.name}, retrying',
          context: <String, Object?>{
            'attempt': attempt,
            'error': '$error',
            'wait_ms': wait.inMilliseconds,
          },
        );
        await Future<void>.delayed(wait);
      }
    }
  }

  Duration _backoffDelay(int attempt, {Duration? apiSuggestedDelay}) {
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
}
