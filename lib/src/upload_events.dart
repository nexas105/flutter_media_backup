/// Push-based upload events streamed from native via EventChannel.
///
/// Replaces polling `statusCounts()` for responsive UI updates.
sealed class UploadEvent {
  const UploadEvent();

  factory UploadEvent.fromMap(Map<String, dynamic> map) {
    final event = map['event'] as String;
    return switch (event) {
      'started' => UploadStartedEvent(
          localIdentifier: map['localIdentifier'] as String,
          mediaType: (map['mediaType'] as num).toInt(),
          fileBytes: (map['fileBytes'] as num).toInt(),
        ),
      'progress' => UploadProgressEvent(
          localIdentifier: map['localIdentifier'] as String,
          bytesSent: (map['bytesSent'] as num).toInt(),
          totalBytes: (map['totalBytes'] as num).toInt(),
        ),
      'completed' => UploadCompletedEvent(
          localIdentifier: map['localIdentifier'] as String,
        ),
      'failed' => UploadFailedEvent(
          localIdentifier: map['localIdentifier'] as String,
          error: map['error'] as String? ?? '',
          willRetry: map['willRetry'] as bool? ?? false,
        ),
      'statusCounts' => StatusCountsEvent(
          pending: (map['pending'] as num?)?.toInt() ?? 0,
          uploading: (map['uploading'] as num?)?.toInt() ?? 0,
          done: (map['done'] as num?)?.toInt() ?? 0,
          failed: (map['failed'] as num?)?.toInt() ?? 0,
        ),
      _ => _UnknownUploadEvent(event),
    };
  }
}

class UploadStartedEvent extends UploadEvent {
  final String localIdentifier;
  final int mediaType;
  final int fileBytes;

  const UploadStartedEvent({
    required this.localIdentifier,
    required this.mediaType,
    required this.fileBytes,
  });
}

class UploadProgressEvent extends UploadEvent {
  final String localIdentifier;
  final int bytesSent;
  final int totalBytes;

  const UploadProgressEvent({
    required this.localIdentifier,
    required this.bytesSent,
    required this.totalBytes,
  });

  double get fraction => totalBytes > 0 ? bytesSent / totalBytes : 0;
}

class UploadCompletedEvent extends UploadEvent {
  final String localIdentifier;

  const UploadCompletedEvent({required this.localIdentifier});
}

class UploadFailedEvent extends UploadEvent {
  final String localIdentifier;
  final String error;
  final bool willRetry;

  const UploadFailedEvent({
    required this.localIdentifier,
    required this.error,
    required this.willRetry,
  });
}

class StatusCountsEvent extends UploadEvent {
  final int pending;
  final int uploading;
  final int done;
  final int failed;

  const StatusCountsEvent({
    required this.pending,
    required this.uploading,
    required this.done,
    required this.failed,
  });

  int get total => pending + uploading + done + failed;
}

class _UnknownUploadEvent extends UploadEvent {
  final String type;
  const _UnknownUploadEvent(this.type);
}
