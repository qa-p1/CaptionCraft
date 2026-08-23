import 'package:flutter_dotenv/flutter_dotenv.dart';

class PixabayConstants {
  PixabayConstants._();

  static const _definedApiKey = String.fromEnvironment('PIXABAY_API_KEY');

  static String get apiKey {
    final defined = _definedApiKey.trim();
    if (defined.isNotEmpty) return defined;
    return dotenv.env['PIXABAY_API_KEY']?.trim() ?? '';
  }

  static const String baseUrl = 'https://pixabay.com/api';
  static const int defaultLimit = 24;
  static const int minimumLimit = 3;
  static const int maximumLimit = 200;
}
