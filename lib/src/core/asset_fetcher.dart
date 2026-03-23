import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'models.dart';

class DownloadException implements Exception {
  DownloadException({
    required this.message,
    required this.retryable,
    this.httpStatus,
  });

  final String message;
  final bool retryable;
  final int? httpStatus;

  @override
  String toString() => message;
}

class FetchedAsset {
  const FetchedAsset({
    required this.localPath,
    required this.fileName,
    required this.sha256Hex,
    required this.bytes,
  });

  final String localPath;
  final String fileName;
  final String sha256Hex;
  final List<int> bytes;
}

class AssetFetcher {
  AssetFetcher({required this.cacheRootPath, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  final String cacheRootPath;
  final http.Client _httpClient;

  Future<FetchedAsset> fetch({
    required String runId,
    required EmojiSpec spec,
    String? existingLocalPath,
  }) async {
    if (existingLocalPath != null && await File(existingLocalPath).exists()) {
      final bytes = await File(existingLocalPath).readAsBytes();
      return FetchedAsset(
        localPath: existingLocalPath,
        fileName: p.basename(existingLocalPath),
        sha256Hex: sha256.convert(bytes).toString(),
        bytes: bytes,
      );
    }

    if (_isRemote(spec.src)) {
      return _fetchRemote(runId: runId, spec: spec);
    }
    return _fetchLocal(runId: runId, spec: spec);
  }

  Future<FetchedAsset> _fetchLocal({
    required String runId,
    required EmojiSpec spec,
  }) async {
    final file = File(spec.src);
    if (!await file.exists()) {
      throw DownloadException(
        message: 'Local file not found: ${spec.src}',
        retryable: false,
      );
    }

    final bytes = await file.readAsBytes();
    return _persistInCache(
      runId: runId,
      spec: spec,
      bytes: bytes,
      fileName: p.basename(spec.src),
    );
  }

  Future<FetchedAsset> _fetchRemote({
    required String runId,
    required EmojiSpec spec,
  }) async {
    final uri = Uri.parse(spec.src);
    late http.Response response;
    try {
      response = await _httpClient
          .get(uri)
          .timeout(const Duration(seconds: 45));
    } on TimeoutException {
      throw DownloadException(
        message: 'Download timeout: ${spec.src}',
        retryable: true,
      );
    } on SocketException {
      throw DownloadException(
        message: 'Network error downloading: ${spec.src}',
        retryable: true,
      );
    } on http.ClientException catch (error) {
      throw DownloadException(
        message: 'HTTP client error: $error',
        retryable: true,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final fileName = _fileNameFromRemoteSource(spec.src, spec.name);
      return _persistInCache(
        runId: runId,
        spec: spec,
        bytes: response.bodyBytes,
        fileName: fileName,
      );
    }

    throw DownloadException(
      message: 'Download failed with HTTP ${response.statusCode}: ${spec.src}',
      retryable: response.statusCode == 429 || response.statusCode >= 500,
      httpStatus: response.statusCode,
    );
  }

  Future<FetchedAsset> _persistInCache({
    required String runId,
    required EmojiSpec spec,
    required List<int> bytes,
    required String fileName,
  }) async {
    final ext = p.extension(fileName).toLowerCase();
    final safeExt = ext.isEmpty ? '.bin' : ext;
    final cacheDir = Directory(p.join(cacheRootPath, runId));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }

    final normalizedName = _normalizeEmojiName(spec.name);
    final cachePath = p.join(cacheDir.path, '$normalizedName$safeExt');
    await File(cachePath).writeAsBytes(bytes);

    return FetchedAsset(
      localPath: cachePath,
      fileName: p.basename(cachePath),
      sha256Hex: sha256.convert(bytes).toString(),
      bytes: bytes,
    );
  }

  String _normalizeEmojiName(String input) {
    final sanitized = input.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9_]+'),
      '_',
    );
    return sanitized.isEmpty ? base64Url.encode(utf8.encode(input)) : sanitized;
  }

  String _fileNameFromRemoteSource(String src, String fallbackName) {
    final uri = Uri.parse(src);
    final lastSegment = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (lastSegment.isNotEmpty) {
      return lastSegment;
    }
    return '$fallbackName.bin';
  }

  bool _isRemote(String src) {
    final uri = Uri.tryParse(src);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  void close() {
    _httpClient.close();
  }
}
