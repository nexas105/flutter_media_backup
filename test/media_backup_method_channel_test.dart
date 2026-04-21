import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_backup/src/method_channel_media_backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelMediaBackup();
  const channel = MethodChannel('media_backup');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          switch (methodCall.method) {
            case 'getPlatformVersion':
              return '42';
            case 'requestPhotoPermission':
              return 'authorized';
            case 'loadAssetsToDatabase':
              return <String, dynamic>{
                'scannedCount': 2,
                'databasePath': '/tmp/assets.sqlite',
                'batchSize': 50,
              };
            case 'startDeltaObserver':
              return 'authorized';
            case 'stopDeltaObserver':
              return null;
            case 'configureUploader':
              return <String, dynamic>{
                'uploadUrl': 'https://example.com/upload',
                'imageConcurrency': 2,
                'videoConcurrency': 1,
                'maxTempBytes': 734003200,
              };
            case 'startUploader':
              return null;
            case 'stopUploader':
              return null;
            case 'getUploadStatusCounts':
              return <String, dynamic>{
                'pending': 1,
                'uploading': 0,
                'done': 3,
                'failed': 0,
              };
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('requestPhotoPermission', () async {
    expect(await platform.requestPhotoPermission(), 'authorized');
  });

  test('loadAssetsToDatabase', () async {
    final result = await platform.loadAssetsToDatabase(batchSize: 100);
    expect(result['scannedCount'], 2);
    expect(result['batchSize'], 50);
  });

  test('startDeltaObserver', () async {
    expect(await platform.startDeltaObserver(), 'authorized');
  });

  test('configureUploader', () async {
    final result = await platform.configureUploader(
      provider: const <String, dynamic>{
        'kind': 'custom',
        'url': 'https://example.com/upload',
        'method': 'POST',
        'headers': <String, String>{},
      },
    );
    expect(result['uploadUrl'], 'https://example.com/upload');
  });

  test('getUploadStatusCounts', () async {
    final counts = await platform.getUploadStatusCounts();
    expect(counts['done'], 3);
  });
}
