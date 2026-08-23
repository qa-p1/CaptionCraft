import 'package:flutter_dotenv/flutter_dotenv.dart';

class PexelsConstants {
  PexelsConstants._();

  static const _definedApiKey = String.fromEnvironment('PEXELS_API_KEY');

  static String get apiKey {
    final defined = _definedApiKey.trim();
    if (defined.isNotEmpty) return defined;
    return dotenv.env['PEXELS_API_KEY']?.trim() ?? '';
  }

  static const String baseUrl = 'https://api.pexels.com/v1';
  static const int defaultLimit = 24;
  static const int maximumLimit = 80;
}
