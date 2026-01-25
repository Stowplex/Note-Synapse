import 'package:sqlparser/sqlparser.dart';

import 'database_service.dart';
import 'logger_service.dart';
import 'service_locator.dart';

/// Callback type for requesting write operation approval.
/// Returns true if the user approves the write operation.
typedef WriteApprovalCallback =
    Future<bool> Function(
      SqlQueryService source,
      String sql,
      SqlQueryType queryType,
    );

/// The type of SQL query detected by parsing.
enum SqlQueryType {
  select,
  insert,
  update,
  delete,
  createTable,
  createIndex,
  createTrigger,
  createView,
  dropTable,
  dropIndex,
  dropTrigger,
  dropView,
  alterTable,
  pragma,
  other,
}

/// Result of executing a SQL query.
class SqlQueryResult {
  SqlQueryResult({
    required this.success,
    this.data,
    this.error,
    this.isReadOnly = true,
    this.wasApproved = false,
  });

  final bool success;
  final List<Map<String, dynamic>>? data;
  final String? error;
  final bool isReadOnly;
  final bool wasApproved;

  /// Format the result as a markdown table for display.
  String toMarkdownTable() {
    if (data == null || data!.isEmpty) return 'No results found.';

    final rows = data!;
    final headers = rows.first.keys.toList();
    final buffer = StringBuffer();

    buffer.write('| ${headers.join(' | ')} |\n');
    buffer.write('| ${headers.map((_) => '---').join(' | ')} |\n');

    for (final row in rows) {
      buffer.write(
        '| ${headers.map((h) => row[h]?.toString().replaceAll('\n', ' ') ?? '').join(' | ')} |\n',
      );
    }

    return buffer.toString();
  }

  /// Convert to a JSON-serializable map for JavaScript callbacks.
  Map<String, dynamic> toJson() {
    return {
      'success': success,
      if (data != null) 'data': data,
      if (error != null) 'error': error,
    };
  }
}

/// Shared service for SQL query parsing, validation, and execution.
///
/// This service consolidates SQL execution logic used by both the agentic mode
/// (RunSqlTool) and SynapseAPI (Synapse.runQuery). It provides:
/// - SQL parsing using the sqlparser package
/// - Query type detection (read-only vs write operations)
/// - Session-level approval for write operations
/// - Unified query execution with proper error handling
class SqlQueryService {
  SqlQueryService({
    this.onWriteApprovalRequest,
    DatabaseService? databaseService,
  }) : _injectedDatabaseService = databaseService;

  final DatabaseService? _injectedDatabaseService;

  /// Lazy-loaded database service from GetIt.
  DatabaseService get _databaseService =>
      _injectedDatabaseService ?? getIt<DatabaseService>();

  /// Callback to request user approval for write operations.
  WriteApprovalCallback? onWriteApprovalRequest;

  /// Whether write operations have been approved for this session.
  bool _sessionApprovedWrites = false;

  /// The SQL parser engine.
  static final SqlEngine _sqlEngine = SqlEngine();

  /// Approve all write operations for this session.
  void approveWritesForSession() {
    _sessionApprovedWrites = true;
    LoggerService.debug(
      '[SqlQueryService] Write operations approved for session',
    );
  }

  /// Reset session approval state.
  void resetSessionApproval() {
    _sessionApprovedWrites = false;
  }

  /// Check if write operations are approved for this session.
  bool get sessionApprovedWrites => _sessionApprovedWrites;

  /// Parse SQL and determine if it's a read-only query.
  ///
  /// Note: The sqlparser returns InvalidStatement for multi-statement SQL,
  /// which falls back to string detection. If getQueryType returns 'other',
  /// we treat it as non-read-only since we don't know what the query does.
  bool isReadOnlyQuery(String sql) {
    final queryType = getQueryType(sql);
    // Only SELECT and PRAGMA are definitively read-only
    // 'other' is treated as non-read-only for safety
    return queryType == SqlQueryType.select || queryType == SqlQueryType.pragma;
  }

  /// Detect the type of SQL query.
  SqlQueryType getQueryType(String sql) {
    try {
      final trimmedSql = sql.trim();
      final parseResult = _sqlEngine.parse(trimmedSql);

      if (parseResult.errors.isNotEmpty) {
        // If parsing fails, fall back to simple string-based detection
        LoggerService.debug(
          '[SqlQueryService] Parse error, using fallback detection: ${parseResult.errors.first}',
        );
        return _fallbackQueryTypeDetection(trimmedSql);
      }

      final rootNode = parseResult.rootNode;

      // Check statement type
      if (rootNode is SelectStatement) {
        return SqlQueryType.select;
      } else if (rootNode is InsertStatement) {
        return SqlQueryType.insert;
      } else if (rootNode is UpdateStatement) {
        return SqlQueryType.update;
      } else if (rootNode is DeleteStatement) {
        return SqlQueryType.delete;
      } else if (rootNode is CreateTableStatement) {
        return SqlQueryType.createTable;
      } else if (rootNode is CreateIndexStatement) {
        return SqlQueryType.createIndex;
      } else if (rootNode is CreateTriggerStatement) {
        return SqlQueryType.createTrigger;
      } else if (rootNode is CreateViewStatement) {
        return SqlQueryType.createView;
      }

      // For other statement types (including DROP), use fallback
      return _fallbackQueryTypeDetection(trimmedSql);
    } catch (e) {
      LoggerService.warning(
        '[SqlQueryService] Failed to parse SQL, using fallback: $e',
      );
      return _fallbackQueryTypeDetection(sql.trim());
    }
  }

  /// Fallback query type detection using simple string matching.
  SqlQueryType _fallbackQueryTypeDetection(String trimmedSql) {
    final upperSql = trimmedSql.toUpperCase();

    if (upperSql.startsWith('SELECT')) {
      return SqlQueryType.select;
    } else if (upperSql.startsWith('INSERT')) {
      return SqlQueryType.insert;
    } else if (upperSql.startsWith('UPDATE')) {
      return SqlQueryType.update;
    } else if (upperSql.startsWith('DELETE')) {
      return SqlQueryType.delete;
    } else if (upperSql.startsWith('CREATE TABLE')) {
      return SqlQueryType.createTable;
    } else if (upperSql.startsWith('CREATE INDEX')) {
      return SqlQueryType.createIndex;
    } else if (upperSql.startsWith('CREATE TRIGGER')) {
      return SqlQueryType.createTrigger;
    } else if (upperSql.startsWith('CREATE VIEW')) {
      return SqlQueryType.createView;
    } else if (upperSql.startsWith('DROP TABLE')) {
      return SqlQueryType.dropTable;
    } else if (upperSql.startsWith('DROP INDEX')) {
      return SqlQueryType.dropIndex;
    } else if (upperSql.startsWith('DROP TRIGGER')) {
      return SqlQueryType.dropTrigger;
    } else if (upperSql.startsWith('DROP VIEW')) {
      return SqlQueryType.dropView;
    } else if (upperSql.startsWith('ALTER')) {
      return SqlQueryType.alterTable;
    } else if (upperSql.startsWith('PRAGMA')) {
      return SqlQueryType.pragma;
    }

    return SqlQueryType.other;
  }

  /// Get a human-readable description of the query type.
  String getQueryTypeDescription(SqlQueryType queryType) {
    switch (queryType) {
      case SqlQueryType.select:
        return 'SELECT (read data)';
      case SqlQueryType.insert:
        return 'INSERT (add data)';
      case SqlQueryType.update:
        return 'UPDATE (modify data)';
      case SqlQueryType.delete:
        return 'DELETE (remove data)';
      case SqlQueryType.createTable:
        return 'CREATE TABLE';
      case SqlQueryType.createIndex:
        return 'CREATE INDEX';
      case SqlQueryType.createTrigger:
        return 'CREATE TRIGGER';
      case SqlQueryType.createView:
        return 'CREATE VIEW';
      case SqlQueryType.dropTable:
        return 'DROP TABLE';
      case SqlQueryType.dropIndex:
        return 'DROP INDEX';
      case SqlQueryType.dropTrigger:
        return 'DROP TRIGGER';
      case SqlQueryType.dropView:
        return 'DROP VIEW';
      case SqlQueryType.alterTable:
        return 'ALTER TABLE';
      case SqlQueryType.pragma:
        return 'PRAGMA';
      case SqlQueryType.other:
        return 'Other';
    }
  }

  /// Execute a SQL query with optional write operation approval.
  ///
  /// If [requireApprovalForWrites] is true (default) and the query is a write
  /// operation, this will either:
  /// - Execute immediately if session-approved
  /// - Request approval via [onWriteApprovalRequest] callback
  /// - Return an error if no callback is set and not approved
  ///
  /// If [allowWriteOperations] is false (default), write operations will be
  /// rejected without prompting for approval.
  Future<SqlQueryResult> executeQuery(
    String sql, {
    bool requireApprovalForWrites = true,
    bool allowWriteOperations = true,
    int maxRows = 50,
  }) async {
    final queryType = getQueryType(sql);
    final isReadOnly = isReadOnlyQuery(sql);

    LoggerService.debug(
      '[SqlQueryService] Executing query type: ${getQueryTypeDescription(queryType)}, read-only: $isReadOnly',
    );

    // If it's a write operation, check approval
    if (!isReadOnly) {
      if (!allowWriteOperations) {
        return SqlQueryResult(
          success: false,
          error: 'Only SELECT queries are allowed.',
          isReadOnly: false,
        );
      }

      if (requireApprovalForWrites && !_sessionApprovedWrites) {
        if (onWriteApprovalRequest != null) {
          final approved = await onWriteApprovalRequest!(this, sql, queryType);
          if (!approved) {
            return SqlQueryResult(
              success: false,
              error: 'User denied the write operation.',
              isReadOnly: false,
            );
          }
          LoggerService.debug(
            '[SqlQueryService] Write operation approved by user',
          );
        } else {
          return SqlQueryResult(
            success: false,
            error:
                'Write operations require user approval. No approval callback configured.',
            isReadOnly: false,
          );
        }
      }
    }

    // Execute the query
    try {
      final startTime = DateTime.now();
      final results = await _databaseService.runRawQuery(sql);
      final duration = DateTime.now().difference(startTime);

      LoggerService.debug(
        '[SqlQueryService] Query completed in ${duration.inMilliseconds}ms, returned ${results.length} rows',
      );

      // Truncate results if necessary
      final truncatedResults = results.length > maxRows
          ? results.take(maxRows).toList()
          : results;

      if (results.length > maxRows) {
        LoggerService.debug(
          '[SqlQueryService] Results truncated from ${results.length} to $maxRows rows',
        );
      }

      return SqlQueryResult(
        success: true,
        data: truncatedResults,
        isReadOnly: isReadOnly,
        wasApproved: !isReadOnly && _sessionApprovedWrites,
      );
    } catch (e) {
      LoggerService.error('[SqlQueryService] Query execution failed: $e');
      return SqlQueryResult(
        success: false,
        error: 'SQL query execution failed: $e',
        isReadOnly: isReadOnly,
      );
    }
  }
}
