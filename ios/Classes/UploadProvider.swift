import CommonCrypto
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Best-effort MIME type from a file URL's path extension.
/// iOS 14+: uses UniformTypeIdentifiers (`UTType`). Older falls back to a
/// small built-in map covering the usual iOS photo/video formats.
func mimeType(for url: URL, fallback: String) -> String {
  let ext = url.pathExtension.lowercased()
  if ext.isEmpty { return fallback }

  if #available(iOS 14.0, *) {
    if let type = UTType(filenameExtension: ext),
       let mime = type.preferredMIMEType {
      return mime
    }
  }

  switch ext {
  case "jpg", "jpeg": return "image/jpeg"
  case "png":         return "image/png"
  case "heic":        return "image/heic"
  case "heif":        return "image/heif"
  case "gif":         return "image/gif"
  case "webp":        return "image/webp"
  case "bmp":         return "image/bmp"
  case "tif", "tiff": return "image/tiff"
  case "mp4", "m4v":  return "video/mp4"
  case "mov":         return "video/quicktime"
  case "avi":         return "video/x-msvideo"
  case "hevc":        return "video/hevc"
  case "webm":        return "video/webm"
  case "mkv":         return "video/x-matroska"
  case "m4a":         return "audio/mp4"
  case "mp3":         return "audio/mpeg"
  case "wav":         return "audio/wav"
  default:            return fallback
  }
}

struct UploadRequestBuild {
  let request: URLRequest
  let providerKind: String
}

protocol UploadProvider {
  var kind: String { get }
  var simulatesUpload: Bool { get }
  var simulatedLatency: TimeInterval { get }
  var simulatedFailureRate: Double { get }

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest?
}

extension UploadProvider {
  var simulatesUpload: Bool { false }
  var simulatedLatency: TimeInterval { 0 }
  var simulatedFailureRate: Double { 0 }
}

enum UploadProviderError: LocalizedError {
  case invalidConfiguration(String)
  case unknownKind(String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let reason):
      return "Invalid upload provider configuration: \(reason)"
    case .unknownKind(let kind):
      return "Unknown upload provider kind: \(kind)"
    }
  }
}

enum UploadProviderFactory {
  static func make(from map: [String: Any]) throws -> UploadProvider {
    guard let kind = map["kind"] as? String else {
      throw UploadProviderError.invalidConfiguration("missing 'kind'")
    }

    switch kind {
    case "custom":
      return try CustomUploadProvider(map: map)
    case "supabase":
      return try SupabaseUploadProvider(map: map)
    case "s3":
      return try S3UploadProvider(map: map)
    case "gcs":
      return try GcsUploadProvider(map: map)
    case "azure_blob":
      return try AzureBlobUploadProvider(map: map)
    case "firebase_storage":
      return try FirebaseStorageUploadProvider(map: map)
    case "test":
      return try TestUploadProvider(map: map)
    default:
      throw UploadProviderError.unknownKind(kind)
    }
  }
}

private func sanitizeObjectKey(_ assetId: String, prefix: String?) -> String {
  let safeAssetId = assetId.replacingOccurrences(of: "/", with: "_")
  let trimmedPrefix = (prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  if trimmedPrefix.isEmpty { return safeAssetId }
  return "\(trimmedPrefix)/\(safeAssetId)"
}

private extension CharacterSet {
  static let rfc3986Unreserved: CharacterSet = {
    var set = CharacterSet(charactersIn: "A"..."Z")
    set.insert(charactersIn: "a"..."z")
    set.insert(charactersIn: "0"..."9")
    set.insert(charactersIn: "-._~")
    return set
  }()

  static let rfc3986UnreservedWithSlash: CharacterSet = {
    var set = CharacterSet.rfc3986Unreserved
    set.insert(charactersIn: "/")
    return set
  }()
}

private func percentEncodeKeyPath(_ key: String) -> String {
  return key.addingPercentEncoding(withAllowedCharacters: .rfc3986UnreservedWithSlash) ?? key
}

struct CustomUploadProvider: UploadProvider {
  let url: URL
  let method: String
  let headers: [String: String]

  init(map: [String: Any]) throws {
    guard let raw = map["url"] as? String, let url = URL(string: raw) else {
      throw UploadProviderError.invalidConfiguration("custom.url is missing or invalid")
    }
    self.url = url
    self.method = (map["method"] as? String)?.uppercased() ?? "POST"
    self.headers = (map["headers"] as? [String: Any])?.compactMapValues { "\($0)" } ?? [:]
  }

  let kind = "custom"

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 600
    request.setValue(mimeType(for: fileURL, fallback: "application/octet-stream"),
                     forHTTPHeaderField: "Content-Type")
    request.setValue(assetId, forHTTPHeaderField: "X-Asset-Id")
    request.setValue(String(mediaType), forHTTPHeaderField: "X-Asset-Media-Type")
    for (k, v) in headers {
      request.setValue(v, forHTTPHeaderField: k)
    }
    return request
  }
}

struct SupabaseUploadProvider: UploadProvider {
  let projectUrl: URL
  let bucket: String
  let pathPrefix: String?
  let accessToken: String
  let upsert: Bool
  let contentType: String

  init(map: [String: Any]) throws {
    guard let raw = map["projectUrl"] as? String,
          let url = URL(string: raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
          let bucket = map["bucket"] as? String,
          let token = map["accessToken"] as? String else {
      throw UploadProviderError.invalidConfiguration("supabase needs projectUrl + bucket + accessToken")
    }
    self.projectUrl = url
    self.bucket = bucket
    self.pathPrefix = map["pathPrefix"] as? String
    self.accessToken = token
    self.upsert = map["upsert"] as? Bool ?? true
    self.contentType = map["contentType"] as? String ?? "application/octet-stream"
  }

  let kind = "supabase"

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    let key = sanitizeObjectKey(assetId, prefix: pathPrefix)
    let urlString = "\(projectUrl.absoluteString)/storage/v1/object/\(bucket)/\(percentEncodeKeyPath(key))"
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    // POST = insert (standard Supabase Storage pattern). With `x-upsert: true`
    // the request becomes idempotent — retries on the same asset overwrite
    // rather than returning 409 "Duplicate".
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    let resolvedContentType = mimeType(for: fileURL, fallback: contentType)
    request.setValue(resolvedContentType, forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    // Supabase Storage requires both the Authorization bearer AND the apikey
    // header (same value for anon/authenticated JWTs). Without apikey the
    // gateway returns 400 with a non-obvious body.
    request.setValue(accessToken, forHTTPHeaderField: "apikey")
    if upsert {
      request.setValue("true", forHTTPHeaderField: "x-upsert")
    }
    return request
  }
}

struct GcsUploadProvider: UploadProvider {
  let bucket: String
  let pathPrefix: String?
  let accessToken: String
  let contentType: String

  init(map: [String: Any]) throws {
    guard let bucket = map["bucket"] as? String,
          let token = map["accessToken"] as? String else {
      throw UploadProviderError.invalidConfiguration("gcs needs bucket + accessToken")
    }
    self.bucket = bucket
    self.pathPrefix = map["pathPrefix"] as? String
    self.accessToken = token
    self.contentType = map["contentType"] as? String ?? "application/octet-stream"
  }

  let kind = "gcs"

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    let key = sanitizeObjectKey(assetId, prefix: pathPrefix)
    let encodedName = key.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? key
    let urlString = "https://storage.googleapis.com/upload/storage/v1/b/\(bucket)/o?uploadType=media&name=\(encodedName)"
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    request.setValue(mimeType(for: fileURL, fallback: contentType), forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(String(fileBytes), forHTTPHeaderField: "Content-Length")
    return request
  }
}

struct AzureBlobUploadProvider: UploadProvider {
  let accountName: String
  let container: String
  let pathPrefix: String?
  let sasToken: String?
  let contentType: String

  init(map: [String: Any]) throws {
    guard let accountName = map["accountName"] as? String,
          let container = map["container"] as? String else {
      throw UploadProviderError.invalidConfiguration("azure_blob needs accountName + container")
    }
    self.accountName = accountName
    self.container = container
    self.pathPrefix = map["pathPrefix"] as? String
    self.sasToken = map["sasToken"] as? String
    self.contentType = map["contentType"] as? String ?? "application/octet-stream"
  }

  let kind = "azure_blob"

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    let key = sanitizeObjectKey(assetId, prefix: pathPrefix)
    var urlString = "https://\(accountName).blob.core.windows.net/\(container)/\(percentEncodeKeyPath(key))"
    if let sasToken, !sasToken.isEmpty {
      let clean = sasToken.hasPrefix("?") ? String(sasToken.dropFirst()) : sasToken
      urlString += "?\(clean)"
    }
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "PUT"
    request.timeoutInterval = 600
    request.setValue(mimeType(for: fileURL, fallback: contentType), forHTTPHeaderField: "Content-Type")
    request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
    request.setValue("2020-04-08", forHTTPHeaderField: "x-ms-version")
    return request
  }
}

struct FirebaseStorageUploadProvider: UploadProvider {
  let bucket: String
  let pathPrefix: String?
  let idToken: String
  let contentType: String

  init(map: [String: Any]) throws {
    guard let bucket = map["bucket"] as? String,
          let idToken = map["idToken"] as? String else {
      throw UploadProviderError.invalidConfiguration("firebase_storage needs bucket + idToken")
    }
    self.bucket = bucket
    self.pathPrefix = map["pathPrefix"] as? String
    self.idToken = idToken
    self.contentType = map["contentType"] as? String ?? "application/octet-stream"
  }

  let kind = "firebase_storage"

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    let key = sanitizeObjectKey(assetId, prefix: pathPrefix)
    let encodedName = key.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? key
    let urlString = "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o?uploadType=media&name=\(encodedName)"
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    request.setValue(mimeType(for: fileURL, fallback: contentType), forHTTPHeaderField: "Content-Type")
    request.setValue("Firebase \(idToken)", forHTTPHeaderField: "Authorization")
    return request
  }
}

struct TestUploadProvider: UploadProvider {
  let simulatedLatencyMs: Int
  let failureRate: Double

  init(map: [String: Any]) throws {
    self.simulatedLatencyMs = (map["simulatedLatencyMs"] as? Int) ?? 250
    self.failureRate = max(0, min(1, (map["failureRate"] as? Double) ?? 0))
  }

  let kind = "test"
  var simulatesUpload: Bool { true }
  var simulatedLatency: TimeInterval { Double(simulatedLatencyMs) / 1000.0 }
  var simulatedFailureRate: Double { failureRate }

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    return nil
  }
}

struct S3UploadProvider: UploadProvider {
  let accessKeyId: String
  let secretAccessKey: String
  let sessionToken: String?
  let region: String
  let bucket: String
  let pathPrefix: String?
  let endpoint: URL?
  let usePathStyle: Bool
  let contentType: String

  init(map: [String: Any]) throws {
    guard let accessKeyId = map["accessKeyId"] as? String,
          let secretAccessKey = map["secretAccessKey"] as? String,
          let region = map["region"] as? String,
          let bucket = map["bucket"] as? String else {
      throw UploadProviderError.invalidConfiguration("s3 needs accessKeyId + secretAccessKey + region + bucket")
    }
    self.accessKeyId = accessKeyId
    self.secretAccessKey = secretAccessKey
    self.sessionToken = map["sessionToken"] as? String
    self.region = region
    self.bucket = bucket
    self.pathPrefix = map["pathPrefix"] as? String
    if let endpointString = map["endpoint"] as? String {
      self.endpoint = URL(string: endpointString)
    } else {
      self.endpoint = nil
    }
    self.usePathStyle = map["usePathStyle"] as? Bool ?? false
    self.contentType = map["contentType"] as? String ?? "application/octet-stream"
  }

  let kind = "s3"

  func buildRequest(assetId: String,
                    mediaType: Int,
                    fileURL: URL,
                    fileBytes: Int64) -> URLRequest? {
    let key = sanitizeObjectKey(assetId, prefix: pathPrefix)
    let encodedKey = percentEncodeKeyPath(key)
    let (host, basePath, scheme) = resolveEndpoint()

    let urlString = "\(scheme)://\(host)\(basePath)/\(encodedKey)"
    guard let target = URL(string: urlString) else { return nil }

    var request = URLRequest(url: target)
    request.httpMethod = "PUT"
    request.timeoutInterval = 600
    request.setValue(mimeType(for: fileURL, fallback: contentType), forHTTPHeaderField: "Content-Type")
    request.setValue(String(fileBytes), forHTTPHeaderField: "Content-Length")

    signRequestV4(request: &request,
                  host: host,
                  canonicalPath: "\(basePath)/\(encodedKey)",
                  contentLength: fileBytes)

    return request
  }

  // MARK: - Multipart upload helpers

  /// Default chunk size for S3 multipart: 8 MB (min 5 MB per AWS).
  static let defaultPartSize: Int64 = 8 * 1024 * 1024

  /// Files above this threshold use multipart upload.
  static let resumableThreshold: Int64 = 50 * 1024 * 1024

  func buildMultipartCreateRequest(objectKey: String, fileURL: URL) -> URLRequest? {
    let (host, basePath, scheme) = resolveEndpoint()
    let encodedKey = percentEncodeKeyPath(objectKey)
    let urlString = "\(scheme)://\(host)\(basePath)/\(encodedKey)?uploads"
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    let resolved = mimeType(for: fileURL, fallback: contentType)
    request.setValue(resolved, forHTTPHeaderField: "Content-Type")
    request.setValue("0", forHTTPHeaderField: "Content-Length")
    signRequestV4(request: &request, host: host,
                  canonicalPath: "\(basePath)/\(encodedKey)",
                  queryString: "uploads=", contentLength: 0)
    return request
  }

  func buildMultipartPartRequest(objectKey: String, uploadId: String,
                                  partNumber: Int, partData: Data) -> URLRequest? {
    let (host, basePath, scheme) = resolveEndpoint()
    let encodedKey = percentEncodeKeyPath(objectKey)
    let encodedUploadId = uploadId.addingPercentEncoding(withAllowedCharacters: .rfc3986Unreserved) ?? uploadId
    let query = "partNumber=\(partNumber)&uploadId=\(encodedUploadId)"
    let urlString = "\(scheme)://\(host)\(basePath)/\(encodedKey)?\(query)"
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "PUT"
    request.timeoutInterval = 600
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(partData.count), forHTTPHeaderField: "Content-Length")
    signRequestV4(request: &request, host: host,
                  canonicalPath: "\(basePath)/\(encodedKey)",
                  queryString: query, contentLength: Int64(partData.count))
    return request
  }

  func buildMultipartCompleteRequest(objectKey: String, uploadId: String,
                                      xmlBody: String) -> URLRequest? {
    let (host, basePath, scheme) = resolveEndpoint()
    let encodedKey = percentEncodeKeyPath(objectKey)
    let query = "uploadId=\(uploadId)"
    let urlString = "\(scheme)://\(host)\(basePath)/\(encodedKey)?\(query)"
    guard let target = URL(string: urlString) else { return nil }
    var request = URLRequest(url: target)
    request.httpMethod = "POST"
    request.timeoutInterval = 120
    let bodyData = xmlBody.data(using: .utf8) ?? Data()
    request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    request.setValue(String(bodyData.count), forHTTPHeaderField: "Content-Length")
    signRequestV4(request: &request, host: host,
                  canonicalPath: "\(basePath)/\(encodedKey)",
                  queryString: query, contentLength: Int64(bodyData.count))
    return request
  }

  private func resolveEndpoint() -> (host: String, basePath: String, scheme: String) {
    if let endpoint, let host = endpoint.host {
      let scheme = endpoint.scheme ?? "https"
      let hostPort = host + (endpoint.port.map { ":\($0)" } ?? "")
      let basePath = usePathStyle ? "/\(bucket)" : ""
      return (hostPort, basePath, scheme)
    } else {
      if usePathStyle {
        return ("s3.\(region).amazonaws.com", "/\(bucket)", "https")
      } else {
        return ("\(bucket).s3.\(region).amazonaws.com", "", "https")
      }
    }
  }

  private func signRequestV4(request: inout URLRequest,
                             host: String,
                             canonicalPath: String,
                             queryString: String = "",
                             contentLength: Int64) {
    let now = Date()
    let isoFormatter = DateFormatter()
    isoFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    isoFormatter.timeZone = TimeZone(identifier: "UTC")
    let amzDate = isoFormatter.string(from: now)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyyMMdd"
    dateFormatter.timeZone = TimeZone(identifier: "UTC")
    let dateStamp = dateFormatter.string(from: now)

    let unsignedPayload = "UNSIGNED-PAYLOAD"

    request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
    request.setValue(unsignedPayload, forHTTPHeaderField: "X-Amz-Content-Sha256")
    request.setValue(host, forHTTPHeaderField: "Host")
    if let sessionToken {
      request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
    }

    let method = request.httpMethod ?? "PUT"
    let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"

    var canonicalHeaders = ""
    var signedHeadersList: [String] = []

    var headerPairs: [(String, String)] = [
      ("content-length", String(contentLength)),
      ("content-type", contentType),
      ("host", host),
      ("x-amz-content-sha256", unsignedPayload),
      ("x-amz-date", amzDate),
    ]
    if let sessionToken {
      headerPairs.append(("x-amz-security-token", sessionToken))
    }
    headerPairs.sort { $0.0 < $1.0 }
    for (name, value) in headerPairs {
      canonicalHeaders += "\(name):\(value.trimmingCharacters(in: .whitespaces))\n"
      signedHeadersList.append(name)
    }
    let signedHeaders = signedHeadersList.joined(separator: ";")

    let canonicalRequest = [
      method,
      canonicalPath,
      queryString,
      canonicalHeaders,
      signedHeaders,
      unsignedPayload,
    ].joined(separator: "\n")

    let credentialScope = "\(dateStamp)/\(region)/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      amzDate,
      credentialScope,
      sha256Hex(canonicalRequest),
    ].joined(separator: "\n")

    let kDate = hmacSha256(Array("AWS4\(secretAccessKey)".utf8), Array(dateStamp.utf8))
    let kRegion = hmacSha256(kDate, Array(region.utf8))
    let kService = hmacSha256(kRegion, Array("s3".utf8))
    let kSigning = hmacSha256(kService, Array("aws4_request".utf8))
    let signature = hmacSha256(kSigning, Array(stringToSign.utf8))
    let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

    let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signatureHex)"
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
  }

  private func sha256Hex(_ input: String) -> String {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    let bytes = Array(input.utf8)
    CC_SHA256(bytes, CC_LONG(bytes.count), &hash)
    return hash.map { String(format: "%02x", $0) }.joined()
  }

  private func hmacSha256(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
    var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &mac)
    return mac
  }
}
