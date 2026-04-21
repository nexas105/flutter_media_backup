import 'package:media_backup/media_backup.dart';

/// Build an [UploadProvider] from `--dart-define` values supplied via the
/// `.env` file at build time.
///
/// IMPORTANT: every `String.fromEnvironment(...)` must use a *literal* key —
/// the compiler only substitutes values for const expressions. Variables/loops
/// would always return the default.
class Env {
  // --- explicit overrides ----------------------------------------------------

  static const _explicitProvider = String.fromEnvironment('UPLOAD_PROVIDER');

  // --- folders (with aliases) ------------------------------------------------

  static const _remoteFolderPrimary = String.fromEnvironment('REMOTE_FOLDER');
  static const _remoteFolderAlias = String.fromEnvironment('FOLDER');
  static const _remoteSubfolderPrimary = String.fromEnvironment(
    'REMOTE_SUBFOLDER',
  );
  static const _remoteSubfolderAlias = String.fromEnvironment('SUBFOLDER');

  static String get remoteFolder =>
      _remoteFolderPrimary.isNotEmpty ? _remoteFolderPrimary : _remoteFolderAlias;

  static String get remoteSubfolder => _remoteSubfolderPrimary.isNotEmpty
      ? _remoteSubfolderPrimary
      : _remoteSubfolderAlias;

  // --- Supabase --------------------------------------------------------------

  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const _supabaseBucketPrimary = String.fromEnvironment(
    'SUPABASE_BUCKET',
  );
  static const _supabaseBucketAlias = String.fromEnvironment('BUCKET');
  static const _supabaseTokenPrimary = String.fromEnvironment(
    'SUPABASE_ACCESS_TOKEN',
  );
  static const _supabaseTokenAlias1 = String.fromEnvironment('ACCESS_TOKEN');
  static const _supabaseTokenAlias2 = String.fromEnvironment('ACCESSKEY');

  static String get supabaseBucket => _supabaseBucketPrimary.isNotEmpty
      ? _supabaseBucketPrimary
      : _supabaseBucketAlias;

  static String get supabaseAccessToken {
    if (_supabaseTokenPrimary.isNotEmpty) return _supabaseTokenPrimary;
    if (_supabaseTokenAlias1.isNotEmpty) return _supabaseTokenAlias1;
    return _supabaseTokenAlias2;
  }

  // --- Custom HTTP -----------------------------------------------------------

  static const customUploadUrl = String.fromEnvironment('CUSTOM_UPLOAD_URL');
  static const customAuthHeader = String.fromEnvironment('CUSTOM_AUTH_HEADER');

  // --- S3 --------------------------------------------------------------------

  static const s3AccessKeyId = String.fromEnvironment('S3_ACCESS_KEY_ID');
  static const s3SecretAccessKey = String.fromEnvironment(
    'S3_SECRET_ACCESS_KEY',
  );
  static const s3Region = String.fromEnvironment('S3_REGION');
  static const s3Bucket = String.fromEnvironment('S3_BUCKET');
  static const s3Endpoint = String.fromEnvironment('S3_ENDPOINT');
  static const s3UsePathStyle = bool.fromEnvironment('S3_USE_PATH_STYLE');

  // --- provider selection ----------------------------------------------------

  /// Explicit `UPLOAD_PROVIDER` wins. Otherwise infer from which credentials
  /// are populated.
  static String get providerKind {
    final explicit = _explicitProvider.toLowerCase();
    if (explicit.isNotEmpty) return explicit;
    if (supabaseUrl.isNotEmpty) return 'supabase';
    if (s3AccessKeyId.isNotEmpty) return 's3';
    if (customUploadUrl.isNotEmpty) return 'custom';
    return 'test';
  }

  // --- factory ---------------------------------------------------------------

  static UploadProvider buildProvider() {
    switch (providerKind) {
      case 'supabase':
        return SupabaseUploadProvider(
          projectUrl: supabaseUrl,
          bucket: supabaseBucket,
          accessToken: supabaseAccessToken,
        );
      case 'custom':
        return CustomUploadProvider(
          url: customUploadUrl,
          headers: customAuthHeader.isEmpty
              ? const <String, String>{}
              : {'Authorization': customAuthHeader},
        );
      case 's3':
        return S3UploadProvider(
          accessKeyId: s3AccessKeyId,
          secretAccessKey: s3SecretAccessKey,
          region: s3Region,
          bucket: s3Bucket,
          endpoint: s3Endpoint.isEmpty ? null : s3Endpoint,
          usePathStyle: s3UsePathStyle,
        );
      case 'test':
      default:
        return const TestUploadProvider(
          simulatedLatency: Duration(milliseconds: 300),
        );
    }
  }
}
