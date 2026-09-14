import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/utils/yt_dlp_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late ServerSocket server;
  late StreamSubscription<Socket> connections;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('media_bridge_test_');
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    connections = server.listen((socket) async {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      final request = jsonDecode(line) as Map;
      socket.write(
        '${jsonEncode({
          'result': {'id': request['url']},
        })}\n',
      );
      await socket.flush();
      await socket.close();
    });
  });
  tearDown(() async {
    await connections.cancel();
    await server.close();
    await root.delete(recursive: true);
  });

  test(
    'Android readiness does not await a long-running Python future',
    () async {
      final program = Completer<String?>();
      var launches = 0;
      final bridge = YtDlpBridge(
        temporaryDirectory: () async => root,
        prepareRuntime: () async => root.path,
        launchRuntime: (_, environment) {
          launches++;
          File(
            p.join(environment['CAPTIONCRAFT_MEDIA_RUNTIME']!, 'ready.json'),
          ).writeAsStringSync(jsonEncode({'port': server.port}));
          return program.future;
        },
        startupTimeout: const Duration(seconds: 1),
      );
      final results = await Future.wait([
        bridge.inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw'),
        bridge.inspect('https://www.instagram.com/reel/Caption123/'),
      ]).timeout(const Duration(seconds: 2));
      expect(results, hasLength(2));
      expect(launches, 1);
      expect(program.isCompleted, isFalse);
      program.complete(null);
    },
  );

  test(
    'a slow startup retries readiness without launching another interpreter',
    () async {
      String? runtime;
      var launches = 0;
      final program = Completer<String?>();
      final bridge = YtDlpBridge(
        temporaryDirectory: () async => root,
        prepareRuntime: () async => root.path,
        launchRuntime: (_, environment) {
          launches++;
          runtime = environment['CAPTIONCRAFT_MEDIA_RUNTIME'];
          return program.future;
        },
        startupTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        bridge.inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw'),
        throwsA(isA<TimeoutException>()),
      );
      await File(
        p.join(runtime!, 'ready.json'),
      ).writeAsString(jsonEncode({'port': server.port}));
      expect(
        await bridge.inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw'),
        contains('id'),
      );
      expect(launches, 1);
      program.complete(null);
    },
  );

  test(
    'an invalid readiness marker does not launch a second interpreter',
    () async {
      String? runtime;
      var launches = 0;
      final program = Completer<String?>();
      final bridge = YtDlpBridge(
        temporaryDirectory: () async => root,
        prepareRuntime: () async => root.path,
        launchRuntime: (_, environment) {
          launches++;
          runtime = environment['CAPTIONCRAFT_MEDIA_RUNTIME'];
          File(
            p.join(runtime!, 'ready.json'),
          ).writeAsStringSync('{"port":');
          return program.future;
        },
        startupTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        bridge.inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw'),
        throwsA(isA<TimeoutException>()),
      );

      await File(
        p.join(runtime!, 'ready.json'),
      ).writeAsString(jsonEncode({'port': server.port}));
      expect(
        await bridge.inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw'),
        contains('id'),
      );
      expect(launches, 1);
      program.complete(null);
    },
  );

  test(
    'native startup errors surface without waiting for the deadline',
    () async {
      final bridge = YtDlpBridge(
        temporaryDirectory: () async => root,
        prepareRuntime: () async => root.path,
        launchRuntime: (_, _) async =>
            throw StateError('Missing Python bundle'),
      );
      await expectLater(
        bridge
            .inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw')
            .timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'a definite startup failure does not poison later requests',
    () async {
      var launches = 0;
      var failFirstLaunch = true;
      final bridge = YtDlpBridge(
        temporaryDirectory: () async => root,
        prepareRuntime: () async => root.path,
        launchRuntime: (_, environment) {
          launches++;
          if (failFirstLaunch) {
            failFirstLaunch = false;
            return Future<String?>.error(StateError('temporary startup error'));
          }
          File(
            p.join(environment['CAPTIONCRAFT_MEDIA_RUNTIME']!, 'ready.json'),
          ).writeAsStringSync(jsonEncode({'port': server.port}));
          return Future<String?>.value(null);
        },
        startupTimeout: const Duration(seconds: 1),
      );

      await expectLater(
        bridge.inspect('https://www.youtube.com/watch?v=jNQXAC9IVRw'),
        throwsA(isA<StateError>()),
      );
      final result = await bridge.inspect(
        'https://www.youtube.com/watch?v=jNQXAC9IVRw',
      );

      expect(result, contains('id'));
      expect(launches, 2);
    },
  );
}
