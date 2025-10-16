import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/user_app_library.dart';
import '../models/user_app_library_dependency.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';

class UserAppLibraryService {
  static final UserAppLibraryService _instance = UserAppLibraryService._internal();
  factory UserAppLibraryService() => _instance;
  UserAppLibraryService._internal();

  final DatabaseService _databaseService = DatabaseService();

  /// Add a library to a user app with its dependencies
  Future<UserAppLibrary> addLibrary({
    required String appUuid,
    required int revisionId,
    required String name,
    String? usageInstructions,
    required List<LibraryDependency> dependencies,
  }) async {
    try {
      // Insert the library
      final libraryId = await _databaseService.insertUserAppLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        usageInstructions: usageInstructions,
      );

      // Insert all dependencies
      for (final dependency in dependencies) {
        await _databaseService.insertUserAppLibraryDependency(
          originalUrl: dependency.originalUrl,
          localPath: dependency.localPath,
          bytes: dependency.bytes,
          libraryId: libraryId,
        );
      }

      LoggerService.info('Added library "$name" with ${dependencies.length} dependencies');

      return UserAppLibrary(
        id: libraryId,
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        usageInstructions: usageInstructions,
      );
    } catch (e) {
      LoggerService.error('Error adding library: $e', error: e);
      rethrow;
    }
  }

  /// Download and add a library from a URL
  Future<UserAppLibrary> addLibraryFromUrl({
    required String appUuid,
    required int revisionId,
    required String name,
    required String baseUrl,
    required List<String> filePaths,
    String? usageInstructions,
  }) async {
    try {
      final dependencies = <LibraryDependency>[];

      // Download each file
      for (final filePath in filePaths) {
        final url = '$baseUrl/$filePath';
        LoggerService.debug('Downloading: $url');
        
        final response = await http.get(Uri.parse(url));
        if (response.statusCode == 200) {
          dependencies.add(LibraryDependency(
            originalUrl: url,
            localPath: filePath,
            bytes: response.bodyBytes,
          ));
        } else {
          LoggerService.warning('Failed to download $url: ${response.statusCode}');
        }
      }

      return await addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        usageInstructions: usageInstructions,
        dependencies: dependencies,
      );
    } catch (e) {
      LoggerService.error('Error adding library from URL: $e', error: e);
      rethrow;
    }
  }

  /// Add a library from local files
  Future<UserAppLibrary> addLibraryFromFiles({
    required String appUuid,
    required int revisionId,
    required String name,
    required Map<String, String> filePaths, // localPath -> filePath
    String? usageInstructions,
  }) async {
    try {
      final dependencies = <LibraryDependency>[];

      // Read each file
      for (final entry in filePaths.entries) {
        final localPath = entry.key;
        final filePath = entry.value;
        
        final file = File(filePath);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          dependencies.add(LibraryDependency(
            originalUrl: null,
            localPath: localPath,
            bytes: bytes,
          ));
        } else {
          LoggerService.warning('File not found: $filePath');
        }
      }

      return await addLibrary(
        appUuid: appUuid,
        revisionId: revisionId,
        name: name,
        usageInstructions: usageInstructions,
        dependencies: dependencies,
      );
    } catch (e) {
      LoggerService.error('Error adding library from files: $e', error: e);
      rethrow;
    }
  }

  /// Get all libraries for an app and revision
  Future<List<UserAppLibrary>> getLibraries(String appUuid, int revisionId) async {
    try {
      final libraryMaps = await _databaseService.getUserAppLibraries(appUuid, revisionId);
      return libraryMaps.map((map) => UserAppLibrary(
        id: map['id'] as int,
        appUuid: map['app_uuid'] as String,
        revisionId: map['revision_id'] as int,
        name: map['name'] as String,
        usageInstructions: map['usage_instructions'] as String?,
      )).toList();
    } catch (e) {
      LoggerService.error('Error getting libraries: $e', error: e);
      rethrow;
    }
  }

  /// Get all dependencies for a library
  Future<List<UserAppLibraryDependency>> getDependencies(int libraryId) async {
    try {
      final dependencyMaps = await _databaseService.getUserAppLibraryDependencies(libraryId);
      return dependencyMaps.map((map) => UserAppLibraryDependency(
        id: map['id'] as int,
        originalUrl: map['original_url'] as String?,
        localPath: map['local_path'] as String,
        bytes: List<int>.from(map['bytes'] as List),
        libraryId: map['library_id'] as int,
      )).toList();
    } catch (e) {
      LoggerService.error('Error getting dependencies: $e', error: e);
      rethrow;
    }
  }

  /// Delete a library and all its dependencies
  Future<void> deleteLibrary(int libraryId) async {
    try {
      await _databaseService.deleteUserAppLibrary(libraryId);
      LoggerService.info('Deleted library with ID: $libraryId');
    } catch (e) {
      LoggerService.error('Error deleting library: $e', error: e);
      rethrow;
    }
  }
}

/// Helper class for library dependencies
class LibraryDependency {
  final String? originalUrl;
  final String localPath;
  final List<int> bytes;

  const LibraryDependency({
    this.originalUrl,
    required this.localPath,
    required this.bytes,
  });
}
