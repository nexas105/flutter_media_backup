import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'method_channel_media_backup.dart';
import 'upload_events.dart';

abstract class MediaBackupPlatform extends PlatformInterface {
  MediaBackupPlatform() : super(token: _token);

  static final Object _token = Object();

  static MediaBackupPlatform _instance = MethodChannelMediaBackup();

  static MediaBackupPlatform get instance => _instance;

  static set instance(MediaBackupPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  Future<Map<String, dynamic>> configureLogger({
    required int level,
    required bool enableFileLogging,
    required bool enableConsoleLogging,
    required int maxFileBytes,
  }) {
    throw UnimplementedError('configureLogger() has not been implemented.');
  }

  Future<String> requestPhotoPermission() {
    throw UnimplementedError(
      'requestPhotoPermission() has not been implemented.',
    );
  }

  Future<Map<String, dynamic>> loadAssetsToDatabase({int batchSize = 50}) {
    throw UnimplementedError(
      'loadAssetsToDatabase() has not been implemented.',
    );
  }

  Future<String> startDeltaObserver() {
    throw UnimplementedError('startDeltaObserver() has not been implemented.');
  }

  Future<void> stopDeltaObserver() {
    throw UnimplementedError('stopDeltaObserver() has not been implemented.');
  }

  Future<Map<String, dynamic>> configureUploader({
    required Map<String, dynamic> provider,
    int imageConcurrency = 2,
    int videoConcurrency = 1,
    int maxTempBytes = 734003200,
    int maxInFlightBytes = 314572800,
    int extractionConcurrency = 2,
    int maxConcurrentUploads = 6,
    bool useBackgroundSession = false,
    String uploadOrder = 'newest_first',
    bool downloadFromICloud = true,
  }) {
    throw UnimplementedError('configureUploader() has not been implemented.');
  }

  Future<void> startUploader() {
    throw UnimplementedError('startUploader() has not been implemented.');
  }

  Future<void> stopUploader() {
    throw UnimplementedError('stopUploader() has not been implemented.');
  }

  Future<Map<String, dynamic>> getUploadStatusCounts() {
    throw UnimplementedError(
      'getUploadStatusCounts() has not been implemented.',
    );
  }

  Future<Map<String, dynamic>> resetDatabase({bool autoRestart = true}) {
    throw UnimplementedError('resetDatabase() has not been implemented.');
  }

  Future<Map<String, dynamic>> retryFailedUploads() {
    throw UnimplementedError('retryFailedUploads() has not been implemented.');
  }

  Stream<UploadEvent> get uploadEvents {
    throw UnimplementedError('uploadEvents has not been implemented.');
  }

  Future<List<Map<String, dynamic>>> queryAssets(Map<String, dynamic> query) {
    throw UnimplementedError('queryAssets() has not been implemented.');
  }

  Future<Map<String, dynamic>?> getAsset(String localIdentifier) {
    throw UnimplementedError('getAsset() has not been implemented.');
  }

  Future<int> countAssets({String? status, int? mediaType}) {
    throw UnimplementedError('countAssets() has not been implemented.');
  }
}
