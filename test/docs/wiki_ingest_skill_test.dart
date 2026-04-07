import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final skillFile = File('docs/skills/wiki-ingest.md');

  test('wiki-ingest skill uses synapseresource note links', () async {
    final content = await skillFile.readAsString();
    expect(content, isNot(contains('notesynapse://note/')));
    expect(content, contains('synapseresource://note/'));
  });

  test('wiki-ingest skill prefers modify_notes and index read', () async {
    final content = await skillFile.readAsString();
    expect(content, contains('modify_notes'));
    expect(
      content,
      contains('read_note: { note_id: "[index-id]", mode: "full" }'),
    );
  });
}
