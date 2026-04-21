import Foundation
import Photos
import SQLite3

enum AssetDatabaseError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case .message(let message):
      return message
    }
  }
}

enum UploadStatus: String {
  case pending
  case uploading
  case done
  case failed
}

struct PendingAsset {
  let localIdentifier: String
  let mediaType: Int
}

struct ScanState {
  let lastCompletedAt: Double?
  let cursorCreationTs: Double?
}

enum UploadOrder: String {
  case oldestFirst = "oldest_first"
  case newestFirst = "newest_first"
  case any = "any"

  var orderByClause: String {
    switch self {
    case .oldestFirst: return "ORDER BY ifnull(creation_ts, 0) ASC, local_id ASC"
    case .newestFirst: return "ORDER BY ifnull(creation_ts, 0) DESC, local_id DESC"
    case .any:         return ""
    }
  }
}

struct AssetRow {
  let localIdentifier: String
  let mediaType: Int
  let mediaSubtypes: Int
  let creationTimestamp: Double?
  let modificationTimestamp: Double?
  let duration: Double
  let pixelWidth: Int
  let pixelHeight: Int
  let isFavorite: Bool
  let isHidden: Bool
  let sourceType: Int

  init(asset: PHAsset) {
    localIdentifier = asset.localIdentifier
    mediaType = asset.mediaType.rawValue
    mediaSubtypes = Int(asset.mediaSubtypes.rawValue)
    creationTimestamp = asset.creationDate?.timeIntervalSince1970
    modificationTimestamp = asset.modificationDate?.timeIntervalSince1970
    duration = asset.duration
    pixelWidth = asset.pixelWidth
    pixelHeight = asset.pixelHeight
    isFavorite = asset.isFavorite
    isHidden = asset.isHidden
    sourceType = Int(asset.sourceType.rawValue)
  }
}

final class AssetDatabase {
  private var db: OpaquePointer?
  private let lock = NSLock()
  let path: String

  init(path: String? = nil) throws {
    self.path = try path ?? Self.defaultPath()
    try open()
    try createSchema()
    try migrateUploadColumnsIfNeeded()
    try createScanStateSchema()
  }

  deinit {
    lock.lock()
    if db != nil {
      sqlite3_close(db)
    }
    lock.unlock()
  }

  func upsert(rows: [AssetRow]) throws {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      if rows.isEmpty {
        return
      }

      try execute(sql: "BEGIN TRANSACTION;")

      let sql = """
        INSERT INTO assets (
          local_id,
          media_type,
          media_subtypes,
          creation_ts,
          modification_ts,
          duration,
          pixel_width,
          pixel_height,
          is_favorite,
          is_hidden,
          source_type,
          upload_status,
          retry_count,
          last_error,
          uploaded_at,
          updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, NULL, NULL, ?)
        ON CONFLICT(local_id) DO UPDATE SET
          media_type=excluded.media_type,
          media_subtypes=excluded.media_subtypes,
          creation_ts=excluded.creation_ts,
          modification_ts=excluded.modification_ts,
          duration=excluded.duration,
          pixel_width=excluded.pixel_width,
          pixel_height=excluded.pixel_height,
          is_favorite=excluded.is_favorite,
          is_hidden=excluded.is_hidden,
          source_type=excluded.source_type,
          upload_status=CASE
            WHEN ifnull(assets.modification_ts, -1) <> ifnull(excluded.modification_ts, -1)
              OR ifnull(assets.creation_ts, -1) <> ifnull(excluded.creation_ts, -1)
              OR assets.pixel_width <> excluded.pixel_width
              OR assets.pixel_height <> excluded.pixel_height
              OR assets.media_type <> excluded.media_type
              OR assets.duration <> excluded.duration
            THEN 'pending'
            ELSE assets.upload_status
          END,
          retry_count=CASE
            WHEN ifnull(assets.modification_ts, -1) <> ifnull(excluded.modification_ts, -1)
              OR ifnull(assets.creation_ts, -1) <> ifnull(excluded.creation_ts, -1)
              OR assets.pixel_width <> excluded.pixel_width
              OR assets.pixel_height <> excluded.pixel_height
              OR assets.media_type <> excluded.media_type
              OR assets.duration <> excluded.duration
            THEN 0
            ELSE assets.retry_count
          END,
          last_error=CASE
            WHEN ifnull(assets.modification_ts, -1) <> ifnull(excluded.modification_ts, -1)
              OR ifnull(assets.creation_ts, -1) <> ifnull(excluded.creation_ts, -1)
              OR assets.pixel_width <> excluded.pixel_width
              OR assets.pixel_height <> excluded.pixel_height
              OR assets.media_type <> excluded.media_type
              OR assets.duration <> excluded.duration
            THEN NULL
            ELSE assets.last_error
          END,
          uploaded_at=CASE
            WHEN ifnull(assets.modification_ts, -1) <> ifnull(excluded.modification_ts, -1)
              OR ifnull(assets.creation_ts, -1) <> ifnull(excluded.creation_ts, -1)
              OR assets.pixel_width <> excluded.pixel_width
              OR assets.pixel_height <> excluded.pixel_height
              OR assets.media_type <> excluded.media_type
              OR assets.duration <> excluded.duration
            THEN NULL
            ELSE assets.uploaded_at
          END,
          updated_at=excluded.updated_at;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        try? execute(sql: "ROLLBACK;")
        throw AssetDatabaseError.message("Failed to prepare upsert statement: \(message)")
      }

      defer {
        sqlite3_finalize(statement)
      }

      do {
        let updatedAt = Date().timeIntervalSince1970
        for row in rows {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)

          bindText(statement, index: 1, value: row.localIdentifier)
          sqlite3_bind_int64(statement, 2, sqlite3_int64(row.mediaType))
          sqlite3_bind_int64(statement, 3, sqlite3_int64(row.mediaSubtypes))
          bindOptionalDouble(statement, index: 4, value: row.creationTimestamp)
          bindOptionalDouble(statement, index: 5, value: row.modificationTimestamp)
          sqlite3_bind_double(statement, 6, row.duration)
          sqlite3_bind_int64(statement, 7, sqlite3_int64(row.pixelWidth))
          sqlite3_bind_int64(statement, 8, sqlite3_int64(row.pixelHeight))
          sqlite3_bind_int(statement, 9, row.isFavorite ? 1 : 0)
          sqlite3_bind_int(statement, 10, row.isHidden ? 1 : 0)
          sqlite3_bind_int64(statement, 11, sqlite3_int64(row.sourceType))
          sqlite3_bind_double(statement, 12, updatedAt)

          if sqlite3_step(statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw AssetDatabaseError.message("Failed to upsert row: \(message)")
          }
        }

        try execute(sql: "COMMIT;")
      } catch {
        try? execute(sql: "ROLLBACK;")
        throw error
      }
    }
  }

  func remove(localIdentifiers: [String]) throws {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      if localIdentifiers.isEmpty {
        return
      }

      try execute(sql: "BEGIN TRANSACTION;")

      let sql = "DELETE FROM assets WHERE local_id = ?;"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        try? execute(sql: "ROLLBACK;")
        throw AssetDatabaseError.message("Failed to prepare delete statement: \(message)")
      }

      defer {
        sqlite3_finalize(statement)
      }

      do {
        for localIdentifier in localIdentifiers {
          sqlite3_reset(statement)
          sqlite3_clear_bindings(statement)
          bindText(statement, index: 1, value: localIdentifier)

          if sqlite3_step(statement) != SQLITE_DONE {
            let message = String(cString: sqlite3_errmsg(db))
            throw AssetDatabaseError.message("Failed to delete row: \(message)")
          }
        }

        try execute(sql: "COMMIT;")
      } catch {
        try? execute(sql: "ROLLBACK;")
        throw error
      }
    }
  }

  func fetchPendingAssets(limit: Int, order: UploadOrder = .newestFirst) throws -> [PendingAsset] {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      let now = Date().timeIntervalSince1970
      let sql = """
        SELECT local_id, media_type
        FROM assets
        WHERE upload_status = 'pending'
          AND (next_retry_at IS NULL OR next_retry_at <= ?)
        \(order.orderByClause)
        LIMIT ?;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        throw AssetDatabaseError.message("Failed to prepare pending query: \(message)")
      }

      defer {
        sqlite3_finalize(statement)
      }

      sqlite3_bind_double(statement, 1, now)
      sqlite3_bind_int64(statement, 2, sqlite3_int64(max(1, limit)))

      var result: [PendingAsset] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let cString = sqlite3_column_text(statement, 0) else {
          continue
        }

        let localIdentifier = String(cString: cString)
        let mediaType = Int(sqlite3_column_int64(statement, 1))
        result.append(PendingAsset(localIdentifier: localIdentifier, mediaType: mediaType))
      }

      return result
    }
  }

  func markUploading(localIdentifier: String) throws -> Bool {
    try withLock {
      let changedRows = try executeUpdate(
        sql: "UPDATE assets SET upload_status = 'uploading', last_error = NULL WHERE local_id = ? AND upload_status = 'pending';",
        bind: { statement in
          self.bindText(statement, index: 1, value: localIdentifier)
        }
      )

      return changedRows > 0
    }
  }

  func setFileInfo(localIdentifier: String, fileBytes: Int64, fileName: String?) throws {
    try withLock {
      _ = try executeUpdate(
        sql: "UPDATE assets SET file_bytes = ?, file_name = coalesce(?, file_name) WHERE local_id = ?;",
        bind: { statement in
          sqlite3_bind_int64(statement, 1, sqlite3_int64(fileBytes))
          if let fileName {
            self.bindText(statement, index: 2, value: fileName)
          } else {
            sqlite3_bind_null(statement, 2)
          }
          self.bindText(statement, index: 3, value: localIdentifier)
        }
      )
    }
  }

  func markPending(localIdentifier: String) throws {
    try withLock {
      _ = try executeUpdate(
        sql: "UPDATE assets SET upload_status = 'pending' WHERE local_id = ?;",
        bind: { statement in
          self.bindText(statement, index: 1, value: localIdentifier)
        }
      )
    }
  }

  func markDone(localIdentifier: String, remotePath: String? = nil) throws {
    try withLock {
      let uploadedAt = Date().timeIntervalSince1970
      _ = try executeUpdate(
        sql: "UPDATE assets SET upload_status = 'done', uploaded_at = ?, last_error = NULL, remote_path = coalesce(?, remote_path) WHERE local_id = ?;",
        bind: { statement in
          sqlite3_bind_double(statement, 1, uploadedAt)
          if let remotePath {
            self.bindText(statement, index: 2, value: remotePath)
          } else {
            sqlite3_bind_null(statement, 2)
          }
          self.bindText(statement, index: 3, value: localIdentifier)
        }
      )
    }
  }

  func markFailed(localIdentifier: String, errorMessage: String?) throws {
    try withLock {
      _ = try executeUpdate(
        sql: "UPDATE assets SET upload_status = 'failed', retry_count = retry_count + 1, last_error = ?, next_retry_at = NULL WHERE local_id = ?;",
        bind: { statement in
          if let errorMessage {
            self.bindText(statement, index: 1, value: errorMessage)
          } else {
            sqlite3_bind_null(statement, 1)
          }
          self.bindText(statement, index: 2, value: localIdentifier)
        }
      )
    }
  }

  /// Marks the asset as retry-scheduled: it stays in `pending`, retry_count is
  /// incremented, and `next_retry_at` is set so the uploader's pump will pick
  /// it up after the backoff window.
  func scheduleRetry(localIdentifier: String,
                     nextRetryAt: Double,
                     errorMessage: String?) throws {
    try withLock {
      _ = try executeUpdate(
        sql: """
          UPDATE assets SET
            upload_status = 'pending',
            retry_count = retry_count + 1,
            last_error = ?,
            next_retry_at = ?
          WHERE local_id = ?;
        """,
        bind: { statement in
          if let errorMessage {
            self.bindText(statement, index: 1, value: errorMessage)
          } else {
            sqlite3_bind_null(statement, 1)
          }
          sqlite3_bind_double(statement, 2, nextRetryAt)
          self.bindText(statement, index: 3, value: localIdentifier)
        }
      )
    }
  }

  /// Returns the seconds until the earliest scheduled retry, or `nil` if
  /// nothing is waiting.
  func secondsUntilNextRetry() throws -> Double? {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      let sql = """
        SELECT MIN(next_retry_at) FROM assets
        WHERE upload_status = 'pending' AND next_retry_at IS NOT NULL;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        return nil
      }
      defer { sqlite3_finalize(statement) }

      if sqlite3_step(statement) == SQLITE_ROW {
        if sqlite3_column_type(statement, 0) == SQLITE_NULL {
          return nil
        }
        let ts = sqlite3_column_double(statement, 0)
        let diff = ts - Date().timeIntervalSince1970
        return max(0, diff)
      }
      return nil
    }
  }

  func retryCount(localIdentifier: String) throws -> Int {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }
      let sql = "SELECT retry_count FROM assets WHERE local_id = ?;"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        return 0
      }
      defer { sqlite3_finalize(statement) }
      bindText(statement, index: 1, value: localIdentifier)
      if sqlite3_step(statement) == SQLITE_ROW {
        return Int(sqlite3_column_int64(statement, 0))
      }
      return 0
    }
  }

  func resetUploadingToPending() throws {
    try withLock {
      _ = try executeUpdate(sql: "UPDATE assets SET upload_status = 'pending' WHERE upload_status = 'uploading';")
    }
  }

  func saveResumeState(localIdentifier: String, resumeURL: String, offset: Int64) throws {
    try withLock {
      _ = try executeUpdate(
        sql: "UPDATE assets SET resume_url = ?, resume_offset = ? WHERE local_id = ?;",
        bind: { statement in
          self.bindText(statement, index: 1, value: resumeURL)
          sqlite3_bind_int64(statement, 2, sqlite3_int64(offset))
          self.bindText(statement, index: 3, value: localIdentifier)
        }
      )
    }
  }

  func clearResumeState(localIdentifier: String) throws {
    try withLock {
      _ = try executeUpdate(
        sql: "UPDATE assets SET resume_url = NULL, resume_offset = 0 WHERE local_id = ?;",
        bind: { statement in
          self.bindText(statement, index: 1, value: localIdentifier)
        }
      )
    }
  }

  struct ResumeState {
    let resumeURL: String?
    let resumeOffset: Int64
  }

  func loadResumeState(localIdentifier: String) throws -> ResumeState {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }
      let sql = "SELECT resume_url, resume_offset FROM assets WHERE local_id = ?;"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        return ResumeState(resumeURL: nil, resumeOffset: 0)
      }
      defer { sqlite3_finalize(statement) }
      bindText(statement, index: 1, value: localIdentifier)
      if sqlite3_step(statement) == SQLITE_ROW {
        let url: String? = sqlite3_column_type(statement, 0) == SQLITE_NULL
          ? nil
          : String(cString: sqlite3_column_text(statement, 0))
        let offset = sqlite3_column_int64(statement, 1)
        return ResumeState(resumeURL: url, resumeOffset: Int64(offset))
      }
      return ResumeState(resumeURL: nil, resumeOffset: 0)
    }
  }

  func retryFailed() throws -> Int {
    try withLock {
      try executeUpdate(sql: """
        UPDATE assets SET
          upload_status = 'pending',
          last_error = NULL,
          retry_count = 0,
          next_retry_at = NULL
        WHERE upload_status = 'failed';
      """)
    }
  }

  func reset() throws {
    try withLock {
      try execute(sql: "BEGIN TRANSACTION;")
      do {
        try execute(sql: "DELETE FROM assets;")
        try execute(sql: "DELETE FROM scan_state;")
        try execute(sql: "COMMIT;")
      } catch {
        try? execute(sql: "ROLLBACK;")
        throw error
      }
    }
  }

  func statusCounts() throws -> [String: Int] {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      var statement: OpaquePointer?
      let sql = "SELECT upload_status, COUNT(*) FROM assets GROUP BY upload_status;"
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        throw AssetDatabaseError.message("Failed to prepare counts query: \(message)")
      }

      defer {
        sqlite3_finalize(statement)
      }

      var counts: [String: Int] = [
        UploadStatus.pending.rawValue: 0,
        UploadStatus.uploading.rawValue: 0,
        UploadStatus.done.rawValue: 0,
        UploadStatus.failed.rawValue: 0,
      ]

      while sqlite3_step(statement) == SQLITE_ROW {
        guard let statusCString = sqlite3_column_text(statement, 0) else {
          continue
        }

        let status = String(cString: statusCString)
        counts[status] = Int(sqlite3_column_int64(statement, 1))
      }

      return counts
    }
  }

  // MARK: - Asset query API (for building UIs)

  func queryAssets(status: String?,
                   mediaType: Int?,
                   limit: Int,
                   offset: Int,
                   orderBy: String) throws -> [[String: Any]] {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      var clauses: [String] = []
      if status != nil { clauses.append("upload_status = ?1") }
      if mediaType != nil { clauses.append("media_type = ?2") }
      let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"

      let sql = """
        SELECT local_id, media_type, media_subtypes, creation_ts, modification_ts,
               duration, pixel_width, pixel_height, is_favorite, is_hidden,
               source_type, upload_status, retry_count, last_error, uploaded_at,
               remote_path, file_bytes, file_name
        FROM assets
        \(whereClause)
        \(orderBy)
        LIMIT ?3 OFFSET ?4;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        throw AssetDatabaseError.message("Failed to prepare query: \(message)")
      }
      defer { sqlite3_finalize(statement) }

      if let status { bindText(statement, index: 1, value: status) }
      if let mediaType { sqlite3_bind_int64(statement, 2, sqlite3_int64(mediaType)) }
      sqlite3_bind_int64(statement, 3, sqlite3_int64(max(1, limit)))
      sqlite3_bind_int64(statement, 4, sqlite3_int64(max(0, offset)))

      var rows: [[String: Any]] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        var row: [String: Any] = [:]
        row["localIdentifier"] = readString(statement, col: 0) ?? ""
        row["mediaType"] = Int(sqlite3_column_int64(statement, 1))
        row["mediaSubtypes"] = Int(sqlite3_column_int64(statement, 2))
        row["creationTimestamp"] = readOptionalDouble(statement, col: 3)
        row["modificationTimestamp"] = readOptionalDouble(statement, col: 4)
        row["duration"] = sqlite3_column_double(statement, 5)
        row["pixelWidth"] = Int(sqlite3_column_int64(statement, 6))
        row["pixelHeight"] = Int(sqlite3_column_int64(statement, 7))
        row["isFavorite"] = sqlite3_column_int(statement, 8) != 0
        row["isHidden"] = sqlite3_column_int(statement, 9) != 0
        row["sourceType"] = Int(sqlite3_column_int64(statement, 10))
        row["uploadStatus"] = readString(statement, col: 11) ?? "pending"
        row["retryCount"] = Int(sqlite3_column_int64(statement, 12))
        row["lastError"] = readString(statement, col: 13)
        row["uploadedAt"] = readOptionalDouble(statement, col: 14)
        row["remotePath"] = readString(statement, col: 15)
        row["fileBytes"] = sqlite3_column_type(statement, 16) == SQLITE_NULL
          ? nil : Int(sqlite3_column_int64(statement, 16))
        row["fileName"] = readString(statement, col: 17)
        rows.append(row)
      }

      return rows
    }
  }

  func getAsset(localIdentifier: String) throws -> [String: Any]? {
    return try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      let sql = """
        SELECT local_id, media_type, media_subtypes, creation_ts, modification_ts,
               duration, pixel_width, pixel_height, is_favorite, is_hidden,
               source_type, upload_status, retry_count, last_error, uploaded_at,
               remote_path, file_bytes, file_name
        FROM assets WHERE local_id = ?;
      """

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
      defer { sqlite3_finalize(statement) }
      bindText(statement, index: 1, value: localIdentifier)

      guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
      var row: [String: Any] = [:]
      row["localIdentifier"] = readString(statement, col: 0) ?? ""
      row["mediaType"] = Int(sqlite3_column_int64(statement, 1))
      row["mediaSubtypes"] = Int(sqlite3_column_int64(statement, 2))
      row["creationTimestamp"] = readOptionalDouble(statement, col: 3)
      row["modificationTimestamp"] = readOptionalDouble(statement, col: 4)
      row["duration"] = sqlite3_column_double(statement, 5)
      row["pixelWidth"] = Int(sqlite3_column_int64(statement, 6))
      row["pixelHeight"] = Int(sqlite3_column_int64(statement, 7))
      row["isFavorite"] = sqlite3_column_int(statement, 8) != 0
      row["isHidden"] = sqlite3_column_int(statement, 9) != 0
      row["sourceType"] = Int(sqlite3_column_int64(statement, 10))
      row["uploadStatus"] = readString(statement, col: 11) ?? "pending"
      row["retryCount"] = Int(sqlite3_column_int64(statement, 12))
      row["lastError"] = readString(statement, col: 13)
      row["uploadedAt"] = readOptionalDouble(statement, col: 14)
      row["remotePath"] = readString(statement, col: 15)
      row["fileBytes"] = sqlite3_column_type(statement, 16) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int64(statement, 16))
      row["fileName"] = readString(statement, col: 17)
      return row
    }
  }

  func countAssets(status: String?, mediaType: Int?) throws -> Int {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      var clauses: [String] = []
      if status != nil { clauses.append("upload_status = ?1") }
      if mediaType != nil { clauses.append("media_type = ?2") }
      let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
      let sql = "SELECT COUNT(*) FROM assets \(whereClause);"

      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
      defer { sqlite3_finalize(statement) }
      if let status { bindText(statement, index: 1, value: status) }
      if let mediaType { sqlite3_bind_int64(statement, 2, sqlite3_int64(mediaType)) }
      if sqlite3_step(statement) == SQLITE_ROW {
        return Int(sqlite3_column_int64(statement, 0))
      }
      return 0
    }
  }

  private func readString(_ statement: OpaquePointer?, col: Int32) -> String? {
    guard sqlite3_column_type(statement, col) != SQLITE_NULL,
          let cStr = sqlite3_column_text(statement, col) else { return nil }
    return String(cString: cStr)
  }

  private func readOptionalDouble(_ statement: OpaquePointer?, col: Int32) -> Any {
    if sqlite3_column_type(statement, col) == SQLITE_NULL { return NSNull() }
    return sqlite3_column_double(statement, col)
  }

  private func open() throws {
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      let message = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown sqlite open error"
      throw AssetDatabaseError.message("Failed to open database: \(message)")
    }

    // Performance pragmas. Ignore errors — worst case we fall back to defaults.
    //
    // WAL allows concurrent readers (uploader pump) and a writer (delta
    // observer upsert) without locking the whole DB — critical when scans
    // and uploads overlap.
    //
    // synchronous=NORMAL trades a tiny crash-recovery risk (last write may
    // be lost) for ~2× write throughput. Acceptable for a queue we can
    // always re-derive from the photo library.
    //
    // temp_store=MEMORY keeps temp B-trees off disk during large sorts.
    _ = try? execute(sql: "PRAGMA journal_mode=WAL;")
    _ = try? execute(sql: "PRAGMA synchronous=NORMAL;")
    _ = try? execute(sql: "PRAGMA temp_store=MEMORY;")
    _ = try? execute(sql: "PRAGMA foreign_keys=ON;")
  }

  private func createSchema() throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS assets (
        local_id TEXT PRIMARY KEY,
        media_type INTEGER NOT NULL,
        media_subtypes INTEGER NOT NULL,
        creation_ts REAL,
        modification_ts REAL,
        duration REAL NOT NULL,
        pixel_width INTEGER NOT NULL,
        pixel_height INTEGER NOT NULL,
        is_favorite INTEGER NOT NULL,
        is_hidden INTEGER NOT NULL,
        source_type INTEGER NOT NULL,
        upload_status TEXT NOT NULL DEFAULT 'pending',
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        uploaded_at REAL,
        updated_at REAL NOT NULL
      );

      CREATE INDEX IF NOT EXISTS idx_assets_creation_ts ON assets(creation_ts);
      CREATE INDEX IF NOT EXISTS idx_assets_modification_ts ON assets(modification_ts);
      CREATE INDEX IF NOT EXISTS idx_assets_upload_status ON assets(upload_status);
      -- Covering index for the uploader's pump query:
      --   WHERE upload_status = ? AND (next_retry_at IS NULL OR next_retry_at <= ?)
      --   ORDER BY creation_ts, local_id
      -- Matches the WHERE prefix, avoids the filesort on the LIMITed page.
      CREATE INDEX IF NOT EXISTS idx_assets_pending_queue
        ON assets(upload_status, next_retry_at, creation_ts, local_id);
    """

    try execute(sql: sql)
  }

  private func createScanStateSchema() throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS scan_state (
        key TEXT PRIMARY KEY,
        value REAL
      );
    """
    try execute(sql: sql)
  }

  func loadScanState() throws -> ScanState {
    try withLock {
      guard let db else {
        throw AssetDatabaseError.message("Database is not initialized")
      }

      var statement: OpaquePointer?
      let sql = "SELECT key, value FROM scan_state;"
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(db))
        throw AssetDatabaseError.message("Failed to prepare scan_state query: \(message)")
      }

      defer {
        sqlite3_finalize(statement)
      }

      var lastCompletedAt: Double?
      var cursorCreationTs: Double?

      while sqlite3_step(statement) == SQLITE_ROW {
        guard let keyCString = sqlite3_column_text(statement, 0) else {
          continue
        }

        let key = String(cString: keyCString)
        let value = sqlite3_column_double(statement, 1)
        switch key {
        case "last_completed_at":
          lastCompletedAt = value
        case "cursor_creation_ts":
          cursorCreationTs = value
        default:
          break
        }
      }

      return ScanState(lastCompletedAt: lastCompletedAt, cursorCreationTs: cursorCreationTs)
    }
  }

  func saveScanCursor(creationTs: Double) throws {
    try withLock {
      try setScanValue(key: "cursor_creation_ts", value: creationTs)
    }
  }

  func clearScanCursor() throws {
    try withLock {
      try deleteScanValue(key: "cursor_creation_ts")
    }
  }

  func markScanCompleted(at completedAt: Double) throws {
    try withLock {
      try setScanValue(key: "last_completed_at", value: completedAt)
      try deleteScanValue(key: "cursor_creation_ts")
    }
  }

  private func setScanValue(key: String, value: Double) throws {
    guard let db else {
      throw AssetDatabaseError.message("Database is not initialized")
    }

    let sql = "INSERT INTO scan_state (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed to prepare scan_state upsert: \(message)")
    }

    defer {
      sqlite3_finalize(statement)
    }

    bindText(statement, index: 1, value: key)
    sqlite3_bind_double(statement, 2, value)

    guard sqlite3_step(statement) == SQLITE_DONE else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed to persist scan_state: \(message)")
    }
  }

  private func deleteScanValue(key: String) throws {
    guard let db else {
      throw AssetDatabaseError.message("Database is not initialized")
    }

    let sql = "DELETE FROM scan_state WHERE key = ?;"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed to prepare scan_state delete: \(message)")
    }

    defer {
      sqlite3_finalize(statement)
    }

    bindText(statement, index: 1, value: key)

    guard sqlite3_step(statement) == SQLITE_DONE else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed to delete scan_state key: \(message)")
    }
  }

  private func migrateUploadColumnsIfNeeded() throws {
    try addColumnIfMissing(columnName: "upload_status", definition: "TEXT NOT NULL DEFAULT 'pending'")
    try addColumnIfMissing(columnName: "retry_count", definition: "INTEGER NOT NULL DEFAULT 0")
    try addColumnIfMissing(columnName: "last_error", definition: "TEXT")
    try addColumnIfMissing(columnName: "uploaded_at", definition: "REAL")
    try addColumnIfMissing(columnName: "next_retry_at", definition: "REAL")
    // Resumable upload state — persists TUS upload URL / S3 upload ID + byte
    // offset so uploads can resume after app kill or crash.
    try addColumnIfMissing(columnName: "resume_url", definition: "TEXT")
    try addColumnIfMissing(columnName: "resume_offset", definition: "INTEGER DEFAULT 0")
    // Remote path stored on successful upload so users can build UIs /
    // generate download links without knowing the provider config.
    try addColumnIfMissing(columnName: "remote_path", definition: "TEXT")
    try addColumnIfMissing(columnName: "file_bytes", definition: "INTEGER")
    try addColumnIfMissing(columnName: "file_name", definition: "TEXT")
  }

  private func addColumnIfMissing(columnName: String, definition: String) throws {
    guard let db else {
      throw AssetDatabaseError.message("Database is not initialized")
    }

    let pragma = "PRAGMA table_info(assets);"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, pragma, -1, &statement, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed to inspect schema: \(message)")
    }

    defer {
      sqlite3_finalize(statement)
    }

    var found = false
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let nameCString = sqlite3_column_text(statement, 1) else {
        continue
      }

      let existingName = String(cString: nameCString)
      if existingName == columnName {
        found = true
        break
      }
    }

    if !found {
      try execute(sql: "ALTER TABLE assets ADD COLUMN \(columnName) \(definition);")
    }
  }

  private func execute(sql: String) throws {
    guard let db else {
      throw AssetDatabaseError.message("Database is not initialized")
    }

    var errorMessagePointer: UnsafeMutablePointer<Int8>?
    guard sqlite3_exec(db, sql, nil, nil, &errorMessagePointer) == SQLITE_OK else {
      let message = errorMessagePointer.map { String(cString: $0) } ?? "Unknown sqlite error"
      sqlite3_free(errorMessagePointer)
      throw AssetDatabaseError.message("Failed SQL execution: \(message)")
    }
  }

  private func executeUpdate(sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws -> Int {
    guard let db else {
      throw AssetDatabaseError.message("Database is not initialized")
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed to prepare update statement: \(message)")
    }

    defer {
      sqlite3_finalize(statement)
    }

    bind?(statement)

    guard sqlite3_step(statement) == SQLITE_DONE else {
      let message = String(cString: sqlite3_errmsg(db))
      throw AssetDatabaseError.message("Failed SQL update: \(message)")
    }

    return Int(sqlite3_changes(db))
  }

  private func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
    value.withCString { valueCString in
      sqlite3_bind_text(statement, index, valueCString, -1, SQLITE_TRANSIENT)
    }
  }

  private func bindOptionalDouble(_ statement: OpaquePointer?, index: Int32, value: Double?) {
    if let value {
      sqlite3_bind_double(statement, index, value)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func withLock<T>(_ block: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    return try block()
  }

  private static func defaultPath() throws -> String {
    let fileManager = FileManager.default
    let appSupport = try fileManager.url(for: .applicationSupportDirectory,
                                         in: .userDomainMask,
                                         appropriateFor: nil,
                                         create: true)
    let folder = appSupport.appendingPathComponent("media_backup", isDirectory: true)
    if !fileManager.fileExists(atPath: folder.path) {
      try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: nil)
    }
    let dbURL = folder.appendingPathComponent("assets.sqlite")
    return dbURL.path
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
