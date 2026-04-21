# media_backup

Flutter plugin for iOS media indexing + uploading to a cloud storage backend (Supabase, S3, GCS, Azure, Firebase, or any custom HTTP endpoint). Keeps an SQLite queue on-device, reacts to Photo Library changes in real time, and handles retries + provider-specific upload shape.

iOS only for now. Android is a future addition.

## What it does

- Asks for Photo Library permission
- Scans the library into a local SQLite DB, resumable via cursor if the scan gets interrupted
- **Incremental follow-up scans**: after the initial full scan, subsequent scans only fetch assets created or modified since the last completed scan — reduces re-scan time from minutes to sub-second at 100k+ assets
- Observes `PHPhotoLibraryChangeObserver` for live deltas (new captures, edits, deletions)
- **Pre-staging queue**: extraction (iCloud download + temp file write) runs in a separate pool from upload, so a slow iCloud download never blocks an upload slot
- **Byte-based concurrency**: upload concurrency is governed by a byte budget (`maxInFlightBytes`, default 300 MB) instead of a fixed task count — prevents 3 concurrent 4K photo bursts from saturating temp storage
- Picks pending assets from the queue ordered newest-first (configurable) and uploads them via `URLSession`
- **Resumable uploads**: files above 50 MB use TUS protocol (Supabase) or S3 multipart, so a 10 GB video interrupted at 9 GB resumes from the last chunk — not from zero
- Retries transient failures with exponential backoff + jitter, marks permanent failures as failed
- Classifies non-iCloud-only assets and (optionally) triggers iCloud download before upload
- **Push-based upload events**: a `Stream<UploadEvent>` delivers per-asset progress, completion, and failure events via `EventChannel` — no polling needed for responsive UI
- Logs everything to OSLog, a rotating log file, and — in debug — to the Flutter console via a native-to-Dart bridge
- Exposes runtime control: start/pause, retry-failed, status counts, DB reset (with or without auto-restart)

## Install

```yaml
dependencies:
  media_backup:
    path: ../path/to/media_backup
```

Minimum iOS: `13.0`.

Add to `Info.plist`:
```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>We need access to your photos to back them up.</string>
```

## Quick start

```dart
import 'package:media_backup/media_backup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await MediaBackup.configure(
    settings: MediaBackupSettings(
      enableDeltaObserver: true,
      startUploader: true,
      maxInFlightBytes: 300 * 1024 * 1024, // 300 MB byte budget
      extractionConcurrency: 2,             // 2 concurrent PHAsset extractions
      maxConcurrentUploads: 6,              // hard cap on URLSession tasks
      remoteFolder: 'my_app/user_42',
      provider: const SupabaseUploadProvider(
        projectUrl: 'https://<project>.supabase.co',
        bucket: 'media-backup',
        accessToken: '<token>',
      ),
      ios: MediaBackupIosSettings(
        uploadOrder: UploadOrder.newestFirst,
        downloadFromICloud: true,
        useBackgroundSession: false,
      ),
    ),
  );

  final init = await MediaBackup.instance.initialize();
  if (init.permissionGranted) {
    await MediaBackup.instance.loadAssetsToDatabase();
  }

  runApp(const MyApp());
}
```

Use from anywhere after configure:
```dart
MediaBackup.instance.uploader.start();
MediaBackup.instance.uploader.pause();
await MediaBackup.instance.uploader.retryFailed();
final counts = await MediaBackup.instance.uploader.statusCounts();
print('${counts.done}/${counts.total}'); // 230/10280
await MediaBackup.instance.resetDatabase(autoRestart: true);
```

### Upload event stream

Listen for per-asset progress instead of polling:
```dart
MediaBackup.instance.uploader.events.listen((event) {
  switch (event) {
    case UploadStartedEvent e:
      print('Started: ${e.localIdentifier} (${e.fileBytes} bytes)');
    case UploadProgressEvent e:
      print('Progress: ${(e.fraction * 100).toInt()}%');
    case UploadCompletedEvent e:
      print('Done: ${e.localIdentifier}');
    case UploadFailedEvent e:
      print('Failed: ${e.error} (willRetry: ${e.willRetry})');
    case StatusCountsEvent e:
      print('Counts: ${e.done}/${e.total}');
  }
});
```

`statusCounts()` polling still works as a fallback; the event stream is additive.

### Asset query API

Query the backup database to build custom UIs — gallery views, progress screens, remote file browsers:

```dart
// All uploaded images, newest first, paginated
final uploaded = await MediaBackup.instance.queryAssets(
  const AssetQuery(
    status: BackupStatus.done,
    mediaType: BackupMediaType.image,
    limit: 20,
    offset: 0,
    sortBy: AssetSortBy.uploadedAt,
  ),
);

for (final asset in uploaded) {
  print('${asset.localIdentifier} -> ${asset.remotePath}');
  print('  ${asset.pixelWidth}x${asset.pixelHeight}, uploaded ${asset.uploadedAt}');
}

// Single asset lookup
final asset = await MediaBackup.instance.getAsset('PHAsset/123');
if (asset != null && asset.isDone) {
  final downloadUrl = buildSignedUrl(asset.remotePath!);
}

// Fast count without loading rows
final failedCount = await MediaBackup.instance.countAssets(
  status: BackupStatus.failed,
);
final videoCount = await MediaBackup.instance.countAssets(
  mediaType: BackupMediaType.video,
);
```

`BackupAsset` exposes all metadata: `localIdentifier`, `mediaType`, `pixelWidth/Height`, `duration`, `createdAt`, `modifiedAt`, `uploadStatus`, `remotePath`, `uploadedAt`, `lastError`, `retryCount`, `isFavorite`, `isHidden`.

The `remotePath` is the actual object key used during upload — use it to generate signed download URLs, verify remote existence, or display in a file browser.

## Upload providers

Pick one of the bundled providers or plug your own backend via `CustomUploadProvider`:

| Provider | Auth | Endpoint | Resumable |
|---|---|---|---|
| `CustomUploadProvider` | your headers | your URL | -- |
| `SupabaseUploadProvider` | JWT (anon or user) | Supabase Storage REST | TUS v1.0.0 (>50 MB) |
| `S3UploadProvider` | Access Key + Secret (SigV4 with UNSIGNED-PAYLOAD) | AWS S3 or any S3-compatible service (R2, MinIO) via `endpoint` | S3 multipart (>50 MB) |
| `GcsUploadProvider` | OAuth2 Bearer | Google Cloud Storage JSON API | -- |
| `AzureBlobUploadProvider` | SAS token | Azure Blob | -- |
| `FirebaseStorageUploadProvider` | Firebase ID token | Firebase Storage REST | -- |
| `TestUploadProvider` | -- | simulated, no network calls | -- |

Object key convention:
```
<bucket>/<remoteFolder>/<provider.pathPrefix>/<assetId>
```

`remoteFolder` comes from `settings.remoteFolder` (+ optional `remoteSubfolder`). `pathPrefix` is provider-scoped (useful for fine-grained layout inside a bucket).

### Resumable uploads

Files larger than 50 MB automatically use resumable uploads when the provider supports it:

- **Supabase**: TUS v1.0.0 protocol via `/storage/v1/upload/resumable`. Chunks of 6 MB, offset persisted in SQLite for crash recovery.
- **S3**: Standard multipart upload (CreateMultipartUpload / UploadPart / CompleteMultipartUpload). Part size 8 MB.

Smaller files use the standard single-request upload. Resumable uploads run in the foreground URLSession (TUS/multipart requires sequential request chaining). The upload offset is persisted in the `resume_url` and `resume_offset` columns of the assets table, so an app kill mid-upload resumes from the last completed chunk.

## Configuration

### Core settings

| Field | Default | Effect |
|---|---|---|
| `maxInFlightBytes` | 300 MB | Maximum bytes actively being uploaded. Controls upload concurrency by byte budget. |
| `extractionConcurrency` | 2 | Number of concurrent PHAsset extractions (iCloud downloads). Decoupled from upload slots. |
| `maxConcurrentUploads` | 6 | Hard cap on simultaneous URLSession upload tasks. |
| `maxTempBytes` | 700 MB | Total temp disk usage cap (staged + uploading files). |
| `imageConcurrency` | 2 | Legacy — kept for backward compatibility. |
| `videoConcurrency` | 1 | Legacy — kept for backward compatibility. |

### iOS-specific settings

Nested under `MediaBackupSettings.ios`:

| Field | Default | Effect |
|---|---|---|
| `uploadOrder` | `newestFirst` | newest-first / oldest-first / any — what comes off the queue first |
| `downloadFromICloud` | `true` | `PHAssetResourceManager` is allowed to pull iCloud-only originals before upload; set false to only back up what's already on-device |
| `useBackgroundSession` | `false` | Use `URLSessionConfiguration.background(...)` so transfers keep running after app suspend/kill (requires AppDelegate wiring — see below). Leave off in the simulator: delegate callbacks are flaky there |

## Runtime control

### Uploader — `MediaBackup.instance.uploader`

| Method / Property | Purpose |
|---|---|
| `start()` / `resume()` | begin/resume processing pending queue |
| `stop()` / `pause()` | stop staging new uploads (in-flight tasks finish) |
| `retryFailed()` | move every `failed` row back to `pending` with `retry_count=0` — returns count |
| `statusCounts()` | returns typed `UploadStatusCounts` with `pending/uploading/done/failed/total/progress` |
| `snapshot()` | convenience wrapper — counts + timestamp |
| `events` | `Stream<UploadEvent>` — push-based per-asset events (started, progress, completed, failed, statusCounts) |

### Data access — `MediaBackup.instance`

| Method | Purpose |
|---|---|
| `queryAssets(AssetQuery)` | paginated, filterable query returning `List<BackupAsset>` with all metadata + `remotePath` |
| `getAsset(localIdentifier)` | single asset lookup by iOS `localIdentifier` |
| `countAssets(status?, mediaType?)` | fast count without loading rows |

## Retry + failure handling

Failures are classified:

- **Retriable** (`5xx`, `408`, `409`, `425`, `429`, network errors): asset stays `pending`, `retry_count` is incremented, `next_retry_at = now + min(3600s, 5s * 2^n) + jitter`. The pump re-wakes automatically when the earliest scheduled retry is due.
- **Permanent** (other `4xx`): marked `failed` with `last_error` capturing the response body snippet (capped at 8 KB) so the cause is obvious (bucket missing, RLS denial, missing header, invalid token).

Press **Retry failed** in the example UI or call `uploader.retryFailed()` to put them all back in the queue with a fresh retry-count.

## Logging

- Native logs land in OSLog (Console.app / filter by bundle id) + a rotating file at `ApplicationSupport/media_backup/logs/media_backup.log` (1 MB rotation).
- When `enableConsoleLogging` is true (default), native logs are bridged to Dart via a reverse MethodChannel so they appear in `flutter run` console with `flutter:` prefix.
- Dart logs go to `debugPrint` and the same log file.
- UI: the in-app **LogScreen** renders the tail of the file with copy-to-clipboard.

## Database reset

```dart
await MediaBackup.instance.resetDatabase(autoRestart: true);
```

Cancels all in-flight upload tasks (including resumable uploads), clears the staging temp directory, truncates `assets` + `scan_state` tables. When `autoRestart: true`, automatically re-runs scan -> delta observer -> uploader. With `false`, leaves the pipeline stopped.

## `.env` / `--dart-define` integration (example app)

The example app pulls credentials from `example/.env` at build time (never runtime). The `Makefile` converts each line into `--dart-define=KEY=VALUE` flags passed to `flutter run`.

```bash
make env:init     # copy .env.example -> .env
# edit .env with real values
make env:check    # list loaded keys (values masked)
make ios:sim      # run on booted simulator, .env values compiled in
make ios:dev      # run on first physical device
```

Secrets never enter your binary as a readable file — they're baked in as compile-time Dart constants via `String.fromEnvironment(...)`. Key aliases supported: `BUCKET` = `SUPABASE_BUCKET`, `ACCESSKEY` = `SUPABASE_ACCESS_TOKEN`, `FOLDER` = `REMOTE_FOLDER`.

## Background execution

Problem: a media-backup app needs to keep working when the user leaves. Uploads survive suspension via `URLSession.background`, but **extracting** an asset from the photo library (`PHAssetResourceManager.writeData`) requires the app to be running. If the user opens the app for 10 seconds, you get ~3 extractions + handoffs, and a library of 10k items would take weeks.

The plugin ships three co-operating mechanisms so backups progress even with short foreground windows.

### 1. Background `URLSession` for transfers

Flip this on:
```dart
ios: MediaBackupIosSettings(useBackgroundSession: true)
```

Uses `URLSessionConfiguration.background(withIdentifier: "<bundleId>.media_backup.upload")`. Files already on disk keep uploading while the app sleeps; iOS wakes the app briefly to deliver completion events. Then wire your AppDelegate so iOS' system completion-handler reaches the session:

```swift
// ios/Runner/AppDelegate.swift
import UIKit
import Flutter
import media_backup

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    MediaBackupPlugin.handleBackgroundSession(
      identifier: identifier,
      completionHandler: completionHandler
    )
  }
}
```

### 2. Graceful-exit grace period (`beginBackgroundTask`)

Automatic — no config needed. When the user suspends/backgrounds the app, iOS grants ~30 seconds. The plugin:

- Holds the grace window with `beginBackgroundTask`
- Triggers one last uploader pump so ready items get handed off to URLSession
- Ends the grace task at 25s (safety margin)

This bridges the gap where extraction is mid-flight when the app is closed — a few more items make it onto the URLSession queue before suspension.

### 3. `BGProcessingTask` — iOS wakes the app later (iOS 13+)

Automatic registration — you only need to opt in via Info.plist. iOS decides when to run it (typically idle + Wi-Fi + charging, often overnight). The plugin:

- Registers the task on first launch
- Requests reschedule on every `willResignActive`
- When iOS fires the task: runs a scan, starts the uploader, polls until the pending queue drains or 4 minutes elapse, then hands control back

This is the mechanism that lets a 10k-item library actually finish — iOS grants the app multiple minutes of "processing" time while it's plugged in, during which the plugin can extract + upload hundreds of assets per run.

**Required Info.plist** additions:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER).media_backup.bg_processing</string>
</array>

<key>UIBackgroundModes</key>
<array>
  <string>fetch</string>
  <string>processing</string>
</array>
```

The identifier string is derived from your app's bundle id: `<bundleId>.media_backup.bg_processing`.

### Limitations to plan around

- **`PHAssetResourceManager.writeData(...)` needs wall-time.** With the three mechanisms above, that wall-time comes from (a) app foreground, (b) the 30s grace window, or (c) the BGProcessingTask window. iOS background *fetch* windows (a few dozen seconds) are too short for bulk extraction.
- **Background URLSession uploads from a file, not in-memory data.** The plugin already writes to temp files, so this is handled.
- **Background URLSession doesn't handle HTTP auth challenges mid-flight.** OAuth-bearer backends (Supabase, GCS, Firebase) are fine. mTLS / on-the-fly token refresh is not.
- **Resumable uploads (TUS/S3 multipart) require foreground.** Chunked sequential requests can't run in a background URLSession. Simple uploads (<50 MB) work in background mode.
- **Simulator is flaky for background features.** Background sessions drop delegate callbacks, BGTasks don't fire reliably. Test on a real device.
- **iOS throttles.** iOS decides how often to run BGProcessingTasks based on device usage patterns. First-time users may see the task run once a day; consistent nightly usage trains the heuristic to fire more frequently.

## Architecture notes

- **SQLite is the source of truth.** Every state transition goes through it so the pipeline survives app kills and cold launches. WAL mode + `synchronous=NORMAL` for concurrent reader/writer access without lock contention.
- **Cursor-resumable scan.** The scanner writes a `scan_state.cursor_creation_ts` row after every batch; a killed scan picks up from `creationDate > cursor` on restart.
- **Incremental follow-up scans.** After the first full scan completes, subsequent scans use `creationDate > lastScan OR modificationDate > lastScan` to only fetch changed/new assets — sub-second at 100k+ items.
- **Pre-staging queue.** Extraction (PHAsset -> temp file) runs in a separate pool (`extractionConcurrency`, default 2) from upload. Staged files queue up and are consumed by the upload pump. An iCloud download blocking for 30s no longer idles an upload slot.
- **Byte-based upload concurrency.** The upload pump checks `activeUploadBytes + nextFile <= maxInFlightBytes` (default 300 MB) AND `activeTasks < maxConcurrentUploads` (default 6). Prevents 3 concurrent 4K photo bursts from saturating temp storage while allowing many small files in parallel.
- **Pre-upload scan guarantee.** `startUploader` and `appDidBecomeActive` both run a light scan first if none has completed in the last 5 min — no blind pumps against a stale DB.
- **Stable ordering.** Pending query uses `ORDER BY creation_ts, local_id` (desc or asc depending on `uploadOrder`). A late-inserted asset lands in its correct spot on the next pump, not at the end.
- **Composite covering index.** `idx_assets_pending_queue(upload_status, next_retry_at, creation_ts, local_id)` makes the pump query a direct index scan instead of a filesort.
- **Push-based events.** Native `EventChannel` pushes per-asset upload lifecycle events (started, progress, completed, failed) and aggregate status counts to Dart. Replaces polling for responsive UI.

## Roadmap

- Content-hash keying (SHA256) for server-side deduplication + resumption across device-restores. Today the object key is the iOS `localIdentifier` — which changes on restore.
- Wi-Fi-only toggle via `NWPathMonitor`.
- Android support.

## License

MIT.
