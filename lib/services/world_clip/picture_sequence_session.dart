import 'dart:io';
import 'dart:typed_data';

import 'glare_fusion.dart';

/// Where over the page an anti-glare shot is taken from. The screen layer
/// switches exhaustively on this to localize each step's label/instruction,
/// so reordering or extending [kAntiGlareSteps] can't silently mislabel a
/// step.
enum AntiGlarePosition { center, topLeft, topRight, bottomLeft, bottomRight }

/// One guided shot position for an anti-glare page: where the camera should
/// sit over the page ([dx]/[dy] in -1..1, directly usable as a Flutter
/// `Alignment`). A specular highlight moves with the camera's VIEWING ANGLE
/// relative to the page, which changes far more from moving the camera to a
/// different position over the page than from tilting/rotating it in place —
/// a small wrist tilt barely shifts the highlight at all. Modeled on Google
/// PhotoScan's center + four-corner capture, which is built on the same
/// premise.
class AntiGlareStep {
  const AntiGlareStep(this.position, this.dx, this.dy);
  final AntiGlarePosition position;
  final double dx;
  final double dy;
}

/// The guided shot sequence for an anti-glare page, in capture order:
/// center, then the four corners.
const List<AntiGlareStep> kAntiGlareSteps = [
  AntiGlareStep(AntiGlarePosition.center, 0, 0),
  AntiGlareStep(AntiGlarePosition.topLeft, -1, -1),
  AntiGlareStep(AntiGlarePosition.topRight, 1, -1),
  AntiGlareStep(AntiGlarePosition.bottomLeft, -1, 1),
  AntiGlareStep(AntiGlarePosition.bottomRight, 1, 1),
];

/// Shots captured per page when anti-glare guidance is on — one from each
/// position in [kAntiGlareSteps]. [fuseAntiGlare] suppresses a highlight or
/// shadow that only shows up in a minority of positions.
final int kAntiGlareShotsPerPage = kAntiGlareSteps.length;

/// The page/shot bookkeeping behind `PictureSequenceScreen`, factored out of
/// the widget so retake/discard/anti-glare sequencing is unit-testable
/// without a live camera. One session per capture flow; the widget feeds it
/// accepted shot bytes and reflects [pages] back into its thumbnail strip.
class PictureSequenceSession {
  PictureSequenceSession({required this.fuse, required this.writePage});

  /// Combines a completed page's shots into one JPEG. Only called when the
  /// page has more than one shot (anti-glare) — a single-shot page is used
  /// as-is. Async so the screen's default can run [fuseAntiGlare] off the UI
  /// isolate (it does seconds of native + per-pixel work per page).
  final Future<Uint8List> Function(List<Uint8List> shots) fuse;

  /// Persists one finished page's bytes to a durable [File] and returns it.
  final Future<File> Function(Uint8List bytes) writePage;

  bool _antiGlare = false;
  bool get antiGlare => _antiGlare;

  // Global for the whole session, not per-shot: once toggled it stays in
  // effect for every subsequent capture (across pages, retakes, and anti-
  // glare's multi-shot pages alike) until toggled again.
  bool _flashOn = false;
  bool get flashOn => _flashOn;
  void setFlashOn(bool value) => _flashOn = value;

  final List<Uint8List> _liveShots = [];
  final List<File> _pages = [];
  int? _retakeIndex;

  /// Finished pages so far, in sequence order.
  List<File> get pages => List.unmodifiable(_pages);

  /// Shots accepted for the page currently being captured (not yet finished).
  int get liveShotCount => _liveShots.length;

  int get shotsPerPage => _antiGlare ? kAntiGlareShotsPerPage : 1;

  /// True while a page's shots are being accumulated (one or more of anti-
  /// glare's [kAntiGlareShotsPerPage] shots already kept, but not yet
  /// finished).
  bool get midPage => _liveShots.isNotEmpty;

  /// The page index [finishPage] will replace instead of append to, or null
  /// when the next finished page is a fresh addition.
  int? get retakeIndex => _retakeIndex;

  /// Anti-glare changes how many shots a page takes, so it can't be flipped
  /// mid-page without stranding a partial shot count.
  bool get canToggleAntiGlare => !midPage;

  void setAntiGlare(bool value) {
    if (!canToggleAntiGlare) return;
    _antiGlare = value;
  }

  /// Accepts one captured shot into the in-progress page. Returns true when
  /// that completes the page (the caller should then await [finishPage]).
  bool acceptShot(Uint8List bytes) {
    _liveShots.add(bytes);
    return _liveShots.length >= shotsPerPage;
  }

  /// Finishes the current page: fuses its shots (if more than one), writes
  /// the result, and appends it to [pages] — or, when a [retakePage] is
  /// pending, replaces that page in place instead. Returns the written file
  /// and whether fusion failed and fell back to the first shot unfused.
  Future<(File, bool)> finishPage() async {
    final shots = List<Uint8List>.of(_liveShots);
    _liveShots.clear();
    Uint8List bytes;
    var usedFallback = false;
    try {
      bytes = shots.length > 1 ? await fuse(shots) : shots.single;
    } on GlareFusionException {
      bytes = shots.first;
      usedFallback = true;
    }
    final file = await writePage(bytes);
    final target = _retakeIndex;
    if (target != null) {
      _pages[target] = file;
    } else {
      _pages.add(file);
    }
    _retakeIndex = null;
    return (file, usedFallback);
  }

  /// Marks [index] to be replaced (rather than appended after) the next time
  /// a page completes, and clears any shots already taken for a *different*
  /// in-progress page.
  void retakePage(int index) {
    _retakeIndex = index;
    _liveShots.clear();
  }

  /// Removes a finished page, keeping any pending [retakeIndex] pointed at
  /// the same logical page.
  void discardPage(int index) {
    _pages.removeAt(index);
    if (_retakeIndex == index) {
      _retakeIndex = null;
    } else if (_retakeIndex != null && _retakeIndex! > index) {
      _retakeIndex = _retakeIndex! - 1;
    }
  }
}
