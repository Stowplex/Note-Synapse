# Note Synapse User Manual

## Table of Contents

1. [Setup](#setup)
2. [Notes](#notes)
3. [Chat](#chat)
4. [User App](#user-app)
5. [Settings](#settings)

---

## Setup

### How to Set Up API Key

1. When you first launch the app, you'll be prompted to enter an API key.
2. Alternatively, navigate to **Settings** → **AI API** → **API Key**.
3. Enter your API key in the provided field.
4. Click the key icon or "Get API Key" button to open the API key provider's website in your browser.
5. The API key is securely stored and will be used for all AI operations.

> **Note:** You can configure multiple AI models with different API keys. Go to **Settings** → **AI API** → **Model Configuration** to add or change models.

---

## Notes

### How to Create a Note

#### Manually from Text, Image, Attachment

1. From the main screen, tap the **+** (plus) button or the "Create Note" button.
2. **For text notes:**
   - Enter a title and content in the note editor.
   - Tap **Save** to create the note.
3. **For image notes:**
   - Tap the image icon in the toolbar.
   - Choose **Take Photo** or **Pick from Gallery**.
   - The image will be attached to a new note automatically.
4. **For file attachments:**
   - Tap the attachment icon in the toolbar.
   - Select a file from your device.
   - The file will be attached to a new note automatically.

> **Image Placeholder:** [Screenshot of main screen with create note button]

#### Clipboard, Share

1. **From clipboard:**
   - Copy text or an image to your clipboard.
   - Open Note Synapse and use the share extension or paste option.
2. **From share menu:**
   - In any app, tap the **Share** button.
   - Select **Note Synapse** from the share menu.
   - The shared content will open in the Share Screen.

##### Web Extraction

When sharing a URL:

1. The Share Screen will detect the URL automatically.
2. Tap **Extract Web Content** to open the web extraction dialog.
3. A WebView will load the page.
4. Use the extraction controls to:
   - Extract the main article content
   - Select specific images to download
   - Save the page as a note with extracted content
5. Review the extracted content, edit the title and tags if needed.
6. Tap **Create Note** or **Append to Note** to save.

> **Image Placeholder:** [Screenshot of web extraction dialog with WebView]

#### AI Note Creation

1. From the main screen or notes list, tap the AI icon or select **AI Actions**.
2. Choose **Create New Notes**.
3. Enter a prompt describing what you want to create.
4. Optionally:
   - Attach files or images
   - Select existing notes as context
5. Tap **Create** to generate the note(s).
6. Review the generated content and save.

> **Image Placeholder:** [Screenshot of AI note creation dialog]

### How to Edit a Note

#### Manually

1. Open a note by tapping it from the notes list.
2. Tap the **Edit** button (pencil icon) in the toolbar.
3. Modify the title, content, tags, or attachments.
4. Changes are auto-saved as you type.
5. Tap **Done** or the back button to exit edit mode.

#### With AI (Note Transform)

1. Open a note.
2. Tap the **AI Actions** button (or three-dot menu → **Transform Note**).
3. Enter a transformation instruction (e.g., "Make this more concise" or "Translate to Spanish").
4. Optionally attach additional files for context.
5. Tap **Transform**.
6. Review the transformed content.
7. Choose to:
   - Replace the original content
   - Create a new note with the transformed content
   - Cancel

> **Image Placeholder:** [Screenshot of note transform dialog]

### Subnotes

#### Reparent Subnote

1. Open a note that contains subnotes.
2. Find the subnote you want to move.
3. Tap the three-dot menu (⋮) next to the subnote.
4. Select **Reparent Subnote**.
5. In the dialog that appears:
   - Search for the target note by title or content
   - Filter by tags if needed
   - Select the destination note
6. Tap **Move** to complete the reparenting.

> **Image Placeholder:** [Screenshot of reparent subnote dialog]

### Task

#### How to Specify Due Date

1. Create a new task or convert an existing note to a task.
2. Open the task detail screen.
3. Tap the **Due Date** field.
4. Select a date and time from the date picker.
5. The due date will be saved automatically.

> **Image Placeholder:** [Screenshot of task with due date picker]

#### How to Change Status

1. Open a task.
2. Find the status dropdown (usually in the header or toolbar).
3. Select one of the following statuses:
   - **To Do**: Task not started
   - **In Progress**: Task is being worked on
   - **Completed**: Task is finished
   - **Cancelled**: Task is abandoned
4. The status change is saved automatically.

Alternatively, you can change status from:
- The task list view (status dropdown in each task card)
- The calendar view
- The TODO list view

> **Image Placeholder:** [Screenshot of task status dropdown]

#### How to Convert Between Note and Task

1. Open a note or task.
2. Tap the three-dot menu (⋮) in the toolbar.
3. Select **Convert to Task** or **Convert to Note**.
4. The conversion happens immediately.
   - Notes converted to tasks will have status set to "To Do"
   - Tasks converted to notes will lose task-specific fields (status, due date, etc.)

> **Image Placeholder:** [Screenshot of convert menu option]

#### How to View Tasks on Calendar

1. Navigate to the **Calendar** tab in the main navigation.
2. The calendar view shows:
   - Tasks scheduled for specific dates
   - Tasks with due dates
3. Tap on a date to see tasks for that day.
4. Use the view switcher to change between:
   - **Month view**: Full calendar month
   - **Two Weeks view**: Two-week period
   - **Week view**: Single week
5. Tap a task in the calendar to open its details.

> **Image Placeholder:** [Screenshot of calendar view with tasks]

#### How to View Tasks Timeline

1. Navigate to the **Calendar** tab.
2. Tap the view switcher and select **Timeline**.
3. The timeline view shows all tasks and notes in chronological order.
4. Tasks are grouped by date.
5. Filter by tags using the tag filter chips at the top.
6. Tap any item to open it.

> **Image Placeholder:** [Screenshot of timeline view]

#### How to View Tasks TODO List

1. Navigate to the **Calendar** tab.
2. Tap the view switcher and select **TODO**.
3. The TODO list shows all tasks with their:
   - Status icons
   - Titles and content preview
   - Completion percentage (if applicable)
   - Status dropdown for quick changes
4. Filter by tags using the tag filter chips.
5. Tap a task to open its details.
6. Change task status directly from the list using the status dropdown.

> **Image Placeholder:** [Screenshot of TODO list view]

---

## Chat

### How to Chat

1. Navigate to the **Chat** tab or tap the chat icon.
2. Start a new conversation or open an existing one.
3. Type your message in the input field at the bottom.
4. Optionally:
   - Attach files or images
   - Add notes as context (see below)
5. Tap **Send** or press Enter.
6. Wait for the AI response.

#### How to Save Chat to Note

1. During or after a chat, find the message you want to save.
2. For assistant messages, tap the **Add to Note** button (note icon) in the message action row.
3. Choose to:
   - Create a new note with the message content
   - Append to an existing note
4. The message content will be saved as a note.

> **Image Placeholder:** [Screenshot of chat message with save to note button]

#### How to Retry Chat

1. If an AI response fails or you want to regenerate:
   - Tap the **Retry** button (refresh icon) next to the failed message
   - Or tap the three-dot menu on a message and select **Retry**
2. The AI will regenerate the response.

> **Image Placeholder:** [Screenshot of retry button in chat]

#### How to Configure AI Tools and MCPs

1. In the chat screen, look for the **Tools** or **MCP** panel (usually collapsible).
2. **For MCP servers:**
   - Tap to expand the MCP panel
   - Toggle MCP endpoints on/off using the filter chips
   - Each endpoint shows available tools
3. **For AI Tools:**
   - Toggle AI tool services on/off using the filter chips
   - Each service shows its available tools
4. Active tools will be automatically used by the AI when relevant.
5. To configure MCP servers globally:
   - Go to **Settings** → **MCP Settings**
   - Add, edit, or remove MCP endpoints
   - Configure authentication (bearer tokens, etc.)

> **Image Placeholder:** [Screenshot of tools/MCP configuration panel in chat]

### How to Add Note as Context to Chat

1. In the chat screen, tap the **Add Notes** button (note icon with plus).
2. A note selection dialog will appear.
3. Search or browse for notes to add.
4. Select one or more notes.
5. Tap **Add** to include them as context.
6. The selected notes will appear as chips above the message input.
7. The AI will have access to the content of these notes during the conversation.

> **Image Placeholder:** [Screenshot of note selection dialog in chat]

### How to View Past Chats

1. In the chat screen, tap the **History** button (clock icon) or three-dot menu → **View History**.
2. The history dialog shows:
   - All past conversations
   - Filtered by time range (Last 24 hours, Last week, Last month, All time)
   - Filtered by tags (if conversations are tagged)
3. Tap a conversation to open it.
4. Use the search bar to find specific conversations.

> **Image Placeholder:** [Screenshot of chat history dialog]

### How to Use Non-Linear Chats

#### Fork

1. In a conversation, find the message where you want to fork.
2. Tap the three-dot menu on that message.
3. Select **Fork Conversation**.
4. If the message appears in multiple conversations, you'll be asked to select which conversation context to use.
5. A new conversation will be created starting from that message.
6. You can continue the conversation from that point with different questions or directions.

> **Image Placeholder:** [Screenshot of fork conversation option]

#### Transform

1. In a conversation, find the message you want to transform.
2. Tap the three-dot menu on that message.
3. Select **Transform** (if available).
4. Enter a transformation instruction.
5. The message content will be transformed using AI.
6. You can use the transformed content to continue the conversation.

> **Note:** Transform functionality may vary depending on the message type and context.

---

## User App

### How to Create an App

#### User App

1. Navigate to **User Apps** from the main menu.
2. Tap the **+** (plus) button or **Create App**.
3. Fill in the app details:
   - **Name**: The app's display name
   - **Description**: What the app does
   - **Steps**: List the steps/features the app should have (add multiple steps with the + button)
4. Optionally:
   - Select **App Type**: Normal, Note Action, or AI Tool
   - Add attachments (images, files) for reference
   - Add notes as context
   - Add third-party libraries (see below)
5. Tap **Create** to generate the app.
6. The AI will generate the HTML code for your app.
7. Review the generated app in the preview.

> **Image Placeholder:** [Screenshot of app creation form]

#### Note Action App

1. Follow the steps above for creating a user app.
2. Select **App Type**: **Note Action App**.
3. Note Action Apps operate on pre-selected notes.
4. When the app runs, it will receive the selected notes through `window.Synapse.Notes`.
5. Design your app to process, analyze, or manipulate these notes.

> **Image Placeholder:** [Screenshot of note action app type selection]

#### AI Tool

1. Follow the steps above for creating a user app.
2. Select **App Type**: **AI Tool**.
3. AI Tool apps can be used as tools in chat conversations.
4. The app should expose functions that can be called by the AI.
5. Configure the tool's description and parameters.

> **Image Placeholder:** [Screenshot of AI tool app type selection]

#### Provide Context to Create App

1. When creating an app, you can provide context in several ways:
   - **Notes**: Tap **Add Notes** and select relevant notes that describe what you want
   - **Attachments**: Add images or files that show examples or requirements
   - **Libraries**: Add third-party libraries that the app should use
2. The AI will use this context to better understand your requirements and generate appropriate code.

> **Image Placeholder:** [Screenshot of context selection in app creation]

### How to Iterate App

#### Submit Edit Suggestion

1. Open the app you want to edit.
2. Tap **Edit** or the edit icon.
3. In the edit screen, you'll see tabs for:
   - **Edit Suggestion**: Enter what you want to change
   - **Code**: View and edit the source code directly
   - **Preview**: See how the app looks
4. In the **Edit Suggestion** tab:
   - Enter a description of the changes you want
   - Optionally add notes, attachments, or libraries
5. Tap **Submit** to generate a new revision.

> **Image Placeholder:** [Screenshot of app edit suggestion form]

#### View AI Response

1. After submitting an edit suggestion, the AI will generate a new revision.
2. The AI response (explanation of changes) will be shown in the revision details.
3. You can view it in the **Revisions** section of the app.

> **Image Placeholder:** [Screenshot of AI response in revision]

#### Check Source Code

1. In the app edit screen, switch to the **Code** tab.
2. You'll see the full HTML source code of the app.
3. You can:
   - View the code with syntax highlighting
   - Edit the code directly
   - Search within the code
4. Changes made directly to the code will create a new revision when saved.

> **Image Placeholder:** [Screenshot of code editor]

#### Move Between Revisions

1. In the app detail screen, find the **Revisions** section.
2. You'll see a list of all revisions with:
   - Revision number
   - Timestamp
   - User prompt or edit description
   - AI response summary
3. Tap a revision to view its details.
4. To switch to a different revision:
   - Tap **Use This Revision** or the pin icon
   - The app will use that revision's code
5. You can compare revisions side-by-side.

> **Image Placeholder:** [Screenshot of revisions list]

### How to Add Third Party Dependencies to App

1. When creating or editing an app, find the **Libraries** section.
2. Tap **Add Library**.
3. For each library, provide:
   - **Name**: The library name (e.g., "Chart.js")
   - **Usage Instructions**: How the library should be used in the app
   - **Links**: CDN URLs or download links for the library files
4. Add multiple dependency links for each library if needed.
5. The libraries will be downloaded and included when the app runs.
6. The AI will be informed about these libraries and can use them in the generated code.

> **Image Placeholder:** [Screenshot of library configuration]

### Share App

#### Export

1. Open the app you want to export.
2. Tap the three-dot menu (⋮) or **Share** button.
3. Select **Export App**.
4. The app will be exported as a YAML file containing:
   - App metadata (name, description, type)
   - The current revision's HTML code (base64 encoded)
   - Library dependencies and their links
5. Choose where to save the file or share it via your device's share menu.

> **Image Placeholder:** [Screenshot of export app option]

#### Import

1. Navigate to **User Apps**.
2. Tap the **+** (plus) button or **Import App**.
3. Select the YAML file you want to import.
4. The import process will:
   - Parse the YAML file
   - Create the app with its metadata
   - Restore the HTML code
   - Download and restore library dependencies
5. Once imported, the app will appear in your apps list and be ready to use.

> **Image Placeholder:** [Screenshot of import app dialog]

---

## Settings

### Configure Color Theme

1. Navigate to **Settings** → **Appearance**.
2. Toggle **Dark Mode** on or off.
3. The theme change applies immediately.

> **Image Placeholder:** [Screenshot of appearance settings]

### Configure Language

1. Navigate to **Settings** → **Language**.
2. Select your preferred language:
   - **English**
   - **Chinese (Simplified)**
3. The language change applies immediately.

> **Image Placeholder:** [Screenshot of language settings]

### AI Configuration

#### Add / Change AI Models

1. Navigate to **Settings** → **AI API** → **Model Configuration**.
2. You'll see a list of available model types (OpenAI, Gemini, etc.).
3. To configure a model:
   - Tap on the model
   - Enter or update the **API Key**
   - Optionally configure:
     - **Endpoint URL** (for custom endpoints)
     - **Model Name** (specific model variant)
     - **Display Name**
     - **Max Input/Output Tokens**
4. Tap **Save** to store the configuration.
5. To add a new model type, tap **Add Model** and follow the same steps.

> **Image Placeholder:** [Screenshot of model configuration screen]

#### Add Custom Prompts

1. Navigate to **Settings** → **Prompt Settings**.
2. You'll see different prompt categories:
   - **Note Transformation**: Custom instructions for note transformations
   - **Chat System**: System-level instructions for chat conversations
   - **Chat Per Message**: Instructions added to each chat message
   - **App Generation**: Instructions for app generation
3. Tap on a category to edit.
4. Enter your custom prompt or instructions.
5. These will be appended to the default prompts when using the respective features.

> **Image Placeholder:** [Screenshot of prompt settings]

#### Add MCP Servers

1. Navigate to **Settings** → **MCP Settings**.
2. Tap **Add MCP Server** or the **+** button.
3. Fill in the server details:
   - **Name**: Display name for the server
   - **Base URL**: The MCP server endpoint URL
   - **Transport Type**: HTTP or SSE (Server-Sent Events)
   - **Bearer Token**: Authentication token (if required)
   - **Additional Headers**: Custom headers (if needed)
4. Tap **Save**.
5. The MCP server will be available in chat conversations.
6. To test the connection, tap **Refresh Tools** to fetch available tools from the server.

> **Image Placeholder:** [Screenshot of MCP settings screen]

### AI Debug

#### How to Debug AI Activities

1. Navigate to **Settings** → **AI Debug Overlay**.
2. Toggle the debug overlay on.
3. When enabled, you'll see a debug panel that shows:
   - All AI requests and responses
   - Request IDs
   - Endpoints called
   - Headers and request bodies
   - Response data
   - Timing information
   - Errors and warnings
4. The debug overlay appears as a floating panel or overlay on relevant screens.

> **Image Placeholder:** [Screenshot of AI debug overlay]

#### Interpret Debugging Info

The debug overlay shows:

- **Request ID**: Unique identifier for each request (useful for tracking)
- **Endpoint**: Which AI service/model was called
- **Headers**: Authentication and request headers
- **Request Body**: The full prompt and context sent to the AI
- **Response**: The AI's response
- **Duration**: How long the request took
- **Status**: Success or error status
- **Error Details**: If an error occurred, details about what went wrong

Use this information to:
- Understand what prompts are being sent
- Debug why certain responses are generated
- Identify API errors or configuration issues
- Optimize prompt structure

> **Image Placeholder:** [Screenshot of detailed debug info]

### Backup and Recovery

1. Navigate to **Settings** → **Recovery**.
2. **To create a backup:**
   - Tap **Backup All Notes**
   - The backup process will:
     - Create a checkpoint of the database
     - Copy the database file
     - Copy all attachments
     - Update file paths to be relative
     - Package everything into a ZIP file
   - Choose where to save the backup file
3. **To restore from backup:**
   - Tap **Restore from Backup**
   - Select the backup ZIP file
   - The restore process will:
     - Extract the backup
     - Validate the database version
     - Migrate if needed
     - Merge notes, tags, conversations, etc. with existing data
     - Restore attachments
   - Review the import log for any issues
4. **To undo a restore:**
   - If you just restored and want to undo:
     - Tap **Undo Last Restore**
     - The app will restore the database from before the import
5. **Recovery points:**
   - The app automatically creates recovery points before major operations
   - You can view and restore from these recovery points in the Recovery screen

> **Image Placeholder:** [Screenshot of backup and recovery screen]

---

## Additional Tips

- **Search**: Use the search bar in notes, chats, and apps lists to quickly find content.
- **Tags**: Organize notes and conversations with tags for better filtering and organization.
- **Pinning**: Pin important notes to keep them at the top of your list.
- **Archiving**: Archive old notes to keep your main list clean without deleting them.

---

*Last Updated: [Date]*

*For technical support or feature requests, please refer to the project repository.*

