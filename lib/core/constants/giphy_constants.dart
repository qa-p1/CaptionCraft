import 'package:flutter_dotenv/flutter_dotenv.dart';

class GiphyConstants {
  GiphyConstants._();

  static const _definedApiKey = String.fromEnvironment('GIPHY_API_KEY');

  static String get apiKey {
    final defined = _definedApiKey.trim();
    if (defined.isNotEmpty) return defined;
    return dotenv.env['GIPHY_API_KEY']?.trim() ?? '';
  }

  static const String baseUrl = 'https://api.giphy.com/v1';
  static const int defaultLimit = 12;
}
