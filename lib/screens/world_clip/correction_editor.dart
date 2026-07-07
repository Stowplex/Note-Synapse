import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../services/service_locator.dart';
import '../../services/world_clip/edge_detector.dart';
import '../../services/world_clip/frame_correction.dart';
import '../../services/world_clip/models/correction.dart';
import '../../services/world_clip/models/mesh_grid.dart';
import '../../services/world_clip/models/norm_point.dart';

/// Per-clip correction editor: rotate the frame to the right orientation, then
/// drag the keystone quad (with optional creases) over the document. Includes
/// auto edge detection and connecting region lines so the selection reads like
/// a crop tool rather than loose bubbles. A second toolbar panel adjusts
/// contrast / saturation / color temperature with a live preview.
class CorrectionEditor extends StatefulWidget {
  final Uint8List framePng;
  final List<Correction> initial;
  final void Function(List<Correction> corrections) onDone;

  /// Injectable for tests; defaults to the registered engine.
  final FrameCorrection? correction;

  const CorrectionEditor({
    super.key,
    required this.framePng,
    required this.initial,
    required this.onDone,
    this.correction,
  });

  @override
  State<CorrectionEditor> createState() => _CorrectionEditorState();
}

class _CorrectionEditorState extends State<CorrectionEditor> {
  late FrameCorrection _engine;
  late MeshGrid _grid;
  int _quarterTurns = 0; // 90° steps
  double _fineDeg = 0; // fine leveling within [-15, 15]
  Uint8List _basePng = Uint8List(0);
  double _aspect = 1;
  bool _busy = false;
  int _recomputeGen = 0; // discards stale rotation renders (race guard)
  bool _colorPanel = false; // toolbar shows color sliders instead of shape tools
  double _contrast = 1;
  double _saturation = 1;
  double _temperature = 0;

  double get _totalRotation => _quarterTurns * 90 + _fineDeg;

  @override
  void initState() {
    super.initState();
    _engine = widget.correction ?? getIt<FrameCorrection>();
    var rotation = widget.initial
        .whereType<RotateCorrection>()
        .fold<double>(0, (sum, r) => sum + r.degrees);
    // Normalize to [0, 360) so a stored -90 (rotate-left) re-opens correctly
    // instead of producing negative quarter-turns + a bogus fine tilt.
    rotation = rotation % 360;
    if (rotation < 0) rotation += 360;
    _quarterTurns = (rotation / 90).round() % 4;
    _fineDeg = (rotation - _quarterTurns * 90).clamp(-15, 15).toDouble();
    final mesh = widget.initial.whereType<MeshDewarpCorrection>();
    _grid = mesh.isEmpty ? MeshGrid.identity(rows: 1, cols: 1) : mesh.first.grid;
    final color = widget.initial.whereType<ColorAdjustCorrection>();
    if (color.isNotEmpty) {
      _contrast = color.first.contrast;
      _saturation = color.first.saturation;
      _temperature = color.first.temperature;
    }
    _basePng = widget.framePng;
    _recomputeBase(resetGrid: false);
  }

  /// Re-renders the base preview with the current rotation so what the user
  /// drags on matches exactly what the pipeline will produce.
  Future<void> _recomputeBase({bool resetGrid = true}) async {
    final gen = ++_recomputeGen;
    setState(() => _busy = true);
    // Yield a frame so the busy overlay paints before the synchronous OpenCV
    // warp blocks the UI isolate.
    await Future<void>.delayed(Duration.zero);
    final rotation = _totalRotation;
    Uint8List base;
    if (rotation % 360 == 0) {
      base = widget.framePng;
    } else {
      base = await _engine
          .apply(widget.framePng, [RotateCorrection(degrees: rotation)]);
    }
    final size = await _decodeSize(base);
    // Drop the result if a newer rotation has since been requested.
    if (!mounted || gen != _recomputeGen) return;
    setState(() {
      _basePng = base;
      _aspect = size.height == 0 ? 1 : size.width / size.height;
      if (resetGrid) _grid = MeshGrid.identity(rows: 1, cols: 1);
      _busy = false;
    });
  }

  Future<Size> _decodeSize(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final size =
        Size(frame.image.width.toDouble(), frame.image.height.toDouble());
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  void _rotate(int turns) {
    setState(() => _quarterTurns = (_quarterTurns + turns) % 4);
    _recomputeBase();
  }

  Future<void> _autoDetect() async {
    setState(() => _busy = true);
    // Yield a frame so the busy overlay paints before the synchronous OpenCV
    // detection blocks the UI isolate.
    await Future<void>.delayed(Duration.zero);
    final quad = detectDocumentQuad(_basePng);
    if (kDebugMode) {
      debugPrint('WorldClip autoDetect: input=${_basePng.length}B quad='
          '${quad?.points.map((p) => '(${p.x.toStringAsFixed(3)},'
              '${p.y.toStringAsFixed(3)})').join()}');
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (quad != null) _grid = quad;
    });
    if (quad == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No document edges detected')),
      );
    }
  }

  /// Adds a crease by resampling the current mesh to one more row
  /// ([horizontal] = true, a fold across the page) or one more column
  /// ([horizontal] = false, a fold down the page), preserving the existing
  /// (auto-detected / hand-dragged) corners instead of resetting to a rect.
  void _addCrease({required bool horizontal}) => setState(() {
        final oldRows = _grid.rows, oldCols = _grid.cols;
        NormPoint at(int r, int c) => _grid.points[r * (oldCols + 1) + c];
        final newRows = horizontal ? oldRows + 1 : oldRows;
        final newCols = horizontal ? oldCols : oldCols + 1;
        final pts = <NormPoint>[];
        for (var r = 0; r <= newRows; r++) {
          final tr = r / newRows * oldRows; // continuous old-row index
          final r0 = tr.floor().clamp(0, oldRows);
          final r1 = (r0 + 1).clamp(0, oldRows);
          final fr = tr - r0;
          for (var c = 0; c <= newCols; c++) {
            final tc = c / newCols * oldCols; // continuous old-col index
            final c0 = tc.floor().clamp(0, oldCols);
            final c1 = (c0 + 1).clamp(0, oldCols);
            final fc = tc - c0;
            // Bilinear sample of the old grid at (tr, tc).
            final p00 = at(r0, c0), p01 = at(r0, c1);
            final p10 = at(r1, c0), p11 = at(r1, c1);
            double lerp(double a, double b, double t) => a + (b - a) * t;
            final topX = lerp(p00.x, p01.x, fc), topY = lerp(p00.y, p01.y, fc);
            final botX = lerp(p10.x, p11.x, fc), botY = lerp(p10.y, p11.y, fc);
            pts.add(NormPoint(lerp(topX, botX, fr), lerp(topY, botY, fr)));
          }
        }
        _grid = MeshGrid(rows: newRows, cols: newCols, points: pts);
      });

  void _reset() {
    setState(() {
      _quarterTurns = 0;
      _fineDeg = 0;
      _grid = MeshGrid.identity(rows: 1, cols: 1);
      _resetColor();
    });
    _recomputeBase(resetGrid: false);
  }

  // Callers wrap in setState.
  void _resetColor() {
    _contrast = 1;
    _saturation = 1;
    _temperature = 0;
  }

  ColorAdjustCorrection get _colorAdjust => ColorAdjustCorrection(
      contrast: _contrast, saturation: _saturation, temperature: _temperature);

  /// The live-preview filter — built from the same 3x4 RGB matrix the OpenCV
  /// pipeline applies, so the preview matches the compiled page exactly.
  ColorFilter get _previewFilter {
    final m = _colorAdjust.rgbMatrix();
    return ColorFilter.matrix([
      m[0], m[1], m[2], 0, m[3],
      m[4], m[5], m[6], 0, m[7],
      m[8], m[9], m[10], 0, m[11],
      0, 0, 0, 1, 0,
    ]);
  }

  void _movePoint(int index, double nx, double ny) => setState(() {
        final pts = List<NormPoint>.from(_grid.points);
        pts[index] = NormPoint(nx.clamp(0, 1), ny.clamp(0, 1));
        _grid = MeshGrid(rows: _grid.rows, cols: _grid.cols, points: pts);
      });

  void _done() {
    final color = _colorAdjust;
    final corrections = <Correction>[
      if (_totalRotation % 360 != 0)
        RotateCorrection(degrees: _totalRotation),
      MeshDewarpCorrection(grid: _grid),
      if (!color.isNeutral) color,
    ];
    widget.onDone(corrections);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              // Generous gutter so corner handles sit well clear of the screen
              // edge (and the OS back-swipe zone) and stay easy to grab.
              padding: const EdgeInsets.all(48),
              child: AspectRatio(
                aspectRatio: _aspect,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints.maxWidth, h = constraints.maxHeight;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: ColorFiltered(
                            colorFilter: _previewFilter,
                            child: Image.memory(_basePng, fit: BoxFit.fill),
                          ),
                        ),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _MeshPainter(_grid),
                          ),
                        ),
                        for (var i = 0; i < _grid.points.length; i++)
                          _handle(i, w, h),
                        if (_busy)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Color(0x55000000),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        _toolbar(),
      ],
    );
  }

  Widget _handle(int i, double w, double h) {
    const hit = 56.0;
    final p = _grid.points[i];
    return Positioned(
      left: p.x * w - hit / 2,
      top: p.y * h - hit / 2,
      width: hit,
      height: hit,
      child: GestureDetector(
        key: ValueKey('wc-handle-$i'),
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _movePoint(
          i,
          (p.x * w + d.delta.dx) / w,
          (p.y * h + d.delta.dy) / h,
        ),
        child: Center(
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(color: Colors.blueAccent, width: 3),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      elevation: 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: _colorPanel ? _colorToolbar(l10n) : _shapeToolbar(l10n),
      ),
    );
  }

  Widget _shapeToolbar(AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Level: ${_fineDeg.toStringAsFixed(0)}°',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
          ],
        ),
        Slider(
          value: _fineDeg,
          min: -15,
          max: 15,
          divisions: 30,
          label: '${_fineDeg.toStringAsFixed(0)}°',
          onChanged: (v) => setState(() => _fineDeg = v),
          onChangeEnd: (_) => _recomputeBase(resetGrid: false),
        ),
        Row(
          children: [
            // The tool strip can outgrow narrow phones (especially with large
            // display scaling), so it scrolls horizontally while Done stays
            // pinned — never pushed off the edge or into the back-swipe zone.
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Rotate left',
                      icon: const Icon(Icons.rotate_left),
                      onPressed: () => _rotate(-1),
                    ),
                    IconButton(
                      tooltip: 'Rotate right',
                      icon: const Icon(Icons.rotate_right),
                      onPressed: () => _rotate(1),
                    ),
                    TextButton.icon(
                      onPressed: _autoDetect,
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text('Auto edges'),
                    ),
                    IconButton(
                      tooltip: 'Add horizontal crease',
                      icon: const Icon(Icons.table_rows),
                      onPressed: () => _addCrease(horizontal: true),
                    ),
                    IconButton(
                      tooltip: 'Add vertical crease',
                      icon: const Icon(Icons.view_column),
                      onPressed: () => _addCrease(horizontal: false),
                    ),
                    IconButton(
                      key: const ValueKey('wc-color-toggle'),
                      tooltip: l10n.worldClipColorAdjust,
                      icon: const Icon(Icons.palette_outlined),
                      onPressed: () => setState(() => _colorPanel = true),
                    ),
                    IconButton(
                      tooltip: 'Reset',
                      icon: const Icon(Icons.restart_alt),
                      onPressed: _reset,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('wc-mesh-done'),
              onPressed: _done,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _colorToolbar(AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _colorSlider(
          key: const ValueKey('wc-contrast'),
          label: l10n.worldClipContrast,
          value: _contrast,
          min: 0.5,
          max: 1.5,
          display: '${(_contrast * 100).round()}%',
          onChanged: (v) => setState(() => _contrast = v),
        ),
        _colorSlider(
          key: const ValueKey('wc-saturation'),
          label: l10n.worldClipSaturation,
          value: _saturation,
          min: 0,
          max: 2,
          display: '${(_saturation * 100).round()}%',
          onChanged: (v) => setState(() => _saturation = v),
        ),
        _colorSlider(
          key: const ValueKey('wc-temperature'),
          label: l10n.worldClipTemperature,
          value: _temperature,
          min: -1,
          max: 1,
          display: (_temperature * 100).round().toString(),
          onChanged: (v) => setState(() => _temperature = v),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              key: const ValueKey('wc-color-back'),
              tooltip: l10n.worldClipShapeTools,
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _colorPanel = false),
            ),
            IconButton(
              tooltip: l10n.worldClipResetColor,
              icon: const Icon(Icons.format_color_reset),
              onPressed: () => setState(_resetColor),
            ),
            FilledButton(
              key: const ValueKey('wc-color-done'),
              onPressed: _done,
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _colorSlider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label, style: style)),
        Expanded(
          child: Slider(
            key: key,
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(display, style: style, textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

/// Draws the mesh as connecting region lines (horizontal + vertical polylines
/// through the control points) so the selection reads as bounded regions.
class _MeshPainter extends CustomPainter {
  final MeshGrid grid;
  _MeshPainter(this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final fill = Paint()
      ..color = const Color(0x22448AFF)
      ..style = PaintingStyle.fill;

    Offset at(int r, int c) {
      final p = grid.points[r * (grid.cols + 1) + c];
      return Offset(p.x * size.width, p.y * size.height);
    }

    // Translucent fill of the outer quad.
    final outer = Path()
      ..moveTo(at(0, 0).dx, at(0, 0).dy)
      ..lineTo(at(0, grid.cols).dx, at(0, grid.cols).dy)
      ..lineTo(at(grid.rows, grid.cols).dx, at(grid.rows, grid.cols).dy)
      ..lineTo(at(grid.rows, 0).dx, at(grid.rows, 0).dy)
      ..close();
    canvas.drawPath(outer, fill);

    // Horizontal lines (one per row of control points).
    for (var r = 0; r <= grid.rows; r++) {
      for (var c = 0; c < grid.cols; c++) {
        canvas.drawLine(at(r, c), at(r, c + 1), paint);
      }
    }
    // Vertical lines (one per column of control points).
    for (var c = 0; c <= grid.cols; c++) {
      for (var r = 0; r < grid.rows; r++) {
        canvas.drawLine(at(r, c), at(r + 1, c), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_MeshPainter old) => old.grid != grid;
}
