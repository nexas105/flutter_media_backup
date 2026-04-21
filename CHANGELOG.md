## 0.1.0

Initial public release.

### Features

- **Photo library scanning** with cursor-resumable batches and incremental follow-up scans (`creationDate > lastScan OR modificationDate > lastScan`)
- **Real-time delta observation** via `PHPhotoLibraryChangeObserver` (new captures, edits, deletions)
- **Pre-staging queue** decouples PHAsset extraction (iCloud download) from upload — slow downloads never block upload slots
- **Byte-based upload concurrency** (`maxInFlightBytes`, default 300 MB) instead of fixed task counts
- **Resumable uploads** for files >50 MB: TUS v1.0.0 (Supabase) and S3 multipart, with crash-recovery via persisted offset
- **Push-based upload events** via `EventChannel` — per-asset started/progress/completed/failed + aggregate status counts
- **7 upload providers**: Supabase, S3 (+ R2/MinIO), GCS, Azure Blob, Firebase Storage, Custom HTTP, Test (simulated)
- **Retry with exponential backoff** + jitter; retriable vs permanent failure classification
- **Background execution**: background `URLSession`, graceful-exit grace period, `BGProcessingTask`
- **Logging**: OSLog + rotating file + native-to-Dart bridge for `flutter run` console
- **Runtime control**: start/stop/pause/resume, retry-failed, status counts, full DB reset with optional auto-restart

### Platforms

- iOS 13.0+
