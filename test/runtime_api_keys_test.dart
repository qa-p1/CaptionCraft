import 'package:caption_craft/core/utils/api_key_vault.dart';
import 'package:caption_craft/core/utils/api_service_error.dart';
import 'package:caption_craft/core/utils/giphy_service.dart';
import 'package:caption_craft/core/utils/pexels_service.dart';
import 'package:caption_craft/core/utils/pixabay_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ApiKeys.selectOwner(null);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => ApiKeys.selectOwner(null));

  test(
    'existing API clients use saved, rotated and removed runtime keys',
    () async {
      final requests = <RequestOptions>[];
      final client = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'data': [], 'photos': [], 'hits': []},
                ),
              );
            },
          ),
        );
      addTearDown(() => client.close(force: true));
      final giphy = GiphyService(client: client);
      final pexels = PexelsService(client: client);
      final pixabay = PixabayService(client: client);
      ApiKeys.selectOwner('local-test', cloud: false);
      final vault = ApiKeys.active!;
      for (final key in ['first-key', 'rotated-key']) {
        await vault.save({
          for (final service in ApiService.values) service: key,
        });
        await giphy.search(query: 'runtime', kind: GiphySearchKind.gifs);
        await pexels.search(query: 'runtime', filter: PexelsMediaFilter.photos);
        await pixabay.search(
          query: 'runtime',
          filter: PixabayMediaFilter.photos,
        );
        final batch = requests.skip(requests.length - 3).toList();
        expect(batch[0].uri.queryParameters['api_key'], key);
        expect(batch[1].headers['Authorization'], key);
        expect(batch[2].uri.queryParameters['key'], key);
        expect(batch.every((request) => !request.followRedirects), isTrue);
      }
      expect(requests, hasLength(6));
      await vault.save({});
      await expectLater(
        giphy.search(query: 'runtime', kind: GiphySearchKind.gifs),
        throwsStateError,
      );
      await expectLater(pexels.search(), throwsStateError);
      await expectLater(pixabay.search(), throwsStateError);
      expect(requests, hasLength(6));
      ApiKeys.selectOwner('another-user', cloud: false);
      await ApiKeys.active!.initialize();
      expect(ApiKeys.key(ApiService.groq), isEmpty);
      ApiKeys.selectOwner('local-test', cloud: false);
      await ApiKeys.active!.initialize();
      expect(ApiKeys.key(ApiService.groq), isEmpty);
    },
  );

  test('provider errors never reflect request keys or response bodies', () {
    final request = RequestOptions(
      path: 'https://example.test?key=private-key',
      headers: {'Authorization': 'private-key'},
    );
    for (final status in [401, 403, 429, 500]) {
      final error = DioException(
        requestOptions: request,
        response: Response(
          requestOptions: request,
          statusCode: status,
          data: 'private-key',
        ),
      );
      final message = apiServiceError('Test provider', error);
      expect(message, isNot(contains('private-key')));
      expect(message, isNot(contains('example.test')));
      expect(message, contains('Test provider'));
    }
  });
}
