import '../utils/api_key_vault.dart';

class PexelsConstants {
  PexelsConstants._();

  static String get apiKey => ApiKeys.key(ApiService.pexels);

  static const String baseUrl = 'https://api.pexels.com/v1';
  static const int defaultLimit = 24;
  static const int maximumLimit = 80;
}
