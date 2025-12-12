import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_painter_v2/flutter_painter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

class DrawingEditor extends StatefulWidget {
  final File? initialImage;
  final String? initialImagePath; // To handle both File and path if needed
  final double? width;
  final double? height;

  const DrawingEditor({
    super.key,
    this.initialImage,
    this.initialImagePath,
    this.width,
    this.height,
  });

  @override
  State<DrawingEditor> createState() => _DrawingEditorState();
}

class _DrawingEditorState extends State<DrawingEditor> {
  // Controller for the painter
  late PainterController _controller;

  // State variables for UI
  ui.Image? _backgroundImage;
  DrawingTool _currentTool = DrawingTool.pen;
  Color _selectedColor = Colors.red;
  double _strokeWidth = 3.0;

  final List<Color> _colors = [
    Colors.black,
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.yellow,
    Colors.purple,
    Colors.orange,
    Colors.white,
  ];

  Size _canvasSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _initController() {
    // Initializing the controller with default settings
    _controller = PainterController(
      settings: PainterSettings(
        freeStyle: const FreeStyleSettings(color: Colors.red, strokeWidth: 3.0),
        text: const TextSettings(
          textStyle: TextStyle(color: Colors.red, fontSize: 20),
        ),
        shape: ShapeSettings(
          paint: Paint()
            ..color = Colors.red
            ..strokeWidth = 3.0
            ..style = PaintingStyle.stroke,
        ),
        scale: const ScaleSettings(enabled: true, minScale: 0.8, maxScale: 5.0),
      ),
    );

    // Default mode
    _controller.freeStyleMode = FreeStyleMode.draw;

    // Default white background
    _controller.background = ColorBackgroundDrawable(color: Colors.white);
  }

  Future<void> _loadInitialImage() async {
    ui.Image? bgImage;
    if (widget.initialImage != null) {
      final bytes = await widget.initialImage!.readAsBytes();
      bgImage = await _bytesToImage(bytes);
    } else if (widget.initialImagePath != null) {
      final file = File(widget.initialImagePath!);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        bgImage = await _bytesToImage(bytes);
      }
    }

    if (bgImage != null) {
      _addImageAsDrawable(bgImage);
    }
  }

  void _addImageAsDrawable(ui.Image image) {
    if (_canvasSize.isEmpty) return; // Should allow retry if not ready?
    // Actually Logic call is controlled by _pendingLoad which checks _canvasSize.

    final Size viewportSize = _canvasSize;

    final double maxWidth = viewportSize.width * 0.9;
    final double maxHeight = viewportSize.height * 0.8;

    double targetWidth = image.width.toDouble();
    double targetHeight = image.height.toDouble();

    // Scale down if needed
    if (targetWidth > maxWidth || targetHeight > maxHeight) {
      final double widthRatio = maxWidth / targetWidth;
      final double heightRatio = maxHeight / targetHeight;
      final double scale = widthRatio < heightRatio ? widthRatio : heightRatio;
      targetWidth *= scale;
      targetHeight *= scale;
    }

    final double scale = targetWidth / image.width.toDouble();

    final drawable = ImageDrawable(
      image: image,
      position: Offset(
        (viewportSize.width - targetWidth) / 2,
        (viewportSize.height - targetHeight) / 2,
      ),
      scale: scale,
    );

    _controller.value = _controller.value.copyWith(
      drawables: List<Drawable>.from(_controller.value.drawables)
        ..add(drawable),
    );
    // Save history after adding image
    _saveToHistory();
  }

  Future<ui.Image> _bytesToImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drawing Editor'),
        actions: [
          IconButton(icon: const Icon(Icons.undo), onPressed: _undo),
          IconButton(icon: const Icon(Icons.check), onPressed: _saveAndExit),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Update canvas size
                _canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

                // If we have a pending image load and valid size, trigger it now
                if (_pendingLoad && !_canvasSize.isEmpty) {
                  _pendingLoad = false;
                  // Use addPostFrameCallback to avoid state modification during build
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _loadInitialImage();
                  });
                }

                return Container(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  color: Colors.white, // Canvas background
                  child: Listener(
                    onPointerUp: (_) => _saveToHistory(),
                    child: FlutterPainter(controller: _controller),
                  ),
                );
              },
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  bool _pendingLoad = true;
  List<List<Drawable>> _history = [];

  bool _isRestoring = false;

  void _undo() {
    if (_history.isNotEmpty) {
      _isRestoring = true;
      setState(() {
        if (_history.length > 1) {
          _history.removeLast(); // Remove current state
          _controller.value = _controller.value.copyWith(
            drawables: List.from(_history.last),
          );
        } else {
          _history.clear();
          _controller.value = _controller.value.copyWith(drawables: []);
        }
      });
      // Allow the listener to fire but be ignored?
      // Actually listener fires synchronously usually on value set.
      // So setting flag before is correct.
      // We might need to defer setting it back to false if it's async, but it's likely sync.
      // To be safe, let's schedule it for next frame or just assume sync.
      // PainterController uses ValueNotifier which is sync.
      _isRestoring = false;
    }
  }

  // Hook into controller to save history
  // actually PainterController doesn't have a simple onDraw callback easily accessible without digging.
  // We can use a listener on the value.

  void _saveToHistory() {
    if (_isRestoring) return;

    final current = _controller.value.drawables;
    if (_history.isEmpty) {
      if (current.isNotEmpty) {
        _history.add(List.from(current));
      }
    } else {
      // Only save if different length or if last item changed (simple heuristic)
      // For freeform, length changes. For sync changes, we might want to check equality?
      // List equality isn't usually recursive by value for custom objects.
      // But we know we want to snapshot on "action end".
      // So we just save blindly on pointer up?
      // Might duplicate state if user just tapped without drawing.
      // Let's check simplistic diff:
      bool changed = false;
      if (current.length != _history.last.length) {
        changed = true;
      } else if (current.isNotEmpty && _history.last.isNotEmpty) {
        // This might fail if Drawables don't implement equality value-wise.
        // But let's assume they might be different instances or we just save.
        // Actually, saving on every pointer up is safer for "undo stroke".
        // Optimization: check if length is same and last item reference is same?
        // Freeform creates a new drawable.
        if (current.last != _history.last.last) {
          changed = true;
        }
      }

      if (changed) {
        _history.add(List.from(current));
      }
    }
  }

  // NOTE: Implementing the listener in initState

  Widget _buildToolbar() {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Color Picker Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _colors
                  .map((color) => _buildColorButton(color))
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          // Tools Row
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit),
                  color: _currentTool == DrawingTool.pen
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () => _updateTool(DrawingTool.pen),
                  tooltip: 'Pen',
                ),
                IconButton(
                  icon: const Icon(Icons.text_fields),
                  color: _currentTool == DrawingTool.text
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () => _addText(),
                  tooltip: 'Text',
                ),
                IconButton(
                  icon: const Icon(Icons.crop_square),
                  color: _currentTool == DrawingTool.rectangle
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () => _updateTool(DrawingTool.rectangle),
                  tooltip: 'Rectangle',
                ),
                IconButton(
                  icon: const Icon(Icons.circle_outlined),
                  color: _currentTool == DrawingTool.oval
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () => _updateTool(DrawingTool.oval),
                  tooltip: 'Oval',
                ),
                IconButton(
                  icon: const Icon(Icons.horizontal_rule),
                  color: _currentTool == DrawingTool.line
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () => _updateTool(DrawingTool.line),
                  tooltip: 'Line',
                ),
                IconButton(
                  icon: const Icon(Icons.back_hand),
                  color: _currentTool == DrawingTool.move
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  onPressed: () => _updateTool(DrawingTool.move),
                  tooltip: 'Move',
                ),
                IconButton(
                  icon: const Icon(Icons.image),
                  onPressed: _importImage,
                  tooltip: 'Add Image',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    // Clear all
                    _controller.value = _controller.value.copyWith(
                      drawables: [],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      final image = await _bytesToImage(bytes);
      // Add as drawable object
      _addImageAsDrawable(image);
    }
  }

  Widget _buildColorButton(Color color) {
    final isSelected = _selectedColor == color;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedColor = color;
          _controller.freeStyleColor = color;
          // Update paint for shapes if needed.
          // Since ShapeSettings are usually global or per-draw, we might need to update settings.
          // Note for shapes: Factory usually takes color, or settings do.
          // Assuming settings take precedence or we update settings.
          _controller.settings = _controller.settings.copyWith(
            shape: _controller.settings.shape.copyWith(
              paint: Paint()
                ..color = color
                ..strokeWidth = _strokeWidth
                ..style = PaintingStyle.stroke,
            ),
          );
        });
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: isSelected
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : Border.all(color: Colors.grey, width: 1),
        ),
      ),
    );
  }

  void _updateTool(DrawingTool tool) {
    setState(() {
      _currentTool = tool;
    });

    // Reset properties
    _controller.freeStyleMode = FreeStyleMode.none;
    _controller.shapeFactory = null;

    switch (tool) {
      case DrawingTool.pen:
        _controller.freeStyleMode = FreeStyleMode.draw;
        break;
      case DrawingTool.rectangle:
        _controller.shapeFactory = RectangleFactory();
        break;
      case DrawingTool.oval:
        _controller.shapeFactory = OvalFactory();
        break;
      case DrawingTool.line:
        _controller.shapeFactory = LineFactory();
        break;
      case DrawingTool.move:
        // Default behavior when no other mode is active is usually object selection/movement
        break;
      default:
        break;
    }
  }

  Future<void> _addText() async {
    final textController = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Text'),
        content: TextField(controller: textController, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, textController.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (text != null && text.isNotEmpty) {
      final drawable = TextDrawable(
        text: text,
        position: const Offset(100, 100),
        style: TextStyle(color: _selectedColor, fontSize: 20),
      );
      _controller.value = _controller.value.copyWith(
        drawables: List<Drawable>.from(_controller.value.drawables)
          ..add(drawable),
      );
      _updateTool(DrawingTool.move);
    }
  }

  Future<void> _saveAndExit() async {
    try {
      // Use the actual canvas size for output, ensuring WPSIWYG
      final outputSize = _canvasSize.isEmpty
          ? Size(widget.width ?? 1080, widget.height ?? 1920)
          : _canvasSize;

      final image = await _controller.renderImage(outputSize);

      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final bytes = byteData.buffer.asUint8List();

      final tempDir = await getTemporaryDirectory();
      final file = await File(
        '${tempDir.path}/drawing_${DateTime.now().millisecondsSinceEpoch}.png',
      ).create();
      await file.writeAsBytes(bytes);

      if (mounted) {
        Navigator.pop(context, file);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving drawing: $e')));
      }
    }
  }
}

enum DrawingTool { pen, text, rectangle, oval, line, move, eraser }
