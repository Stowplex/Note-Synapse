import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import '../models/user_app.dart';
import '../models/app_revision.dart';
import 'ai_service.dart';
import 'database_service.dart';
import 'logger_service.dart';
import 'user_app_library_service.dart';

class UserAppService {
  
  // Get all user apps
  static Future<List<UserApp>> getAllUserApps() async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.getAllUserApps();
    } catch (e) {
      LoggerService.error('Error loading user apps: $e', error: e);
      return [];
    }
  }
  
  // Save a user app
  static Future<void> saveUserApp(UserApp app) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.insertUserApp(app);
    } catch (e) {
      LoggerService.error('Error saving user app: $e', error: e);
      rethrow;
    }
  }
  
  // Update a user app
  static Future<void> updateUserApp(UserApp app) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.updateUserApp(app);
    } catch (e) {
      LoggerService.error('Error updating user app: $e', error: e);
      rethrow;
    }
  }
  
  // Delete a user app
  static Future<void> deleteUserApp(String appId) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.deleteUserApp(appId);
    } catch (e) {
      LoggerService.error('Error deleting user app: $e', error: e);
      rethrow;
    }
  }
  
  // Get app state
  static Future<Map<String, dynamic>?> getAppState(String appId) async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.getUserAppState(appId);
    } catch (e) {
      LoggerService.error('Error loading app state: $e', error: e);
      return null;
    }
  }
  
  // Save app state
  static Future<void> saveAppState(String appId, Map<String, dynamic> state) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.updateUserAppState(appId, state);
    } catch (e) {
      LoggerService.error('Error saving app state: $e', error: e);
      rethrow;
    }
  }

  // App Revisions management
  static Future<List<AppRevision>> getAppRevisions(String appId) async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.getAppRevisions(appId);
    } catch (e) {
      LoggerService.error('Error loading app revisions: $e', error: e);
      return [];
    }
  }

  static Future<AppRevision?> getAppRevision(String revisionId) async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.getAppRevision(revisionId);
    } catch (e) {
      LoggerService.error('Error loading app revision: $e', error: e);
      return null;
    }
  }

  static Future<void> deleteAppRevision(String revisionId) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.deleteAppRevision(revisionId);
    } catch (e) {
      LoggerService.error('Error deleting app revision: $e', error: e);
      rethrow;
    }
  }

  static Future<void> setSelectedRevision(String appId, String revisionId) async {
    try {
      final databaseService = DatabaseService();
      final app = await databaseService.getUserApp(appId);
      if (app != null) {
        final updatedApp = app.copyWith(selectedRevisionId: revisionId);
        await databaseService.updateUserApp(updatedApp);
      }
    } catch (e) {
      LoggerService.error('Error setting selected revision: $e', error: e);
      rethrow;
    }
  }

  // Create initial revision for apps that don't have any revisions yet
  static Future<AppRevision> createInitialRevision(String appId) async {
    try {
      final databaseService = DatabaseService();
      final app = await databaseService.getUserApp(appId);
      if (app == null) {
        throw Exception('App not found: $appId');
      }

      // Check if app already has revisions
      final existingRevisions = await databaseService.getAppRevisions(appId);
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
      await databaseService.insertAppRevision(revision);

      // Update the app to set the selected revision
      final updatedApp = app.copyWith(selectedRevisionId: revision.id);
      await databaseService.updateUserApp(updatedApp);

      return revision;
    } catch (e) {
      LoggerService.error('Error creating initial revision: $e', error: e);
      rethrow;
    }
  }
  
  
  // Create a new user app using AI
  static Future<UserApp> createUserApp({
    required String name,
    required String description,
    required List<String> steps,
    UserAppType type = UserAppType.normal,
    String? userPrompt,
    List<String>? attachmentPaths,
    List<UserAppLibraryInfo>? libraries,
  }) async {
    try {
      // Generate the app using AI
      final aiResponse = await _generateAppWithAI(name, description, steps, type, attachmentPaths: attachmentPaths, libraries: libraries);
      
      // Parse the AI response to extract code and explanation
      final parsedResponse = parseAIResponse(aiResponse);
      final htmlContent = parsedResponse['code']?.isNotEmpty == true ? parsedResponse['code']! : aiResponse;
      final explanation = parsedResponse['explanation']?.isNotEmpty == true ? parsedResponse['explanation']! : '';
      
      LoggerService.debug('createUserApp: Parsed response - code length: ${parsedResponse['code']?.length ?? 0}, explanation length: ${parsedResponse['explanation']?.length ?? 0}');
      LoggerService.debug('createUserApp: Using parsed code: ${parsedResponse['code']?.isNotEmpty == true}');
      LoggerService.debug('createUserApp: Final htmlContent length: ${htmlContent.length}');
      LoggerService.debug('createUserApp: Final explanation length: ${explanation.length}');
      
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
      final databaseService = DatabaseService();
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
      LoggerService.debug('Revision aiResponse length: ${revision.aiResponse.length}');
      LoggerService.debug('Revision appCode length: ${revision.appCode.length}');
      LoggerService.debug('Revision appCode preview: ${revision.appCode.substring(0, revision.appCode.length > 200 ? 200 : revision.appCode.length)}...');
      
      await databaseService.insertAppRevision(revision);
      
      // Update app with selected revision
      final updatedApp = app.copyWith(selectedRevisionId: revision.id);
      await databaseService.updateUserApp(updatedApp);
      LoggerService.debug('Updated app with selectedRevisionId: ${updatedApp.selectedRevisionId}');
      
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
  static Future<AppRevision> saveManualCodeEdit({
    required UserApp originalApp,
    required String newCode,
    List<String>? attachmentPaths,
  }) async {
    try {
      // Get the next revision number
      final databaseService = DatabaseService();
      final revisionNumber = await databaseService.getNextRevisionNumber(originalApp.id);
      
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
      await databaseService.insertAppRevision(revision);
      
      // Copy dependencies from the current revision to the new revision
      if (originalApp.selectedRevisionId != null) {
        try {
          LoggerService.debug('Manual edit: Copying dependencies from revision ${originalApp.selectedRevisionId}');
          final currentRevision = await databaseService.getAppRevision(originalApp.selectedRevisionId!);
          if (currentRevision != null) {
            LoggerService.debug('Manual edit: Found current revision ${currentRevision.id} with revision number ${currentRevision.revisionNumber}');
            final libraryService = UserAppLibraryService();
            await libraryService.copyLibrariesToRevision(
              appUuid: originalApp.uuid,
              fromRevisionId: currentRevision.revisionNumber,
              toRevisionId: revisionNumber,
            );
            LoggerService.debug('Manual edit: Successfully copied dependencies to revision $revisionNumber');
          } else {
            LoggerService.warning('Manual edit: Current revision not found: ${originalApp.selectedRevisionId}');
          }
        } catch (e) {
          LoggerService.warning('Failed to copy dependencies for manual edit: $e');
          // Don't rethrow - the revision creation should still succeed
        }
      } else {
        LoggerService.warning('Manual edit: No selectedRevisionId found in originalApp');
      }
      
      // Update the app's selected revision (but NOT the htmlContent)
      final updatedApp = originalApp.copyWith(
        selectedRevisionId: revision.id,
        updatedAt: DateTime.now(),
      );
      await databaseService.updateUserApp(updatedApp);
      
      return revision;
    } catch (e) {
      LoggerService.error('Error saving manual code edit: $e', error: e);
      rethrow;
    }
  }

  // Edit an existing app by creating a new revision
  static Future<AppRevision> editUserApp({
    required UserApp originalApp,
    required String editSuggestion,
    List<String>? attachmentPaths,
    List<UserAppLibraryInfo>? libraries,
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
        libraries: libraries,
      );
      
      // Parse the AI response to extract code and explanation
      final parsedResponse = parseAIResponse(aiResponse);
      final newHtmlContent = parsedResponse['code'] ?? originalApp.htmlContent;
      final explanation = parsedResponse['explanation'] ?? '';
      
      // Get the next revision number
      final databaseService = DatabaseService();
      final revisionNumber = await databaseService.getNextRevisionNumber(originalApp.id);
      
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
      await databaseService.insertAppRevision(revision);
      
      // Download and store libraries if provided
      if (libraries != null && libraries.isNotEmpty) {
        await _downloadAndStoreLibraries(originalApp, revision, libraries);
      }
      
      // Copy dependencies from the current revision to the new revision
      if (originalApp.selectedRevisionId != null) {
        try {
          LoggerService.debug('AI edit: Copying dependencies from revision ${originalApp.selectedRevisionId}');
          final currentRevision = await databaseService.getAppRevision(originalApp.selectedRevisionId!);
          if (currentRevision != null) {
            LoggerService.debug('AI edit: Found current revision ${currentRevision.id} with revision number ${currentRevision.revisionNumber}');
            final libraryService = UserAppLibraryService();
            await libraryService.copyLibrariesToRevision(
              appUuid: originalApp.uuid,
              fromRevisionId: currentRevision.revisionNumber,
              toRevisionId: revisionNumber,
            );
            LoggerService.debug('AI edit: Successfully copied dependencies to revision $revisionNumber');
          } else {
            LoggerService.warning('AI edit: Current revision not found: ${originalApp.selectedRevisionId}');
          }
        } catch (e) {
          LoggerService.warning('Failed to copy dependencies for AI edit: $e');
          // Don't rethrow - the revision creation should still succeed
        }
      } else {
        LoggerService.warning('AI edit: No selectedRevisionId found in originalApp');
      }
      
      // Update the app's selected revision (but NOT the htmlContent)
      final updatedApp = originalApp.copyWith(
        selectedRevisionId: revision.id,
        updatedAt: DateTime.now(),
      );
      await databaseService.updateUserApp(updatedApp);
      
      return revision;
    } catch (e) {
      LoggerService.error('Error editing user app: $e', error: e);
      rethrow;
    }
  }
  
  // Generate app HTML using AI
  static Future<String> _generateAppWithAI(String name, String description, List<String> steps, UserAppType type, {List<String>? attachmentPaths, List<UserAppLibraryInfo>? libraries}) async {
    try {
      final prompt = _buildAppGenerationPrompt(name, description, steps, type, libraries: libraries);
      
      // Convert attachment paths to PlatformFile objects for the AI service
      List<PlatformFile>? attachedFiles;
      if (attachmentPaths != null && attachmentPaths.isNotEmpty) {
        attachedFiles = [];
        for (final path in attachmentPaths) {
          final file = File(path);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            final fileName = path.split('/').last;
            attachedFiles.add(PlatformFile(
              name: fileName,
              size: bytes.length,
              bytes: bytes,
              path: path,
            ));
          }
        }
      }
      
      final response = await AIService.generateAppWithAttachments(prompt, attachedFiles);
      return response; // Return the full response, let parseAIResponse handle the parsing
    } catch (e) {
      LoggerService.error('Error generating app with AI: $e', error: e);
      rethrow;
    }
  }
  
  // Generate app edit using AI
  static Future<String> _generateAppEditWithAI(
    String name,
    String description,
    List<String> steps,
    String originalHtml,
    String editSuggestion,
    UserAppType type, {
    List<String>? attachmentPaths,
    List<UserAppLibraryInfo>? libraries,
  }) async {
    try {
      final librariesSection = libraries != null && libraries.isNotEmpty ? '''
  - User-provided libraries:
${libraries.map((lib) => '''
    - ${lib.name}: ${lib.usage ?? 'No usage instructions provided'}
      Import with: ${lib.links.map((link) => link.replaceAll('https://', 'synapseuser://')).map((link) => link.endsWith('.css') ? '<link rel="stylesheet" href="$link">' : '<script src="$link"></script>').join('\n      ')}
''').join('')}
''' : '';

      final prompt = '''
Edit the following HTML application based on the user's suggestion:

Original App Name: $name
Description: $description
Steps: ${steps.join(', ')}

$librariesSection

Original HTML:
$originalHtml

User's Edit Suggestion: $editSuggestion

Database Schema (same as original):
The app has access to the following database tables:

1. NOTES table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - title (TEXT NOT NULL) - Note title
   - content (TEXT NOT NULL) - Note content
   - type (TEXT NOT NULL) - 'note' or 'task'
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp
   - scheduledAt (TEXT) - Scheduled date (for tasks)
   - completeBy (TEXT) - Due date (for tasks)
   - status (TEXT) - Task status: 'todo', 'inProgress', 'completed', 'cancelled'
   - completionPercentage (REAL) - Task completion percentage
   - pinned (INTEGER NOT NULL DEFAULT 0) - Whether note is pinned
   - isArchived (INTEGER NOT NULL DEFAULT 0) - Whether note is archived

2. SUBNOTES table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - noteId (TEXT NOT NULL) - Parent note ID
   - name (TEXT NOT NULL) - Sub-note name
   - content (TEXT NOT NULL) - Sub-note content
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - isCompleted (INTEGER NOT NULL DEFAULT 0) - Completion status

3. TAGS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - name (TEXT NOT NULL UNIQUE) - Tag name
   - color (TEXT NOT NULL) - Tag color
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - usageCount (INTEGER NOT NULL DEFAULT 0) - Usage count

4. NOTE_TAGS table (many-to-many relationship):
   - noteId (TEXT NOT NULL) - Note ID
   - tagId (TEXT NOT NULL) - Tag ID
   - PRIMARY KEY (noteId, tagId)

5. ATTACHMENTS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - noteId (TEXT NOT NULL) - Parent note ID
   - filePath (TEXT NOT NULL) - File path
   - fileName (TEXT NOT NULL) - File name
   - fileType (TEXT NOT NULL) - File type
   - isRelativePath (INTEGER NOT NULL DEFAULT 0) - Whether path is relative
   - createdAt (INTEGER NOT NULL) - Creation timestamp

6. RELATIONSHIPS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - fromNoteId (TEXT NOT NULL) - Source note ID
   - toNoteId (TEXT NOT NULL) - Target note ID
   - type (TEXT NOT NULL) - Relationship type
   - createdAt (INTEGER NOT NULL) - Creation timestamp

7. FILTERS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - name (TEXT NOT NULL) - Filter name
   - includeText (TEXT) - Text to search for
   - includeTags (TEXT NOT NULL) - JSON array of tag names
   - includeArchived (INTEGER NOT NULL DEFAULT 0) - Include archived notes
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp

8. USER_APPS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - uuid (TEXT NOT NULL) - App UUID
   - name (TEXT NOT NULL) - App name
   - description (TEXT NOT NULL) - App description
   - steps (TEXT NOT NULL) - App steps
   - htmlContent (TEXT NOT NULL) - HTML content
   - appState (TEXT) - App state JSON
   - type (TEXT NOT NULL DEFAULT 'normal') - App type
   - selectedRevisionId (TEXT) - Selected revision ID
   - author (TEXT DEFAULT "") - App author
   - license (TEXT DEFAULT "") - App license
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp

9. APP_REVISIONS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - appId (TEXT NOT NULL) - Parent app ID
   - revisionNumber (INTEGER NOT NULL) - Revision number
   - revisionTimestamp (INTEGER NOT NULL) - Revision timestamp
   - userPrompt (TEXT NOT NULL) - User prompt
   - aiResponse (TEXT NOT NULL) - AI response
   - appCode (TEXT NOT NULL) - App code
   - attachmentPaths (TEXT) - Attachment paths JSON

10. USER_APP_LIBRARIES table:
    - id (INTEGER PRIMARY KEY AUTOINCREMENT) - Unique identifier
    - app_uuid (TEXT NOT NULL) - App UUID
    - revision_id (INTEGER NOT NULL) - Revision ID
    - name (TEXT NOT NULL) - Library name
    - usage_instructions (TEXT) - Usage instructions

11. USER_APP_LIBRARY_DEPENDENCIES table:
    - id (INTEGER PRIMARY KEY AUTOINCREMENT) - Unique identifier
    - original_url (TEXT) - Original URL
    - local_path (TEXT NOT NULL) - Local path
    - bytes (BLOB NOT NULL) - File bytes
    - library_id (INTEGER NOT NULL) - Library ID

12. CONVERSATIONS table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - title (TEXT NOT NULL) - Conversation title
    - noteIds (TEXT NOT NULL DEFAULT '[]') - Associated note IDs JSON
    - createdAt (INTEGER NOT NULL) - Creation timestamp
    - updatedAt (INTEGER NOT NULL) - Last update timestamp
    - isArchived (INTEGER NOT NULL DEFAULT 0) - Whether archived

13. CONVERSATION_MESSAGES table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - type (TEXT NOT NULL) - Message type
    - content (TEXT NOT NULL) - Message content
    - timestamp (INTEGER NOT NULL) - Message timestamp
    - modelUsed (TEXT) - AI model used
    - metadata (TEXT) - Additional metadata JSON

14. CONVERSATION_ATTACHMENTS table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - messageId (TEXT NOT NULL) - Parent message ID
    - filePath (TEXT NOT NULL) - File path
    - fileName (TEXT NOT NULL) - File name
    - fileType (TEXT NOT NULL) - File type
    - isRelativePath (INTEGER NOT NULL DEFAULT 0) - Whether path is relative
    - createdAt (INTEGER NOT NULL) - Creation timestamp

15. CONVERSATION_TREE table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - treeData (TEXT NOT NULL) - Tree data JSON
    - createdAt (INTEGER NOT NULL) - Creation timestamp
    - updatedAt (INTEGER NOT NULL) - Last update timestamp

16. CONVERSATION_MESSAGE_MAPPING table:
    - id (INTEGER PRIMARY KEY AUTOINCREMENT) - Unique identifier
    - conversationId (TEXT NOT NULL) - Conversation ID
    - messageId (TEXT NOT NULL) - Message ID
    - createdAt (INTEGER NOT NULL) - Creation timestamp

17. MESSAGE_PARENTS table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - messageId (TEXT NOT NULL) - Message ID
    - parentMessageId (TEXT NOT NULL) - Parent message ID
    - createdAt (INTEGER NOT NULL) - Creation timestamp

IMPORTANT - REQUIREMENTS:
1. The HTML must be completely self-contained with embedded CSS and JavaScript
2. Do not reference any external resources unless explicitly instructed by user.
3. Document the purpose, requirements, and approach in comments
4. Use the following APIs to interact with the Flutter app, generated code should strictly follow the API parameter types.
   - Synapse.runQuery(sql: string) - Query the app's database by running the sql query
     Param format: a string of SQL query to execute
     Response format: {success: boolean, data: array, error?: string}
   - Synapse.storeAppState(state: object) - Store JSON serialized state to the app's database
     Response format: {success: boolean, error?: string}
   - Synapse.loadAppState() - Load saved JSON serialized state from the app's database
     Response format: {success: boolean, data?: object, error?: string}
   - Synapse.chatAI(prompt: string, options?: object) - Send prompt through the app's AI channel and get the response
     Param format: 
       - prompt: a string of prompt to send to the app's AI channel
       - options: optional object with the following parameters (IMPORTANT: Follow exact types):
         * temperature: number (double) between 0.0 and 1.0, controls randomness (e.g., 0.7)
         * topK: integer between 1 and 100, number of tokens to consider (e.g., 40)
         * topP: number (double) between 0.0 and 1.0, nucleus sampling parameter (e.g., 0.9)
         * attachments: array of mixed attachment types (strings or objects):
           - File path: string - Path to existing attachment (e.g., '/path/to/file1.pdf')
           - synapsetemp URI: string - URI returned by Synapse.saveTemp (e.g., 'synapsetemp:///image.png')
           - Base64 data: object with:
             * type: 'base64' (required)
             * mimeType: string (required) - MIME type (e.g., 'image/png', 'text/plain')
             * data: string (required) - Base64 encoded data (e.g., 'data:image/jpeg;base64,/9j/4AAQ...')
       Example: {temperature: 0.7, topK: 40, topP: 0.9, attachments: ['/path/to/file1.pdf', {type: 'base64', mimeType: 'image/png', data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...'}]}
     Response format: {success: boolean, response?: string, error?: string}
   - Synapse.proxyFetch(url: string, options?: object) - Perform an HTTP request via the Synapse backend proxy to bypass browser CORS restrictions (supports GET and POST).
     Options format (all fields optional):
       * method: string - HTTP method (defaults to 'GET'; set to 'POST' when sending data)
       * headers: object - Key/value pairs of request headers (values must be strings)
       * body: string - Raw text payload (used when `json` is not provided)
       * json: any - JavaScript object/array automatically JSON-encoded; takes precedence over `body`
     Response format:
       {
         status: 'success' | 'error',
         statusCode?: number,      // Present when the request reached the server
         error?: string,           // Present when status === 'error'
         content?: {
           mime: string,           // MIME type returned by the server
           data: string            // UTF-8 text when mime starts with 'text/', otherwise base64 encoded string
         }
       }
     Usage notes:
       * Passing a plain headers object as the second argument is still supported; it will be treated as `{headers: ...}`.
       * When sending JSON, the Content-Type defaults to `application/json; charset=utf-8` unless you override it.
       * When providing a text `body`, the Content-Type defaults to `text/plain; charset=utf-8` if unspecified.
       * Always handle the possibility of `status === 'error'`.
       * When `content.mime` does not start with `text/`, decode the base64 string before using binary data.
   - Synapse.readAttachment(attachmentPath: string) - Read an attachment file and return its base64 encoded data
     Param format: a string path to an attachment file (must exist in database)
     Response format: 
        {
            success: boolean,   // Whether this operation was succesful
            data?: string,      // Optional, present when successful. base64 encoded string of the raw binary data of the attachment. e.g. /9j/4AAQ...
            mimeType?: string,  // Optional, present when successful. The mimetype of the attachment.
            error?: string      // Optional, present when failed. The error message.
        }
  - Synapse.saveTemp(data: object, mimeType: string) - Store temporary content in the cache and receive a synapsetemp:/// URI
    Param format:
      * data: object with either `text` (UTF-8 string) or `binary` (base64 string, data URI supported)
      * mimeType: string - MIME type describing the data (e.g., 'image/png')
    Response format: {success: boolean, uri?: string, error?: string}
   - Synapse.saveNotes(notes: array) - Save new notes to the database (IDs and timestamps generated automatically)
     Param format: array of note objects with the following structure:
       - title: string (required) - Note title
       - content: string (required) - Note content
       - type: string (required) - 'note' or 'task'
       - subNotes: array (optional) - Array of subnote objects with:
         * name: string (required) - Subnote name
         * content: string (optional) - Subnote content
         * isCompleted: boolean (optional, default: false) - Completion status
       - attachments: array (optional) - Array of attachment objects:
         * File URI: string - Path to existing file (e.g., '/path/to/file.jpg')
        * synapsetemp URI: string - URI returned by Synapse.saveTemp (e.g., 'synapsetemp:///image.png')
         * Base64: object with:
           - type: 'base64' (required)
           - data: string (required) - Base64 encoded data (e.g., 'data:image/jpeg;base64,/9j/4AAQ...')
           - fileName: string (required) - Original filename (e.g., 'image.jpg')
       - For tasks only:
         * scheduledAt: string (optional) - ISO date string when task is scheduled to start
         * completeBy: string (optional) - ISO date string when task needs to be completed
         * status: string (optional, default: 'todo') - 'todo', 'in_progress', 'complete', 'abandoned'
         * completionPercentage: number (optional, default: 0.0) - 0.0 to 1.0
         * pinned: boolean (optional, default: false) - Whether note is pinned
         * isArchived: boolean (optional, default: false) - Whether note is archived
     Response format: {success: boolean, savedCount?: number, error?: string}
   - Synapse.openNote(noteId: string, replaceWindow: bool = false) - Open a note natively on the platform
     Param format: 
       - noteId: a string of the note ID to open
       - replaceWindow: optional boolean (default: false). If true, replaces the current view with the note view. If false, pushes the note view on top.
     Response format: {success: boolean, error?: string}

   CORRECT saveNotes Usage Examples:
   ```javascript
   // Basic note creation
   const result1 = await Synapse.saveNotes([
     {
       title: 'My Note',
       content: 'Note content',
       type: 'note',
     }
   ]);
   
   // Note with subnotes and file attachments
   const result2 = await Synapse.saveNotes([
     {
       title: 'Project Planning',
       content: 'Planning document for new project',
       type: 'note',
       subNotes: [
         {
           name: 'Research Phase',
           content: 'Gather requirements and analyze market',
           isCompleted: false
         },
         {
           name: 'Design Phase',
           content: 'Create wireframes and mockups',
           isCompleted: true
         }
       ],
       attachments: ['/path/to/existing/file.pdf']
     }
   ]);

  // Save a note using a temporary attachment created at runtime
  const tempImage = await Synapse.saveTemp({ binary: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...' }, 'image/png');
  if (tempImage.success) {
    await Synapse.saveNotes([
      {
        title: 'Whiteboard Snapshot',
        content: 'Automatically captured whiteboard image',
        type: 'note',
        attachments: [tempImage.uri]
      }
    ]);
  }
   
   // Task with base64 attachment
   const result3 = await Synapse.saveNotes([
     {
       title: 'Review Document',
       content: 'Review the attached document',
       type: 'task',
       subNotes: [
         {
           name: 'Read Document',
           content: 'Read through the entire document',
           isCompleted: false
         },
         {
           name: 'Write Summary',
           content: 'Write a summary of key points',
           isCompleted: false
         }
       ],
       attachments: [
         {
           type: 'base64',
           data: 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ...',
           fileName: 'document.jpg'
         }
       ],
       scheduledAt: '2024-01-15T09:00:00.000Z',
       completeBy: '2024-01-20T17:00:00.000Z',
       status: 'todo',
       completionPercentage: 0.0,
       pinned: true,
       isArchived: false
     }
   ]);
   ```

   CORRECT chatAI Usage Examples:
   ```javascript
   // Basic usage - no parameters
   const result1 = await Synapse.chatAI('Explain quantum computing');
   
   // With correct parameter types and mixed attachments
   const result2 = await Synapse.chatAI('Analyze this data', {
     temperature: 0.7,    // number (double) 0.0-1.0
     topK: 40,           // integer 1-100
     topP: 0.9,          // number (double) 0.0-1.0
     attachments: [      // mixed array of strings and objects
       '/path/to/file.pdf',  // file path
       {                     // base64 data object
         type: 'base64',
         mimeType: 'image/png',
         data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...'
       }
     ]
   });

  // With a temporary file created via Synapse.saveTemp
  const tempSnapshot = await Synapse.saveTemp({ binary: 'data:audio/mpeg;base64,//uQZAAAAAAAAAAA...' }, 'audio/mpeg');
  if (tempSnapshot.success) {
    const resultTemp = await Synapse.chatAI('Transcribe this snippet', {
      attachments: [tempSnapshot.uri]
    });
  }
   
   // WRONG - will cause parameter validation errors:
   // const result3 = await Synapse.chatAI('Test', {
   //   topK: 32.5,        // WRONG: topK must be integer, not double
   //   topP: 1.5,         // WRONG: topP must be 0.0-1.0
   //   temperature: "0.7" // WRONG: temperature must be number, not string
   // });
   ```

   CORRECT readAttachment Usage Examples:
   ```javascript
   // Read an attachment and get base64 data
   const result1 = await Synapse.readAttachment('/path/to/image.jpg');
   if (result1.success) {
     console.log('MIME type:', result1.mimeType);
     console.log('Base64 data:', result1.data);
     // Use the data with chatAI or saveNotes
   } else {
     console.error('Error:', result1.error);
   }
   
   // Read attachment and use with chatAI
   const attachmentResult = await Synapse.readAttachment('/path/to/document.pdf');
   if (attachmentResult.success) {
     const chatResult = await Synapse.chatAI('Analyze this document', {
       attachments: [{
         type: 'base64',
         mimeType: attachmentResult.mimeType,
         data: attachmentResult.data
       }]
     });
   }
   ```

   CORRECT openNote Usage Examples:
   ```javascript
   // Open note in a new view (push)
   const result1 = await Synapse.openNote('note-id-123');
   if (result1.success) {
     console.log('Note opened successfully');
   } else {
     console.error('Error:', result1.error);
   }
   
   // Replace current view with note view
   const result2 = await Synapse.openNote('note-id-123', true);
   if (result2.success) {
     console.log('Note opened and replaced current view');
   } else {
     console.error('Error:', result2.error);
   }
   ```

5. Libraries you can utilize:
  - You are provided with the chart.js libary (version 2.9.4). You can import it with:
    ```html
    <script src="synapse://chart.min.js"></script>
    ```
    DO NOT USE time scale due to lack of adapter.
  - You are provided with the bootstrap library (version 4.6). You can import it with:
    ```html
    <link rel="stylesheet" href="synapse://bootstrap.min.css">
    ```
  - You are provided with the highlight.js library (version 11.11.1) to highlight code. You can import it with:
    ```html
    <link rel="stylesheet" href="synapse://highlight.min.css">
    <script src="synapse://highlight.min.js"></script>
    ```
    Then you can initiating highlight for the <pre><code></code></pre> block with the following, after the code block is generated:
    ```javascript
    const codeBlock = document.getElementById('my-code-block');
    hljs.highlightBlock(codeBlock);
    ```
6. DO NOT mock Synapse or mock any data. If the API is not supported, show error message and do not proceed.
7. If the data format cannot be safely assumed between each step, lean on using Synapse.chatAI to ask AI to extract data.
   but be mindful of the latency, you should try to batch data in one request.
8. Be careful when you parse the output of AI interaction with chatAI. You should clearly require that
   the output follow a format (such as JSON), but be careful that the AI might output JSON with quotes like ```json ```,
   your code should be able to handle this.
9.  Be reminded that notes can have attachments. You should include them in chatAI if needed.
10. Prefer creating responsive layout with existing libraries over manual css.
11. Use MathML to display mathematical formulas.
12. Place adequate console logging to help tracking key steps in the code.

${type == UserAppType.noteAction ? _getNoteActionAppInstructions() : type == UserAppType.aiTool ? _getAiToolAppInstructions() : ''}

Please generate the updated HTML application that incorporates the user's suggestions while maintaining the same structure and API integrations.

IMPORTANT: Your response must be formatted as follows:
1. First, provide a brief explanation of the changes made
2. Then, provide the complete HTML code wrapped in ```html code blocks

Example format:
Here's the updated application with your requested changes:

[Brief explanation of changes]

```html
<!DOCTYPE html>
<html>
<head>
    <!-- Complete HTML code here -->
</head>
<body>
    <!-- Complete HTML code here -->
</body>
</html>
```
''';
      
      // Convert attachment paths to PlatformFile objects for the AI service
      List<PlatformFile>? attachedFiles;
      if (attachmentPaths != null && attachmentPaths.isNotEmpty) {
        attachedFiles = [];
        for (final path in attachmentPaths) {
          final file = File(path);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            final fileName = path.split('/').last;
            attachedFiles.add(PlatformFile(
              name: fileName,
              size: bytes.length,
              bytes: bytes,
              path: path,
            ));
          }
        }
      }
      
      final response = await AIService.generateAppWithAttachments(prompt, attachedFiles);
      return response; // Return the full response, let parseAIResponse handle the parsing
    } catch (e) {
      LoggerService.error('Error generating app edit with AI: $e', error: e);
      rethrow;
    }
  }
  
  // Build the app generation prompt
  static String _buildAppGenerationPrompt(String name, String description, List<String> steps, UserAppType type, {List<UserAppLibraryInfo>? libraries}) {
    final librariesSection = libraries != null && libraries.isNotEmpty ? '''
  - User-provided libraries:
${libraries.map((lib) => '''
    - ${lib.name}: ${lib.usage ?? 'No usage instructions provided'}
      Import with: ${lib.links.map((link) => link.replaceAll('https://', 'synapseuser://')).map((link) => link.endsWith('.css') ? '<link rel="stylesheet" href="$link">' : '<script src="$link"></script>').join('\n      ')}
''').join('')}
''' : '';
    
    final basePrompt = '''
Create a single-page self-contained HTML application based on the following requirements:

App Name: $name
Description: $description
Steps: 
- ${steps.join('\n - ')}

$librariesSection

IMPORTANT - REQUIREMENTS:
1. The HTML must be completely self-contained with embedded CSS and JavaScript
2. Do not reference any external resources
3. Document the purpose, requirements, and approach in comments
4. Use the following APIs to interact with the Flutter app, generated code should strictly follow the API parameter types.
   - Synapse.runQuery(sql: string) - Query the app's database by running the sql query
     Param format: a string of SQL query to execute
     Response format: {success: boolean, data: array, error?: string}
   - Synapse.storeAppState(state: object) - Store JSON serialized state to the app's database
     Response format: {success: boolean, error?: string}
   - Synapse.loadAppState() - Load saved JSON serialized state from the app's database
     Response format: {success: boolean, data?: object, error?: string}
   - Synapse.chatAI(prompt: string, options?: object) - Send prompt through the app's AI channel and get the response
     Param format: 
       - prompt: a string of prompt to send to the app's AI channel
       - options: optional object with the following parameters (IMPORTANT: Follow exact types):
         * temperature: number (double) between 0.0 and 1.0, controls randomness (e.g., 0.7)
         * topK: integer between 1 and 100, number of tokens to consider (e.g., 40)
         * topP: number (double) between 0.0 and 1.0, nucleus sampling parameter (e.g., 0.9)
         * attachments: array of mixed attachment types (strings or objects):
           - File path: string - Path to existing attachment (e.g., '/path/to/file1.pdf')
          - synapsetemp URI: string - URI returned by Synapse.saveTemp (e.g., 'synapsetemp:///image.png')
           - Base64 data: object with:
             * type: 'base64' (required)
             * mimeType: string (required) - MIME type (e.g., 'image/png', 'text/plain')
             * data: string (required) - Base64 encoded data (e.g., 'data:image/jpeg;base64,/9j/4AAQ...')
       Example: {temperature: 0.7, topK: 40, topP: 0.9, attachments: ['/path/to/file1.pdf', {type: 'base64', mimeType: 'image/png', data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...'}]}
     Response format: {success: boolean, response?: string, error?: string}
   - Synapse.proxyFetch(url: string, options?: object) - Perform an HTTP request via the Synapse backend proxy to bypass browser CORS restrictions (supports GET and POST).
     Options format (all fields optional):
       * method: string - HTTP method (defaults to 'GET'; set to 'POST' when sending data)
       * headers: object - Key/value pairs of request headers (values must be strings)
       * body: string - Raw text payload (used when `json` is not provided)
       * json: any - JavaScript object/array automatically JSON-encoded; takes precedence over `body`
     Response format:
       {
         status: 'success' | 'error',
         statusCode?: number,      // Present when the request reached the server
         error?: string,           // Present when status === 'error'
         content?: {
           mime: string,           // MIME type returned by the server
           data: string            // UTF-8 text when mime starts with 'text/', otherwise base64 encoded string
         }
       }
     Usage notes:
       * Passing a plain headers object as the second argument is still supported; it will be treated as `{headers: ...}`.
       * When sending JSON, the Content-Type defaults to `application/json; charset=utf-8` unless you override it.
       * When providing a text `body`, the Content-Type defaults to `text/plain; charset=utf-8` if unspecified.
       * Always handle the possibility of `status === 'error'`.
       * When `content.mime` does not start with `text/`, decode the base64 string before using binary data.
   - Synapse.readAttachment(attachmentPath: string) - Read an attachment file and return its base64 encoded data
     Param format: a string path to an attachment file (must exist in database)
     Response format:
        {
            success: boolean,   // Whether this operation was succesful
            data?: string,      // Optional, present when successful. base64 encoded string of the raw binary data of the attachment. e.g. /9j/4AAQ...
            mimeType?: string,  // Optional, present when successful. The mimetype of the attachment.
            error?: string      // Optional, present when failed. The error message.
        }
  - Synapse.saveTemp(data: object, mimeType: string) - Store temporary content in the cache and receive a synapsetemp:/// URI
    Param format:
      * data: object with either `text` (UTF-8 string) or `binary` (base64 string, data URI supported)
      * mimeType: string - MIME type describing the data (e.g., 'image/png')
    Response format: {success: boolean, uri?: string, error?: string}
   - Synapse.saveNotes(notes: array) - Save new notes to the database (IDs and timestamps generated automatically)
     Param format: array of note objects with the following structure:
       - title: string (required) - Note title
       - content: string (required) - Note content
       - type: string (required) - 'note' or 'task'
       - subNotes: array (optional) - Array of subnote objects with:
         * name: string (required) - Subnote name
         * content: string (optional) - Subnote content
         * isCompleted: boolean (optional, default: false) - Completion status
       - attachments: array (optional) - Array of attachment objects:
         * File URI: string - Path to existing file (e.g., '/path/to/file.jpg')
        * synapsetemp URI: string - URI returned by Synapse.saveTemp (e.g., 'synapsetemp:///image.png')
         * Base64: object with:
           - type: 'base64' (required)
           - data: string (required) - Base64 encoded data (e.g., 'data:image/jpeg;base64,/9j/4AAQ...')
           - fileName: string (required) - Original filename (e.g., 'image.jpg')
       - For tasks only:
         * scheduledAt: string (optional) - ISO date string when task is scheduled to start
         * completeBy: string (optional) - ISO date string when task needs to be completed
         * status: string (optional, default: 'todo') - 'todo', 'in_progress', 'complete', 'abandoned'
         * completionPercentage: number (optional, default: 0.0) - 0.0 to 1.0
         * pinned: boolean (optional, default: false) - Whether note is pinned
         * isArchived: boolean (optional, default: false) - Whether note is archived
     Response format: {success: boolean, savedCount?: number, error?: string}
   - Synapse.openNote(noteId: string, replaceWindow: bool = false) - Open a note natively on the platform
     Param format: 
       - noteId: a string of the note ID to open
       - replaceWindow: optional boolean (default: false). If true, replaces the current view with the note view. If false, pushes the note view on top.
     Response format: {success: boolean, error?: string}

   CORRECT saveNotes Usage Examples:
   ```javascript
   // Basic note creation
   const result1 = await Synapse.saveNotes([
     {
       title: 'My Note',
       content: 'Note content',
       type: 'note',
     }
   ]);
   
   // Note with subnotes and file attachments
   const result2 = await Synapse.saveNotes([
     {
       title: 'Project Planning',
       content: 'Planning document for new project',
       type: 'note',
       subNotes: [
         {
           name: 'Research Phase',
           content: 'Gather requirements and analyze market',
           isCompleted: false
         },
         {
           name: 'Design Phase',
           content: 'Create wireframes and mockups',
           isCompleted: true
         }
       ],
       attachments: ['/path/to/existing/file.pdf']
     }
   ]);

  // Save a note using a temporary attachment created at runtime
  const tempImage = await Synapse.saveTemp({ binary: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...' }, 'image/png');
  if (tempImage.success) {
    await Synapse.saveNotes([
      {
        title: 'Whiteboard Snapshot',
        content: 'Automatically captured whiteboard image',
        type: 'note',
        attachments: [tempImage.uri]
      }
    ]);
  }
   
   // Task with base64 attachment
   const result3 = await Synapse.saveNotes([
     {
       title: 'Review Document',
       content: 'Review the attached document',
       type: 'task',
       subNotes: [
         {
           name: 'Read Document',
           content: 'Read through the entire document',
           isCompleted: false
         },
         {
           name: 'Write Summary',
           content: 'Write a summary of key points',
           isCompleted: false
         }
       ],
       attachments: [
         {
           type: 'base64',
           data: 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ...',
           fileName: 'document.jpg'
         }
       ],
       scheduledAt: '2024-01-15T09:00:00.000Z',
       completeBy: '2024-01-20T17:00:00.000Z',
       status: 'todo',
       completionPercentage: 0.0,
       pinned: true,
       isArchived: false
     }
   ]);
   ```

   CORRECT chatAI Usage Examples:
   ```javascript
   // Basic usage - no parameters
   const result1 = await Synapse.chatAI('Explain quantum computing');
   
   // With correct parameter types and mixed attachments
   const result2 = await Synapse.chatAI('Analyze this data', {
     temperature: 0.7,    // number (double) 0.0-1.0
     topK: 40,           // integer 1-100
     topP: 0.9,          // number (double) 0.0-1.0
     attachments: [      // mixed array of strings and objects
       '/path/to/file.pdf',  // file path
       {                     // base64 data object
         type: 'base64',
         mimeType: 'image/png',
         data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...'
       }
     ]
   });

  // With a temporary file created via Synapse.saveTemp
  const tempSnapshot = await Synapse.saveTemp({ binary: 'data:audio/mpeg;base64,//uQZAAAAAAAAAAA...' }, 'audio/mpeg');
  if (tempSnapshot.success) {
    const resultTemp = await Synapse.chatAI('Transcribe this snippet', {
      attachments: [tempSnapshot.uri]
    });
  }
   
   // WRONG - will cause parameter validation errors:
   // const result3 = await Synapse.chatAI('Test', {
   //   topK: 32.5,        // WRONG: topK must be integer, not double
   //   topP: 1.5,         // WRONG: topP must be 0.0-1.0
   //   temperature: "0.7" // WRONG: temperature must be number, not string
   // });
   ```

   CORRECT readAttachment Usage Examples:
   ```javascript
   // Read an attachment and get base64 data
   const result1 = await Synapse.readAttachment('/path/to/image.jpg');
   if (result1.success) {
     console.log('MIME type:', result1.mimeType);
     console.log('Base64 data:', result1.data);
     // Use the data with chatAI or saveNotes
   } else {
     console.error('Error:', result1.error);
   }
   
   // Read attachment and use with chatAI
   const attachmentResult = await Synapse.readAttachment('/path/to/document.pdf');
   if (attachmentResult.success) {
     const chatResult = await Synapse.chatAI('Analyze this document', {
       attachments: [{
         type: 'base64',
         mimeType: attachmentResult.mimeType,
         data: attachmentResult.data
       }]
     });
   }
   ```

   CORRECT openNote Usage Examples:
   ```javascript
   // Open note in a new view (push)
   const result1 = await Synapse.openNote('note-id-123');
   if (result1.success) {
     console.log('Note opened successfully');
   } else {
     console.error('Error:', result1.error);
   }
   
   // Replace current view with note view
   const result2 = await Synapse.openNote('note-id-123', true);
   if (result2.success) {
     console.log('Note opened and replaced current view');
   } else {
     console.error('Error:', result2.error);
   }
   ```

5. Libraries you can utilize:
  - You are provided with the chart.js libary (version 2.9.4). You can import it with:
    ```html
    <script src="synapse://chart.min.js"></script>
    ```
    DO NOT USE time scale due to lack of adapter.
  - You are provided with the bootstrap library (version 4.6). You can import it with:
    ```html
    <link rel="stylesheet" href="synapse://bootstrap.min.css">
    ```
  - You are provided with the highlight.js library (version 11.11.1) to highlight code. You can import it with:
    ```html
    <link rel="stylesheet" href="synapse://highlight.min.css">
    <script src="synapse://highlight.min.js"></script>
    ```
    Then you can initiating highlight for the <pre><code></code></pre> block with the following, after the code block is generated:
    ```javascript
    const codeBlock = document.getElementById('my-code-block');
    hljs.highlightBlock(codeBlock);
    ```
6. DO NOT mock Synapse or mock any data. If the API is not supported, show error message and do not proceed.
7. If the data format cannot be safely assumed between each step, lean on using Synapse.chatAI to ask AI to extract data.
   but be mindful of the latency, you should try to batch data in one request.
8. Be careful when you parse the output of AI interaction with chatAI. You should clearly require that
   the output follow a format (such as JSON), but be careful that the AI might output JSON with quotes like ```json ```,
   your code should be able to handle this.
9.  Be reminded that notes can have attachments. You should include them in chatAI if needed.
10. Prefer creating responsive layout with existing libraries over manual css.
11. Use MathML to display mathematical formulas.
12. Place adequate console logging to help tracking key steps in the code.


Database Schema:
The app has access to the following database tables:

1. NOTES table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - title (TEXT NOT NULL) - Note title
   - content (TEXT NOT NULL) - Note content
   - type (TEXT NOT NULL) - 'note' or 'task'
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp
   - scheduledAt (TEXT) - Scheduled date (for tasks)
   - completeBy (TEXT) - Due date (for tasks)
   - status (TEXT) - Task status: 'todo', 'inProgress', 'completed', 'cancelled'
   - completionPercentage (REAL) - Task completion percentage
   - pinned (INTEGER NOT NULL DEFAULT 0) - Whether note is pinned
   - isArchived (INTEGER NOT NULL DEFAULT 0) - Whether note is archived

2. SUBNOTES table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - noteId (TEXT NOT NULL) - Parent note ID
   - name (TEXT NOT NULL) - Sub-note name
   - content (TEXT NOT NULL) - Sub-note content
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - isCompleted (INTEGER NOT NULL DEFAULT 0) - Completion status

3. TAGS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - name (TEXT NOT NULL UNIQUE) - Tag name
   - color (TEXT NOT NULL) - Tag color
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - usageCount (INTEGER NOT NULL DEFAULT 0) - Usage count

4. NOTE_TAGS table (many-to-many relationship):
   - noteId (TEXT NOT NULL) - Note ID
   - tagId (TEXT NOT NULL) - Tag ID
   - PRIMARY KEY (noteId, tagId)

5. ATTACHMENTS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - noteId (TEXT NOT NULL) - Parent note ID
   - filePath (TEXT NOT NULL) - File path
   - fileName (TEXT NOT NULL) - File name
   - fileType (TEXT NOT NULL) - File type
   - isRelativePath (INTEGER NOT NULL DEFAULT 0) - Whether path is relative
   - createdAt (INTEGER NOT NULL) - Creation timestamp

6. RELATIONSHIPS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - fromNoteId (TEXT NOT NULL) - Source note ID
   - toNoteId (TEXT NOT NULL) - Target note ID
   - type (TEXT NOT NULL) - Relationship type
   - createdAt (INTEGER NOT NULL) - Creation timestamp

7. FILTERS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - name (TEXT NOT NULL) - Filter name
   - includeText (TEXT) - Text to search for
   - includeTags (TEXT NOT NULL) - JSON array of tag names
   - includeArchived (INTEGER NOT NULL DEFAULT 0) - Include archived notes
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp

8. USER_APPS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - uuid (TEXT NOT NULL) - App UUID
   - name (TEXT NOT NULL) - App name
   - description (TEXT NOT NULL) - App description
   - steps (TEXT NOT NULL) - App steps
   - htmlContent (TEXT NOT NULL) - HTML content
   - appState (TEXT) - App state JSON
   - type (TEXT NOT NULL DEFAULT 'normal') - App type
   - selectedRevisionId (TEXT) - Selected revision ID
   - author (TEXT DEFAULT "") - App author
   - license (TEXT DEFAULT "") - App license
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp

9. APP_REVISIONS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - appId (TEXT NOT NULL) - Parent app ID
   - revisionNumber (INTEGER NOT NULL) - Revision number
   - revisionTimestamp (INTEGER NOT NULL) - Revision timestamp
   - userPrompt (TEXT NOT NULL) - User prompt
   - aiResponse (TEXT NOT NULL) - AI response
   - appCode (TEXT NOT NULL) - App code
   - attachmentPaths (TEXT) - Attachment paths JSON

10. USER_APP_LIBRARIES table:
    - id (INTEGER PRIMARY KEY AUTOINCREMENT) - Unique identifier
    - app_uuid (TEXT NOT NULL) - App UUID
    - revision_id (INTEGER NOT NULL) - Revision ID
    - name (TEXT NOT NULL) - Library name
    - usage_instructions (TEXT) - Usage instructions

11. USER_APP_LIBRARY_DEPENDENCIES table:
    - id (INTEGER PRIMARY KEY AUTOINCREMENT) - Unique identifier
    - original_url (TEXT) - Original URL
    - local_path (TEXT NOT NULL) - Local path
    - bytes (BLOB NOT NULL) - File bytes
    - library_id (INTEGER NOT NULL) - Library ID

12. CONVERSATIONS table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - title (TEXT NOT NULL) - Conversation title
    - noteIds (TEXT NOT NULL DEFAULT '[]') - Associated note IDs JSON
    - createdAt (INTEGER NOT NULL) - Creation timestamp
    - updatedAt (INTEGER NOT NULL) - Last update timestamp
    - isArchived (INTEGER NOT NULL DEFAULT 0) - Whether archived

13. CONVERSATION_MESSAGES table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - type (TEXT NOT NULL) - Message type
    - content (TEXT NOT NULL) - Message content
    - timestamp (INTEGER NOT NULL) - Message timestamp
    - modelUsed (TEXT) - AI model used
    - metadata (TEXT) - Additional metadata JSON

14. CONVERSATION_ATTACHMENTS table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - messageId (TEXT NOT NULL) - Parent message ID
    - filePath (TEXT NOT NULL) - File path
    - fileName (TEXT NOT NULL) - File name
    - fileType (TEXT NOT NULL) - File type
    - isRelativePath (INTEGER NOT NULL DEFAULT 0) - Whether path is relative
    - createdAt (INTEGER NOT NULL) - Creation timestamp

15. CONVERSATION_TREE table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - treeData (TEXT NOT NULL) - Tree data JSON
    - createdAt (INTEGER NOT NULL) - Creation timestamp
    - updatedAt (INTEGER NOT NULL) - Last update timestamp

16. CONVERSATION_MESSAGE_MAPPING table:
    - id (INTEGER PRIMARY KEY AUTOINCREMENT) - Unique identifier
    - conversationId (TEXT NOT NULL) - Conversation ID
    - messageId (TEXT NOT NULL) - Message ID
    - createdAt (INTEGER NOT NULL) - Creation timestamp

17. MESSAGE_PARENTS table:
    - id (TEXT PRIMARY KEY) - Unique identifier
    - messageId (TEXT NOT NULL) - Message ID
    - parentMessageId (TEXT NOT NULL) - Parent message ID
    - createdAt (INTEGER NOT NULL) - Creation timestamp

Example SQL queries you can use:
- SELECT * FROM notes WHERE type = 'task' AND status = 'todo'
- SELECT n.*, GROUP_CONCAT(t.name) as tags FROM notes n LEFT JOIN note_tags nt ON n.id = nt.noteId LEFT JOIN tags t ON nt.tagId = t.id GROUP BY n.id
- SELECT * FROM notes WHERE pinned = 1 ORDER BY createdAt DESC
- SELECT * FROM subnotes WHERE noteId = 'some-note-id' AND isCompleted = 0

${type == UserAppType.noteAction ? _getNoteActionAppInstructions() : type == UserAppType.aiTool ? _getAiToolAppInstructions() : ''}

Generate the complete HTML application now.

IMPORTANT: Your response must be formatted as follows:
1. First, provide a brief explanation of the application and its features
2. Then, provide the complete HTML code wrapped in ```html code blocks

Example format:
Here's the complete HTML application:

[Brief explanation of the application and its features]

```html
<!DOCTYPE html>
<html>
<head>
    <!-- Complete HTML code here -->
</head>
<body>
    <!-- Complete HTML code here -->
</body>
</html>
```
''';
    
    return basePrompt + librariesSection;
  }

  // Get Note Action App specific instructions
  static String _getNoteActionAppInstructions() {
    return '''
 NOTE ACTION APP SPECIFIC INSTRUCTIONS:
 This is a Note Action App that operates on pre-selected notes. The app will receive a list of notes through window.Synapse.Notes.

 IMPORTANT: The window.Synapse.Notes array will be pre-populated with the user's selected notes when the app runs.

 Note Object Format:
 Each note in window.Synapse.Notes has the following structure:
 {
   "id": "string",                    // Unique note identifier
   "title": "string",                 // Note title
   "content": "string",               // Note content (may contain markdown)
   "tags": ["string"],                // Array of tag names
   "createdAt": "ISO8601 string",     // Creation timestamp
   "updatedAt": "ISO8601 string",     // Last update timestamp
   "isTask": boolean,                 // Whether this is a task (true) or note (false)
   "status": "string",                // Task status: "todo", "inProgress", "completed", "cancelled" (only for tasks)
   "pinned": boolean,                 // Whether the note is pinned
   "isArchived": boolean,             // Whether the note is archived
   "attachmentPaths": ["string"]      // Array of file paths to attachments
 }

 USAGE GUIDELINES:
 1. The app should primarily work with the notes provided in window.Synapse.Notes
 2. You can access individual notes like: window.Synapse.Notes[0], window.Synapse.Notes[1], etc.
 3. You can iterate through all notes using: window.Synapse.Notes.forEach(note => { ... })
 4. The app should be designed to process, analyze, or manipulate these specific notes
 5. If you need to query the database for additional context, you can still use Synapse.runQuery()
 6. The app should clearly indicate that it's working with the selected notes
 7. Consider showing the number of notes being processed: window.Synapse.Notes.length
 8. You can display note titles, content, tags, and other properties as needed
 9. For tasks, check the isTask property and status to handle them appropriately
 10. For attachments, the attachmentPaths array contains file paths that can be used with Synapse.chatAI() if needed

 EXAMPLE USAGE:
 ```javascript
 // Check if notes are available
 if (window.Synapse.Notes && window.Synapse.Notes.length > 0) {
   console.log(`Processing \${window.Synapse.Notes.length} selected notes`);
   
   // Process each note
   window.Synapse.Notes.forEach((note, index) => {
     console.log(`Note \${index + 1}: \${note.title}`);
     console.log(`Content: \${note.content}`);
     console.log(`Tags: \${note.tags.join(', ')}`);
     console.log(`Type: \${note.isTask ? 'Task' : 'Note'}`);
     if (note.isTask) {
       console.log(`Status: \${note.status}`);
     }
   });
 } else {
   console.log('No notes selected');
 }
 ```
 ''';
  }

  // Get AI Tool App specific instructions
  static String _getAiToolAppInstructions() {
    return '''
 AI TOOL APP SPECIFIC INSTRUCTIONS:
 This application must expose reusable tools that the AI can call headlessly and that users can try in an interactive playground.

 REQUIRED STRUCTURE:
 1. Prepend the HTML with a comment block containing a YAML array describing each tool. For every tool include:
    - name: Tool identifier (string, snake_case recommended)
    - description: Concise explanation of what the tool does
    - input_params: Keys and schemas for accepted arguments (describe type, optional flag, enum values, etc.)
    - output_params: Keys and schemas for returned fields the tool produces
 2. The YAML must be valid and free of extra commentary so it can be parsed automatically.

 RUNTIME BEHAVIOUR:
 1. Register each tool implementation in JavaScript as `window.Synapse.tool.registered.<tool_name> = (params) => { ... }`.
 2. Every registered function must return a JSON-serialisable object matching the declared output parameters.
 3. Detect `window.Synapse.tool.env.isInteractive`:
    - When `true`, render a UI playground that lets the user call the tools manually (forms, buttons, result display, etc.).
    - When `false`, skip the UI and only expose the tool functions for headless execution.
 4. Use `console` logging judiciously for debugging key steps.
 5. If user's intention requires manual configurations, such as setting up an API KEY, the playground is the right place to allow the
    uesr to set it up, and save to the application state, so that in AI headless calls, it can be loaded and used.

 GENERAL REQUIREMENTS:
 - Keep the HTML fully self-contained (inline JS/CSS, or use provided Synapse user libraries only).
 - Validate user inputs, surface errors gracefully, and ensure return objects never throw.
 - Document tool usage and parameter expectations in comments or the interactive UI.
 - Use `Synapse.proxyFetch` when you must contact external HTTP APIs; remember to decode base64 results for non-text MIME types.
 ''';
  }
  
  // Check if WebView is supported on current platform
  static bool isWebViewSupported() {
    return kIsWeb || !Platform.isLinux;
  }

  // Parse AI response and extract code
  static Map<String, String> parseAIResponse(String response) {
    final Map<String, String> result = {
      'code': '',
      'explanation': '',
    };
    
    // Remove leading and trailing whitespace
    String trimmed = response.trim();
    LoggerService.debug('parseAIResponse: Input length: ${trimmed.length},Input preview: ${trimmed.substring(0, trimmed.length > 200 ? 200 : trimmed.length)}...');
    
    // Look for HTML code blocks
    final htmlCodeBlockRegex = RegExp(r'```html\s*\n(.*?)\n```', dotAll: true);
    final codeBlockRegex = RegExp(r'```\s*\n(.*?)\n```', dotAll: true);
    
    String? code;
    if (htmlCodeBlockRegex.hasMatch(trimmed)) {
      final match = htmlCodeBlockRegex.firstMatch(trimmed);
      code = match?.group(1)?.trim();
      LoggerService.debug('parseAIResponse: Found HTML code block, length: ${code?.length ?? 0}');
    } else if (codeBlockRegex.hasMatch(trimmed)) {
      final match = codeBlockRegex.firstMatch(trimmed);
      code = match?.group(1)?.trim();
      LoggerService.debug('parseAIResponse: Found generic code block, length: ${code?.length ?? 0}');
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
    
    LoggerService.debug('parseAIResponse: Result - code length: ${result['code']?.length ?? 0}, explanation length: ${result['explanation']?.length ?? 0}');
    return result;
  }

  // Download and store libraries for a user app
  static Future<void> _downloadAndStoreLibraries(UserApp app, AppRevision revision, List<UserAppLibraryInfo> libraries) async {
    try {
      LoggerService.info('Downloading ${libraries.length} libraries for app ${app.name}');
      
      final libraryService = UserAppLibraryService();
      
      // Get revision number from revision ID
      final revisionNumber = revision.revisionNumber;
      
      for (final libraryInfo in libraries) {
        if (libraryInfo.name.trim().isEmpty || libraryInfo.links.isEmpty) {
          LoggerService.warning('Skipping library with empty name or no links: ${libraryInfo.name}');
          continue;
        }
        
        LoggerService.info('Processing library: ${libraryInfo.name}');
        
        // Download each library link
        final dependencies = <LibraryDependency>[];
        
        for (final link in libraryInfo.links) {
          if (link.trim().isEmpty) continue;
          
          try {
            LoggerService.debug('Downloading library file: $link');
            
            final response = await http.get(Uri.parse(link));
            if (response.statusCode == 200) {
              // Process the URL to get the local path
              final localPath = _processLibraryUrl(link);
              
              dependencies.add(LibraryDependency(
                originalUrl: link,
                localPath: localPath,
                bytes: response.bodyBytes,
              ));
              
              LoggerService.debug('Downloaded: $link -> $localPath (${response.bodyBytes.length} bytes)');
            } else {
              LoggerService.warning('Failed to download $link: HTTP ${response.statusCode}');
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
          
          LoggerService.info('Successfully added library: ${libraryInfo.name} with ${dependencies.length} dependencies');
        } else {
          LoggerService.warning('No dependencies downloaded for library: ${libraryInfo.name}');
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
  static Future<UserApp> cloneUserApp(UserApp originalApp) async {
    try {
      LoggerService.info('Cloning user app: ${originalApp.name}');
      
      // Get the selected revision from the original app
      AppRevision? selectedRevision;
      if (originalApp.selectedRevisionId != null) {
        selectedRevision = await getAppRevision(originalApp.selectedRevisionId!);
      }
      
      if (selectedRevision == null) {
        throw Exception('No selected revision found for app: ${originalApp.id}');
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
        libraries: originalApp.libraries != null ? List<UserAppLibraryInfo>.from(originalApp.libraries!) : null,
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
        aiResponse: 'This app was cloned from the selected revision of "${originalApp.name}".',
        appCode: selectedRevision.appCode,
        attachmentPaths: List<String>.from(selectedRevision.attachmentPaths),
      );
      
      // Save the new revision
      final databaseService = DatabaseService();
      await databaseService.insertAppRevision(newRevision);
      
      // Update the app with the selected revision
      final updatedApp = newApp.copyWith(selectedRevisionId: newRevision.id);
      await databaseService.updateUserApp(updatedApp);
      
      // Copy libraries if they exist
      LoggerService.debug('Checking for libraries in original app: ${originalApp.name}');
      LoggerService.debug('Original app libraries field: ${originalApp.libraries?.length ?? 0}');
      
      try {
        LoggerService.info('Copying libraries for cloned app: ${newApp.name}');
        final libraryService = UserAppLibraryService();
        
        // Get libraries from the original app's selected revision
        final sourceLibraries = await libraryService.getLibraries(
          originalApp.uuid, 
          selectedRevision.revisionNumber
        );
        
        LoggerService.debug('Found ${sourceLibraries.length} libraries in source revision ${selectedRevision.revisionNumber}');
        
        if (sourceLibraries.isNotEmpty) {
          // Copy each library to the new app
          for (final library in sourceLibraries) {
            LoggerService.debug('Copying library: ${library.name} (ID: ${library.id})');
            
            // Get all dependencies for this library
            final dependencies = await libraryService.getDependencies(library.id);
            LoggerService.debug('Found ${dependencies.length} dependencies for library ${library.name}');
            
            // Convert UserAppLibraryDependency to LibraryDependency
            final libraryDependencies = dependencies.map((dep) => LibraryDependency(
              originalUrl: dep.originalUrl,
              localPath: dep.localPath,
              bytes: dep.bytes,
            )).toList();
            
            // Create the library in the new app
            await libraryService.addLibrary(
              appUuid: newApp.uuid,
              revisionId: 1, // New app starts with revision 1
              name: library.name,
              usageInstructions: library.usageInstructions,
              dependencies: libraryDependencies,
            );
          }
          
          LoggerService.info('Successfully copied ${sourceLibraries.length} libraries for cloned app');
        } else {
          LoggerService.debug('No libraries found in source revision ${selectedRevision.revisionNumber} for app ${originalApp.uuid}');
        }
      } catch (e) {
        LoggerService.warning('Failed to copy libraries for cloned app: $e');
        // Don't rethrow - the clone should still succeed
      }
      
      LoggerService.info('Successfully cloned user app: ${originalApp.name} -> ${newApp.name}');
      return updatedApp;
    } catch (e) {
      LoggerService.error('Error cloning user app: $e', error: e);
      rethrow;
    }
  }

}
