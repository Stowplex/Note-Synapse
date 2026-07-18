import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/world_clip/camera_source.dart';
import '../../services/world_clip/glare_fusion.dart';
import '../../services/world_clip/picture_sequence_session.dart';
import 'progress_scrim.dart';

/// Default page fuser: [fuseAntiGlare] moved off the UI isolate — it does
/// seconds of ORB alignment plus a per-pixel medoid vote per page, which
/// would freeze the progress overlay (and risk an ANR) if run on the main
/// isolate. Same pattern as the clip compiler's PDF rendering.
Future<Uint8List> fuseAntiGlareInIsolate(List<Uint8List> shots) =>
    compute(fuseAntiGlare, shots);

/// "Picture Sequence" capture: repeated in-app still-photo captures, ordered
/// into a page sequence, with per-page retake/discard. In anti-glare mode
/// each page is [kAntiGlareShotsPerPage] guided shots fused by
/// [fuseAntiGlare] into one glare/shadow-suppressed page instead of a single
/// shot. The shot/page bookkeeping itself lives in [PictureSequenceSession];
/// this widget is the live-camera shell around it.
///
/// Pops the finished page files (already written to disk) back to the flow
/// screen on Done, or `null` if the user cancels. Mirrors
/// `WorldClipFlowScreen`'s "Import pictures" contract (a plain `List<File>`
/// fed straight into `ClipProjectStore.createFromImages`), so this reuses
/// that entire downstream pipeline unchanged.
class PictureSequenceScreen extends StatefulWidget {
  /// Injectable for tests; defaults to a fresh [CameraPictureSource].
  final CameraPictureSource? source;

  /// Injectable for tests; defaults to [fuseAntiGlareInIsolate].
  final Future<Uint8List> Function(List<Uint8List> shots) fuse;

  /// Injectable for tests; defaults to a fresh system temp dir per session.
  final Future<Directory> Function() tempDirProvider;

  PictureSequenceScreen({
    super.key,
    this.source,
    Future<Uint8List> Function(List<Uint8List> shots)? fuse,
    Future<Directory> Function()? tempDirProvider,
  })  : fuse = fuse ?? fuseAntiGlareInIsolate,
        tempDirProvider = tempDirProvider ?? Directory.systemTemp.createTemp;

  @override
  State<PictureSequenceScreen> createState() => _PictureSequenceScreenState();
}

/// Localized label for an anti-glare step. Exhaustive over
/// [AntiGlarePosition], so adding or reordering steps is a compile-time
/// reminder to localize them.
String antiGlareStepLabel(AppLocalizations l10n, AntiGlareStep step) =>
    switch (step.position) {
      AntiGlarePosition.center => l10n.worldClipAgLabelCenter,
      AntiGlarePosition.topLeft => l10n.worldClipAgLabelTopLeft,
      AntiGlarePosition.topRight => l10n.worldClipAgLabelTopRight,
      AntiGlarePosition.bottomLeft => l10n.worldClipAgLabelBottomLeft,
      AntiGlarePosition.bottomRight => l10n.worldClipAgLabelBottomRight,
    };

/// Localized movement instruction for an anti-glare step.
String antiGlareStepInstruction(AppLocalizations l10n, AntiGlareStep step) =>
    switch (step.position) {
      AntiGlarePosition.center => l10n.worldClipAgInstructionCenter,
      AntiGlarePosition.topLeft => l10n.worldClipAgInstructionTopLeft,
      AntiGlarePosition.topRight => l10n.worldClipAgInstructionTopRight,
      AntiGlarePosition.bottomLeft => l10n.worldClipAgInstructionBottomLeft,
      AntiGlarePosition.bottomRight => l10n.worldClipAgInstructionBottomRight,
    };

class _PictureSequenceScreenState extends State<PictureSequenceScreen>
    with WidgetsBindingObserver {
  late final CameraPictureSource _source =
      widget.source ?? CameraPictureSource();
  late final PictureSequenceSession _session = PictureSequenceSession(
    fuse: widget.fuse,
    writePage: _writePage,
  );

  bool _ready = false;
  bool _initializing = false;
  // False while the app is backgrounded (inactive/paused) — the camera must
  // not be (re)opened until the next resume.
  bool _appActive = true;
  Object? _initError;
  bool _busy = false;
  String _busyLabel = '';
  // A setFlashMode is in flight — the shutter must not fire concurrently on
  // the same controller (and the flash button must not re-enter).
  bool _flashBusy = false;
  Uint8List? _pendingShot; // just-captured, awaiting Keep/Retake

  // All pages this session writes share one temp dir (created lazily, once)
  // rather than one per page. It's cleaned up in [dispose] UNLESS the pages
  // were just handed off to the caller (Done) — the caller copies them into
  // the project immediately after the pop, so deleting the source files out
  // from under that copy would be a race. On cancel nothing needs these
  // files anymore, so dispose is the right place to reclaim them.
  Directory? _tempDir;
  bool _handedOffPages = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    if (_initializing || !_appActive) return;
    _initializing = true;
    try {
      await _source.initialize();
      // Backed out (or backgrounded) while the camera was opening — the
      // source already tore the controller down; don't treat it as live.
      if (_source.isDisposed) return;
      // Re-init after a background/resume cycle gets a fresh controller;
      // re-apply the session's flash choice so the toggle icon stays honest.
      if (_session.flashOn) {
        try {
          await _source.setFlashMode(FlashMode.torch);
        } catch (_) {
          _session.setFlashOn(false);
        }
        // A pause can land during that await and dispose the source — going
        // ready then would hand CameraPreview a dead controller (and a later
        // resume would skip re-init). The finally/resume logic recovers.
        if (_source.isDisposed) return;
      }
      if (!mounted) return;
      setState(() {
        _ready = true;
        _initError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // A teardown-induced failure (backgrounded/backed out mid-open) isn't
      // a camera error — the next resume re-inits.
      if (_source.isDisposed) return;
      setState(() => _initError = e);
    } finally {
      _initializing = false;
      // A resume that arrived while this init was still winding down (its
      // open torn down by a pause) was skipped by the reentrancy guard —
      // pick it up now. Terminates: only the disposed-mid-open case
      // re-enters, and it can't recur unless the app is backgrounded again
      // (_appActive false) or the screen was left (unmounted).
      if (mounted && _appActive && !_ready && _source.isDisposed) {
        _init();
      }
    }
  }

  /// The camera plugin requires releasing the camera when the app is
  /// backgrounded and re-opening it on resume — otherwise the preview comes
  /// back black and the next capture throws. Disposing is NOT gated on
  /// [_ready]: backgrounding can race the initial open, and the camera must
  /// not be left opening (and then held) in the background —
  /// [CameraPictureSource.initialize] tears down a controller whose open
  /// lands after its dispose.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _appActive = false;
      if (_ready) setState(() => _ready = false);
      _source.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _appActive = true;
      if (!_ready) _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _source.dispose();
    if (!_handedOffPages) {
      // Best-effort: dispose() can't be awaited, and a page's project copy
      // (once handed off) must never race a delete of its source file.
      _tempDir?.delete(recursive: true).catchError((_) => _tempDir!);
    }
    super.dispose();
  }

  Future<Directory> _ensureTempDir() async =>
      _tempDir ??= await widget.tempDirProvider();

  Future<File> _writePage(Uint8List bytes) async {
    final dir = await _ensureTempDir();
    final file = File(
      p.join(dir.path, 'page_${DateTime.now().microsecondsSinceEpoch}.jpg'),
    );
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<void> _capture() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _source.takePicture();
      final bytes = await file.readAsBytes();
      // The plugin wrote the capture into its own cache dir; the bytes are
      // copied, so reclaim the file rather than stranding a full-res JPEG
      // per shot there for the OS to clean up eventually.
      try {
        await file.delete();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _pendingShot = bytes;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context)!.worldClipPsShotFailed('$e'))));
    }
  }

  void _retakeShot() => setState(() => _pendingShot = null);

  Future<void> _keepShot() async {
    if (_busy) return;
    final shot = _pendingShot;
    if (shot == null) return;
    final pageComplete = _session.acceptShot(shot);
    if (!pageComplete) {
      setState(() => _pendingShot = null);
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = _session.liveShotCount > 1
          ? AppLocalizations.of(context)!.worldClipPsCombining
          : '';
    });
    await _finishPage();
  }

  Future<void> _finishPage() async {
    try {
      final (_, usedFallback) = await _session.finishPage();
      if (!mounted) return;
      setState(() {
        _pendingShot = null;
        _busy = false;
        _busyLabel = '';
      });
      if (usedFallback) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context)!.worldClipPsFuseFallback)));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pendingShot = null;
        _busy = false;
        _busyLabel = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(AppLocalizations.of(context)!.worldClipPsSaveFailed('$e'))));
    }
  }

  /// Retake/discard on a FINISHED page must be blocked while a shot is
  /// pending review or a page is mid-capture — otherwise retaking/discarding
  /// an unrelated page silently destroys the shots already accepted toward
  /// the page in progress (or, worse, orphans them into a later page's
  /// fusion once that page finishes — see PictureSequenceSession.discardPage
  /// docs).
  bool get _canManagePages => _pendingShot == null && !_session.midPage;

  Future<void> _showPageActions(int index) async {
    if (!_canManagePages) return;
    final l10n = AppLocalizations.of(context)!;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('ps-page-retake'),
              leading: const Icon(Icons.replay),
              title: Text(l10n.worldClipPsRetakePage),
              onTap: () => Navigator.of(context).pop('retake'),
            ),
            ListTile(
              key: const ValueKey('ps-page-discard'),
              leading: const Icon(Icons.delete_outline),
              title: Text(l10n.worldClipPsDiscardPage),
              onTap: () => Navigator.of(context).pop('discard'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'retake') {
      setState(() {
        _session.retakePage(index);
        _pendingShot = null;
      });
    } else if (action == 'discard') {
      setState(() => _session.discardPage(index));
    }
  }

  void _toggleAntiGlare() =>
      setState(() => _session.setAntiGlare(!_session.antiGlare));

  /// Flash is a global, session-wide toggle (not per-shot): once applied to
  /// the live controller it stays in effect for every capture from here on,
  /// so this is the only place flash mode is ever set. Uses [FlashMode.torch]
  /// (a continuous light) rather than [FlashMode.always] (fires only at the
  /// instant of capture) — `always` makes the camera turn the flash on,
  /// re-run AE/AF against the now-differently-lit scene, and only then
  /// capture, so exposure/focus (and the shot itself) become inconsistent
  /// shot to shot. Torch stays on for the whole session, so every shot sees
  /// the same lighting AE/AF already settled against, and it's visible in
  /// the live preview while framing besides. Reverts the toggled state if
  /// the hardware rejects it (e.g. no flash unit on this camera) so the
  /// on/off icon never lies about what the camera will actually do.
  Future<void> _toggleFlash() async {
    if (_flashBusy) return;
    final next = !_session.flashOn;
    setState(() {
      _flashBusy = true;
      _session.setFlashOn(next);
    });
    try {
      await _source.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (!mounted) return;
      setState(() => _flashBusy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _flashBusy = false;
        _session.setFlashOn(!next);
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              AppLocalizations.of(context)!.worldClipPsFlashFailed('$e'))));
    }
  }

  /// Anything leaving the screen would destroy: finished pages, anti-glare
  /// shots accepted toward an unfinished page, or a shot awaiting Keep.
  bool get _hasCapturedWork =>
      _session.pages.isNotEmpty || _session.midPage || _pendingShot != null;

  Future<void> _cancel() async {
    if (!_hasCapturedWork) {
      Navigator.of(context).pop(null);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.worldClipPsDiscardTitle),
        content: Text(_session.pages.isEmpty
            ? l10n.worldClipPsDiscardShotsBody
            : l10n.worldClipPsDiscardBody(_session.pages.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.worldClipPsKeepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.worldClipPsDiscard),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) Navigator.of(context).pop(null);
  }

  void _done() {
    if (_session.pages.isEmpty) return;
    _handedOffPages = true; // caller now owns copying these files
    Navigator.of(context).pop(_session.pages);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopScope(
      // A system back with captured work (pages, mid-page anti-glare shots,
      // or a shot awaiting Keep) must go through the same discard
      // confirmation as the close button — one accidental back gesture must
      // not silently destroy it.
      canPop: !_hasCapturedWork && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _cancel();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(l10n.worldClipPictureSequence),
          leading: IconButton(
            key: const ValueKey('ps-cancel'),
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : _cancel,
          ),
          actions: [
            IconButton(
              key: const ValueKey('ps-flash-toggle'),
              icon: Icon(_session.flashOn ? Icons.flash_on : Icons.flash_off),
              // Not ready: nothing to apply the flash mode to yet. Busy: avoid
              // racing setFlashMode against an in-flight takePicture() on the
              // same controller.
              onPressed: (_ready && !_busy && !_flashBusy) ? _toggleFlash : null,
            ),
            Row(
              children: [
                Text(l10n.worldClipPsAntiGlare,
                    style: const TextStyle(fontSize: 14)),
                Switch(
                  key: const ValueKey('ps-anti-glare-toggle'),
                  value: _session.antiGlare,
                  onChanged: _session.canToggleAntiGlare
                      ? (_) => _toggleAntiGlare()
                      : null,
                ),
              ],
            ),
            TextButton(
              key: const ValueKey('ps-done'),
              // midPage: finishing now would silently drop the shots already
              // accepted toward the unfinished anti-glare page — complete the
              // page (or cancel) first.
              onPressed:
                  (_busy || _session.midPage || _session.pages.isEmpty)
                      ? null
                      : _done,
              child: Text(
                l10n.worldClipPsDone(_session.pages.length),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        body: _buildBody(l10n),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_initError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.worldClipPsCameraError,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
                child:
                    _pendingShot == null ? _buildLive(l10n) : _buildReview(l10n)),
            _buildPageStrip(l10n),
          ],
        ),
        if (_busy) ProgressScrim(label: _busyLabel),
      ],
    );
  }

  Widget _buildLive(AppLocalizations l10n) {
    final guidanceIndex = _session.liveShotCount;
    final step = _session.antiGlare && guidanceIndex < kAntiGlareSteps.length
        ? kAntiGlareSteps[guidanceIndex]
        : null;
    return Stack(
      children: [
        Center(child: CameraPreview(_source.controller)),
        if (step != null)
          Positioned(
            top: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                key: const ValueKey('ps-anti-glare-guidance'),
                constraints: const BoxConstraints(maxWidth: 320),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xCC000000),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _AntiGlarePositionDiagram(currentIndex: guidanceIndex),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.worldClipPsStepProgress(
                              antiGlareStepLabel(l10n, step),
                              guidanceIndex + 1,
                              kAntiGlareShotsPerPage,
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            antiGlareStepInstruction(l10n, step),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: FloatingActionButton(
              key: const ValueKey('ps-shutter'),
              backgroundColor: Colors.white,
              onPressed: (_busy || _flashBusy) ? null : _capture,
              child: const Icon(Icons.camera_alt, color: Colors.black),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReview(AppLocalizations l10n) {
    return Column(
      children: [
        Expanded(child: Image.memory(_pendingShot!, fit: BoxFit.contain)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('ps-retake-shot'),
                  icon: const Icon(Icons.replay),
                  label: Text(l10n.worldClipPsRetake),
                  onPressed: _retakeShot,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('ps-keep-shot'),
                  icon: const Icon(Icons.check),
                  label: Text(l10n.worldClipPsKeep),
                  onPressed: _keepShot,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPageStrip(AppLocalizations l10n) {
    final pages = _session.pages;
    if (pages.isEmpty) {
      return SizedBox(
        height: 72,
        child: Center(
          child: Text(l10n.worldClipPsNoPages,
              style: const TextStyle(color: Colors.white38)),
        ),
      );
    }
    return SizedBox(
      key: const ValueKey('ps-page-strip'),
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: pages.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: GestureDetector(
            key: ValueKey('ps-page-thumb-$index'),
            onTap: _canManagePages ? () => _showPageActions(index) : null,
            child: Opacity(
              opacity: _canManagePages ? 1.0 : 0.4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(pages[index], width: 56, fit: BoxFit.cover),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A miniature top-down view of the page with a dot at each
/// [kAntiGlareSteps] position — a page-shaped square outline plus 5 dots laid
/// out at their [AntiGlareStep.dx]/[dy] (which are already in Flutter's
/// Alignment(-1..1) range). Gives an at-a-glance sense of WHERE to move the
/// camera to next that the text instruction alone doesn't: green for
/// positions already shot (the flow is strictly sequential, so that's every
/// index below [currentIndex]), amber (and bigger) for the current target,
/// dim white for what's still ahead.
class _AntiGlarePositionDiagram extends StatelessWidget {
  const _AntiGlarePositionDiagram({required this.currentIndex});

  final int currentIndex;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white38),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          for (var i = 0; i < kAntiGlareSteps.length; i++)
            Align(
              alignment: Alignment(
                kAntiGlareSteps[i].dx,
                kAntiGlareSteps[i].dy,
              ),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: _Dot(
                  color: i < currentIndex
                      ? Colors.greenAccent
                      : i == currentIndex
                          ? Colors.amberAccent
                          : Colors.white38,
                  size: i == currentIndex ? 12 : 7,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
