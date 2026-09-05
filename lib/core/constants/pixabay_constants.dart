import '../utils/api_key_vault.dart';

class PixabayConstants {
  PixabayConstants._();

  static String get apiKey => ApiKeys.key(ApiService.pixabay);

  static const String baseUrl = 'https://pixabay.com/api';
  static const int defaultLimit = 24;
  static const int minimumLimit = 3;
  static const int maximumLimit = 200;
}
