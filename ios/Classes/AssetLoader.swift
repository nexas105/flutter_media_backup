import Foundation
import Photos

struct AssetLoadSummary {
  let scannedCount: Int
  let databasePath: String
  let batchSize: Int
}

enum AssetLoaderError: LocalizedError {
  case authorizationRequired

  var errorDescription: String? {
    switch self {
    case .authorizationRequired:
      return "Photo library permission is required"
    }
  }
}

final class AssetLoader: NSObject, PHPhotoLibraryChangeObserver {
  private let database: AssetDatabase
  private let queue = DispatchQueue(label: "media_backup.asset_loader", qos: .utility)
  private var observedFetchResult: PHFetchResult<PHAsset>?
  private var isObserverRegistered = false
  var onDatabaseChanged: (() -> Void)?

  init(database: AssetDatabase) {
    self.database = database
  }

  deinit {
    if isObserverRegistered {
      PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
  }

  func requestAuthorization(completion: @escaping (String) -> Void) {
    if #available(iOS 14, *) {
      let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      if current == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
          completion(Self.permissionString(from: status))
        }
      } else {
        completion(Self.permissionString(from: current))
      }
    } else {
      let current = PHPhotoLibrary.authorizationStatus()
      if current == .notDetermined {
        PHPhotoLibrary.requestAuthorization { status in
          completion(Self.permissionString(from: status))
        }
      } else {
        completion(Self.permissionString(from: current))
      }
    }
  }

  func loadAllAssets(batchSize: Int = 50,
                     incrementalSinceTs: Double? = nil,
                     completion: @escaping (Result<AssetLoadSummary, Error>) -> Void) {
    requestAuthorization { [weak self] permission in
      guard let self else {
        return
      }

      guard permission == "authorized" || permission == "limited" else {
        completion(.failure(AssetLoaderError.authorizationRequired))
        return
      }

      let safeBatchSize = max(1, batchSize)
      queue.async {
        let state = (try? self.database.loadScanState()) ?? ScanState(lastCompletedAt: nil, cursorCreationTs: nil)
        let resumeCursor = state.cursorCreationTs

        // Decide fetch mode:
        // 1. Pending cursor → resume interrupted scan from cursor
        // 2. incrementalSinceTs → follow-up scan, only fetch changed/new assets
        // 3. Neither → full scan
        let options: PHFetchOptions
        let isIncremental: Bool
        if resumeCursor != nil {
          options = self.fetchOptions(resumeFromCreationTs: resumeCursor)
          isIncremental = false
        } else if let sinceTs = incrementalSinceTs {
          options = self.fetchOptions(incrementalSinceTs: sinceTs)
          isIncremental = true
        } else {
          options = self.fetchOptions()
          isIncremental = false
        }

        let fetchResult = PHAsset.fetchAssets(with: options)
        var scanned = 0
        var buffer: [AssetRow] = []
        buffer.reserveCapacity(safeBatchSize)
        var writeError: Error?
        var maxCursor: Double? = resumeCursor

        fetchResult.enumerateObjects { asset, _, stop in
          if writeError != nil {
            stop.pointee = true
            return
          }

          scanned += 1
          let row = AssetRow(asset: asset)
          buffer.append(row)

          // Track cursor for full/resume scans only — incremental scans
          // don't paginate by creationDate.
          if !isIncremental, let ts = row.creationTimestamp {
            if maxCursor == nil || ts > (maxCursor ?? 0) {
              maxCursor = ts
            }
          }

          if buffer.count >= safeBatchSize {
            do {
              try self.database.upsert(rows: buffer)
              if !isIncremental, let cursor = maxCursor {
                try? self.database.saveScanCursor(creationTs: cursor)
              }
              buffer.removeAll(keepingCapacity: true)
            } catch {
              writeError = error
              stop.pointee = true
            }
          }
        }

        if let writeError {
          completion(.failure(writeError))
          return
        }

        do {
          if !buffer.isEmpty {
            try self.database.upsert(rows: buffer)
            if !isIncremental, let cursor = maxCursor {
              try? self.database.saveScanCursor(creationTs: cursor)
            }
          }

          try? self.database.markScanCompleted(at: Date().timeIntervalSince1970)

          self.onDatabaseChanged?()
          completion(.success(AssetLoadSummary(scannedCount: scanned,
                                               databasePath: self.database.path,
                                               batchSize: safeBatchSize)))
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  func startDeltaObservation(completion: @escaping (Result<String, Error>) -> Void) {
    requestAuthorization { [weak self] permission in
      guard let self else {
        return
      }

      guard permission == "authorized" || permission == "limited" else {
        completion(.failure(AssetLoaderError.authorizationRequired))
        return
      }

      self.queue.async {
        self.observedFetchResult = PHAsset.fetchAssets(with: self.fetchOptions())
        if !self.isObserverRegistered {
          PHPhotoLibrary.shared().register(self)
          self.isObserverRegistered = true
        }

        completion(.success(permission))
      }
    }
  }

  func stopDeltaObservation() {
    queue.async {
      if self.isObserverRegistered {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        self.isObserverRegistered = false
      }

      self.observedFetchResult = nil
    }
  }

  func photoLibraryDidChange(_ changeInstance: PHChange) {
    queue.async {
      guard let currentFetchResult = self.observedFetchResult,
            let details = changeInstance.changeDetails(for: currentFetchResult)
      else {
        return
      }

      self.observedFetchResult = details.fetchResultAfterChanges

      var hasChanges = false

      do {
        let changedRows = details.changedObjects.map { AssetRow(asset: $0) }
        let insertedRows = details.insertedObjects.map { AssetRow(asset: $0) }
        let removedIds = details.removedObjects.map { $0.localIdentifier }

        if !changedRows.isEmpty || !insertedRows.isEmpty {
          var rows = changedRows
          rows.append(contentsOf: insertedRows)
          try self.database.upsert(rows: rows)
          hasChanges = true
        }

        if !removedIds.isEmpty {
          try self.database.remove(localIdentifiers: removedIds)
          hasChanges = true
        }

        if hasChanges {
          self.onDatabaseChanged?()
        }
      } catch {
        MediaBackupLogger.shared.error("Loader",
                                       "Delta scan failed",
                                       error: error)
      }
    }
  }

  private func fetchOptions(resumeFromCreationTs: Double? = nil,
                            incrementalSinceTs: Double? = nil) -> PHFetchOptions {
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    if let resumeFromCreationTs {
      let cursorDate = NSDate(timeIntervalSince1970: resumeFromCreationTs)
      options.predicate = NSPredicate(format: "creationDate > %@", cursorDate)
    } else if let incrementalSinceTs {
      // Follow-up scan: only fetch assets created or modified since the last
      // completed scan. Catches both new photos and edited/re-exported ones.
      let sinceDate = NSDate(timeIntervalSince1970: incrementalSinceTs)
      options.predicate = NSPredicate(format: "creationDate > %@ OR modificationDate > %@",
                                      sinceDate, sinceDate)
    }
    return options
  }

  private static func permissionString(from status: PHAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .limited:
      return "limited"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "notDetermined"
    @unknown default:
      return "unknown"
    }
  }
}
