import 'package:flutter_dotenv/flutter_dotenv.dart';

class GroqConstants {
  GroqConstants._();

  static String get apiKey => dotenv.env['GROQ_API_KEY'] ?? '';

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
}