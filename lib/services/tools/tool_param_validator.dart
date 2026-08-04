import 'dart:convert';

import 'package:json_repair_flutter/json_repair_flutter.dart';

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
/// Result of [ToolParamValidator.validateAndNormalize]: either a failure to
/// return to the model, or the (possibly coerced) params to execute with.
class ToolParamValidationResult {
  final ToolOutcome? failure;
  final Map<String, dynamic> params;

  const ToolParamValidationResult({this.failure, required this.params});
}

class ToolParamValidator {
  static const int _maxDepth = 6;
  static const int _maxEchoedValueLength = 60;

  /// Validates [params] and applies argument-shape normalizations that
  /// small models demonstrably need (observed in real traces):
  ///
  /// - **String→container coercion**: a declared-object (or -array)
  ///   property whose value is a JSON-encoded string is decoded
  ///   (`jsonDecode`, then `repairJson` for mangled output) — models
  ///   frequently double-encode nested arguments.
  /// - **Misplaced-key lifting**: when a declared-object property is
  ///   absent or still a string, sibling keys that are NOT declared on the
  ///   parent but ARE declared on that property's schema are lifted into
  ///   it (e.g. `action`/`old_text`/`new_text` placed beside `content`
  ///   instead of inside it).
  ///
  /// On success, [ToolParamValidationResult.params] is the normalized map
  /// to execute with (a deep copy; the input is never mutated). On failure,
  /// the original params are returned alongside the failure outcome.
  static ToolParamValidationResult validateAndNormalize({
    required String toolName,
    required Map<String, dynamic> params,
    required Map<String, dynamic>? inputSchema,
  }) {
    if (inputSchema == null || inputSchema.isEmpty) {
      return ToolParamValidationResult(params: params);
    }
    final normalized = _deepCopy(params) as Map<String, dynamic>;
    final violations = <ToolParamViolation>[];
    _validateObject(normalized, inputSchema, '', violations, 0,
        normalize: true);
    if (violations.isEmpty) {
      return ToolParamValidationResult(params: normalized);
    }
    return ToolParamValidationResult(
      failure: _buildFailure(toolName, violations, inputSchema),
      params: params,
    );
  }

  /// Returns a failure outcome when [params] definitely violate
  /// [inputSchema]; null when the call should proceed. Prefer
  /// [validateAndNormalize] at dispatch sites so coerced params are used.
  static ToolOutcome? validationFailure({
    required String toolName,
    required Map<String, dynamic> params,
    required Map<String, dynamic>? inputSchema,
  }) {
    return validateAndNormalize(
      toolName: toolName,
      params: params,
      inputSchema: inputSchema,
    ).failure;
  }

  static ToolOutcome _buildFailure(
    String toolName,
    List<ToolParamViolation> violations,
    Map<String, dynamic>? inputSchema,
  ) {
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

  /// Structural check of [params] against [schema] without normalization.
  /// Empty list = proceed.
  static List<ToolParamViolation> validate(
    Map<String, dynamic> params,
    Map<String, dynamic>? schema,
  ) {
    if (schema == null || schema.isEmpty) return const [];
    final violations = <ToolParamViolation>[];
    _validateObject(params, schema, '', violations, 0, normalize: false);
    return violations;
  }

  static void _validateObject(
    Map<dynamic, dynamic> value,
    Map<String, dynamic> schema,
    String path,
    List<ToolParamViolation> violations,
    int depth, {
    required bool normalize,
  }) {
    if (depth >= _maxDepth) return;

    final properties = schema['properties'];
    if (properties is! Map) return;

    if (normalize) {
      _coerceAndLift(value, properties);
    }

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

    for (final entry in value.entries.toList()) {
      final key = entry.key.toString();
      final propSchema = properties[key];
      if (propSchema is! Map) continue; // Extra/unknown keys pass.
      _validateValue(
        entry.value,
        propSchema.cast<String, dynamic>(),
        path.isEmpty ? key : '$path.$key',
        violations,
        depth + 1,
        normalize: normalize,
      );
    }
  }

  /// In-place normalization of one object level (only ever called on deep
  /// copies): coerce JSON-string values of container-typed properties, then
  /// lift misplaced sibling keys into their declared object property.
  static void _coerceAndLift(Map<dynamic, dynamic> value, Map properties) {
    // Pass 1: string→container coercion.
    for (final entry in value.entries.toList()) {
      final propSchema = properties[entry.key.toString()];
      if (propSchema is! Map) continue;
      final coerced = _maybeCoerceString(
        entry.value,
        propSchema.cast<String, dynamic>(),
      );
      if (!identical(coerced, entry.value)) {
        value[entry.key] = coerced;
      }
    }

    // Pass 2: misplaced-key lifting. For each declared-object property that
    // is absent or (still) a string, collect sibling keys that are NOT
    // declared on this level but ARE declared inside that property.
    for (final propEntry in properties.entries) {
      final propName = propEntry.key.toString();
      final propSchema = propEntry.value;
      if (propSchema is! Map) continue;
      if (propSchema['type'] != 'object') continue;
      final childProps = propSchema['properties'];
      if (childProps is! Map || childProps.isEmpty) continue;

      final current = value[propName];
      if (current is Map) continue; // Already structured.

      final misplaced = value.keys
          .map((key) => key.toString())
          .where(
            (key) =>
                !properties.containsKey(key) && childProps.containsKey(key),
          )
          .toList();
      if (misplaced.isEmpty) continue;

      final liftedChild = <String, dynamic>{
        for (final key in misplaced) key: value.remove(key),
      };
      // A stray string value becomes the child's `text` when that slot is
      // declared and not already lifted (e.g. content: "hello" + action:
      // "append" as siblings); when replaced-text keys were lifted, the
      // stray string is superseded.
      if (current is String &&
          childProps.containsKey('text') &&
          !liftedChild.containsKey('text') &&
          !liftedChild.containsKey('old_text')) {
        liftedChild['text'] = current;
      }
      value[propName] = liftedChild;
    }
  }

  /// Decodes a JSON-string value for a container-typed property. Small
  /// models frequently double-encode nested arguments; `repairJson` also
  /// recovers mildly mangled output (trailing garbage, unquoted keys).
  static dynamic _maybeCoerceString(
    dynamic value,
    Map<String, dynamic> schema,
  ) {
    if (value is! String) return value;
    final declared = _declaredType(schema);
    if (declared != 'object' && declared != 'array') return value;
    final trimmed = value.trim();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return value;

    dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      try {
        decoded = repairJson(trimmed);
      } catch (_) {
        return value;
      }
    }
    if (declared == 'object' && decoded is Map) {
      return decoded.map((key, v) => MapEntry(key.toString(), v));
    }
    if (declared == 'array' && decoded is List) return decoded;
    return value;
  }

  static dynamic _deepCopy(dynamic value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key.toString(): _deepCopy(entry.value),
      };
    }
    if (value is List) {
      return [for (final item in value) _deepCopy(item)];
    }
    return value;
  }

  static void _validateValue(
    dynamic value,
    Map<String, dynamic> schema,
    String path,
    List<ToolParamViolation> violations,
    int depth, {
    required bool normalize,
  }) {
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
          _validateObject(
            value,
            schema,
            path,
            violations,
            depth,
            normalize: normalize,
          );
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
              if (normalize) {
                final coerced = _maybeCoerceString(value[i], itemSchema);
                if (!identical(coerced, value[i])) value[i] = coerced;
              }
              _validateValue(
                value[i],
                itemSchema,
                '$path[$i]',
                violations,
                depth + 1,
                normalize: normalize,
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
