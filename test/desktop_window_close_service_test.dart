import 'package:caption_craft/core/utils/desktop_window_close_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native close asks top routes first and stops when one declines',
    () async {
      final editorOwner = Object();
      final exportOwner = Object();
      final calls = <String>[];
      addTearDown(() {
        DesktopWindowCloseService.unregisterHandler(exportOwner);
        DesktopWindowCloseService.unregisterHandler(editorOwner);
      });

      DesktopWindowCloseService.registerHandler(
        owner: editorOwner,
        handler: () async {
          calls.add('editor');
          return true;
        },
      );
      DesktopWindowCloseService.registerHandler(
        owner: exportOwner,
        handler: () async {
          calls.add('export');
          return false;
        },
      );

      expect(await DesktopWindowCloseService.requestCloseForTesting(), isFalse);
      expect(calls, <String>['export']);

      calls.clear();
      DesktopWindowCloseService.registerHandler(
        owner: exportOwner,
        handler: () async {
          calls.add('export');
          return true;
        },
      );
      expect(await DesktopWindowCloseService.requestCloseForTesting(), isTrue);
      expect(calls, <String>['export', 'editor']);
    },
  );

  test('native close is allowed when no protected route is mounted', () async {
    expect(await DesktopWindowCloseService.requestCloseForTesting(), isTrue);
  });
}
