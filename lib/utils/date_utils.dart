import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AppDateUtils {
  /// Formats a date string (YYYY-MM-DD or ISO string) to display format
  /// Uses YYYY-MM-DD for storage/internal use
  static String formatDateForDisplay(String? dateString) {
    if (dateString == null || dateString.isEmpty) return '';
    
    try {
      // If it's already in YYYY-MM-DD format, return as is
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateString)) {
        return dateString;
      }
      
      // If it's an ISO string, parse and format to YYYY-MM-DD
      final date = DateTime.parse(dateString);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      // If parsing fails, return the original string
      return dateString;
    }
  }

  /// Formats a date string (YYYY-MM-DD or ISO string) to locale-aware display format
  /// For Chinese locales: YYYY-MM-DD
  /// For English and other locales: MM/DD/YYYY
  static String formatDateForDisplayLocalized(String? dateString, BuildContext context) {
    if (dateString == null || dateString.isEmpty) return '';
    
    try {
      final date = DateTime.parse(dateString);
      return formatDateNumeric(date, context);
    } catch (e) {
      // If parsing fails, return the original string
      return dateString;
    }
  }

  /// Formats a DateTime object to YYYY-MM-DD string
  static String formatDateOnly(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// Checks if a date string represents an overdue date
  static bool isOverdue(String? dateString) {
    if (dateString == null || dateString.isEmpty) return false;
    
    try {
      final date = DateTime.parse(dateString);
      return date.isBefore(DateTime.now());
    } catch (e) {
      return false;
    }
  }

  /// Formats a DateTime object to a localized numeric date string (yyyy-mm-dd or mm/dd/yyyy)
  /// Defaults to mm/dd/yyyy if locale is not supported
  static String formatDateNumeric(DateTime date, BuildContext context) {
    final locale = Localizations.localeOf(context);
    
    // Use short date pattern based on locale
    // For Chinese locales, use yyyy-mm-dd format
    // For other locales (English and default), use mm/dd/yyyy format
    if (locale.languageCode == 'zh') {
      return DateFormat('yyyy-MM-dd').format(date);
    } else {
      // Default to mm/dd/yyyy for English and other locales
      return DateFormat('MM/dd/yyyy').format(date);
    }
  }
}
