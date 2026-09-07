import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:serious_python/serious_python.dart';
import 'package:uuid/uuid.dart';

/// Embedded yt-dlp, shared by media services. No server account or external
/// Python installation is required; the runtime and pinned package ship in-app.
abstract interface class MediaExtractor {
  Future<Map<String, dynamic>> inspect(String url);
  Future<void> downloadFormat({
    required String jobId,
    required String url,
    required String format,
    required String outputPath,
    required int maxBytes,
    required void Function(int, int?) onProgress,
  });
  Future<void> cancel(String jobId);
}

class YtDlpBridge implements MediaExtractor {
  YtDlpBridge._();
  static final instance = YtDlpBridge._();
  final _token = const Uuid().v4();
  Future<int>? _startup;
  Directory? _directory;
  final Map<String, Socket> _sockets = {};
  final Map<String, String> _workers = {};
  final Set<String> _cancelledJobs = {};

  Future<int> _start() async {
    final temporary = await getTemporaryDirectory();
    final root = await Directory(
      p.join(temporary.path, 'media_runtime'),
    ).create(recursive: true);
    final directory = await root.createTemp('session_');
    _directory = directory;
    final app = await extractAssetZip('assets/media_runtime.zip');
    await SeriousPython.runProgram(
      p.join(app, 'main.py'),
      modulePaths: [p.join(app, '__pypackages__')],
      environmentVariables: {
        'CAPTIONCRAFT_MEDIA_RUNTIME': directory.path,
        'CAPTIONCRAFT_MEDIA_TOKEN': _token,
      },
      sync: false,
    ).timeout(const Duration(seconds: 15));
    final ready = File(p.join(directory.path, 'ready.json'));
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (await ready.exists()) {
        return (jsonDecode(await ready.readAsString()) as Map)['port'] as int;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('The media downloader could not start.');
  }

  @override
  Future<Map<String, dynamic>> inspect(String url) =>
      _request({'operation': 'inspect', 'url': url});

  @override
  Future<void> downloadFormat({
    required String jobId,
    required String url,
    required String format,
    required String outputPath,
    required int maxBytes,
    required void Function(int, int?) onProgress,
  }) async {
    final result = await _request(
      {
        'operation': 'download',
        'url': url,
        'format': format,
        'job': jobId,
        'maxBytes': maxBytes,
      },
      jobId: jobId,
      onProgress: onProgress,
    );
    final downloaded = File(result['path'] as String);
    try {
      final bytes = await downloaded.length();
      if (bytes <= 0 || bytes > maxBytes) {
        throw StateError(
          'Downloaded media is empty or exceeds the size limit.',
        );
      }
      if (_cancelledJobs.contains(jobId)) {
        throw StateError('Download cancelled');
      }
      await downloaded.copy(outputPath);
    } finally {
      if (await downloaded.exists()) await downloaded.delete();
    }
  }

  Future<Map<String, dynamic>> _request(
    Map<String, Object> request, {
    String? jobId,
    void Function(int, int?)? onProgress,
  }) async {
    final worker = jobId == null ? null : const Uuid().v4();
    if (jobId != null) {
      _cancelledJobs.remove(jobId);
      _workers[jobId] = worker!;
    }
    Socket? socket;
    var completed = false;
    try {
      int port;
      try {
        port = await (_startup ??= _start());
      } catch (_) {
        _startup = null;
        rethrow;
      }
      void checkCancelled() {
        if (jobId != null && _cancelledJobs.contains(jobId)) {
          throw StateError('Download cancelled');
        }
      }

      checkCancelled();
      socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(seconds: 5),
      );
      checkCancelled();
      if (jobId != null) _sockets[jobId] = socket;
      socket.write(
        '${jsonEncode({...request, 'token': _token, 'job': ?worker})}\n',
      );
      await socket.flush();
      await for (final line
          in socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 45))) {
        checkCancelled();
        final event = jsonDecode(line) as Map<String, dynamic>;
        if (event['error'] != null) throw StateError(event['error'] as String);
        if (event['result'] is Map) {
          completed = true;
          return Map<String, dynamic>.from(event['result'] as Map);
        }
        if (event['received'] is num) {
          onProgress?.call(
            (event['received'] as num).toInt(),
            (event['total'] as num?)?.toInt(),
          );
        }
      }
      throw StateError(
        'The media downloader disconnected. Retry the download.',
      );
    } finally {
      if (jobId != null) {
        if (!completed && worker != null) await _signalCancel(worker);
        if (identical(_sockets[jobId], socket)) _sockets.remove(jobId);
        if (_workers[jobId] == worker) _workers.remove(jobId);
      }
      socket?.destroy();
    }
  }

  Future<void> _signalCancel(String worker) async {
    final directory = _directory;
    if (directory != null) {
      await File(
        p.join(directory.path, '$worker.cancel'),
      ).writeAsString('cancel');
    }
  }

  @override
  Future<void> cancel(String jobId) async {
    _cancelledJobs.add(jobId);
    final worker = _workers[jobId];
    if (worker != null) await _signalCancel(worker);
    _sockets.remove(jobId)?.destroy();
  }
}
