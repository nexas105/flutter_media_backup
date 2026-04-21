import Foundation
import Photos

private struct StagedAsset {
  let localIdentifier: String
  let mediaType: Int
  let tempFileURL: URL
  let fileBytes: Int64
}

private struct UploadTaskContext {
  let localIdentifier: String
  let mediaType: Int
  let tempFileURL: URL
  let tempFileBytes: Int64
  var responseBody: Data = Data()
}

final class AssetUploader: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
  private let database: AssetDatabase
  private let queue = DispatchQueue(label: "media_backup.asset_uploader", qos: .utility)

  private var session: URLSession?
  private var useBackgroundSession = false

  // Configuration
  private var provider: UploadProvider?
  private var maxInFlightBytes: Int64 = 300 * 1024 * 1024
  private var maxConcurrentUploads: Int = 6
  private var extractionConcurrency: Int = 2
  private var maxTempBytes: Int64 = 700 * 1024 * 1024
  private var isRunning = false
  private var uploadOrder: UploadOrder = .newestFirst
  private var downloadFromICloud: Bool = true

  // Extraction pool — assets being extracted from PHAsset to temp file
  private var extractingAssets: [String: Int] = [:]

  // Staged queue — extracted temp files ready for upload
  private var stagedQueue: [StagedAsset] = []
  private var stagedBytes: Int64 = 0

  // Active simple uploads (URLSession)
  private var activeTasks: [Int: UploadTaskContext] = [:]
  private var activeUploadBytes: Int64 = 0

  // Active resumable uploads (TUS / S3 multipart)
  private var activeResumable: [String: Any] = [:]  // localId → TUSUploader | S3MultipartUploader
  private var resumableTempFiles: [String: (url: URL, bytes: Int64)] = [:]

  private var retryPumpItem: DispatchWorkItem?

  /// Push-based event callback — wired to the FlutterEventChannel sink by the plugin.
  var onUploadEvent: (([String: Any]) -> Void)?

  init(database: AssetDatabase) {
    self.database = database
    super.init()
  }

  func configure(provider: UploadProvider,
                 imageConcurrency: Int,
                 videoConcurrency: Int,
                 maxTempBytes: Int64,
                 useBackgroundSession: Bool,
                 uploadOrder: UploadOrder,
                 downloadFromICloud: Bool,
                 maxInFlightBytes: Int64 = 300 * 1024 * 1024,
                 extractionConcurrency: Int = 2,
                 maxConcurrentUploads: Int = 6) {
    queue.async {
      self.provider = provider
      self.maxInFlightBytes = max(50 * 1024 * 1024, maxInFlightBytes)
      self.maxConcurrentUploads = max(1, maxConcurrentUploads)
      self.extractionConcurrency = max(1, extractionConcurrency)
      self.maxTempBytes = max(50 * 1024 * 1024, maxTempBytes)
      self.uploadOrder = uploadOrder
      self.downloadFromICloud = downloadFromICloud

      let sessionChanged = self.session == nil || self.useBackgroundSession != useBackgroundSession
      if sessionChanged {
        self.useBackgroundSession = useBackgroundSession
        self.rebuildSession()
      }

      MediaBackupLogger.shared.info("Uploader",
                                    "Configured",
                                    context: [
                                      "provider": provider.kind,
                                      "maxInFlightBytes": self.maxInFlightBytes,
                                      "maxConcurrentUploads": self.maxConcurrentUploads,
                                      "extractionConcurrency": self.extractionConcurrency,
                                      "maxTempBytes": self.maxTempBytes,
                                      "simulated": provider.simulatesUpload,
                                      "backgroundSession": self.useBackgroundSession,
                                      "uploadOrder": uploadOrder.rawValue,
                                      "downloadFromICloud": downloadFromICloud,
                                    ])
    }
  }

  private func rebuildSession() {
    session?.invalidateAndCancel()

    let config: URLSessionConfiguration
    if useBackgroundSession {
      let bundleId = Bundle.main.bundleIdentifier ?? "media_backup"
      config = URLSessionConfiguration.background(withIdentifier: "\(bundleId).media_backup.upload")
      config.sessionSendsLaunchEvents = true
    } else {
      config = URLSessionConfiguration.default
    }
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 600
    config.httpMaximumConnectionsPerHost = 6

    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  func start() {
    queue.async {
      self.isRunning = true

      do {
        try self.database.resetUploadingToPending()
      } catch {
        MediaBackupLogger.shared.error("Uploader",
                                       "Failed to reset uploading state",
                                       error: error)
      }

      self.pumpLocked()
    }
  }

  func stop() {
    queue.async {
      self.isRunning = false
    }
  }

  func cancelAllAndClear(completion: @escaping () -> Void) {
    queue.async {
      self.isRunning = false

      // Cancel resumable uploads
      for (_, uploader) in self.activeResumable {
        if let tus = uploader as? TUSUploader { tus.cancel() }
        if let s3 = uploader as? S3MultipartUploader { s3.cancel() }
      }
      for (_, info) in self.resumableTempFiles {
        self.removeTempFile(at: info.url)
      }
      self.activeResumable.removeAll()
      self.resumableTempFiles.removeAll()

      // Cancel simple uploads
      for (_, context) in self.activeTasks {
        self.removeTempFile(at: context.tempFileURL)
      }
      self.activeTasks.removeAll()
      self.activeUploadBytes = 0

      // Clear staged queue
      for staged in self.stagedQueue {
        self.removeTempFile(at: staged.tempFileURL)
      }
      self.stagedQueue.removeAll()
      self.stagedBytes = 0

      // Clear extracting state (extractions in flight will be ignored on callback)
      self.extractingAssets.removeAll()

      guard let session = self.session else {
        self.clearTempFolder()
        completion()
        return
      }
      session.getAllTasks { tasks in
        tasks.forEach { $0.cancel() }
        self.queue.async {
          self.clearTempFolder()
          completion()
        }
      }
    }
  }

  private func clearTempFolder() {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("media_backup_uploads", isDirectory: true)
    try? FileManager.default.removeItem(at: folder)
  }

  func triggerPump() {
    queue.async {
      self.pumpLocked()
    }
  }

  // MARK: - Total bytes tracking

  /// Total temp bytes on disk: staged + actively uploading + resumable.
  private var totalTempBytes: Int64 {
    stagedBytes + activeUploadBytes + resumableTempFiles.values.reduce(0) { $0 + $1.bytes }
  }

  /// Total active upload tasks (simple + resumable).
  private var totalActiveUploads: Int {
    activeTasks.count + activeResumable.count
  }

  // MARK: - Two-phase pump

  private func pumpLocked() {
    guard isRunning, provider != nil else { return }
    extractionPump()
    uploadPump()
  }

  /// Phase 1: Fill extraction slots from DB pending assets.
  private func extractionPump() {
    guard isRunning else { return }

    // How many extraction slots are free?
    let freeSlots = extractionConcurrency - extractingAssets.count
    guard freeSlots > 0 else { return }

    let needed = freeSlots + 2 // small buffer
    let pendingAssets: [PendingAsset]
    do {
      pendingAssets = try database.fetchPendingAssets(limit: needed, order: uploadOrder)
    } catch {
      MediaBackupLogger.shared.error("Uploader",
                                     "Failed to fetch pending assets",
                                     error: error)
      return
    }

    if pendingAssets.isEmpty && stagedQueue.isEmpty && activeTasks.isEmpty && activeResumable.isEmpty {
      if let waitSeconds = try? database.secondsUntilNextRetry(), waitSeconds > 0 {
        scheduleRetryPump(in: waitSeconds)
      }
      return
    }

    var started = 0
    for candidate in pendingAssets {
      guard started < freeSlots else { break }
      guard extractingAssets[candidate.localIdentifier] == nil else { continue }
      guard !stagedQueue.contains(where: { $0.localIdentifier == candidate.localIdentifier }) else { continue }
      guard !activeTasks.values.contains(where: { $0.localIdentifier == candidate.localIdentifier }) else { continue }
      guard activeResumable[candidate.localIdentifier] == nil else { continue }

      // Check temp storage budget (estimate: allow at least one extraction)
      if totalTempBytes > maxTempBytes && started > 0 { break }

      do {
        let wasReserved = try database.markUploading(localIdentifier: candidate.localIdentifier)
        guard wasReserved else { continue }
      } catch {
        MediaBackupLogger.shared.error("Uploader",
                                       "Failed to reserve asset",
                                       error: error,
                                       context: ["localIdentifier": candidate.localIdentifier])
        continue
      }

      extractingAssets[candidate.localIdentifier] = candidate.mediaType
      startExtraction(candidate)
      started += 1
    }
  }

  /// Phase 2: Move staged assets into active upload tasks, respecting byte budget.
  private func uploadPump() {
    guard isRunning, let provider else { return }

    while let next = stagedQueue.first {
      guard totalActiveUploads < maxConcurrentUploads else { break }
      guard activeUploadBytes + next.fileBytes <= maxInFlightBytes || activeTasks.isEmpty else { break }

      stagedQueue.removeFirst()
      stagedBytes -= next.fileBytes

      startUploadForStaged(next, provider: provider)
    }
  }

  // MARK: - Extraction

  private func startExtraction(_ pendingAsset: PendingAsset) {
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [pendingAsset.localIdentifier], options: nil)
    guard let asset = fetchResult.firstObject else {
      handleExtractionFailure(localIdentifier: pendingAsset.localIdentifier,
                              message: "Asset not found in photo library")
      return
    }

    writeAssetToTempFile(asset: asset) { [weak self] result in
      guard let self else { return }
      self.queue.async {
        // If we were cancelled or the extraction was cleared, discard result.
        guard self.extractingAssets.removeValue(forKey: pendingAsset.localIdentifier) != nil else {
          if case .success(let r) = result { self.removeTempFile(at: r.fileURL) }
          return
        }

        switch result {
        case .failure(let error):
          self.handleExtractionFailure(localIdentifier: pendingAsset.localIdentifier,
                                       message: error.localizedDescription)
        case .success(let tempResult):
          let staged = StagedAsset(localIdentifier: pendingAsset.localIdentifier,
                                   mediaType: pendingAsset.mediaType,
                                   tempFileURL: tempResult.fileURL,
                                   fileBytes: tempResult.fileBytes)
          self.stagedQueue.append(staged)
          self.stagedBytes += staged.fileBytes
        }

        self.pumpLocked()
      }
    }
  }

  private func handleExtractionFailure(localIdentifier: String, message: String) {
    extractingAssets.removeValue(forKey: localIdentifier)
    try? database.markFailed(localIdentifier: localIdentifier, errorMessage: message)
    pumpLocked()
  }

  // MARK: - Upload dispatch (simple vs resumable)

  private func startUploadForStaged(_ staged: StagedAsset, provider: UploadProvider) {
    // Simulated uploads
    if provider.simulatesUpload {
      runSimulatedUpload(staged: staged, provider: provider)
      return
    }

    // Check for resumable upload eligibility
    if let supabase = provider as? SupabaseUploadProvider,
       staged.fileBytes >= 50 * 1024 * 1024 {
      startTUSUpload(staged: staged, provider: supabase)
      return
    }

    if let s3 = provider as? S3UploadProvider,
       staged.fileBytes >= S3UploadProvider.resumableThreshold {
      startS3MultipartUpload(staged: staged, provider: s3)
      return
    }

    // Simple one-shot upload
    startSimpleUpload(staged: staged, provider: provider)
  }

  // MARK: - Simple upload (URLSession uploadTask)

  private func startSimpleUpload(staged: StagedAsset, provider: UploadProvider) {
    guard let request = provider.buildRequest(assetId: staged.localIdentifier,
                                              mediaType: staged.mediaType,
                                              fileURL: staged.tempFileURL,
                                              fileBytes: staged.fileBytes) else {
      MediaBackupLogger.shared.error("Uploader",
                                     "Provider returned no request",
                                     context: [
                                       "provider": provider.kind,
                                       "localIdentifier": staged.localIdentifier,
                                     ])
      try? database.markFailed(localIdentifier: staged.localIdentifier,
                               errorMessage: "Upload provider returned no request")
      removeTempFile(at: staged.tempFileURL)
      pumpLocked()
      return
    }

    guard let session else {
      removeTempFile(at: staged.tempFileURL)
      try? database.markPending(localIdentifier: staged.localIdentifier)
      return
    }

    MediaBackupLogger.shared.info("Uploader",
                                  "Starting upload",
                                  context: [
                                    "provider": provider.kind,
                                    "localIdentifier": staged.localIdentifier,
                                    "mediaType": staged.mediaType,
                                    "fileBytes": staged.fileBytes,
                                    "method": request.httpMethod ?? "",
                                    "url": request.url?.absoluteString ?? "",
                                  ])

    let task = session.uploadTask(with: request, fromFile: staged.tempFileURL)
    activeTasks[task.taskIdentifier] = UploadTaskContext(localIdentifier: staged.localIdentifier,
                                                         mediaType: staged.mediaType,
                                                         tempFileURL: staged.tempFileURL,
                                                         tempFileBytes: staged.fileBytes)
    activeUploadBytes += staged.fileBytes
    task.resume()

    onUploadEvent?([
      "event": "started",
      "localIdentifier": staged.localIdentifier,
      "mediaType": staged.mediaType,
      "fileBytes": staged.fileBytes,
    ])

    pumpLocked()
  }

  // MARK: - TUS resumable upload (Supabase)

  private func startTUSUpload(staged: StagedAsset, provider: SupabaseUploadProvider) {
    let tusEndpoint = "\(provider.projectUrl.absoluteString)/storage/v1/upload/resumable"
    guard let endpoint = URL(string: tusEndpoint) else {
      try? database.markFailed(localIdentifier: staged.localIdentifier,
                               errorMessage: "Invalid TUS endpoint")
      removeTempFile(at: staged.tempFileURL)
      pumpLocked()
      return
    }

    let key = sanitizeObjectKeyForResumable(staged.localIdentifier, prefix: provider.pathPrefix)
    let resolved = mimeType(for: staged.tempFileURL, fallback: provider.contentType)

    var authHeaders: [String: String] = [
      "Authorization": "Bearer \(provider.accessToken)",
      "apikey": provider.accessToken,
    ]
    if provider.upsert {
      authHeaders["x-upsert"] = "true"
    }

    let tus = TUSUploader(
      endpoint: endpoint,
      fileURL: staged.tempFileURL,
      totalBytes: staged.fileBytes,
      chunkSize: 6 * 1024 * 1024,
      authHeaders: authHeaders,
      metadata: [
        "bucketName": provider.bucket,
        "objectName": key,
        "contentType": resolved,
      ],
      queue: queue
    )

    activeResumable[staged.localIdentifier] = tus
    resumableTempFiles[staged.localIdentifier] = (url: staged.tempFileURL, bytes: staged.fileBytes)
    activeUploadBytes += staged.fileBytes

    tus.onProgress = { [weak self] sent, total in
      self?.onUploadEvent?([
        "event": "progress",
        "localIdentifier": staged.localIdentifier,
        "bytesSent": sent,
        "totalBytes": total,
      ])
      // Persist offset for crash recovery
      try? self?.database.saveResumeState(localIdentifier: staged.localIdentifier,
                                          resumeURL: tus.uploadURL?.absoluteString ?? "",
                                          offset: sent)
    }

    tus.onComplete = { [weak self] in
      self?.handleResumableComplete(localIdentifier: staged.localIdentifier)
    }

    tus.onError = { [weak self] message, retriable in
      self?.handleResumableFailure(localIdentifier: staged.localIdentifier,
                                   error: message, retriable: retriable)
    }

    MediaBackupLogger.shared.info("Uploader",
                                  "Starting TUS upload",
                                  context: [
                                    "localIdentifier": staged.localIdentifier,
                                    "fileBytes": staged.fileBytes,
                                  ])

    onUploadEvent?([
      "event": "started",
      "localIdentifier": staged.localIdentifier,
      "mediaType": staged.mediaType,
      "fileBytes": staged.fileBytes,
    ])

    // Check for existing resume state
    let resumeState = (try? database.loadResumeState(localIdentifier: staged.localIdentifier))
      ?? AssetDatabase.ResumeState(resumeURL: nil, resumeOffset: 0)

    tus.start(resumeURL: resumeState.resumeURL, resumeOffset: resumeState.resumeOffset)
  }

  // MARK: - S3 Multipart resumable upload

  private func startS3MultipartUpload(staged: StagedAsset, provider: S3UploadProvider) {
    let key = sanitizeObjectKeyForResumable(staged.localIdentifier, prefix: provider.pathPrefix)

    let uploader = S3MultipartUploader(
      provider: provider,
      objectKey: key,
      fileURL: staged.tempFileURL,
      totalBytes: staged.fileBytes,
      partSize: S3UploadProvider.defaultPartSize,
      queue: queue
    )

    activeResumable[staged.localIdentifier] = uploader
    resumableTempFiles[staged.localIdentifier] = (url: staged.tempFileURL, bytes: staged.fileBytes)
    activeUploadBytes += staged.fileBytes

    uploader.onProgress = { [weak self] sent, total in
      self?.onUploadEvent?([
        "event": "progress",
        "localIdentifier": staged.localIdentifier,
        "bytesSent": sent,
        "totalBytes": total,
      ])
    }

    uploader.onComplete = { [weak self] in
      self?.handleResumableComplete(localIdentifier: staged.localIdentifier)
    }

    uploader.onError = { [weak self] message, retriable in
      self?.handleResumableFailure(localIdentifier: staged.localIdentifier,
                                   error: message, retriable: retriable)
    }

    MediaBackupLogger.shared.info("Uploader",
                                  "Starting S3 multipart upload",
                                  context: [
                                    "localIdentifier": staged.localIdentifier,
                                    "fileBytes": staged.fileBytes,
                                  ])

    onUploadEvent?([
      "event": "started",
      "localIdentifier": staged.localIdentifier,
      "mediaType": staged.mediaType,
      "fileBytes": staged.fileBytes,
    ])

    uploader.start()
  }

  // MARK: - Resumable upload callbacks

  private func handleResumableComplete(localIdentifier: String) {
    activeResumable.removeValue(forKey: localIdentifier)
    if let info = resumableTempFiles.removeValue(forKey: localIdentifier) {
      activeUploadBytes = max(0, activeUploadBytes - info.bytes)
      removeTempFile(at: info.url)
    }
    try? database.clearResumeState(localIdentifier: localIdentifier)
    try? database.markDone(localIdentifier: localIdentifier)

    MediaBackupLogger.shared.info("Uploader",
                                  "Resumable upload completed",
                                  context: ["localIdentifier": localIdentifier])

    onUploadEvent?(["event": "completed", "localIdentifier": localIdentifier])
    emitStatusCountsEvent()
    pumpLocked()
  }

  private func handleResumableFailure(localIdentifier: String, error: String, retriable: Bool) {
    activeResumable.removeValue(forKey: localIdentifier)
    if let info = resumableTempFiles.removeValue(forKey: localIdentifier) {
      activeUploadBytes = max(0, activeUploadBytes - info.bytes)
      removeTempFile(at: info.url)
    }
    // Always clear resume state — temp file is gone, so stale resume URL
    // would try to resume against a new extraction with wrong offsets.
    try? database.clearResumeState(localIdentifier: localIdentifier)

    if retriable {
      let retryCount = (try? database.retryCount(localIdentifier: localIdentifier)) ?? 0
      let delay = Self.backoffSeconds(retryCount: retryCount)
      let nextAt = Date().timeIntervalSince1970 + delay
      try? database.scheduleRetry(localIdentifier: localIdentifier,
                                  nextRetryAt: nextAt,
                                  errorMessage: error)
      scheduleRetryPump(in: delay)
    } else {
      try? database.markFailed(localIdentifier: localIdentifier, errorMessage: error)
    }

    onUploadEvent?([
      "event": "failed",
      "localIdentifier": localIdentifier,
      "error": error,
      "willRetry": retriable,
    ])
    emitStatusCountsEvent()
    pumpLocked()
  }

  // MARK: - Simulated upload

  private func runSimulatedUpload(staged: StagedAsset, provider: UploadProvider) {
    MediaBackupLogger.shared.info("Uploader",
                                  "[SIMULATED] Starting upload",
                                  context: [
                                    "provider": provider.kind,
                                    "localIdentifier": staged.localIdentifier,
                                    "mediaType": staged.mediaType,
                                    "fileBytes": staged.fileBytes,
                                    "latencySeconds": provider.simulatedLatency,
                                  ])

    let failureRate = provider.simulatedFailureRate
    let delay = provider.simulatedLatency

    queue.asyncAfter(deadline: .now() + delay) {
      self.removeTempFile(at: staged.tempFileURL)

      let shouldFail = failureRate > 0 && Double.random(in: 0...1) < failureRate
      if shouldFail {
        MediaBackupLogger.shared.warn("Uploader",
                                      "[SIMULATED] Upload failed",
                                      context: ["localIdentifier": staged.localIdentifier])
        try? self.database.markFailed(localIdentifier: staged.localIdentifier,
                                      errorMessage: "Simulated upload failure")
        self.onUploadEvent?([
          "event": "failed",
          "localIdentifier": staged.localIdentifier,
          "error": "Simulated upload failure",
          "willRetry": false,
        ])
      } else {
        MediaBackupLogger.shared.info("Uploader",
                                      "[SIMULATED] Upload completed",
                                      context: ["localIdentifier": staged.localIdentifier])
        try? self.database.markDone(localIdentifier: staged.localIdentifier)
        self.onUploadEvent?([
          "event": "completed",
          "localIdentifier": staged.localIdentifier,
        ])
      }
      self.emitStatusCountsEvent()
      self.pumpLocked()
    }
  }

  // MARK: - Retry handling

  private static let retriableStatusCodes: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504]

  private static func isRetriable(statusCode: Int) -> Bool {
    if (500...599).contains(statusCode) { return true }
    return retriableStatusCodes.contains(statusCode)
  }

  static func backoffSeconds(retryCount: Int) -> Double {
    let base: Double = 5
    let attempt = min(retryCount, 12)
    let exp = min(3600.0, base * pow(2.0, Double(attempt)))
    let jitter = Double.random(in: 0...(exp * 0.2))
    return exp + jitter
  }

  private enum FailureLogLevel { case warn, error }

  private func handleUploadFailure(context: UploadTaskContext,
                                   statusCode: Int,
                                   retriable: Bool,
                                   reason: String,
                                   bodySnippet: String,
                                   bytesSent: Int64,
                                   level: FailureLogLevel) {
    var logContext: [String: Any] = [
      "localIdentifier": context.localIdentifier,
      "statusCode": statusCode,
      "bytesSent": bytesSent,
      "retriable": retriable,
    ]
    if !bodySnippet.isEmpty {
      logContext["responseBody"] = bodySnippet
    }

    if retriable {
      let retryCount = (try? database.retryCount(localIdentifier: context.localIdentifier)) ?? 0
      let delay = Self.backoffSeconds(retryCount: retryCount)
      let nextAt = Date().timeIntervalSince1970 + delay
      logContext["retryIn"] = Int(delay)

      switch level {
      case .warn:
        MediaBackupLogger.shared.warn("Uploader", "Upload failed — will retry", context: logContext)
      case .error:
        MediaBackupLogger.shared.error("Uploader", "Upload errored — will retry", context: logContext)
      }

      try? database.scheduleRetry(localIdentifier: context.localIdentifier,
                                  nextRetryAt: nextAt,
                                  errorMessage: bodySnippet.isEmpty ? reason : "\(reason): \(bodySnippet)")
      scheduleRetryPump(in: delay)
    } else {
      MediaBackupLogger.shared.warn("Uploader", "Upload failed — permanent", context: logContext)
      try? database.markFailed(localIdentifier: context.localIdentifier,
                               errorMessage: bodySnippet.isEmpty ? reason : "\(reason): \(bodySnippet)")
    }
  }

  private func scheduleRetryPump(in delay: TimeInterval) {
    retryPumpItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.queue.async { self?.pumpLocked() }
    }
    retryPumpItem = item
    let bounded = max(0.25, delay + 0.25)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bounded, execute: item)
  }

  // MARK: - URLSession delegates (simple uploads)

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    guard let identifier = session.configuration.identifier else { return }
    DispatchQueue.main.async {
      if let handler = MediaBackupPlugin.drainBackgroundHandler(identifier: identifier) {
        MediaBackupLogger.shared.info("Uploader",
                                      "Invoked background completion handler",
                                      context: ["identifier": identifier])
        handler()
      }
    }
  }

  private static let maxResponseBodyBytes = 8 * 1024

  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64,
                  totalBytesExpectedToSend: Int64) {
    queue.async {
      guard let context = self.activeTasks[task.taskIdentifier] else { return }
      self.onUploadEvent?([
        "event": "progress",
        "localIdentifier": context.localIdentifier,
        "bytesSent": totalBytesSent,
        "totalBytes": totalBytesExpectedToSend,
      ])
    }
  }

  func urlSession(_ session: URLSession,
                  dataTask: URLSessionDataTask,
                  didReceive data: Data) {
    queue.async {
      if var context = self.activeTasks[dataTask.taskIdentifier] {
        let remaining = Self.maxResponseBodyBytes - context.responseBody.count
        if remaining > 0 {
          context.responseBody.append(data.prefix(remaining))
          self.activeTasks[dataTask.taskIdentifier] = context
        }
      }
    }
  }

  func urlSession(_ session: URLSession,
                  task: URLSessionTask,
                  didCompleteWithError error: Error?) {
    queue.async {
      guard let context = self.activeTasks.removeValue(forKey: task.taskIdentifier) else {
        return
      }

      self.activeUploadBytes = max(0, self.activeUploadBytes - context.tempFileBytes)
      self.removeTempFile(at: context.tempFileURL)

      let metrics = task.progress
      let bytesSent = task.countOfBytesSent
      let response = task.response as? HTTPURLResponse
      let statusCode = response?.statusCode ?? -1
      let responseBody = String(data: context.responseBody, encoding: .utf8) ?? ""

      if let error {
        self.handleUploadFailure(context: context,
                                 statusCode: -1,
                                 retriable: true,
                                 reason: error.localizedDescription,
                                 bodySnippet: "",
                                 bytesSent: bytesSent,
                                 level: .error)
        self.emitFailedEvent(context: context, error: error.localizedDescription, willRetry: true)
      } else if (200...299).contains(statusCode) {
        MediaBackupLogger.shared.info("Uploader",
                                      "Upload completed",
                                      context: [
                                        "localIdentifier": context.localIdentifier,
                                        "statusCode": statusCode,
                                        "bytesSent": bytesSent,
                                        "progress": metrics.fractionCompleted,
                                      ])
        try? self.database.markDone(localIdentifier: context.localIdentifier)
        self.onUploadEvent?([
          "event": "completed",
          "localIdentifier": context.localIdentifier,
        ])
      } else {
        let bodySnippet = responseBody.count > 400
          ? String(responseBody.prefix(400)) + "…"
          : responseBody
        let retriable = Self.isRetriable(statusCode: statusCode)
        self.handleUploadFailure(context: context,
                                 statusCode: statusCode,
                                 retriable: retriable,
                                 reason: "HTTP \(statusCode)",
                                 bodySnippet: bodySnippet,
                                 bytesSent: bytesSent,
                                 level: .warn)
        self.emitFailedEvent(context: context,
                             error: "HTTP \(statusCode)",
                             willRetry: retriable)
      }

      self.emitStatusCountsEvent()
      self.pumpLocked()
    }
  }

  // MARK: - PHAsset extraction

  private func writeAssetToTempFile(asset: PHAsset,
                                    completion: @escaping (Result<(fileURL: URL, fileBytes: Int64), Error>) -> Void) {
    guard let resource = preferredResource(for: asset) else {
      completion(.failure(NSError(domain: "media_backup",
                                  code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "No asset resource available"])))
      return
    }

    do {
      let folder = try tempFolder()
      let tempFileURL = folder.appendingPathComponent(tempFilename(for: resource), isDirectory: false)

      if FileManager.default.fileExists(atPath: tempFileURL.path) {
        try FileManager.default.removeItem(at: tempFileURL)
      }

      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = self.downloadFromICloud

      PHAssetResourceManager.default().writeData(for: resource,
                                                 toFile: tempFileURL,
                                                 options: options) { error in
        if let error {
          completion(.failure(error))
          return
        }

        do {
          let fileSize = try self.fileSize(at: tempFileURL)
          completion(.success((fileURL: tempFileURL, fileBytes: fileSize)))
        } catch {
          completion(.failure(error))
        }
      }
    } catch {
      completion(.failure(error))
    }
  }

  private func preferredResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    if asset.mediaType == .video {
      return resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video }) ?? resources.first
    }
    if asset.mediaType == .image {
      return resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo }) ?? resources.first
    }
    return resources.first
  }

  private func tempFolder() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("media_backup_uploads", isDirectory: true)
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory,
                                              withIntermediateDirectories: true,
                                              attributes: nil)
    }
    return directory
  }

  private func tempFilename(for resource: PHAssetResource) -> String {
    let original = resource.originalFilename
    let ext = (original as NSString).pathExtension
    if ext.isEmpty {
      return "\(UUID().uuidString).bin"
    }
    return "\(UUID().uuidString).\(ext)"
  }

  private func fileSize(at url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values.fileSize ?? 0)
  }

  private func removeTempFile(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Helpers

  private func sanitizeObjectKeyForResumable(_ assetId: String, prefix: String?) -> String {
    let safeAssetId = assetId.replacingOccurrences(of: "/", with: "_")
    let trimmedPrefix = (prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if trimmedPrefix.isEmpty { return safeAssetId }
    return "\(trimmedPrefix)/\(safeAssetId)"
  }

  private func emitFailedEvent(context: UploadTaskContext, error: String, willRetry: Bool) {
    onUploadEvent?([
      "event": "failed",
      "localIdentifier": context.localIdentifier,
      "error": error,
      "willRetry": willRetry,
    ])
  }

  private func emitStatusCountsEvent() {
    guard let counts = try? database.statusCounts() else { return }
    onUploadEvent?([
      "event": "statusCounts",
      "pending": counts[UploadStatus.pending.rawValue] ?? 0,
      "uploading": counts[UploadStatus.uploading.rawValue] ?? 0,
      "done": counts[UploadStatus.done.rawValue] ?? 0,
      "failed": counts[UploadStatus.failed.rawValue] ?? 0,
    ])
  }
}
