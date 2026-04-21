import 'media_backup_errors.dart';

/// Describes where and how uploaded media bytes should be sent.
/// Native side selects an implementation based on [kind] and the parameters
/// returned by [toMap].
abstract class UploadProvider {
  const UploadProvider();

  String get kind;

  Map<String, dynamic> toMap();

  /// Throws [MediaBackupConfigurationException] when a required field is
  /// missing or invalid. Called by [MediaBackup.configureUploader] before
  /// serializing to native.
  void validate() {}

  void _require(String name, String? value) {
    if (value == null || value.trim().isEmpty) {
      throw MediaBackupConfigurationException(
        '$kind provider: "$name" is required but empty. '
        'Check your .env / settings.',
      );
    }
  }
}

/// Sends the asset body to a user-defined HTTP endpoint.
///
/// Useful for any custom backend: forward the bytes to your own API, pair
/// with server-side signing for S3/GCS/Azure, etc.
class CustomUploadProvider extends UploadProvider {
  final String url;
  final String method;
  final Map<String, String> headers;

  const CustomUploadProvider({
    required this.url,
    this.method = 'POST',
    this.headers = const <String, String>{},
  });

  @override
  String get kind => 'custom';

  @override
  void validate() {
    _require('url', url);
    if (Uri.tryParse(url)?.hasScheme != true) {
      throw MediaBackupConfigurationException(
        'custom provider: "url" must be an absolute URL with scheme (got "$url")',
      );
    }
  }

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'url': url,
    'method': method,
    'headers': headers,
  };
}

/// Uploads directly to Supabase Storage via the standard object endpoint:
/// `$projectUrl/storage/v1/object/$bucket/$path`.
///
/// The caller's [accessToken] must have insert (and if [upsert] is true, also
/// update) permissions on the bucket.
class SupabaseUploadProvider extends UploadProvider {
  final String projectUrl;
  final String bucket;
  final String? pathPrefix;
  final String accessToken;
  final bool upsert;
  final String contentType;

  const SupabaseUploadProvider({
    required this.projectUrl,
    required this.bucket,
    required this.accessToken,
    this.pathPrefix,
    this.upsert = true,
    this.contentType = 'application/octet-stream',
  });

  @override
  String get kind => 'supabase';

  @override
  void validate() {
    _require('projectUrl', projectUrl);
    _require('bucket', bucket);
    _require('accessToken', accessToken);
    if (Uri.tryParse(projectUrl)?.hasScheme != true) {
      throw MediaBackupConfigurationException(
        'supabase provider: "projectUrl" must include scheme (got "$projectUrl")',
      );
    }
  }

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'projectUrl': projectUrl,
    'bucket': bucket,
    'pathPrefix': pathPrefix,
    'accessToken': accessToken,
    'upsert': upsert,
    'contentType': contentType,
  };
}

/// Uploads to AWS S3 using SigV4 with `UNSIGNED-PAYLOAD` so no local content
/// hashing is required. Works with any S3-compatible backend by overriding
/// [endpoint] (e.g. MinIO, Cloudflare R2).
class S3UploadProvider extends UploadProvider {
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
  final String region;
  final String bucket;
  final String? pathPrefix;

  /// Override for S3-compatible services. When null, AWS S3 is used.
  /// Example for R2: `https://<account>.r2.cloudflarestorage.com`.
  final String? endpoint;

  final bool usePathStyle;
  final String contentType;

  const S3UploadProvider({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    required this.bucket,
    this.sessionToken,
    this.pathPrefix,
    this.endpoint,
    this.usePathStyle = false,
    this.contentType = 'application/octet-stream',
  });

  @override
  String get kind => 's3';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'sessionToken': sessionToken,
    'region': region,
    'bucket': bucket,
    'pathPrefix': pathPrefix,
    'endpoint': endpoint,
    'usePathStyle': usePathStyle,
    'contentType': contentType,
  };
}

/// Uploads to Google Cloud Storage via the JSON API (`/upload/storage/v1/b/...`).
/// [accessToken] is a Bearer OAuth2 access token.
class GcsUploadProvider extends UploadProvider {
  final String bucket;
  final String? pathPrefix;
  final String accessToken;
  final String contentType;

  const GcsUploadProvider({
    required this.bucket,
    required this.accessToken,
    this.pathPrefix,
    this.contentType = 'application/octet-stream',
  });

  @override
  String get kind => 'gcs';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'bucket': bucket,
    'pathPrefix': pathPrefix,
    'accessToken': accessToken,
    'contentType': contentType,
  };
}

/// Uploads to Azure Blob Storage. Supply either a SAS-token URL pattern
/// ([sasToken] appended to the container URL) or a pre-authenticated
/// [sharedKey] + [accountName] (less common).
class AzureBlobUploadProvider extends UploadProvider {
  final String accountName;
  final String container;
  final String? pathPrefix;

  /// SAS token (without leading `?`). When set, used as query string.
  final String? sasToken;

  final String contentType;

  const AzureBlobUploadProvider({
    required this.accountName,
    required this.container,
    required this.sasToken,
    this.pathPrefix,
    this.contentType = 'application/octet-stream',
  });

  @override
  String get kind => 'azure_blob';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'accountName': accountName,
    'container': container,
    'pathPrefix': pathPrefix,
    'sasToken': sasToken,
    'contentType': contentType,
  };
}

/// Uploads to Firebase Storage via the public REST endpoint.
/// [idToken] is the Firebase auth ID token (from `signInWith...`).
class FirebaseStorageUploadProvider extends UploadProvider {
  final String bucket;
  final String? pathPrefix;
  final String idToken;
  final String contentType;

  const FirebaseStorageUploadProvider({
    required this.bucket,
    required this.idToken,
    this.pathPrefix,
    this.contentType = 'application/octet-stream',
  });

  @override
  String get kind => 'firebase_storage';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'bucket': bucket,
    'pathPrefix': pathPrefix,
    'idToken': idToken,
    'contentType': contentType,
  };
}

/// Simulates an upload without making any network request. Useful while the
/// real backend isn't ready or for end-to-end tests of the pipeline
/// (scan → queue → mark done).
class TestUploadProvider extends UploadProvider {
  final Duration simulatedLatency;
  final double failureRate;

  const TestUploadProvider({
    this.simulatedLatency = const Duration(milliseconds: 250),
    this.failureRate = 0.0,
  }) : assert(
         failureRate >= 0.0 && failureRate <= 1.0,
         'failureRate must be in [0,1]',
       );

  @override
  String get kind => 'test';

  @override
  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind,
    'simulatedLatencyMs': simulatedLatency.inMilliseconds,
    'failureRate': failureRate,
  };
}

UploadProvider resolveProvider({
  UploadProvider? provider,
  String? legacyUploadUrl,
  Map<String, String>? legacyHeaders,
}) {
  if (provider != null) return provider;
  if (legacyUploadUrl != null) {
    return CustomUploadProvider(
      url: legacyUploadUrl,
      headers: legacyHeaders ?? const <String, String>{},
    );
  }
  throw const MediaBackupConfigurationException(
    'No upload provider configured. Pass settings.provider or settings.uploadUrl.',
  );
}
