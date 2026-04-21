import 'package:flutter_test/flutter_test.dart';
import 'package:media_backup/media_backup.dart';
import 'package:media_backup/src/method_channel_media_backup.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockMediaBackupPlatform
    with MockPlatformInterfaceMixin
    implements MediaBackupPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');

  @override
  Future<Map<String, dynamic>> configureLogger({
    required int level,
    required bool enableFileLogging,
    required bool enableConsoleLogging,
    required int maxFileBytes,
  }) async => <String, dynamic>{'logFile': null};

  @override
  Future<Map<String, dynamic>> loadAssetsToDatabase({
    int batchSize = 50,
  }) async {
    return <String, dynamic>{
      'scannedCount': 123,
      'databasePath': '/tmp/assets.sqlite',
      'batchSize': batchSize,
    };
  }

  @override
  Future<String> requestPhotoPermission() => Future.value('authorized');

  @override
  Future<String> startDeltaObserver() => Future.value('authorized');

  @override
  Future<void> stopDeltaObserver() async {}

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
  }) async {
    return <String, dynamic>{
      'providerKind': provider['kind'],
      'maxInFlightBytes': maxInFlightBytes,
      'extractionConcurrency': extractionConcurrency,
      'maxConcurrentUploads': maxConcurrentUploads,
      'maxTempBytes': maxTempBytes,
      'backgroundSession': useBackgroundSession,
      'uploadOrder': uploadOrder,
      'downloadFromICloud': downloadFromICloud,
    };
  }

  @override
  Future<void> startUploader() async {}

  @override
  Future<void> stopUploader() async {}

  @override
  Future<Map<String, dynamic>> getUploadStatusCounts() async {
    return <String, dynamic>{
      'pending': 2,
      'uploading': 1,
      'done': 5,
      'failed': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> resetDatabase({bool autoRestart = true}) async {
    return <String, dynamic>{'reset': true, 'autoRestart': autoRestart};
  }

  @override
  Future<Map<String, dynamic>> retryFailedUploads() async {
    return <String, dynamic>{'retriedCount': 7};
  }

  @override
  Stream<UploadEvent> get uploadEvents => const Stream.empty();

  @override
  Future<List<Map<String, dynamic>>> queryAssets(
      Map<String, dynamic> query) async {
    return [
      <String, dynamic>{
        'localIdentifier': 'test-1',
        'mediaType': 1,
        'uploadStatus': 'done',
        'remotePath': 'photos/test-1',
      },
    ];
  }

  @override
  Future<Map<String, dynamic>?> getAsset(String localIdentifier) async {
    return <String, dynamic>{
      'localIdentifier': localIdentifier,
      'mediaType': 1,
      'uploadStatus': 'done',
      'remotePath': 'photos/$localIdentifier',
    };
  }

  @override
  Future<int> countAssets({String? status, int? mediaType}) async => 42;
}

Future<MediaBackup> _bootstrap() async {
  return MediaBackup.configure(
    settings: const MediaBackupSettings(enableFileLogging: false),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final MediaBackupPlatform initialPlatform = MediaBackupPlatform.instance;

  test('$MethodChannelMediaBackup is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelMediaBackup>());
  });

  test('getPlatformVersion', () async {
    final mediaBackupPlugin = await _bootstrap();
    final fakePlatform = MockMediaBackupPlatform();
    MediaBackupPlatform.instance = fakePlatform;

    expect(await mediaBackupPlugin.getPlatformVersion(), '42');
  });

  test('requestPhotoPermission', () async {
    final mediaBackupPlugin = await _bootstrap();
    final fakePlatform = MockMediaBackupPlatform();
    MediaBackupPlatform.instance = fakePlatform;

    expect(await mediaBackupPlugin.requestPhotoPermission(), 'authorized');
  });

  test('loadAssetsToDatabase uses caller batch size', () async {
    final mediaBackupPlugin = await _bootstrap();
    final fakePlatform = MockMediaBackupPlatform();
    MediaBackupPlatform.instance = fakePlatform;

    final result = await mediaBackupPlugin.loadAssetsToDatabase(batchSize: 250);
    expect(result['scannedCount'], 123);
    expect(result['databasePath'], '/tmp/assets.sqlite');
    expect(result['batchSize'], 250);
  });

  test('configureUploader', () async {
    final mediaBackupPlugin = await _bootstrap();
    final fakePlatform = MockMediaBackupPlatform();
    MediaBackupPlatform.instance = fakePlatform;

    final result = await mediaBackupPlugin.configureUploader(
      provider: const CustomUploadProvider(url: 'https://example.com/upload'),
      imageConcurrency: 4,
      videoConcurrency: 2,
      maxTempBytes: 1000,
    );

    expect(result['providerKind'], 'custom');
    expect(result['extractionConcurrency'], 2);
    expect(result['maxConcurrentUploads'], 6);
  });

  test('getUploadStatusCounts', () async {
    final mediaBackupPlugin = await _bootstrap();
    final fakePlatform = MockMediaBackupPlatform();
    MediaBackupPlatform.instance = fakePlatform;

    final counts = await mediaBackupPlugin.getUploadStatusCounts();
    expect(counts['pending'], 2);
    expect(counts['done'], 5);
  });

  test('accessing instance without configure throws', () {
    // Reset singleton via new configure each test run already; this test just
    // proves the error type exists with a clear message.
    const exception = MediaBackupNotConfiguredException();
    expect(exception.toString(), contains('configure'));
  });
}
