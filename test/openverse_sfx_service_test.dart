import 'dart:convert';
import 'dart:io';

import 'package:caption_craft/core/utils/openverse_sfx_service.dart';
import 'package:caption_craft/features/editor/models/sound_effect_library_asset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpenverseSfxService', () {
    test('uses the exact SFX query and normalizes result metadata', () async {
      final server = await _OpenverseServer.start({
        'result_count': 1,
        'results': [
          {
            'id': 'asset-42',
            'title': 'Cinematic whoosh',
            'url': 'https://media.example.test/source.wav',
            'filetype': 'wav',
            'filesize': 9000,
            'alt_files': [
              {
                'url': 'https://media.example.test/preview.ogg',
                'filetype': 'audio/ogg',
                'filesize': 3000,
              },
              {
                'url': 'https://media.example.test/preview-hq.mp3',
                'filetype': 'audio/mpeg',
                'filesize': 4000,
              },
            ],
            'duration': 1250,
            'creator': 'Field Recordist',
            'creator_url': 'https://example.test/creators/field-recordist',
            'license': 'BY',
            'license_version': '4.0',
            'license_url': 'https://creativecommons.org/licenses/by/4.0/',
            'source': 'freesound',
            'provider': 'freesound',
            'foreign_landing_url': 'https://example.test/sounds/42',
            'attribution': 'Cinematic whoosh by Field Recordist (CC BY 4.0)',
            'tags': [
              {'name': 'Whoosh'},
              {'name': 'whoosh'},
              {'name': 'transition'},
              'cinematic',
            ],
            'thumbnail': 'https://api.example.test/thumb/42',
            'waveform': 'https://api.example.test/waveform/42',
          },
        ],
      });
      addTearDown(server.close);
      final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

      final assets = await service.search(query: '  cinematic whoosh  ');

      expect(server.requests, hasLength(1));
      final request = server.requests.single;
      expect(request.path, '/v1/audio/');
      expect(request.queryParameters, containsPair('q', 'cinematic whoosh'));
      expect(request.queryParameters, containsPair('category', 'sound_effect'));
      expect(request.queryParameters, containsPair('mature', 'false'));
      expect(request.queryParameters, containsPair('filter_dead', 'true'));
      expect(request.queryParameters, containsPair('license', 'cc0,pdm,by'));
      expect(request.queryParameters, containsPair('page', '1'));
      expect(request.queryParameters, containsPair('page_size', '20'));
      expect(request.authorization, isNull);

      expect(assets, hasLength(1));
      final asset = assets.single;
      expect(asset.id, 'openverse-asset-42');
      expect(asset.title, 'Cinematic whoosh');
      expect(asset.provider, SoundEffectLibraryProvider.openverse);
      expect(asset.previewUrl, 'https://media.example.test/preview-hq.mp3');
      expect(asset.downloadUrl, asset.previewUrl);
      expect(asset.fileExtension, 'mp3');
      expect(asset.fileSizeBytes, 4000);
      expect(asset.duration, const Duration(milliseconds: 1250));
      expect(asset.creatorName, 'Field Recordist');
      expect(asset.creatorPageUrl, contains('/creators/field-recordist'));
      expect(asset.licenseCode, 'by');
      expect(asset.licenseVersion, '4.0');
      expect(asset.licenseUrl, contains('/licenses/by/4.0/'));
      expect(asset.sourceName, 'freesound');
      expect(asset.sourcePageUrl, contains('/sounds/42'));
      expect(
        asset.attribution,
        'Cinematic whoosh by Field Recordist (CC BY 4.0)',
      );
      expect(asset.tags, ['Whoosh', 'transition', 'cinematic']);
      expect(asset.thumbnailUrl, contains('/thumb/42'));
      expect(asset.waveformUrl, contains('/waveform/42'));
    });

    test('maps license filters and clamps pagination', () async {
      final server = await _OpenverseServer.start({'results': <Object>[]});
      addTearDown(server.close);
      final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

      for (final entry in {
        OpenverseLicenseFilter.allUsable: 'cc0,pdm,by',
        OpenverseLicenseFilter.publicDomain: 'cc0,pdm',
        OpenverseLicenseFilter.attribution: 'by',
      }.entries) {
        await service.search(
          query: 'impact',
          filter: entry.key,
          page: 0,
          limit: 999,
        );
        final query = server.requests.last.queryParameters;
        expect(query['license'], entry.value);
        expect(query['page'], '1');
        expect(query['page_size'], '20');
      }
    });

    test(
      're-enforces the selected license filter on returned results',
      () async {
        final server = await _OpenverseServer.start({
          'results': [
            {
              'id': 'cc0-result',
              'url': 'https://media.example.test/cc0.mp3',
              'filetype': 'mp3',
              'license': 'cc0',
            },
            {
              'id': 'pdm-result',
              'url': 'https://media.example.test/pdm.mp3',
              'filetype': 'mp3',
              'license': 'pdm',
            },
            {
              'id': 'by-result',
              'title': 'Attributed hit',
              'url': 'https://media.example.test/by.mp3',
              'filetype': 'mp3',
              'license': 'by',
              'creator': 'Field Recordist',
              'license_url': 'https://creativecommons.org/licenses/by/4.0/',
              'foreign_landing_url': 'https://example.test/sounds/by-result',
              'attribution': 'Attributed hit by Field Recordist (CC BY 4.0)',
            },
          ],
        });
        addTearDown(server.close);
        final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

        final publicDomain = await service.search(
          query: 'server ignored filter',
          filter: OpenverseLicenseFilter.publicDomain,
        );
        final attribution = await service.search(
          query: 'server ignored filter',
          filter: OpenverseLicenseFilter.attribution,
        );

        expect(publicDomain.map((asset) => asset.licenseCode), ['cc0', 'pdm']);
        expect(attribution.map((asset) => asset.licenseCode), ['by']);
      },
    );

    test('does not make a request for an empty query', () async {
      final server = await _OpenverseServer.start({'results': <Object>[]});
      addTearDown(server.close);
      final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

      expect(server.requests, isEmpty);
      await expectLater(
        service.search(query: '   '),
        throwsA(isA<ArgumentError>()),
      );
      expect(server.requests, isEmpty);
    });

    test('caches identical search metadata without fetching audio', () async {
      final server = await _OpenverseServer.start({
        'results': [
          {
            'id': 'cached-result',
            'url': 'https://media.example.test/cached.mp3',
            'filetype': 'mp3',
            'license': 'cc0',
          },
        ],
      });
      addTearDown(server.close);
      final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

      final first = await service.search(query: 'Door Slam');
      final second = await service.search(query: '  door slam  ');

      expect(server.requests, hasLength(1));
      expect(first, hasLength(1));
      expect(second, same(first));
      expect(
        first.single.downloadUrl,
        startsWith('https://media.example.test'),
      );
    });

    test(
      'falls back to supported main files and skips unsafe results',
      () async {
        final server = await _OpenverseServer.start({
          'results': [
            {
              'id': 'wav-main',
              'title': 'Main WAV',
              'url': 'https://media.example.test/main.WAV?download=1',
              'filetype': 'audio/x-wav',
              'alt_files': [
                {
                  'url': 'http://media.example.test/insecure.mp3',
                  'filetype': 'mp3',
                },
              ],
              'license': 'cc0',
              'provider': 'wikimedia',
              'tags': null,
            },
            {
              'id': 'typed-main',
              'url': 'https://media.example.test/download?id=7',
              'filetype': 'audio/flac',
              'license': 'pdm',
              'source': 'wikimedia_audio',
            },
            {
              'id': 'mapped-alt',
              'url': 'https://media.example.test/source.aiff',
              'filetype': 'aiff',
              'alt_files': {
                'mp3': {
                  'url': 'https://media.example.test/mapped.mp3',
                  'filesize': '1234',
                },
              },
              'license': 'cc0',
            },
            {
              'id': 'unsafe-http',
              'url': 'http://media.example.test/effect.mp3',
              'filetype': 'mp3',
            },
            {
              'id': 'unsupported',
              'url': 'https://media.example.test/effect.aiff',
              'filetype': 'aiff',
            },
            {
              'title': 'Missing id',
              'url': 'https://media.example.test/effect.mp3',
            },
          ],
        });
        addTearDown(server.close);
        final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

        final assets = await service.search(query: 'hit');

        expect(assets.map((asset) => asset.id), [
          'openverse-wav-main',
          'openverse-typed-main',
          'openverse-mapped-alt',
        ]);
        expect(assets[0].fileExtension, 'wav');
        expect(assets[0].downloadUrl, contains('main.WAV'));
        expect(assets[1].fileExtension, 'flac');
        expect(assets[2].downloadUrl, endsWith('/mapped.mp3'));
        expect(assets[2].fileSizeBytes, 1234);
        expect(assets[0].attribution, contains('Main WAV'));
      },
    );

    test('returns an empty list for a malformed response body', () async {
      final server = await _OpenverseServer.start({'results': 'not-a-list'});
      addTearDown(server.close);
      final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

      expect(await service.search(query: 'rain'), isEmpty);
    });

    test(
      'rejects licenses outside the allowlist and incomplete BY data',
      () async {
        final server = await _OpenverseServer.start({
          'results': [
            {
              'id': 'non-commercial',
              'url': 'https://media.example.test/nc.mp3',
              'filetype': 'mp3',
              'license': 'by-nc',
            },
            {
              'id': 'unknown-license',
              'url': 'https://media.example.test/unknown.mp3',
              'filetype': 'mp3',
            },
            {
              'id': 'incomplete-by',
              'url': 'https://media.example.test/by.mp3',
              'filetype': 'mp3',
              'license': 'by',
              'creator': 'Creator without provenance links',
            },
            {
              'id': 'allowed-cc0',
              'url': 'https://media.example.test/cc0.mp3',
              'filetype': 'mp3',
              'license': 'cc0',
            },
          ],
        });
        addTearDown(server.close);
        final service = OpenverseSfxService(baseUrl: server.baseUri.toString());

        final assets = await service.search(query: 'license boundary');

        expect(assets.map((asset) => asset.id), ['openverse-allowed-cc0']);
      },
    );

    test('rejects a non-absolute API base URL', () {
      expect(
        () => OpenverseSfxService(baseUrl: '/relative/api'),
        throwsArgumentError,
      );
    });
  });
}

class _OpenverseServer {
  final HttpServer _server;
  final Object responseBody;
  final List<_ObservedRequest> requests = [];

  _OpenverseServer._(this._server, this.responseBody) {
    _server.listen(_handleRequest);
  }

  static Future<_OpenverseServer> start(Object responseBody) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _OpenverseServer._(server, responseBody);
  }

  Uri get baseUri =>
      Uri.parse('http://${_server.address.address}:${_server.port}/v1/');

  Future<void> close() => _server.close(force: true);

  Future<void> _handleRequest(HttpRequest request) async {
    requests.add(
      _ObservedRequest(
        path: request.uri.path,
        queryParameters: Map.unmodifiable(request.uri.queryParameters),
        authorization: request.headers.value(HttpHeaders.authorizationHeader),
      ),
    );
    if (request.uri.path != '/v1/audio/') {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(responseBody));
    }
    await request.response.close();
  }
}

class _ObservedRequest {
  final String path;
  final Map<String, String> queryParameters;
  final String? authorization;

  const _ObservedRequest({
    required this.path,
    required this.queryParameters,
    required this.authorization,
  });
}
