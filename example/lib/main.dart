import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_backup/media_backup.dart';

import 'env_provider.dart';
import 'log_screen.dart';
import 'user_identity.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final identity = await UserIdentity.load();

  await MediaBackup.configure(
    settings: MediaBackupSettings(
      batchSize: 50,
      enableDeltaObserver: true,
      startUploader: true,
      // Byte-based concurrency (Tier 3)
      maxInFlightBytes: 300 * 1024 * 1024, // 300 MB upload byte budget
      extractionConcurrency: 2, // 2 concurrent iCloud extractions
      maxConcurrentUploads: 6, // hard cap on URLSession tasks
      maxTempBytes: 700 * 1024 * 1024,
      logLevel: LogLevel.info,
      remoteFolder: identity.remoteFolder,
      provider: Env.buildProvider(),
    ),
  );

  final init = await MediaBackup.instance.initialize();
  if (init.permissionGranted) {
    await MediaBackup.instance.loadAssetsToDatabase();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomeScreen());
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _platformVersion = 'Unknown';
  String? _logFilePath;
  UploadStatusCounts _counts = const UploadStatusCounts(
    pending: 0,
    uploading: 0,
    done: 0,
    failed: 0,
  );

  // Per-asset progress from the event stream
  final Map<String, double> _assetProgress = {};
  String? _lastEvent;
  StreamSubscription<UploadEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _refresh();
    _listenToEvents();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  /// Subscribe to the push-based upload event stream.
  void _listenToEvents() {
    _eventSub = MediaBackup.instance.uploader.events.listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case UploadStartedEvent e:
            _assetProgress[e.localIdentifier] = 0;
            _lastEvent = 'Started: ${_shortId(e.localIdentifier)}';
          case UploadProgressEvent e:
            _assetProgress[e.localIdentifier] = e.fraction;
          case UploadCompletedEvent e:
            _assetProgress.remove(e.localIdentifier);
            _lastEvent = 'Done: ${_shortId(e.localIdentifier)}';
          case UploadFailedEvent e:
            _assetProgress.remove(e.localIdentifier);
            _lastEvent =
                'Failed: ${_shortId(e.localIdentifier)} (${e.willRetry ? "retry" : "permanent"})';
          case StatusCountsEvent e:
            _counts = UploadStatusCounts(
              pending: e.pending,
              uploading: e.uploading,
              done: e.done,
              failed: e.failed,
            );
          default:
            break;
        }
      });
    });
  }

  static String _shortId(String id) =>
      id.length > 12 ? '${id.substring(0, 12)}...' : id;

  Future<void> _refresh() async {
    String platformVersion;
    try {
      platformVersion =
          await MediaBackup.instance.getPlatformVersion() ??
          'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    } on MediaBackupException catch (e) {
      platformVersion = 'MediaBackup error: ${e.message}';
    }

    final logFile = await MediaBackup.instance.logFile();
    final counts = await MediaBackup.instance.uploader.statusCounts();

    if (!mounted) return;
    setState(() {
      _platformVersion = platformVersion;
      _logFilePath = logFile?.path;
      _counts = counts;
    });
  }

  Future<void> _runUploader(Future<void> Function() action) async {
    try {
      await action();
    } on MediaBackupException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: ${e.message}')));
    }
    await _refresh();
  }

  Future<void> _retryFailed() async {
    try {
      final retried = await MediaBackup.instance.uploader.retryFailed();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Retried $retried failed uploads')),
      );
    } on MediaBackupException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Retry failed: ${e.message}')));
    }
    await _refresh();
  }

  Future<void> _reset({required bool autoRestart}) async {
    try {
      await MediaBackup.instance.resetDatabase(autoRestart: autoRestart);
    } on MediaBackupException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Reset failed: ${e.message}')));
      return;
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('media_backup example'),
        actions: [
          IconButton(
            tooltip: 'View logs',
            icon: const Icon(Icons.terminal),
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const LogScreen())),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Platform: $_platformVersion'),
            const SizedBox(height: 8),
            Text('Log file: ${_logFilePath ?? "—"}'),
            const SizedBox(height: 16),

            // Overall progress
            Text(
              'Upload progress',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: _counts.progress),
            const SizedBox(height: 4),
            Text(
              '${(_counts.progress * 100).toStringAsFixed(1)}% '
              '(${_counts.done}/${_counts.total}) — '
              'pending: ${_counts.pending}, '
              'uploading: ${_counts.uploading}, '
              'failed: ${_counts.failed}',
            ),
            const SizedBox(height: 16),

            // Live per-asset progress from EventChannel
            Text(
              'Active uploads (live)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            if (_assetProgress.isEmpty)
              Text(
                'No active uploads',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              ..._assetProgress.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(
                          _shortId(e.key),
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(value: e.value),
                      ),
                      const SizedBox(width: 8),
                      Text('${(e.value * 100).toInt()}%'),
                    ],
                  ),
                ),
              ),
            if (_lastEvent != null) ...[
              const SizedBox(height: 4),
              Text(
                _lastEvent!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
            ],

            const Spacer(),

            // Controls
            Text('Uploader', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () =>
                      _runUploader(MediaBackup.instance.uploader.resume),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Resume'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () =>
                      _runUploader(MediaBackup.instance.uploader.pause),
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                OutlinedButton.icon(
                  onPressed: _retryFailed,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry failed'),
                ),
                OutlinedButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.update),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Database', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.tonal(
                  onPressed: () => _reset(autoRestart: true),
                  child: const Text('Reset DB (restart)'),
                ),
                OutlinedButton(
                  onPressed: () => _reset(autoRestart: false),
                  child: const Text('Reset DB (stay stopped)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
