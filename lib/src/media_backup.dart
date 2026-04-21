import 'dart:io';

import 'ios_settings.dart';
import 'media_backup_errors.dart';
import 'media_backup_logger.dart';
import 'media_backup_platform_interface.dart';
import 'media_backup_settings.dart';
import 'media_backup_uploader.dart';
import 'upload_providers.dart';

class MediaBackup {
  MediaBackup._(this.settings);

  static const _tag = 'MediaBackup';

  static MediaBackup? _instance;

  final MediaBackupSettings settings;

  /// Runtime control + state for the upload pipeline. Use this surface from
  /// UI code that needs to start/stop/pause uploads or display counts —
  /// keeps the upload concerns separate from the configuration class.
  late final MediaBackupUploader uploader = MediaBackupUploader();

  static bool get isConfigured => _instance != null;

  static MediaBackup get instance {
    final i = _instance;
    if (i == null) {
      throw const MediaBackupNotConfiguredException();
    }
    return i;
  }

  static Future<MediaBackup> configure({
    MediaBackupSettings settings = const MediaBackupSettings(),
  }) async {
    await MediaBackupLogger.instance.configure(
      level: settings.logLevel,
      enableFile: settings.enableFileLogging,
      maxFileBytes: settings.maxLogFileBytes,
    );

    try {
      await MediaBackupPlatform.instance.configureLogger(
        level: settings.logLevel.index,
        enableFileLogging: settings.enableFileLogging,
        enableConsoleLogging: settings.enableConsoleLogging,
        maxFileBytes: settings.maxLogFileBytes,
      );
    } catch (e, st) {
      MediaBackupLogger.instance.warn(
        _tag,
        'Native logger configuration failed',
        error: e,
        context: {'stack': st.toString()},
      );
    }

    final backup = MediaBackup._(settings);
    _instance = backup;
    MediaBackupLogger.instance.info(
      _tag,
      'Configured',
      context: {
        'uploadUrl': settings.uploadUrl,
        'batchSize': settings.batchSize,
        'enableDeltaObserver': settings.enableDeltaObserver,
        'startUploader': settings.startUploader,
      },
    );
    return backup;
  }

  Future<File?> logFile() => MediaBackupLogger.instance.currentLogFile();

  Future<String?> getPlatformVersion() {
    return MediaBackupPlatform.instance.getPlatformVersion();
  }

  Future<String> requestPhotoPermission() async {
    final status = await MediaBackupPlatform.instance.requestPhotoPermission();
    MediaBackupLogger.instance.info(
      _tag,
      'Permission status',
      context: {'status': status},
    );
    return status;
  }

  Future<Map<String, dynamic>> loadAssetsToDatabase({int? batchSize}) async {
    MediaBackupLogger.instance.debug(_tag, 'loadAssetsToDatabase');
    try {
      final result = await MediaBackupPlatform.instance.loadAssetsToDatabase(
        batchSize: batchSize ?? settings.batchSize,
      );
      MediaBackupLogger.instance.info(
        _tag,
        'Scan complete',
        context: {
          'scannedCount': result['scannedCount'],
          'statusCounts': result['statusCounts'],
        },
      );
      return result;
    } catch (e, st) {
      MediaBackupLogger.instance.error(
        _tag,
        'loadAssetsToDatabase failed',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<String> startDeltaObserver() async {
    MediaBackupLogger.instance.debug(_tag, 'startDeltaObserver');
    final status = await MediaBackupPlatform.instance.startDeltaObserver();
    MediaBackupLogger.instance.info(
      _tag,
      'Delta observer',
      context: {'status': status},
    );
    return status;
  }

  Future<void> stopDeltaObserver() {
    MediaBackupLogger.instance.debug(_tag, 'stopDeltaObserver');
    return MediaBackupPlatform.instance.stopDeltaObserver();
  }

  Future<Map<String, dynamic>> configureUploader({
    UploadProvider? provider,
    int? imageConcurrency,
    int? videoConcurrency,
    int? maxTempBytes,
    int? maxInFlightBytes,
    int? extractionConcurrency,
    int? maxConcurrentUploads,
  }) {
    final effective = resolveProvider(
      provider: provider ?? settings.provider,
      legacyUploadUrl: settings.uploadUrl,
      legacyHeaders: settings.headers,
    );

    effective.validate();

    final providerMap = Map<String, dynamic>.from(effective.toMap());
    final composedFolder = settings.composedRemoteFolder;
    if (composedFolder.isNotEmpty) {
      final existing = (providerMap['pathPrefix'] as String?)?.trim() ?? '';
      providerMap['pathPrefix'] = existing.isEmpty
          ? composedFolder
          : '$composedFolder/${existing.replaceAll(RegExp(r'^/+|/+$'), '')}';
    }

    MediaBackupLogger.instance.info(
      _tag,
      'configureUploader',
      context: {
        'providerKind': effective.kind,
        'pathPrefix': providerMap['pathPrefix'],
      },
    );

    return MediaBackupPlatform.instance.configureUploader(
      provider: providerMap,
      imageConcurrency: imageConcurrency ?? settings.imageConcurrency,
      videoConcurrency: videoConcurrency ?? settings.videoConcurrency,
      maxTempBytes: maxTempBytes ?? settings.maxTempBytes,
      maxInFlightBytes: maxInFlightBytes ?? settings.maxInFlightBytes,
      extractionConcurrency: extractionConcurrency ?? settings.extractionConcurrency,
      maxConcurrentUploads: maxConcurrentUploads ?? settings.maxConcurrentUploads,
      useBackgroundSession: settings.ios.useBackgroundSession,
      uploadOrder: settings.ios.uploadOrder.wireValue,
      downloadFromICloud: settings.ios.downloadFromICloud,
    );
  }

  Future<void> startUploader() {
    MediaBackupLogger.instance.info(_tag, 'startUploader');
    return MediaBackupPlatform.instance.startUploader();
  }

  Future<void> stopUploader() {
    MediaBackupLogger.instance.info(_tag, 'stopUploader');
    return MediaBackupPlatform.instance.stopUploader();
  }

  Future<Map<String, dynamic>> getUploadStatusCounts() {
    return MediaBackupPlatform.instance.getUploadStatusCounts();
  }

  /// Stops uploader + delta observer, wipes all DB tables and any staged
  /// upload temp files. When [autoRestart] is true (default), the pipeline
  /// restarts automatically (scan → delta observer → uploader) based on the
  /// components that were enabled before the reset.
  Future<Map<String, dynamic>> resetDatabase({bool autoRestart = true}) async {
    MediaBackupLogger.instance.warn(
      _tag,
      'resetDatabase',
      context: {'autoRestart': autoRestart},
    );
    final result = await MediaBackupPlatform.instance.resetDatabase(
      autoRestart: autoRestart,
    );
    MediaBackupLogger.instance.info(_tag, 'resetDatabase complete',
        context: result);
    return result;
  }

  Future<MediaBackupInitResult> initialize() async {
    final permission = await requestPhotoPermission();
    final permissionGranted =
        permission == 'authorized' || permission == 'limited';

    Map<String, dynamic>? uploaderConfig;
    if (settings.hasUploadTarget) {
      uploaderConfig = await configureUploader();

      if (settings.startUploader && permissionGranted) {
        await startUploader();
      }
    }

    String? deltaStatus;
    if (settings.enableDeltaObserver && permissionGranted) {
      deltaStatus = await startDeltaObserver();
    }

    return MediaBackupInitResult(
      permission: permission,
      permissionGranted: permissionGranted,
      batchSize: settings.batchSize,
      uploaderConfig: uploaderConfig,
      deltaStatus: deltaStatus,
    );
  }
}

class MediaBackupInitResult {
  final String permission;
  final bool permissionGranted;
  final int batchSize;
  final Map<String, dynamic>? uploaderConfig;
  final String? deltaStatus;

  const MediaBackupInitResult({
    required this.permission,
    required this.permissionGranted,
    required this.batchSize,
    required this.uploaderConfig,
    required this.deltaStatus,
  });

  bool get uploaderConfigured => uploaderConfig != null;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'permission': permission,
    'permissionGranted': permissionGranted,
    'batchSize': batchSize,
    'uploaderConfigured': uploaderConfigured,
    'uploaderConfig': uploaderConfig,
    'deltaStatus': deltaStatus,
  };
}
