import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS App Attest production entitlement is wired to every app build', () {
    final entitlements = File(
      'ios/Runner/Runner.entitlements',
    ).readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    expect(
      entitlements,
      contains('com.apple.developer.devicecheck.appattest-environment'),
    );
    expect(entitlements, contains('<string>production</string>'));
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'
          .allMatches(project)
          .length,
      3,
      reason: 'Debug, Profile, and Release must all use the entitlement file.',
    );
  });

  test('Windows release inputs and modern CMake compatibility are pinned', () {
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    final workflow = File(
      '.github/workflows/build-windows-release.yml',
    ).readAsStringSync();

    expect(cmake, contains('set(CMAKE_POLICY_VERSION_MINIMUM 3.5)'));
    expect(
      workflow,
      contains(
        'FIREBASE_CPP_SDK_SHA256: '
        'acc415e7a50d80f8456ce8abd8eb2e1a6f0739517b3939a1b1feb66d865b0be8',
      ),
    );
    expect(workflow, contains('FIREBASE_CPP_SDK_BYTES: "957334242"'));
    expect(workflow, contains('Prepare verified Firebase C++ SDK'));
    expect(workflow, contains('Prepare verified Windows FFmpeg runtime'));
  });
}
