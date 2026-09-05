import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef DesktopWindowCloseHandler = Future<bool> Function();

/// Coordinates native Windows close requests with any mounted editor.
///
/// Win32 normally destroys the process as soon as the title-bar close button
/// is pressed. The runner asks this channel for permission first so an editor
/// can finish its local save (or let the user explicitly discard it).
class DesktopWindowCloseService {
  DesktopWindowCloseService._();

  static const MethodChannel _channel = MethodChannel(
    'captioncraft/window_lifecycle',
  );

  static bool _initialized = false;
  static final List<({Object owner, DesktopWindowCloseHandler handler})>
  _handlers = <({Object owner, DesktopWindowCloseHandler handler})>[];

  static void initialize() {
    if (_initialized ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static void registerHandler({
    required Object owner,
    required DesktopWindowCloseHandler handler,
  }) {
    initialize();
    _handlers.removeWhere(
      (registration) => identical(registration.owner, owner),
    );
    _handlers.add((owner: owner, handler: handler));
  }

  static void unregisterHandler(Object owner) {
    _handlers.removeWhere(
      (registration) => identical(registration.owner, owner),
    );
  }

  static Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method != 'requestClose') {
      throw MissingPluginException('Unknown window lifecycle method.');
    }
    return _requestClose();
  }

  static Future<bool> _requestClose() async {
    // Ask the top-most route first (for example an active export), followed by
    // the editor underneath it. A copied list remains stable if a successful
    // handler disposes itself while the request is in flight.
    for (final registration in List.of(_handlers).reversed) {
      try {
        if (!await registration.handler()) return false;
      } catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint('Could not prepare the app for window close: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
        return false;
      }
    }
    return true;
  }

  @visibleForTesting
  static Future<bool> requestCloseForTesting() => _requestClose();
}
