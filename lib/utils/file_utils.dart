import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Utility class for file operations
class FileUtils {
  /// Opens a file using the platform's default application
  /// 
  /// This method handles platform-specific file opening, including Android intents.
  /// It provides comprehensive error handling and user feedback.
  /// 
  /// [filePath] - The path to the file to open
  /// [context] - The BuildContext for showing error messages
  /// 
  /// Returns true if the file was opened successfully, false otherwise
  static Future<bool> openFile(String filePath, BuildContext context) async {
    try {
      // Check if file exists
      final file = File(filePath);
      if (!file.existsSync()) {
        _showErrorSnackBar(context, 'File not found: ${filePath.split('/').last}');
        return false;
      }

      // Use open_file package for proper Android file handling
      final result = await OpenFile.open(filePath);
      
      if (result.type != ResultType.done) {
        String errorMessage = _getErrorMessage(result);
        _showErrorSnackBar(context, errorMessage);
        return false;
      }
      
      return true;
    } catch (e) {
      _showErrorSnackBar(context, 'Error opening file: $e');
      return false;
    }
  }


  /// Gets a user-friendly error message based on the OpenFile result type
  static String _getErrorMessage(dynamic result) {
    switch (result.type) {
      case ResultType.noAppToOpen:
        return 'No application found to open this file type';
      case ResultType.fileNotFound:
        return 'File not found';
      case ResultType.permissionDenied:
        return 'Permission denied to open file';
      case ResultType.error:
        return 'Error opening file: ${result.message}';
      default:
        return 'Unknown error opening file';
    }
  }

  /// Shows an error snackbar with the given message
  static void _showErrorSnackBar(BuildContext context, String message) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Gets the app's private storage directory for attachments
  /// This directory is persistent and won't be cleared by the system
  static Future<Directory> getPrivateStorageDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final attachmentsDir = Directory('${appDir.path}/attachments');
    if (!await attachmentsDir.exists()) {
      await attachmentsDir.create(recursive: true);
    }
    return attachmentsDir;
  }

  /// Generates a unique filename with UUID appended to avoid name clashes
  /// [originalFileName] - The original filename
  /// Returns a unique filename with UUID appended before the extension
  static String generateUniqueFileName(String originalFileName) {
    const uuid = Uuid();
    final uniqueId = uuid.v4();
    
    // Extract file extension
    final fileExtension = originalFileName.contains('.') ? '.${originalFileName.split('.').last}' : '';
    final baseFileName = originalFileName.contains('.') ? originalFileName.substring(0, originalFileName.lastIndexOf('.')) : originalFileName;
    
    // Create unique filename with UUID appended before extension
    // Format: basefilename_uuid.extension (e.g., document_abc123.pdf)
    return '${baseFileName}_$uniqueId$fileExtension';
  }

  /// Saves file data to the app's private storage with a unique filename
  /// [data] - The file data as bytes
  /// [originalFileName] - The original filename
  /// Returns the relative path to the saved file
  static Future<String> saveFileToPrivateStorage(List<int> data, String originalFileName) async {
    final attachmentsDir = await getPrivateStorageDirectory();
    final uniqueFileName = generateUniqueFileName(originalFileName);
    final file = File('${attachmentsDir.path}/$uniqueFileName');
    
    await file.writeAsBytes(data);
    
    // Return relative path from the app's documents directory
    final relativePath = 'attachments/$uniqueFileName';
    
    return relativePath;
  }

  /// Constructs the full file path from a relative path stored in the database
  /// [relativePath] - The relative path stored in the database
  /// [isRelativePath] - Whether the path is relative to app's private storage
  /// Returns the full file path
  static Future<String> getFullFilePath(String filePath, bool isRelativePath) async {
    if (isRelativePath) {
      final appDir = await getApplicationDocumentsDirectory();
      return '${appDir.path}/$filePath';
    } else {
      // Legacy absolute path - return as is
      return filePath;
    }
  }
}
