import Flutter
import UIKit
import media_backup

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
  }

  // Forward iOS' background URLSession completion handler to the plugin so
  // it can call it once the session has drained all background events.
  // Required when MediaBackupIosSettings(useBackgroundSession: true).
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    MediaBackupPlugin.handleBackgroundSession(
      identifier: identifier,
      completionHandler: completionHandler
    )
  }
}
