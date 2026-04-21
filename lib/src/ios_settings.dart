/// iOS-specific configuration. Accessed via [MediaBackupSettings.ios].
///
/// When future platforms (Android, Windows, macOS) are added, each gets its
/// own namespace — e.g. `MediaBackupAndroidSettings` under `.android`.
class MediaBackupIosSettings {
  /// Order in which pending assets are selected for upload. Default is
  /// [UploadOrder.newestFirst] — your most recent photos land in the cloud
  /// first, which is usually what users want to see progress on.
  final UploadOrder uploadOrder;

  /// When true, iOS' `PHAssetResourceManager` is allowed to download
  /// iCloud-only originals before upload. Set to false if you only want to
  /// back up media that's already fully on-device.
  final bool downloadFromICloud;

  /// Use `URLSessionConfiguration.background(withIdentifier:)` so transfers
  /// continue after app suspension/kill. Requires AppDelegate integration
  /// (see README). Leave off in development — the simulator drops delegate
  /// callbacks and makes debugging frustrating.
  final bool useBackgroundSession;

  const MediaBackupIosSettings({
    this.uploadOrder = UploadOrder.newestFirst,
    this.downloadFromICloud = true,
    this.useBackgroundSession = false,
  });
}

enum UploadOrder {
  /// `creation_ts ASC` — oldest media uploads first (good for full archival).
  oldestFirst,

  /// `creation_ts DESC` — newest media uploads first. Users see their
  /// recent captures backed up immediately. Default.
  newestFirst,

  /// Natural fetch order (no ORDER BY on creation). Cheapest query, no
  /// guarantees on sort stability.
  any,
}

extension UploadOrderWire on UploadOrder {
  String get wireValue {
    switch (this) {
      case UploadOrder.oldestFirst:
        return 'oldest_first';
      case UploadOrder.newestFirst:
        return 'newest_first';
      case UploadOrder.any:
        return 'any';
    }
  }
}
