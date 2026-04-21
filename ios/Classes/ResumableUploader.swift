import Foundation

/// Drives a single TUS v1.0.0 resumable upload (used by Supabase Storage).
///
/// Flow: POST to create → sequential PATCH chunks → completion.
/// On resume: HEAD to check offset → continue from there.
final class TUSUploader {
  private let endpoint: URL
  private let fileURL: URL
  let totalBytes: Int64
  private let chunkSize: Int64
  private let authHeaders: [String: String]
  private let metadata: [String: String]
  private let queue: DispatchQueue

  private(set) var uploadURL: URL?
  private(set) var currentOffset: Int64 = 0
  private var isCancelled = false

  /// Shared foreground session — TUS chunked uploads don't work with
  /// background URLSession (needs sequential request chaining).
  private static let tusSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 3600
    return URLSession(configuration: config)
  }()

  var onProgress: ((Int64, Int64) -> Void)?
  var onComplete: (() -> Void)?
  var onError: ((String, Bool) -> Void)?

  init(endpoint: URL,
       fileURL: URL,
       totalBytes: Int64,
       chunkSize: Int64,
       authHeaders: [String: String],
       metadata: [String: String],
       queue: DispatchQueue) {
    self.endpoint = endpoint
    self.fileURL = fileURL
    self.totalBytes = totalBytes
    self.chunkSize = chunkSize
    self.authHeaders = authHeaders
    self.metadata = metadata
    self.queue = queue
  }

  func start(resumeURL: String? = nil, resumeOffset: Int64 = 0) {
    if let resumeURL, let url = URL(string: resumeURL) {
      uploadURL = url
      currentOffset = resumeOffset
      checkOffsetAndResume()
    } else {
      createUpload()
    }
  }

  func cancel() {
    queue.async { self.isCancelled = true }
  }

  // MARK: - TUS Protocol

  private func createUpload() {
    guard !isCancelled else { return }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
    request.setValue(String(totalBytes), forHTTPHeaderField: "Upload-Length")
    for (k, v) in authHeaders {
      request.setValue(v, forHTTPHeaderField: k)
    }

    // Encode metadata as comma-separated "key base64value" pairs.
    let encoded = metadata.map { key, value in
      "\(key) \(Data(value.utf8).base64EncodedString())"
    }.joined(separator: ",")
    request.setValue(encoded, forHTTPHeaderField: "Upload-Metadata")

    Self.tusSession.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        guard !self.isCancelled else { return }
        if let error {
          self.onError?(error.localizedDescription, true)
          return
        }

        guard let http = response as? HTTPURLResponse else {
          self.onError?("No HTTP response from TUS create", true)
          return
        }

        guard (200...299).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else {
          let msg = "TUS create failed: HTTP \(http.statusCode)"
          self.onError?(msg, http.statusCode >= 500 || http.statusCode == 429)
          return
        }

        // Location may be relative or absolute.
        if let absolute = URL(string: location, relativeTo: self.endpoint) {
          self.uploadURL = absolute
        } else {
          self.uploadURL = URL(string: location)
        }
        self.currentOffset = 0
        self.sendNextChunk()
      }
    }.resume()
  }

  private func checkOffsetAndResume() {
    guard !isCancelled, let uploadURL else {
      createUpload()
      return
    }

    var request = URLRequest(url: uploadURL)
    request.httpMethod = "HEAD"
    request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
    for (k, v) in authHeaders {
      request.setValue(v, forHTTPHeaderField: k)
    }

    Self.tusSession.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        guard !self.isCancelled else { return }
        if let http = response as? HTTPURLResponse,
           let offsetStr = http.value(forHTTPHeaderField: "Upload-Offset"),
           let offset = Int64(offsetStr) {
          self.currentOffset = offset
        }
        // If HEAD fails, just try from stored offset.
        self.sendNextChunk()
      }
    }.resume()
  }

  private func sendNextChunk() {
    guard !isCancelled, let uploadURL else { return }

    if currentOffset >= totalBytes {
      onComplete?()
      return
    }

    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
      onError?("Cannot open file for reading", false)
      return
    }
    defer { try? handle.close() }

    handle.seek(toFileOffset: UInt64(currentOffset))
    let remaining = totalBytes - currentOffset
    let thisChunk = min(chunkSize, remaining)
    let data = handle.readData(ofLength: Int(thisChunk))

    var request = URLRequest(url: uploadURL)
    request.httpMethod = "PATCH"
    request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
    request.setValue(String(currentOffset), forHTTPHeaderField: "Upload-Offset")
    request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
    for (k, v) in authHeaders {
      request.setValue(v, forHTTPHeaderField: k)
    }

    // Use uploadTask(with:from:) so URLSession can release the Data buffer
    // during transfer, instead of pinning it via httpBody on a dataTask.
    Self.tusSession.uploadTask(with: request, from: data) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        guard !self.isCancelled else { return }
        if let error {
          self.onError?(error.localizedDescription, true)
          return
        }

        guard let http = response as? HTTPURLResponse else {
          self.onError?("No HTTP response from TUS PATCH", true)
          return
        }

        guard (200...299).contains(http.statusCode) else {
          let retriable = http.statusCode >= 500 || http.statusCode == 429 || http.statusCode == 409
          self.onError?("TUS PATCH failed: HTTP \(http.statusCode)", retriable)
          return
        }

        if let newOffsetStr = http.value(forHTTPHeaderField: "Upload-Offset"),
           let newOffset = Int64(newOffsetStr) {
          self.currentOffset = newOffset
        } else {
          self.currentOffset += Int64(data.count)
        }

        self.onProgress?(self.currentOffset, self.totalBytes)
        self.sendNextChunk()
      }
    }.resume()
  }
}

// MARK: - S3 Multipart Upload

/// Drives a single S3 multipart upload.
///
/// Flow: CreateMultipartUpload → sequential UploadPart → CompleteMultipartUpload.
final class S3MultipartUploader {
  private let provider: S3UploadProvider
  private let objectKey: String
  private let fileURL: URL
  let totalBytes: Int64
  private let partSize: Int64
  private let queue: DispatchQueue

  private(set) var uploadId: String?
  private var completedParts: [(partNumber: Int, etag: String)] = []
  private var nextPartNumber: Int = 1
  private(set) var currentOffset: Int64 = 0
  private var isCancelled = false

  private static let s3Session: URLSession = {
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 120
    config.timeoutIntervalForResource = 3600
    return URLSession(configuration: config)
  }()

  var onProgress: ((Int64, Int64) -> Void)?
  var onComplete: (() -> Void)?
  var onError: ((String, Bool) -> Void)?

  init(provider: S3UploadProvider,
       objectKey: String,
       fileURL: URL,
       totalBytes: Int64,
       partSize: Int64,
       queue: DispatchQueue) {
    self.provider = provider
    self.objectKey = objectKey
    self.fileURL = fileURL
    self.totalBytes = totalBytes
    self.partSize = partSize
    self.queue = queue
  }

  func start(resumeUploadId: String? = nil, resumeOffset: Int64 = 0, resumeParts: [(Int, String)] = []) {
    if let resumeUploadId {
      uploadId = resumeUploadId
      completedParts = resumeParts.map { (partNumber: $0.0, etag: $0.1) }
      nextPartNumber = (completedParts.map(\.partNumber).max() ?? 0) + 1
      currentOffset = resumeOffset
      uploadNextPart()
    } else {
      createMultipartUpload()
    }
  }

  func cancel() {
    queue.async { self.isCancelled = true }
  }

  // MARK: - S3 Multipart Protocol

  private func createMultipartUpload() {
    guard !isCancelled else { return }

    guard var request = provider.buildMultipartCreateRequest(objectKey: objectKey, fileURL: fileURL) else {
      onError?("Failed to build S3 CreateMultipartUpload request", false)
      return
    }
    request.httpMethod = "POST"

    Self.s3Session.dataTask(with: request) { [weak self] data, response, error in
      guard let self, !self.isCancelled else { return }
      self.queue.async {
        if let error {
          self.onError?(error.localizedDescription, true)
          return
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let data,
              let body = String(data: data, encoding: .utf8),
              let id = self.parseUploadId(from: body) else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? -1
          self.onError?("S3 CreateMultipartUpload failed: HTTP \(code)", code >= 500)
          return
        }

        self.uploadId = id
        self.nextPartNumber = 1
        self.currentOffset = 0
        self.completedParts = []
        self.uploadNextPart()
      }
    }.resume()
  }

  private func uploadNextPart() {
    guard !isCancelled, let uploadId else { return }

    if currentOffset >= totalBytes {
      completeMultipartUpload()
      return
    }

    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
      onError?("Cannot open file for reading", false)
      return
    }
    defer { try? handle.close() }

    handle.seek(toFileOffset: UInt64(currentOffset))
    let remaining = totalBytes - currentOffset
    let thisPart = min(partSize, remaining)
    let data = handle.readData(ofLength: Int(thisPart))

    guard let request = provider.buildMultipartPartRequest(
      objectKey: objectKey,
      uploadId: uploadId,
      partNumber: nextPartNumber,
      partData: data
    ) else {
      onError?("Failed to build S3 UploadPart request", false)
      return
    }

    Self.s3Session.uploadTask(with: request, from: data) { [weak self] responseData, response, error in
      guard let self, !self.isCancelled else { return }
      self.queue.async {
        if let error {
          self.onError?(error.localizedDescription, true)
          return
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let etag = http.value(forHTTPHeaderField: "ETag") else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? -1
          self.onError?("S3 UploadPart failed: HTTP \(code)", code >= 500)
          return
        }

        self.completedParts.append((partNumber: self.nextPartNumber, etag: etag))
        self.currentOffset += Int64(data.count)
        self.nextPartNumber += 1
        self.onProgress?(self.currentOffset, self.totalBytes)
        self.uploadNextPart()
      }
    }.resume()
  }

  private func completeMultipartUpload() {
    guard !isCancelled, let uploadId else { return }

    let sortedParts = completedParts.sorted { $0.partNumber < $1.partNumber }
    var xml = "<CompleteMultipartUpload>"
    for part in sortedParts {
      xml += "<Part><PartNumber>\(part.partNumber)</PartNumber><ETag>\(xmlEscape(part.etag))</ETag></Part>"
    }
    xml += "</CompleteMultipartUpload>"

    guard var request = provider.buildMultipartCompleteRequest(
      objectKey: objectKey,
      uploadId: uploadId,
      xmlBody: xml
    ) else {
      onError?("Failed to build S3 CompleteMultipartUpload request", false)
      return
    }
    request.httpBody = xml.data(using: .utf8)

    Self.s3Session.dataTask(with: request) { [weak self] _, response, error in
      guard let self else { return }
      self.queue.async {
        guard !self.isCancelled else { return }
        if let error {
          self.onError?(error.localizedDescription, true)
          return
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
          let code = (response as? HTTPURLResponse)?.statusCode ?? -1
          self.onError?("S3 CompleteMultipartUpload failed: HTTP \(code)", code >= 500)
          return
        }

        self.onComplete?()
      }
    }.resume()
  }

  private func parseUploadId(from xml: String) -> String? {
    // Minimal XML parse: extract <UploadId>...</UploadId>
    guard let startRange = xml.range(of: "<UploadId>"),
          let endRange = xml.range(of: "</UploadId>") else { return nil }
    return String(xml[startRange.upperBound..<endRange.lowerBound])
  }

  private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
  }
}
