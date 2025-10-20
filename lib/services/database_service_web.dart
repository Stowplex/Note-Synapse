// Web-specific database initialization
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

void initializeDatabaseFactory() {
  // For web platform, initialize with sqflite_common_ffi_web
  databaseFactory = databaseFactoryFfiWeb;
}
