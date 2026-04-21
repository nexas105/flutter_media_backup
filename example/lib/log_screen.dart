import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_backup/media_backup.dart';

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  final _scrollController = ScrollController();
  String? _logFilePath;
  String _contents = '';
  int _sizeBytes = 0;
  bool _autoFollow = true;
  Timer? _poller;

  @override
  void initState() {
    super.initState();
    _load();
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _load());
  }

  @override
  void dispose() {
    _poller?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final file = await MediaBackup.instance.logFile();
    if (file == null) {
      if (!mounted) return;
      setState(() {
        _logFilePath = null;
        _contents = 'File logging is disabled (enableFileLogging: false).';
        _sizeBytes = 0;
      });
      return;
    }

    String contents;
    int size;
    try {
      contents = await file.readAsString();
      size = await file.length();
    } on FileSystemException catch (e) {
      contents = 'Unable to read log file: ${e.message}';
      size = 0;
    }

    if (!mounted) return;
    setState(() {
      _logFilePath = file.path;
      _contents = contents;
      _sizeBytes = size;
    });

    if (_autoFollow && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      });
    }
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _contents));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $_sizeBytes bytes to clipboard')),
    );
  }

  Future<void> _copyPath() async {
    if (_logFilePath == null) return;
    await Clipboard.setData(ClipboardData(text: _logFilePath!));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Log path copied')));
  }

  @override
  Widget build(BuildContext context) {
    final tail = _contents.length > 200_000
        ? _contents.substring(_contents.length - 200_000)
        : _contents;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            tooltip: _autoFollow ? 'Auto-scroll on' : 'Auto-scroll off',
            icon: Icon(
              _autoFollow ? Icons.vertical_align_bottom : Icons.pause,
            ),
            onPressed: () => setState(() => _autoFollow = !_autoFollow),
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Copy path',
            icon: const Icon(Icons.link),
            onPressed: _copyPath,
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyAll,
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              _logFilePath == null
                  ? 'no file'
                  : '${_logFilePath!} · ${(_sizeBytes / 1024).toStringAsFixed(1)} KB',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  tail.isEmpty ? '(empty)' : tail,
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
