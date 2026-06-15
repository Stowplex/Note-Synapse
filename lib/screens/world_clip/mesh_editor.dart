import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/world_clip/models/correction.dart';
import '../../services/world_clip/models/mesh_grid.dart';
import '../../services/world_clip/models/norm_point.dart';

/// Optional per-clip correction editor: drag the 4 (or subdivided) mesh
/// corners over the frame; "Add crease" subdivides vertically for folded pages.
class MeshEditor extends StatefulWidget {
  final Uint8List framePng;
  final List<Correction> initial;
  final void Function(List<Correction> corrections) onDone;

  const MeshEditor({
    super.key,
    required this.framePng,
    required this.initial,
    required this.onDone,
  });

  @override
  State<MeshEditor> createState() => _MeshEditorState();
}

class _MeshEditorState extends State<MeshEditor> {
  late MeshGrid _grid;

  @override
  void initState() {
    super.initState();
    final meshes = widget.initial.whereType<MeshDewarpCorrection>();
    _grid = meshes.isEmpty
        ? MeshGrid.identity(rows: 1, cols: 1)
        : meshes.first.grid;
  }

  void _addCrease() => setState(() {
        _grid = MeshGrid.identity(rows: _grid.rows + 1, cols: _grid.cols);
      });

  void _movePoint(int index, NormPoint to) => setState(() {
        final pts = List<NormPoint>.from(_grid.points);
        pts[index] = NormPoint(to.x.clamp(0, 1), to.y.clamp(0, 1));
        _grid = MeshGrid(rows: _grid.rows, cols: _grid.cols, points: pts);
      });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth, h = constraints.maxHeight;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(widget.framePng, fit: BoxFit.contain),
                  for (var i = 0; i < _grid.points.length; i++)
                    Positioned(
                      left: _grid.points[i].x * w - 12,
                      top: _grid.points[i].y * h - 12,
                      child: GestureDetector(
                        onPanUpdate: (d) => _movePoint(
                          i,
                          NormPoint(
                            (_grid.points[i].x * w + d.delta.dx) / w,
                            (_grid.points[i].y * h + d.delta.dy) / h,
                          ),
                        ),
                        child: const Icon(Icons.circle,
                            size: 24, color: Colors.blueAccent),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: _addCrease,
              icon: const Icon(Icons.add),
              label: const Text('Add crease'),
            ),
            FilledButton(
              key: const ValueKey('wc-mesh-done'),
              onPressed: () =>
                  widget.onDone([MeshDewarpCorrection(grid: _grid)]),
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }
}
