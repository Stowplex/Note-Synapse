import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/screens/world_clip/mesh_editor.dart';
import 'package:note_synapse/services/world_clip/models/correction.dart';

void main() {
  final png = Uint8List.fromList(const [
    137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,
    144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,0,0,3,0,1,169,
    118,218,141,0,0,0,0,73,69,78,68,174,66,96,130
  ]);

  testWidgets('returns mesh corrections via onDone', (tester) async {
    List<Correction>? result;
    await tester.pumpWidget(MaterialApp(
      home: MeshEditor(
        framePng: png,
        initial: const [],
        onDone: (c) => result = c,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('wc-mesh-done')));
    expect(result, isNotNull);
  });
}
