// IO-specific database initialization (for desktop platforms)
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/foundation.dart';

void initializeDatabaseFactory() {
  // Initialize database factory for desktop platforms
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // For mobile platforms, use the default databaseFactory from sqflite
}
