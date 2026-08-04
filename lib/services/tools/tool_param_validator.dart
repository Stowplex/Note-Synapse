import 'dart:convert';

import 'tool_outcome.dart';

/// A single structural problem found in tool parameters.
class ToolParamViolation {
  /// JSON-path-like location, e.g. `modifications[0].modification`.
  final String path;
  final String expected;
  final String actual;

  const ToolParamViolation({
    required this.path,
    required this.expected,
    required this.actual,
  });

  @override
  String toString() => '$path: expected $expected, got $actual';
}

/// Conservative structural validator for tool parameters against a tool's
/// JSON-schema-shaped `inputSchema`, run at the dispatch boundary BEFORE
/// approval or execution.
///
/// Design rule: **fail open**. Only definite violations are flagged — the
/// kinds that would otherwise surface as raw Dart type-cast errors:
///
/// - a scalar (number/string/bool) where an object or array is declared
/// - an explicit `null` for a present key with a declared type
/// - an object/array where a scalar type is declared
/// - a missing required key
/// - a scalar value outside a declared scalar `enum`
///
/// - a number/bool where a string is declared, and a non-numeric string
///   where a number/integer is declared (native tools cast these and crash)
///
/// Deliberately NOT flagged (schemas drift from runtime tolerance):
/// - an ARRAY where an OBJECT is declared (e.g. `modification.link` is
///   declared as an object but its handler also accepts a bare array); the
///   reverse — an object where an array is declared — IS flagged
/// - numeric strings where a number/integer is declared (`"5"`)
/// - unknown/extra keys, unknown schema keywords (`oneOf`, `$ref`, ...),
///   schema-less parameters
class ToolParamValidator {
  static const int _maxDepth = 6;
  static const int _maxEchoedValueLength = 60;

  /// Returns a failure outcome when [params] definitely violate
  /// [inputSchema]; null when the call should proceed.
  static ToolOutcome? validationFailure({
    required String toolName,
    required Map<String, dynamic> params,
    required Map<String, dynamic>? inputSchema,
  }) {
    final violations = validate(params, inputSchema);
    if (violations.isEmpty) return null;

    final buffer = StringBuffer('Invalid arguments for $toolName: ');
    buffer.writeAll(violations, '; ');
    final hint = _schemaHintForFirstViolation(violations.first, inputSchema);
    if (hint != null) {
      buffer.write('. $hint');
    }
    final examples = inputSchema?['examples'];
    if (examples is List && examples.isNotEmpty) {
      try {
        buffer.write(' Example: ${jsonEncode(examples.first)}');
      } catch (_) {
        // Skip unencodable examples.
      }
    }
    buffer.write(
      ' Fix the arguments before calling again; '
      'do not resend the same arguments.',
    );

    return ToolOutcome.failure(
      code: ToolOutcome.codeInvalidArgument,
      message: buffer.toString(),
      data: {
        'violations': [
          for (final v in violations)
            {'path': v.path, 'expected': v.expected, 'actual': v.actual},
        ],
      },
    );
  }

  /// Structural check of [params] against [schema]. Empty list = proceed.
  static List<ToolParamViolation> validate(
    Map<String, dynamic> params,
    Map<String, dynamic>? schema,
  ) {
    if (schema == null || schema.isEmpty) return const [];
    final violations = <ToolParamViolation>[];
    _validateObject(params, schema, '', violations, 0);
    return violations;
  }

  static void _validateObject(
    Map<dynamic, dynamic> value,
    Map<String, dynamic> schema,
    String path,
    List<ToolParamViolation> violations,
    int depth,
  ) {
    if (depth >= _maxDepth) return;

    final properties = schema['properties'];
    if (properties is! Map) return;

    final required = schema['required'];
    if (required is List) {
      for (final key in required) {
        if (key is String && !value.containsKey(key)) {
          violations.add(
            ToolParamViolation(
              path: path.isEmpty ? key : '$path.$key',
              expected: 'required ${_declaredType(properties[key]) ?? 'value'}',
              actual: 'missing',
            ),
          );
        }
      }
    }

    for (final entry in value.entries) {
      final key = entry.key.toString();
      final propSchema = properties[key];
      if (propSchema is! Map) continue; // Extra/unknown keys pass.
      _validateValue(
        entry.value,
        propSchema.cast<String, dynamic>(),
        path.isEmpty ? key : '$path.$key',
        violations,
        depth + 1,
      );
    }
  }

  static void _validateValue(
    dynamic value,
    Map<String, dynamic> schema,
    String path,
    List<ToolParamViolation> violations,
    int depth,
  ) {
    if (depth >= _maxDepth) return;
    final declared = _declaredType(schema);
    if (declared == null) return; // No usable type keyword: pass.

    if (value == null) {
      violations.add(
        ToolParamViolation(
          path: path,
          expected: declared,
          actual: 'null (remove the key or provide a $declared)',
        ),
      );
      return;
    }

    switch (declared) {
      case 'object':
        if (_isScalar(value)) {
          violations.add(
            ToolParamViolation(
              path: path,
              expected: 'object',
              actual: _describe(value),
            ),
          );
        } else if (value is Map) {
          _validateObject(value, schema, path, violations, depth);
        }
        // Lists where an object is declared pass (runtime may normalize).
        break;
      case 'array':
        if (_isScalar(value) || value is Map) {
          violations.add(
            ToolParamViolation(
              path: path,
              expected: 'array',
              actual: _describe(value),
            ),
          );
        } else if (value is List) {
          final items = schema['items'];
          if (items is Map) {
            final itemSchema = items.cast<String, dynamic>();
            for (var i = 0; i < value.length; i++) {
              _validateValue(
                value[i],
                itemSchema,
                '$path[$i]',
                violations,
                depth + 1,
              );
            }
          }
        }
        break;
      case 'string':
      case 'number':
      case 'integer':
      case 'boolean':
        if (value is Map || value is List) {
          violations.add(
            ToolParamViolation(
              path: path,
              expected: declared,
              actual: _describe(value),
            ),
          );
          return;
        }
        if (_scalarKindMismatch(declared, value)) {
          violations.add(
            ToolParamViolation(
              path: path,
              expected: declared,
              actual: _describe(value),
            ),
          );
          return;
        }
        final enumValues = schema['enum'];
        if (enumValues is List &&
            enumValues.isNotEmpty &&
            enumValues.every((e) => e is String || e is num || e is bool) &&
            !enumValues.contains(value)) {
          violations.add(
            ToolParamViolation(
              path: path,
              expected: 'one of ${enumValues.join('|')}',
              actual: _describe(value),
            ),
          );
        }
        break;
      default:
        break; // Unknown declared type: pass.
    }
  }

  /// The declared `type`, when it is a single recognized string. Type arrays
  /// and unknown keywords make the property pass validation (fail open).
  static String? _declaredType(dynamic schema) {
    if (schema is! Map) return null;
    final type = schema['type'];
    if (type is! String) return null;
    const known = {
      'object',
      'array',
      'string',
      'number',
      'integer',
      'boolean',
    };
    return known.contains(type) ? type : null;
  }

  static bool _isScalar(dynamic value) =>
      value is num || value is String || value is bool;

  static final RegExp _numericString = RegExp(
    r'^-?\d+(\.\d+)?([eE][+-]?\d+)?$',
  );

  /// Scalar values of the wrong kind that runtimes cast-and-crash on.
  /// Numeric strings pass for number/integer (trivially coercible).
  static bool _scalarKindMismatch(String declared, dynamic value) {
    switch (declared) {
      case 'string':
        return value is num || value is bool;
      case 'integer':
      case 'number':
        if (value is num) return false;
        if (value is String) return !_numericString.hasMatch(value);
        return true; // bool
      case 'boolean':
        if (value is bool) return false;
        if (value is String) {
          return value != 'true' && value != 'false';
        }
        return true; // num
      default:
        return false;
    }
  }

  static String _describe(dynamic value) {
    final type = value is Map
        ? 'object'
        : value is List
        ? 'array'
        : value is int
        ? 'int'
        : value is double
        ? 'double'
        : value is bool
        ? 'bool'
        : value is String
        ? 'string'
        : value.runtimeType.toString();
    String echoed;
    try {
      echoed = jsonEncode(value);
    } catch (_) {
      echoed = value.toString();
    }
    if (echoed.length > _maxEchoedValueLength) {
      echoed = '${echoed.substring(0, _maxEchoedValueLength)}…';
    }
    return '$type ($echoed)';
  }

  /// A compact expected-shape hint for the first violation's parent schema.
  static String? _schemaHintForFirstViolation(
    ToolParamViolation violation,
    Map<String, dynamic>? rootSchema,
  ) {
    if (rootSchema == null) return null;
    // Walk the path (dropping a trailing missing-key segment is fine — the
    // hint then describes the object that must contain it).
    final segments = violation.path
        .replaceAll(RegExp(r'\[\d+\]'), '')
        .split('.')
        .where((s) => s.isNotEmpty)
        .toList();
    Map<String, dynamic>? current = rootSchema;
    for (final segment in segments) {
      if (current == null) return null;
      var next = (current['properties'] as Map?)?[segment];
      next ??= ((current['items'] as Map?)?['properties'] as Map?)?[segment];
      if (next is! Map) {
        break;
      }
      current = next.cast<String, dynamic>();
    }
    if (current == null) return null;
    final schema = current['type'] == 'array' && current['items'] is Map
        ? (current['items'] as Map).cast<String, dynamic>()
        : current;
    final properties = schema['properties'];
    if (properties is! Map || properties.isEmpty) return null;
    final keys = properties.keys.take(8).join(', ');
    return 'Expected "${segments.isEmpty ? violation.path : segments.last}" '
        'to be an object with properties: {$keys}.';
  }
}
