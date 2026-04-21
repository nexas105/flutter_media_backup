import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

/// Persists a per-install user UUID + surfaces the app's project identifier.
/// [remoteFolder] is what MediaBackup uses as the top-level path prefix:
/// `<projectName>/<userId>`.
class UserIdentity {
  UserIdentity._(this.projectName, this.userId);

  static const projectNameDefault = 'media_backup_example';

  final String projectName;
  final String userId;

  /// Top-level folder convention: `<projectName>/<userId>`.
  String get remoteFolder => '$projectName/$userId';

  static Future<UserIdentity> load({String projectName = projectNameDefault}) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/media_backup/user_id');

    String userId;
    if (await file.exists()) {
      userId = (await file.readAsString()).trim();
      if (userId.isEmpty) {
        userId = _generateUuidV4();
        await file.writeAsString(userId);
      }
    } else {
      await file.parent.create(recursive: true);
      userId = _generateUuidV4();
      await file.writeAsString(userId);
    }

    return UserIdentity._(projectName, userId);
  }

  /// Minimal RFC 4122 v4 (random). No extra deps.
  static String _generateUuidV4() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
