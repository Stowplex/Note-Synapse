import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:gpt_markdown/custom_widgets/selectable_adapter.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

import 'package:crypto/crypto.dart';
import '../models/note.dart';
import '../utils/synapse_app_block_syntax.dart';
import '../utils/synapse_temp_utils.dart';
import '../utils/synapse_resource_uri.dart';
import '../services/attachment_link_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import 'embedded_user_app_view.dart';
import '../services/network_provider.dart';
import '../screens/immersive_note_screen.dart';
import '../screens/note_detail_screen.dart';
import '../screens/conversation_chat_screen.dart';
import '../utils/remote_image_storage.dart';
import '../utils/file_utils.dart';
import '../utils/file_type_utils.dart';
import 'heading_anchor_registry.dart';
import 'interactive_checkbox_component.dart';
import '../widgets/drawing_editor.dart';

/// Enum to represent image source type
enum _ImageSourceType { local, remote }

/// Applies a checkbox toggle to [content] and returns the updated string.
///
/// [checkboxLine] is the trimmed line as seen by the markdown component (may
/// or may not include the leading "- " list marker).
/// [checkboxText] is the label text after `[x]` / `[ ]`.
/// [newValue] is the desired checked state.
/// [occurrenceIndex] is the 0-based index among lines that match [checkboxLine],
/// in document order.  This disambiguates duplicate list items — e.g. two
/// consecutive `- [ ] item` lines each have a distinct occurrence index.
String applyCheckboxToggle(
  String content,
  String checkboxLine,
  String checkboxText,
  bool newValue, {
  int occurrenceIndex = 0,
}) {
  final lines = content.split('\n');
  final lineRegex = RegExp(r'^(\s*)(?:-\s+)?\[([ x])\]\s+(.+)$');

  // The markdown parser may strip the "- " prefix before passing text to
  // InteractiveCheckboxMd, so checkboxLine may be "[x] text" while the raw
  // source line is "- [x] text". Normalise before comparing.
  String normalize(String s) => s.startsWith('- ') ? s.substring(2) : s;

  // --- Pass 1: use checkboxLine for exact matching, honoring occurrenceIndex.
  int exactMatchCount = 0;
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmedLine = line.trim();
    if (normalize(trimmedLine) == normalize(checkboxLine)) {
      final m = lineRegex.firstMatch(line);
      if (m != null) {
        if (exactMatchCount == occurrenceIndex) {
          final indent = m.group(1) ?? '';
          final text = m.group(3) ?? '';
          final dash = trimmedLine.startsWith('-') ? '- ' : '';
          lines[i] = '$indent$dash[${newValue ? 'x' : ' '}] $text';
          return lines.join('\n');
        }
        exactMatchCount++;
      }
    }
  }

  // --- Pass 2: fallback — match by label text, honoring occurrenceIndex.
  // Do NOT use contains() — it causes false positives when one item's text is
  // a substring of another (e.g. "牙刷" inside "牙膏牙刷").
  int fallbackMatchCount = 0;
  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmedLine = line.trim();
    final m = lineRegex.firstMatch(line);
    if (m != null && m.group(3)?.trim() == checkboxText.trim()) {
      if (fallbackMatchCount == occurrenceIndex) {
        final indent = m.group(1) ?? '';
        final text = m.group(3) ?? '';
        final dash = trimmedLine.startsWith('-') ? '- ' : '';
        lines[i] = '$indent$dash[${newValue ? 'x' : ' '}] $text';
        return lines.join('\n');
      }
      fallbackMatchCount++;
    }
  }

  return content; // no match found — return unchanged
}

/// A wrapper widget that provides interactive checkboxes using gpt_markdown
/// with a custom checkbox component that handles state updates.
class InteractiveCheckboxMarkdown extends StatefulWidget {
  final String originalContent;
  final Function(String)? onContentChanged;
  final TextStyle? style;
  final TextDirection textDirection;
  final Function(String, String)? onLinkTap;
  final int? maxLines;
  final TextOverflow? overflow;
  final String? noteId;
  final Size defaultWebViewSize;

  const InteractiveCheckboxMarkdown({
    super.key,
    required this.originalContent,
    this.onContentChanged,
    this.style,
    this.textDirection = TextDirection.ltr,
    this.onLinkTap,
    this.maxLines,
    this.overflow,
    this.noteId,
    this.defaultWebViewSize = const Size(640, 400),
    this.hasWebViewNotifier,
    this.onFetchImage,
    this.headingAnchorRegistry,
  });

  final ValueNotifier<bool>? hasWebViewNotifier;
  final Function(String)? onFetchImage;

  /// When provided, the rendered markdown participates in GitHub-style
  /// `[text](#section)` anchor links: heading widgets register themselves into
  /// this registry and `#`-prefixed link taps scroll the matching heading
  /// into view. Owners (the screen) must `clear()` the registry on note
  /// changes; this widget never clears it.
  final HeadingAnchorRegistry? headingAnchorRegistry;

  @override
  State<InteractiveCheckboxMarkdown> createState() =>
      _InteractiveCheckboxMarkdownState();
}

class _InteractiveCheckboxMarkdownState
    extends State<InteractiveCheckboxMarkdown> {
  late String _currentContent;

  /// Preprocessed copy of [_currentContent] in which every
  /// ```synapse-app``` fenced block has been replaced with a synthetic
  /// `@[WxH](synapseresource://app/<uuid>?__blockRef=<id>)` inline embed.
  /// The actual block body is stored in [_appBlockBodies] keyed by the
  /// `<id>` so the inline dispatcher can recover it at render time without
  /// forcing large payloads through a URL query string.
  String _renderedContent = '';
  String? _preprocessedSourceCache;
  final Map<String, SynapseAppBlockBody> _appBlockBodies = {};

  /// Tracks how many times each checkbox line has been seen during the current
  /// build pass.  Reset at the start of every [build] call so that occurrence
  /// indices stay in sync with the rendered order.
  final Map<String, int> _checkboxOccurrenceCounters = {};

  int _getOccurrence(String blockText) {
    final count = _checkboxOccurrenceCounters[blockText] ?? 0;
    _checkboxOccurrenceCounters[blockText] = count + 1;
    return count;
  }

  /// Rewrites [_currentContent] into [_renderedContent], replacing every
  /// ```synapse-app``` fenced block with a synthetic inline embed that
  /// references the block body via [_appBlockBodies]. Memoises the result
  /// so repeated rebuilds with unchanged source are cheap.
  void _refreshPreprocessedContent() {
    if (_currentContent == _preprocessedSourceCache) {
      return;
    }
    _preprocessedSourceCache = _currentContent;
    _appBlockBodies.clear();

    final matches = findSynapseAppBlocks(_currentContent).toList();
    if (matches.isEmpty) {
      _renderedContent = _currentContent;
      return;
    }

    final buffer = StringBuffer();
    int cursor = 0;
    int idCounter = 0;
    for (final match in matches) {
      buffer.write(_currentContent.substring(cursor, match.startOffset));
      final body = match.body;
      if (body.isValid) {
        final refId = 'b${idCounter++}';
        _appBlockBodies[refId] = body;
        final w =
            (body.width ?? widget.defaultWebViewSize.width).toInt();
        final h =
            (body.height ?? widget.defaultWebViewSize.height).toInt();
        buffer.write(
          '@[${w}x$h](${SynapseResourceUri.scheme}://app/${Uri.encodeComponent(body.appUuid)}'
          '?$synapseAppBlockRefKey=$refId)',
        );
      } else {
        buffer.write(
          '> **Embedded app error**: '
          '${body.error ?? 'invalid synapse-app block'}',
        );
      }
      cursor = match.endOffset;
    }
    buffer.write(_currentContent.substring(cursor));
    _renderedContent = buffer.toString();
  }

  @override
  void initState() {
    super.initState();
    _currentContent = widget.originalContent;
  }

  final Map<String, Future<_LocalImageSource?>> _localImageFutures = {};
  final Map<String, Future<SynapseTempFile>> _synapseTempFutures = {};

  /// Map to track image versions and force rebuilds on edit
  final Map<String, int> _imageVersions = {};

  /// Handles synapseresource:// URIs and navigates to the appropriate screen.
  Future<void> _handleSynapseResourceLink(String url) async {
    final link = SynapseResourceUri.parse(url);
    if (link == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid resource link')));
      }
      return;
    }

    switch (link.type) {
      case SynapseResourceType.note:
        final note = await DatabaseService().getNote(link.id);
        if (note != null && mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => NoteDetailScreen(note: note),
            ),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Note not found')));
        }
      case SynapseResourceType.conversation:
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) =>
                  ConversationChatScreen(conversationId: link.id),
            ),
          );
        }
      case SynapseResourceType.attachment:
        final service = AttachmentLinkService(DatabaseService());
        final result = await service.resolveAttachmentLink(link.id);
        if (result != null && mounted) {
          final path = await result.attachment.getAbsolutePath();
          final pageStr = link.queryParameters['page'];
          final pageRaw = pageStr != null ? int.tryParse(pageStr) : null;
          // Convert 1-based page number (from URL) to 0-based index (for internal use)
          final page = pageRaw != null ? (pageRaw > 0 ? pageRaw - 1 : 0) : null;

          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => ImmersiveNoteScreen(
                notes: [result.note],
                initialAttachmentPath: path,
                initialPage: page,
              ),
            ),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Attachment not found')));
        }
      case SynapseResourceType.app:
        // App URIs are rendered inline via _AppEmbedFromUri; clicking the
        // rendered widget is not expected to route here.
        break;
    }
  }

  Future<_LocalImageSource?> _resolveLocalImageSourceCached(String url) {
    return _localImageFutures.putIfAbsent(
      url,
      () => _resolveLocalImageSource(url),
    );
  }

  Future<SynapseTempFile> _resolveSynapseTempFileCached(String url) {
    return _synapseTempFutures.putIfAbsent(
      url,
      () => SynapseTempUtils.loadFile(url),
    );
  }

  void _handleCheckboxToggle(
    String checkboxLine,
    String checkboxText,
    bool newValue,
    int occurrenceIndex,
  ) {
    final updated = applyCheckboxToggle(
      _currentContent,
      checkboxLine,
      checkboxText,
      newValue,
      occurrenceIndex: occurrenceIndex,
    );
    if (updated != _currentContent) {
      _currentContent = updated;
      widget.onContentChanged?.call(_currentContent);
      setState(() {});
    }
  }

  /// Custom latex builder that wraps individual math formulas in horizontal scroll views
  /// This handles long formulas by allowing horizontal scrolling
  Widget _customLatexBuilder(
    BuildContext context,
    String tex,
    TextStyle textStyle,
    bool inline,
  ) {
    final mathWidget = SelectableAdapter(
      selectedText: tex,
      child: Math.tex(
        tex,
        textStyle: textStyle,
        mathStyle: inline ? MathStyle.text : MathStyle.display,
        textScaleFactor: 1,
        settings: const TexParserSettings(strict: Strict.ignore),
        options: MathOptions(
          sizeUnderTextStyle: MathSize.large,
          color: widget.style?.color ?? Theme.of(context).colorScheme.onSurface,
          fontSize:
              widget.style?.fontSize ??
              Theme.of(context).textTheme.bodyMedium?.fontSize,
          mathFontOptions: FontOptions(
            fontFamily: "Main",
            fontWeight: widget.style?.fontWeight ?? FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          textFontOptions: FontOptions(
            fontFamily: "Main",
            fontWeight: widget.style?.fontWeight ?? FontWeight.normal,
            fontShape: FontStyle.normal,
          ),
          style: inline ? MathStyle.text : MathStyle.display,
        ),
        onErrorFallback: (err) {
          return Text(
            tex,
            textDirection: widget.textDirection,
            style: textStyle.copyWith(
              color: (!kDebugMode) ? null : Theme.of(context).colorScheme.error,
            ),
          );
        },
      ),
    );

    // Wrap the math widget in a horizontal scrollable container
    // This allows long formulas to scroll without affecting the rest of the content
    // Use LayoutBuilder to ensure proper constraints are provided to the child
    // This prevents layout errors when selection containers try to access widget sizes
    // The key is providing finite vertical constraints even when the parent has infinite height
    Widget result = LayoutBuilder(
      builder: (context, constraints) {
        // Provide a finite maxHeight to prevent layout issues with transforms in selection containers
        // Use a large but finite value if constraints are unbounded
        final maxHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight
            : 10000.0; // Large finite value as fallback

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.hardEdge,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: mathWidget,
          ),
        );
      },
    );

    return result;
  }

  Widget _buildGenericSynapseTempImage(
    BuildContext context,
    String url,
    double? width,
    double? height, {
    BoxFit fit = BoxFit.contain,
  }) {
    return FutureBuilder<SynapseTempFile>(
      future: _resolveSynapseTempFileCached(url),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _buildLoadingPlaceholder(width, height);
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return _buildPlaceholder(
            width,
            height,
            'Unable to load temporary image',
          );
        }

        final tempFile = snapshot.data!;
        final mime = tempFile.mimeType.toLowerCase();
        final isSvg = mime == 'image/svg+xml';

        if (isSvg) {
          // Render SVG using InAppWebView for better compatibility and edge case handling
          try {
            final svgContent = utf8.decode(tempFile.bytes);
            widget.hasWebViewNotifier?.value = true;
            return _SvgWebViewWithInfoBar(
              svgContent: svgContent,
              imageUrl: url,
              width: width,
              height: height,
              noteId: widget.noteId,
            );
          } catch (e) {
            return _buildPlaceholder(width, height, 'Failed to decode SVG');
          }
        }

        if (mime.startsWith('image/')) {
          final imageWidget = Image.memory(
            tempFile.bytes,
            key: ValueKey('\$url_\${_imageVersions[url] ?? 0}'),
            fit: fit,
            errorBuilder: (context, error, stackTrace) {
              return _buildPlaceholder(width, height, 'Failed to render image');
            },
          );
          return _wrapImageWithInfoBar(
            image: SizedBox(width: width, height: height, child: imageWidget),
            imageUrl: url,
            isSvg: false,
            onFullscreen: () {
              _FullscreenViewer.show(
                context,
                imageWidget: Image.memory(tempFile.bytes, fit: BoxFit.contain),
                title: 'Image',
              );
            },
          );
        }

        return _buildPlaceholder(
          width,
          height,
          'Unsupported image type: ${tempFile.mimeType}',
        );
      },
    );
  }

  /// Custom image builder that handles data URLs and synapsetemp:/// URIs.
  ///
  /// - synapsetemp:/// URIs load files from the app's cache directory
  /// - data: URIs are decoded and rendered from memory
  /// - all other URIs fall back to network loading
  Widget _customImageBuilder(
    BuildContext context,
    String url, {
    double? width,
    double? height,
    String? title,
    String? alt,
    Function(String)? onFetch,
  }) {
    Widget wrapWithDragTarget(Widget child) {
      return child;
    }

    // If we are in "preview mode" (indicated by maxLines being set),
    // we want to enforce a stable image height to prevent scroll jumping in lists.
    // We also use BoxFit.cover to fill the banner area nicely.
    final bool isPreview = widget.maxLines != null;
    final double? effectiveHeight = isPreview ? 200.0 : height;
    final double? effectiveWidth = isPreview ? double.infinity : width;
    final BoxFit effectiveFit = isPreview ? BoxFit.cover : BoxFit.contain;

    if (url.startsWith('data:')) {
      try {
        final uri = Uri.parse(url);
        final dataString = uri.toString();

        final commaIndex = dataString.indexOf(',');
        if (commaIndex == -1) {
          return wrapWithDragTarget(
            _buildPlaceholder(
              effectiveWidth,
              effectiveHeight,
              'Invalid data URL format',
            ),
          );
        }

        final header = dataString.substring(5, commaIndex); // Skip 'data:'
        final data = dataString.substring(commaIndex + 1);

        String mimetype = 'text/plain';
        bool isBase64 = false;

        if (header.isNotEmpty) {
          final parts = header.split(';');
          if (parts.isNotEmpty && parts[0].isNotEmpty) {
            mimetype = parts[0];
          }
          isBase64 = parts.any((p) => p.toLowerCase() == 'base64');
        }

        final isSvg = mimetype.toLowerCase() == 'image/svg+xml';
        if (isSvg) {
          // Render SVG using InAppWebView for better compatibility and edge case handling
          try {
            final svgContent = isBase64
                ? utf8.decode(base64.decode(data))
                : Uri.decodeComponent(data);
            widget.hasWebViewNotifier?.value = true;
            return wrapWithDragTarget(
              _SvgWebViewWithInfoBar(
                svgContent: svgContent,
                imageUrl: url,
                width: effectiveWidth,
                height: effectiveHeight,
                noteId: widget.noteId,
              ),
            );
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Error decoding SVG from data URL: $e');
            }
            return wrapWithDragTarget(
              _buildPlaceholder(
                effectiveWidth,
                effectiveHeight,
                'Failed to decode SVG',
              ),
            );
          }
        }

        if (mimetype.startsWith('image/')) {
          if (!isBase64) {
            return wrapWithDragTarget(
              _buildPlaceholder(
                effectiveWidth,
                effectiveHeight,
                'Only base64 encoded images are supported',
              ),
            );
          }

          final bytes = base64.decode(data);
          final imageWidget = Image.memory(
            bytes,
            key: ValueKey('${url}_${_imageVersions[url] ?? 0}'),
            fit: effectiveFit,
            errorBuilder: (context, error, stackTrace) {
              return wrapWithDragTarget(
                _buildPlaceholder(
                  effectiveWidth,
                  effectiveHeight,
                  'Failed to render image',
                ),
              );
            },
          );
          return wrapWithDragTarget(
            _wrapImageWithInfoBar(
              image: SizedBox(
                width: effectiveWidth,
                height: effectiveHeight,
                child: imageWidget,
              ),
              imageUrl: url,
              isSvg: false,
              onFullscreen: () {
                _FullscreenViewer.show(
                  context,
                  imageWidget: Image.memory(bytes, fit: BoxFit.contain),
                  title: 'Image',
                );
              },
              onFetch: onFetch != null ? () => onFetch(url) : null,
            ),
          );
        }

        return wrapWithDragTarget(
          _buildPlaceholder(
            effectiveWidth,
            effectiveHeight,
            'Unsupported image type: $mimetype',
          ),
        );
      } catch (e) {
        return wrapWithDragTarget(
          _buildPlaceholder(
            effectiveWidth,
            effectiveHeight,
            'Error loading image: $e',
          ),
        );
      }
    }

    if (widget.noteId != null &&
        (SynapseTempUtils.isSynapseTempUri(url) ||
            _isHttpUrl(url) ||
            url.startsWith('file://') ||
            url.startsWith('/') ||
            (!url.contains(':') &&
                !url.contains('/') &&
                !url.contains('\\')))) {
      return FutureBuilder<_LocalImageSource?>(
        future: _resolveLocalImageSourceCached(url),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _buildLoadingPlaceholder(effectiveWidth, effectiveHeight);
          }

          Widget buildFallback() {
            if (kDebugMode) {
              debugPrint(
                'InteractiveCheckboxMarkdown: Building fallback for $url',
              );
            }
            if (SynapseTempUtils.isSynapseTempUri(url)) {
              return _buildGenericSynapseTempImage(
                context,
                url,
                effectiveWidth,
                effectiveHeight,
                fit: effectiveFit,
              );
            }
            return _wrapImageWithInfoBar(
              image: _buildNetworkImage(
                url,
                effectiveWidth,
                effectiveHeight,
                fit: effectiveFit,
              ),
              imageUrl: url,
              isSvg: false,
              onFullscreen: () {
                _FullscreenViewer.show(
                  context,
                  imageWidget: Image.network(url, fit: BoxFit.contain),
                  title: 'Image',
                );
              },
              onFetch: onFetch != null ? () => onFetch(url) : null,
            );
          }

          if (snapshot.hasError) {
            return buildFallback();
          }

          final source = snapshot.data;
          if (source != null) {
            if (source.svgContent != null) {
              widget.hasWebViewNotifier?.value = true;
              return wrapWithDragTarget(
                _SvgWebViewWithInfoBar(
                  svgContent: source.svgContent!,
                  imageUrl: url,
                  width: effectiveWidth,
                  height: effectiveHeight,
                  noteId: widget.noteId,
                ),
              );
            }
            final imageFile = File(source.path);
            if (kDebugMode) {
              debugPrint(
                'InteractiveCheckboxMarkdown: Building local image widget for $url version ${_imageVersions[url]} (path: ${source.path})',
              );
            }

            // Use Image.file to leverage Flutter's image cache
            return wrapWithDragTarget(
              _wrapImageWithInfoBar(
                image: SizedBox(
                  width: effectiveWidth,
                  height: effectiveHeight,
                  child: Image.file(
                    imageFile,
                    key: ValueKey('${url}${_imageVersions[url] ?? 0}'),
                    fit: effectiveFit,
                    errorBuilder: (context, error, stackTrace) {
                      return wrapWithDragTarget(
                        _buildPlaceholder(
                          effectiveWidth,
                          effectiveHeight,
                          'Failed to render local image file',
                        ),
                      );
                    },
                  ),
                ),
                imageUrl: url,
                isSvg: false,
                onFullscreen: () {
                  _FullscreenViewer.show(
                    context,
                    imageWidget: Image.file(imageFile, fit: BoxFit.contain),
                    title: 'Image',
                  );
                },
              ),
            );
          }
          return buildFallback();
        },
      );
    }

    if (SynapseTempUtils.isSynapseTempUri(url)) {
      return wrapWithDragTarget(
        _buildGenericSynapseTempImage(
          context,
          url,
          effectiveWidth,
          effectiveHeight,
          fit: effectiveFit,
        ),
      );
    }

    final imageWidget = _buildNetworkImage(
      url,
      effectiveWidth,
      effectiveHeight,
      fit: effectiveFit,
    );
    return wrapWithDragTarget(
      _wrapImageWithInfoBar(
        image: SizedBox(
          width: effectiveWidth,
          height: effectiveHeight,
          child: imageWidget,
        ),
        imageUrl: url,
        isSvg: false,
        onFullscreen: () {
          _FullscreenViewer.show(
            context,
            imageWidget: Image.network(url, fit: BoxFit.contain),
            title: 'Image',
          );
        },
      ),
    );
  }

  /// Builds a placeholder widget for unsupported or error cases.
  Widget _buildPlaceholder(double? width, double? height, String message) {
    return SizedBox(
      width: width,
      height: height ?? 100,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder(double? width, double? height) {
    return SizedBox(
      width: width,
      height: height ?? 100,
      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }

  Widget _buildNetworkImage(
    String url,
    double? width,
    double? height, {
    BoxFit fit = BoxFit.contain,
  }) {
    if (url.startsWith('/') || url.startsWith('file://')) {
      return _buildPlaceholder(
        width,
        height,
        'Invalid network URL (local path used as network): \$url',
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: Image(
        key: ValueKey('${url}_${_imageVersions[url] ?? 0}'),
        image: NetworkImage(url),
        loadingBuilder:
            (
              BuildContext context,
              Widget child,
              ImageChunkEvent? loadingProgress,
            ) {
              if (loadingProgress == null) {
                return child;
              }
              return Center(
                child: CircularProgressIndicator(
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                      : null,
                ),
              );
            },
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return const Icon(Icons.broken_image, size: 48);
        },
      ),
    );
  }

  /// Wraps an image widget with an info bar
  Widget _wrapImageWithInfoBar({
    required Widget image,
    required String imageUrl,
    required bool isSvg,
    VoidCallback? onBackgroundToggle,
    VoidCallback? onFullscreen,
    VoidCallback? onFetch,
  }) {
    return FutureBuilder<_ImageSourceType>(
      future: _determineImageSourceTypeCached(imageUrl),
      builder: (context, snapshot) {
        final sourceType = snapshot.data ?? _ImageSourceType.remote;
        return _ImageWithInfoBar(
          image: image,
          sourceType: sourceType,
          isSvg: isSvg,
          onBackgroundToggle: onBackgroundToggle,
          onFullscreen: onFullscreen,
          onEdit: () async {
            if (sourceType == _ImageSourceType.remote) {
              await _handleNetworkImageEdit(imageUrl);
            } else {
              // Local handling
              File? file;
              if (SynapseTempUtils.isSynapseTempUri(imageUrl)) {
                try {
                  final synapseFile = await _resolveSynapseTempFileCached(
                    imageUrl,
                  );
                  file = synapseFile.file;
                } catch (_) {}
              } else {
                final source = await _resolveLocalImageSource(imageUrl);
                if (source != null) {
                  file = File(source.path);
                }
              }

              if (file != null && await file.exists()) {
                final editedFile = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        DrawingEditor(initialImagePath: file!.path),
                  ),
                );

                if (editedFile != null && editedFile is File) {
                  await file.writeAsBytes(
                    await editedFile.readAsBytes(),
                    flush: true,
                  );
                  if (kDebugMode) {
                    debugPrint(
                      'InteractiveCheckboxMarkdown: Overwrote local file ${file.path} with edited content (flushed)',
                    );
                  }

                  if (mounted) {
                    _localImageFutures.remove(imageUrl);
                    _synapseTempFutures.remove(imageUrl);
                    if (kDebugMode) {
                      debugPrint(
                        'InteractiveCheckboxMarkdown: Cleared futures cache for $imageUrl',
                      );
                    }

                    await FileImage(file).evict();
                    await FileImage(editedFile).evict();
                    PaintingBinding.instance.imageCache.clear();
                    PaintingBinding.instance.imageCache.clearLiveImages();

                    // Wait for navigation animation
                    await Future.delayed(const Duration(milliseconds: 350));

                    // Increment version to force keyed rebuild
                    _imageVersions[imageUrl] =
                        (_imageVersions[imageUrl] ?? 0) + 1;
                    if (kDebugMode) {
                      debugPrint(
                        'InteractiveCheckboxMarkdown: Updated version for $imageUrl to ${_imageVersions[imageUrl]}',
                      );
                    }
                    setState(() {});
                  }
                }
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cannot edit this image (file not found)'),
                    ),
                  );
                }
              }
            }
          },
          onFetch: onFetch,
        );
      },
    );
  }

  Future<void> _handleNetworkImageEdit(String imageUrl) async {
    final shouldDownload = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Network Image'),
        content: const Text(
          'To edit this image, it must be downloaded first. Do you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download & Edit'),
          ),
        ],
      ),
    );

    if (shouldDownload == true) {
      try {
        // Download
        final response = await NetworkProvider.get(Uri.parse(imageUrl));
        if (response.statusCode == 200) {
          final bytes = response.bodyBytes;
          final tempDir = await getTemporaryDirectory();
          final tempFile = File(
            '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}_edit.png',
          );
          await tempFile.writeAsBytes(bytes);

          if (!mounted) return;

          // Open Editor
          final editedFile = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) =>
                  DrawingEditor(initialImagePath: tempFile.path),
            ),
          );

          if (editedFile != null && editedFile is File) {
            // We have the edited file locally.
            // We need to update the markdown content to point to this new local file.
            // Using file:// URI Scheme
            final newUri = Uri.file(editedFile.path).toString();

            // Update Content
            if (widget.onContentChanged != null) {
              // Evict cache for the new file
              await FileImage(editedFile).evict();
              // Also evict the old URL just in case
              await NetworkImage(imageUrl).evict();

              final newContent = _currentContent.replaceAll(imageUrl, newUri);
              _currentContent = newContent;
              widget.onContentChanged!(_currentContent);
              setState(() {
                // Update version
                _imageVersions[imageUrl] = (_imageVersions[imageUrl] ?? 0) + 1;
              });
            }
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Download failed: ${response.statusCode}'),
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error downloading image: $e')),
          );
        }
      }
    }
  }

  Future<_ImageSourceType> _determineImageSourceTypeCached(String url) {
    // We can reuse the same future logic/cache mechanism or separate map
    // Since _determineImageSourceType calls _resolveLocalImageSource (which is cached),
    // we should cache this top-level result too to avoid FutureBuilder loop.
    // However, _determineImageSourceType is lightweight EXCEPT for the async part.
    // The FutureBuilder itself is the issue.
    // Let's assume we can cache it in a map.
    return _imageSourceTypeFutures.putIfAbsent(
      url,
      () => _determineImageSourceType(url),
    );
  }

  final Map<String, Future<_ImageSourceType>> _imageSourceTypeFutures = {};

  @override
  void didUpdateWidget(InteractiveCheckboxMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.originalContent != widget.originalContent) {
      _currentContent = widget.originalContent;
      // We don't strictly need to clear cache on content change as URLs are unique keys,
      // but it helps keep memory usage low if content changes completely.
      _localImageFutures.clear();
      _synapseTempFutures.clear();
      _imageSourceTypeFutures.clear();
    }
    if (oldWidget.noteId != widget.noteId) {
      _localImageFutures.clear();
      _synapseTempFutures.clear();
      _imageSourceTypeFutures.clear();
    }
  }

  Future<_LocalImageSource?> _resolveLocalImageSource(String url) async {
    if (kDebugMode) {
      debugPrint(
        'InteractiveCheckboxMarkdown: Resolving local image source for $url',
      );
    }
    if (widget.noteId == null) {
      if (kDebugMode) {
        debugPrint('InteractiveCheckboxMarkdown: noteId is null');
      }
      return null;
    }

    try {
      // Check if it's a synapsetemp URI and try to resolve via hash
      if (SynapseTempUtils.isSynapseTempUri(url)) {
        final hash = sha256.convert(utf8.encode(url)).toString();
        // We don't know the extension, so we might need to search or try common ones.
        // However, RemoteImageStorage.resolveAbsolutePath might handle this if we pass the "virtual" path?
        // No, RemoteImageStorage expects a relative path or uses its own hashing for remote URLs.

        // Let's manually check for the file in attachments dir
        final dir = await FileUtils.getPrivateStorageDirectory();
        final prefix = '${widget.noteId}_$hash';

        // List files to find the one with matching prefix
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File) {
              final name = p.basename(entity.path);
              if (name.startsWith(prefix)) {
                final extension = p.extension(name).toLowerCase();
                if (extension == '.svg') {
                  final content = await entity.readAsString();
                  return _LocalImageSource(
                    path: entity.path,
                    extension: extension,
                    svgContent: content,
                  );
                }
                return _LocalImageSource(
                  path: entity.path,
                  extension: extension,
                );
              }
            }
          }
        }
      }

      // Check if it's a simple filename (local attachment)
      // No scheme (contains ':'), no path separators
      if (!url.contains(':') && !url.contains('/') && !url.contains('\\')) {
        final dir = await FileUtils.getPrivateStorageDirectory();
        final filePath = p.join(dir.path, url);
        final file = File(filePath);

        if (await file.exists()) {
          final extension = p.extension(filePath).toLowerCase();
          if (extension == '.svg') {
            final content = await file.readAsString();
            return _LocalImageSource(
              path: filePath,
              extension: extension,
              svgContent: content,
            );
          }
          return _LocalImageSource(path: filePath, extension: extension);
        }
      }

      // Handle absolute paths and file:// URIs (e.g. for testing)
      if (url.startsWith('file://') || url.startsWith('/')) {
        final filePath = url.startsWith('file://')
            ? Uri.parse(url).toFilePath()
            : url;
        final file = File(filePath);
        if (await file.exists()) {
          final extension = p.extension(filePath).toLowerCase();
          if (extension == '.svg') {
            final content = await file.readAsString();
            return _LocalImageSource(
              path: filePath,
              extension: extension,
              svgContent: content,
            );
          }
          return _LocalImageSource(path: filePath, extension: extension);
        }
      }

      final absolutePath = await RemoteImageStorage.resolveAbsolutePath(
        noteId: widget.noteId!,
        imageUrl: url,
      );
      if (absolutePath == null) {
        return null;
      }
      final file = File(absolutePath);
      if (!await file.exists()) {
        return null;
      }
      final extension = p.extension(absolutePath).toLowerCase();
      if (extension == '.svg') {
        final content = await file.readAsString();
        return _LocalImageSource(
          path: absolutePath,
          extension: extension,
          svgContent: content,
        );
      }
      return _LocalImageSource(path: absolutePath, extension: extension);
    } catch (_) {
      return null;
    }
  }

  bool _isHttpUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  /// Determines if an image URL represents a local or remote source
  Future<_ImageSourceType> _determineImageSourceType(String url) async {
    // SynapseTemp URIs are always local
    if (SynapseTempUtils.isSynapseTempUri(url)) {
      return _ImageSourceType.local;
    }

    // Data URIs are considered local (embedded)
    if (url.startsWith('data:')) {
      return _ImageSourceType.local;
    }

    // For HTTP URLs, check if they resolve to local files
    if (widget.noteId != null && _isHttpUrl(url)) {
      final source = await _resolveLocalImageSource(url);
      if (source != null) {
        return _ImageSourceType.local;
      }
      return _ImageSourceType.remote;
    }

    // Default to remote for HTTP URLs, local for others
    return _isHttpUrl(url) ? _ImageSourceType.remote : _ImageSourceType.local;
  }

  Widget _buildCodeBlock(
    BuildContext context,
    String name,
    String code,
    bool closed,
  ) {
    return _HighlightedCodeBlock(
      code: code,
      languageHint: name,
      textStyle: widget.style,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Reset occurrence counters so they match the order of rendered checkboxes.
    _checkboxOccurrenceCounters.clear();

    // When this widget owns the heading-anchor registry (immersive path),
    // clear it before rebuild so DragTargetSafeHTag re-registers each heading
    // in document order with deterministic duplicate suffixes. The registry
    // is only passed in when the caller hosts a single InteractiveCheckboxMarkdown
    // for the entire document (BlockMarkdownBody does not pass one — it owns
    // registration at parse time).
    widget.headingAnchorRegistry?.clear();

    _refreshPreprocessedContent();

    // Basic inline components
    final inlineComponents = [
      CustomImageMd(
        onImage: (url, alt) {
          return _customImageBuilder(
            context,
            url,
            alt: alt,
            onFetch: (url) async {
              await widget.onFetchImage?.call(url);
              if (mounted) {
                // Invalidate caches so the image source type is re-evaluated
                _imageSourceTypeFutures.remove(url);
                _localImageFutures.remove(url);
                setState(() {
                  // Force rebuild of specific image key if needed, or just setState
                  // Update version to force new key for image widget
                  _imageVersions[url] = (_imageVersions[url] ?? 0) + 1;
                });
              }
            },
          );
        },
      ),
      CustomATagMd(),
      _EmbeddedWebViewMd(
        defaultSize: widget.defaultWebViewSize,
        noteId: widget.noteId,
        hasWebViewNotifier: widget.hasWebViewNotifier,
        appBlockLookup: (id) => _appBlockBodies[id],
      ),
      if (widget.onLinkTap != null || widget.noteId != null)
        // Helper to ensure links are handled if needed, usually default ATag is fine
        // but we used DragTargetATagMd before. Standard ATagMd should be enough.
        // If we need custom link handling (like avoiding ! prefixes),
        // GptMarkdown handles that.
        // We'll use the standard ones implicitly by NOT passing them in 'inlineComponents'
        // except for the custom one.
        ...MarkdownComponent.inlineComponents.where((e) => e is! ATagMd),
    ];

    // Check if we need to add standard ATagMd back if we excluded it?
    // Wait, GptMarkdown adds inlineComponents on top of defaults?
    // No, 'inlineComponents' argument to GptMarkdown REPLACES the list or APPENDS?
    // Docs say: "inlineComponents: A list of custom inline components"
    // Usually it appends or overrides if types match.
    // Let's assume we can just pass our custom ones.

    final components = [
      CodeBlockMd(),
      NewLines(),
      if (widget.onContentChanged != null)
        InteractiveCheckboxMd(
          getOccurrence: _getOccurrence,
          onToggle: _handleCheckboxToggle,
        )
      else
        CheckBoxMd(),
      HrLine(),
      UnOrderedList(),
      OrderedList(),
      BlockQuote(),
      TableMd(),
      IndentMd(),
      SafeHTag(), // Using SafeHTag from interactive_checkbox_component
      LatexMathMultiLine(),
      LatexBracketBlockMd(),
    ];

    final markdown = GptMarkdown(
      _renderedContent,
      style: widget.style,
      textDirection: widget.textDirection,
      onLinkTap: (url, text) {
        // GitHub-style intra-document anchor: `[text](#section)`.
        if (url.startsWith('#') && widget.headingAnchorRegistry != null) {
          // Fire-and-forget; gpt_markdown's onLinkTap is sync.
          widget.headingAnchorRegistry!.scrollToSection(url.substring(1));
          return;
        }
        // Handle synapseresource:// URIs internally
        if (SynapseResourceUri.isSynapseResourceUri(url)) {
          _handleSynapseResourceLink(url);
          return;
        }
        // Fall back to parent callback
        widget.onLinkTap?.call(url, text);
      },
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      latexBuilder: _customLatexBuilder,
      imageBuilder: (context, url, {alt, height, title, width}) {
        return _customImageBuilder(
          context,
          url,
          width: width,
          height: height,
          title: title,
          alt: alt,
          onFetch: (url) async {
            await widget.onFetchImage?.call(url);
            if (mounted) {
              // Invalidate caches so the image source type is re-evaluated
              _imageSourceTypeFutures.remove(url);
              _localImageFutures.remove(url);
              setState(() {
                // Force rebuild of specific image key if needed, or just setState
                // Update version to force new key for image widget
                _imageVersions[url] = (_imageVersions[url] ?? 0) + 1;
              });
            }
          },
        );
      },
      codeBuilder: _buildCodeBlock,
      tableBuilder: _buildConstrainedTable,
      components: components,
      inlineComponents: inlineComponents,
      useDollarSignsForLatex: true,
    );

    // When a registry is supplied, expose it to descendants so heading
    // components can register themselves. We avoid installing the scope
    // otherwise — block-level callers (BlockMarkdownBody) own registration
    // at parse time and don't want headings to self-register.
    final Widget child = widget.headingAnchorRegistry != null
        ? HeadingAnchorScope(
            registry: widget.headingAnchorRegistry!,
            child: markdown,
          )
        : markdown;

    return KeyedSubtree(
      key: ValueKey('md_${_imageVersions.values.join()}'),
      child: child,
    );
  }

  /// Custom table builder that caps total table width at ~1.5x the screen
  /// width and allows text in each cell to wrap instead of growing the
  /// table unboundedly. Horizontal scroll is still available up to the cap.
  Widget _buildConstrainedTable(
    BuildContext context,
    List<CustomTableRow> tableRows,
    TextStyle textStyle,
    GptMarkdownConfig config,
  ) {
    final screenWidth = MediaQuery.of(context).size.width;
    final maxTableWidth = screenWidth * 1.5;
    final perColumnCap = screenWidth * 0.6;
    final controller = ScrollController();

    final colCount = tableRows
        .map((r) => r.fields.length)
        .fold<int>(0, (a, b) => a > b ? a : b);

    final headerColor = Theme.of(context).colorScheme.surfaceContainerHighest;
    final borderColor = Theme.of(context).colorScheme.onSurface;

    final rows = tableRows.map<TableRow>((row) {
      final fields = row.fields;
      return TableRow(
        decoration: row.isHeader ? BoxDecoration(color: headerColor) : null,
        children: List.generate(colCount, (index) {
          final field = index < fields.length ? fields[index] : null;
          final data = field?.data.trim() ?? '';

          Widget content = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: GptMarkdown(
              data,
              style: textStyle,
              textDirection: config.textDirection,
              onLinkTap: config.onLinkTap,
              latexBuilder: _customLatexBuilder,
              imageBuilder: (context, url, {alt, height, title, width}) {
                return _customImageBuilder(
                  context,
                  url,
                  width: width,
                  height: height,
                  title: title,
                  alt: alt,
                );
              },
              codeBuilder: _buildCodeBlock,
              useDollarSignsForLatex: true,
            ),
          );

          switch (field?.alignment) {
            case TextAlign.center:
              content = Center(child: content);
              break;
            case TextAlign.right:
              content = Align(
                alignment: Alignment.centerRight,
                child: content,
              );
              break;
            case TextAlign.left:
            default:
              content = Align(
                alignment: Alignment.centerLeft,
                child: content,
              );
              break;
          }

          return content;
        }),
      );
    }).toList();

    return Scrollbar(
      controller: controller,
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxTableWidth),
          child: Table(
            textDirection: config.textDirection,
            defaultColumnWidth: MinColumnWidth(
              const IntrinsicColumnWidth(),
              FixedColumnWidth(perColumnCap),
            ),
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder.all(width: 1, color: borderColor),
            children: rows,
          ),
        ),
      ),
    );
  }
}

/// Markdown inline component that renders custom WebView embed syntax.
class _EmbeddedWebViewMd extends InlineMd {
  _EmbeddedWebViewMd({
    required this.defaultSize,
    this.noteId,
    this.hasWebViewNotifier,
    this.appBlockLookup,
  });

  final Size defaultSize;
  final String? noteId;
  final ValueNotifier<bool>? hasWebViewNotifier;

  /// Resolves a fenced-block reference id (the `__blockRef` URI query value)
  /// to its parsed body. Injected by the host widget so inline URI
  /// dispatch can pull parameters that don't fit in a URI query.
  final SynapseAppBlockBody? Function(String blockRefId)? appBlockLookup;

  @override
  RegExp get exp => RegExp(r"@\[[^\[\]]*\]\([^\s]*\)");

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final trimmed = text.trim();
    final basicMatch = RegExp(r'@\[(.*?)\]\(').firstMatch(trimmed);
    if (basicMatch == null) {
      return const TextSpan();
    }

    final sizeSpec = basicMatch.group(1) ?? '';
    final urlStart = basicMatch.end;
    final urlEnd = _findUrlEnd(trimmed, urlStart);
    if (urlEnd <= urlStart) {
      return const TextSpan();
    }

    final url = trimmed.substring(urlStart, urlEnd).trim();
    if (url.isEmpty) {
      return const TextSpan();
    }

    final parsedSize = _WebViewSizeSpec.parse(sizeSpec);
    final resolvedWidth = _sanitizeDimension(
      parsedSize.width ?? defaultSize.width,
      defaultSize.width,
    );
    final resolvedHeight = _sanitizeDimension(
      parsedSize.height ?? defaultSize.height,
      defaultSize.height,
    );

    if (isSynapseAppUri(url)) {
      hasWebViewNotifier?.value = true;
      return WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectionContainer.disabled(
            child: _AppEmbedFromUri(
              url: url,
              width: resolvedWidth,
              height: resolvedHeight,
              parentNoteId: noteId,
              appBlockLookup: appBlockLookup,
              defaultSize: defaultSize,
            ),
          ),
        ),
      );
    }

    hasWebViewNotifier?.value = true;

    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectionContainer.disabled(
          child: _MarkdownEmbeddedWebView(
            url: url,
            width: resolvedWidth,
            height: resolvedHeight,
            backgroundColor: Theme.of(context).colorScheme.surface,
            noteId: noteId,
          ),
        ),
      ),
    );
  }

  int _findUrlEnd(String text, int startIndex) {
    int parenDepth = 0;
    for (int i = startIndex; i < text.length; i++) {
      if (text[i] == '(') {
        parenDepth++;
      } else if (text[i] == ')') {
        if (parenDepth == 0) return i;
        parenDepth--;
      } else if (text[i] == ' ' && parenDepth == 0) {
        // Stop at space if not inside parens (though URL usually doesn't have spaces unless encoded)
        // Standard markdown allows title after URL in quotes, but here we just want the URL
        return i;
      }
    }
    return -1;
  }
}

class _MarkdownEmbeddedWebView extends StatefulWidget {
  const _MarkdownEmbeddedWebView({
    required this.url,
    required this.width,
    required this.height,
    required this.backgroundColor,
    this.noteId,
  });

  final String url;
  final double width;
  final double height;
  final Color backgroundColor;
  final String? noteId;

  @override
  State<_MarkdownEmbeddedWebView> createState() =>
      _MarkdownEmbeddedWebViewState();
}

class _MarkdownEmbeddedWebViewState extends State<_MarkdownEmbeddedWebView> {
  late Future<_WebViewContent> _contentFuture;

  @override
  void initState() {
    super.initState();
    _contentFuture = _resolveContent();
  }

  @override
  void didUpdateWidget(covariant _MarkdownEmbeddedWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.backgroundColor != widget.backgroundColor) {
      setState(() {
        _contentFuture = _resolveContent();
      });
    }
  }

  Future<_WebViewContent> _resolveContent() async {
    final targetUrl = widget.url.trim();
    if (SynapseTempUtils.isSynapseTempUri(targetUrl)) {
      try {
        Uint8List bytes;
        String mime;

        try {
          final tempFile = await SynapseTempUtils.loadFile(targetUrl);
          bytes = tempFile.bytes;
          mime = tempFile.mimeType.toLowerCase();
        } catch (e) {
          // If temp file load fails, try to find it in attachments using SHA256 hash
          File? fallbackFile;
          if (widget.noteId != null) {
            final hash = sha256.convert(utf8.encode(targetUrl)).toString();
            final dir = await FileUtils.getPrivateStorageDirectory();
            final prefix = '${widget.noteId}_$hash';

            if (await dir.exists()) {
              await for (final entity in dir.list()) {
                if (entity is File &&
                    p.basename(entity.path).startsWith(prefix)) {
                  fallbackFile = entity;
                  break;
                }
              }
            }
          }

          if (fallbackFile == null) rethrow;

          bytes = await fallbackFile.readAsBytes();
          mime = (await FileTypeUtils.getMimeTypeForFile(
            fallbackFile.path,
          )).toLowerCase();
        }

        final decoded = utf8.decode(bytes, allowMalformed: true);
        if (mime.contains('html') || mime.contains('xml')) {
          // Wrap HTML/XML in sandboxed iframe
          final contentDataUrl =
              'data:$mime;charset=utf-8,' + Uri.encodeComponent(decoded);
          final wrappedHtml =
              '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    html, body { margin: 0; padding: 0; height: 100%; width: 100%; background: ${_colorToCss(widget.backgroundColor)}; }
    iframe { border: 0; width: 100%; height: 100%; }
  </style>
</head>
<body>
  <iframe src="$contentDataUrl" sandbox="allow-scripts allow-same-origin"></iframe>
</body>
</html>
''';
          return _WebViewContent(
            data: wrappedHtml,
            mimeType: 'text/html',
            encoding: 'utf8',
          );
        }
        final escaped = const HtmlEscape().convert(decoded);
        final html =
            '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body {
    margin: 0;
    padding: 16px;
    font-family: monospace;
    background: ${_colorToCss(widget.backgroundColor)};
    white-space: pre-wrap;
    word-break: break-word;
  }
</style>
</head>
<body>$escaped</body>
</html>
''';
        return _WebViewContent(
          data: html,
          mimeType: 'text/html',
          encoding: 'utf8',
        );
      } catch (e) {
        if (kDebugMode) {
          debugPrint('Embedded markdown webview failed to load: $e');
        }
        return const _WebViewContent.error('Unable to load embedded content');
      }
    }

    if (!_looksLikeHttpUrl(targetUrl)) {
      return const _WebViewContent.error('Unsupported URL');
    }

    final html = _buildIframeHtml(targetUrl, widget.backgroundColor);
    return _WebViewContent(data: html, mimeType: 'text/html', encoding: 'utf8');
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = Theme.of(context).colorScheme.outlineVariant;
    final fadedBorderColor = borderColor.withValues(
      alpha: (borderColor.a * 0.6).clamp(0.0, 1.0),
    );

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fadedBorderColor),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: FutureBuilder<_WebViewContent>(
            future: _contentFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              }

              if (snapshot.hasError) {
                return _EmbeddedWebViewError(message: 'Failed to load view');
              }

              final content = snapshot.data;
              if (content == null || content.hasError) {
                return _EmbeddedWebViewError(
                  message: content?.errorMessage ?? 'Unable to load content',
                );
              }

              return _buildWebView(content);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildWebView(_WebViewContent content) {
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) {},
          onHorizontalDragStart: (_) {},
          child: InAppWebView(
            initialData: InAppWebViewInitialData(
              data: content.data,
              mimeType: content.mimeType,
              encoding: content.encoding,
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              supportZoom: true,
              transparentBackground: true,
              disableHorizontalScroll: false,
              disableVerticalScroll: false,
              allowsInlineMediaPlayback: true,
              resourceCustomSchemes: const [SynapseTempUtils.scheme],
              useHybridComposition: true,
            ),
            gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
              Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
            },
            onLoadResourceWithCustomScheme: (controller, request) async {
              final scheme = request.url.scheme.toLowerCase();
              if (scheme == SynapseTempUtils.scheme) {
                try {
                  final file = await SynapseTempUtils.loadFile(
                    request.url.toString(),
                  );
                  return CustomSchemeResponse(
                    data: file.bytes,
                    contentType: file.mimeType,
                  );
                } catch (e) {
                  if (kDebugMode) {
                    debugPrint('Embedded webview resource error: $e');
                  }
                }
              }
              return null;
            },
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                _FullscreenViewer.show(
                  context,
                  htmlContent: content.data,
                  htmlMimeType: content.mimeType,
                  htmlEncoding: content.encoding,
                  title: 'Web View',
                );
              },
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.fullscreen,
                  size: 16,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmbeddedWebViewError extends StatelessWidget {
  const _EmbeddedWebViewError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceVariant,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _WebViewContent {
  const _WebViewContent({
    required this.data,
    this.mimeType = 'text/html',
    this.encoding = 'utf8',
  }) : errorMessage = null;

  const _WebViewContent.error(this.errorMessage)
    : data = '',
      mimeType = 'text/html',
      encoding = 'utf8';

  final String data;
  final String mimeType;
  final String encoding;
  final String? errorMessage;

  bool get hasError => errorMessage != null;
}

class _WebViewSizeSpec {
  const _WebViewSizeSpec({this.width, this.height});

  final double? width;
  final double? height;

  static _WebViewSizeSpec parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const _WebViewSizeSpec();
    }

    final sizeMatch = RegExp(
      r'^(\d+)?\s*x\s*(\d+)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (sizeMatch != null) {
      final widthValue = sizeMatch.group(1);
      final heightValue = sizeMatch.group(2);
      return _WebViewSizeSpec(
        width: widthValue != null ? double.tryParse(widthValue) : null,
        height: heightValue != null ? double.tryParse(heightValue) : null,
      );
    }

    final numeric = double.tryParse(trimmed);
    if (numeric != null) {
      return _WebViewSizeSpec(width: numeric);
    }

    return const _WebViewSizeSpec();
  }
}

double _sanitizeDimension(double? value, double fallback) {
  if (value == null) {
    return fallback;
  }
  if (!value.isFinite || value <= 0) {
    return fallback;
  }
  return value;
}

String _buildIframeHtml(String url, Color backgroundColor) {
  final escapedUrl = const HtmlEscape().convert(url);
  final bgColor = _colorToCss(backgroundColor);
  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  html, body {
    margin: 0;
    padding: 0;
    height: 100%;
    width: 100%;
    background: $bgColor;
  }
  iframe {
    border: 0;
    width: 100%;
    height: 100%;
  }
</style>
</head>
<body>
  <iframe
    src="$escapedUrl"
    sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
    loading="lazy"
    allow="encrypted-media;web-share"
    referrerpolicy="strict-origin-when-cross-origin"
    allowfullscreen>
  </iframe>
</body>
</html>
''';
}

String _colorToCss(Color color) {
  final double alpha = color.a.clamp(0.0, 1.0).toDouble();
  final red = (color.r.clamp(0.0, 1.0).toDouble() * 255).round();
  final green = (color.g.clamp(0.0, 1.0).toDouble() * 255).round();
  final blue = (color.b.clamp(0.0, 1.0).toDouble() * 255).round();
  return 'rgba($red, $green, $blue, ${alpha.toStringAsFixed(3)})';
}

bool _looksLikeHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme.isEmpty) {
    return false;
  }
  final scheme = uri.scheme.toLowerCase();
  return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty;
}

/// Stateful widget for SVG WebView with dark/light background toggle
class _SvgWebViewWidget extends StatefulWidget {
  const _SvgWebViewWidget({
    super.key,
    required this.svgContent,
    this.width,
    this.height,
  });

  final String svgContent;
  final double? width;
  final double? height;

  @override
  State<_SvgWebViewWidget> createState() => _SvgWebViewWidgetState();
}

class _SvgWebViewWidgetState extends State<_SvgWebViewWidget> {
  bool _isDarkBackground = false;
  InAppWebViewController? _webViewController;

  void toggleBackground() {
    setState(() {
      _isDarkBackground = !_isDarkBackground;
    });
    _updateBackgroundColor();
  }

  void _updateBackgroundColor() {
    if (_webViewController == null) return;
    final backgroundColor = _isDarkBackground ? '#1e1e1e' : '#ffffff';
    _webViewController!.evaluateJavascript(
      source:
          '''
      (function() {
        const iframe = document.querySelector('iframe');
        if (iframe && iframe.contentWindow) {
          try {
            iframe.contentWindow.postMessage({type: 'setBackground', color: '$backgroundColor'}, '*');
          } catch (e) {
            console.log('Cannot set background:', e);
          }
        }
      })();
    ''',
    );
  }

  /// Parse SVG content to extract aspect ratio from viewBox or width/height attributes
  double? _parseSvgAspectRatio(String svgContent) {
    // Try to parse viewBox first: viewBox="minX minY width height"
    final viewBoxMatch = RegExp(
      r'viewBox\s*=\s*["\x27]([^"\x27]+)["\x27]',
      caseSensitive: false,
    ).firstMatch(svgContent);
    if (viewBoxMatch != null) {
      final parts = viewBoxMatch.group(1)!.trim().split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        final width = double.tryParse(parts[2]);
        final height = double.tryParse(parts[3]);
        if (width != null && height != null && width > 0 && height > 0) {
          return height / width;
        }
      }
    }

    // Fall back to width/height attributes
    final widthMatch = RegExp(
      r'<svg[^>]*\swidth\s*=\s*["\x27]?([\d.]+)',
      caseSensitive: false,
    ).firstMatch(svgContent);
    final heightMatch = RegExp(
      r'<svg[^>]*\sheight\s*=\s*["\x27]?([\d.]+)',
      caseSensitive: false,
    ).firstMatch(svgContent);

    if (widthMatch != null && heightMatch != null) {
      final width = double.tryParse(widthMatch.group(1)!);
      final height = double.tryParse(heightMatch.group(1)!);
      if (width != null && height != null && width > 0 && height > 0) {
        return height / width;
      }
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    // If explicit height is provided (e.g., preview mode), use it without LayoutBuilder
    if (widget.height != null) {
      return _buildWebView(widget.width, widget.height!);
    }

    // Use LayoutBuilder to get actual available width and calculate height
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.width ?? 400.0;

        // Parse SVG to get aspect ratio
        final aspectRatio = _parseSvgAspectRatio(widget.svgContent);

        // Calculate height: if we have aspect ratio, use it; otherwise default to 0.75
        // Cap height at 500px for non-preview mode
        final double calculatedHeight;
        if (aspectRatio != null) {
          calculatedHeight = (availableWidth * aspectRatio).clamp(100.0, 500.0);
        } else {
          // Default aspect ratio of 0.75 (4:3)
          calculatedHeight = (availableWidth * 0.75).clamp(100.0, 500.0);
        }

        return _buildWebView(
          constraints.maxWidth.isFinite ? null : widget.width,
          calculatedHeight,
        );
      },
    );
  }

  Widget _buildWebView(double? width, double height) {
    final htmlContent = _createSvgHtmlWrapper(
      widget.svgContent,
      isDarkBackground: _isDarkBackground,
    );

    return SelectionContainer.disabled(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) {},
        onHorizontalDragStart: (_) {},
        child: SizedBox(
          width: width,
          height: height,
          child: InAppWebView(
            initialData: InAppWebViewInitialData(
              data: htmlContent,
              mimeType: 'text/html',
              encoding: 'utf8',
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              supportZoom: true,
              transparentBackground: true,
              disableContextMenu: false,
              horizontalScrollBarEnabled: false,
              verticalScrollBarEnabled: false,
              resourceCustomSchemes: ['synapse'],
              useHybridComposition: true,
              disableVerticalScroll: false,
              disableHorizontalScroll: false,
            ),
            gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
              Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
            },
            onWebViewCreated: (controller) {
              _webViewController = controller;
            },
            onLoadStop: (controller, url) {
              _webViewController = controller;
            },
            onLoadResourceWithCustomScheme: (controller, request) async {
              if (request.url.scheme.toLowerCase() == 'synapse') {
                final data = await rootBundle.loadString(
                  "assets/scripts/${request.url.host}",
                );
                return CustomSchemeResponse(
                  contentType: 'application/javascript',
                  data: Uint8List.fromList(utf8.encode(data)),
                );
              }
              return null;
            },
          ),
        ),
      ),
    );
  }

  String _createSvgHtmlWrapper(
    String svgContent, {
    bool isDarkBackground = false,
  }) {
    final backgroundColor = isDarkBackground ? '#1e1e1e' : '#ffffff';
    // Create sandboxed iframe with SVG content
    // CSS updated to make SVG fill width while maintaining aspect ratio
    final svgDataUrl =
        'data:text/html;charset=utf-8,' +
        Uri.encodeComponent('''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; overflow: hidden; background-color: $backgroundColor; }
    body { display: flex; align-items: center; justify-content: center; }
    #svg-container { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
    svg { width: 100%; height: auto; max-height: 100%; display: block; }
  </style>
  <script src="synapse://svg.pan-zoom.min.js"></script>
</head>
<body>
  <div id="svg-container">$svgContent</div>
  <script>
    window.addEventListener('message', function(e) {
      if (e.data.type === 'setBackground') {
        document.body.style.backgroundColor = e.data.color;
        document.documentElement.style.backgroundColor = e.data.color;
      }
    });
    document.addEventListener('DOMContentLoaded', function() {
      const svgElement = document.querySelector('svg');
      if (svgElement && typeof svgPanZoom !== 'undefined') {
        svgPanZoom(svgElement, {
          zoomEnabled: true,
          controlIconsEnabled: false,
          fit: true,
          center: true,
          minZoom: 0.1,
          maxZoom: 15,
          zoomScaleSensitivity: 0.3,
          dblClickZoomEnabled: true,
          mouseWheelZoomEnabled: true,
          preventMouseEventsDefault: true,
        });
      }
    });
  </script>
</body>
</html>
''');

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    html, body { margin: 0; padding: 0; height: 100%; width: 100%; background: $backgroundColor; }
    iframe { border: 0; width: 100%; height: 100%; }
  </style>
</head>
<body>
  <iframe src="$svgDataUrl" sandbox="allow-scripts allow-same-origin"></iframe>
</body>
</html>
''';
  }
}

/// Widget that wraps SVG WebView with info bar
class _SvgWebViewWithInfoBar extends StatefulWidget {
  const _SvgWebViewWithInfoBar({
    required this.svgContent,
    required this.imageUrl,
    this.width,
    this.height,
    this.noteId,
  });

  final String svgContent;
  final String imageUrl;
  final double? width;
  final double? height;
  final String? noteId;

  @override
  State<_SvgWebViewWithInfoBar> createState() => _SvgWebViewWithInfoBarState();
}

class _SvgWebViewWithInfoBarState extends State<_SvgWebViewWithInfoBar> {
  final GlobalKey<_SvgWebViewWidgetState> _svgWebViewKey = GlobalKey();

  Future<_ImageSourceType> _determineImageSourceType(String url) async {
    // SynapseTemp URIs are always local
    if (SynapseTempUtils.isSynapseTempUri(url)) {
      return _ImageSourceType.local;
    }

    // Data URIs are considered local (embedded)
    if (url.startsWith('data:')) {
      return _ImageSourceType.local;
    }

    // For HTTP URLs, check if they resolve to local files
    if (widget.noteId != null && _isHttpUrl(url)) {
      final source = await _resolveLocalImageSource(url);
      if (source != null) {
        return _ImageSourceType.local;
      }
      return _ImageSourceType.remote;
    }

    // Default to remote for HTTP URLs, local for others
    return _isHttpUrl(url) ? _ImageSourceType.remote : _ImageSourceType.local;
  }

  bool _isHttpUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }

  Future<_LocalImageSource?> _resolveLocalImageSource(String url) async {
    if (widget.noteId == null) {
      return null;
    }

    try {
      final absolutePath = await RemoteImageStorage.resolveAbsolutePath(
        noteId: widget.noteId!,
        imageUrl: url,
      );
      if (absolutePath == null) {
        return null;
      }
      final file = File(absolutePath);
      if (!await file.exists()) {
        return null;
      }
      final extension = p.extension(absolutePath).toLowerCase();
      if (extension == '.svg') {
        final content = await file.readAsString();
        return _LocalImageSource(
          path: absolutePath,
          extension: extension,
          svgContent: content,
        );
      }
      return _LocalImageSource(path: absolutePath, extension: extension);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ImageSourceType>(
      future: _determineImageSourceType(widget.imageUrl),
      builder: (context, snapshot) {
        final sourceType = snapshot.data ?? _ImageSourceType.remote;
        // Note: We don't use IntrinsicWidth here because LayoutBuilder
        // (used inside _SvgWebViewWidget) doesn't support intrinsic dimensions.
        // Since we want SVG to span full width anyway, Column with stretch is correct.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                topRight: Radius.circular(4),
              ),
              child: _SvgWebViewWidget(
                key: _svgWebViewKey,
                svgContent: widget.svgContent,
                width: widget.width,
                height: widget.height,
              ),
            ),
            _ImageInfoBar(
              sourceType: sourceType,
              isSvg: true,
              onBackgroundToggle: () {
                _svgWebViewKey.currentState?.toggleBackground();
              },
              onFullscreen: () {
                _FullscreenViewer.show(
                  context,
                  svgContent: widget.svgContent,
                  title: 'SVG',
                );
              },
              onEdit: null, // Hide edit button for SVGs
            ),
          ],
        );
      },
    );
  }
}

/// Thin info bar widget showing image source type and SVG controls
class _ImageInfoBar extends StatelessWidget {
  const _ImageInfoBar({
    required this.sourceType,
    required this.isSvg,
    this.onBackgroundToggle,
    this.onFullscreen,
    this.onEdit,
    this.onFetch,
  });

  final _ImageSourceType sourceType;
  final bool isSvg;
  final VoidCallback? onBackgroundToggle;
  final VoidCallback? onFullscreen;
  final VoidCallback? onEdit;
  final VoidCallback? onFetch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return SelectionContainer.disabled(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isDark
              ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.2)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Row(
          // Remove mainAxisSize: MainAxisSize.min to allow Spacer to work
          children: [
            if (sourceType == _ImageSourceType.remote && onFetch != null)
              GestureDetector(
                onTap: onFetch,
                child: Icon(
                  Icons.cloud_download,
                  size: 22,
                  color: colorScheme
                      .primary, // Use primary color to indicate action
                ),
              )
            else
              Icon(
                sourceType == _ImageSourceType.local
                    ? Icons.storage
                    : Icons
                          .cloud_off, // Use cloud_off to indicate not fetched/offline
                size: 22,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            if (onBackgroundToggle != null) ...[
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onBackgroundToggle,
                child: Icon(
                  Icons.contrast,
                  size: 22,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            ],
            if (onFullscreen != null) ...[
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onFullscreen,
                child: Icon(
                  Icons.fullscreen,
                  size: 22,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            ],
            const Spacer(),
            if (onEdit != null) ...[
              const SizedBox(width: 12),
              GestureDetector(
                onTap: onEdit,
                child: Icon(
                  Icons.edit,
                  size: 20,
                  color: colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.8,
                  ), // Slightly more opaque for visibility
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ImageWithInfoBar extends StatefulWidget {
  const _ImageWithInfoBar({
    required this.image,
    required this.sourceType,
    required this.isSvg,
    this.onBackgroundToggle,
    this.onFullscreen,
    this.onEdit,
    this.onFetch,
  });

  final Widget image;
  final _ImageSourceType sourceType;
  final bool isSvg;
  final VoidCallback? onBackgroundToggle;
  final VoidCallback? onFullscreen;
  final VoidCallback? onEdit;
  final VoidCallback? onFetch;

  @override
  State<_ImageWithInfoBar> createState() => _ImageWithInfoBarState();
}

class _ImageWithInfoBarState extends State<_ImageWithInfoBar> {
  bool _isDarkBackground = false;

  @override
  Widget build(BuildContext context) {
    // If it's SVG, the background toggle is handled by the SVG widget itself (via onBackgroundToggle callback)
    // If it's a regular image, we handle the background here if onBackgroundToggle is NOT provided by the parent
    // But wait, for regular images, we want to provide the toggle functionality HERE.
    // The previous implementation for SVG had onSvgBackgroundToggle passed down.
    // For regular images, we want to introduce this functionality.

    final showLocalToggle = !widget.isSvg;

    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(4),
            ),
            child: Container(
              color: showLocalToggle
                  ? (_isDarkBackground
                        ? const Color(0xFF1E1E1E)
                        : const Color(0xFFFFFFFF))
                  : null,
              child: widget.image,
            ),
          ),
          _ImageInfoBar(
            sourceType: widget.sourceType,
            isSvg: widget.isSvg,
            onBackgroundToggle:
                widget.onBackgroundToggle ??
                (showLocalToggle
                    ? () {
                        setState(() {
                          _isDarkBackground = !_isDarkBackground;
                        });
                      }
                    : null),
            onFullscreen: widget.onFullscreen,
            onEdit: widget.onEdit,
            onFetch: widget.onFetch,
          ),
        ],
      ),
    );
  }
}

class _LocalImageSource {
  const _LocalImageSource({
    required this.path,
    required this.extension,
    this.svgContent,
  });

  final String path;
  final String extension;
  final String? svgContent;
}

class _HighlightedCodeBlock extends StatefulWidget {
  const _HighlightedCodeBlock({
    required this.code,
    required this.languageHint,
    this.textStyle,
  });

  final String code;
  final String languageHint;
  final TextStyle? textStyle;

  @override
  State<_HighlightedCodeBlock> createState() => _HighlightedCodeBlockState();
}

class _HighlightedCodeBlockState extends State<_HighlightedCodeBlock> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final Map<String, TextStyle> themeMap = isDark
        ? atomOneDarkTheme
        : atomOneLightTheme;
    final TextStyle baseStyle = _buildBaseStyle(context);
    final int styleSignature = _styleSignature(baseStyle);

    final _HighlightResult highlightResult = _CodeHighlightEngine.instance
        .highlight(
          code: widget.code,
          languageHint: widget.languageHint,
          baseStyle: baseStyle,
          theme: themeMap,
          isDarkTheme: isDark,
          styleSignature: styleSignature,
        );

    final String? resolvedLanguage = highlightResult.language;
    final String? fallbackLabel = _CodeHighlightEngine.instance.displayLabel(
      widget.languageHint,
    );
    final String headerLabel = (resolvedLanguage ?? fallbackLabel ?? 'code')
        .toUpperCase();

    final Color backgroundColor = isDark
        ? Color.alphaBlend(Colors.black.withOpacity(0.35), colorScheme.surface)
        : Color.alphaBlend(
            colorScheme.primary.withOpacity(0.05),
            colorScheme.surface,
          );

    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colorScheme.outline.withOpacity(0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text(
                  headerLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.onSurface,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    textStyle: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: widget.code.isEmpty ? null : _handleCopy,
                  icon: Icon(
                    _copied ? Icons.done : Icons.content_paste,
                    size: 14,
                  ),
                  label: Text(_copied ? 'Copied!' : 'Copy code'),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            thickness: 0.8,
            color: colorScheme.outline.withOpacity(0.08),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: SelectableText.rich(highlightResult.span, style: baseStyle),
          ),
        ],
      ),
    );
  }

  TextStyle _buildBaseStyle(BuildContext context) {
    final theme = Theme.of(context);
    final TextStyle effectiveBase =
        widget.textStyle ?? theme.textTheme.bodyMedium ?? const TextStyle();
    final double baseSize =
        effectiveBase.fontSize ?? theme.textTheme.bodyMedium?.fontSize ?? 14;
    return effectiveBase.copyWith(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: const ['SourceCodePro', 'monospace'],
      fontSize: (baseSize * 0.92),
      height: 1.42,
      letterSpacing: 0.05,
      color: effectiveBase.color ?? theme.colorScheme.onSurface,
    );
  }

  int _styleSignature(TextStyle style) {
    return Object.hash(
      style.fontFamily,
      style.fontSize,
      style.fontWeight,
      style.fontStyle,
      style.letterSpacing,
      style.wordSpacing,
      style.height,
      style.decoration,
      style.decorationColor?.value,
      style.color?.value,
      style.backgroundColor?.value,
    );
  }

  Future<void> _handleCopy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() {
      _copied = true;
    });
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    setState(() {
      _copied = false;
    });
  }
}

class _CodeHighlightEngine {
  _CodeHighlightEngine._internal() {
    for (final String language in _preloadLanguages) {
      _ensureLanguageRegistered(language);
    }
  }

  static final _CodeHighlightEngine instance = _CodeHighlightEngine._internal();

  final Highlight _highlight = Highlight();
  final LinkedHashMap<_HighlightCacheKey, _HighlightResult> _cache =
      LinkedHashMap<_HighlightCacheKey, _HighlightResult>();

  static const int _maxCacheEntries = 64;

  static const Set<String> _preloadLanguages = {
    'bash',
    'c',
    'cpp',
    'csharp',
    'css',
    'dart',
    'diff',
    'dockerfile',
    'go',
    'graphql',
    'html',
    'ini',
    'java',
    'javascript',
    'json',
    'kotlin',
    'latex',
    'markdown',
    'objectivec',
    'php',
    'plaintext',
    'powershell',
    'python',
    'ruby',
    'rust',
    'shell',
    'sql',
    'swift',
    'typescript',
    'xml',
    'yaml',
  };

  _HighlightResult highlight({
    required String code,
    required String languageHint,
    required TextStyle baseStyle,
    required Map<String, TextStyle> theme,
    required bool isDarkTheme,
    required int styleSignature,
  }) {
    if (code.isEmpty) {
      return _HighlightResult(
        span: TextSpan(text: code, style: baseStyle),
        language: null,
      );
    }

    final String? normalizedHint = _normalizeLanguage(languageHint);
    if (normalizedHint == null || normalizedHint.isEmpty) {
      return _HighlightResult(
        span: TextSpan(text: code, style: baseStyle),
        language: null,
      );
    }

    final _HighlightCacheKey cacheKey = _HighlightCacheKey(
      code: code,
      languageHint: normalizedHint,
      isDarkTheme: isDarkTheme,
      styleSignature: styleSignature,
    );

    final _HighlightResult? cachedResult = _takeFromCache(cacheKey);
    if (cachedResult != null) {
      return cachedResult;
    }

    HighlightResult? result;
    String? resolvedLanguage;

    if (_ensureLanguageRegistered(normalizedHint)) {
      try {
        result = _highlight.highlight(code: code, language: normalizedHint);
        resolvedLanguage = normalizedHint;
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint('Code highlight failed for $normalizedHint: $error');
          debugPrint('$stackTrace');
        }
      }
    }

    if (result == null) {
      final _HighlightResult fallback = _HighlightResult(
        span: TextSpan(text: code, style: baseStyle),
        language: resolvedLanguage,
      );
      _storeInCache(cacheKey, fallback);
      return fallback;
    }

    final TextSpanRenderer renderer = TextSpanRenderer(baseStyle, theme);
    try {
      result.render(renderer);
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Code highlight render error: $error');
        debugPrint('$stackTrace');
      }
      final _HighlightResult fallback = _HighlightResult(
        span: TextSpan(text: code, style: baseStyle),
        language: resolvedLanguage,
      );
      _storeInCache(cacheKey, fallback);
      return fallback;
    }

    final TextSpan? highlightedSpan = renderer.span;
    final _HighlightResult output = _HighlightResult(
      span: highlightedSpan ?? TextSpan(text: code, style: baseStyle),
      language: resolvedLanguage,
    );
    _storeInCache(cacheKey, output);
    return output;
  }

  String? displayLabel(String? raw) {
    return raw?.trim().isEmpty ?? true ? null : raw?.trim();
  }

  static String? _normalizeLanguage(String? raw) {
    if (raw == null) {
      return null;
    }
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final String candidate = trimmed
        .split(RegExp(r'[\s:{(]'))
        .first
        .trim()
        .toLowerCase();
    if (candidate.isEmpty) {
      return null;
    }
    return candidate;
  }

  _HighlightResult? _takeFromCache(_HighlightCacheKey key) {
    final _HighlightResult? cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
    }
    return cached;
  }

  void _storeInCache(_HighlightCacheKey key, _HighlightResult value) {
    if (_cache.length >= _maxCacheEntries) {
      final _HighlightCacheKey oldestKey = _cache.keys.first;
      _cache.remove(oldestKey);
    }
    _cache[key] = value;
  }

  bool _ensureLanguageRegistered(String language) {
    if (_highlight.getLanguage(language) != null) {
      return true;
    }
    final Mode? mode = builtinAllLanguages[language];
    if (mode == null) {
      return false;
    }
    _highlight.registerLanguage(language, mode);
    return true;
  }
}

class _HighlightResult {
  const _HighlightResult({required this.span, this.language});

  final TextSpan span;
  final String? language;
}

class _HighlightCacheKey {
  const _HighlightCacheKey({
    required this.code,
    required this.languageHint,
    required this.isDarkTheme,
    required this.styleSignature,
  });

  final String code;
  final String languageHint;
  final bool isDarkTheme;
  final int styleSignature;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is _HighlightCacheKey &&
        code == other.code &&
        languageHint == other.languageHint &&
        isDarkTheme == other.isDarkTheme &&
        styleSignature == other.styleSignature;
  }

  @override
  int get hashCode =>
      Object.hash(code, languageHint, isDarkTheme, styleSignature);
}

/// Fullscreen viewer for images, SVG, and HTML content
/// Supports pinch-zoom and pan for images using InteractiveViewer
class _FullscreenViewer extends StatelessWidget {
  const _FullscreenViewer({
    this.imageWidget,
    this.svgContent,
    this.htmlContent,
    this.htmlMimeType,
    this.htmlEncoding,
    this.title,
  }) : assert(
         (imageWidget != null) ^ (svgContent != null) ^ (htmlContent != null),
         'Exactly one of imageWidget, svgContent, or htmlContent must be provided',
       );

  final Widget? imageWidget;
  final String? svgContent;
  final String? htmlContent;
  final String? htmlMimeType;
  final String? htmlEncoding;
  final String? title;

  static void show(
    BuildContext context, {
    Widget? imageWidget,
    String? svgContent,
    String? htmlContent,
    String? htmlMimeType,
    String? htmlEncoding,
    String? title,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => _FullscreenViewer(
          imageWidget: imageWidget,
          svgContent: svgContent,
          htmlContent: htmlContent,
          htmlMimeType: htmlMimeType,
          htmlEncoding: htmlEncoding,
          title: title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        foregroundColor: Colors.white,
        elevation: 0,
        title: title != null ? Text(title!) : null,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (imageWidget != null) {
      // For images, use InteractiveViewer for pinch-zoom and pan
      return _FullscreenImageWidget(imageWidget: imageWidget!);
    } else if (svgContent != null) {
      // For SVG, render in webview with pan-zoom support
      return _FullscreenSvgWebView(svgContent: svgContent!);
    } else if (htmlContent != null) {
      // For HTML, render in webview
      return _FullscreenHtmlWebView(
        htmlContent: htmlContent!,
        mimeType: htmlMimeType ?? 'text/html',
        encoding: htmlEncoding ?? 'utf8',
      );
    }
    return const SizedBox.shrink();
  }
}

/// Fullscreen SVG WebView with sandboxed iframe
class _FullscreenSvgWebView extends StatefulWidget {
  const _FullscreenSvgWebView({required this.svgContent});

  final String svgContent;

  @override
  State<_FullscreenSvgWebView> createState() => _FullscreenSvgWebViewState();
}

class _FullscreenSvgWebViewState extends State<_FullscreenSvgWebView> {
  bool _isDarkBackground = false;
  InAppWebViewController? _webViewController;

  void _toggleBackground() {
    setState(() {
      _isDarkBackground = !_isDarkBackground;
    });
    _updateBackgroundColor();
  }

  void _updateBackgroundColor() {
    if (_webViewController == null) return;
    final backgroundColor = _isDarkBackground ? '#1e1e1e' : '#ffffff';
    _webViewController!.evaluateJavascript(
      source:
          '''
      (function() {
        const iframe = document.querySelector('iframe');
        if (iframe && iframe.contentWindow) {
          try {
            iframe.contentWindow.postMessage({type: 'setBackground', color: '$backgroundColor'}, '*');
          } catch (e) {
            console.log('Cannot set background:', e);
          }
        }
      })();
    ''',
    );
  }

  @override
  Widget build(BuildContext context) {
    final htmlContent = _createFullscreenSvgHtml(
      widget.svgContent,
      isDarkBackground: _isDarkBackground,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          InAppWebView(
            initialData: InAppWebViewInitialData(
              data: htmlContent,
              mimeType: 'text/html',
              encoding: 'utf8',
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              supportZoom: true,
              transparentBackground: true,
              disableContextMenu: false,
              resourceCustomSchemes: ['synapse'],
              useHybridComposition: true,
            ),
            gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
              Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
            },
            onWebViewCreated: (controller) {
              _webViewController = controller;
            },
            onLoadStop: (controller, url) {
              _webViewController = controller;
            },
            onLoadResourceWithCustomScheme: (controller, request) async {
              if (request.url.scheme.toLowerCase() == 'synapse') {
                final data = await rootBundle.loadString(
                  "assets/scripts/\${request.url.host}",
                );
                return CustomSchemeResponse(
                  contentType: 'application/javascript',
                  data: Uint8List.fromList(utf8.encode(data)),
                );
              }
              return null;
            },
          ),
          Positioned(
            bottom: 32, // Adjusted for SafeArea removal
            right: 16,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.white.withValues(alpha: 0.9),
              foregroundColor: Colors.black87,
              onPressed: _toggleBackground,
              child: const Icon(Icons.contrast, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  String _createFullscreenSvgHtml(
    String svgContent, {
    bool isDarkBackground = false,
  }) {
    final backgroundColor = isDarkBackground ? '#1e1e1e' : '#ffffff';
    // Create sandboxed iframe with SVG content
    final svgDataUrl =
        'data:text/html;charset=utf-8,' +
        Uri.encodeComponent('''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; overflow: hidden; background-color: $backgroundColor; }
    body { display: flex; align-items: center; justify-content: center; }
    #svg-container { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
    svg { max-width: 100%; max-height: 100%; width: auto; height: auto; display: block; }
  </style>
  <script src="synapse://svg.pan-zoom.min.js"></script>
</head>
<body>
  <div id="svg-container">$svgContent</div>
  <script>
    window.addEventListener('message', function(e) {
      if (e.data.type === 'setBackground') {
        document.body.style.backgroundColor = e.data.color;
        document.documentElement.style.backgroundColor = e.data.color;
      }
    });
    document.addEventListener('DOMContentLoaded', function() {
      const svgElement = document.querySelector('svg');
      if (svgElement && typeof svgPanZoom !== 'undefined') {
        svgPanZoom(svgElement, {
          zoomEnabled: true,
          controlIconsEnabled: false,
          fit: true,
          center: true,
          minZoom: 0.1,
          maxZoom: 15,
          zoomScaleSensitivity: 0.3,
          dblClickZoomEnabled: true,
          mouseWheelZoomEnabled: true,
          preventMouseEventsDefault: true,
        });
      }
    });
  </script>
</body>
</html>
''');

    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    html, body { margin: 0; padding: 0; height: 100%; width: 100%; background: $backgroundColor; }
    iframe { border: 0; width: 100%; height: 100%; }
  </style>
</head>
<body>
  <iframe src="$svgDataUrl" sandbox="allow-scripts allow-same-origin"></iframe>
</body>
</html>
''';
  }
}

/// Fullscreen HTML WebView with sandboxed iframe
class _FullscreenHtmlWebView extends StatelessWidget {
  const _FullscreenHtmlWebView({
    required this.htmlContent,
    required this.mimeType,
    required this.encoding,
  });

  final String htmlContent;
  final String mimeType;
  final String encoding;

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: htmlContent,
        mimeType: mimeType,
        encoding: encoding,
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: true,
        transparentBackground: true,
        disableContextMenu: false,
        resourceCustomSchemes: const [SynapseTempUtils.scheme],
        useHybridComposition: true,
      ),
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
      },
      onLoadResourceWithCustomScheme: (controller, request) async {
        final scheme = request.url.scheme.toLowerCase();
        if (scheme == SynapseTempUtils.scheme) {
          try {
            final file = await SynapseTempUtils.loadFile(
              request.url.toString(),
            );
            return CustomSchemeResponse(
              data: file.bytes,
              contentType: file.mimeType,
            );
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Fullscreen webview resource error: $e');
            }
          }
        }
        return null;
      },
    );
  }
}

class _FullscreenImageWidget extends StatefulWidget {
  const _FullscreenImageWidget({required this.imageWidget});

  final Widget imageWidget;

  @override
  State<_FullscreenImageWidget> createState() => _FullscreenImageWidgetState();
}

class _FullscreenImageWidgetState extends State<_FullscreenImageWidget> {
  bool _isDarkBackground = false;

  void _toggleBackground() {
    setState(() {
      _isDarkBackground = !_isDarkBackground;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          color: _isDarkBackground
              ? const Color(0xFF1E1E1E)
              : const Color(0xFFFFFFFF),
          child: SizedBox.expand(
            child: InteractiveViewer(
              minScale: 0.1,
              maxScale: 10.0,
              boundaryMargin: const EdgeInsets.all(double.infinity),
              clipBehavior: Clip.none,
              child: Center(child: widget.imageWidget),
            ),
          ),
        ),
        Positioned(
          bottom: 32, // Adjusted for SafeArea removal
          right: 16,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: Colors.white.withValues(alpha: 0.9),
            foregroundColor: Colors.black87,
            onPressed: _toggleBackground,
            child: const Icon(Icons.contrast, size: 20),
          ),
        ),
      ],
    );
  }
}

class CustomATagMd extends ATagMd {
  @override
  RegExp get exp => RegExp(
    r"(?<!\!)\[(?:[^\[\]]|\[[^\[\]]*\])*\]\((?:[^()]*)(?:\((?:[^()]*)(?:\([^()]*\)[^()]*)*\)[^()]*)*\)",
  );

  @override
  InlineSpan span(
    BuildContext context,
    String text,
    final GptMarkdownConfig config,
  ) {
    var bracketCount = 0;
    var start = 1;
    var end = 0;
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '[') {
        bracketCount++;
      } else if (text[i] == ']') {
        bracketCount--;
        if (bracketCount == 0) {
          end = i;
          break;
        }
      }
    }

    if (end + 1 >= text.length || text[end + 1] != '(') {
      return const TextSpan();
    }

    final linkText = text.substring(start, end);
    final urlStart = end + 2;

    // Now find the balanced closing parenthesis
    int parenCount = 0;
    int urlEnd = urlStart;

    for (int i = urlStart; i < text.length; i++) {
      final char = text[i];

      if (char == '(') {
        parenCount++;
      } else if (char == ')') {
        if (parenCount == 0) {
          // This is the closing parenthesis of the link
          urlEnd = i;
          break;
        } else {
          parenCount--;
        }
      }
    }

    if (urlEnd == urlStart) {
      // No closing parenthesis found
      return const TextSpan();
    }

    final url = text.substring(urlStart, urlEnd).trim();

    var builder = config.linkBuilder;

    var ending = text.substring(urlEnd + 1);

    var endingSpans = MarkdownComponent.generate(
      context,
      ending,
      config,
      false,
    );
    var theme = GptMarkdownTheme.of(context);
    final linkColor = Theme.of(context).colorScheme.primary;
    // Strip common formatting chars that might surround the number
    final cleanText = linkText.replaceAll(RegExp(r'[\[\]\s_]'), '');
    final isNumericLink = RegExp(r'^\d+$').hasMatch(cleanText);
    // Generate children with the link style enforced
    var children = MarkdownComponent.generate(context, linkText, config, false);
    // Force style on children if they are TextSpans to ensure color sticks
    children = children.map((span) {
      if (span is TextSpan) {
        return TextSpan(
          text: span.text,
          children: span.children,
          style: (span.style ?? config.style ?? const TextStyle()).copyWith(
            color: linkColor,
            decoration: isNumericLink
                ? TextDecoration.none
                : TextDecoration.underline,
            decorationColor: linkColor,
          ),
          recognizer: span.recognizer,
          mouseCursor: span.mouseCursor,
          onEnter: span.onEnter,
          onExit: span.onExit,
          semanticsLabel: span.semanticsLabel,
          locale: span.locale,
          spellOut: span.spellOut,
        );
      }
      return span;
    }).toList();

    var linkTextSpan = TextSpan(
      children: children,
      style:
          config.style?.copyWith(
            color: linkColor,
            decoration: isNumericLink
                ? TextDecoration.none
                : TextDecoration.underline,
            decorationColor: linkColor,
          ) ??
          TextStyle(
            color: linkColor,
            decoration: isNumericLink
                ? TextDecoration.none
                : TextDecoration.underline,
            decorationColor: linkColor,
          ),
    );

    // Use custom builder if provided
    WidgetSpan? child;
    if (builder != null) {
      child = WidgetSpan(
        baseline: TextBaseline.alphabetic,
        alignment: PlaceholderAlignment.baseline,
        child: GestureDetector(
          onTap: () => config.onLinkTap?.call(url, linkText),
          child: builder(
            context,
            linkTextSpan,
            url,
            config.style ?? const TextStyle(),
          ),
        ),
      );
    }

    // Default rendering
    child ??= WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: InkWell(
        hoverColor: theme.linkHoverColor,
        onTap: () {
          config.onLinkTap?.call(url, linkText);
        },
        child: config.getRich(linkTextSpan),
      ),
    );
    var textSpan = TextSpan(children: [child, ...endingSpans]);
    return textSpan;
  }
}

/// Custom Image Markdown component to handle data URIs with newlines/encoding.
class CustomImageMd extends InlineMd {
  final Widget Function(String url, String? alt)? onImage;

  CustomImageMd({this.onImage});

  @override
  // Match ![alt](url) but allow newlines/spaces in URL part
  RegExp get exp => RegExp(r"!\[([^\]]*)\]\(([^)]*)\)");

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    var match = exp.firstMatch(text.trim());
    if (match == null) return TextSpan(text: text);

    var alt = match.group(1);
    var url = match.group(2) ?? "";

    // Clean up the URL if it looks like a data URI
    // Use loose check for data: because sometimes it might have spaces before it
    if (url.trim().contains('data:')) {
      try {
        url = Uri.decodeFull(url);
      } catch (_) {}
      url = url.replaceAll(RegExp(r'\s'), '');
    }

    if (onImage != null) {
      return WidgetSpan(
        alignment: PlaceholderAlignment.bottom,
        child: onImage!(url, alt),
      );
    }
    return TextSpan(text: text);
  }
}

/// Resolves a `synapseresource://app/...` URI (either an inline
/// `@[WxH](...)` embed or a preprocessed `__blockRef` sentinel for a
/// ```synapse-app``` fenced block) into an [EmbeddedUserAppView].
///
/// Handles:
/// - Parsing query parameters into the [EmbeddedUserAppView.params] map.
/// - Resolving `note=current` / `notes=current,<id>,...` selectors into a
///   real `List<Note>` by looking up ids in [DatabaseService] and
///   substituting the host note for `current`.
/// - Looking up the fenced-block body via `appBlockLookup` when the URI
///   contains a `__blockRef` key (allows embeds with params too large for a
///   URL).
class _AppEmbedFromUri extends StatefulWidget {
  const _AppEmbedFromUri({
    required this.url,
    required this.width,
    required this.height,
    required this.defaultSize,
    this.parentNoteId,
    this.appBlockLookup,
  });

  final String url;
  final double width;
  final double height;
  final Size defaultSize;
  final String? parentNoteId;
  final SynapseAppBlockBody? Function(String blockRefId)? appBlockLookup;

  @override
  State<_AppEmbedFromUri> createState() => _AppEmbedFromUriState();
}

class _AppEmbedFromUriState extends State<_AppEmbedFromUri> {
  late Future<_EmbedRequest> _future;

  @override
  void initState() {
    super.initState();
    _future = _resolve();
  }

  @override
  void didUpdateWidget(covariant _AppEmbedFromUri oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.parentNoteId != widget.parentNoteId) {
      setState(() {
        _future = _resolve();
      });
    }
  }

  Future<_EmbedRequest> _resolve() async {
    final link = SynapseResourceUri.parse(widget.url);
    if (link == null || link.type != SynapseResourceType.app) {
      return _EmbedRequest.error('Invalid synapseresource://app URI');
    }

    final appUuid = link.id;
    final query = link.queryParameters;

    SynapseAppBlockBody? blockBody;
    final blockRefId = query[synapseAppBlockRefKey];
    if (blockRefId != null && widget.appBlockLookup != null) {
      blockBody = widget.appBlockLookup!(blockRefId);
    }

    final revisionRaw = blockBody?.revisionNumber?.toString() ??
        query['revision'];
    final int? revisionNumber = revisionRaw == null
        ? null
        : int.tryParse(revisionRaw);

    final noteSelectors = <String>[];
    if (blockBody != null) {
      noteSelectors.addAll(blockBody.noteSelectors);
    } else {
      final singleNote = query['note'];
      if (singleNote != null && singleNote.trim().isNotEmpty) {
        noteSelectors.add(singleNote.trim());
      }
      final manyNotes = query['notes'];
      if (manyNotes != null && manyNotes.trim().isNotEmpty) {
        noteSelectors.addAll(
          manyNotes.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
        );
      }
    }

    final resolvedNotes = await _resolveNoteSelectors(noteSelectors);

    Map<String, dynamic> params;
    if (blockBody != null) {
      params = Map<String, dynamic>.from(blockBody.params);
    } else {
      params = <String, dynamic>{};
      for (final entry in query.entries) {
        if (synapseAppReservedQueryKeys.contains(entry.key)) continue;
        params[entry.key] = entry.value;
      }
    }

    return _EmbedRequest.ok(
      appUuid: appUuid,
      revisionNumber: revisionNumber,
      selectedNotes: resolvedNotes,
      params: params,
    );
  }

  Future<List<Note>> _resolveNoteSelectors(List<String> selectors) async {
    if (selectors.isEmpty) return const [];

    final db = DatabaseService();
    final concreteIds = <String>{};
    bool includesCurrent = false;
    for (final s in selectors) {
      if (s.toLowerCase() == 'current') {
        includesCurrent = true;
      } else {
        concreteIds.add(s);
      }
    }

    if (includesCurrent) {
      if (widget.parentNoteId != null) {
        concreteIds.add(widget.parentNoteId!);
      } else {
        LoggerService.warning(
          "[EmbeddedUserApp] 'current' note selector used without a parent note id; "
          'the app will receive an empty Notes list for that slot.',
        );
      }
    }

    if (concreteIds.isEmpty) return const [];
    final notes = await db.getNotesByIds(concreteIds.toList());
    // Preserve selector order where possible.
    final byId = {for (final n in notes) n.id: n};
    final ordered = <Note>[];
    for (final s in selectors) {
      final id = s.toLowerCase() == 'current' ? widget.parentNoteId : s;
      if (id == null) continue;
      final note = byId[id];
      if (note != null && !ordered.contains(note)) {
        ordered.add(note);
      }
    }
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_EmbedRequest>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final request = snapshot.data;
        if (request == null || !request.ok) {
          return _EmbeddedWebViewError(
            message: request?.error ?? 'Unable to resolve embedded app',
          );
        }
        return EmbeddedUserAppView(
          appUuid: request.appUuid!,
          revisionNumber: request.revisionNumber,
          selectedNotes: request.selectedNotes!,
          params: request.params!,
          width: widget.width,
          height: widget.height,
          parentNoteId: widget.parentNoteId,
        );
      },
    );
  }
}

class _EmbedRequest {
  const _EmbedRequest._({
    this.appUuid,
    this.revisionNumber,
    this.selectedNotes,
    this.params,
    this.error,
  });
  factory _EmbedRequest.ok({
    required String appUuid,
    int? revisionNumber,
    required List<Note> selectedNotes,
    required Map<String, dynamic> params,
  }) =>
      _EmbedRequest._(
        appUuid: appUuid,
        revisionNumber: revisionNumber,
        selectedNotes: selectedNotes,
        params: params,
      );
  factory _EmbedRequest.error(String message) =>
      _EmbedRequest._(error: message);

  final String? appUuid;
  final int? revisionNumber;
  final List<Note>? selectedNotes;
  final Map<String, dynamic>? params;
  final String? error;

  bool get ok => error == null && appUuid != null && selectedNotes != null;
}
