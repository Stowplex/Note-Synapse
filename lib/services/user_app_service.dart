import 'dart:io';
import '../models/user_app.dart';
import 'gemini_api_service.dart';
import 'database_service.dart';

class UserAppService {
  
  // Get all user apps
  static Future<List<UserApp>> getAllUserApps() async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.getAllUserApps();
    } catch (e) {
      print('Error loading user apps: $e');
      return [];
    }
  }
  
  // Save a user app
  static Future<void> saveUserApp(UserApp app) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.insertUserApp(app);
    } catch (e) {
      print('Error saving user app: $e');
      rethrow;
    }
  }
  
  // Delete a user app
  static Future<void> deleteUserApp(String appId) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.deleteUserApp(appId);
    } catch (e) {
      print('Error deleting user app: $e');
      rethrow;
    }
  }
  
  // Get app state
  static Future<Map<String, dynamic>?> getAppState(String appId) async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.getUserAppState(appId);
    } catch (e) {
      print('Error loading app state: $e');
      return null;
    }
  }
  
  // Save app state
  static Future<void> saveAppState(String appId, Map<String, dynamic> state) async {
    try {
      final databaseService = DatabaseService();
      await databaseService.updateUserAppState(appId, state);
    } catch (e) {
      print('Error saving app state: $e');
      rethrow;
    }
  }
  
  
  // Create a new user app using AI
  static Future<UserApp> createUserApp({
    required String name,
    required String description,
    required List<String> steps,
  }) async {
    try {
      // Generate the app using AI
      final htmlContent = await _generateAppWithAI(name, description, steps);
      
      final app = UserApp(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        description: description,
        steps: steps,
        htmlContent: htmlContent,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      
      await saveUserApp(app);
      return app;
    } catch (e) {
      print('Error creating user app: $e');
      rethrow;
    }
  }
  
  
  // Edit an existing app
  static Future<UserApp> editUserApp({
    required UserApp originalApp,
    required String editSuggestion,
  }) async {
    try {
      // Generate new app based on original and edit suggestion
      final newHtmlContent = await _generateAppEditWithAI(
        originalApp.name,
        originalApp.description,
        originalApp.steps,
        originalApp.htmlContent,
        editSuggestion,
      );
      
      final editedApp = UserApp(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: '${originalApp.name} - ${DateTime.now().toString().substring(0, 16)}',
        description: originalApp.description,
        steps: originalApp.steps,
        htmlContent: newHtmlContent,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      
      await saveUserApp(editedApp);
      return editedApp;
    } catch (e) {
      print('Error editing user app: $e');
      rethrow;
    }
  }
  
  // Generate app HTML using AI
  static Future<String> _generateAppWithAI(String name, String description, List<String> steps) async {
    try {
      final prompt = _buildAppGenerationPrompt(name, description, steps);
      final response = await GeminiApiService.generateApp(prompt);
      return _trimMarkdownCodeBlocks(response);
    } catch (e) {
      print('Error generating app with AI: $e');
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
  ) async {
    try {
      final prompt = '''
Edit the following HTML application based on the user's suggestion:

Original App Name: $name
Description: $description
Steps: ${steps.join(', ')}

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
   - createdAt (INTEGER NOT NULL) - Creation timestamp

6. RELATIONSHIPS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - fromNoteId (TEXT NOT NULL) - Source note ID
   - toNoteId (TEXT NOT NULL) - Target note ID
   - type (TEXT NOT NULL) - Relationship type
   - createdAt (INTEGER NOT NULL) - Creation timestamp

7. AI_INTERACTIONS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - type (TEXT NOT NULL) - Interaction type
   - prompt (TEXT NOT NULL) - User prompt
   - response (TEXT NOT NULL) - AI response
   - contextNoteIds (TEXT NOT NULL) - JSON array of context note IDs
   - transformedNoteId (TEXT) - Transformed note ID
   - createdNoteIds (TEXT) - JSON array of created note IDs
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - expiresAt (INTEGER NOT NULL) - Expiration timestamp

8. FILTERS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - name (TEXT NOT NULL) - Filter name
   - includeText (TEXT) - Text to search for
   - includeTags (TEXT NOT NULL) - JSON array of tag names
   - includeArchived (INTEGER NOT NULL DEFAULT 0) - Include archived notes
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp

Available APIs:
- Synapse.runQuery(sql: string) - Query the app's database by running the sql query
  Response format: {success: boolean, data: array, error?: string}
- Synapse.storeAppState(state: object) - Store JSON serialized state to the app's database
  Response format: {success: boolean, error?: string}
- Synapse.loadAppState() - Load saved JSON serialized state from the app's database
  Response format: {success: boolean, data?: object, error?: string}
- Synapse.chatAI(prompt: string) - Send prompt through the app's AI channel and get the response
  Response format: {success: boolean, response?: string, error?: string}

Please generate the updated HTML application that incorporates the user's suggestions while maintaining the same structure and API integrations.
''';
      
      final response = await GeminiApiService.generateApp(prompt);
      return _trimMarkdownCodeBlocks(response);
    } catch (e) {
      print('Error generating app edit with AI: $e');
      rethrow;
    }
  }
  
  // Build the app generation prompt
  static String _buildAppGenerationPrompt(String name, String description, List<String> steps) {
    return '''
Create a single-page self-contained HTML application based on the following requirements:

App Name: $name
Description: $description
Steps: 
- ${steps.join('\n - ')}

IMPORTANT - REQUIREMENTS:
1. The HTML must be completely self-contained with embedded CSS and JavaScript
2. Do not reference any external resources
3. Document the purpose, requirements, and approach in comments
4. Use the following APIs to interact with the Flutter app, genereated code should strictly follow the API parameter types.
   - Synapse.runQuery(sql: string) - Query the app's database by running the sql query
     Response format: {success: boolean, data: array, error?: string}
   - Synapse.storeAppState(state: object) - Store JSON serialized state to the app's database
     Response format: {success: boolean, error?: string}
   - Synapse.loadAppState() - Load saved JSON serialized state from the app's database
     Response format: {success: boolean, data?: object, error?: string}
   - Synapse.chatAI(prompt: string) - Send prompt through the app's AI channel and get the response
     Response format: {success: boolean, response?: string, error?: string}
5. DO NOT mock Synapse or mock any data. If the API is not supported, show error message and do not proceed.
6. If the data format cannot be safely assumed between each step, lean on using Synapse.chatAI to ask AI to extract data.
   but be mindful of the latency, you should try to batch data in one request.

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
   - createdAt (INTEGER NOT NULL) - Creation timestamp

6. RELATIONSHIPS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - fromNoteId (TEXT NOT NULL) - Source note ID
   - toNoteId (TEXT NOT NULL) - Target note ID
   - type (TEXT NOT NULL) - Relationship type
   - createdAt (INTEGER NOT NULL) - Creation timestamp

7. AI_INTERACTIONS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - type (TEXT NOT NULL) - Interaction type
   - prompt (TEXT NOT NULL) - User prompt
   - response (TEXT NOT NULL) - AI response
   - contextNoteIds (TEXT NOT NULL) - JSON array of context note IDs
   - transformedNoteId (TEXT) - Transformed note ID
   - createdNoteIds (TEXT) - JSON array of created note IDs
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - expiresAt (INTEGER NOT NULL) - Expiration timestamp

8. FILTERS table:
   - id (TEXT PRIMARY KEY) - Unique identifier
   - name (TEXT NOT NULL) - Filter name
   - includeText (TEXT) - Text to search for
   - includeTags (TEXT NOT NULL) - JSON array of tag names
   - includeArchived (INTEGER NOT NULL DEFAULT 0) - Include archived notes
   - createdAt (INTEGER NOT NULL) - Creation timestamp
   - updatedAt (INTEGER NOT NULL) - Last update timestamp

Example SQL queries you can use:
- SELECT * FROM notes WHERE type = 'task' AND status = 'todo'
- SELECT n.*, GROUP_CONCAT(t.name) as tags FROM notes n LEFT JOIN note_tags nt ON n.id = nt.noteId LEFT JOIN tags t ON nt.tagId = t.id GROUP BY n.id
- SELECT * FROM notes WHERE pinned = 1 ORDER BY createdAt DESC
- SELECT * FROM subnotes WHERE noteId = 'some-note-id' AND isCompleted = 0

Generate the complete HTML application now.
''';
  }
  
  // Check if WebView is supported on current platform
  static bool isWebViewSupported() {
    return !Platform.isLinux;
  }

  // Trim markdown code blocks from AI response
  static String _trimMarkdownCodeBlocks(String response) {
    // Remove leading and trailing whitespace
    String trimmed = response.trim();
    
    // Remove markdown code block markers
    if (trimmed.startsWith('```html')) {
      trimmed = trimmed.substring(7); // Remove '```html'
    } else if (trimmed.startsWith('```')) {
      trimmed = trimmed.substring(3); // Remove '```'
    }
    
    if (trimmed.endsWith('```')) {
      trimmed = trimmed.substring(0, trimmed.length - 3); // Remove trailing '```'
    }
    
    // Remove any remaining leading/trailing whitespace
    return trimmed.trim();
  }
}
