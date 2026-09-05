import 'dart:async';

import 'package:caption_craft/core/utils/api_key_vault.dart';
import 'package:caption_craft/features/settings/screens/api_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'api_key_vault_test.dart' show MemoryVaultStorage, copyRecord;

void main() {
  testWidgets('provider links use the external browser', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final vault = ApiKeyVault(
      uid: 'local',
      cloud: false,
      storage: MemoryVaultStorage(),
    );
    await vault.initialize();
    await tester.pumpWidget(MaterialApp(home: ApiSettingsScreen(vault: vault)));
    for (final service in ApiService.values) {
      final link = find.text('Get ${service.label} API key');
      await tester.scrollUntilVisible(
        link,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(calls.last.method, 'launch');
      expect(calls.last.arguments['url'], service.signupUrl);
      expect(calls.last.arguments['useSafariVC'], isFalse);
      expect(calls.last.arguments['useWebView'], isFalse);
    }
  });

  testWidgets('cloud hydration fills the form before editing is enabled', (
    tester,
  ) async {
    final storage = MemoryVaultStorage();
    final source = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
    await tester.runAsync(() async {
      await source.save({ApiService.groq: 'old-key'});
      final local = copyRecord(storage.local);
      await source.save({ApiService.groq: 'cloud-key'});
      storage.local = local;
    });
    storage.cloudReadGate = Completer<void>();
    final vault = ApiKeyVault(uid: 'alice', cloud: true, storage: storage);
    final loading = vault.initialize();
    await tester.pumpWidget(MaterialApp(home: ApiSettingsScreen(vault: vault)));
    final field = find.byKey(const ValueKey('api-key-groq'));
    await tester.scrollUntilVisible(
      field,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<TextFormField>(field).enabled, isFalse);
    await tester.runAsync(() async {
      storage.cloudReadGate!.complete();
      await loading;
    });
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(field).enabled, isTrue);
    expect(tester.widget<TextFormField>(field).controller!.text, 'cloud-key');
  });

  testWidgets('setup is optional and skip is remembered', (tester) async {
    final storage = MemoryVaultStorage();
    final vault = ApiKeyVault(uid: 'local', cloud: false, storage: storage);
    await vault.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showApiSetupPrompt(context, vault),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Skip for now'), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Skip for now'), findsNothing);
    expect(storage.local!['seen'], isTrue);
  });

  testWidgets(
    'settings handles narrow screens, masked keys and unsaved edits',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final vault = ApiKeyVault(
        uid: 'local',
        cloud: false,
        storage: MemoryVaultStorage(),
      );
      await vault.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ApiSettingsScreen(vault: vault),
                  ),
                ),
                child: const Text('Settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('api-key-groq'));
      await tester.scrollUntilVisible(field, 200);
      await tester.enterText(field, 'gsk_my_key');
      await tester.pump();
      final input = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(input.obscureText, isTrue);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard unsaved keys?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save keys securely'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save keys securely'));
      await tester.pumpAndSettle();
      expect(vault.key(ApiService.groq), 'gsk_my_key');
      expect(find.text('Keys saved securely on this PC.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
