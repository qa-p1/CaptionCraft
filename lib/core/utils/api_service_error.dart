import 'package:dio/dio.dart';

/// Do not include request URLs, headers or provider response bodies: some
/// providers send API keys in their query string or reflect them in errors.
String apiServiceError(String provider, DioException error) {
  switch (error.response?.statusCode) {
    case 401:
    case 403:
      return '$provider rejected this API key or its permissions. Check Settings → Connected services and your provider dashboard.';
    case 429:
      return '$provider rate limit or quota reached. Wait and try again, or check your provider plan.';
    default:
      if (error.type == DioExceptionType.cancel) {
        return '$provider request cancelled.';
      }
      return '$provider is unavailable. Check your connection and try again.';
  }
}
