import 'dart:io';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';

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
}
