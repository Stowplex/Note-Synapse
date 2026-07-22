import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan enforcement of the data-change publication convention (see
/// .claude/plans/user-app-bridge-ui-refresh-fix.md, Step 4b):
///
/// Raw SQL writes are observed automatically by the TEMP change journal, but
/// typed note writes (`insertNote`/`updateNote`/`deleteNote`/
/// `updateNoteMetadata` on DatabaseService) bypass it. Any file calling them
/// must either go through AppProvider (which patches its own cache), publish
/// a DataChangeEvent itself, or carry an explicit `data-change-exempt:`
/// comment explaining why staleness is impossible. Without this test, the
/// next direct writer silently reproduces the stale-UI bug this plan fixed.
void main() {
  test('every typed note writer publishes changes or is explicitly exempt',
      () async {
    // Files that ARE the mechanism (no publication expected inside them).
    const allowlist = {
      'lib/providers/app_provider.dart', // patches its own cache + notifies
      'lib/services/database_service.dart', // the persistence layer itself
      'lib/services/database_service_io.dart',
      'lib/services/database_service_web.dart',
    };
    final writerCall = RegExp(
      r'\.(insertNote|updateNote|deleteNote|updateNoteMetadata)\(',
    );
    // Calls routed through AppProvider are safe: its methods notify.
    final providerRouted = RegExp(
      r'(appProvider|context\.read<AppProvider>\(\)|getIt<AppProvider>\(\))'
      r'[\s\S]{0,40}\.(insertNote|updateNote|deleteNote)\(',
    );

    final offenders = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final path = file.path.replaceAll('\\', '/');
      if (allowlist.contains(path)) continue;
      final source = file.readAsStringSync();
      if (!writerCall.hasMatch(source)) continue;

      final publishes =
          source.contains('DataChangeNotifier') || // publishes events
          source.contains('data-change-exempt:'); // documented exemption
      if (publishes) continue;

      // Remaining writer calls must all be AppProvider-routed.
      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!writerCall.hasMatch(line)) continue;
        // Look back a couple of lines for the receiver (call chains wrap).
        final context = [
          if (i >= 2) lines[i - 2],
          if (i >= 1) lines[i - 1],
          line,
        ].join('\n');
        final routed =
            providerRouted.hasMatch(context) ||
            context.contains('appProvider.') ||
            context.contains('read<AppProvider>()');
        if (!routed) {
          offenders.add('$path:${i + 1}: ${line.trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Typed note writes outside AppProvider must publish a '
          'DataChangeEvent or carry a "data-change-exempt:" comment. '
          'Unaccounted writers:\n${offenders.join('\n')}',
    );
  });
}
