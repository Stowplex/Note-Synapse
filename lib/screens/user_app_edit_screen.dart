import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import '../l10n/app_localizations.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import '../models/user_app_library.dart';
import '../providers/app_provider.dart';
import '../services/user_app_library_service.dart';
import '../utils/file_utils.dart';
import 'note_selection_dialog.dart';

class UserAppEditScreen extends StatefulWidget {
  final UserApp app;
  final AppRevision? selectedRevision;

  const UserAppEditScreen({
    super.key,
    required this.app,
    this.selectedRevision,
  });

  @override
  State<UserAppEditScreen> createState() => _UserAppEditScreenState();
}

class _UserAppEditScreenState extends State<UserAppEditScreen>
    with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _editSuggestionController = TextEditingController();
  late final CodeLineEditingController _codeController;
  late final CodeLineEditingController
  _viewController; // Read-only controller for viewing
  late final CodeFindController _findController;
  late final MobileSelectionToolbarController _mobileToolbarController;
  late final MobileSelectionToolbarController _viewMobileToolbarController;
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isCodeEditable = false;
  bool _isSearchVisible = false; // Control search input visibility
  String _originalCode = '';
  List<String> _attachmentPaths = [];
  final List<Note> _selectedNotes = [];

  // Tab management
  late TabController _tabController;

  // Library management
  List<UserAppLibrary> _modifiedLibraries = [];
  Map<int, List<String>> _libraryLinks = {}; // libraryId -> list of links
  bool _isLoadingLibraries = false;

  // Prevent rapid state changes during transitions
  bool _isTransitioning = false;
  static const int _readOnlyCodeLineCount = 20;
  static const double _readOnlyCodeLineHeight = 20.0;

  @override
  void initState() {
    super.initState();
    _codeController = CodeLineEditingController.fromText('');
    _viewController = CodeLineEditingController.fromText('');
    _findController = CodeFindController(_codeController);
    _mobileToolbarController = MobileSelectionToolbarController(
      builder: _buildMobileToolbar,
    );
    _viewMobileToolbarController = MobileSelectionToolbarController(
      builder: _buildViewMobileToolbar,
    );

    // Add listener to find input controller to prevent text selection issues
    // Use addPostFrameCallback to avoid potential issues during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _findController.findInputController.addListener(() {
          final text = _findController.findInputController.text;
          final selection = _findController.findInputController.selection;

          // If all text is selected, move cursor to end
          if (selection.isValid &&
              selection.start == 0 &&
              selection.end == text.length &&
              text.isNotEmpty) {
            _findController.findInputController.selection =
                TextSelection.fromPosition(TextPosition(offset: text.length));
          }
        });
      }
    });

    // Note: No need to add listener to code controller as the mobile toolbar
    // controller already handles selection-based UI updates automatically

    _tabController = TabController(length: 2, vsync: this);
    _loadCurrentRevisionCode();
    _loadCurrentRevisionAttachments();
    _loadCurrentLibraries();
  }

  AppRevision? _currentRevision;

  Future<void> _loadCurrentRevisionCode() async {
    try {
      final appProvider = context.read<AppProvider>();
      await appProvider.getAppRevisions(widget.app.id);

      // Get revisions from provider
      final revisions = appProvider.appRevisions[widget.app.id] ?? [];

      String codeToLoad = '';

      // Use the passed selected revision if available, otherwise fall back to pinned revision
      if (widget.selectedRevision != null) {
        // Use the temporarily selected revision
        _currentRevision = widget.selectedRevision;
        codeToLoad = widget.selectedRevision!.appCode;
      } else {
        // Fall back to the pinned revision (current app's selectedRevisionId)
        final currentApp = appProvider.userApps.firstWhere(
          (app) => app.id == widget.app.id,
          orElse: () => widget.app,
        );

        if (currentApp.selectedRevisionId != null) {
          try {
            _currentRevision = revisions.firstWhere(
              (r) => r.id == currentApp.selectedRevisionId,
            );
            codeToLoad = _currentRevision!.appCode;
          } catch (e) {
            // If pinned revision not found, use the latest revision
            if (revisions.isNotEmpty) {
              _currentRevision = revisions.last;
              codeToLoad = _currentRevision!.appCode;
            }
          }
        } else if (revisions.isNotEmpty) {
          // If no pinned revision, use the latest revision
          _currentRevision = revisions.last;
          codeToLoad = _currentRevision!.appCode;
        }
      }

      setState(() {
        _originalCode = codeToLoad;
        _codeController.text = codeToLoad;
        _viewController.text = codeToLoad;
        // Ensure view controller is properly initialized
        _viewController.value = CodeLineEditingValue(
          codeLines: CodeLines.fromText(codeToLoad),
        );
      });

      // Load libraries for the current revision
      _loadCurrentLibraries();
    } catch (e) {
      // If there's an error loading revisions, show empty code
      setState(() {
        _originalCode = '';
        _codeController.text = '';
        _viewController.text = '';
        // Ensure view controller is properly initialized
        _viewController.value = CodeLineEditingValue(
          codeLines: CodeLines.fromText(''),
        );
        _currentRevision = null;
      });
    }
  }

  Future<void> _loadCurrentRevisionAttachments() async {
    // Don't auto-load previous revision attachments - images should be for current revision only
    setState(() {
      _attachmentPaths = [];
    });
  }

  Future<void> _loadCurrentLibraries() async {
    if (_currentRevision == null) return;

    setState(() {
      _isLoadingLibraries = true;
    });

    try {
      final libraryService = UserAppLibraryService();
      final libraries = await libraryService.getLibraries(
        widget.app.uuid,
        _currentRevision!.revisionNumber,
      );

      // Load dependencies (links) for each library
      final Map<int, List<String>> libraryLinks = {};
      for (final library in libraries) {
        final dependencies = await libraryService.getDependencies(library.id);
        libraryLinks[library.id] = dependencies
            .map((dep) => dep.originalUrl ?? '')
            .where((url) => url.isNotEmpty)
            .toList();
      }

      setState(() {
        _modifiedLibraries = List.from(libraries);
        _libraryLinks = libraryLinks;
        _isLoadingLibraries = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingLibraries = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading libraries: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    // Reset transition flag to prevent any pending operations
    _isTransitioning = false;

    _editSuggestionController.dispose();
    _codeController.dispose();
    _viewController.dispose();
    _findController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _submitEdit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isEditing = true;
    });

    try {
      final appProvider = context.read<AppProvider>();

      // Create a modified app that represents the current revision
      final currentApp = widget.app.copyWith(
        htmlContent: _currentRevision?.appCode ?? widget.app.htmlContent,
        selectedRevisionId:
            _currentRevision?.id ?? widget.app.selectedRevisionId,
      );

      // Convert libraries to UserAppLibraryInfo format for AI prompt
      List<UserAppLibraryInfo>? librariesForAI;
      if (_modifiedLibraries.isNotEmpty) {
        librariesForAI = _modifiedLibraries
            .map((library) {
              final links = _libraryLinks[library.id] ?? [];
              final validLinks = links
                  .where((link) => link.trim().isNotEmpty)
                  .toList();

              return UserAppLibraryInfo(
                name: library.name,
                usage: library.usageInstructions,
                links: validLinks,
              );
            })
            .where((lib) => lib.name.trim().isNotEmpty)
            .toList();

        // If no valid libraries, set to null
        if (librariesForAI.isEmpty) {
          librariesForAI = null;
        }
      }

      // Create the new revision using the existing editUserApp method
      await appProvider.editUserApp(
        originalApp: currentApp,
        editSuggestion: _editSuggestionController.text.trim(),
        attachmentPaths: _attachmentPaths.isNotEmpty ? _attachmentPaths : null,
        contextNotes: _selectedNotes.isNotEmpty
            ? List<Note>.from(_selectedNotes)
            : null,
        libraries: librariesForAI,
      );

      if (mounted) {
        Navigator.pop(context, true); // Return true to indicate successful edit
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('App updated successfully with new revision'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isEditing = false;
        });

        // Show error dialog instead of snackbar for better visibility
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.appEditFailed),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(
                    context,
                  )!.errorCreatingAppFromEdit(e.toString()),
                ),
                const SizedBox(height: 8),
                Text(
                  'Please check your API key and try again.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context)!.close),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _saveCodeDirectly() async {
    if (_codeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(
              context,
            )!.errorSavingCode('Code cannot be empty'),
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final appProvider = context.read<AppProvider>();

      // Create a modified app that represents the current revision
      final currentApp = widget.app.copyWith(
        htmlContent: _currentRevision?.appCode ?? widget.app.htmlContent,
        selectedRevisionId:
            _currentRevision?.id ?? widget.app.selectedRevisionId,
      );

      // Save manual code edit by creating a new revision
      await appProvider.saveManualCodeEdit(
        originalApp: currentApp,
        newCode: _codeController.text.trim(),
        attachmentPaths: _attachmentPaths.isNotEmpty ? _attachmentPaths : null,
      );

      if (mounted) {
        setState(() {
          _originalCode = _codeController.text.trim();
          _isCodeEditable = false;
        });

        // Return true to indicate successful save
        Navigator.pop(context, true);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.codeSavedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(context)!.errorSavingCode(e.toString()),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _toggleCodeEdit() {
    // Prevent rapid state changes during transitions
    if (_isTransitioning) return;

    if (!_isCodeEditable) {
      // Switching to edit mode - can do immediately
      setState(() {
        _isCodeEditable = true;
      });
    } else {
      // Switching to view mode - add delay to allow rendering to complete
      _isTransitioning = true;
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) {
          setState(() {
            _isCodeEditable = false;
            _isTransitioning = false;
            // Reset to original code if canceling edit
            _codeController.text = _originalCode;
            _viewController.text = _originalCode;
            // Ensure view controller is properly initialized
            _viewController.value = CodeLineEditingValue(
              codeLines: CodeLines.fromText(_originalCode),
            );
          });
        }
      });
    }
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _attachmentPaths.add(image.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _takePhoto() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _attachmentPaths.add(image.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error taking photo: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachmentPaths.removeAt(index);
    });
  }

  void _showNoteSelectionDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return NoteSelectionDialog(
          title: l10n.selectNotesToAddToContext,
          onNotesSelected: (notes) {
            Navigator.of(dialogContext).pop();
            if (!mounted) return;
            setState(() {
              final noteMap = {
                for (final note in _selectedNotes) note.id: note,
              };
              for (final note in notes) {
                noteMap[note.id] = note;
              }
              _selectedNotes
                ..clear()
                ..addAll(noteMap.values);
            });
          },
        );
      },
    );
  }

  void _removeSelectedNote(String noteId) {
    setState(() {
      _selectedNotes.removeWhere((note) => note.id == noteId);
    });
  }

  void _clearSelectedNotes() {
    if (_selectedNotes.isEmpty) return;
    setState(() {
      _selectedNotes.clear();
    });
  }

  void _showImageSourceDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Image Source'),
        content: const Text('Choose how you want to add an image'),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _takePhoto();
            },
            icon: const Icon(Icons.camera_alt),
            label: const Text('Camera'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _pickImage();
            },
            icon: const Icon(Icons.photo_library),
            label: const Text('Gallery'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  // Library management methods
  void _addLibrary() {
    setState(() {
      final newLibrary = UserAppLibrary(
        id: -1, // Temporary ID for new libraries
        appUuid: widget.app.uuid,
        revisionId: _currentRevision?.revisionNumber ?? 0,
        name: '',
        usageInstructions: '',
      );
      _modifiedLibraries.add(newLibrary);
      _libraryLinks[newLibrary.id] = [''];
    });
  }

  void _removeLibrary(int index) {
    setState(() {
      final library = _modifiedLibraries[index];
      _libraryLinks.remove(library.id);
      _modifiedLibraries.removeAt(index);
    });
  }

  void _updateLibraryName(int index, String name) {
    setState(() {
      _modifiedLibraries[index] = UserAppLibrary(
        id: _modifiedLibraries[index].id,
        appUuid: _modifiedLibraries[index].appUuid,
        revisionId: _modifiedLibraries[index].revisionId,
        name: name,
        usageInstructions: _modifiedLibraries[index].usageInstructions,
      );
    });
  }

  void _updateLibraryUsage(int index, String usage) {
    setState(() {
      _modifiedLibraries[index] = UserAppLibrary(
        id: _modifiedLibraries[index].id,
        appUuid: _modifiedLibraries[index].appUuid,
        revisionId: _modifiedLibraries[index].revisionId,
        name: _modifiedLibraries[index].name,
        usageInstructions: usage.isEmpty ? null : usage,
      );
    });
  }

  void _addLibraryLink(int libraryIndex) {
    setState(() {
      final library = _modifiedLibraries[libraryIndex];
      final currentLinks = List<String>.from(_libraryLinks[library.id] ?? []);
      currentLinks.add('');
      _libraryLinks[library.id] = currentLinks;
    });
  }

  void _removeLibraryLink(int libraryIndex, int linkIndex) {
    setState(() {
      final library = _modifiedLibraries[libraryIndex];
      final currentLinks = List<String>.from(_libraryLinks[library.id] ?? []);
      if (currentLinks.length > 1) {
        currentLinks.removeAt(linkIndex);
        _libraryLinks[library.id] = currentLinks;
      }
    });
  }

  void _updateLibraryLink(int libraryIndex, int linkIndex, String link) {
    setState(() {
      final library = _modifiedLibraries[libraryIndex];
      final currentLinks = List<String>.from(_libraryLinks[library.id] ?? []);
      currentLinks[linkIndex] = link;
      _libraryLinks[library.id] = currentLinks;
    });
  }

  // Toolbar action methods
  void _toggleSearch() {
    setState(() {
      _isSearchVisible = !_isSearchVisible;
      if (_isSearchVisible) {
        _findController.findMode();
      } else {
        _findController.close();
      }
    });
  }

  void _copySelectedText() {
    final selection = _codeController.selection;
    if (!selection.isCollapsed) {
      // Get the selected text using the proper CodeLineSelection methods
      final codeLines = _codeController.value.codeLines;
      final selectedText = _getSelectedTextFromCodeLines(codeLines, selection);

      Clipboard.setData(ClipboardData(text: selectedText));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied: ${selectedText.length} characters')),
      );
    }
  }

  String _getSelectedTextFromCodeLines(
    CodeLines codeLines,
    CodeLineSelection selection,
  ) {
    if (selection.isCollapsed) return '';

    final startIndex = selection.startIndex;
    final endIndex = selection.endIndex;
    final startOffset = selection.startOffset;
    final endOffset = selection.endOffset;

    if (startIndex == endIndex) {
      // Selection is within a single line
      return codeLines[startIndex].text.substring(startOffset, endOffset);
    } else {
      // Selection spans multiple lines
      final buffer = StringBuffer();

      // First line (from startOffset to end)
      buffer.write(codeLines[startIndex].text.substring(startOffset));

      // Middle lines (complete lines)
      for (int i = startIndex + 1; i < endIndex; i++) {
        buffer.write('\n');
        buffer.write(codeLines[i].text);
      }

      // Last line (from start to endOffset)
      if (endIndex < codeLines.length) {
        buffer.write('\n');
        buffer.write(codeLines[endIndex].text.substring(0, endOffset));
      }

      return buffer.toString();
    }
  }

  void _selectAll() {
    final codeLines = _codeController.value.codeLines;
    if (codeLines.isNotEmpty) {
      _codeController.selection = CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: codeLines.length - 1,
        extentOffset: codeLines.last.length,
      );
    }
  }

  /// Get the appropriate code theme based on the current app theme
  /// Cached to avoid repeated Theme.of(context) calls during build
  CodeHighlightTheme? _cachedCodeTheme;
  Brightness? _lastBrightness;

  CodeHighlightTheme get _codeTheme {
    final currentBrightness = Theme.of(context).brightness;

    // Only recreate theme if brightness has changed
    if (_cachedCodeTheme == null || _lastBrightness != currentBrightness) {
      _lastBrightness = currentBrightness;
      final isDarkMode = currentBrightness == Brightness.dark;

      _cachedCodeTheme = CodeHighlightTheme(
        languages: {
          'html': CodeHighlightThemeMode(
            mode: langXml, // HTML uses XML highlighting mode
          ),
          'javascript': CodeHighlightThemeMode(mode: langJavascript),
          'css': CodeHighlightThemeMode(mode: langCss),
        },
        theme: isDarkMode ? atomOneDarkTheme : atomOneLightTheme,
      );
    }

    return _cachedCodeTheme!;
  }

  void _copyViewSelectedText() {
    final selection = _viewController.selection;
    if (!selection.isCollapsed) {
      // Get the selected text using the proper CodeLineSelection methods
      final codeLines = _viewController.value.codeLines;
      final selectedText = _getSelectedTextFromCodeLines(codeLines, selection);

      Clipboard.setData(ClipboardData(text: selectedText));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copied: ${selectedText.length} characters')),
      );
    }
  }

  void _selectAllView() {
    final codeLines = _viewController.value.codeLines;
    if (codeLines.isNotEmpty) {
      _viewController.selection = CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: codeLines.length - 1,
        extentOffset: codeLines.last.length,
      );
    }
  }

  void _undo() {
    _codeController.undo();
  }

  void _redo() {
    _codeController.redo();
  }

  bool get _canUndo => _codeController.canUndo;
  bool get _canRedo => _codeController.canRedo;

  Widget _buildMobileToolbar({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final hasSelection = !controller.selection.isCollapsed;

    return Align(
      alignment: Alignment.center,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 100, // Increased width to accommodate both buttons
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Copy button when text is selected
              if (hasSelection)
                _buildCompactToolbarButton(
                  context: context,
                  icon: Icons.copy,
                  onPressed: () {
                    _copySelectedText();
                    onDismiss();
                  },
                ),
              // Select All button (always visible)
              _buildCompactToolbarButton(
                context: context,
                icon: Icons.select_all,
                onPressed: () {
                  _selectAll();
                  onRefresh();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewMobileToolbar({
    required BuildContext context,
    required TextSelectionToolbarAnchors anchors,
    required CodeLineEditingController controller,
    required VoidCallback onDismiss,
    required VoidCallback onRefresh,
  }) {
    final hasSelection = !controller.selection.isCollapsed;

    return Align(
      alignment: Alignment.center,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 100, // Same width as edit toolbar
          height: 40,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Copy button when text is selected
              if (hasSelection)
                _buildCompactToolbarButton(
                  context: context,
                  icon: Icons.copy,
                  onPressed: () {
                    _copyViewSelectedText();
                    onDismiss();
                  },
                ),
              // Select All button (always visible)
              _buildCompactToolbarButton(
                context: context,
                icon: Icons.select_all,
                onPressed: () {
                  _selectAllView();
                  onRefresh();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCompactToolbarButton({
    required BuildContext context,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 40,
      height: 32,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(4),
          child: Icon(
            icon,
            size: 16,
            color: onPressed != null
                ? Theme.of(context).textTheme.bodyMedium?.color
                : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }

  Widget _buildPermanentToolbar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      child: Row(
        children: [
          // Undo button
          IconButton(
            icon: const Icon(Icons.undo, size: 18),
            onPressed: _canUndo ? _undo : null,
            tooltip: 'Undo',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          // Redo button
          IconButton(
            icon: const Icon(Icons.redo, size: 18),
            onPressed: _canRedo ? _redo : null,
            tooltip: 'Redo',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 8),
          // Search toggle button
          IconButton(
            icon: Icon(
              _isSearchVisible ? Icons.search_off : Icons.search,
              size: 18,
            ),
            onPressed: _toggleSearch,
            tooltip: _isSearchVisible ? 'Hide search' : 'Show search',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _findController.findInputController,
              focusNode: _findController.findInputFocusNode,
              decoration: const InputDecoration(
                hintText: 'Find...',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                isDense: true,
              ),
              onChanged: (value) {
                _findController.findMode();
              },
              onTap: () {
                // Move cursor to end of text instead of selecting all
                final text = _findController.findInputController.text;
                _findController.findInputController.selection =
                    TextSelection.fromPosition(
                      TextPosition(offset: text.length),
                    );
              },
            ),
          ),
          const SizedBox(width: 8),
          // Match counter
          ValueListenableBuilder<CodeFindValue?>(
            valueListenable: _findController,
            builder: (context, value, child) {
              if (value?.result != null && value!.result!.matches.isNotEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text(
                    '${value.result!.index + 1}/${value.result!.matches.length}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 12),
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 16),
            onPressed: () => _findController.previousMatch(),
            tooltip: 'Find previous',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 16),
            onPressed: () => _findController.nextMatch(),
            tooltip: 'Find next',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.find_replace, size: 16),
            onPressed: () => _findController.replaceMode(),
            tooltip: 'Find and replace',
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      resizeToAvoidBottomInset: true, // Always resize to avoid keyboard
      appBar: AppBar(
        title: Text(l10n.editApp),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.basic),
            Tab(text: l10n.advanced),
          ],
        ),
      ),
      body: Form(
        key: _formKey,
        child: _isCodeEditable
            ? _buildEditModeLayout(l10n)
            : _buildViewModeLayout(l10n),
      ),
    );
  }

  Widget _buildViewModeLayout(AppLocalizations l10n) {
    return TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(), // Disable tab swipe
      children: [_buildBasicTab(l10n), _buildAdvancedTab(l10n)],
    );
  }

  Widget _buildBasicTab(AppLocalizations l10n) {
    final mediaQuery = MediaQuery.of(context);
    final double bottomPadding = mediaQuery.padding.bottom;

    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: bottomPadding + 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAppInfoCard(l10n),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildReadOnlyCodeHeader(l10n),
                const SizedBox(height: 8),
                SizedBox(
                  height: _readOnlyCodeLineCount * _readOnlyCodeLineHeight,
                  child: Card(
                    child: Container(
                      padding: const EdgeInsets.all(12.0),
                      child: _buildReadOnlyCodeEditor(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _buildSuggestionSection(l10n),
          ),
        ],
      ),
    );
  }

  Widget _buildAppInfoCard(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: SizedBox(
        width: double.infinity,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.appName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.app.name,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.appDescription,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  widget.app.description.length > 200
                      ? '${widget.app.description.substring(0, 200)}...'
                      : widget.app.description,
                  style: Theme.of(context).textTheme.bodyLarge,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadOnlyCodeHeader(AppLocalizations l10n) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(l10n.appCode, style: Theme.of(context).textTheme.titleMedium),
        ElevatedButton.icon(
          onPressed: _toggleCodeEdit,
          icon: const Icon(Icons.edit, size: 16),
          label: Text(l10n.editCodeDirectly),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blue,
            foregroundColor: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildReadOnlyCodeEditor() {
    return CodeEditor(
      controller: _viewController,
      toolbarController: _viewMobileToolbarController,
      readOnly: true,
      showCursorWhenReadOnly: true,
      wordWrap: false,
      style: CodeEditorStyle(
        codeTheme: _codeTheme,
        fontFamily: 'monospace',
        fontSize: 12,
      ),
      chunkAnalyzer: DefaultCodeChunkAnalyzer(),
    );
  }

  Widget _buildSuggestionSection(AppLocalizations l10n) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
        ),
      ),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                l10n.editSuggestion,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_selectedNotes.isNotEmpty)
                    IconButton(
                      onPressed: _clearSelectedNotes,
                      icon: const Icon(Icons.clear_all),
                      tooltip: l10n.clearFilters,
                    ),
                  IconButton(
                    onPressed: _showNoteSelectionDialog,
                    icon: const Icon(Icons.note_add),
                    tooltip: l10n.addNotes,
                  ),
                  IconButton(
                    onPressed: _showImageSourceDialog,
                    icon: const Icon(Icons.add_photo_alternate),
                    tooltip: l10n.addImage,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _editSuggestionController,
            decoration: InputDecoration(
              hintText: l10n.editSuggestionHint,
              border: const OutlineInputBorder(),
            ),
            maxLines: 3,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter your edit suggestion';
              }
              return null;
            },
          ),
          if (_selectedNotes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.notesSelected(_selectedNotes.length),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _selectedNotes.map((note) {
                return InputChip(
                  label: Text(note.title),
                  avatar: Icon(
                    note.isTask ? Icons.check_circle : Icons.notes,
                    size: 18,
                  ),
                  onDeleted: () => _removeSelectedNote(note.id),
                );
              }).toList(),
            ),
          ],
          if (_attachmentPaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Attached Images:',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: _attachmentPaths.asMap().entries.map((entry) {
                final index = entry.key;
                final path = entry.value;
                return Stack(
                  children: [
                    GestureDetector(
                      onTap: () => FileUtils.openFile(path, context),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8.0),
                          border: Border.all(
                            color: Colors.grey.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(7.0),
                          child: Image.file(
                            File(path),
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: GestureDetector(
                        onTap: () => _removeAttachment(index),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isEditing ? null : _submitEdit,
            child: _isEditing
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(l10n.editingApp),
                    ],
                  )
                : Text(l10n.submitEdit),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedTab(AppLocalizations l10n) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Add Library Button
          OutlinedButton.icon(
            onPressed: _addLibrary,
            icon: const Icon(Icons.add),
            label: Text(l10n.addLibrary),
          ),
          const SizedBox(height: 16),

          // Libraries List
          if (_isLoadingLibraries)
            const Center(child: CircularProgressIndicator())
          else
            ...List.generate(_modifiedLibraries.length, (index) {
              return _buildLibraryCard(index, l10n);
            }),

          if (_modifiedLibraries.isEmpty && !_isLoadingLibraries) ...[
            const SizedBox(height: 32),
            Center(
              child: Text(
                'No libraries added yet. Click "Add Library" to get started.',
                style: Theme.of(
                  context,
                ).textTheme.bodyLarge?.copyWith(color: Colors.grey[600]),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLibraryCard(int index, AppLocalizations l10n) {
    final library = _modifiedLibraries[index];
    final links = _libraryLinks[library.id] ?? [];

    return Card(
      margin: const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Library Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Library ${index + 1}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: () => _removeLibrary(index),
                  icon: const Icon(Icons.delete),
                  tooltip: l10n.removeLibrary,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Library Name
            TextFormField(
              initialValue: library.name,
              decoration: InputDecoration(
                labelText: l10n.libraryName,
                hintText: l10n.libraryNameHint,
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => _updateLibraryName(index, value),
            ),
            const SizedBox(height: 16),

            // Library Usage
            TextFormField(
              initialValue: library.usageInstructions ?? '',
              decoration: InputDecoration(
                labelText: l10n.libraryUsage,
                hintText: l10n.libraryUsageHint,
                border: const OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) => _updateLibraryUsage(index, value),
            ),
            const SizedBox(height: 16),

            // Library Links
            Text(
              l10n.libraryLink,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),

            ...List.generate(links.length, (linkIndex) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: links[linkIndex],
                        decoration: InputDecoration(
                          hintText: l10n.libraryLinkHint,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) =>
                            _updateLibraryLink(index, linkIndex, value),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: links.length > 1
                          ? () => _removeLibraryLink(index, linkIndex)
                          : null,
                      icon: const Icon(Icons.remove_circle),
                      tooltip: l10n.removeLink,
                    ),
                  ],
                ),
              );
            }),

            // Add Link Button
            OutlinedButton.icon(
              onPressed: () => _addLibraryLink(index),
              icon: const Icon(Icons.add),
              label: Text(l10n.addLink),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditModeLayout(AppLocalizations l10n) {
    return Column(
      children: [
        // App Info Card (smaller in edit mode)
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.app.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          widget.app.description,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveCodeDirectly,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save, size: 16),
                        label: Text(l10n.saveCode),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _isSaving ? null : _toggleCodeEdit,
                        icon: const Icon(Icons.cancel, size: 16),
                        label: Text(l10n.cancel),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),

        // Permanent toolbar
        _buildPermanentToolbar(),

        // Search bar (only visible when search is enabled)
        if (_isSearchVisible) ...[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: _buildSearchBar(),
          ),
        ],

        // Full-screen code editor
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Card(
              child: Container(
                padding: const EdgeInsets.all(12.0),
                child: CodeEditor(
                  controller: _codeController,
                  findController: _findController,
                  toolbarController: _mobileToolbarController,
                  wordWrap: false, // Disable word wrap
                  style: CodeEditorStyle(
                    codeTheme: _codeTheme,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                  chunkAnalyzer: DefaultCodeChunkAnalyzer(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
