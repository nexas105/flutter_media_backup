import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'media_backup_errors.dart';
import 'media_backup_logger.dart';
import 'media_backup_platform_interface.dart';
import 'upload_events.dart';

class MethodChannelMediaBackup extends MediaBackupPlatform {
  static const _tag = 'MethodChannel';

  @visibleForTesting
  final methodChannel = const MethodChannel('media_backup');

  MethodChannelMediaBackup() {
    methodChannel.setMethodCallHandler(_handleHostCall);
  }

  Future<dynamic> _handleHostCall(MethodCall call) async {
    if (call.method == '__nativeLog') {
      final args = call.arguments;
      if (args is Map) {
        final line = args['line'];
        if (line is String) {
          // Re-emit as Flutter-prefixed line so it appears alongside Dart logs
          // in `flutter run` console.
          // ignore: avoid_print
          debugPrint(line);
        }
      }
      return null;
    }
    return null;
  }

  Future<T> _invoke<T>(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final result = await methodChannel.invokeMethod<T>(method, arguments);
      return result as T;
    } on PlatformException catch (e, st) {
      MediaBackupLogger.instance.error(
        _tag,
        'Method "$method" failed',
        error: e,
        stackTrace: st,
      );
      throw MediaBackupChannelException.fromPlatform(e, st);
    }
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final result = await methodChannel.invokeMapMethod<String, dynamic>(
        method,
        arguments,
      );
      return result == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(result);
    } on PlatformException catch (e, st) {
      MediaBackupLogger.instance.error(
        _tag,
        'Method "$method" failed',
        error: e,
        stackTrace: st,
      );
      throw MediaBackupChannelException.fromPlatform(e, st);
    }
  }

  @override
  Future<String?> getPlatformVersion() {
    return _invoke<String?>('getPlatformVersion');
  }

  @override
  Future<Map<String, dynamic>> configureLogger({
    required int level,
    required bool enableFileLogging,
    required bool enableConsoleLogging,
    required int maxFileBytes,
  }) {
    return _invokeMap('configureLogger', {
      'level': level,
      'enableFileLogging': enableFileLogging,
      'enableConsoleLogging': enableConsoleLogging,
      'maxFileBytes': maxFileBytes,
    });
  }

  @override
  Future<String> requestPhotoPermission() async {
    final status = await _invoke<String?>('requestPhotoPermission');
    return status ?? 'unknown';
  }

  @override
  Future<Map<String, dynamic>> loadAssetsToDatabase({int batchSize = 50}) {
    return _invokeMap('loadAssetsToDatabase', {'batchSize': batchSize});
  }

  @override
  Future<String> startDeltaObserver() async {
    final status = await _invoke<String?>('startDeltaObserver');
    return status ?? 'unknown';
  }

  @override
  Future<void> stopDeltaObserver() async {
    await _invoke<void>('stopDeltaObserver');
  }

  @override
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
    return _invokeMap('configureUploader', {
      'provider': provider,
      'imageConcurrency': imageConcurrency,
      'videoConcurrency': videoConcurrency,
      'maxTempBytes': maxTempBytes,
      'maxInFlightBytes': maxInFlightBytes,
      'extractionConcurrency': extractionConcurrency,
      'maxConcurrentUploads': maxConcurrentUploads,
      'useBackgroundSession': useBackgroundSession,
      'uploadOrder': uploadOrder,
      'downloadFromICloud': downloadFromICloud,
    });
  }

  @override
  Future<void> startUploader() async {
    await _invoke<void>('startUploader');
  }

  @override
  Future<void> stopUploader() async {
    await _invoke<void>('stopUploader');
  }

  @override
  Future<Map<String, dynamic>> getUploadStatusCounts() {
    return _invokeMap('getUploadStatusCounts');
  }

  @override
  Future<Map<String, dynamic>> resetDatabase({bool autoRestart = true}) {
    return _invokeMap('resetDatabase', {'autoRestart': autoRestart});
  }

  @override
  Future<Map<String, dynamic>> retryFailedUploads() {
    return _invokeMap('retryFailedUploads');
  }

  @visibleForTesting
  final eventChannel = const EventChannel('media_backup/upload_events');

  Stream<UploadEvent>? _uploadEvents;

  @override
  Stream<UploadEvent> get uploadEvents {
    return _uploadEvents ??= eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) =>
            UploadEvent.fromMap(Map<String, dynamic>.from(event as Map)));
  }

  @override
  Future<List<Map<String, dynamic>>> queryAssets(
      Map<String, dynamic> query) async {
    final result = await methodChannel.invokeListMethod<Map>(
        'queryAssets', query);
    return (result ?? [])
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  @override
  Future<Map<String, dynamic>?> getAsset(String localIdentifier) async {
    final result = await methodChannel.invokeMapMethod<String, dynamic>(
        'getAsset', {'localIdentifier': localIdentifier});
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  @override
  Future<int> countAssets({String? status, int? mediaType}) async {
    final result = await methodChannel.invokeMethod<int>(
        'countAssets', {
      'status': ?status,
      'mediaType': ?mediaType,
    });
    return result ?? 0;
  }
}
