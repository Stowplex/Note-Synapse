class AppDateUtils {
  /// Formats a date string (YYYY-MM-DD or ISO string) to display format (YYYY-MM-DD)
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
}
