import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum LogLevel { trace, debug, info, warn, error }

extension LogLevelLabel on LogLevel {
  String get label {
    switch (this) {
      case LogLevel.trace:
        return 'TRACE';
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warn:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }
}

class MediaBackupLogger {
  MediaBackupLogger._();

  static final MediaBackupLogger instance = MediaBackupLogger._();

  LogLevel _minLevel = LogLevel.info;
  bool _enableFile = true;
  int _maxFileBytes = 1024 * 1024;
  File? _logFile;
  IOSink? _sink;
  Future<void>? _initializing;
  final _queue = <String>[];
  bool _flushing = false;

  Future<void> configure({
    required LogLevel level,
    required bool enableFile,
    required int maxFileBytes,
  }) async {
    _minLevel = level;
    _enableFile = enableFile;
    _maxFileBytes = maxFileBytes;

    if (!_enableFile) {
      await _closeSink();
      return;
    }

    _initializing ??= _openSink();
    await _initializing;
  }

  Future<File?> currentLogFile() async {
    if (!_enableFile) return null;
    _initializing ??= _openSink();
    await _initializing;
    return _logFile;
  }

  void log(
    LogLevel level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) {
    if (level.index < _minLevel.index) return;

    final timestamp = DateTime.now().toUtc().toIso8601String();
    final buffer = StringBuffer()
      ..write(timestamp)
      ..write(' [')
      ..write(level.label)
      ..write('] ')
      ..write(tag)
      ..write(': ')
      ..write(message);

    if (context != null && context.isNotEmpty) {
      buffer
        ..write(' ')
        ..write(jsonEncode(context));
    }
    if (error != null) {
      buffer
        ..write(' | error=')
        ..write(error);
    }
    if (stackTrace != null && level == LogLevel.error) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }

    final line = buffer.toString();
    if (kDebugMode) {
      debugPrint(line);
    }

    if (_enableFile) {
      _queue.add(line);
      unawaited(_flush());
    }
  }

  void trace(String tag, String message, {Map<String, Object?>? context}) =>
      log(LogLevel.trace, tag, message, context: context);
  void debug(String tag, String message, {Map<String, Object?>? context}) =>
      log(LogLevel.debug, tag, message, context: context);
  void info(String tag, String message, {Map<String, Object?>? context}) =>
      log(LogLevel.info, tag, message, context: context);
  void warn(
    String tag,
    String message, {
    Object? error,
    Map<String, Object?>? context,
  }) =>
      log(LogLevel.warn, tag, message, error: error, context: context);
  void error(
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) =>
      log(
        LogLevel.error,
        tag,
        message,
        error: error,
        stackTrace: stackTrace,
        context: context,
      );

  Future<void> _openSink() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final logsDir = Directory('${dir.path}/media_backup/logs');
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }
      final file = File('${logsDir.path}/media_backup.log');
      if (await file.exists()) {
        final size = await file.length();
        if (size > _maxFileBytes) {
          final rotated = File('${logsDir.path}/media_backup.1.log');
          if (await rotated.exists()) {
            await rotated.delete();
          }
          await file.rename(rotated.path);
        }
      }
      _logFile = file;
      _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[media_backup] Failed to open log file: $e');
      }
      _enableFile = false;
    }
  }

  Future<void> _flush() async {
    if (_sink == null || _flushing) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final line = _queue.removeAt(0);
        _sink!.writeln(line);
      }
      await _sink!.flush();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[media_backup] Log flush failed: $e');
      }
    } finally {
      _flushing = false;
    }
    if (_queue.isNotEmpty) {
      unawaited(_flush());
    }
  }

  Future<void> _closeSink() async {
    try {
      await _sink?.flush();
      await _sink?.close();
    } catch (_) {}
    _sink = null;
    _logFile = null;
    _initializing = null;
  }
}
