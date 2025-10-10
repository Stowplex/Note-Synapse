// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Note Synapse';

  @override
  String get settings => 'Settings';

  @override
  String get appearance => 'Appearance';

  @override
  String get appearanceSubtitle => 'Theme and display settings';

  @override
  String get aiApi => 'AI API';

  @override
  String get aiApiSubtitle => 'Configure your AI API key';

  @override
  String get darkMode => 'Dark Mode';

  @override
  String get darkModeSubtitle => 'Toggle between light and dark theme';

  @override
  String get apiKey => 'API Key';

  @override
  String get loading => 'Loading...';

  @override
  String get noApiKeyConfigured => 'No API key configured';

  @override
  String get updateApiKey => 'Update API Key';

  @override
  String get updateApiKeySubtitle => 'Enter a new API key';

  @override
  String get resetApiKey => 'Reset API Key';

  @override
  String get resetApiKeySubtitle => 'Clear current API key and return to setup';

  @override
  String get currentApiKey => 'Current API Key';

  @override
  String get close => 'Close';

  @override
  String get enterNewApiKey => 'Enter your new Gemini API key:';

  @override
  String get apiKeyLabel => 'API Key';

  @override
  String get apiKeyHint => 'Enter your API key here';

  @override
  String get cancel => 'Cancel';

  @override
  String get update => 'Update';

  @override
  String get reset => 'Reset';

  @override
  String get resetApiKeyConfirmation =>
      'This will clear your current API key and return you to the setup screen. Are you sure?';

  @override
  String get apiKeyUpdatedSuccessfully => 'API key updated successfully';

  @override
  String errorUpdatingApiKey(Object error) {
    return 'Error updating API key: $error';
  }

  @override
  String errorResettingApiKey(Object error) {
    return 'Error resetting API key: $error';
  }

  @override
  String get welcomeToNoteSynapse => 'Welcome to Note Synapse';

  @override
  String get aiPoweredNoteTaking => 'Your AI-powered note-taking companion';

  @override
  String get setupRequired => 'Setup Required';

  @override
  String get setupRequiredDescription =>
      'To use AI features, you need a Gemini API key from Google AI Studio.';

  @override
  String get getApiKey => 'Get API Key';

  @override
  String get geminiApiKey => 'Gemini API Key';

  @override
  String get continueButton => 'Continue';

  @override
  String get apiKeySecurityNote =>
      'Your API key is stored securely on your device and never shared.';

  @override
  String get pleaseEnterApiKey => 'Please enter your API key';

  @override
  String failedToSaveApiKey(Object error) {
    return 'Failed to save API key: $error';
  }

  @override
  String get notes => 'Notes';

  @override
  String get calendar => 'Calendar';

  @override
  String get addNewContent => 'Add New Content';

  @override
  String get newAiAction => 'New AI Action';

  @override
  String get newAiActionSubtitle => 'Create content using AI';

  @override
  String get newNote => 'New Note';

  @override
  String get newNoteSubtitle => 'Create a regular note';

  @override
  String get newTask => 'New Task';

  @override
  String get newTaskSubtitle => 'Create a new task';

  @override
  String get newVoice => 'New Voice';

  @override
  String get newVoiceSubtitle => 'Record voice note';

  @override
  String get newPicture => 'New Picture';

  @override
  String get newPictureSubtitle => 'Add image from camera or gallery';

  @override
  String get attachment => 'Attachment';

  @override
  String get attachmentSubtitle => 'Add file attachment';

  @override
  String get newNoteFromClipboard => 'New Note from Clipboard';

  @override
  String get newNoteFromClipboardSubtitle =>
      'Create note from clipboard content';

  @override
  String get recordingStarted => 'Recording started';

  @override
  String get failedToStartRecording =>
      'Failed to start recording. Please check microphone permissions.';

  @override
  String get failedToStartRecordingLinux =>
      'Failed to start recording. Please check if gstreamer and PulseAudio are installed.';

  @override
  String errorStartingRecording(Object error) {
    return 'Error starting recording: $error';
  }

  @override
  String get audioNoteSavedSuccessfully => 'Audio note saved successfully!';

  @override
  String errorStoppingRecording(Object error) {
    return 'Error stopping recording: $error';
  }

  @override
  String get selectImageSource => 'Select Image Source';

  @override
  String get chooseImageSource => 'Choose how you want to add an image';

  @override
  String get camera => 'Camera';

  @override
  String get takePhoto => 'Take Photo';

  @override
  String get gallery => 'Gallery';

  @override
  String get imageNoteCreatedSuccessfully => 'Image note created successfully!';

  @override
  String errorCreatingImageNote(Object error) {
    return 'Error creating image note: $error';
  }

  @override
  String errorPickingImage(Object error) {
    return 'Error picking image: $error';
  }

  @override
  String get clipboardIsEmpty => 'Clipboard is empty';

  @override
  String errorAccessingClipboard(Object error) {
    return 'Error accessing clipboard: $error';
  }

  @override
  String get unableToAccessFileData => 'Unable to access file data';

  @override
  String errorPickingFile(Object error) {
    return 'Error picking file: $error';
  }

  @override
  String get fileNoteCreatedSuccessfully => 'File note created successfully!';

  @override
  String errorCreatingFileNote(Object error) {
    return 'Error creating file note: $error';
  }

  @override
  String get recording => 'Recording...';

  @override
  String get voiceNoteRecording => 'Voice Note Recording';

  @override
  String get recordingTapStop => 'Recording... Tap stop when done';

  @override
  String get recordingWillContinue =>
      'Recording will continue until you tap \"Stop Recording\"';

  @override
  String get startRecordingVoiceNote => 'Start recording your voice note';

  @override
  String get startRecording => 'Start Recording';

  @override
  String get stopRecording => 'Stop Recording';

  @override
  String get language => 'Language';

  @override
  String get languageSubtitle => 'Select your preferred language';

  @override
  String get english => 'English';

  @override
  String get chineseSimplified => '简体中文';

  @override
  String get languageChanged => 'Language changed successfully';

  @override
  String errorChangingLanguage(Object error) {
    return 'Error changing language: $error';
  }

  @override
  String get selected => 'selected';

  @override
  String get linkSelectedNotes => 'Link Selected Notes';

  @override
  String get deleteSelectedNotes => 'Delete Selected Notes';

  @override
  String get openAIAction => 'Open AI Action';

  @override
  String get exitMultiSelectMode => 'Exit Multi-Select Mode';

  @override
  String get searchNotes => 'Search notes...';

  @override
  String get allNotes => 'All Notes';

  @override
  String get defaultNotes => 'Default';

  @override
  String get pinnedNotes => 'Pinned';

  @override
  String get archivedNotes => 'Archived';

  @override
  String get filter => 'Filter';

  @override
  String get noNotesFound => 'No notes found';

  @override
  String get createFirstNote => 'Create your first note';

  @override
  String get timeline => 'Timeline';

  @override
  String get todo => 'Todo';

  @override
  String get today => 'Today';

  @override
  String get noTasksForToday => 'No tasks for today';

  @override
  String get noNotesForToday => 'No notes for today';

  @override
  String get createFirstTask => 'Create your first task';

  @override
  String get createFirstTimelineNote => 'Create your first timeline note';

  @override
  String get taskCompletion => 'Task Completion';

  @override
  String get completed => 'Completed';

  @override
  String get pending => 'Pending';

  @override
  String get inProgress => 'In Progress';

  @override
  String get overdue => 'Overdue';

  @override
  String get dueToday => 'Due Today';

  @override
  String get dueTomorrow => 'Due Tomorrow';

  @override
  String get dueThisWeek => 'Due This Week';

  @override
  String get dueNextWeek => 'Due Next Week';

  @override
  String get dueThisMonth => 'Due This Month';

  @override
  String get dueNextMonth => 'Due Next Month';

  @override
  String get overdueTasks => 'Overdue Tasks';

  @override
  String get dueTodayTasks => 'Due Today';

  @override
  String get dueTomorrowTasks => 'Due Tomorrow';

  @override
  String get dueThisWeekTasks => 'Due This Week';

  @override
  String get dueNextWeekTasks => 'Due Next Week';

  @override
  String get dueThisMonthTasks => 'Due This Month';

  @override
  String get dueNextMonthTasks => 'Due Next Month';

  @override
  String get noOverdueTasks => 'No overdue tasks';

  @override
  String get noDueTodayTasks => 'No tasks due today';

  @override
  String get noDueTomorrowTasks => 'No tasks due tomorrow';

  @override
  String get noDueThisWeekTasks => 'No tasks due this week';

  @override
  String get noDueNextWeekTasks => 'No tasks due next week';

  @override
  String get noDueThisMonthTasks => 'No tasks due this month';

  @override
  String get noDueNextMonthTasks => 'No tasks due next month';

  @override
  String get aiActions => 'AI Actions';

  @override
  String get selectAIAction => 'Select AI Action';

  @override
  String get noteQa => 'Note Q&A';

  @override
  String get noteQaDescription => 'Ask questions about your selected notes';

  @override
  String get transformNote => 'Transform Note';

  @override
  String get transformNoteDescription =>
      'Rewrite, reorganize, or modify your note';

  @override
  String get createNewNotes => 'Create New Notes';

  @override
  String get createNewNotesDescription =>
      'Generate new notes based on your prompt and context';

  @override
  String get enterYourPrompt => 'Enter your prompt:';

  @override
  String get attachFiles => 'Attach Files';

  @override
  String get answerOnlyFromNotes => 'Answer only from selected notes';

  @override
  String get process => 'Process';

  @override
  String get processing => 'Processing...';

  @override
  String get clearResponse => 'Clear Response';

  @override
  String get response => 'Response';

  @override
  String get copyResponse => 'Copy Response';

  @override
  String get createNotesFromResponse => 'Create Notes from Response';

  @override
  String get noFilesAttached => 'No files attached';

  @override
  String get filesAttached => 'Files attached';

  @override
  String get removeFile => 'Remove File';

  @override
  String get addFiles => 'Add Files';

  @override
  String get processingRequest => 'Processing your request...';

  @override
  String errorProcessingRequest(Object error) {
    return 'Error processing request: $error';
  }

  @override
  String get responseCopied => 'Response copied to clipboard';

  @override
  String get notesCreatedSuccessfully => 'Notes created successfully!';

  @override
  String errorCreatingNotes(Object error) {
    return 'Error creating notes: $error';
  }

  @override
  String get sharedContent => 'Shared Content';

  @override
  String get createNote => 'Create Note';

  @override
  String get appendToNote => 'Append to Note';

  @override
  String get selectNoteToAppend => 'Select Note to Append';

  @override
  String get searchNotesToAppend => 'Search notes to append to...';

  @override
  String get title => 'Title';

  @override
  String get tags => 'Tags';

  @override
  String get addNewTag => 'Add New Tag';

  @override
  String get extractContent => 'Extract Content';

  @override
  String get extractingContent => 'Extracting content...';

  @override
  String get contentExtracted => 'Content extracted successfully!';

  @override
  String errorExtractingContent(Object error) {
    return 'Error extracting content: $error';
  }

  @override
  String get noApiKeyForExtraction => 'API key required for content extraction';

  @override
  String get urlDetected => 'URL Detected';

  @override
  String get extractFromUrl => 'Extract from URL';

  @override
  String get contentType => 'Content Type';

  @override
  String get text => 'Text';

  @override
  String get url => 'URL';

  @override
  String get image => 'Image';

  @override
  String get file => 'File';

  @override
  String get unknown => 'Unknown';

  @override
  String get noNotesAvailable => 'No notes available';

  @override
  String errorLoadingNotes(Object error) {
    return 'Error loading notes: $error';
  }

  @override
  String get noteCreatedSuccessfully => 'Note created successfully!';

  @override
  String errorCreatingNote(Object error) {
    return 'Error creating note: $error';
  }

  @override
  String get noteUpdatedSuccessfully => 'Note updated successfully!';

  @override
  String errorUpdatingNote(Object error) {
    return 'Error updating note: $error';
  }

  @override
  String get pinNote => 'Pin note';

  @override
  String get unpinNote => 'Unpin note';

  @override
  String get archiveNote => 'Archive note';

  @override
  String get unarchiveNote => 'Unarchive note';

  @override
  String get editNote => 'Edit Note';

  @override
  String get saveChanges => 'Save Changes';

  @override
  String get discardChanges => 'Discard Changes';

  @override
  String get deleteNote => 'Delete Note';

  @override
  String get confirmDeleteNote => 'Are you sure you want to delete this note?';

  @override
  String get noteDeletedSuccessfully => 'Note deleted successfully!';

  @override
  String errorDeletingNote(Object error) {
    return 'Error deleting note: $error';
  }

  @override
  String get addSubNote => 'Add Sub-Note';

  @override
  String get subNotes => 'Sub-Notes';

  @override
  String get noSubNotes => 'No sub-notes';

  @override
  String get addNewSubNote => 'Add New Sub-Note';

  @override
  String get editSubNote => 'Edit Sub-Note';

  @override
  String get deleteSubNote => 'Delete Sub-Note';

  @override
  String get confirmDeleteSubNote =>
      'Are you sure you want to delete this sub-note?';

  @override
  String get subNoteAddedSuccessfully => 'Sub-note added successfully!';

  @override
  String get subNoteUpdatedSuccessfully => 'Sub-note updated successfully!';

  @override
  String get subNoteDeletedSuccessfully => 'Sub-note deleted successfully!';

  @override
  String errorAddingSubNote(Object error) {
    return 'Error adding sub-note: $error';
  }

  @override
  String errorUpdatingSubNote(Object error) {
    return 'Error updating sub-note: $error';
  }

  @override
  String errorDeletingSubNote(Object error) {
    return 'Error deleting sub-note: $error';
  }

  @override
  String get scheduledAt => 'Scheduled At';

  @override
  String get completeBy => 'Complete By';

  @override
  String get dateValidationError =>
      'Complete by date must be after scheduled date';

  @override
  String get relationships => 'Relationships';

  @override
  String get linkedNotes => 'Linked Notes';

  @override
  String get noLinkedNotes => 'No linked notes';

  @override
  String get addRelationship => 'Add Relationship';

  @override
  String get removeRelationship => 'Remove Relationship';

  @override
  String get confirmRemoveRelationship =>
      'Are you sure you want to remove this relationship?';

  @override
  String get relationshipAddedSuccessfully =>
      'Relationship added successfully!';

  @override
  String get relationshipRemovedSuccessfully =>
      'Relationship removed successfully!';

  @override
  String errorAddingRelationship(Object error) {
    return 'Error adding relationship: $error';
  }

  @override
  String errorRemovingRelationship(Object error) {
    return 'Error removing relationship: $error';
  }

  @override
  String get audioRecording => 'Audio Recording';

  @override
  String get playAudio => 'Play Audio';

  @override
  String get pauseAudio => 'Pause Audio';

  @override
  String get recordingInProgress => 'Recording in progress...';

  @override
  String get audioRecordedSuccessfully => 'Audio recorded successfully!';

  @override
  String errorRecordingAudio(Object error) {
    return 'Error recording audio: $error';
  }

  @override
  String errorPlayingAudio(Object error) {
    return 'Error playing audio: $error';
  }

  @override
  String get noAudioAttachments => 'No audio attachments';

  @override
  String get audioAttachment => 'Audio Attachment';

  @override
  String get duration => 'Duration';

  @override
  String get position => 'Position';

  @override
  String get autoSave => 'Auto-save';

  @override
  String get saved => 'Saved';

  @override
  String get saving => 'Saving...';

  @override
  String get unsavedChanges => 'Unsaved changes';

  @override
  String get confirmDiscardChanges =>
      'You have unsaved changes. Are you sure you want to discard them?';

  @override
  String get yes => 'Yes';

  @override
  String get no => 'No';

  @override
  String get start => 'Start';

  @override
  String get due => 'Due';

  @override
  String get yesterday => 'Yesterday';

  @override
  String daysAgo(Object count) {
    return '$count days ago';
  }

  @override
  String get subNote => 'Sub-note';

  @override
  String get addTag => 'Add tag';

  @override
  String get noTagsYet => 'No tags yet. Tap \"Add tag\" to add some.';

  @override
  String get addLink => 'Add Link';

  @override
  String get attach => 'Attach';

  @override
  String get recordAudio => 'Record Audio';

  @override
  String get status => 'Status';

  @override
  String get toDo => 'To Do';

  @override
  String get cancelled => 'Cancelled';

  @override
  String get scheduled => 'Scheduled';

  @override
  String get content => 'Content';

  @override
  String get checkbox => 'Checkbox';

  @override
  String get bold => 'Bold';

  @override
  String get created => 'Created';

  @override
  String get updated => 'Updated';

  @override
  String get markComplete => 'Mark Complete';

  @override
  String get markIncomplete => 'Mark Incomplete';

  @override
  String get noLinkedNotesYet => 'No linked notes yet';

  @override
  String get tasks => 'Tasks';

  @override
  String get month => 'Month';

  @override
  String get week => 'Week';

  @override
  String get twoWeeks => '2 Weeks';

  @override
  String get january => 'Jan';

  @override
  String get february => 'Feb';

  @override
  String get march => 'Mar';

  @override
  String get april => 'Apr';

  @override
  String get may => 'May';

  @override
  String get june => 'Jun';

  @override
  String get july => 'Jul';

  @override
  String get august => 'Aug';

  @override
  String get september => 'Sep';

  @override
  String get october => 'Oct';

  @override
  String get november => 'Nov';

  @override
  String get december => 'Dec';

  @override
  String get noTasksWithSelectedTags => 'No tasks with selected tags';

  @override
  String get noNotesWithSelectedTags => 'No notes with selected tags';

  @override
  String get noTasksWithSelectedTagsForThisDay =>
      'No tasks with selected tags for this day';

  @override
  String get noNotesWithSelectedTagsForThisDay =>
      'No notes with selected tags for this day';

  @override
  String get trySelectingDifferentTags => 'Try selecting different tags';

  @override
  String get cannotOpenLink => 'Cannot open link';

  @override
  String get errorOpeningLink => 'Error opening link';

  @override
  String subtasksCompleted(Object completed, Object total) {
    return '$completed/$total subtasks completed';
  }

  @override
  String get audioNote => 'Audio Note';

  @override
  String get audioRecordingFrom => 'Audio recording from';

  @override
  String get attachments => 'Attachments';

  @override
  String get removeAttachment => 'Remove Attachment';

  @override
  String removeAttachmentConfirm(Object fileName) {
    return 'Are you sure you want to remove \"$fileName\" from this note?';
  }

  @override
  String get attachmentRemoved => 'Attachment removed';

  @override
  String get errorRemovingAttachment => 'Error removing attachment';

  @override
  String addedAttachments(Object count) {
    return 'Added $count attachment(s)';
  }

  @override
  String get errorAddingAttachment => 'Error adding attachment';

  @override
  String get recordingSavedAsAttachment => 'Recording saved as attachment';

  @override
  String get photoAddedToNote => 'Photo added to note';

  @override
  String errorTakingPhoto(Object error) {
    return 'Error taking photo: $error';
  }

  @override
  String get removeAttachmentTooltip => 'Remove attachment';

  @override
  String get share => 'Share';

  @override
  String get shareNote => 'Share Note';

  @override
  String get shareNotes => 'Share Notes';

  @override
  String get shareAsText => 'Share as Text';

  @override
  String get copyToClipboard => 'Copy to Clipboard';

  @override
  String get shareSubNotesAndLinkedNotes => 'Share sub-notes and linked notes';

  @override
  String get shareDialogTitle => 'Share Notes';

  @override
  String get shareDialogDescription =>
      'Choose how you want to share the selected notes';

  @override
  String get textCopiedToClipboard => 'Text copied to clipboard';

  @override
  String errorCopyingToClipboard(Object error) {
    return 'Error copying to clipboard: $error';
  }

  @override
  String errorSharingText(Object error) {
    return 'Error sharing text: $error';
  }

  @override
  String get selectFileLocation => 'Select file location';

  @override
  String get saveAsMarkdown => 'Save as Markdown';

  @override
  String get fileSavedSuccessfully => 'File saved successfully';

  @override
  String errorSavingFile(Object error) {
    return 'Error saving file: $error';
  }

  @override
  String get shareSelectedNotes => 'Share Selected Notes';

  @override
  String get type => 'Type';

  @override
  String get note => 'Note';

  @override
  String get task => 'Task';

  @override
  String get createFilter => 'Create Filter';

  @override
  String get editFilter => 'Edit Filter';

  @override
  String get filterName => 'Filter Name';

  @override
  String get filterNameHint => 'Enter a name for this filter';

  @override
  String get includeText => 'Include Text';

  @override
  String get includeTextHint => 'Text to search for in notes';

  @override
  String get includeTags => 'Include Tags';

  @override
  String get includeTagsHint => 'Select tags to filter by';

  @override
  String get includeArchivedNotes => 'Include archived notes';

  @override
  String get create => 'Create';

  @override
  String get selectTags => 'Select Tags';

  @override
  String get apply => 'Apply';

  @override
  String get deleteFilter => 'Delete Filter';

  @override
  String deleteFilterConfirm(Object filterName) {
    return 'Are you sure you want to delete \"$filterName\"?';
  }

  @override
  String get addFilter => 'Add Filter';

  @override
  String get delete => 'Delete';

  @override
  String get manageTags => 'Manage Tags';

  @override
  String get tagManagement => 'Tag Management';

  @override
  String tagUsageCount(Object count) {
    return '$count notes';
  }

  @override
  String get deleteTag => 'Delete Tag';

  @override
  String confirmDeleteTag(Object tagName) {
    return 'Are you sure you want to delete the tag \"$tagName\"?';
  }

  @override
  String confirmDeleteTagWarning(Object count) {
    return 'This will remove the tag from all $count associated notes. This action cannot be undone.';
  }

  @override
  String get tagDeletedSuccessfully => 'Tag deleted successfully!';

  @override
  String errorDeletingTag(Object error) {
    return 'Error deleting tag: $error';
  }

  @override
  String get noTagsAvailable => 'No tags available';

  @override
  String get tagUsage => 'Usage';

  @override
  String get deleteTags => 'Delete Tags';

  @override
  String get dedupTags => 'Dedup Tags';

  @override
  String get dedupRules => 'Dedup Rules';

  @override
  String get addDedupRule => 'Add Dedup Rule';

  @override
  String get leftTag => 'Left Tag';

  @override
  String get rightTag => 'Right Tag';

  @override
  String get selectLeftTag => 'Select Left Tag';

  @override
  String get selectRightTag => 'Select Right Tag';

  @override
  String get swapTags => 'Swap Tags';

  @override
  String get executeDedup => 'Execute';

  @override
  String get aiSuggestDedup => 'AI Suggest';

  @override
  String get noDedupRules => 'No dedup rules yet';

  @override
  String get addFirstDedupRule => 'Add your first dedup rule';

  @override
  String dedupRuleValidationError(Object error) {
    return 'Invalid dedup rule: $error';
  }

  @override
  String get dedupRulesExecutedSuccessfully =>
      'Dedup rules executed successfully!';

  @override
  String errorExecutingDedupRules(Object error) {
    return 'Error executing dedup rules: $error';
  }

  @override
  String get aiSuggestingDedupRules => 'AI is suggesting dedup rules...';

  @override
  String errorGettingAiSuggestions(Object error) {
    return 'Error getting AI suggestions: $error';
  }

  @override
  String get confirmExecuteDedupRules =>
      'Are you sure you want to execute these dedup rules? This will replace all left tags with right tags and cannot be undone.';

  @override
  String get dedupRuleLeftTagDuplicate => 'Left tag appears in multiple rules';

  @override
  String get dedupRuleRightTagDuplicate =>
      'Right tag appears in multiple rules';

  @override
  String get dedupRuleCircularReference => 'Circular reference detected';

  @override
  String get dedupRuleSelfReference => 'Cannot replace tag with itself';
}
