import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release builds require no provider credentials or proxy defines', () {
    for (final name in ['android-release', 'ios-ipa', 'windows-release']) {
      final workflow = File(
        '.github/workflows/build-$name.yml',
      ).readAsStringSync();
      expect(workflow, isNot(contains('CAPTIONCRAFT_TRANSCRIPTION_PROXY_URL')));
      expect(workflow, isNot(contains('--dart-define')));
      for (final provider in ['GROQ', 'GIPHY', 'PEXELS', 'PIXABAY']) {
        expect(workflow, isNot(contains('${provider}_API_KEY')));
      }
    }
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('flutter_dotenv')),
    );
    expect(File('lib/main.dart').readAsStringSync(), isNot(contains('dotenv')));
    expect(File('.env.example').existsSync(), isFalse);
  });

  test(
    'native secure storage has Keychain and device-backup configuration',
    () {
      expect(
        File('ios/Runner/Runner.entitlements').readAsStringSync(),
        contains('<key>keychain-access-groups</key>'),
      );
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('android:fullBackupContent="@xml/backup_rules"'),
      );
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      for (final name in ['backup_rules', 'data_extraction_rules']) {
        final rules = File(
          'android/app/src/main/res/xml/$name.xml',
        ).readAsStringSync();
        expect(rules, contains('path="FlutterSecureStorage.xml"'));
        expect(rules, contains('path="FlutterSecureKeyStorage.xml"'));
      }
    },
  );
}
