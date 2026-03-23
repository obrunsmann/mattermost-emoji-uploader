import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'rate_limiter.dart';
import 'run_logger.dart';

class MattermostApiException implements Exception {
  MattermostApiException({
    required this.statusCode,
    required this.message,
    this.requestId,
    this.retryAfter,
  });

  final int statusCode;
  final String message;
  final String? requestId;
  final Duration? retryAfter;

  bool get retryable =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'HTTP $statusCode: $message';
}

class MattermostClient {
  MattermostClient({
    required String baseUrl,
    required String token,
    this.rateLimiter,
    this.logger,
    http.Client? httpClient,
  }) : _baseUri = _normalizeBaseUrl(baseUrl),
       _token = token,
       _httpClient = httpClient ?? http.Client();

  final Uri _baseUri;
  final String _token;
  final AdaptiveRateLimiter? rateLimiter;
  final RunLogger? logger;
  final http.Client _httpClient;

  static Future<LoginResult> login({
    required String baseUrl,
    required String loginId,
    required String password,
  }) async {
    final client = http.Client();
    final uri = _normalizeBaseUrl(baseUrl).resolve('/api/v4/users/login');

    try {
      final response = await client
          .post(
            uri,
            headers: <String, String>{
              HttpHeaders.contentTypeHeader: 'application/json',
            },
            body: jsonEncode(<String, String>{
              'login_id': loginId,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw _toApiException(response);
      }

      final token = response.headers['token'];
      if (token == null || token.isEmpty) {
        throw const FormatException(
          'Login succeeded but response did not include Token header.',
        );
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> || body['id'] is! String) {
        throw const FormatException('Login response did not contain user id.');
      }

      return LoginResult(token: token, userId: body['id'] as String);
    } finally {
      client.close();
    }
  }

  Future<String> getCurrentUserId() async {
    final request = http.Request('GET', _baseUri.resolve('/api/v4/users/me'));
    final response = await _send(request, acceptedStatusCodes: <int>{200});
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['id'] is! String) {
      throw const FormatException('Could not parse current user id.');
    }
    return body['id'] as String;
  }

  Future<List<TeamInfo>> getTeamsForUser(String userId) async {
    final request = http.Request(
      'GET',
      _baseUri.resolve('/api/v4/users/$userId/teams'),
    );
    final response = await _send(request, acceptedStatusCodes: <int>{200});

    final body = jsonDecode(response.body);
    if (body is! List<dynamic>) {
      throw const FormatException('Team response is not a list.');
    }

    return body
        .whereType<Map<String, dynamic>>()
        .map(
          (raw) => TeamInfo(
            id: raw['id'] as String? ?? '',
            name: raw['name'] as String? ?? '',
            displayName: raw['display_name'] as String? ?? '',
          ),
        )
        .where((team) => team.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> emojiExists(String emojiName) async {
    final request = http.Request(
      'GET',
      _baseUri.resolve('/api/v4/emoji/name/${Uri.encodeComponent(emojiName)}'),
    );
    final response = await _send(request, acceptedStatusCodes: <int>{200, 404});
    return response.statusCode == 200;
  }

  Future<List<CustomEmoji>> listCustomEmojisPage({
    required int page,
    required int perPage,
  }) async {
    final requestUri = _baseUri
        .resolve('/api/v4/emoji')
        .replace(
          queryParameters: <String, String>{
            'page': '$page',
            'per_page': '$perPage',
            'sort': 'name',
          },
        );
    final request = http.Request('GET', requestUri);
    final response = await _send(request, acceptedStatusCodes: <int>{200});

    final body = jsonDecode(response.body);
    if (body is! List<dynamic>) {
      throw const FormatException('Emoji response is not a list.');
    }

    return body
        .whereType<Map<String, dynamic>>()
        .map(
          (raw) => CustomEmoji(
            id: raw['id'] as String? ?? '',
            name: raw['name'] as String? ?? '',
            creatorId: raw['creator_id'] as String? ?? '',
          ),
        )
        .where((emoji) => emoji.id.isNotEmpty && emoji.name.isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> deleteCustomEmoji(String emojiId) async {
    final request = http.Request(
      'DELETE',
      _baseUri.resolve('/api/v4/emoji/${Uri.encodeComponent(emojiId)}'),
    );
    final response = await _send(request, acceptedStatusCodes: <int>{200, 404});
    return response.statusCode == 200;
  }

  Future<void> uploadEmoji({
    required String name,
    required String creatorId,
    required List<int> fileBytes,
    required String fileName,
  }) async {
    final request =
        http.MultipartRequest('POST', _baseUri.resolve('/api/v4/emoji'))
          ..headers[HttpHeaders.authorizationHeader] = 'Bearer $_token'
          ..fields['emoji'] = jsonEncode(<String, String>{
            'name': name,
            'creator_id': creatorId,
          })
          ..files.add(
            http.MultipartFile.fromBytes(
              'image',
              fileBytes,
              filename: fileName,
            ),
          );

    if (rateLimiter != null) {
      await rateLimiter!.acquire();
    }

    late http.StreamedResponse streamed;
    try {
      streamed = await _httpClient
          .send(request)
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw MattermostApiException(
        statusCode: 408,
        message: 'Upload request timed out.',
      );
    } on SocketException catch (error) {
      throw MattermostApiException(
        statusCode: 503,
        message: 'Network error during upload: $error',
      );
    } on http.ClientException catch (error) {
      throw MattermostApiException(
        statusCode: 503,
        message: 'HTTP client error during upload: $error',
      );
    }

    final response = await http.Response.fromStream(streamed);
    rateLimiter?.updateFromHeaders(response.headers, response.statusCode);

    if (response.statusCode != 201) {
      throw _toApiException(response);
    }
  }

  Future<http.Response> _send(
    http.BaseRequest request, {
    required Set<int> acceptedStatusCodes,
  }) async {
    request.headers[HttpHeaders.authorizationHeader] = 'Bearer $_token';

    if (rateLimiter != null) {
      await rateLimiter!.acquire();
    }

    late http.StreamedResponse streamed;
    try {
      streamed = await _httpClient
          .send(request)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw MattermostApiException(
        statusCode: 408,
        message: 'Request timed out.',
      );
    } on SocketException catch (error) {
      throw MattermostApiException(
        statusCode: 503,
        message: 'Network error: $error',
      );
    } on http.ClientException catch (error) {
      throw MattermostApiException(
        statusCode: 503,
        message: 'HTTP client error: $error',
      );
    }

    final response = await http.Response.fromStream(streamed);
    rateLimiter?.updateFromHeaders(response.headers, response.statusCode);

    if (!acceptedStatusCodes.contains(response.statusCode)) {
      throw _toApiException(response);
    }

    return response;
  }

  static MattermostApiException _toApiException(http.Response response) {
    String message = 'Request failed';
    String? requestId;

    try {
      final parsed = jsonDecode(response.body);
      if (parsed is Map<String, dynamic>) {
        message = parsed['message'] as String? ?? message;
        requestId = parsed['request_id'] as String?;
      } else if (response.body.isNotEmpty) {
        message = response.body;
      }
    } catch (_) {
      if (response.body.isNotEmpty) {
        message = response.body;
      }
    }

    final retryAfter = _parseRetryAfter(response.headers);
    return MattermostApiException(
      statusCode: response.statusCode,
      message: message,
      requestId: requestId,
      retryAfter: retryAfter,
    );
  }

  static Duration? _parseRetryAfter(Map<String, String> headers) {
    final retryAfterHeader = headers['retry-after'];
    if (retryAfterHeader != null) {
      final parsedSeconds = int.tryParse(retryAfterHeader.trim());
      if (parsedSeconds != null && parsedSeconds >= 0) {
        return Duration(seconds: parsedSeconds);
      }
    }

    final resetHeader = headers['x-ratelimit-reset'];
    if (resetHeader == null) {
      return null;
    }
    final parsed = int.tryParse(resetHeader.trim());
    if (parsed == null) {
      return null;
    }

    final now = DateTime.now();
    final nowEpochSeconds = now.millisecondsSinceEpoch ~/ 1000;
    if (parsed > nowEpochSeconds + 5) {
      final resetAt = DateTime.fromMillisecondsSinceEpoch(parsed * 1000);
      if (resetAt.isAfter(now)) {
        return resetAt.difference(now);
      }
      return Duration.zero;
    }

    return Duration(seconds: parsed);
  }

  static Uri _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Server URL must not be empty.');
    }
    final withProtocol =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
        ? trimmed
        : 'https://$trimmed';
    return Uri.parse(withProtocol);
  }

  void close() {
    _httpClient.close();
  }
}
