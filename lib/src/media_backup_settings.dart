import 'ios_settings.dart';
import 'media_backup_logger.dart';
import 'upload_providers.dart';

class MediaBackupSettings {
  final int batchSize;
  final bool enableDeltaObserver;
  final bool startUploader;

  /// Preferred upload configuration. Pick one of [CustomUploadProvider],
  /// [SupabaseUploadProvider], [S3UploadProvider], [GcsUploadProvider],
  /// [AzureBlobUploadProvider], [FirebaseStorageUploadProvider] or
  /// [TestUploadProvider].
  final UploadProvider? provider;

  /// Legacy shortcut — builds a [CustomUploadProvider] automatically when
  /// [provider] is null.
  final String? uploadUrl;
  final Map<String, String> headers;

  /// Top-level folder under which uploads are stored. Composed with
  /// [remoteSubfolder] (and the provider's own `pathPrefix` if any) into the
  /// final object key, e.g. `users/123/photos/<asset>`.
  final String? remoteFolder;
  final String? remoteSubfolder;

  final int imageConcurrency;
  final int videoConcurrency;
  final int maxTempBytes;

  /// Maximum bytes actively being uploaded at once. Controls upload
  /// concurrency by byte budget instead of task count.
  /// Default: 300 MB (314572800).
  final int maxInFlightBytes;

  /// Number of concurrent PHAsset extractions (iCloud downloads).
  /// Decoupled from upload slots so extraction doesn't block uploads.
  final int extractionConcurrency;

  /// Hard cap on simultaneous URLSession upload tasks.
  final int maxConcurrentUploads;

  /// iOS-specific configuration (upload order, iCloud download, background
  /// session). Other platforms will get their own sub-namespace.
  final MediaBackupIosSettings ios;
  final LogLevel logLevel;
  final bool enableFileLogging;

  /// Pipes native (iOS) logs through stdout so they appear in the
  /// `flutter run` console alongside Dart logs. Default true — turn off
  /// only if console output is too noisy.
  final bool enableConsoleLogging;
  final int maxLogFileBytes;

  const MediaBackupSettings({
    this.batchSize = 50,
    this.enableDeltaObserver = false,
    this.startUploader = false,
    this.provider,
    this.uploadUrl,
    this.headers = const <String, String>{},
    this.remoteFolder,
    this.remoteSubfolder,
    this.imageConcurrency = 2,
    this.videoConcurrency = 1,
    this.maxTempBytes = 734003200,
    this.maxInFlightBytes = 314572800,
    this.extractionConcurrency = 2,
    this.maxConcurrentUploads = 6,
    this.ios = const MediaBackupIosSettings(),
    this.logLevel = LogLevel.info,
    this.enableFileLogging = true,
    this.enableConsoleLogging = true,
    this.maxLogFileBytes = 1024 * 1024,
  });

  bool get hasUploadTarget => provider != null || uploadUrl != null;

  /// Joins [remoteFolder] and [remoteSubfolder] (skipping empty/null) into a
  /// `/`-separated path. Used by [MediaBackup] when serializing the provider
  /// so the final object key becomes `<composedRemoteFolder>/<assetId>`.
  String get composedRemoteFolder {
    final parts = <String>[];
    final f = remoteFolder?.trim();
    final s = remoteSubfolder?.trim();
    if (f != null && f.isNotEmpty) parts.add(f.replaceAll(RegExp(r'^/+|/+$'), ''));
    if (s != null && s.isNotEmpty) parts.add(s.replaceAll(RegExp(r'^/+|/+$'), ''));
    return parts.join('/');
  }
}
