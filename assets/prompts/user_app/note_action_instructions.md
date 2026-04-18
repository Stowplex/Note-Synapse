
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
   console.log(`Processing ${window.Synapse.Notes.length} selected notes`);
   
   // Process each note
   window.Synapse.Notes.forEach((note, index) => {
     console.log(`Note ${index + 1}: ${note.title}`);
     console.log(`Content: ${note.content}`);
     console.log(`Tags: ${note.tags.join(', ')}`);
     console.log(`Type: ${note.isTask ? 'Task' : 'Note'}`);
     if (note.isTask) {
       console.log(`Status: ${note.status}`);
     }
   });
 } else {
   console.log('No notes selected');
 }
 ```
 