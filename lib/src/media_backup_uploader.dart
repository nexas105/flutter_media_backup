import 'media_backup_logger.dart';
import 'media_backup_platform_interface.dart';
import 'upload_events.dart';

/// Runtime control + state for the upload pipeline. Get it via
/// [MediaBackup.uploader]. All methods are safe to call any time after
/// `MediaBackup.configure(...)` has resolved.
///
/// Keeps the upload concerns separate from the configuration-shaped
/// [MediaBackup] surface so UI/business logic only depends on what it needs.
class MediaBackupUploader {
  MediaBackupUploader();

  static const _tag = 'Uploader';

  /// Begin (or resume) processing pending assets.
  Future<void> start() {
    MediaBackupLogger.instance.info(_tag, 'start');
    return MediaBackupPlatform.instance.startUploader();
  }

  /// Stop staging new uploads. Currently in-flight `URLSessionUploadTask`s
  /// continue to completion and report their result normally.
  Future<void> stop() {
    MediaBackupLogger.instance.info(_tag, 'stop');
    return MediaBackupPlatform.instance.stopUploader();
  }

  /// Semantic alias for [stop] — use when the user temporarily pauses.
  Future<void> pause() => stop();

  /// Semantic alias for [start] — use when the user resumes after a pause.
  Future<void> resume() => start();

  /// Returns counts grouped by upload status:
  /// `{ pending, uploading, done, failed }`. Missing keys default to 0.
  Future<UploadStatusCounts> statusCounts() async {
    final raw = await MediaBackupPlatform.instance.getUploadStatusCounts();
    return UploadStatusCounts.fromMap(raw);
  }

  /// Reset every `failed` row back to `pending` so they get picked up on the
  /// next pump. Useful after recovering from a transient backend outage or
  /// after rotating credentials.
  ///
  /// Returns the number of rows that were moved.
  Future<int> retryFailed() async {
    MediaBackupLogger.instance.info(_tag, 'retryFailed');
    final result = await MediaBackupPlatform.instance.retryFailedUploads();
    final retried = (result['retriedCount'] as num?)?.toInt() ?? 0;
    MediaBackupLogger.instance.info(
      _tag,
      'retryFailed result',
      context: {'retried': retried},
    );
    return retried;
  }

  /// Convenience: snapshot of every progress-relevant value in one call.
  Future<UploadSnapshot> snapshot() async {
    final counts = await statusCounts();
    return UploadSnapshot(counts: counts);
  }

  /// Push-based stream of per-asset upload events from native.
  /// Replaces polling `statusCounts()` for responsive UI updates.
  Stream<UploadEvent> get events =>
      MediaBackupPlatform.instance.uploadEvents;
}

class UploadStatusCounts {
  final int pending;
  final int uploading;
  final int done;
  final int failed;

  const UploadStatusCounts({
    required this.pending,
    required this.uploading,
    required this.done,
    required this.failed,
  });

  factory UploadStatusCounts.fromMap(Map<String, dynamic> raw) {
    int read(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return UploadStatusCounts(
      pending: read('pending'),
      uploading: read('uploading'),
      done: read('done'),
      failed: read('failed'),
    );
  }

  int get total => pending + uploading + done + failed;
  double get progress => total == 0 ? 0.0 : done / total;

  Map<String, int> toMap() => <String, int>{
    'pending': pending,
    'uploading': uploading,
    'done': done,
    'failed': failed,
  };

  @override
  String toString() =>
      'UploadStatusCounts(pending: $pending, uploading: $uploading, done: $done, failed: $failed)';
}

class UploadSnapshot {
  final UploadStatusCounts counts;
  final DateTime takenAt;

  UploadSnapshot({required this.counts, DateTime? takenAt})
    : takenAt = takenAt ?? DateTime.now();
}
