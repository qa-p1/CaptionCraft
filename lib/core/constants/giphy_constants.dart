import 'package:flutter_dotenv/flutter_dotenv.dart';

class GiphyConstants {
  GiphyConstants._();

  static String get apiKey => dotenv.env['GIPHY_API_KEY'] ?? '';

  static const String baseUrl = 'https://api.giphy.com/v1';
  static const int defaultLimit = 12;
}
