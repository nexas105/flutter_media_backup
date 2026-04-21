/// A single asset from the backup database with all metadata and upload state.
///
/// Used to build custom UIs showing backup progress, remote paths, thumbnails,
/// or any other asset-level information.
class BackupAsset {
  final String localIdentifier;
  final BackupMediaType mediaType;
  final int mediaSubtypes;
  final DateTime? createdAt;
  final DateTime? modifiedAt;
  final double duration;
  final int pixelWidth;
  final int pixelHeight;
  final bool isFavorite;
  final bool isHidden;
  final int sourceType;
  final BackupStatus uploadStatus;
  final int retryCount;
  final String? lastError;
  final DateTime? uploadedAt;

  /// The remote object key / path where this asset was uploaded.
  /// Available after a successful upload. Use this to build download URLs,
  /// generate signed links, or verify remote existence.
  final String? remotePath;

  /// File size in bytes. Available after extraction (before upload starts).
  final int? fileBytes;

  /// Original filename from the photo library (e.g. `IMG_1234.HEIC`).
  /// Available after extraction.
  final String? fileName;

  const BackupAsset({
    required this.localIdentifier,
    required this.mediaType,
    required this.mediaSubtypes,
    this.createdAt,
    this.modifiedAt,
    required this.duration,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.isFavorite,
    required this.isHidden,
    required this.sourceType,
    required this.uploadStatus,
    required this.retryCount,
    this.lastError,
    this.uploadedAt,
    this.remotePath,
    this.fileBytes,
    this.fileName,
  });

  factory BackupAsset.fromMap(Map<String, dynamic> m) {
    return BackupAsset(
      localIdentifier: m['localIdentifier'] as String? ?? '',
      mediaType: BackupMediaType.fromRaw(m['mediaType'] as int? ?? 0),
      mediaSubtypes: m['mediaSubtypes'] as int? ?? 0,
      createdAt: _optionalDateTime(m['creationTimestamp']),
      modifiedAt: _optionalDateTime(m['modificationTimestamp']),
      duration: (m['duration'] as num?)?.toDouble() ?? 0,
      pixelWidth: m['pixelWidth'] as int? ?? 0,
      pixelHeight: m['pixelHeight'] as int? ?? 0,
      isFavorite: m['isFavorite'] as bool? ?? false,
      isHidden: m['isHidden'] as bool? ?? false,
      sourceType: m['sourceType'] as int? ?? 0,
      uploadStatus: BackupStatus.fromString(m['uploadStatus'] as String? ?? 'pending'),
      retryCount: m['retryCount'] as int? ?? 0,
      lastError: m['lastError'] as String?,
      uploadedAt: _optionalDateTime(m['uploadedAt']),
      remotePath: m['remotePath'] as String?,
      fileBytes: (m['fileBytes'] as num?)?.toInt(),
      fileName: m['fileName'] as String?,
    );
  }

  bool get isImage => mediaType == BackupMediaType.image;
  bool get isVideo => mediaType == BackupMediaType.video;
  bool get isDone => uploadStatus == BackupStatus.done;
  bool get isPending => uploadStatus == BackupStatus.pending;
  bool get isFailed => uploadStatus == BackupStatus.failed;

  static DateTime? _optionalDateTime(dynamic value) {
    if (value == null || value is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (value.toDouble() * 1000).toInt(),
      isUtc: true,
    ).toLocal();
  }

  @override
  String toString() =>
      'BackupAsset($localIdentifier, $uploadStatus, remote: $remotePath)';
}

/// PHAssetMediaType mapping.
enum BackupMediaType {
  unknown(0),
  image(1),
  video(2),
  audio(3);

  final int raw;
  const BackupMediaType(this.raw);

  static BackupMediaType fromRaw(int raw) {
    return BackupMediaType.values.firstWhere(
      (e) => e.raw == raw,
      orElse: () => BackupMediaType.unknown,
    );
  }
}

enum BackupStatus {
  pending,
  uploading,
  done,
  failed;

  static BackupStatus fromString(String s) {
    return BackupStatus.values.firstWhere(
      (e) => e.name == s,
      orElse: () => BackupStatus.pending,
    );
  }
}

/// Query parameters for [MediaBackup.queryAssets].
class AssetQuery {
  /// Filter by upload status. Null = all statuses.
  final BackupStatus? status;

  /// Filter by media type. Null = all types.
  final BackupMediaType? mediaType;

  /// Max results to return. Default 50.
  final int limit;

  /// Offset for pagination. Default 0.
  final int offset;

  /// Column to sort by. Default `createdAt`.
  final AssetSortBy sortBy;

  /// Sort direction. Default descending (newest first).
  final bool ascending;

  const AssetQuery({
    this.status,
    this.mediaType,
    this.limit = 50,
    this.offset = 0,
    this.sortBy = AssetSortBy.createdAt,
    this.ascending = false,
  });

  Map<String, dynamic> toMap() => <String, dynamic>{
    if (status != null) 'status': status!.name,
    if (mediaType != null) 'mediaType': mediaType!.raw,
    'limit': limit,
    'offset': offset,
    'sortBy': sortBy.column,
    'ascending': ascending,
  };
}

enum AssetSortBy {
  createdAt('creation_ts'),
  modifiedAt('modification_ts'),
  uploadedAt('uploaded_at');

  final String column;
  const AssetSortBy(this.column);
}
