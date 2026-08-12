import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/protocol_study.dart';

typedef ProtocolWorkspaceRootProvider = Future<Directory> Function();

/// Route-scoped access to the raw Protocol Study workspace.
///
/// The default root is app-private application-support storage, outside the
/// notes database and attachment tree. Callers must explicitly hold this
/// instance; it is intentionally not registered in the global service locator.
class ProtocolStudyWorkspace {
  ProtocolStudyWorkspace({ProtocolWorkspaceRootProvider? rootProvider})
    : _rootProvider = rootProvider ?? _defaultRoot;

  final ProtocolWorkspaceRootProvider _rootProvider;
  static const _platform = MethodChannel('note_synapse/protocol_study');
  static const _maxSerializedStudyBytes = 100 * 1024 * 1024;

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'protocol_study_workspace'));
  }

  Future<List<ProtocolStudy>> listStudies() async {
    final root = await _ensureRoot();
    final studies = <ProtocolStudy>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = p.basename(entity.path);
      if (!_validId(id)) continue;
      final study = await load(id);
      if (study != null) studies.add(study);
    }
    studies.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return studies;
  }

  Future<ProtocolStudy?> load(String id) async {
    _requireValidId(id);
    final directory = p.join((await _ensureRoot()).path, id);
    final target = File(p.join(directory, 'study.json'));
    final temporary = File(p.join(directory, 'study.json.tmp'));
    final backup = File(p.join(directory, 'study.json.bak'));
    for (final candidate in [target, temporary, backup]) {
      final study = await _read(candidate);
      if (study == null) continue;
      if (candidate.path != target.path) {
        try {
          if (await target.exists()) await target.delete();
          await candidate.rename(target.path);
        } on FileSystemException {
          // Returning the recovered value is still safe if repair cannot be
          // persisted (for example, storage became read-only).
        }
      }
      return study;
    }
    return null;
  }

  Future<void> save(ProtocolStudy study) async {
    _requireValidId(study.id);
    final root = await _ensureRoot();
    final directory = Directory(p.join(root.path, study.id));
    await directory.create(recursive: true);
    final target = File(p.join(directory.path, 'study.json'));
    final temporary = File(p.join(directory.path, 'study.json.tmp'));
    final backup = File(p.join(directory.path, 'study.json.bak'));
    await temporary.writeAsString(jsonEncode(study.toJson()), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  Future<void> delete(String id) async {
    _requireValidId(id);
    final directory = Directory(p.join((await _ensureRoot()).path, id));
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Directory> _ensureRoot() async {
    final directory = await _rootProvider();
    await directory.create(recursive: true);
    // Android excludes this relative files/ path through backup_rules.xml.
    // iOS needs the NSURLIsExcludedFromBackupKey resource value on the actual
    // directory. Tests and unsupported platforms intentionally skip it.
    if (!kIsWeb && Platform.isIOS) {
      try {
        await _platform.invokeMethod<void>('excludeFromBackup', {
          'path': directory.path,
        });
      } on MissingPluginException {
        // Unit tests and pre-migration builds do not have the native channel.
      }
    }
    return directory;
  }

  Future<ProtocolStudy?> _read(File file) async {
    try {
      if (!await file.exists() ||
          await file.length() > _maxSerializedStudyBytes) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      return ProtocolStudy.fromJson(Map<String, dynamic>.from(decoded as Map));
    } catch (_) {
      return null;
    }
  }

  static void _requireValidId(String id) {
    if (!_validId(id)) throw ArgumentError.value(id, 'id', 'invalid study ID');
  }

  static bool _validId(String id) =>
      id.isNotEmpty &&
      id.length <= 100 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);
}
