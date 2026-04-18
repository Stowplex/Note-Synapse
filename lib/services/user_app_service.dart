import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import 'package:html2md/html2md.dart' as html2md;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../models/user_app.dart';
import 'ai_service.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'network_provider.dart';
import 'prompts/note_prompt_builder.dart';
import 'prompts/prompt_configuration_service.dart';
import 'prompts/prompt_template_service.dart';
import 'prompts/registrations/app_prompt_configuration.dart';
import 'user_app_library_service.dart';
import 'global_library_service.dart';
import '../models/generation_context.dart';
import 'service_locator.dart';

class UserAppService {
  final DatabaseService _databaseService;
  final AIService _aiService;

  UserAppService(this._databaseService, this._aiService);

  /// Factory constructor to get the singleton instance from GetIt.
  factory UserAppService.instance() => getIt<UserAppService>();

  /// Create an instance for testing with a mock DatabaseService.
  @visibleForTesting
  static UserAppService createForTesting(
    DatabaseService databaseService,
    AIService aiService,
  ) {
    return UserAppService(databaseService, aiService);
  }

  // Get all user apps
  Future<List<UserApp>> getAllUserApps() async {
    try {
      return await _databaseService.getAllUserApps();
    } catch (e) {
      LoggerService.error('Error loading user apps: $e', error: e);
      return [];
    }
  }

  // Save a user app
  Future<void> saveUserApp(UserApp app) async {
    try {
      await _databaseService.insertUserApp(app);
    } catch (e) {
      LoggerService.error('Error saving user app: $e', error: e);
      rethrow;
    }
  }

  // Update a user app
  Future<void> updateUserApp(UserApp app) async {
    try {
      await _databaseService.updateUserApp(app);
    } catch (e) {
      LoggerService.error('Error updating user app: $e', error: e);
      rethrow;
    }
  }

  // Delete a user app
  Future<void> deleteUserApp(String appId) async {
    try {
      await _databaseService.deleteUserApp(appId);
    } catch (e) {
      LoggerService.error('Error deleting user app: $e', error: e);
      rethrow;
    }
  }

  // Get app state
  Future<Map<String, dynamic>?> getAppState(String appId) async {
    try {
      return await _databaseService.getUserAppState(appId);
    } catch (e) {
      LoggerService.error('Error loading app state: $e', error: e);
      return null;
    }
  }

  // Save app state
  Future<void> saveAppState(String appId, Map<String, dynamic> state) async {
    try {
      await _databaseService.updateUserAppState(appId, state);
    } catch (e) {
      LoggerService.error('Error saving app state: $e', error: e);
      rethrow;
    }
  }

  // App Revisions management
  Future<List<AppRevision>> getAppRevisions(String appId) async {
    try {
      return await _databaseService.getAppRevisions(appId);
    } catch (e) {
      LoggerService.error('Error loading app revisions: $e', error: e);
      return [];
    }
  }

  Future<AppRevision?> getAppRevision(String revisionId) async {
    try {
      return await _databaseService.getAppRevision(revisionId);
    } catch (e) {
      LoggerService.error('Error loading app revision: $e', error: e);
      return null;
    }
  }

  Future<void> deleteAppRevision(String revisionId) async {
    try {
      await _databaseService.deleteAppRevision(revisionId);
    } catch (e) {
      LoggerService.error('Error deleting app revision: $e', error: e);
      rethrow;
    }
  }

  Future<void> setSelectedRevision(String appId, String revisionId) async {
    try {
      final app = await _databaseService.getUserApp(appId);
      if (app != null) {
        final updatedApp = app.copyWith(selectedRevisionId: revisionId);
        await _databaseService.updateUserApp(updatedApp);
      }
    } catch (e) {
      LoggerService.error('Error setting selected revision: $e', error: e);
      rethrow;
    }
  }

  // Create initial revision for apps that don't have any revisions yet
  Future<AppRevision> createInitialRevision(String appId) async {
    try {
      final app = await _databaseService.getUserApp(appId);
      if (app == null) {
        throw Exception('App not found: $appId');
      }

      // Check if app already has revisions
      final existingRevisions = await _databaseService.getAppRevisions(appId);
      if (existingRevisions.isNotEmpty) {
        throw Exception('App already has revisions');
      }

      // Create initial revision
      final revision = AppRevision(
        id: '${appId}_rev_1',
        appId: appId,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: 'Initial app creation',
        aiResponse: 'This is the initial version of the app.',
        appCode: app.htmlContent,
      );

      // Save the revision
      await _databaseService.insertAppRevision(revision);

      // Update the app to set the selected revision
      final updatedApp = app.copyWith(selectedRevisionId: revision.id);
      await _databaseService.updateUserApp(updatedApp);

      return revision;
    } catch (e) {
      LoggerService.error('Error creating initial revision: $e', error: e);
      rethrow;
    }
  }

  // Create a new user app using AI
  Future<UserApp> createUserApp({
    required String name,
    required String description,
    required List<String> steps,
    UserAppType type = UserAppType.normal,
    String? userPrompt,
    List<String>? attachmentPaths,
    List<Note>? contextNotes,
    List<UserAppLibraryInfo>? libraries,
    GenerationContext? generationContext,
  }) async {
    try {
      // Generate the app using AI
      final aiResponse = await _generateAppWithAI(
        name,
        description,
        steps,
        type,
        attachmentPaths: attachmentPaths,
        contextNotes: contextNotes,
        libraries: libraries,
        generationContext: generationContext,
      );

      // Parse the AI response to extract code and explanation
      final parsedResponse = parseAIResponse(aiResponse);
      final htmlContent = parsedResponse['code']?.isNotEmpty == true
          ? parsedResponse['code']!
          : aiResponse;
      final explanation = parsedResponse['explanation']?.isNotEmpty == true
          ? parsedResponse['explanation']!
          : '';

      LoggerService.debug(
        'createUserApp: Parsed response - code length: ${parsedResponse['code']?.length ?? 0}, explanation length: ${parsedResponse['explanation']?.length ?? 0}',
      );
      LoggerService.debug(
        'createUserApp: Using parsed code: ${parsedResponse['code']?.isNotEmpty == true}',
      );
      LoggerService.debug(
        'createUserApp: Final htmlContent length: ${htmlContent.length}',
      );
      LoggerService.debug(
        'createUserApp: Final explanation length: ${explanation.length}',
      );

      final app = UserApp(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        uuid: const Uuid().v4(),
        name: name,
        description: description,
        steps: steps,
        htmlContent: '', // No longer used - code is stored in revisions
        type: type,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        libraries: libraries,
      );

      await saveUserApp(app);

      // Always create initial revision for new apps
      final revision = AppRevision(
        id: '${DateTime.now().millisecondsSinceEpoch}_rev',
        appId: app.id,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: userPrompt ?? 'Initial app creation',
        aiResponse: explanation,
        appCode: htmlContent,
        attachmentPaths: attachmentPaths ?? [],
      );

      LoggerService.debug('Creating revision ${revision.id} for app ${app.id}');
      LoggerService.debug('Revision userPrompt: ${revision.userPrompt}');
      LoggerService.debug(
        'Revision aiResponse length: ${revision.aiResponse.length}',
      );
      LoggerService.debug(
        'Revision appCode length: ${revision.appCode.length}',
      );
      LoggerService.debug(
        'Revision appCode preview: ${revision.appCode.substring(0, revision.appCode.length > 200 ? 200 : revision.appCode.length)}...',
      );

      await _databaseService.insertAppRevision(revision);

      // Update app with selected revision
      final updatedApp = app.copyWith(selectedRevisionId: revision.id);
      await _databaseService.updateUserApp(updatedApp);
      LoggerService.debug(
        'Updated app with selectedRevisionId: ${updatedApp.selectedRevisionId}',
      );

      // Download and store libraries if provided
      if (libraries != null && libraries.isNotEmpty) {
        await _downloadAndStoreLibraries(updatedApp, revision, libraries);
      }

      return updatedApp;
    } catch (e) {
      LoggerService.error('Error creating user app: $e', error: e);
      rethrow;
    }
  }

  // Save manual code edit by creating a new revision
  Future<AppRevision> saveManualCodeEdit({
    required UserApp originalApp,
    required String newCode,
    List<String>? attachmentPaths,
  }) async {
    try {
      // Get the next revision number
      final revisionNumber = await _databaseService.getNextRevisionNumber(
        originalApp.id,
      );

      // Create the revision for manual edit
      final revision = AppRevision(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        appId: originalApp.id,
        revisionNumber: revisionNumber,
        revisionTimestamp: DateTime.now(),
        userPrompt: 'Manual code edit',
        aiResponse: 'User manually edited the app code.',
        appCode: newCode,
        attachmentPaths: attachmentPaths ?? [],
      );

      // Save the revision
      await _databaseService.insertAppRevision(revision);

      // Copy dependencies from the current revision to the new revision
      if (originalApp.selectedRevisionId != null) {
        try {
          LoggerService.debug(
            'Manual edit: Copying dependencies from revision ${originalApp.selectedRevisionId}',
          );
          final currentRevision = await _databaseService.getAppRevision(
            originalApp.selectedRevisionId!,
          );
          if (currentRevision != null) {
            LoggerService.debug(
              'Manual edit: Found current revision ${currentRevision.id} with revision number ${currentRevision.revisionNumber}',
            );
            final libraryService = UserAppLibraryService();
            await libraryService.copyLibrariesToRevision(
              appUuid: originalApp.uuid,
              fromRevisionId: currentRevision.revisionNumber,
              toRevisionId: revisionNumber,
            );
            LoggerService.debug(
              'Manual edit: Successfully copied dependencies to revision $revisionNumber',
            );
          } else {
            LoggerService.warning(
              'Manual edit: Current revision not found: ${originalApp.selectedRevisionId}',
            );
          }
        } catch (e) {
          LoggerService.warning(
            'Failed to copy dependencies for manual edit: $e',
          );
          // Don't rethrow - the revision creation should still succeed
        }
      } else {
        LoggerService.warning(
          'Manual edit: No selectedRevisionId found in originalApp',
        );
      }

      // Update the app's selected revision (but NOT the htmlContent)
      final updatedApp = originalApp.copyWith(
        selectedRevisionId: revision.id,
        updatedAt: DateTime.now(),
      );
      await _databaseService.updateUserApp(updatedApp);

      return revision;
    } catch (e) {
      LoggerService.error('Error saving manual code edit: $e', error: e);
      rethrow;
    }
  }

  // Edit an existing app by creating a new revision
  Future<AppRevision> editUserApp({
    required UserApp originalApp,
    required String editSuggestion,
    List<String>? attachmentPaths,
    List<Note>? contextNotes,
    List<UserAppLibraryInfo>? libraries,
    GenerationContext? generationContext,
  }) async {
    try {
      // Generate new app based on original and edit suggestion
      final aiResponse = await _generateAppEditWithAI(
        originalApp.name,
        originalApp.description,
        originalApp.steps,
        originalApp.htmlContent,
        editSuggestion,
        originalApp.type,
        attachmentPaths: attachmentPaths,
        contextNotes: contextNotes,
        libraries: libraries,
        generationContext: generationContext,
      );

      // Parse the AI response to extract code and explanation
      final parsedResponse = parseAIResponse(aiResponse);
      final newHtmlContent = parsedResponse['code'] ?? originalApp.htmlContent;
      final explanation = parsedResponse['explanation'] ?? '';

      // Get the next revision number
      final revisionNumber = await _databaseService.getNextRevisionNumber(
        originalApp.id,
      );

      // Create the revision
      final revision = AppRevision(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        appId: originalApp.id,
        revisionNumber: revisionNumber,
        revisionTimestamp: DateTime.now(),
        userPrompt: editSuggestion,
        aiResponse: explanation,
        appCode: newHtmlContent,
        attachmentPaths: attachmentPaths ?? [],
      );

      // Save the revision
      await _databaseService.insertAppRevision(revision);

      // Download and store libraries if provided
      if (libraries != null && libraries.isNotEmpty) {
        await _downloadAndStoreLibraries(originalApp, revision, libraries);
      }

      // Copy dependencies from the current revision to the new revision
      if (originalApp.selectedRevisionId != null) {
        try {
          LoggerService.debug(
            'AI edit: Copying dependencies from revision ${originalApp.selectedRevisionId}',
          );
          final currentRevision = await _databaseService.getAppRevision(
            originalApp.selectedRevisionId!,
          );
          if (currentRevision != null) {
            LoggerService.debug(
              'AI edit: Found current revision ${currentRevision.id} with revision number ${currentRevision.revisionNumber}',
            );
            final libraryService = UserAppLibraryService();
            await libraryService.copyLibrariesToRevision(
              appUuid: originalApp.uuid,
              fromRevisionId: currentRevision.revisionNumber,
              toRevisionId: revisionNumber,
            );
            LoggerService.debug(
              'AI edit: Successfully copied dependencies to revision $revisionNumber',
            );
          } else {
            LoggerService.warning(
              'AI edit: Current revision not found: ${originalApp.selectedRevisionId}',
            );
          }
        } catch (e) {
          LoggerService.warning('Failed to copy dependencies for AI edit: $e');
          // Don't rethrow - the revision creation should still succeed
        }
      } else {
        LoggerService.warning(
          'AI edit: No selectedRevisionId found in originalApp',
        );
      }

      // Update the app's selected revision (but NOT the htmlContent)
      final updatedApp = originalApp.copyWith(
        selectedRevisionId: revision.id,
        updatedAt: DateTime.now(),
      );
      await _databaseService.updateUserApp(updatedApp);

      return revision;
    } catch (e) {
      LoggerService.error('Error editing user app: $e', error: e);
      rethrow;
    }
  }

  // Generate app HTML using AI
  Future<String> _generateAppWithAI(
    String name,
    String description,
    List<String> steps,
    UserAppType type, {
    List<String>? attachmentPaths,
    List<Note>? contextNotes,
    List<UserAppLibraryInfo>? libraries,
    GenerationContext? generationContext,
  }) async {
    try {
      final noteContextPayload = await _buildNoteContextPayload(contextNotes);
      final prompt = _buildAppGenerationPrompt(
        name,
        description,
        steps,
        type,
        libraries: libraries,
        noteContext: noteContextPayload?.text,
      );

      final attachedFiles = await _prepareAttachments(
        attachmentPaths: attachmentPaths,
        noteAttachments: noteContextPayload?.attachments,
      );

      final response = await _aiService.generateApp(
        prompt,
        attachedFiles: attachedFiles,
        generationContext: generationContext,
      );
      return response; // Return the full response, let parseAIResponse handle the parsing
    } catch (e) {
      LoggerService.error('Error generating app with AI: $e', error: e);
      rethrow;
    }
  }

  // Generate app edit using AI
  Future<String> _generateAppEditWithAI(
    String name,
    String description,
    List<String> steps,
    String originalHtml,
    String editSuggestion,
    UserAppType type, {
    List<String>? attachmentPaths,
    List<Note>? contextNotes,
    List<UserAppLibraryInfo>? libraries,
    GenerationContext? generationContext,
  }) async {
    try {
      final noteContextPayload = await _buildNoteContextPayload(contextNotes);
      final librariesSection = _buildLibrariesSectionForPrompt(libraries);

      final noteContextSection =
          (noteContextPayload?.text?.trim().isNotEmpty ?? false)
          ? '''
Additional Note Context:
${noteContextPayload!.text}

Use these notes (including linked relationships) to ground the edits and incorporate relevant data or behaviours.
'''
          : '';

      final typeInstructions = type == UserAppType.noteAction
          ? _getNoteActionAppInstructions()
          : type == UserAppType.aiTool
              ? _getAiToolAppInstructions()
              : '';

      final prompt = getIt<PromptTemplateService>().renderSync(
        'user_app/app_edit',
        {
          'name': name,
          'description': description,
          'stepsJoined': steps.join(', '),
          'librariesSection': librariesSection,
          'noteContextSection': noteContextSection,
          'originalHtml': originalHtml,
          'editSuggestion': editSuggestion,
          'databaseSchema': _buildDatabaseSchemaSection(),
          'apiDocumentation': _buildApiDocumentationSection(),
          'librariesFromService': _buildLibrariesSection(),
          'requirementsSection': _buildRequirementsSection(),
          'typeSpecificInstructions': typeInstructions,
        },
      );

      final attachedFiles = await _prepareAttachments(
        attachmentPaths: attachmentPaths,
        noteAttachments: noteContextPayload?.attachments,
      );

      final response = await _aiService.generateApp(
        prompt,
        attachedFiles: attachedFiles,
        generationContext: generationContext,
      );
      return response; // Return the full response, let parseAIResponse handle the parsing
    } catch (e) {
      LoggerService.error('Error generating app edit with AI: $e', error: e);
      rethrow;
    }
  }

  // Build the app generation prompt
  static String _buildAppGenerationPrompt(
    String name,
    String description,
    List<String> steps,
    UserAppType type, {
    List<UserAppLibraryInfo>? libraries,
    String? noteContext,
  }) {
    final templateService = getIt<PromptTemplateService>();

    final librariesSection = _buildLibrariesSectionForPrompt(libraries);
    final noteContextSection =
        (noteContext != null && noteContext.trim().isNotEmpty)
            ? 'Additional Note Context:\n$noteContext\n\n'
                'Use these notes (including linked relationships) to shape '
                "the app's functionality, data access patterns, and UI examples."
            : '';

    final typeInstructions = type == UserAppType.noteAction
        ? _getNoteActionAppInstructions()
        : type == UserAppType.aiTool
            ? _getAiToolAppInstructions()
            : '';

    final addOn = PromptConfigurationService.instance.getValue(
      AppPromptConfiguration.generationAddendumId,
    );
    final trimmedAddOn = addOn?.trim();

    return templateService.renderSync(
      'user_app/app_generation',
      {
        'name': name,
        'description': description,
        'stepsJoined': steps.join('\n - '),
        'librariesSection': librariesSection,
        'noteContextSection': noteContextSection,
        'apiDocumentation': _buildApiDocumentationSection(),
        'librariesFromService': _buildLibrariesSection(),
        'requirementsSection': _buildRequirementsSection(),
        'databaseSchema': _buildDatabaseSchemaSection(),
        'typeSpecificInstructions': typeInstructions,
        'hasAddendum': trimmedAddOn != null && trimmedAddOn.isNotEmpty,
        'addendum': trimmedAddOn,
      },
    );
  }

  Future<_NoteContextPayload?> _buildNoteContextPayload(
    List<Note>? contextNotes,
  ) async {
    if (contextNotes == null || contextNotes.isEmpty) {
      return null;
    }

    try {
      final builder = NotePromptBuilder(_databaseService);
      final context = await builder.buildNoteContext(contextNotes);
      final attachments = await builder.loadNoteAttachments(contextNotes);
      final formattedContext = context.trim().isEmpty
          ? null
          : 'Note context with linked relationships:\n$context';

      return _NoteContextPayload(
        text: formattedContext,
        attachments: attachments,
      );
    } catch (e) {
      LoggerService.warning(
        'Failed to build note context for user app prompts: $e',
      );
      return null;
    }
  }

  static Future<List<PlatformFile>?> _prepareAttachments({
    List<String>? attachmentPaths,
    List<PlatformFile>? noteAttachments,
  }) async {
    final attachments = <PlatformFile>[];
    final seenKeys = <String>{};

    void addFile(PlatformFile file) {
      final key = file.path ?? '${file.name}_${file.size}';
      if (seenKeys.add(key)) {
        attachments.add(file);
      }
    }

    if (noteAttachments != null) {
      for (final file in noteAttachments) {
        addFile(file);
      }
    }

    if (attachmentPaths != null) {
      for (final path in attachmentPaths) {
        try {
          final file = File(path);
          if (!await file.exists()) {
            continue;
          }

          final bytes = await file.readAsBytes();
          addFile(
            PlatformFile(
              name: path.split('/').last,
              size: bytes.length,
              bytes: bytes,
              path: path,
            ),
          );
        } catch (e) {
          LoggerService.warning('Failed to read attachment $path: $e');
        }
      }
    }

    return attachments.isEmpty ? null : attachments;
  }

  // Build database schema section for prompts
  static String _buildDatabaseSchemaSection() {
    final formattedSchema = DatabaseService.getSchemaDescription();

    return '''
Database Schema:
The app has access to the following database tables:

$formattedSchema

IMPORTANT: 
- Use the schema above to understand the database structure.
- The comments in the schema describe the purpose of each column.
- Use this schema when writing SQL queries or interacting with the database.
''';
  }

  // Build API documentation section for prompts
  static String _buildApiDocumentationSection() {
    return getIt<PromptTemplateService>().renderSync(
      'user_app/api_documentation',
    );
  }

  // Build libraries section for prompts
  static String _buildLibrariesSection() {
    final service = GlobalLibraryService();
    // Ensure service is initialized (it should be, but just in case)
    // Note: init() is async, but this method is sync.
    // Ideally GlobalLibraryService should be initialized at app startup.
    // For now, we assume it's initialized or we might miss libraries if called too early.

    final enabledLibs = service.enabledLibraries;
    if (enabledLibs.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    buffer.writeln('5. Libraries you can utilize:');

    for (final lib in enabledLibs) {
      buffer.writeln('  - ${lib.usage.trim()}');
    }

    return buffer.toString();
  }

  // Build requirements section for prompts
  static String _buildRequirementsSection() {
    return getIt<PromptTemplateService>().renderSync(
      'user_app/requirements',
    );
  }

  // Build libraries section from user-provided libraries
  static String _buildLibrariesSectionForPrompt(
    List<UserAppLibraryInfo>? libraries,
  ) {
    if (libraries == null || libraries.isEmpty) {
      return '';
    }
    final templateService = getIt<PromptTemplateService>();

    final libraryContexts = libraries.map((lib) {
      final importTags = lib.links
          .map((link) => link.replaceAll('https://', 'synapseuser://'))
          .map(
            (link) => link.endsWith('.css')
                ? '<link rel="stylesheet" href="$link">'
                : '<script src="$link"></script>',
          )
          .join('\n      ');

      return {
        'name': lib.name,
        'usage': lib.usage ?? 'No usage instructions provided',
        'importTags': importTags,
      };
    }).toList();

    return templateService.renderSync(
      'user_app/libraries_for_prompt',
      {'libraries': libraryContexts},
    );
  }

  // Get Note Action App specific instructions
  static String _getNoteActionAppInstructions() {
    return getIt<PromptTemplateService>().renderSync(
      'user_app/note_action_instructions',
    );
  }

  // Get AI Tool App specific instructions
  static String _getAiToolAppInstructions() {
    return getIt<PromptTemplateService>().renderSync(
      'user_app/ai_tool_instructions',
    );
  }

  // Check if WebView is supported on current platform
  static bool isWebViewSupported() {
    return kIsWeb || !Platform.isLinux;
  }

  static Future<Map<String, dynamic>> fetchWebPage(String urlRaw) async {
    final url = urlRaw.trim();
    if (url.isEmpty) {
      throw ArgumentError('URL is required');
    }

    if (!isWebViewSupported()) {
      throw Exception('WebView is not supported on this platform.');
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw ArgumentError('Invalid URL: $urlRaw');
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw ArgumentError('Only HTTP(S) URLs are supported');
    }

    final startTime = DateTime.now();
    LoggerService.debug('[Synapse.fetchWebPage] Loading $url');

    final completer = Completer<Map<String, dynamic>>();
    const timeout = Duration(seconds: 45);
    const allowedSchemes = {
      'http',
      'https',
      'data',
      'about',
      'file',
      'javascript',
    };

    final headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        allowFileAccess: false,
        allowContentAccess: false,
        allowFileAccessFromFileURLs: false,
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final targetUrl = navigationAction.request.url;
        if (targetUrl == null) {
          return NavigationActionPolicy.CANCEL;
        }

        final targetScheme = targetUrl.scheme.toLowerCase();
        if (allowedSchemes.contains(targetScheme)) {
          return NavigationActionPolicy.ALLOW;
        }

        LoggerService.warning(
          '[Synapse.fetchWebPage] Blocked navigation to unsupported scheme: $targetScheme',
        );
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, url) async {
        if (url.toString() == 'about:blank') {
          return;
        }

        if (completer.isCompleted) {
          return;
        }

        try {
          // Get the body HTML (similar to share_screen.dart when Readability is off)
          final htmlResult = await controller.evaluateJavascript(
            source: '''
              (function() {
                try {
                  if (document.body) {
                    return document.body.innerHTML;
                  }
                  return document.documentElement ? document.documentElement.innerHTML : '';
                } catch (e) {
                  console.log(e, e.stack);
                  return '';
                }
              })();
            ''',
          );
          final htmlContent = htmlResult?.toString() ?? '';

          if (htmlContent.isEmpty) {
            throw Exception('Failed to extract HTML content from webpage');
          }

          // Get the title
          final titleResult = await controller.evaluateJavascript(
            source: 'document.title || ""',
          );
          final title = titleResult?.toString().trim() ?? '';

          // Convert HTML to markdown, ignoring script and style tags (like share_screen.dart)
          final markdown = html2md.convert(
            htmlContent,
            ignore: ['script', 'style'],
          );

          final duration = DateTime.now().difference(startTime);
          LoggerService.debug(
            '[Synapse.fetchWebPage] Success (${markdown.length} chars) in ${duration.inMilliseconds}ms',
          );

          if (!completer.isCompleted) {
            completer.complete({
              'url': url.toString(),
              'title': title,
              'markdown': markdown,
            });
          }
        } catch (e, stackTrace) {
          LoggerService.error(
            '[Synapse.fetchWebPage] Extraction failed: $e',
            error: e,
            stackTrace: stackTrace,
          );
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        }
      },
      onReceivedError: (controller, request, error) {
        if (completer.isCompleted) {
          return;
        }

        if (request.isForMainFrame ?? false) {
          // Correct property is mainFrame for WebResourceRequest in flutter_inappwebview
          final exception = Exception(
            'Failed to load page (${error.type}): ${error.description}',
          );
          LoggerService.error(
            '[Synapse.fetchWebPage] Load error for ${request.url}: ${error.description} (${error.type})',
          );
          completer.completeError(exception);
        } else {
          LoggerService.warning(
            '[Synapse.fetchWebPage] Load error for subresource ${request.url}: ${error.description} (${error.type})',
          );
        }
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        if (completer.isCompleted) {
          return;
        }

        if (request.isForMainFrame ?? false) {
          final exception = Exception(
            'HTTP ${errorResponse.statusCode}: ${errorResponse.reasonPhrase}',
          );
          LoggerService.error(
            '[Synapse.fetchWebPage] HTTP error ${errorResponse.statusCode} for ${request.url}: ${errorResponse.reasonPhrase}',
          );
          completer.completeError(exception);
        } else {
          LoggerService.warning(
            '[Synapse.fetchWebPage] HTTP error ${errorResponse.statusCode} for subresource ${request.url}: ${errorResponse.reasonPhrase}',
          );
        }
      },
    );

    await headlessWebView.run();

    try {
      final result = await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw Exception('Timed out loading $url');
        },
      );
      return result;
    } catch (e, stackTrace) {
      final duration = DateTime.now().difference(startTime);
      LoggerService.error(
        '[Synapse.fetchWebPage] Error after ${duration.inMilliseconds}ms for $url: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      try {
        if (headlessWebView.isRunning()) {
          await headlessWebView.dispose();
        }
      } catch (e) {
        LoggerService.warning(
          '[Synapse.fetchWebPage] Error disposing headless webview: $e',
        );
      }
    }
  }

  // Parse AI response and extract code
  static Map<String, String> parseAIResponse(String response) {
    final Map<String, String> result = {'code': '', 'explanation': ''};

    // Remove leading and trailing whitespace
    String trimmed = response.trim();
    LoggerService.debug(
      'parseAIResponse: Input length: ${trimmed.length},Input preview: ${trimmed.substring(0, trimmed.length > 200 ? 200 : trimmed.length)}...',
    );

    // Look for HTML code blocks
    final htmlCodeBlockRegex = RegExp(r'```html\s*\n(.*?)\n```', dotAll: true);
    final codeBlockRegex = RegExp(r'```\s*\n(.*?)\n```', dotAll: true);

    String? code;
    if (htmlCodeBlockRegex.hasMatch(trimmed)) {
      final match = htmlCodeBlockRegex.firstMatch(trimmed);
      code = match?.group(1)?.trim();
      LoggerService.debug(
        'parseAIResponse: Found HTML code block, length: ${code?.length ?? 0}',
      );
    } else if (codeBlockRegex.hasMatch(trimmed)) {
      final match = codeBlockRegex.firstMatch(trimmed);
      code = match?.group(1)?.trim();
      LoggerService.debug(
        'parseAIResponse: Found generic code block, length: ${code?.length ?? 0}',
      );
    } else {
      LoggerService.debug('parseAIResponse: No code blocks found');
    }

    if (code != null && code.isNotEmpty) {
      result['code'] = code;
      // Remove the code block from the response to get the explanation
      result['explanation'] = trimmed
          .replaceAll(htmlCodeBlockRegex, '')
          .replaceAll(codeBlockRegex, '')
          .trim();
    } else {
      // If no code blocks found, treat the entire response as explanation
      result['explanation'] = trimmed;
    }

    LoggerService.debug(
      'parseAIResponse: Result - code length: ${result['code']?.length ?? 0}, explanation length: ${result['explanation']?.length ?? 0}',
    );
    return result;
  }

  // Download and store libraries for a user app
  static Future<void> _downloadAndStoreLibraries(
    UserApp app,
    AppRevision revision,
    List<UserAppLibraryInfo> libraries,
  ) async {
    try {
      LoggerService.info(
        'Downloading ${libraries.length} libraries for app ${app.name}',
      );

      final libraryService = UserAppLibraryService();

      // Get revision number from revision ID
      final revisionNumber = revision.revisionNumber;

      for (final libraryInfo in libraries) {
        if (libraryInfo.name.trim().isEmpty || libraryInfo.links.isEmpty) {
          LoggerService.warning(
            'Skipping library with empty name or no links: ${libraryInfo.name}',
          );
          continue;
        }

        LoggerService.info('Processing library: ${libraryInfo.name}');

        // Download each library link
        final dependencies = <LibraryDependency>[];

        for (final link in libraryInfo.links) {
          if (link.trim().isEmpty) continue;

          try {
            LoggerService.debug('Downloading library file: $link');

            final response = await NetworkProvider.get(Uri.parse(link));
            if (response.statusCode == 200) {
              // Process the URL to get the local path
              final localPath = _processLibraryUrl(link);

              dependencies.add(
                LibraryDependency(
                  originalUrl: link,
                  localPath: localPath,
                  bytes: response.bodyBytes,
                ),
              );

              LoggerService.debug(
                'Downloaded: $link -> $localPath (${response.bodyBytes.length} bytes)',
              );
            } else {
              LoggerService.warning(
                'Failed to download $link: HTTP ${response.statusCode}',
              );
            }
          } catch (e) {
            LoggerService.error('Error downloading $link: $e');
          }
        }

        if (dependencies.isNotEmpty) {
          // Add the library to the database
          await libraryService.addLibrary(
            appUuid: app.uuid,
            revisionId: revisionNumber,
            name: libraryInfo.name,
            usageInstructions: libraryInfo.usage,
            dependencies: dependencies,
          );

          LoggerService.info(
            'Successfully added library: ${libraryInfo.name} with ${dependencies.length} dependencies',
          );
        } else {
          LoggerService.warning(
            'No dependencies downloaded for library: ${libraryInfo.name}',
          );
        }
      }

      LoggerService.info('Completed downloading libraries for app ${app.name}');
    } catch (e) {
      LoggerService.error('Error downloading libraries: $e', error: e);
      // Don't rethrow - library download failure shouldn't prevent app creation
    }
  }

  // Process library URL to extract local path
  static String _processLibraryUrl(String url) {
    try {
      final uri = Uri.parse(url);

      // Remove the scheme and host, keep the path
      // Example: https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js -> /npm/mermaid@11/dist/mermaid.min.js
      var path = uri.path;

      // Ensure path starts with /
      if (!path.startsWith('/')) {
        path = '/$path';
      }

      return path;
    } catch (e) {
      LoggerService.error('Error processing library URL $url: $e');
      // Fallback to using the full URL as path
      return Uri.parse(url).path;
    }
  }

  // Clone a user app
  Future<UserApp> cloneUserApp(UserApp originalApp) async {
    try {
      LoggerService.info('Cloning user app: ${originalApp.name}');

      // Get the selected revision from the original app
      AppRevision? selectedRevision;
      if (originalApp.selectedRevisionId != null) {
        selectedRevision = await getAppRevision(
          originalApp.selectedRevisionId!,
        );
      }

      if (selectedRevision == null) {
        throw Exception(
          'No selected revision found for app: ${originalApp.id}',
        );
      }

      // Create new app with new UUID and ID
      final newApp = UserApp(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        uuid: const Uuid().v4(),
        name: '${originalApp.name} (Copy)',
        description: originalApp.description,
        steps: List<String>.from(originalApp.steps),
        htmlContent: '', // Will be set from revision
        type: originalApp.type,
        author: originalApp.author,
        license: originalApp.license,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        libraries: originalApp.libraries != null
            ? List<UserAppLibraryInfo>.from(originalApp.libraries!)
            : null,
      );

      // Save the new app
      await saveUserApp(newApp);

      // Create a new revision with the selected revision's content
      final newRevision = AppRevision(
        id: '${DateTime.now().millisecondsSinceEpoch}_rev',
        appId: newApp.id,
        revisionNumber: 1,
        revisionTimestamp: DateTime.now(),
        userPrompt: 'Cloned from ${originalApp.name}',
        aiResponse:
            'This app was cloned from the selected revision of "${originalApp.name}".',
        appCode: selectedRevision.appCode,
        attachmentPaths: List<String>.from(selectedRevision.attachmentPaths),
      );

      // Save the new revision
      await _databaseService.insertAppRevision(newRevision);

      // Update the app with the selected revision
      final updatedApp = newApp.copyWith(selectedRevisionId: newRevision.id);
      await _databaseService.updateUserApp(updatedApp);

      // Copy libraries if they exist
      LoggerService.debug(
        'Checking for libraries in original app: ${originalApp.name}',
      );
      LoggerService.debug(
        'Original app libraries field: ${originalApp.libraries?.length ?? 0}',
      );

      try {
        LoggerService.info('Copying libraries for cloned app: ${newApp.name}');
        final libraryService = UserAppLibraryService();

        // Get libraries from the original app's selected revision
        final sourceLibraries = await libraryService.getLibraries(
          originalApp.uuid,
          selectedRevision.revisionNumber,
        );

        LoggerService.debug(
          'Found ${sourceLibraries.length} libraries in source revision ${selectedRevision.revisionNumber}',
        );

        if (sourceLibraries.isNotEmpty) {
          // Copy each library to the new app
          for (final library in sourceLibraries) {
            LoggerService.debug(
              'Copying library: ${library.name} (ID: ${library.id})',
            );

            // Get all dependencies for this library
            final dependencies = await libraryService.getDependencies(
              library.id,
            );
            LoggerService.debug(
              'Found ${dependencies.length} dependencies for library ${library.name}',
            );

            // Convert UserAppLibraryDependency to LibraryDependency
            final libraryDependencies = dependencies
                .map(
                  (dep) => LibraryDependency(
                    originalUrl: dep.originalUrl,
                    localPath: dep.localPath,
                    bytes: dep.bytes,
                  ),
                )
                .toList();

            // Create the library in the new app
            await libraryService.addLibrary(
              appUuid: newApp.uuid,
              revisionId: 1, // New app starts with revision 1
              name: library.name,
              usageInstructions: library.usageInstructions,
              dependencies: libraryDependencies,
            );
          }

          LoggerService.info(
            'Successfully copied ${sourceLibraries.length} libraries for cloned app',
          );
        } else {
          LoggerService.debug(
            'No libraries found in source revision ${selectedRevision.revisionNumber} for app ${originalApp.uuid}',
          );
        }
      } catch (e) {
        LoggerService.warning('Failed to copy libraries for cloned app: $e');
        // Don't rethrow - the clone should still succeed
      }

      LoggerService.info(
        'Successfully cloned user app: ${originalApp.name} -> ${newApp.name}',
      );
      return updatedApp;
    } catch (e) {
      LoggerService.error('Error cloning user app: $e', error: e);
      rethrow;
    }
  }

  @visibleForTesting
  static String testBuildApiDocumentationSection() => _buildApiDocumentationSection();
  @visibleForTesting
  static String testBuildRequirementsSection() => _buildRequirementsSection();
  @visibleForTesting
  static String testGetNoteActionAppInstructions() => _getNoteActionAppInstructions();
  @visibleForTesting
  static String testGetAiToolAppInstructions() => _getAiToolAppInstructions();
  @visibleForTesting
  static String testBuildAppGenerationPrompt(
    String name,
    String description,
    List<String> steps,
    UserAppType type, {
    List<UserAppLibraryInfo>? libraries,
    String? noteContext,
  }) => _buildAppGenerationPrompt(
        name, description, steps, type,
        libraries: libraries, noteContext: noteContext,
      );
}

class _NoteContextPayload {
  final String? text;
  final List<PlatformFile> attachments;

  const _NoteContextPayload({this.text, this.attachments = const []});
}
