import 'package:caption_craft/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Firebase startup failures render a recoverable app screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: CaptionCraftApp(startupFailure: true)),
    );

    expect(find.text('CaptionCraft could not start securely'), findsOneWidget);
    expect(find.textContaining('Close and reopen the app'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
