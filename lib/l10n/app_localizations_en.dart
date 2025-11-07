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
  String get pleaseEnterApiKey => 'Please enter an API key';

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
  String get transformNoteHint =>
      'Describe how you want to transform this note...';

  @override
  String get createNewNotesHint =>
      'Describe what new notes you want to create...';

  @override
  String get enterYourPrompt => 'Enter your prompt:';

  @override
  String get attachFiles => 'Attach files';

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
  String noteCreatedSuccessfully(Object title) {
    return 'Note \"$title\" created successfully';
  }

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
  String get convertToNote => 'Convert to Note';

  @override
  String get convertToTask => 'Convert to Task';

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
  String get reparentSubNote => 'Reparent';

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
  String get unsaved => 'Unsaved';

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
  String get shareAsPdf => 'Share as PDF';

  @override
  String get shareAsText => 'Share as Text';

  @override
  String get copyToClipboard => 'Copy to clipboard';

  @override
  String get shareSubNotesAndLinkedNotes => 'Share sub-notes and linked notes';

  @override
  String get shareDialogTitle => 'Share Notes';

  @override
  String get shareDialogDescription =>
      'Choose how you want to share the selected notes';

  @override
  String notesToShare(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Notes',
      one: 'Note',
    );
    return '$count $_temp0 to share';
  }

  @override
  String get textCopiedToClipboard => 'Text copied to clipboard';

  @override
  String errorCopyingToClipboard(String error) {
    return 'Error copying to clipboard: $error';
  }

  @override
  String errorSharingText(String error) {
    return 'Error sharing text: $error';
  }

  @override
  String pdfSavedToCache(String fileName) {
    return 'PDF saved to cache: $fileName';
  }

  @override
  String errorGeneratingPdf(String error) {
    return 'Error generating PDF: $error';
  }

  @override
  String get attachmentMissing => 'Attachment not found.';

  @override
  String get attachmentUnavailable => 'Attachment unavailable';

  @override
  String get pdfPreviewUnavailable =>
      'PDF preview not available. Use the saved attachment to view.';

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
  String get addTags => 'Add tags';

  @override
  String get filterTags => 'Filter tags';

  @override
  String get filterTagsDialog => 'Filter Tags';

  @override
  String filterTagsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'tags',
      one: 'tag',
    );
    return '$count $_temp0';
  }

  @override
  String get clearFilters => 'Clear Filters';

  @override
  String get applyFilters => 'Apply Filters';

  @override
  String get clearTags => 'Clear Tags';

  @override
  String applyTagsWithCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Tags',
      one: 'Tag',
    );
    return 'Apply $count $_temp0';
  }

  @override
  String get addTagsCapitalized => 'Add Tags';

  @override
  String addTagsWithCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Tags',
      one: 'Tag',
    );
    return 'Add $count $_temp0';
  }

  @override
  String get searchTags => 'Search tags';

  @override
  String get searchTagsCapitalized => 'Search Tags';

  @override
  String get addNewTagOrSearch => 'Add new tag or search';

  @override
  String get tagManagement => 'Tag Management';

  @override
  String tagUsageCount(Object conversationCount, Object noteCount) {
    return '$noteCount notes / $conversationCount conversations';
  }

  @override
  String get deleteTag => 'Delete Tag';

  @override
  String confirmDeleteTag(Object tagName) {
    return 'Are you sure you want to delete the tag \"$tagName\"?';
  }

  @override
  String confirmDeleteTagWarning(Object conversationCount, Object noteCount) {
    return 'This will remove the tag from $noteCount notes and $conversationCount conversations. This action cannot be undone.';
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

  @override
  String get myApps => 'My Apps';

  @override
  String get myAppsSubtitle => 'Create and manage custom applications';

  @override
  String get noUserApps => 'No custom apps yet';

  @override
  String get createFirstApp => 'Create your first custom app';

  @override
  String get createNewApp => 'Create New App';

  @override
  String get appName => 'App Name';

  @override
  String get appNameHint => 'Enter a name for your app';

  @override
  String get appDescription => 'Description';

  @override
  String get appDescriptionHint => 'Describe what your app does';

  @override
  String get appSteps => 'Steps';

  @override
  String get appStepsHint => 'Describe the steps your app should follow';

  @override
  String get addStep => 'Add Step';

  @override
  String get removeStep => 'Remove Step';

  @override
  String get stepHint => 'Enter a step description';

  @override
  String get createApp => 'Create App';

  @override
  String get creatingApp => 'Creating app...';

  @override
  String get appCreatedSuccessfully => 'App created successfully';

  @override
  String get appCreationFailed => 'App creation failed';

  @override
  String get appCreated => 'Created';

  @override
  String get appCantCreate => 'Can\'t Create';

  @override
  String get reason => 'Reason';

  @override
  String get toApp => 'To App';

  @override
  String get console => 'Console';

  @override
  String get edit => 'Edit';

  @override
  String get confirmDeleteApp => 'Are you sure you want to delete this app?';

  @override
  String get appDeletedSuccessfully => 'App deleted successfully!';

  @override
  String errorDeletingApp(Object error) {
    return 'Error deleting app: $error';
  }

  @override
  String get webViewNotSupported => 'WebView is not supported on Linux';

  @override
  String get webViewNotSupportedDescription =>
      'User-defined apps require WebView which is not available on Linux platform';

  @override
  String get editApp => 'Edit App';

  @override
  String get appCode => 'App Code';

  @override
  String get editSuggestion => 'Edit Suggestion';

  @override
  String get editSuggestionHint => 'Describe what changes you want to make';

  @override
  String get submitEdit => 'Submit Edit';

  @override
  String get editingApp => 'Editing app...';

  @override
  String get appEditSubmitted => 'Edit submitted successfully!';

  @override
  String get appEditFailed => 'App edit failed';

  @override
  String get newAppCreatedFromEdit => 'New app created from edit';

  @override
  String errorCreatingAppFromEdit(Object error) {
    return 'Error creating app from edit: $error';
  }

  @override
  String get saveCode => 'Save Code';

  @override
  String get saveCodeDirectly => 'Save Code Directly';

  @override
  String get codeSavedSuccessfully => 'Code saved successfully!';

  @override
  String errorSavingCode(Object error) {
    return 'Error saving code: $error';
  }

  @override
  String get editCodeDirectly => 'Edit Code Directly';

  @override
  String get editAppName => 'Edit App Name';

  @override
  String get appNameUpdated => 'App name updated successfully!';

  @override
  String errorUpdatingAppName(Object error) {
    return 'Error updating app name: $error';
  }

  @override
  String get consoleOutput => 'Console Output';

  @override
  String get noConsoleOutput => 'No console output yet';

  @override
  String get clearConsole => 'Clear Console';

  @override
  String get consoleOutputCopied => 'Console output copied to clipboard';

  @override
  String get appState => 'App State';

  @override
  String get saveState => 'Save State';

  @override
  String get loadState => 'Load State';

  @override
  String get stateSaved => 'State saved successfully!';

  @override
  String get stateLoaded => 'State loaded successfully!';

  @override
  String errorSavingState(Object error) {
    return 'Error saving state: $error';
  }

  @override
  String errorLoadingState(Object error) {
    return 'Error loading state: $error';
  }

  @override
  String appGenerationPrompt(Object description, Object name, Object steps) {
    return 'Create a single-page self-contained HTML application based on the following requirements:\n\nApp Name: $name\nDescription: $description\nSteps: $steps\n\nRequirements:\n1. The HTML must be completely self-contained with embedded CSS and JavaScript\n2. Do not reference any external resources\n3. Document the purpose, requirements, and approach in comments\n4. Use the following APIs to interact with the Flutter app:\n   - Synapse.runQuery(sql: string) - Query the app\'s database\n   - Synapse.storeAppState(state) - Store JSON serialized state\n   - Synapse.loadAppState() - Load saved state\n   - Synapse.chatAI(prompt) - Send prompt to AI and get response\n\nGenerate the complete HTML application now.';
  }

  @override
  String get deleteApp => 'Delete App';

  @override
  String get aiDebugOverlay => 'AI Debug Overlay';

  @override
  String get aiDebugOverlaySubtitle => 'View AI request/response logs';

  @override
  String get aiDebugOverlayTitle => 'AI Debug Overlay';

  @override
  String get refreshLogs => 'Refresh logs';

  @override
  String get clearLogs => 'Clear logs';

  @override
  String get basic => 'Basic';

  @override
  String get advanced => 'Advanced';

  @override
  String get addLibrary => 'Add Library';

  @override
  String get libraryName => 'Library Name';

  @override
  String get libraryNameHint => 'Enter library name';

  @override
  String get libraryUsage => 'Usage';

  @override
  String get libraryUsageHint => 'Describe how to use this library';

  @override
  String get libraryLink => 'Library Link';

  @override
  String get libraryLinkHint => 'Enter JavaScript library URL';

  @override
  String get removeLibrary => 'Remove Library';

  @override
  String get removeLink => 'Remove Link';

  @override
  String get noAiLogsAvailable => 'No AI logs available';

  @override
  String get aiLogsDescription => 'AI requests and responses will appear here';

  @override
  String get headers => 'Headers';

  @override
  String get body => 'Body';

  @override
  String get statusCode => 'Status Code';

  @override
  String get error => 'Error';

  @override
  String get importApp => 'Import App';

  @override
  String get viewApp => 'View App';

  @override
  String get exportApp => 'Export App';

  @override
  String get exportAppDescription =>
      'Review and update the app information before exporting. The app will be saved as a YAML file that can be shared or imported by others.';

  @override
  String get nameRequired => 'Name is required';

  @override
  String get name => 'Name';

  @override
  String get description => 'Description';

  @override
  String get author => 'Author';

  @override
  String get license => 'License';

  @override
  String get save => 'Save';

  @override
  String get private => 'Private';

  @override
  String get appExportedSuccessfully => 'App exported successfully';

  @override
  String errorExportingApp(Object error) {
    return 'Error exporting app: $error';
  }

  @override
  String get importProgress => 'Import Progress';

  @override
  String get importLog => 'Import Log';

  @override
  String get copyLog => 'Copy log';

  @override
  String get logCopiedToClipboard => 'Log copied to clipboard';

  @override
  String importingFromFile(Object filePath) {
    return 'Importing from File: $filePath';
  }

  @override
  String downloading(Object item) {
    return 'Downloading: $item';
  }

  @override
  String downloaded(Object item) {
    return 'Downloaded: $item';
  }

  @override
  String failedToDownload(Object item, Object status) {
    return 'Failed to download: $item (Status: $status)';
  }

  @override
  String errorDownloading(Object error, Object item) {
    return 'Error downloading $item: $error';
  }

  @override
  String get importComplete => 'Import complete!';

  @override
  String get importCompletedSuccessfully => 'Import completed successfully!';

  @override
  String get readingYamlFile => 'Reading YAML file...';

  @override
  String get validatingYamlStructure => 'Validating YAML structure...';

  @override
  String get processingAppData => 'Processing app data...';

  @override
  String get checkingForExistingApp => 'Checking for existing app...';

  @override
  String get creatingNewApp => 'Creating new app...';

  @override
  String get downloadingLibraries => 'Downloading libraries...';

  @override
  String get yamlFileReadSuccessfully => 'YAML file read successfully';

  @override
  String get yamlStructureValidated => 'YAML structure validated';

  @override
  String get appDataExtracted => 'App data extracted';

  @override
  String processingLibrary(Object libraryName) {
    return 'Processing library: $libraryName';
  }

  @override
  String downloadingLibrary(Object libraryName) {
    return 'Downloading library: $libraryName...';
  }

  @override
  String downloadingDependency(Object fileName) {
    return 'Downloading: $fileName...';
  }

  @override
  String get errorYamlFilePathEmpty => 'Error: YAML file path is empty';

  @override
  String get errorInvalidYamlFormat =>
      'Error: Invalid YAML format - expected a map';

  @override
  String get errorMissingRequiredFields =>
      'Error: Missing required fields in YAML';

  @override
  String get errorAppAlreadyExists =>
      'Error: App with this UUID already exists';

  @override
  String errorCreatingApp(Object error) {
    return 'Error creating app: $error';
  }

  @override
  String errorImportingApp(Object error) {
    return 'Error importing app: $error';
  }

  @override
  String get aiModelSettings => 'AI Model Settings';

  @override
  String get currentModel => 'Current Model';

  @override
  String get noModelSelected => 'No model selected';

  @override
  String get availableModels => 'Available Models';

  @override
  String get configured => 'Configured';

  @override
  String get notConfigured => 'Not Configured';

  @override
  String get current => 'Current';

  @override
  String get useModel => 'Use model';

  @override
  String get configureModel => 'Configure model';

  @override
  String get resetModel => 'Reset model';

  @override
  String switchedToModel(Object modelName) {
    return 'Switched to $modelName';
  }

  @override
  String errorSwitchingModel(Object error) {
    return 'Error switching model: $error';
  }

  @override
  String modelConfigurationUpdatedSuccessfully(Object modelName) {
    return '$modelName configuration updated successfully';
  }

  @override
  String resetModelConfiguration(Object modelName) {
    return 'Reset $modelName Configuration';
  }

  @override
  String resetModelConfigurationConfirmation(Object modelName) {
    return 'Are you sure you want to reset the configuration for $modelName? This will clear all settings and allow you to reconfigure the model.';
  }

  @override
  String modelConfigurationResetSuccessfully(Object modelName) {
    return '$modelName configuration reset successfully';
  }

  @override
  String errorResettingConfiguration(Object error) {
    return 'Error resetting configuration: $error';
  }

  @override
  String configureModelTitle(Object modelName) {
    return 'Configure $modelName';
  }

  @override
  String get loadPreset => 'Load a Preset';

  @override
  String get selectPreset => 'Select a preset';

  @override
  String get unknownPreset => 'Unknown Preset';

  @override
  String get apiEndpoint => 'API Endpoint';

  @override
  String get apiEndpointDescription =>
      'Enter the OpenAI-compatible API endpoint URL';

  @override
  String get endpointUrl => 'Endpoint URL';

  @override
  String get endpointUrlHint => 'https://api.openai.com/v1/chat/completions';

  @override
  String get pleaseEnterEndpointUrl => 'Please enter an endpoint URL';

  @override
  String get pleaseEnterValidUrl => 'Please enter a valid URL';

  @override
  String get modelName => 'Model Name';

  @override
  String get modelNameDescription =>
      'Enter the model name to use (e.g., gpt-4, gpt-3.5-turbo, claude-3-sonnet)';

  @override
  String get modelNameHint => 'gpt-4';

  @override
  String get pleaseEnterModelName => 'Please enter a model name';

  @override
  String get displayName => 'Display Name';

  @override
  String get displayNameDescription =>
      'A custom name to display in the app for this model';

  @override
  String get displayNameHint => 'My Custom Model';

  @override
  String get tokenLimits => 'Token Limits';

  @override
  String get tokenLimitsDescription =>
      'Configure the maximum input and output tokens for this model';

  @override
  String get maxInputTokens => 'Max Input Tokens';

  @override
  String get maxInputTokensHint => '100000';

  @override
  String get maxOutputTokens => 'Max Output Tokens';

  @override
  String get maxOutputTokensHint => '4000';

  @override
  String get required => 'Required';

  @override
  String get mustBePositiveNumber => 'Must be a positive number';

  @override
  String get modelCapabilities => 'Model Capabilities';

  @override
  String get modelCapabilitiesDescription =>
      'Select which capabilities this model supports';

  @override
  String get imageProcessing => 'Image Processing';

  @override
  String get imageProcessingDescription => 'Can analyze and understand images';

  @override
  String get documentUnderstanding => 'Document Understanding';

  @override
  String get documentUnderstandingDescription =>
      'Can process PDFs and documents';

  @override
  String get audioProcessing => 'Audio Processing';

  @override
  String get audioProcessingDescription => 'Can transcribe and analyze audio';

  @override
  String get videoProcessing => 'Video Processing';

  @override
  String get videoProcessingDescription => 'Can analyze video content';

  @override
  String get geminiModelDescription =>
      'Google\'s most advanced model with full multimodal capabilities';

  @override
  String get openaiCompatibleModelDescription =>
      'Compatible with OpenAI API endpoints with configurable capabilities';

  @override
  String get geminiModelDescriptionDetailed =>
      'Google\'s most advanced model with full multimodal capabilities including document understanding.';

  @override
  String get openaiCompatibleModelDescriptionDetailed =>
      'Compatible with OpenAI API endpoints. Configure the endpoint URL and select supported capabilities.';

  @override
  String get geminiApiKeyDescription =>
      'Get your API key from Google AI Studio';

  @override
  String get openaiCompatibleApiKeyDescription =>
      'Get your API key from your OpenAI-compatible service provider';

  @override
  String errorConfiguringModel(Object error) {
    return 'Error configuring model: $error';
  }

  @override
  String get recovery => 'Recovery';

  @override
  String get recoverySubtitle => 'Backup and restore your notes';

  @override
  String get exportAllNotes => 'Export All Notes';

  @override
  String get exportAllNotesDescription =>
      'Create a complete backup of all your notes and attachments';

  @override
  String get exporting => 'Exporting...';

  @override
  String get exportLogs => 'Export Logs';

  @override
  String get previousExports => 'Previous Exports';

  @override
  String get saveAgain => 'Save Again';

  @override
  String get backupAllNotes => 'Backup All Notes';

  @override
  String get backupAllNotesDescription =>
      'Create a complete backup of all your notes and attachments. The backup will be saved as a zip file that you can download.';

  @override
  String get creatingBackup => 'Creating Backup...';

  @override
  String get backupLogs => 'Backup Logs';

  @override
  String get previousBackups => 'Previous Backups';

  @override
  String get backup => 'Backup';

  @override
  String get startingBackupProcess => 'Starting backup process...';

  @override
  String createdTempDirectory(Object path) {
    return 'Created temp directory: $path';
  }

  @override
  String get forcingDatabaseCheckpoint => 'Forcing database checkpoint...';

  @override
  String get databaseCopiedSuccessfully => 'Database copied successfully';

  @override
  String get databaseFileNotFound => 'Database file not found';

  @override
  String get attachmentsDirectoryCopiedSuccessfully =>
      'Attachments directory copied successfully';

  @override
  String get noAttachmentsDirectoryFound =>
      'No attachments directory found, creating empty one';

  @override
  String get updatingAttachmentPathsInCopiedDatabase =>
      'Updating attachment paths in copied database...';

  @override
  String get databaseConsistencyVerified => 'Database consistency verified';

  @override
  String get creatingZipArchive => 'Creating zip archive...';

  @override
  String backupCompleted(Object path) {
    return 'Backup completed: $path';
  }

  @override
  String backupFailed(Object error) {
    return 'Backup failed: $error';
  }

  @override
  String foundAttachmentsWithAbsolutePaths(Object count) {
    return 'Found $count attachments with absolute paths to update';
  }

  @override
  String copiedAndUpdated(Object original, Object unique) {
    return 'Copied and updated: $original -> $unique';
  }

  @override
  String warningSourceFileNotFound(Object path) {
    return 'Warning: Source file not found: $path';
  }

  @override
  String deletedBackup(Object name) {
    return 'Deleted backup: $name';
  }

  @override
  String errorDeletingBackup(Object error) {
    return 'Error deleting backup: $error';
  }

  @override
  String backupFileNotFound(Object name) {
    return 'Backup file not found: $name';
  }

  @override
  String errorSavingBackupAgain(Object error) {
    return 'Error saving backup again: $error';
  }

  @override
  String get importBackup => 'Import Backup';

  @override
  String get importBackupDescription => 'Restore your notes from a backup file';

  @override
  String get importingBackup => 'Importing Backup...';

  @override
  String get importLogs => 'Import Logs';

  @override
  String get selectBackupFile => 'Select Backup File';

  @override
  String get selectBackupFileDescription =>
      'Choose a backup zip file to restore from';

  @override
  String importFailed(Object error) {
    return 'Import failed: $error';
  }

  @override
  String get invalidBackupFile => 'Invalid backup file format';

  @override
  String get backupVersionTooNew =>
      'Backup is from a newer version of the app. Please update the app first.';

  @override
  String get checkpointingDatabase => 'Checkpointing current database...';

  @override
  String get copyingDatabaseToStaging =>
      'Copying database to staging directory...';

  @override
  String get extractingBackupFile => 'Extracting backup file...';

  @override
  String get validatingBackupDatabase =>
      'Validating backup database version...';

  @override
  String get migratingBackupDatabase =>
      'Migrating backup database to current version...';

  @override
  String get mergingNotes => 'Merging notes...';

  @override
  String get mergingSubNotes => 'Merging sub-notes...';

  @override
  String get mergingTags => 'Merging tags...';

  @override
  String get mergingRelationships => 'Merging relationships...';

  @override
  String get mergingFilters => 'Merging filters...';

  @override
  String get mergingUserApps => 'Merging user apps...';

  @override
  String get copyingAttachments => 'Copying attachments...';

  @override
  String get swappingDatabases => 'Swapping databases...';

  @override
  String get reloadingData => 'Reloading data...';

  @override
  String get undoBackup => 'Undo Backup';

  @override
  String get undoBackupDescription => 'Restore the original database';

  @override
  String get undoBackupConfirmation =>
      'Are you sure you want to undo the backup? This will restore your original database and lose any changes made since the import.';

  @override
  String get undoBackupCompleted => 'Backup undone successfully!';

  @override
  String errorUndoingBackup(Object error) {
    return 'Error undoing backup: $error';
  }

  @override
  String get backupRestored => 'Backup restored successfully!';

  @override
  String errorRestoringBackup(Object error) {
    return 'Error restoring backup: $error';
  }

  @override
  String get cloneApp => 'Clone App';

  @override
  String get appClonedSuccessfully => 'App cloned successfully!';

  @override
  String errorCloningApp(Object error) {
    return 'Error cloning app: $error';
  }

  @override
  String get mcpSettings => 'MCP Settings';

  @override
  String get mcpSettingsSubtitle =>
      'Configure Model Context Protocol endpoints';

  @override
  String errorLoadingEndpoints(Object error) {
    return 'Error loading endpoints: $error';
  }

  @override
  String get addMcpEndpoint => 'Add MCP Endpoint';

  @override
  String get addMcpEndpointTitle => 'Add MCP Endpoint';

  @override
  String get nameHint => 'My MCP Server';

  @override
  String get baseUrl => 'Base URL';

  @override
  String get baseUrlHint =>
      'https://api.example.com or https://server.smithery.ai/@user/server/mcp?api_key=xxx';

  @override
  String get baseUrlHelperText =>
      'Include query params for auth if needed (e.g., Smithery)';

  @override
  String get transportType => 'Transport Type';

  @override
  String get bearerTokenOptional => 'Bearer Token (Optional)';

  @override
  String get bearerTokenHint => 'Leave empty if auth is in URL params';

  @override
  String get bearerTokenHelperText =>
      'Optional: For header-based authentication';

  @override
  String get pleaseProvideNameAndUrl => 'Please provide name and URL';

  @override
  String addedEndpoint(Object name) {
    return 'Added endpoint: $name';
  }

  @override
  String errorAddingEndpoint(Object error) {
    return 'Error: $error';
  }

  @override
  String get deleteEndpoint => 'Delete Endpoint';

  @override
  String deleteEndpointConfirmation(Object name) {
    return 'Are you sure you want to delete \"$name\"? This will also delete cached tools.';
  }

  @override
  String deletedEndpoint(Object name) {
    return 'Deleted endpoint: $name';
  }

  @override
  String errorDeletingEndpoint(Object error) {
    return 'Error deleting endpoint: $error';
  }

  @override
  String refreshedToolsFor(Object name) {
    return 'Refreshed tools for $name';
  }

  @override
  String errorRefreshingTools(Object error) {
    return 'Error refreshing tools: $error';
  }

  @override
  String get tools => 'Tools';

  @override
  String toolsFor(Object name) {
    return 'Tools - $name';
  }

  @override
  String get fetched => 'Fetched';

  @override
  String toolsCount(Object count) {
    return 'Tools: $count';
  }

  @override
  String get noToolsAvailable => 'No tools available';

  @override
  String noToolsCachedFor(Object name) {
    return 'No tools cached for $name. Click refresh to fetch tools.';
  }

  @override
  String get refreshTools => 'Refresh Tools';

  @override
  String get viewTools => 'View Tools';

  @override
  String get noMcpEndpointsConfigured => 'No MCP endpoints configured';

  @override
  String get clickAddMcpEndpointToGetStarted =>
      'Click \"Add MCP Endpoint\" to get started';

  @override
  String get noteActionApp => 'Note Action App';

  @override
  String get noteActionAppSubtitle =>
      'This type of app will operate specifically on pre-selected notes';

  @override
  String get appType => 'Type';

  @override
  String get appTypeHint => 'Select how this app should behave';

  @override
  String get appTypeNormal => 'Normal';

  @override
  String get appTypeNoteAction => 'Note Action';

  @override
  String get appTypeAiTool => 'AI Tool';

  @override
  String get aiToolAppSubtitle =>
      'Expose custom JavaScript functions that the AI can call or you can test in a playground';

  @override
  String get aiTools => 'AI Tools';

  @override
  String aiToolStartError(String appName, String error) {
    return 'Failed to start AI tool \"$appName\": $error';
  }

  @override
  String get aiToolMissingRevision =>
      'This AI tool does not have a selected revision yet.';

  @override
  String get aiToolDefinitionParseError =>
      'The selected revision does not contain a valid AI tool specification.';

  @override
  String get imageAttachmentsOptional => 'Image Attachments (Optional)';

  @override
  String get imageAttachmentsSubtitle =>
      'Attach images to help explain what you want the AI to create';

  @override
  String get addImage => 'Add Image';

  @override
  String get noLibrariesAddedYet =>
      'No libraries added yet. Click \"Add Library\" to get started.';

  @override
  String get conversation => 'Conversation';

  @override
  String get aiConversation => 'AI Conversation';

  @override
  String get aiConversationDescription =>
      'Start a conversation with AI about your notes';

  @override
  String get startConversation => 'Start Conversation';

  @override
  String get conversationTree => 'Conversation Tree';

  @override
  String get conversations => 'Conversations';

  @override
  String conversationCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'conversations',
      one: 'conversation',
    );
    return '$count $_temp0';
  }

  @override
  String get noConversations => 'No conversations';

  @override
  String get conversationsWithThisNote => 'Conversations with this note';

  @override
  String get typeYourMessage => 'Type your message...';

  @override
  String get immersiveMode => 'Immersive Mode';

  @override
  String get aiChat => 'AI Chat';

  @override
  String get outline => 'Outline';

  @override
  String get expand => 'Expand';

  @override
  String get collapse => 'Collapse';

  @override
  String get annotate => 'Annotate';

  @override
  String get askAiHint => 'Ask the AI about this note...';

  @override
  String get send => 'Send';

  @override
  String get startConversationHint => 'Start by asking the AI about your note.';

  @override
  String unsupportedAttachment(String type) {
    return 'Unsupported attachment type ($type).';
  }

  @override
  String get openAttachment => 'Open attachment';

  @override
  String get failedToLoadAttachment => 'Failed to load attachment.';

  @override
  String failedToOpenAttachment(String error) {
    return 'Failed to open attachment: $error';
  }

  @override
  String get cancellingRequest => 'Cancelling request...';

  @override
  String get takePhotoAttachment => 'Take photo';

  @override
  String get mcpTools => 'MCP Tools';

  @override
  String get mcpAndLocalTools => 'MCP & Local Tools';

  @override
  String get active => 'active';

  @override
  String toolsAvailable(Object count) {
    return '$count tools available';
  }

  @override
  String get manageNotes => 'Manage Notes';

  @override
  String get viewTree => 'View Tree';

  @override
  String noteIncluded(Object count) {
    return '$count note(s) included';
  }

  @override
  String get messageCopiedToClipboard => 'Message copied to clipboard';

  @override
  String get addToNote => 'Add to Note';

  @override
  String get forkConversation => 'Fork conversation';

  @override
  String get forkConversationConfirm => 'Fork this conversation?';

  @override
  String get fork => 'Fork';

  @override
  String get forkedConversationSuccess => 'Conversation forked successfully';

  @override
  String errorForkingConversation(Object error) {
    return 'Error forking conversation: $error';
  }

  @override
  String get selectNotesForConversation => 'Select notes for conversation';

  @override
  String get selectNotesForNoteActionApp => 'Select Notes for Note Action App';

  @override
  String get selectNotesToAddToContext => 'Select Notes to add to context';

  @override
  String proceedWithNotes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'notes',
      one: 'note',
    );
    return 'Proceed with $count $_temp0';
  }

  @override
  String notesSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'notes',
      one: 'note',
    );
    return '$count $_temp0 selected';
  }

  @override
  String noNotesFoundMatching(String query) {
    return 'No notes found matching \"$query\"';
  }

  @override
  String get notesAndContext => 'Notes and Context';

  @override
  String get addNotes => 'Add Notes';

  @override
  String get addNotesToConversation => 'Add Notes';

  @override
  String get clearAllNotes => 'Clear All';

  @override
  String get missingNotes => 'Missing Notes';

  @override
  String get missingNotesMessage =>
      'This conversation references notes that no longer exist:';

  @override
  String get missingNotesWillCleanup =>
      'These references will be automatically cleaned up.';

  @override
  String get cleanUp => 'Clean Up';

  @override
  String get ok => 'OK';

  @override
  String get refreshTree => 'Refresh tree';

  @override
  String get noConversationsFound =>
      'No conversations found. Start a new conversation to see the tree.';

  @override
  String get treeRefreshedSuccessfully => 'Tree refreshed successfully';

  @override
  String errorRefreshingTree(Object error) {
    return 'Error refreshing tree: $error';
  }

  @override
  String get selectInteractionToViewDetails =>
      'Select an interaction to view details';

  @override
  String get deleteInteraction => 'Delete Interaction';

  @override
  String get deleteInteractionConfirm =>
      'Are you sure you want to delete this interaction and all its descendants? This action cannot be undone.';

  @override
  String get interactionDeletedSuccessfully =>
      'Interaction deleted successfully';

  @override
  String errorDeletingInteraction(Object error) {
    return 'Error deleting interaction: $error';
  }

  @override
  String get forkFromHere => 'Fork from here';

  @override
  String get deleteInteractionAction => 'Delete interaction';

  @override
  String get deleteConversation => 'Delete Conversation';

  @override
  String get confirmDeleteConversation =>
      'Are you sure you want to delete this conversation? This action cannot be undone.';

  @override
  String get conversationDeletedSuccessfully =>
      'Conversation deleted successfully';

  @override
  String errorDeletingConversation(Object error) {
    return 'Error deleting conversation: $error';
  }

  @override
  String get saveSelectedNodesAsNote => 'Save selected nodes as note';

  @override
  String get createFromSelected => 'Create from selected';

  @override
  String get exitMultiSelect => 'Exit multi-select';

  @override
  String get pleaseSelectNodesFirst => 'Please select nodes first';

  @override
  String get interaction => 'Interaction';

  @override
  String get open => 'Open';

  @override
  String get user => 'User';

  @override
  String get ai => 'AI';

  @override
  String get justNow => 'Just now';

  @override
  String get addNoteDialogTitle => 'Add to Note';

  @override
  String get addNoteDialogMessage =>
      'How would you like to add this content to your notes?';

  @override
  String get addAsIs => 'Add as-is';

  @override
  String get addAsIsDescription =>
      'Add the content directly without modification';

  @override
  String get letAICreateNote => 'Let AI create note';

  @override
  String get letAICreateNoteDescription =>
      'Use AI to summarize or transform the content';

  @override
  String get noteTitle => 'Note Title';

  @override
  String get enterNoteTitlePrompt => 'Enter a title for the new note:';

  @override
  String get noteTitleHint => 'Note title';

  @override
  String multipleNotesCreatedSuccessfully(Object count) {
    return '$count notes created successfully';
  }

  @override
  String get aiNoteCreator => 'AI Note Creator';

  @override
  String get aiNoteCreatorInstructions =>
      'The AI will use the conversation content, along with any additional context you provide below, to create note(s) based on your prompt.';

  @override
  String get prompt => 'Prompt';

  @override
  String get promptHint => 'Describe what you want the AI to do...';

  @override
  String get promptTip =>
      'Tip: The default \"Summarize\" will create a concise summary. You can change this to any instruction like \"Extract action items\", \"Create a detailed outline\", etc.';

  @override
  String additionalContextNotes(num count) {
    return 'Additional Context Notes ($count)';
  }

  @override
  String get noAdditionalNotesSelected =>
      'No additional notes selected. The AI will only use the conversation content.';

  @override
  String get proceed => 'Proceed';

  @override
  String get pleaseEnterPrompt => 'Please enter a prompt';

  @override
  String get view => 'View';

  @override
  String errorSavingNodes(Object error) {
    return 'Error saving nodes: $error';
  }

  @override
  String get cancelAiRequest => 'Cancel AI request';

  @override
  String get copy => 'Copy';

  @override
  String attachedFiles(Object count) {
    return 'Attached Files ($count)';
  }

  @override
  String get you => 'You';

  @override
  String get errorLoadingData => 'Error loading data';

  @override
  String get retry => 'Retry';

  @override
  String get errorProcessingSharedContent => 'Error Processing Shared Content';

  @override
  String get whatWouldYouLikeToDo => 'What would you like to do?';

  @override
  String get createNewNoteWithThisContent =>
      'Create a new note with this content';

  @override
  String get addThisContentToExistingNote =>
      'Add this content to an existing note';

  @override
  String get selectNote => 'Select a note...';

  @override
  String showingNotes(int filteredCount, int totalCount) {
    return 'Showing $filteredCount of $totalCount notes';
  }

  @override
  String get noteDetails => 'Note Details';

  @override
  String get contentPreview => 'Content Preview';

  @override
  String get selectedTags => 'Selected tags:';

  @override
  String get availableTags => 'Available tags:';

  @override
  String get webContentExtractionNotSupportedLinux =>
      'Web content extraction is not supported on Linux.';

  @override
  String get pleaseUseOtherPlatformsForWebExtraction =>
      'Please use Android, iOS, or Web to extract web content.';

  @override
  String get extractWebContent => 'Extract Web Content';

  @override
  String get extracting => 'Extracting...';

  @override
  String get extractContentUsingAiForBetterResults =>
      'Extract content using AI for better results';

  @override
  String get extractWithAi => 'Extract with AI (Slower)';

  @override
  String get extractingWithAi => 'Extracting with AI...';

  @override
  String get asIs => 'As-Is';

  @override
  String get loadingWebPage => 'Loading web page...';

  @override
  String get imageDetected => 'Image Detected';

  @override
  String get extractImageContent => 'Extract Image Content';

  @override
  String get extractingImageContent => 'Extracting...';

  @override
  String get pdfDetected => 'PDF Detected';

  @override
  String get extractPdfContent => 'Extract PDF Content';

  @override
  String get extractingPdfContent => 'Extracting...';

  @override
  String get sharedImage => 'Shared Image';

  @override
  String get pleaseSelectNoteToAppend => 'Please select a note to append to';

  @override
  String get contentAppendedSuccessfully => 'Content appended successfully!';

  @override
  String get extractingWebContent => 'Extracting Web Content';

  @override
  String get sharedContentFrom => 'Shared content from';

  @override
  String get sharedUrl => 'Shared URL';

  @override
  String get unknownSource => 'unknown source';

  @override
  String failedToPrepareNote(String error) {
    return 'Failed to prepare note: $error';
  }

  @override
  String errorExtractingWebContent(String error) {
    return 'Error extracting web content: $error';
  }

  @override
  String failedToLoadWebPage(String message) {
    return 'Failed to load web page: $message';
  }

  @override
  String get extractionCancelledByUser => 'Extraction cancelled by user';

  @override
  String readabilityExtractionFailed(String error) {
    return 'Readability extraction failed: $error';
  }

  @override
  String get failedToExtractContentFromWebPage =>
      'Failed to extract content from the web page';

  @override
  String get processingWithAi => 'Processing with AI...';

  @override
  String get checkingApiKey => 'Checking API key...';

  @override
  String errorExtractingImageContent(String error) {
    return 'Error extracting image content: $error';
  }

  @override
  String errorExtractingPdfContent(String error) {
    return 'Error extracting PDF content: $error';
  }

  @override
  String get unknownImage => 'Unknown image';

  @override
  String get unknownPdf => 'Unknown PDF';

  @override
  String get newConversation => 'New Conversation';

  @override
  String get oneHourAgo => '1 hour ago';

  @override
  String get twelveHoursAgo => '12 hours ago';

  @override
  String get oneDayAgo => '1 day ago';

  @override
  String get threeDaysAgo => '3 days ago';

  @override
  String get sevenDaysAgo => '7 days ago';

  @override
  String get fifteenDaysAgo => '15 days ago';

  @override
  String get oneMonthAgo => '1 month ago';

  @override
  String get sixMonthsAgo => '6 months ago';

  @override
  String get allTime => 'All time';

  @override
  String get custom => 'Custom';

  @override
  String get first => 'First';

  @override
  String get last => 'Last';

  @override
  String get deleteInteractionWhatToDelete => 'What do you want to delete?';

  @override
  String get deleteOnlyNodesInFilter => 'Delete only nodes in this filter';

  @override
  String get deleteNodeAndDescendants => 'Delete this node and all descendants';

  @override
  String get tokenTab => 'Token';

  @override
  String get oauthTab => 'OAuth';

  @override
  String get autoConfigure => 'Auto Configure';

  @override
  String get login => 'Login';

  @override
  String get authorizationEndpoint => 'Authorization Endpoint';

  @override
  String get tokenEndpoint => 'Token Endpoint';

  @override
  String get clientId => 'Client ID';

  @override
  String get clientSecretOptionalForPkce => 'Client Secret (Optional for PKCE)';

  @override
  String get scope => 'Scope';

  @override
  String get usePkceNoClientSecret => 'Use PKCE (no client secret)';

  @override
  String get oauthDiscoveryMetadataUrlOptional =>
      'OAuth Discovery Page: Metadata URL (optional)';

  @override
  String get discover => 'Discover';

  @override
  String get registerClient => 'Register Client';

  @override
  String get register => 'Register';

  @override
  String get editMcpEndpoint => 'Edit MCP Endpoint';

  @override
  String get metadataUrlOptional => 'Metadata URL (optional)';

  @override
  String get metadataUrlOptionalHint =>
      'Leave blank to auto-detect using RFC 9728';

  @override
  String get oauthDiscovery => 'OAuth Discovery';

  @override
  String get openInTree => 'Open in Tree';

  @override
  String get addConversationDialogTitle => 'Add Conversation';

  @override
  String get addConversationDialogMessage =>
      'How would you like to create this conversation?';

  @override
  String get addDirectly => 'Add directly';

  @override
  String get addDirectlyDescription =>
      'Create the conversation directly with selected nodes as context';

  @override
  String get addWithAIProcessing => 'Add with AI processing';

  @override
  String get addWithAIProcessingDescription =>
      'Use AI to process the content first (e.g., summarize) then create the conversation';

  @override
  String get conversationTitle => 'Conversation Title';

  @override
  String get enterConversationTitlePrompt =>
      'Enter a title for the new conversation:';

  @override
  String get conversationTitleHint => 'Conversation title';

  @override
  String get createConversation => 'Create Conversation';

  @override
  String conversationCreatedSuccessfully(String title) {
    return 'Conversation \"$title\" created successfully';
  }

  @override
  String errorCreatingConversation(String error) {
    return 'Error creating conversation: $error';
  }

  @override
  String get aiConversationCreator => 'AI Conversation Creator';

  @override
  String get aiConversationCreatorInstructions =>
      'The AI will process the conversation content, along with any additional context you provide below, to create a conversation based on your prompt.';

  @override
  String get selectRelationshipType => 'Select Relationship Type';

  @override
  String selectRelationshipTypeForNotes(int noteCount) {
    String _temp0 = intl.Intl.pluralLogic(
      noteCount,
      locale: localeName,
      other: 'notes',
      one: 'note',
    );
    return 'Select the type of relationship for $noteCount $_temp0:';
  }

  @override
  String get relationshipType => 'Relationship Type';

  @override
  String linkNotes(int noteCount) {
    String _temp0 = intl.Intl.pluralLogic(
      noteCount,
      locale: localeName,
      other: 'Notes',
      one: 'Note',
    );
    return 'Link $noteCount $_temp0';
  }

  @override
  String get customRelationshipType => 'Custom Relationship Type';

  @override
  String get enterCustomRelationshipType => 'Enter custom relationship type';

  @override
  String get customEllipsis => 'Custom...';

  @override
  String get confirmRemoveLink => 'Are you sure you want to remove this link?';

  @override
  String get remove => 'Remove';

  @override
  String get linkNotesDialogTitle => 'Link Notes';

  @override
  String get link => 'Link';

  @override
  String linkNoteTo(String noteTitle) {
    return 'Link \"$noteTitle\" to:';
  }

  @override
  String get audioTranscription => 'Audio Transcription';

  @override
  String get transcribingAudio => 'Transcribing audio...';

  @override
  String get transcriptionAddedToNote => 'Transcription added to note';

  @override
  String errorTranscribingAudio(String error) {
    return 'Error transcribing audio: $error';
  }

  @override
  String errorAddingTranscription(String error) {
    return 'Error adding transcription: $error';
  }
}
