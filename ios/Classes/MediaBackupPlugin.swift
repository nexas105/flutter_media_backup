import Flutter
import UIKit
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

private struct PluginComponents {
  let database: AssetDatabase
  let loader: AssetLoader
  let uploader: AssetUploader
}

public class MediaBackupPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let workerQueue = DispatchQueue(label: "media_backup.plugin", qos: .utility)
  private let scanFreshnessWindow: TimeInterval = 300
  private var uploaderEnabled = false
  private var deltaObserverEnabled = false
  private var isScanInFlight = false
  private var isAppActive: Bool

  private lazy var componentsResult: Result<PluginComponents, Error> = {
    do {
      let database = try AssetDatabase()
      let loader = AssetLoader(database: database)
      let uploader = AssetUploader(database: database)
      loader.onDatabaseChanged = {
        uploader.triggerPump()
      }
      return .success(PluginComponents(database: database, loader: loader, uploader: uploader))
    } catch {
      return .failure(error)
    }
  }()

  private var graceTaskId: UIBackgroundTaskIdentifier = .invalid
  private var graceTimer: DispatchWorkItem?

  static var bgProcessingTaskIdentifier: String {
    (Bundle.main.bundleIdentifier ?? "media_backup") + ".media_backup.bg_processing"
  }

  override init() {
    isAppActive = UIApplication.shared.applicationState == .active
    super.init()

    NotificationCenter.default.addObserver(self,
                                           selector: #selector(appDidBecomeActive),
                                           name: UIApplication.didBecomeActiveNotification,
                                           object: nil)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(appWillResignActive),
                                           name: UIApplication.willResignActiveNotification,
                                           object: nil)

    registerBackgroundProcessingTask()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private var channel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "media_backup", binaryMessenger: registrar.messenger())
    let instance = MediaBackupPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)

    let eventChannel = FlutterEventChannel(name: "media_backup/upload_events",
                                           binaryMessenger: registrar.messenger())
    eventChannel.setStreamHandler(instance)

    // Capture channel strongly so the closure keeps it alive for the lifetime
    // of the plugin (whole app). Weak captures get nil'd immediately because
    // local lets don't retain into the bridge.
    MediaBackupLogger.shared.lineEmitter = { line in
      DispatchQueue.main.async {
        channel.invokeMethod("__nativeLog", arguments: ["line": line])
      }
    }

    // Self-test — this line MUST appear in the `flutter run` console if the
    // native→Dart log bridge is wired correctly. If you don't see it, the
    // bridge is broken and every iOS log is being dropped.
    MediaBackupLogger.shared.info("BRIDGE", "Native log bridge active")
  }

  // MARK: - Background URLSession integration
  //
  // iOS calls `application:handleEventsForBackgroundURLSession:completionHandler:`
  // on the AppDelegate when a background session has finished transfers while
  // the app was suspended. Your AppDelegate must forward that call here so the
  // plugin can hand the completion handler to the URLSession delegate once all
  // events have been delivered — otherwise iOS won't allow the app to suspend
  // cleanly and progress indicators stay wrong.
  //
  //     override func application(
  //       _ application: UIApplication,
  //       handleEventsForBackgroundURLSession identifier: String,
  //       completionHandler: @escaping () -> Void
  //     ) {
  //       MediaBackupPlugin.handleBackgroundSession(
  //         identifier: identifier,
  //         completionHandler: completionHandler
  //       )
  //     }
  //
  private static var backgroundHandlerLock = NSLock()
  private static var backgroundCompletionHandlers: [String: () -> Void] = [:]

  public static func handleBackgroundSession(identifier: String,
                                             completionHandler: @escaping () -> Void) {
    backgroundHandlerLock.lock()
    backgroundCompletionHandlers[identifier] = completionHandler
    backgroundHandlerLock.unlock()

    MediaBackupLogger.shared.info("Plugin",
                                  "Background session handoff received",
                                  context: ["identifier": identifier])
  }

  static func drainBackgroundHandler(identifier: String) -> (() -> Void)? {
    backgroundHandlerLock.lock()
    let handler = backgroundCompletionHandlers.removeValue(forKey: identifier)
    backgroundHandlerLock.unlock()
    return handler
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "configureLogger":
      let arguments = call.arguments as? [String: Any]
      let levelRaw = arguments?["level"] as? Int ?? MediaBackupLogLevel.info.rawValue
      let fileLogging = arguments?["enableFileLogging"] as? Bool ?? true
      let consoleLogging = arguments?["enableConsoleLogging"] as? Bool ?? true
      let maxBytes = arguments?["maxFileBytes"] as? Int ?? 1_048_576
      let level = MediaBackupLogLevel(rawValue: levelRaw) ?? .info
      MediaBackupLogger.shared.configure(minLevel: level,
                                         fileLoggingEnabled: fileLogging,
                                         consoleLoggingEnabled: consoleLogging,
                                         maxFileBytes: maxBytes)
      result(["logFile": MediaBackupLogger.shared.currentLogFileURL()?.path as Any])
    case "requestPhotoPermission":
      withComponents(result: result) { components in
        components.loader.requestAuthorization { permission in
          DispatchQueue.main.async {
            result(permission)
          }
        }
      }
    case "loadAssetsToDatabase":
      withComponents(result: result) { components in
        let arguments = call.arguments as? [String: Any]
        let batchSize = arguments?["batchSize"] as? Int ?? 50

        workerQueue.async {
          components.loader.loadAllAssets(batchSize: batchSize) { loadResult in
            DispatchQueue.main.async {
              switch loadResult {
              case .success(let summary):
                let counts = (try? components.database.statusCounts()) ?? [:]
                result([
                  "scannedCount": summary.scannedCount,
                  "databasePath": summary.databasePath,
                  "batchSize": summary.batchSize,
                  "statusCounts": counts,
                ])
              case .failure(let error):
                result(FlutterError(code: "ASSET_LOAD_FAILED",
                                    message: error.localizedDescription,
                                    details: nil))
              }
            }
          }
        }
      }
    case "startDeltaObserver":
      deltaObserverEnabled = true
      withComponents(result: result) { components in
        guard isAppActive else {
          result("deferred_until_active")
          return
        }

        components.loader.startDeltaObservation { deltaResult in
          DispatchQueue.main.async {
            switch deltaResult {
            case .success(let permission):
              result(permission)
            case .failure(let error):
              result(FlutterError(code: "DELTA_OBSERVER_FAILED",
                                  message: error.localizedDescription,
                                  details: nil))
            }
          }
        }
      }
    case "stopDeltaObserver":
      deltaObserverEnabled = false
      withComponents(result: result) { components in
        components.loader.stopDeltaObservation()
        result(nil)
      }
    case "configureUploader":
      withComponents(result: result) { components in
        guard let arguments = call.arguments as? [String: Any],
              let providerMap = arguments["provider"] as? [String: Any]
        else {
          result(FlutterError(code: "INVALID_ARGUMENTS",
                              message: "configureUploader requires provider map",
                              details: nil))
          return
        }

        let imageConcurrency = arguments["imageConcurrency"] as? Int ?? 2
        let videoConcurrency = arguments["videoConcurrency"] as? Int ?? 1
        let maxTempBytes = (arguments["maxTempBytes"] as? NSNumber)?.int64Value ?? 700 * 1024 * 1024
        let maxInFlightBytes = (arguments["maxInFlightBytes"] as? NSNumber)?.int64Value ?? 300 * 1024 * 1024
        let extractionConcurrency = arguments["extractionConcurrency"] as? Int ?? 2
        let maxConcurrentUploads = arguments["maxConcurrentUploads"] as? Int ?? 6
        let useBackgroundSession = arguments["useBackgroundSession"] as? Bool ?? false
        let uploadOrderRaw = arguments["uploadOrder"] as? String ?? "newest_first"
        let downloadFromICloud = arguments["downloadFromICloud"] as? Bool ?? true
        let uploadOrder = UploadOrder(rawValue: uploadOrderRaw) ?? .newestFirst

        do {
          let provider = try UploadProviderFactory.make(from: providerMap)
          components.uploader.configure(provider: provider,
                                        imageConcurrency: imageConcurrency,
                                        videoConcurrency: videoConcurrency,
                                        maxTempBytes: maxTempBytes,
                                        useBackgroundSession: useBackgroundSession,
                                        uploadOrder: uploadOrder,
                                        downloadFromICloud: downloadFromICloud,
                                        maxInFlightBytes: maxInFlightBytes,
                                        extractionConcurrency: extractionConcurrency,
                                        maxConcurrentUploads: maxConcurrentUploads)
          result([
            "providerKind": provider.kind,
            "simulated": provider.simulatesUpload,
            "backgroundSession": useBackgroundSession,
            "uploadOrder": uploadOrderRaw,
            "downloadFromICloud": downloadFromICloud,
            "maxInFlightBytes": maxInFlightBytes,
            "extractionConcurrency": max(1, extractionConcurrency),
            "maxConcurrentUploads": max(1, maxConcurrentUploads),
            "maxTempBytes": max(50 * 1024 * 1024, maxTempBytes),
          ])
        } catch {
          MediaBackupLogger.shared.error("Plugin",
                                         "Failed to configure provider",
                                         error: error)
          result(FlutterError(code: "INVALID_PROVIDER",
                              message: error.localizedDescription,
                              details: nil))
        }
      }
    case "startUploader":
      uploaderEnabled = true
      withComponents(result: result) { components in
        self.ensureFreshScan(components: components) {
          if self.isAppActive {
            components.uploader.start()
          }
          DispatchQueue.main.async {
            result(nil)
          }
        }
      }
    case "stopUploader":
      uploaderEnabled = false
      withComponents(result: result) { components in
        components.uploader.stop()
        result(nil)
      }
    case "resetDatabase":
      let arguments = call.arguments as? [String: Any]
      let autoRestart = arguments?["autoRestart"] as? Bool ?? true

      withComponents(result: result) { components in
        self.workerQueue.async {
          components.loader.stopDeltaObservation()
          components.uploader.cancelAllAndClear {
            do {
              try components.database.reset()
            } catch {
              MediaBackupLogger.shared.error("Plugin",
                                             "Database reset failed",
                                             error: error)
              DispatchQueue.main.async {
                result(FlutterError(code: "RESET_FAILED",
                                    message: error.localizedDescription,
                                    details: nil))
              }
              return
            }

            MediaBackupLogger.shared.info("Plugin",
                                          "Database reset complete",
                                          context: ["autoRestart": autoRestart])

            let restartUploader = autoRestart && self.uploaderEnabled && self.isAppActive
            let restartObserver = autoRestart && self.deltaObserverEnabled && self.isAppActive

            if restartObserver {
              components.loader.startDeltaObservation { _ in }
            }

            if restartUploader {
              self.ensureFreshScan(components: components) {
                components.uploader.start()
                DispatchQueue.main.async {
                  result(["reset": true, "autoRestart": true])
                }
              }
            } else {
              DispatchQueue.main.async {
                result(["reset": true, "autoRestart": autoRestart])
              }
            }
          }
        }
      }
    case "retryFailedUploads":
      withComponents(result: result) { components in
        self.workerQueue.async {
          do {
            let retried = try components.database.retryFailed()
            MediaBackupLogger.shared.info("Plugin",
                                          "retryFailedUploads",
                                          context: ["retried": retried])
            components.uploader.triggerPump()
            DispatchQueue.main.async {
              result(["retriedCount": retried])
            }
          } catch {
            MediaBackupLogger.shared.error("Plugin",
                                           "retryFailedUploads failed",
                                           error: error)
            DispatchQueue.main.async {
              result(FlutterError(code: "RETRY_FAILED",
                                  message: error.localizedDescription,
                                  details: nil))
            }
          }
        }
      }
    case "getUploadStatusCounts":
      withComponents(result: result) { components in
        do {
          let counts = try components.database.statusCounts()
          result(counts)
        } catch {
          result(FlutterError(code: "STATUS_COUNTS_FAILED",
                              message: error.localizedDescription,
                              details: nil))
        }
      }
    case "queryAssets":
      withComponents(result: result) { components in
        let args = call.arguments as? [String: Any]
        let status = args?["status"] as? String
        let mediaType = args?["mediaType"] as? Int
        let limit = args?["limit"] as? Int ?? 50
        let offset = args?["offset"] as? Int ?? 0
        let sortBy = args?["sortBy"] as? String ?? "creation_ts"
        let ascending = args?["ascending"] as? Bool ?? false
        let dir = ascending ? "ASC" : "DESC"
        let orderBy = "ORDER BY ifnull(\(sortBy), 0) \(dir), local_id \(dir)"

        do {
          let rows = try components.database.queryAssets(status: status,
                                                         mediaType: mediaType,
                                                         limit: limit,
                                                         offset: offset,
                                                         orderBy: orderBy)
          result(rows)
        } catch {
          result(FlutterError(code: "QUERY_FAILED",
                              message: error.localizedDescription,
                              details: nil))
        }
      }
    case "getAsset":
      withComponents(result: result) { components in
        guard let args = call.arguments as? [String: Any],
              let localId = args["localIdentifier"] as? String else {
          result(FlutterError(code: "INVALID_ARGUMENTS",
                              message: "getAsset requires localIdentifier",
                              details: nil))
          return
        }
        do {
          let asset = try components.database.getAsset(localIdentifier: localId)
          result(asset)
        } catch {
          result(FlutterError(code: "QUERY_FAILED",
                              message: error.localizedDescription,
                              details: nil))
        }
      }
    case "countAssets":
      withComponents(result: result) { components in
        let args = call.arguments as? [String: Any]
        let status = args?["status"] as? String
        let mediaType = args?["mediaType"] as? Int
        do {
          let count = try components.database.countAssets(status: status, mediaType: mediaType)
          result(count)
        } catch {
          result(FlutterError(code: "COUNT_FAILED",
                              message: error.localizedDescription,
                              details: nil))
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @objc
  private func appDidBecomeActive() {
    isAppActive = true

    withComponentsSilently { components in
      if self.deltaObserverEnabled {
        components.loader.startDeltaObservation { _ in }
      }

      if self.uploaderEnabled {
        self.ensureFreshScan(components: components) {
          components.uploader.start()
        }
      }
    }
  }

  private func ensureFreshScan(components: PluginComponents,
                               completion: @escaping () -> Void) {
    workerQueue.async {
      if self.isScanInFlight {
        completion()
        return
      }

      let state = (try? components.database.loadScanState()) ?? ScanState(lastCompletedAt: nil, cursorCreationTs: nil)
      let now = Date().timeIntervalSince1970
      let hasPendingCursor = state.cursorCreationTs != nil
      let isStale: Bool
      if let lastCompletedAt = state.lastCompletedAt {
        isStale = (now - lastCompletedAt) > self.scanFreshnessWindow
      } else {
        isStale = true
      }

      guard hasPendingCursor || isStale else {
        completion()
        return
      }

      self.isScanInFlight = true
      // If we already completed a full scan before, do an incremental scan
      // that only fetches assets created or modified since then.
      let incrementalTs = hasPendingCursor ? nil : state.lastCompletedAt
      components.loader.loadAllAssets(batchSize: 50, incrementalSinceTs: incrementalTs) { _ in
        self.workerQueue.async {
          self.isScanInFlight = false
          completion()
        }
      }
    }
  }

  @objc
  private func appWillResignActive() {
    isAppActive = false

    withComponentsSilently { components in
      if self.deltaObserverEnabled {
        components.loader.stopDeltaObservation()
      }

      if self.uploaderEnabled {
        // Don't stop yet — request a short iOS grace window so the uploader
        // can hand off in-flight extractions to the (background) URLSession
        // before suspension. The PHAssetResourceManager.writeData() callbacks
        // only fire while the app still has wall-time; once handed off to
        // URLSession, iOS keeps transferring on its own.
        self.beginGracefulExit(uploader: components.uploader)
      }
    }

    scheduleBackgroundProcessingIfAvailable()
  }

  private func beginGracefulExit(uploader: AssetUploader) {
    graceTimer?.cancel()
    if graceTaskId != .invalid {
      UIApplication.shared.endBackgroundTask(graceTaskId)
      graceTaskId = .invalid
    }

    let taskId = UIApplication.shared.beginBackgroundTask(withName: "media_backup.graceful_exit") { [weak self] in
      self?.endGraceTask(uploader: uploader, reason: "expired")
    }
    graceTaskId = taskId

    MediaBackupLogger.shared.info("Plugin",
                                  "Graceful-exit window opened",
                                  context: ["taskId": taskId.rawValue])

    // Nudge the uploader to pump pending items into URLSession upload tasks.
    // Those survive suspension if the session is background; otherwise
    // they'll at least complete if we're lucky within the grace window.
    uploader.triggerPump()

    let item = DispatchWorkItem { [weak self] in
      self?.endGraceTask(uploader: uploader, reason: "timer")
    }
    graceTimer = item
    // iOS gives ~30s; finish 5s early so we never get expiration-killed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: item)
  }

  private func endGraceTask(uploader: AssetUploader, reason: String) {
    graceTimer?.cancel()
    graceTimer = nil

    uploader.stop()

    if graceTaskId != .invalid {
      MediaBackupLogger.shared.info("Plugin",
                                    "Graceful-exit window closing",
                                    context: ["taskId": graceTaskId.rawValue,
                                              "reason": reason])
      UIApplication.shared.endBackgroundTask(graceTaskId)
      graceTaskId = .invalid
    }
  }

  // MARK: - BGProcessingTask (iOS 13+)

  private func registerBackgroundProcessingTask() {
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: Self.bgProcessingTaskIdentifier,
        using: nil
      ) { [weak self] task in
        guard let self, let processingTask = task as? BGProcessingTask else {
          task.setTaskCompleted(success: false)
          return
        }
        self.handleBackgroundProcessingTask(processingTask)
      }

      MediaBackupLogger.shared.info("Plugin",
                                    "Registered BGProcessingTask",
                                    context: ["identifier": Self.bgProcessingTaskIdentifier])
    }
  }

  private func scheduleBackgroundProcessingIfAvailable() {
    if #available(iOS 13.0, *) {
      let request = BGProcessingTaskRequest(identifier: Self.bgProcessingTaskIdentifier)
      request.requiresNetworkConnectivity = true
      request.requiresExternalPower = false
      // Minimum 15 minutes — iOS typically runs it later, often overnight
      // on charger + Wi-Fi.
      request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

      do {
        try BGTaskScheduler.shared.submit(request)
        MediaBackupLogger.shared.info("Plugin",
                                      "BGProcessingTask scheduled",
                                      context: ["earliest": "15min"])
      } catch BGTaskScheduler.Error.notPermitted {
        MediaBackupLogger.shared.warn("Plugin",
                                      "BGProcessingTask not permitted — check Info.plist BGTaskSchedulerPermittedIdentifiers")
      } catch {
        MediaBackupLogger.shared.warn("Plugin",
                                      "Failed to schedule BGProcessingTask",
                                      error: error)
      }
    }
  }

  @available(iOS 13.0, *)
  private func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
    // Always schedule the next run first, so a failure here doesn't
    // permanently stop us being called again.
    scheduleBackgroundProcessingIfAvailable()

    MediaBackupLogger.shared.info("Plugin",
                                  "BGProcessingTask started",
                                  context: ["identifier": task.identifier])

    let startedAt = Date()

    task.expirationHandler = { [weak self] in
      MediaBackupLogger.shared.warn("Plugin",
                                    "BGProcessingTask expiration — shutting down",
                                    context: ["ranSeconds": Date().timeIntervalSince(startedAt)])
      self?.withComponentsSilently { components in
        components.uploader.stop()
      }
      task.setTaskCompleted(success: false)
    }

    withComponentsSilently { components in
      // Treat BG task like a foreground launch for scanning + uploading
      // purposes: pick up new assets, re-run uploader.
      ensureFreshScan(components: components) {
        components.uploader.start()
        self.pollDrain(components: components, startedAt: startedAt, task: task)
      }
    }
  }

  @available(iOS 13.0, *)
  private func pollDrain(components: PluginComponents,
                         startedAt: Date,
                         task: BGProcessingTask) {
    // iOS typically grants BGProcessingTasks a few minutes; we cap at ~4min
    // to leave buffer for expiration cleanup.
    let maxSeconds: TimeInterval = 240

    workerQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self else { return }

      let counts = (try? components.database.statusCounts()) ?? [:]
      let pending = counts["pending"] ?? 0
      let uploading = counts["uploading"] ?? 0
      let elapsed = Date().timeIntervalSince(startedAt)

      if (pending == 0 && uploading == 0) || elapsed > maxSeconds {
        MediaBackupLogger.shared.info("Plugin",
                                      "BGProcessingTask completing",
                                      context: [
                                        "elapsed": Int(elapsed),
                                        "pending": pending,
                                        "uploading": uploading,
                                      ])
        components.uploader.stop()
        task.setTaskCompleted(success: true)
      } else {
        self.pollDrain(components: components, startedAt: startedAt, task: task)
      }
    }
  }

  private func withComponents(result: @escaping FlutterResult,
                              body: (PluginComponents) -> Void) {
    switch componentsResult {
    case .success(let components):
      body(components)
    case .failure(let error):
      result(FlutterError(code: "PLUGIN_INIT_FAILED",
                          message: error.localizedDescription,
                          details: nil))
    }
  }

  private func withComponentsSilently(body: (PluginComponents) -> Void) {
    if case .success(let components) = componentsResult {
      body(components)
    }
  }

  // MARK: - FlutterStreamHandler (upload events)

  public func onListen(withArguments arguments: Any?,
                       eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    withComponentsSilently { components in
      components.uploader.onUploadEvent = { [weak self] payload in
        DispatchQueue.main.async {
          self?.eventSink?(payload)
        }
      }
    }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    withComponentsSilently { components in
      components.uploader.onUploadEvent = nil
    }
    return nil
  }
}
