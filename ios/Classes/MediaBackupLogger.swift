import Foundation
import os.log

enum MediaBackupLogLevel: Int, Comparable {
  case trace = 0
  case debug = 1
  case info = 2
  case warn = 3
  case error = 4

  var label: String {
    switch self {
    case .trace: return "TRACE"
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .warn: return "WARN"
    case .error: return "ERROR"
    }
  }

  var osLogType: OSLogType {
    switch self {
    case .trace, .debug: return .debug
    case .info: return .info
    case .warn: return .default
    case .error: return .error
    }
  }

  static func < (lhs: MediaBackupLogLevel, rhs: MediaBackupLogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

final class MediaBackupLogger {
  static let shared = MediaBackupLogger()

  private let queue = DispatchQueue(label: "media_backup.logger", qos: .utility)
  private let osLog: OSLog
  private var minLevel: MediaBackupLogLevel = .info
  private var fileHandle: FileHandle?
  private var logFileURL: URL?
  private var maxFileBytes: Int = 1_048_576
  private var fileLoggingEnabled: Bool = true
  private var consoleLoggingEnabled: Bool = true

  /// Optional sink set by the plugin to forward each log line back to Dart
  /// via the method channel — the only reliable way to make native logs
  /// appear in `flutter run` console alongside Dart logs.
  var lineEmitter: ((String) -> Void)?
  private let dateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private init() {
    self.osLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "media_backup",
                       category: "media_backup")
  }

  func configure(minLevel: MediaBackupLogLevel,
                 fileLoggingEnabled: Bool,
                 consoleLoggingEnabled: Bool,
                 maxFileBytes: Int) {
    queue.async {
      self.minLevel = minLevel
      self.fileLoggingEnabled = fileLoggingEnabled
      self.consoleLoggingEnabled = consoleLoggingEnabled
      self.maxFileBytes = max(64 * 1024, maxFileBytes)

      if fileLoggingEnabled {
        self.openLogFile()
      } else {
        self.closeLogFile()
      }
    }
  }

  func currentLogFileURL() -> URL? {
    queue.sync { logFileURL }
  }

  func log(_ level: MediaBackupLogLevel,
           tag: String,
           message: String,
           error: Error? = nil,
           context: [String: Any]? = nil,
           file: String = #fileID,
           line: Int = #line) {
    guard level >= minLevel else { return }

    queue.async {
      let timestamp = self.dateFormatter.string(from: Date())
      var payload = "\(timestamp) [\(level.label)] \(tag): \(message)"
      if let context, !context.isEmpty {
        if let data = try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
          payload += " \(json)"
        }
      }
      if let error {
        payload += " | error=\(error.localizedDescription)"
      }
      #if DEBUG
      payload += " (\(file):\(line))"
      #endif

      os_log("%{public}@", log: self.osLog, type: level.osLogType, payload)

      if self.consoleLoggingEnabled {
        // Bridge to Dart so the line shows up in `flutter run` console.
        // Falling back to print for OSLog/Xcode visibility regardless.
        self.lineEmitter?(payload)
        print(payload)
      }

      if self.fileLoggingEnabled {
        self.writeLine(payload)
      }
    }
  }

  func trace(_ tag: String, _ message: String, context: [String: Any]? = nil) {
    log(.trace, tag: tag, message: message, context: context)
  }

  func debug(_ tag: String, _ message: String, context: [String: Any]? = nil) {
    log(.debug, tag: tag, message: message, context: context)
  }

  func info(_ tag: String, _ message: String, context: [String: Any]? = nil) {
    log(.info, tag: tag, message: message, context: context)
  }

  func warn(_ tag: String, _ message: String, error: Error? = nil, context: [String: Any]? = nil) {
    log(.warn, tag: tag, message: message, error: error, context: context)
  }

  func error(_ tag: String, _ message: String, error: Error? = nil, context: [String: Any]? = nil) {
    log(.error, tag: tag, message: message, error: error, context: context)
  }

  private func openLogFile() {
    do {
      let fileManager = FileManager.default
      let appSupport = try fileManager.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
      let folder = appSupport.appendingPathComponent("media_backup/logs", isDirectory: true)
      if !fileManager.fileExists(atPath: folder.path) {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
      }

      let url = folder.appendingPathComponent("media_backup.log", isDirectory: false)
      try rotateIfNeeded(at: url)

      if !fileManager.fileExists(atPath: url.path) {
        fileManager.createFile(atPath: url.path, contents: nil)
      }

      fileHandle = try FileHandle(forWritingTo: url)
      fileHandle?.seekToEndOfFile()
      logFileURL = url
    } catch {
      os_log("Failed to open log file: %{public}@",
             log: osLog,
             type: .error,
             error.localizedDescription)
      fileLoggingEnabled = false
    }
  }

  private func rotateIfNeeded(at url: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return }

    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber else { return }

    if size.intValue > maxFileBytes {
      let rotated = url.deletingLastPathComponent().appendingPathComponent("media_backup.1.log")
      if fileManager.fileExists(atPath: rotated.path) {
        try fileManager.removeItem(at: rotated)
      }
      try fileManager.moveItem(at: url, to: rotated)
    }
  }

  private func closeLogFile() {
    try? fileHandle?.close()
    fileHandle = nil
    logFileURL = nil
  }

  private func writeLine(_ line: String) {
    guard let handle = fileHandle else { return }
    let bytes = (line + "\n").data(using: .utf8) ?? Data()
    do {
      if #available(iOS 13.4, *) {
        try handle.write(contentsOf: bytes)
      } else {
        handle.write(bytes)
      }
    } catch {
      os_log("Log file write failed: %{public}@",
             log: osLog,
             type: .error,
             error.localizedDescription)
    }
  }
}
