import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "CaptionCraftAssetPackStorage"
    )
    let channel = FlutterMethodChannel(
      name: "captioncraft/asset_pack_storage",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "availableBytes" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let path = arguments["path"] as? String,
        !path.isEmpty
      else {
        result(
          FlutterError(
            code: "invalid_path",
            message: "A storage path is required.",
            details: nil
          )
        )
        return
      }
      do {
        let attributes = try FileManager.default.attributesOfFileSystem(
          forPath: path
        )
        let freeBytes = attributes[.systemFreeSize] as? NSNumber
        result(freeBytes?.int64Value)
      } catch {
        result(
          FlutterError(
            code: "storage_probe_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }
}
