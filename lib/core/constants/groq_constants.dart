import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class GroqConstants {
  GroqConstants._();

  static const _definedApiKey = String.fromEnvironment('GROQ_API_KEY');
  static const _definedLegacyApiKey = String.fromEnvironment('groq_api_key');
  static const _definedProxyUrl = String.fromEnvironment(
    'CAPTIONCRAFT_TRANSCRIPTION_PROXY_URL',
  );

  /// Direct provider credentials are a development convenience only. The
  /// compile-time release branch returns no key, so production code cannot
  /// accidentally authorize requests from a distributable client.
  static String get apiKey {
    if (kReleaseMode) return '';
    return _normalizedValue(_definedApiKey) ??
        _normalizedValue(_definedLegacyApiKey) ??
        _envValue('GROQ_API_KEY') ??
        _envValue('groq_api_key') ??
        '';
  }

  static String get transcriptionProxyUrl =>
      _normalizedValue(_definedProxyUrl) ??
      _envValue('CAPTIONCRAFT_TRANSCRIPTION_PROXY_URL') ??
      '';

  static Uri? get transcriptionProxyUri => validatedProxyUri(
    transcriptionProxyUrl,
    allowLoopbackHttp: !kReleaseMode,
  );

  @visibleForTesting
  static Uri? validatedProxyUri(
    String rawValue, {
    required bool allowLoopbackHttp,
  }) {
    final uri = Uri.tryParse(rawValue.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.query.isNotEmpty) {
      return null;
    }
    if (uri.scheme.toLowerCase() == 'https') return uri;
    final isLoopback = const {
      'localhost',
      '127.0.0.1',
      '::1',
    }.contains(uri.host.toLowerCase());
    if (allowLoopbackHttp && uri.scheme.toLowerCase() == 'http' && isLoopback) {
      return uri;
    }
    return null;
  }

  static bool isConfiguredFor({
    required String proxyUrl,
    required String apiKey,
    required bool releaseMode,
  }) {
    final proxy = validatedProxyUri(proxyUrl, allowLoopbackHttp: !releaseMode);
    return proxy != null || (!releaseMode && apiKey.trim().isNotEmpty);
  }

  static const String baseUrl = 'https://api.groq.com/openai/v1';
  static const String model = 'whisper-large-v3';
  static const String transcriptionsEndpoint = '/audio/transcriptions';
  static const int maxChunkBytes = 15 * 1024 * 1024;
  static const int chunkDurationSeconds = 10 * 60;
  static const int chunkOverlapSeconds = 3;
  static const int targetAudioSampleRate = 16000;
  static const int targetAudioChannels = 1;
  static const int targetAudioBitrate = 32000;
  static const int maxVideoDurationMinutes = 20;

  static String? _envValue(String key) {
    return _normalizedValue(dotenv.env[key]);
  }

  static String? _normalizedValue(String? rawValue) {
    final value = rawValue?.trim();
    if (value == null || value.isEmpty) return null;

    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == "'" && last == "'") || (first == '"' && last == '"')) {
        return value.substring(1, value.length - 1).trim();
      }
    }

    return value;
  }
}
