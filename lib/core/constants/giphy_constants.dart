import '../utils/api_key_vault.dart';

class GiphyConstants {
  GiphyConstants._();

  static String get apiKey => ApiKeys.key(ApiService.giphy);

  static const String baseUrl = 'https://api.giphy.com/v1';
  static const int defaultLimit = 12;
}
