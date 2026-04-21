import 'package:flutter/services.dart';

abstract class MediaBackupException implements Exception {
  final String message;
  final String? code;
  final Object? cause;
  final StackTrace? stackTrace;

  const MediaBackupException(
    this.message, {
    this.code,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message');
    if (code != null) {
      buffer.write(' (code=$code)');
    }
    if (cause != null) {
      buffer.write(' cause=$cause');
    }
    return buffer.toString();
  }
}

class MediaBackupNotConfiguredException extends MediaBackupException {
  const MediaBackupNotConfiguredException()
    : super(
        'MediaBackup.configure(...) must be called before accessing instance.',
        code: 'NOT_CONFIGURED',
      );
}

class MediaBackupPermissionDeniedException extends MediaBackupException {
  final String permission;
  const MediaBackupPermissionDeniedException(this.permission)
    : super(
        'Photo library permission not granted: $permission',
        code: 'PERMISSION_DENIED',
      );
}

class MediaBackupChannelException extends MediaBackupException {
  const MediaBackupChannelException(
    super.message, {
    super.code,
    super.cause,
    super.stackTrace,
  });

  factory MediaBackupChannelException.fromPlatform(
    PlatformException e, [
    StackTrace? stackTrace,
  ]) {
    return MediaBackupChannelException(
      e.message ?? 'Platform error',
      code: e.code,
      cause: e,
      stackTrace: stackTrace,
    );
  }
}

class MediaBackupConfigurationException extends MediaBackupException {
  const MediaBackupConfigurationException(super.message)
    : super(code: 'INVALID_CONFIG');
}
