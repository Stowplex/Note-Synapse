import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Note Synapse'**
  String get appTitle;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @appearanceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Theme and display settings'**
  String get appearanceSubtitle;

  /// No description provided for @aiApi.
  ///
  /// In en, this message translates to:
  /// **'AI API'**
  String get aiApi;

  /// No description provided for @aiApiSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure your AI API key'**
  String get aiApiSubtitle;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// No description provided for @darkModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Toggle between light and dark theme'**
  String get darkModeSubtitle;

  /// No description provided for @apiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @noApiKeyConfigured.
  ///
  /// In en, this message translates to:
  /// **'No API key configured'**
  String get noApiKeyConfigured;

  /// No description provided for @updateApiKey.
  ///
  /// In en, this message translates to:
  /// **'Update API Key'**
  String get updateApiKey;

  /// No description provided for @updateApiKeySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter a new API key'**
  String get updateApiKeySubtitle;

  /// No description provided for @resetApiKey.
  ///
  /// In en, this message translates to:
  /// **'Reset API Key'**
  String get resetApiKey;

  /// No description provided for @resetApiKeySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Clear current API key and return to setup'**
  String get resetApiKeySubtitle;

  /// No description provided for @currentApiKey.
  ///
  /// In en, this message translates to:
  /// **'Current API Key'**
  String get currentApiKey;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @enterNewApiKey.
  ///
  /// In en, this message translates to:
  /// **'Enter your new Gemini API key:'**
  String get enterNewApiKey;

  /// No description provided for @apiKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKeyLabel;

  /// No description provided for @apiKeyHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your API key here'**
  String get apiKeyHint;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get reset;

  /// No description provided for @resetApiKeyConfirmation.
  ///
  /// In en, this message translates to:
  /// **'This will clear your current API key and return you to the setup screen. Are you sure?'**
  String get resetApiKeyConfirmation;

  /// No description provided for @apiKeyUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'API key updated successfully'**
  String get apiKeyUpdatedSuccessfully;

  /// No description provided for @errorUpdatingApiKey.
  ///
  /// In en, this message translates to:
  /// **'Error updating API key: {error}'**
  String errorUpdatingApiKey(Object error);

  /// No description provided for @errorResettingApiKey.
  ///
  /// In en, this message translates to:
  /// **'Error resetting API key: {error}'**
  String errorResettingApiKey(Object error);

  /// No description provided for @welcomeToNoteSynapse.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Note Synapse'**
  String get welcomeToNoteSynapse;

  /// No description provided for @aiPoweredNoteTaking.
  ///
  /// In en, this message translates to:
  /// **'Your AI-powered note-taking companion'**
  String get aiPoweredNoteTaking;

  /// No description provided for @setupRequired.
  ///
  /// In en, this message translates to:
  /// **'Setup Required'**
  String get setupRequired;

  /// No description provided for @setupRequiredDescription.
  ///
  /// In en, this message translates to:
  /// **'To use AI features, you need a Gemini API key from Google AI Studio.'**
  String get setupRequiredDescription;

  /// No description provided for @getApiKey.
  ///
  /// In en, this message translates to:
  /// **'Get API Key'**
  String get getApiKey;

  /// No description provided for @geminiApiKey.
  ///
  /// In en, this message translates to:
  /// **'Gemini API Key'**
  String get geminiApiKey;

  /// No description provided for @continueButton.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueButton;

  /// No description provided for @apiKeySecurityNote.
  ///
  /// In en, this message translates to:
  /// **'Your API key is stored securely on your device and never shared.'**
  String get apiKeySecurityNote;

  /// No description provided for @pleaseEnterApiKey.
  ///
  /// In en, this message translates to:
  /// **'Please enter an API key'**
  String get pleaseEnterApiKey;

  /// No description provided for @failedToSaveApiKey.
  ///
  /// In en, this message translates to:
  /// **'Failed to save API key: {error}'**
  String failedToSaveApiKey(Object error);

  /// No description provided for @notes.
  ///
  /// In en, this message translates to:
  /// **'Notes'**
  String get notes;

  /// No description provided for @calendar.
  ///
  /// In en, this message translates to:
  /// **'Calendar'**
  String get calendar;

  /// No description provided for @addNewContent.
  ///
  /// In en, this message translates to:
  /// **'Add New Content'**
  String get addNewContent;

  /// No description provided for @newAiAction.
  ///
  /// In en, this message translates to:
  /// **'New AI Action'**
  String get newAiAction;

  /// No description provided for @newAiActionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create content using AI'**
  String get newAiActionSubtitle;

  /// No description provided for @newNote.
  ///
  /// In en, this message translates to:
  /// **'New Note'**
  String get newNote;

  /// No description provided for @newNoteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a regular note'**
  String get newNoteSubtitle;

  /// No description provided for @newTask.
  ///
  /// In en, this message translates to:
  /// **'New Task'**
  String get newTask;

  /// No description provided for @newTaskSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create a new task'**
  String get newTaskSubtitle;

  /// No description provided for @newVoice.
  ///
  /// In en, this message translates to:
  /// **'New Voice'**
  String get newVoice;

  /// No description provided for @newVoiceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Record voice note'**
  String get newVoiceSubtitle;

  /// No description provided for @newPicture.
  ///
  /// In en, this message translates to:
  /// **'New Picture'**
  String get newPicture;

  /// No description provided for @newPictureSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add image from camera or gallery'**
  String get newPictureSubtitle;

  /// No description provided for @attachment.
  ///
  /// In en, this message translates to:
  /// **'Attachment'**
  String get attachment;

  /// No description provided for @attachmentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Add file attachment'**
  String get attachmentSubtitle;

  /// No description provided for @newNoteFromClipboard.
  ///
  /// In en, this message translates to:
  /// **'New Note from Clipboard'**
  String get newNoteFromClipboard;

  /// No description provided for @newNoteFromClipboardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create note from clipboard content'**
  String get newNoteFromClipboardSubtitle;

  /// No description provided for @recordingStarted.
  ///
  /// In en, this message translates to:
  /// **'Recording started'**
  String get recordingStarted;

  /// No description provided for @failedToStartRecording.
  ///
  /// In en, this message translates to:
  /// **'Failed to start recording. Please check microphone permissions.'**
  String get failedToStartRecording;

  /// No description provided for @failedToStartRecordingLinux.
  ///
  /// In en, this message translates to:
  /// **'Failed to start recording. Please check if gstreamer and PulseAudio are installed.'**
  String get failedToStartRecordingLinux;

  /// No description provided for @errorStartingRecording.
  ///
  /// In en, this message translates to:
  /// **'Error starting recording: {error}'**
  String errorStartingRecording(Object error);

  /// No description provided for @audioNoteSavedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Audio note saved successfully!'**
  String get audioNoteSavedSuccessfully;

  /// No description provided for @errorStoppingRecording.
  ///
  /// In en, this message translates to:
  /// **'Error stopping recording: {error}'**
  String errorStoppingRecording(Object error);

  /// No description provided for @selectImageSource.
  ///
  /// In en, this message translates to:
  /// **'Select Image Source'**
  String get selectImageSource;

  /// No description provided for @chooseImageSource.
  ///
  /// In en, this message translates to:
  /// **'Choose how you want to add an image'**
  String get chooseImageSource;

  /// No description provided for @camera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// No description provided for @takePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take Photo'**
  String get takePhoto;

  /// No description provided for @gallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get gallery;

  /// No description provided for @imageNoteCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Image note created successfully!'**
  String get imageNoteCreatedSuccessfully;

  /// No description provided for @errorCreatingImageNote.
  ///
  /// In en, this message translates to:
  /// **'Error creating image note: {error}'**
  String errorCreatingImageNote(Object error);

  /// No description provided for @errorPickingImage.
  ///
  /// In en, this message translates to:
  /// **'Error picking image: {error}'**
  String errorPickingImage(Object error);

  /// No description provided for @clipboardIsEmpty.
  ///
  /// In en, this message translates to:
  /// **'Clipboard is empty'**
  String get clipboardIsEmpty;

  /// No description provided for @errorAccessingClipboard.
  ///
  /// In en, this message translates to:
  /// **'Error accessing clipboard: {error}'**
  String errorAccessingClipboard(Object error);

  /// No description provided for @unableToAccessFileData.
  ///
  /// In en, this message translates to:
  /// **'Unable to access file data'**
  String get unableToAccessFileData;

  /// No description provided for @errorPickingFile.
  ///
  /// In en, this message translates to:
  /// **'Error picking file: {error}'**
  String errorPickingFile(Object error);

  /// No description provided for @fileNoteCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'File note created successfully!'**
  String get fileNoteCreatedSuccessfully;

  /// No description provided for @errorCreatingFileNote.
  ///
  /// In en, this message translates to:
  /// **'Error creating file note: {error}'**
  String errorCreatingFileNote(Object error);

  /// No description provided for @recording.
  ///
  /// In en, this message translates to:
  /// **'Recording...'**
  String get recording;

  /// No description provided for @voiceNoteRecording.
  ///
  /// In en, this message translates to:
  /// **'Voice Note Recording'**
  String get voiceNoteRecording;

  /// No description provided for @recordingTapStop.
  ///
  /// In en, this message translates to:
  /// **'Recording... Tap stop when done'**
  String get recordingTapStop;

  /// No description provided for @recordingWillContinue.
  ///
  /// In en, this message translates to:
  /// **'Recording will continue until you tap \"Stop Recording\"'**
  String get recordingWillContinue;

  /// No description provided for @startRecordingVoiceNote.
  ///
  /// In en, this message translates to:
  /// **'Start recording your voice note'**
  String get startRecordingVoiceNote;

  /// No description provided for @startRecording.
  ///
  /// In en, this message translates to:
  /// **'Start Recording'**
  String get startRecording;

  /// No description provided for @stopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop Recording'**
  String get stopRecording;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @languageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select your preferred language'**
  String get languageSubtitle;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @chineseSimplified.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get chineseSimplified;

  /// No description provided for @languageChanged.
  ///
  /// In en, this message translates to:
  /// **'Language changed successfully'**
  String get languageChanged;

  /// No description provided for @errorChangingLanguage.
  ///
  /// In en, this message translates to:
  /// **'Error changing language: {error}'**
  String errorChangingLanguage(Object error);

  /// No description provided for @selected.
  ///
  /// In en, this message translates to:
  /// **'selected'**
  String get selected;

  /// No description provided for @linkSelectedNotes.
  ///
  /// In en, this message translates to:
  /// **'Link Selected Notes'**
  String get linkSelectedNotes;

  /// No description provided for @deleteSelectedNotes.
  ///
  /// In en, this message translates to:
  /// **'Delete Selected Notes'**
  String get deleteSelectedNotes;

  /// No description provided for @openAIAction.
  ///
  /// In en, this message translates to:
  /// **'Open AI Action'**
  String get openAIAction;

  /// No description provided for @exitMultiSelectMode.
  ///
  /// In en, this message translates to:
  /// **'Exit Multi-Select Mode'**
  String get exitMultiSelectMode;

  /// No description provided for @searchNotes.
  ///
  /// In en, this message translates to:
  /// **'Search notes...'**
  String get searchNotes;

  /// No description provided for @allNotes.
  ///
  /// In en, this message translates to:
  /// **'All Notes'**
  String get allNotes;

  /// No description provided for @defaultNotes.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get defaultNotes;

  /// No description provided for @pinnedNotes.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinnedNotes;

  /// No description provided for @archivedNotes.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archivedNotes;

  /// No description provided for @filter.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get filter;

  /// No description provided for @noNotesFound.
  ///
  /// In en, this message translates to:
  /// **'No notes found'**
  String get noNotesFound;

  /// No description provided for @createFirstNote.
  ///
  /// In en, this message translates to:
  /// **'Create your first note'**
  String get createFirstNote;

  /// No description provided for @timeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get timeline;

  /// No description provided for @todo.
  ///
  /// In en, this message translates to:
  /// **'Todo'**
  String get todo;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @noTasksForToday.
  ///
  /// In en, this message translates to:
  /// **'No tasks for today'**
  String get noTasksForToday;

  /// No description provided for @noNotesForToday.
  ///
  /// In en, this message translates to:
  /// **'No notes for today'**
  String get noNotesForToday;

  /// No description provided for @createFirstTask.
  ///
  /// In en, this message translates to:
  /// **'Create your first task'**
  String get createFirstTask;

  /// No description provided for @createFirstTimelineNote.
  ///
  /// In en, this message translates to:
  /// **'Create your first timeline note'**
  String get createFirstTimelineNote;

  /// No description provided for @taskCompletion.
  ///
  /// In en, this message translates to:
  /// **'Task Completion'**
  String get taskCompletion;

  /// No description provided for @completed.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get completed;

  /// No description provided for @pending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get pending;

  /// No description provided for @inProgress.
  ///
  /// In en, this message translates to:
  /// **'In Progress'**
  String get inProgress;

  /// No description provided for @overdue.
  ///
  /// In en, this message translates to:
  /// **'Overdue'**
  String get overdue;

  /// No description provided for @dueToday.
  ///
  /// In en, this message translates to:
  /// **'Due Today'**
  String get dueToday;

  /// No description provided for @dueTomorrow.
  ///
  /// In en, this message translates to:
  /// **'Due Tomorrow'**
  String get dueTomorrow;

  /// No description provided for @dueThisWeek.
  ///
  /// In en, this message translates to:
  /// **'Due This Week'**
  String get dueThisWeek;

  /// No description provided for @dueNextWeek.
  ///
  /// In en, this message translates to:
  /// **'Due Next Week'**
  String get dueNextWeek;

  /// No description provided for @dueThisMonth.
  ///
  /// In en, this message translates to:
  /// **'Due This Month'**
  String get dueThisMonth;

  /// No description provided for @dueNextMonth.
  ///
  /// In en, this message translates to:
  /// **'Due Next Month'**
  String get dueNextMonth;

  /// No description provided for @overdueTasks.
  ///
  /// In en, this message translates to:
  /// **'Overdue Tasks'**
  String get overdueTasks;

  /// No description provided for @dueTodayTasks.
  ///
  /// In en, this message translates to:
  /// **'Due Today'**
  String get dueTodayTasks;

  /// No description provided for @dueTomorrowTasks.
  ///
  /// In en, this message translates to:
  /// **'Due Tomorrow'**
  String get dueTomorrowTasks;

  /// No description provided for @dueThisWeekTasks.
  ///
  /// In en, this message translates to:
  /// **'Due This Week'**
  String get dueThisWeekTasks;

  /// No description provided for @dueNextWeekTasks.
  ///
  /// In en, this message translates to:
  /// **'Due Next Week'**
  String get dueNextWeekTasks;

  /// No description provided for @dueThisMonthTasks.
  ///
  /// In en, this message translates to:
  /// **'Due This Month'**
  String get dueThisMonthTasks;

  /// No description provided for @dueNextMonthTasks.
  ///
  /// In en, this message translates to:
  /// **'Due Next Month'**
  String get dueNextMonthTasks;

  /// No description provided for @noOverdueTasks.
  ///
  /// In en, this message translates to:
  /// **'No overdue tasks'**
  String get noOverdueTasks;

  /// No description provided for @noDueTodayTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks due today'**
  String get noDueTodayTasks;

  /// No description provided for @noDueTomorrowTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks due tomorrow'**
  String get noDueTomorrowTasks;

  /// No description provided for @noDueThisWeekTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks due this week'**
  String get noDueThisWeekTasks;

  /// No description provided for @noDueNextWeekTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks due next week'**
  String get noDueNextWeekTasks;

  /// No description provided for @noDueThisMonthTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks due this month'**
  String get noDueThisMonthTasks;

  /// No description provided for @noDueNextMonthTasks.
  ///
  /// In en, this message translates to:
  /// **'No tasks due next month'**
  String get noDueNextMonthTasks;

  /// No description provided for @aiActions.
  ///
  /// In en, this message translates to:
  /// **'AI Actions'**
  String get aiActions;

  /// No description provided for @selectAIAction.
  ///
  /// In en, this message translates to:
  /// **'Select AI Action'**
  String get selectAIAction;

  /// No description provided for @noteQa.
  ///
  /// In en, this message translates to:
  /// **'Note Q&A'**
  String get noteQa;

  /// No description provided for @noteQaDescription.
  ///
  /// In en, this message translates to:
  /// **'Ask questions about your selected notes'**
  String get noteQaDescription;

  /// No description provided for @transformNote.
  ///
  /// In en, this message translates to:
  /// **'Transform Note'**
  String get transformNote;

  /// No description provided for @transformNoteDescription.
  ///
  /// In en, this message translates to:
  /// **'Rewrite, reorganize, or modify your note'**
  String get transformNoteDescription;

  /// No description provided for @createNewNotes.
  ///
  /// In en, this message translates to:
  /// **'Create New Notes'**
  String get createNewNotes;

  /// No description provided for @createNewNotesDescription.
  ///
  /// In en, this message translates to:
  /// **'Generate new notes based on your prompt and context'**
  String get createNewNotesDescription;

  /// No description provided for @enterYourPrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter your prompt:'**
  String get enterYourPrompt;

  /// No description provided for @attachFiles.
  ///
  /// In en, this message translates to:
  /// **'Attach files'**
  String get attachFiles;

  /// No description provided for @answerOnlyFromNotes.
  ///
  /// In en, this message translates to:
  /// **'Answer only from selected notes'**
  String get answerOnlyFromNotes;

  /// No description provided for @process.
  ///
  /// In en, this message translates to:
  /// **'Process'**
  String get process;

  /// No description provided for @processing.
  ///
  /// In en, this message translates to:
  /// **'Processing...'**
  String get processing;

  /// No description provided for @clearResponse.
  ///
  /// In en, this message translates to:
  /// **'Clear Response'**
  String get clearResponse;

  /// No description provided for @response.
  ///
  /// In en, this message translates to:
  /// **'Response'**
  String get response;

  /// No description provided for @copyResponse.
  ///
  /// In en, this message translates to:
  /// **'Copy Response'**
  String get copyResponse;

  /// No description provided for @createNotesFromResponse.
  ///
  /// In en, this message translates to:
  /// **'Create Notes from Response'**
  String get createNotesFromResponse;

  /// No description provided for @noFilesAttached.
  ///
  /// In en, this message translates to:
  /// **'No files attached'**
  String get noFilesAttached;

  /// No description provided for @filesAttached.
  ///
  /// In en, this message translates to:
  /// **'Files attached'**
  String get filesAttached;

  /// No description provided for @removeFile.
  ///
  /// In en, this message translates to:
  /// **'Remove File'**
  String get removeFile;

  /// No description provided for @addFiles.
  ///
  /// In en, this message translates to:
  /// **'Add Files'**
  String get addFiles;

  /// No description provided for @processingRequest.
  ///
  /// In en, this message translates to:
  /// **'Processing your request...'**
  String get processingRequest;

  /// No description provided for @errorProcessingRequest.
  ///
  /// In en, this message translates to:
  /// **'Error processing request: {error}'**
  String errorProcessingRequest(Object error);

  /// No description provided for @responseCopied.
  ///
  /// In en, this message translates to:
  /// **'Response copied to clipboard'**
  String get responseCopied;

  /// No description provided for @notesCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Notes created successfully!'**
  String get notesCreatedSuccessfully;

  /// No description provided for @errorCreatingNotes.
  ///
  /// In en, this message translates to:
  /// **'Error creating notes: {error}'**
  String errorCreatingNotes(Object error);

  /// No description provided for @sharedContent.
  ///
  /// In en, this message translates to:
  /// **'Shared Content'**
  String get sharedContent;

  /// No description provided for @createNote.
  ///
  /// In en, this message translates to:
  /// **'Create Note'**
  String get createNote;

  /// No description provided for @appendToNote.
  ///
  /// In en, this message translates to:
  /// **'Append to Note'**
  String get appendToNote;

  /// No description provided for @selectNoteToAppend.
  ///
  /// In en, this message translates to:
  /// **'Select Note to Append'**
  String get selectNoteToAppend;

  /// No description provided for @searchNotesToAppend.
  ///
  /// In en, this message translates to:
  /// **'Search notes to append to...'**
  String get searchNotesToAppend;

  /// No description provided for @title.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get title;

  /// No description provided for @tags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get tags;

  /// No description provided for @addNewTag.
  ///
  /// In en, this message translates to:
  /// **'Add New Tag'**
  String get addNewTag;

  /// No description provided for @extractContent.
  ///
  /// In en, this message translates to:
  /// **'Extract Content'**
  String get extractContent;

  /// No description provided for @extractingContent.
  ///
  /// In en, this message translates to:
  /// **'Extracting content...'**
  String get extractingContent;

  /// No description provided for @contentExtracted.
  ///
  /// In en, this message translates to:
  /// **'Content extracted successfully!'**
  String get contentExtracted;

  /// No description provided for @errorExtractingContent.
  ///
  /// In en, this message translates to:
  /// **'Error extracting content: {error}'**
  String errorExtractingContent(Object error);

  /// No description provided for @noApiKeyForExtraction.
  ///
  /// In en, this message translates to:
  /// **'API key required for content extraction'**
  String get noApiKeyForExtraction;

  /// No description provided for @urlDetected.
  ///
  /// In en, this message translates to:
  /// **'URL Detected'**
  String get urlDetected;

  /// No description provided for @extractFromUrl.
  ///
  /// In en, this message translates to:
  /// **'Extract from URL'**
  String get extractFromUrl;

  /// No description provided for @contentType.
  ///
  /// In en, this message translates to:
  /// **'Content Type'**
  String get contentType;

  /// No description provided for @text.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get text;

  /// No description provided for @url.
  ///
  /// In en, this message translates to:
  /// **'URL'**
  String get url;

  /// No description provided for @image.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get image;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @unknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get unknown;

  /// No description provided for @noNotesAvailable.
  ///
  /// In en, this message translates to:
  /// **'No notes available'**
  String get noNotesAvailable;

  /// No description provided for @errorLoadingNotes.
  ///
  /// In en, this message translates to:
  /// **'Error loading notes: {error}'**
  String errorLoadingNotes(Object error);

  /// No description provided for @noteCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Note \"{title}\" created successfully'**
  String noteCreatedSuccessfully(Object title);

  /// No description provided for @errorCreatingNote.
  ///
  /// In en, this message translates to:
  /// **'Error creating note: {error}'**
  String errorCreatingNote(Object error);

  /// No description provided for @noteUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Note updated successfully!'**
  String get noteUpdatedSuccessfully;

  /// No description provided for @errorUpdatingNote.
  ///
  /// In en, this message translates to:
  /// **'Error updating note: {error}'**
  String errorUpdatingNote(Object error);

  /// No description provided for @pinNote.
  ///
  /// In en, this message translates to:
  /// **'Pin note'**
  String get pinNote;

  /// No description provided for @unpinNote.
  ///
  /// In en, this message translates to:
  /// **'Unpin note'**
  String get unpinNote;

  /// No description provided for @archiveNote.
  ///
  /// In en, this message translates to:
  /// **'Archive note'**
  String get archiveNote;

  /// No description provided for @unarchiveNote.
  ///
  /// In en, this message translates to:
  /// **'Unarchive note'**
  String get unarchiveNote;

  /// No description provided for @editNote.
  ///
  /// In en, this message translates to:
  /// **'Edit Note'**
  String get editNote;

  /// No description provided for @saveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save Changes'**
  String get saveChanges;

  /// No description provided for @discardChanges.
  ///
  /// In en, this message translates to:
  /// **'Discard Changes'**
  String get discardChanges;

  /// No description provided for @deleteNote.
  ///
  /// In en, this message translates to:
  /// **'Delete Note'**
  String get deleteNote;

  /// No description provided for @confirmDeleteNote.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this note?'**
  String get confirmDeleteNote;

  /// No description provided for @noteDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Note deleted successfully!'**
  String get noteDeletedSuccessfully;

  /// No description provided for @errorDeletingNote.
  ///
  /// In en, this message translates to:
  /// **'Error deleting note: {error}'**
  String errorDeletingNote(Object error);

  /// No description provided for @addSubNote.
  ///
  /// In en, this message translates to:
  /// **'Add Sub-Note'**
  String get addSubNote;

  /// No description provided for @subNotes.
  ///
  /// In en, this message translates to:
  /// **'Sub-Notes'**
  String get subNotes;

  /// No description provided for @noSubNotes.
  ///
  /// In en, this message translates to:
  /// **'No sub-notes'**
  String get noSubNotes;

  /// No description provided for @addNewSubNote.
  ///
  /// In en, this message translates to:
  /// **'Add New Sub-Note'**
  String get addNewSubNote;

  /// No description provided for @editSubNote.
  ///
  /// In en, this message translates to:
  /// **'Edit Sub-Note'**
  String get editSubNote;

  /// No description provided for @reparentSubNote.
  ///
  /// In en, this message translates to:
  /// **'Reparent'**
  String get reparentSubNote;

  /// No description provided for @deleteSubNote.
  ///
  /// In en, this message translates to:
  /// **'Delete Sub-Note'**
  String get deleteSubNote;

  /// No description provided for @confirmDeleteSubNote.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this sub-note?'**
  String get confirmDeleteSubNote;

  /// No description provided for @subNoteAddedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Sub-note added successfully!'**
  String get subNoteAddedSuccessfully;

  /// No description provided for @subNoteUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Sub-note updated successfully!'**
  String get subNoteUpdatedSuccessfully;

  /// No description provided for @subNoteDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Sub-note deleted successfully!'**
  String get subNoteDeletedSuccessfully;

  /// No description provided for @errorAddingSubNote.
  ///
  /// In en, this message translates to:
  /// **'Error adding sub-note: {error}'**
  String errorAddingSubNote(Object error);

  /// No description provided for @errorUpdatingSubNote.
  ///
  /// In en, this message translates to:
  /// **'Error updating sub-note: {error}'**
  String errorUpdatingSubNote(Object error);

  /// No description provided for @errorDeletingSubNote.
  ///
  /// In en, this message translates to:
  /// **'Error deleting sub-note: {error}'**
  String errorDeletingSubNote(Object error);

  /// No description provided for @scheduledAt.
  ///
  /// In en, this message translates to:
  /// **'Scheduled At'**
  String get scheduledAt;

  /// No description provided for @completeBy.
  ///
  /// In en, this message translates to:
  /// **'Complete By'**
  String get completeBy;

  /// No description provided for @dateValidationError.
  ///
  /// In en, this message translates to:
  /// **'Complete by date must be after scheduled date'**
  String get dateValidationError;

  /// No description provided for @relationships.
  ///
  /// In en, this message translates to:
  /// **'Relationships'**
  String get relationships;

  /// No description provided for @linkedNotes.
  ///
  /// In en, this message translates to:
  /// **'Linked Notes'**
  String get linkedNotes;

  /// No description provided for @noLinkedNotes.
  ///
  /// In en, this message translates to:
  /// **'No linked notes'**
  String get noLinkedNotes;

  /// No description provided for @addRelationship.
  ///
  /// In en, this message translates to:
  /// **'Add Relationship'**
  String get addRelationship;

  /// No description provided for @removeRelationship.
  ///
  /// In en, this message translates to:
  /// **'Remove Relationship'**
  String get removeRelationship;

  /// No description provided for @confirmRemoveRelationship.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to remove this relationship?'**
  String get confirmRemoveRelationship;

  /// No description provided for @relationshipAddedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Relationship added successfully!'**
  String get relationshipAddedSuccessfully;

  /// No description provided for @relationshipRemovedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Relationship removed successfully!'**
  String get relationshipRemovedSuccessfully;

  /// No description provided for @errorAddingRelationship.
  ///
  /// In en, this message translates to:
  /// **'Error adding relationship: {error}'**
  String errorAddingRelationship(Object error);

  /// No description provided for @errorRemovingRelationship.
  ///
  /// In en, this message translates to:
  /// **'Error removing relationship: {error}'**
  String errorRemovingRelationship(Object error);

  /// No description provided for @audioRecording.
  ///
  /// In en, this message translates to:
  /// **'Audio Recording'**
  String get audioRecording;

  /// No description provided for @playAudio.
  ///
  /// In en, this message translates to:
  /// **'Play Audio'**
  String get playAudio;

  /// No description provided for @pauseAudio.
  ///
  /// In en, this message translates to:
  /// **'Pause Audio'**
  String get pauseAudio;

  /// No description provided for @recordingInProgress.
  ///
  /// In en, this message translates to:
  /// **'Recording in progress...'**
  String get recordingInProgress;

  /// No description provided for @audioRecordedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Audio recorded successfully!'**
  String get audioRecordedSuccessfully;

  /// No description provided for @errorRecordingAudio.
  ///
  /// In en, this message translates to:
  /// **'Error recording audio: {error}'**
  String errorRecordingAudio(Object error);

  /// No description provided for @errorPlayingAudio.
  ///
  /// In en, this message translates to:
  /// **'Error playing audio: {error}'**
  String errorPlayingAudio(Object error);

  /// No description provided for @noAudioAttachments.
  ///
  /// In en, this message translates to:
  /// **'No audio attachments'**
  String get noAudioAttachments;

  /// No description provided for @audioAttachment.
  ///
  /// In en, this message translates to:
  /// **'Audio Attachment'**
  String get audioAttachment;

  /// No description provided for @duration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get duration;

  /// No description provided for @position.
  ///
  /// In en, this message translates to:
  /// **'Position'**
  String get position;

  /// No description provided for @autoSave.
  ///
  /// In en, this message translates to:
  /// **'Auto-save'**
  String get autoSave;

  /// No description provided for @saved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get saved;

  /// No description provided for @unsaved.
  ///
  /// In en, this message translates to:
  /// **'Unsaved'**
  String get unsaved;

  /// No description provided for @saving.
  ///
  /// In en, this message translates to:
  /// **'Saving...'**
  String get saving;

  /// No description provided for @unsavedChanges.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes'**
  String get unsavedChanges;

  /// No description provided for @confirmDiscardChanges.
  ///
  /// In en, this message translates to:
  /// **'You have unsaved changes. Are you sure you want to discard them?'**
  String get confirmDiscardChanges;

  /// No description provided for @yes.
  ///
  /// In en, this message translates to:
  /// **'Yes'**
  String get yes;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @start.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get start;

  /// No description provided for @due.
  ///
  /// In en, this message translates to:
  /// **'Due'**
  String get due;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} days ago'**
  String daysAgo(Object count);

  /// No description provided for @subNote.
  ///
  /// In en, this message translates to:
  /// **'Sub-note'**
  String get subNote;

  /// No description provided for @addTag.
  ///
  /// In en, this message translates to:
  /// **'Add tag'**
  String get addTag;

  /// No description provided for @noTagsYet.
  ///
  /// In en, this message translates to:
  /// **'No tags yet. Tap \"Add tag\" to add some.'**
  String get noTagsYet;

  /// No description provided for @addLink.
  ///
  /// In en, this message translates to:
  /// **'Add Link'**
  String get addLink;

  /// No description provided for @attach.
  ///
  /// In en, this message translates to:
  /// **'Attach'**
  String get attach;

  /// No description provided for @recordAudio.
  ///
  /// In en, this message translates to:
  /// **'Record Audio'**
  String get recordAudio;

  /// No description provided for @status.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get status;

  /// No description provided for @toDo.
  ///
  /// In en, this message translates to:
  /// **'To Do'**
  String get toDo;

  /// No description provided for @cancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get cancelled;

  /// No description provided for @scheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get scheduled;

  /// No description provided for @content.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get content;

  /// No description provided for @checkbox.
  ///
  /// In en, this message translates to:
  /// **'Checkbox'**
  String get checkbox;

  /// No description provided for @bold.
  ///
  /// In en, this message translates to:
  /// **'Bold'**
  String get bold;

  /// No description provided for @created.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get created;

  /// No description provided for @updated.
  ///
  /// In en, this message translates to:
  /// **'Updated'**
  String get updated;

  /// No description provided for @markComplete.
  ///
  /// In en, this message translates to:
  /// **'Mark Complete'**
  String get markComplete;

  /// No description provided for @markIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Mark Incomplete'**
  String get markIncomplete;

  /// No description provided for @noLinkedNotesYet.
  ///
  /// In en, this message translates to:
  /// **'No linked notes yet'**
  String get noLinkedNotesYet;

  /// No description provided for @tasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get tasks;

  /// No description provided for @month.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get month;

  /// No description provided for @week.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get week;

  /// No description provided for @twoWeeks.
  ///
  /// In en, this message translates to:
  /// **'2 Weeks'**
  String get twoWeeks;

  /// No description provided for @january.
  ///
  /// In en, this message translates to:
  /// **'Jan'**
  String get january;

  /// No description provided for @february.
  ///
  /// In en, this message translates to:
  /// **'Feb'**
  String get february;

  /// No description provided for @march.
  ///
  /// In en, this message translates to:
  /// **'Mar'**
  String get march;

  /// No description provided for @april.
  ///
  /// In en, this message translates to:
  /// **'Apr'**
  String get april;

  /// No description provided for @may.
  ///
  /// In en, this message translates to:
  /// **'May'**
  String get may;

  /// No description provided for @june.
  ///
  /// In en, this message translates to:
  /// **'Jun'**
  String get june;

  /// No description provided for @july.
  ///
  /// In en, this message translates to:
  /// **'Jul'**
  String get july;

  /// No description provided for @august.
  ///
  /// In en, this message translates to:
  /// **'Aug'**
  String get august;

  /// No description provided for @september.
  ///
  /// In en, this message translates to:
  /// **'Sep'**
  String get september;

  /// No description provided for @october.
  ///
  /// In en, this message translates to:
  /// **'Oct'**
  String get october;

  /// No description provided for @november.
  ///
  /// In en, this message translates to:
  /// **'Nov'**
  String get november;

  /// No description provided for @december.
  ///
  /// In en, this message translates to:
  /// **'Dec'**
  String get december;

  /// No description provided for @noTasksWithSelectedTags.
  ///
  /// In en, this message translates to:
  /// **'No tasks with selected tags'**
  String get noTasksWithSelectedTags;

  /// No description provided for @noNotesWithSelectedTags.
  ///
  /// In en, this message translates to:
  /// **'No notes with selected tags'**
  String get noNotesWithSelectedTags;

  /// No description provided for @noTasksWithSelectedTagsForThisDay.
  ///
  /// In en, this message translates to:
  /// **'No tasks with selected tags for this day'**
  String get noTasksWithSelectedTagsForThisDay;

  /// No description provided for @noNotesWithSelectedTagsForThisDay.
  ///
  /// In en, this message translates to:
  /// **'No notes with selected tags for this day'**
  String get noNotesWithSelectedTagsForThisDay;

  /// No description provided for @trySelectingDifferentTags.
  ///
  /// In en, this message translates to:
  /// **'Try selecting different tags'**
  String get trySelectingDifferentTags;

  /// No description provided for @cannotOpenLink.
  ///
  /// In en, this message translates to:
  /// **'Cannot open link'**
  String get cannotOpenLink;

  /// No description provided for @errorOpeningLink.
  ///
  /// In en, this message translates to:
  /// **'Error opening link'**
  String get errorOpeningLink;

  /// No description provided for @subtasksCompleted.
  ///
  /// In en, this message translates to:
  /// **'{completed}/{total} subtasks completed'**
  String subtasksCompleted(Object completed, Object total);

  /// No description provided for @audioNote.
  ///
  /// In en, this message translates to:
  /// **'Audio Note'**
  String get audioNote;

  /// No description provided for @audioRecordingFrom.
  ///
  /// In en, this message translates to:
  /// **'Audio recording from'**
  String get audioRecordingFrom;

  /// No description provided for @attachments.
  ///
  /// In en, this message translates to:
  /// **'Attachments'**
  String get attachments;

  /// No description provided for @removeAttachment.
  ///
  /// In en, this message translates to:
  /// **'Remove Attachment'**
  String get removeAttachment;

  /// No description provided for @removeAttachmentConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to remove \"{fileName}\" from this note?'**
  String removeAttachmentConfirm(Object fileName);

  /// No description provided for @attachmentRemoved.
  ///
  /// In en, this message translates to:
  /// **'Attachment removed'**
  String get attachmentRemoved;

  /// No description provided for @errorRemovingAttachment.
  ///
  /// In en, this message translates to:
  /// **'Error removing attachment'**
  String get errorRemovingAttachment;

  /// No description provided for @addedAttachments.
  ///
  /// In en, this message translates to:
  /// **'Added {count} attachment(s)'**
  String addedAttachments(Object count);

  /// No description provided for @errorAddingAttachment.
  ///
  /// In en, this message translates to:
  /// **'Error adding attachment'**
  String get errorAddingAttachment;

  /// No description provided for @recordingSavedAsAttachment.
  ///
  /// In en, this message translates to:
  /// **'Recording saved as attachment'**
  String get recordingSavedAsAttachment;

  /// No description provided for @photoAddedToNote.
  ///
  /// In en, this message translates to:
  /// **'Photo added to note'**
  String get photoAddedToNote;

  /// No description provided for @errorTakingPhoto.
  ///
  /// In en, this message translates to:
  /// **'Error taking photo: {error}'**
  String errorTakingPhoto(Object error);

  /// No description provided for @removeAttachmentTooltip.
  ///
  /// In en, this message translates to:
  /// **'Remove attachment'**
  String get removeAttachmentTooltip;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @shareNote.
  ///
  /// In en, this message translates to:
  /// **'Share Note'**
  String get shareNote;

  /// No description provided for @shareNotes.
  ///
  /// In en, this message translates to:
  /// **'Share Notes'**
  String get shareNotes;

  /// No description provided for @shareAsText.
  ///
  /// In en, this message translates to:
  /// **'Share as Text'**
  String get shareAsText;

  /// No description provided for @copyToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy to clipboard'**
  String get copyToClipboard;

  /// No description provided for @shareSubNotesAndLinkedNotes.
  ///
  /// In en, this message translates to:
  /// **'Share sub-notes and linked notes'**
  String get shareSubNotesAndLinkedNotes;

  /// No description provided for @shareDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Share Notes'**
  String get shareDialogTitle;

  /// No description provided for @shareDialogDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose how you want to share the selected notes'**
  String get shareDialogDescription;

  /// No description provided for @textCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Text copied to clipboard'**
  String get textCopiedToClipboard;

  /// No description provided for @errorCopyingToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Error copying to clipboard: {error}'**
  String errorCopyingToClipboard(Object error);

  /// No description provided for @errorSharingText.
  ///
  /// In en, this message translates to:
  /// **'Error sharing text: {error}'**
  String errorSharingText(Object error);

  /// No description provided for @selectFileLocation.
  ///
  /// In en, this message translates to:
  /// **'Select file location'**
  String get selectFileLocation;

  /// No description provided for @saveAsMarkdown.
  ///
  /// In en, this message translates to:
  /// **'Save as Markdown'**
  String get saveAsMarkdown;

  /// No description provided for @fileSavedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'File saved successfully'**
  String get fileSavedSuccessfully;

  /// No description provided for @errorSavingFile.
  ///
  /// In en, this message translates to:
  /// **'Error saving file: {error}'**
  String errorSavingFile(Object error);

  /// No description provided for @shareSelectedNotes.
  ///
  /// In en, this message translates to:
  /// **'Share Selected Notes'**
  String get shareSelectedNotes;

  /// No description provided for @type.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get type;

  /// No description provided for @note.
  ///
  /// In en, this message translates to:
  /// **'Note'**
  String get note;

  /// No description provided for @task.
  ///
  /// In en, this message translates to:
  /// **'Task'**
  String get task;

  /// No description provided for @createFilter.
  ///
  /// In en, this message translates to:
  /// **'Create Filter'**
  String get createFilter;

  /// No description provided for @editFilter.
  ///
  /// In en, this message translates to:
  /// **'Edit Filter'**
  String get editFilter;

  /// No description provided for @filterName.
  ///
  /// In en, this message translates to:
  /// **'Filter Name'**
  String get filterName;

  /// No description provided for @filterNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a name for this filter'**
  String get filterNameHint;

  /// No description provided for @includeText.
  ///
  /// In en, this message translates to:
  /// **'Include Text'**
  String get includeText;

  /// No description provided for @includeTextHint.
  ///
  /// In en, this message translates to:
  /// **'Text to search for in notes'**
  String get includeTextHint;

  /// No description provided for @includeTags.
  ///
  /// In en, this message translates to:
  /// **'Include Tags'**
  String get includeTags;

  /// No description provided for @includeTagsHint.
  ///
  /// In en, this message translates to:
  /// **'Select tags to filter by'**
  String get includeTagsHint;

  /// No description provided for @includeArchivedNotes.
  ///
  /// In en, this message translates to:
  /// **'Include archived notes'**
  String get includeArchivedNotes;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @selectTags.
  ///
  /// In en, this message translates to:
  /// **'Select Tags'**
  String get selectTags;

  /// No description provided for @apply.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get apply;

  /// No description provided for @deleteFilter.
  ///
  /// In en, this message translates to:
  /// **'Delete Filter'**
  String get deleteFilter;

  /// No description provided for @deleteFilterConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{filterName}\"?'**
  String deleteFilterConfirm(Object filterName);

  /// No description provided for @addFilter.
  ///
  /// In en, this message translates to:
  /// **'Add Filter'**
  String get addFilter;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @manageTags.
  ///
  /// In en, this message translates to:
  /// **'Manage Tags'**
  String get manageTags;

  /// No description provided for @tagManagement.
  ///
  /// In en, this message translates to:
  /// **'Tag Management'**
  String get tagManagement;

  /// No description provided for @tagUsageCount.
  ///
  /// In en, this message translates to:
  /// **'{count} notes'**
  String tagUsageCount(Object count);

  /// No description provided for @deleteTag.
  ///
  /// In en, this message translates to:
  /// **'Delete Tag'**
  String get deleteTag;

  /// No description provided for @confirmDeleteTag.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete the tag \"{tagName}\"?'**
  String confirmDeleteTag(Object tagName);

  /// No description provided for @confirmDeleteTagWarning.
  ///
  /// In en, this message translates to:
  /// **'This will remove the tag from all {count} associated notes. This action cannot be undone.'**
  String confirmDeleteTagWarning(Object count);

  /// No description provided for @tagDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Tag deleted successfully!'**
  String get tagDeletedSuccessfully;

  /// No description provided for @errorDeletingTag.
  ///
  /// In en, this message translates to:
  /// **'Error deleting tag: {error}'**
  String errorDeletingTag(Object error);

  /// No description provided for @noTagsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No tags available'**
  String get noTagsAvailable;

  /// No description provided for @tagUsage.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get tagUsage;

  /// No description provided for @deleteTags.
  ///
  /// In en, this message translates to:
  /// **'Delete Tags'**
  String get deleteTags;

  /// No description provided for @dedupTags.
  ///
  /// In en, this message translates to:
  /// **'Dedup Tags'**
  String get dedupTags;

  /// No description provided for @dedupRules.
  ///
  /// In en, this message translates to:
  /// **'Dedup Rules'**
  String get dedupRules;

  /// No description provided for @addDedupRule.
  ///
  /// In en, this message translates to:
  /// **'Add Dedup Rule'**
  String get addDedupRule;

  /// No description provided for @leftTag.
  ///
  /// In en, this message translates to:
  /// **'Left Tag'**
  String get leftTag;

  /// No description provided for @rightTag.
  ///
  /// In en, this message translates to:
  /// **'Right Tag'**
  String get rightTag;

  /// No description provided for @selectLeftTag.
  ///
  /// In en, this message translates to:
  /// **'Select Left Tag'**
  String get selectLeftTag;

  /// No description provided for @selectRightTag.
  ///
  /// In en, this message translates to:
  /// **'Select Right Tag'**
  String get selectRightTag;

  /// No description provided for @swapTags.
  ///
  /// In en, this message translates to:
  /// **'Swap Tags'**
  String get swapTags;

  /// No description provided for @executeDedup.
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get executeDedup;

  /// No description provided for @aiSuggestDedup.
  ///
  /// In en, this message translates to:
  /// **'AI Suggest'**
  String get aiSuggestDedup;

  /// No description provided for @noDedupRules.
  ///
  /// In en, this message translates to:
  /// **'No dedup rules yet'**
  String get noDedupRules;

  /// No description provided for @addFirstDedupRule.
  ///
  /// In en, this message translates to:
  /// **'Add your first dedup rule'**
  String get addFirstDedupRule;

  /// No description provided for @dedupRuleValidationError.
  ///
  /// In en, this message translates to:
  /// **'Invalid dedup rule: {error}'**
  String dedupRuleValidationError(Object error);

  /// No description provided for @dedupRulesExecutedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Dedup rules executed successfully!'**
  String get dedupRulesExecutedSuccessfully;

  /// No description provided for @errorExecutingDedupRules.
  ///
  /// In en, this message translates to:
  /// **'Error executing dedup rules: {error}'**
  String errorExecutingDedupRules(Object error);

  /// No description provided for @aiSuggestingDedupRules.
  ///
  /// In en, this message translates to:
  /// **'AI is suggesting dedup rules...'**
  String get aiSuggestingDedupRules;

  /// No description provided for @errorGettingAiSuggestions.
  ///
  /// In en, this message translates to:
  /// **'Error getting AI suggestions: {error}'**
  String errorGettingAiSuggestions(Object error);

  /// No description provided for @confirmExecuteDedupRules.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to execute these dedup rules? This will replace all left tags with right tags and cannot be undone.'**
  String get confirmExecuteDedupRules;

  /// No description provided for @dedupRuleLeftTagDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Left tag appears in multiple rules'**
  String get dedupRuleLeftTagDuplicate;

  /// No description provided for @dedupRuleRightTagDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Right tag appears in multiple rules'**
  String get dedupRuleRightTagDuplicate;

  /// No description provided for @dedupRuleCircularReference.
  ///
  /// In en, this message translates to:
  /// **'Circular reference detected'**
  String get dedupRuleCircularReference;

  /// No description provided for @dedupRuleSelfReference.
  ///
  /// In en, this message translates to:
  /// **'Cannot replace tag with itself'**
  String get dedupRuleSelfReference;

  /// No description provided for @myApps.
  ///
  /// In en, this message translates to:
  /// **'My Apps'**
  String get myApps;

  /// No description provided for @myAppsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Create and manage custom applications'**
  String get myAppsSubtitle;

  /// No description provided for @noUserApps.
  ///
  /// In en, this message translates to:
  /// **'No custom apps yet'**
  String get noUserApps;

  /// No description provided for @createFirstApp.
  ///
  /// In en, this message translates to:
  /// **'Create your first custom app'**
  String get createFirstApp;

  /// No description provided for @createNewApp.
  ///
  /// In en, this message translates to:
  /// **'Create New App'**
  String get createNewApp;

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'App Name'**
  String get appName;

  /// No description provided for @appNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a name for your app'**
  String get appNameHint;

  /// No description provided for @appDescription.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get appDescription;

  /// No description provided for @appDescriptionHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what your app does'**
  String get appDescriptionHint;

  /// No description provided for @appSteps.
  ///
  /// In en, this message translates to:
  /// **'Steps'**
  String get appSteps;

  /// No description provided for @appStepsHint.
  ///
  /// In en, this message translates to:
  /// **'Describe the steps your app should follow'**
  String get appStepsHint;

  /// No description provided for @addStep.
  ///
  /// In en, this message translates to:
  /// **'Add Step'**
  String get addStep;

  /// No description provided for @removeStep.
  ///
  /// In en, this message translates to:
  /// **'Remove Step'**
  String get removeStep;

  /// No description provided for @stepHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a step description'**
  String get stepHint;

  /// No description provided for @createApp.
  ///
  /// In en, this message translates to:
  /// **'Create App'**
  String get createApp;

  /// No description provided for @creatingApp.
  ///
  /// In en, this message translates to:
  /// **'Creating app...'**
  String get creatingApp;

  /// No description provided for @appCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'App created successfully'**
  String get appCreatedSuccessfully;

  /// No description provided for @appCreationFailed.
  ///
  /// In en, this message translates to:
  /// **'App creation failed'**
  String get appCreationFailed;

  /// No description provided for @appCreated.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get appCreated;

  /// No description provided for @appCantCreate.
  ///
  /// In en, this message translates to:
  /// **'Can\'t Create'**
  String get appCantCreate;

  /// No description provided for @reason.
  ///
  /// In en, this message translates to:
  /// **'Reason'**
  String get reason;

  /// No description provided for @toApp.
  ///
  /// In en, this message translates to:
  /// **'To App'**
  String get toApp;

  /// No description provided for @console.
  ///
  /// In en, this message translates to:
  /// **'Console'**
  String get console;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @confirmDeleteApp.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this app?'**
  String get confirmDeleteApp;

  /// No description provided for @appDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'App deleted successfully!'**
  String get appDeletedSuccessfully;

  /// No description provided for @errorDeletingApp.
  ///
  /// In en, this message translates to:
  /// **'Error deleting app: {error}'**
  String errorDeletingApp(Object error);

  /// No description provided for @webViewNotSupported.
  ///
  /// In en, this message translates to:
  /// **'WebView is not supported on Linux'**
  String get webViewNotSupported;

  /// No description provided for @webViewNotSupportedDescription.
  ///
  /// In en, this message translates to:
  /// **'User-defined apps require WebView which is not available on Linux platform'**
  String get webViewNotSupportedDescription;

  /// No description provided for @editApp.
  ///
  /// In en, this message translates to:
  /// **'Edit App'**
  String get editApp;

  /// No description provided for @appCode.
  ///
  /// In en, this message translates to:
  /// **'App Code'**
  String get appCode;

  /// No description provided for @editSuggestion.
  ///
  /// In en, this message translates to:
  /// **'Edit Suggestion'**
  String get editSuggestion;

  /// No description provided for @editSuggestionHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what changes you want to make'**
  String get editSuggestionHint;

  /// No description provided for @submitEdit.
  ///
  /// In en, this message translates to:
  /// **'Submit Edit'**
  String get submitEdit;

  /// No description provided for @editingApp.
  ///
  /// In en, this message translates to:
  /// **'Editing app...'**
  String get editingApp;

  /// No description provided for @appEditSubmitted.
  ///
  /// In en, this message translates to:
  /// **'Edit submitted successfully!'**
  String get appEditSubmitted;

  /// No description provided for @appEditFailed.
  ///
  /// In en, this message translates to:
  /// **'App edit failed'**
  String get appEditFailed;

  /// No description provided for @newAppCreatedFromEdit.
  ///
  /// In en, this message translates to:
  /// **'New app created from edit'**
  String get newAppCreatedFromEdit;

  /// No description provided for @errorCreatingAppFromEdit.
  ///
  /// In en, this message translates to:
  /// **'Error creating app from edit: {error}'**
  String errorCreatingAppFromEdit(Object error);

  /// No description provided for @saveCode.
  ///
  /// In en, this message translates to:
  /// **'Save Code'**
  String get saveCode;

  /// No description provided for @saveCodeDirectly.
  ///
  /// In en, this message translates to:
  /// **'Save Code Directly'**
  String get saveCodeDirectly;

  /// No description provided for @codeSavedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Code saved successfully!'**
  String get codeSavedSuccessfully;

  /// No description provided for @errorSavingCode.
  ///
  /// In en, this message translates to:
  /// **'Error saving code: {error}'**
  String errorSavingCode(Object error);

  /// No description provided for @editCodeDirectly.
  ///
  /// In en, this message translates to:
  /// **'Edit Code Directly'**
  String get editCodeDirectly;

  /// No description provided for @editAppName.
  ///
  /// In en, this message translates to:
  /// **'Edit App Name'**
  String get editAppName;

  /// No description provided for @appNameUpdated.
  ///
  /// In en, this message translates to:
  /// **'App name updated successfully!'**
  String get appNameUpdated;

  /// No description provided for @errorUpdatingAppName.
  ///
  /// In en, this message translates to:
  /// **'Error updating app name: {error}'**
  String errorUpdatingAppName(Object error);

  /// No description provided for @consoleOutput.
  ///
  /// In en, this message translates to:
  /// **'Console Output'**
  String get consoleOutput;

  /// No description provided for @noConsoleOutput.
  ///
  /// In en, this message translates to:
  /// **'No console output yet'**
  String get noConsoleOutput;

  /// No description provided for @clearConsole.
  ///
  /// In en, this message translates to:
  /// **'Clear Console'**
  String get clearConsole;

  /// No description provided for @consoleOutputCopied.
  ///
  /// In en, this message translates to:
  /// **'Console output copied to clipboard'**
  String get consoleOutputCopied;

  /// No description provided for @appState.
  ///
  /// In en, this message translates to:
  /// **'App State'**
  String get appState;

  /// No description provided for @saveState.
  ///
  /// In en, this message translates to:
  /// **'Save State'**
  String get saveState;

  /// No description provided for @loadState.
  ///
  /// In en, this message translates to:
  /// **'Load State'**
  String get loadState;

  /// No description provided for @stateSaved.
  ///
  /// In en, this message translates to:
  /// **'State saved successfully!'**
  String get stateSaved;

  /// No description provided for @stateLoaded.
  ///
  /// In en, this message translates to:
  /// **'State loaded successfully!'**
  String get stateLoaded;

  /// No description provided for @errorSavingState.
  ///
  /// In en, this message translates to:
  /// **'Error saving state: {error}'**
  String errorSavingState(Object error);

  /// No description provided for @errorLoadingState.
  ///
  /// In en, this message translates to:
  /// **'Error loading state: {error}'**
  String errorLoadingState(Object error);

  /// No description provided for @appGenerationPrompt.
  ///
  /// In en, this message translates to:
  /// **'Create a single-page self-contained HTML application based on the following requirements:\n\nApp Name: {name}\nDescription: {description}\nSteps: {steps}\n\nRequirements:\n1. The HTML must be completely self-contained with embedded CSS and JavaScript\n2. Do not reference any external resources\n3. Document the purpose, requirements, and approach in comments\n4. Use the following APIs to interact with the Flutter app:\n   - Synapse.runQuery(sql: string) - Query the app\'s database\n   - Synapse.storeAppState(state) - Store JSON serialized state\n   - Synapse.loadAppState() - Load saved state\n   - Synapse.chatAI(prompt) - Send prompt to AI and get response\n\nGenerate the complete HTML application now.'**
  String appGenerationPrompt(Object description, Object name, Object steps);

  /// No description provided for @deleteApp.
  ///
  /// In en, this message translates to:
  /// **'Delete App'**
  String get deleteApp;

  /// No description provided for @aiDebugOverlay.
  ///
  /// In en, this message translates to:
  /// **'AI Debug Overlay'**
  String get aiDebugOverlay;

  /// No description provided for @aiDebugOverlaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'View AI request/response logs'**
  String get aiDebugOverlaySubtitle;

  /// No description provided for @aiDebugOverlayTitle.
  ///
  /// In en, this message translates to:
  /// **'AI Debug Overlay'**
  String get aiDebugOverlayTitle;

  /// No description provided for @refreshLogs.
  ///
  /// In en, this message translates to:
  /// **'Refresh logs'**
  String get refreshLogs;

  /// No description provided for @clearLogs.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get clearLogs;

  /// No description provided for @basic.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get basic;

  /// No description provided for @advanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get advanced;

  /// No description provided for @addLibrary.
  ///
  /// In en, this message translates to:
  /// **'Add Library'**
  String get addLibrary;

  /// No description provided for @libraryName.
  ///
  /// In en, this message translates to:
  /// **'Library Name'**
  String get libraryName;

  /// No description provided for @libraryNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter library name'**
  String get libraryNameHint;

  /// No description provided for @libraryUsage.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get libraryUsage;

  /// No description provided for @libraryUsageHint.
  ///
  /// In en, this message translates to:
  /// **'Describe how to use this library'**
  String get libraryUsageHint;

  /// No description provided for @libraryLink.
  ///
  /// In en, this message translates to:
  /// **'Library Link'**
  String get libraryLink;

  /// No description provided for @libraryLinkHint.
  ///
  /// In en, this message translates to:
  /// **'Enter JavaScript library URL'**
  String get libraryLinkHint;

  /// No description provided for @removeLibrary.
  ///
  /// In en, this message translates to:
  /// **'Remove Library'**
  String get removeLibrary;

  /// No description provided for @removeLink.
  ///
  /// In en, this message translates to:
  /// **'Remove Link'**
  String get removeLink;

  /// No description provided for @noAiLogsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No AI logs available'**
  String get noAiLogsAvailable;

  /// No description provided for @aiLogsDescription.
  ///
  /// In en, this message translates to:
  /// **'AI requests and responses will appear here'**
  String get aiLogsDescription;

  /// No description provided for @headers.
  ///
  /// In en, this message translates to:
  /// **'Headers'**
  String get headers;

  /// No description provided for @body.
  ///
  /// In en, this message translates to:
  /// **'Body'**
  String get body;

  /// No description provided for @statusCode.
  ///
  /// In en, this message translates to:
  /// **'Status Code'**
  String get statusCode;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @importApp.
  ///
  /// In en, this message translates to:
  /// **'Import App'**
  String get importApp;

  /// No description provided for @viewApp.
  ///
  /// In en, this message translates to:
  /// **'View App'**
  String get viewApp;

  /// No description provided for @exportApp.
  ///
  /// In en, this message translates to:
  /// **'Export App'**
  String get exportApp;

  /// No description provided for @exportAppDescription.
  ///
  /// In en, this message translates to:
  /// **'Review and update the app information before exporting. The app will be saved as a YAML file that can be shared or imported by others.'**
  String get exportAppDescription;

  /// No description provided for @nameRequired.
  ///
  /// In en, this message translates to:
  /// **'Name is required'**
  String get nameRequired;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @description.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get description;

  /// No description provided for @author.
  ///
  /// In en, this message translates to:
  /// **'Author'**
  String get author;

  /// No description provided for @license.
  ///
  /// In en, this message translates to:
  /// **'License'**
  String get license;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @private.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get private;

  /// No description provided for @appExportedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'App exported successfully'**
  String get appExportedSuccessfully;

  /// No description provided for @errorExportingApp.
  ///
  /// In en, this message translates to:
  /// **'Error exporting app: {error}'**
  String errorExportingApp(Object error);

  /// No description provided for @importProgress.
  ///
  /// In en, this message translates to:
  /// **'Import Progress'**
  String get importProgress;

  /// No description provided for @importLog.
  ///
  /// In en, this message translates to:
  /// **'Import Log'**
  String get importLog;

  /// No description provided for @copyLog.
  ///
  /// In en, this message translates to:
  /// **'Copy log'**
  String get copyLog;

  /// No description provided for @logCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Log copied to clipboard'**
  String get logCopiedToClipboard;

  /// No description provided for @importingFromFile.
  ///
  /// In en, this message translates to:
  /// **'Importing from File: {filePath}'**
  String importingFromFile(Object filePath);

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading: {item}'**
  String downloading(Object item);

  /// No description provided for @downloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded: {item}'**
  String downloaded(Object item);

  /// No description provided for @failedToDownload.
  ///
  /// In en, this message translates to:
  /// **'Failed to download: {item} (Status: {status})'**
  String failedToDownload(Object item, Object status);

  /// No description provided for @errorDownloading.
  ///
  /// In en, this message translates to:
  /// **'Error downloading {item}: {error}'**
  String errorDownloading(Object error, Object item);

  /// No description provided for @importComplete.
  ///
  /// In en, this message translates to:
  /// **'Import complete!'**
  String get importComplete;

  /// No description provided for @importCompletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Import completed successfully!'**
  String get importCompletedSuccessfully;

  /// No description provided for @readingYamlFile.
  ///
  /// In en, this message translates to:
  /// **'Reading YAML file...'**
  String get readingYamlFile;

  /// No description provided for @validatingYamlStructure.
  ///
  /// In en, this message translates to:
  /// **'Validating YAML structure...'**
  String get validatingYamlStructure;

  /// No description provided for @processingAppData.
  ///
  /// In en, this message translates to:
  /// **'Processing app data...'**
  String get processingAppData;

  /// No description provided for @checkingForExistingApp.
  ///
  /// In en, this message translates to:
  /// **'Checking for existing app...'**
  String get checkingForExistingApp;

  /// No description provided for @creatingNewApp.
  ///
  /// In en, this message translates to:
  /// **'Creating new app...'**
  String get creatingNewApp;

  /// No description provided for @downloadingLibraries.
  ///
  /// In en, this message translates to:
  /// **'Downloading libraries...'**
  String get downloadingLibraries;

  /// No description provided for @yamlFileReadSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'YAML file read successfully'**
  String get yamlFileReadSuccessfully;

  /// No description provided for @yamlStructureValidated.
  ///
  /// In en, this message translates to:
  /// **'YAML structure validated'**
  String get yamlStructureValidated;

  /// No description provided for @appDataExtracted.
  ///
  /// In en, this message translates to:
  /// **'App data extracted'**
  String get appDataExtracted;

  /// No description provided for @processingLibrary.
  ///
  /// In en, this message translates to:
  /// **'Processing library: {libraryName}'**
  String processingLibrary(Object libraryName);

  /// No description provided for @downloadingLibrary.
  ///
  /// In en, this message translates to:
  /// **'Downloading library: {libraryName}...'**
  String downloadingLibrary(Object libraryName);

  /// No description provided for @downloadingDependency.
  ///
  /// In en, this message translates to:
  /// **'Downloading: {fileName}...'**
  String downloadingDependency(Object fileName);

  /// No description provided for @errorYamlFilePathEmpty.
  ///
  /// In en, this message translates to:
  /// **'Error: YAML file path is empty'**
  String get errorYamlFilePathEmpty;

  /// No description provided for @errorInvalidYamlFormat.
  ///
  /// In en, this message translates to:
  /// **'Error: Invalid YAML format - expected a map'**
  String get errorInvalidYamlFormat;

  /// No description provided for @errorMissingRequiredFields.
  ///
  /// In en, this message translates to:
  /// **'Error: Missing required fields in YAML'**
  String get errorMissingRequiredFields;

  /// No description provided for @errorAppAlreadyExists.
  ///
  /// In en, this message translates to:
  /// **'Error: App with this UUID already exists'**
  String get errorAppAlreadyExists;

  /// No description provided for @errorCreatingApp.
  ///
  /// In en, this message translates to:
  /// **'Error creating app: {error}'**
  String errorCreatingApp(Object error);

  /// No description provided for @errorImportingApp.
  ///
  /// In en, this message translates to:
  /// **'Error importing app: {error}'**
  String errorImportingApp(Object error);

  /// No description provided for @aiModelSettings.
  ///
  /// In en, this message translates to:
  /// **'AI Model Settings'**
  String get aiModelSettings;

  /// No description provided for @currentModel.
  ///
  /// In en, this message translates to:
  /// **'Current Model'**
  String get currentModel;

  /// No description provided for @noModelSelected.
  ///
  /// In en, this message translates to:
  /// **'No model selected'**
  String get noModelSelected;

  /// No description provided for @availableModels.
  ///
  /// In en, this message translates to:
  /// **'Available Models'**
  String get availableModels;

  /// No description provided for @configured.
  ///
  /// In en, this message translates to:
  /// **'Configured'**
  String get configured;

  /// No description provided for @notConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not Configured'**
  String get notConfigured;

  /// No description provided for @current.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get current;

  /// No description provided for @useModel.
  ///
  /// In en, this message translates to:
  /// **'Use model'**
  String get useModel;

  /// No description provided for @configureModel.
  ///
  /// In en, this message translates to:
  /// **'Configure model'**
  String get configureModel;

  /// No description provided for @resetModel.
  ///
  /// In en, this message translates to:
  /// **'Reset model'**
  String get resetModel;

  /// No description provided for @switchedToModel.
  ///
  /// In en, this message translates to:
  /// **'Switched to {modelName}'**
  String switchedToModel(Object modelName);

  /// No description provided for @errorSwitchingModel.
  ///
  /// In en, this message translates to:
  /// **'Error switching model: {error}'**
  String errorSwitchingModel(Object error);

  /// No description provided for @modelConfigurationUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'{modelName} configuration updated successfully'**
  String modelConfigurationUpdatedSuccessfully(Object modelName);

  /// No description provided for @resetModelConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Reset {modelName} Configuration'**
  String resetModelConfiguration(Object modelName);

  /// No description provided for @resetModelConfigurationConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to reset the configuration for {modelName}? This will clear all settings and allow you to reconfigure the model.'**
  String resetModelConfigurationConfirmation(Object modelName);

  /// No description provided for @modelConfigurationResetSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'{modelName} configuration reset successfully'**
  String modelConfigurationResetSuccessfully(Object modelName);

  /// No description provided for @errorResettingConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Error resetting configuration: {error}'**
  String errorResettingConfiguration(Object error);

  /// No description provided for @configureModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Configure {modelName}'**
  String configureModelTitle(Object modelName);

  /// No description provided for @loadPreset.
  ///
  /// In en, this message translates to:
  /// **'Load a Preset'**
  String get loadPreset;

  /// No description provided for @selectPreset.
  ///
  /// In en, this message translates to:
  /// **'Select a preset'**
  String get selectPreset;

  /// No description provided for @unknownPreset.
  ///
  /// In en, this message translates to:
  /// **'Unknown Preset'**
  String get unknownPreset;

  /// No description provided for @apiEndpoint.
  ///
  /// In en, this message translates to:
  /// **'API Endpoint'**
  String get apiEndpoint;

  /// No description provided for @apiEndpointDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter the OpenAI-compatible API endpoint URL'**
  String get apiEndpointDescription;

  /// No description provided for @endpointUrl.
  ///
  /// In en, this message translates to:
  /// **'Endpoint URL'**
  String get endpointUrl;

  /// No description provided for @endpointUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://api.openai.com/v1/chat/completions'**
  String get endpointUrlHint;

  /// No description provided for @pleaseEnterEndpointUrl.
  ///
  /// In en, this message translates to:
  /// **'Please enter an endpoint URL'**
  String get pleaseEnterEndpointUrl;

  /// No description provided for @pleaseEnterValidUrl.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid URL'**
  String get pleaseEnterValidUrl;

  /// No description provided for @modelName.
  ///
  /// In en, this message translates to:
  /// **'Model Name'**
  String get modelName;

  /// No description provided for @modelNameDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter the model name to use (e.g., gpt-4, gpt-3.5-turbo, claude-3-sonnet)'**
  String get modelNameDescription;

  /// No description provided for @modelNameHint.
  ///
  /// In en, this message translates to:
  /// **'gpt-4'**
  String get modelNameHint;

  /// No description provided for @pleaseEnterModelName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a model name'**
  String get pleaseEnterModelName;

  /// No description provided for @displayName.
  ///
  /// In en, this message translates to:
  /// **'Display Name'**
  String get displayName;

  /// No description provided for @displayNameDescription.
  ///
  /// In en, this message translates to:
  /// **'A custom name to display in the app for this model'**
  String get displayNameDescription;

  /// No description provided for @displayNameHint.
  ///
  /// In en, this message translates to:
  /// **'My Custom Model'**
  String get displayNameHint;

  /// No description provided for @tokenLimits.
  ///
  /// In en, this message translates to:
  /// **'Token Limits'**
  String get tokenLimits;

  /// No description provided for @tokenLimitsDescription.
  ///
  /// In en, this message translates to:
  /// **'Configure the maximum input and output tokens for this model'**
  String get tokenLimitsDescription;

  /// No description provided for @maxInputTokens.
  ///
  /// In en, this message translates to:
  /// **'Max Input Tokens'**
  String get maxInputTokens;

  /// No description provided for @maxInputTokensHint.
  ///
  /// In en, this message translates to:
  /// **'100000'**
  String get maxInputTokensHint;

  /// No description provided for @maxOutputTokens.
  ///
  /// In en, this message translates to:
  /// **'Max Output Tokens'**
  String get maxOutputTokens;

  /// No description provided for @maxOutputTokensHint.
  ///
  /// In en, this message translates to:
  /// **'4000'**
  String get maxOutputTokensHint;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @mustBePositiveNumber.
  ///
  /// In en, this message translates to:
  /// **'Must be a positive number'**
  String get mustBePositiveNumber;

  /// No description provided for @modelCapabilities.
  ///
  /// In en, this message translates to:
  /// **'Model Capabilities'**
  String get modelCapabilities;

  /// No description provided for @modelCapabilitiesDescription.
  ///
  /// In en, this message translates to:
  /// **'Select which capabilities this model supports'**
  String get modelCapabilitiesDescription;

  /// No description provided for @imageProcessing.
  ///
  /// In en, this message translates to:
  /// **'Image Processing'**
  String get imageProcessing;

  /// No description provided for @imageProcessingDescription.
  ///
  /// In en, this message translates to:
  /// **'Can analyze and understand images'**
  String get imageProcessingDescription;

  /// No description provided for @documentUnderstanding.
  ///
  /// In en, this message translates to:
  /// **'Document Understanding'**
  String get documentUnderstanding;

  /// No description provided for @documentUnderstandingDescription.
  ///
  /// In en, this message translates to:
  /// **'Can process PDFs and documents'**
  String get documentUnderstandingDescription;

  /// No description provided for @audioProcessing.
  ///
  /// In en, this message translates to:
  /// **'Audio Processing'**
  String get audioProcessing;

  /// No description provided for @audioProcessingDescription.
  ///
  /// In en, this message translates to:
  /// **'Can transcribe and analyze audio'**
  String get audioProcessingDescription;

  /// No description provided for @videoProcessing.
  ///
  /// In en, this message translates to:
  /// **'Video Processing'**
  String get videoProcessing;

  /// No description provided for @videoProcessingDescription.
  ///
  /// In en, this message translates to:
  /// **'Can analyze video content'**
  String get videoProcessingDescription;

  /// No description provided for @geminiModelDescription.
  ///
  /// In en, this message translates to:
  /// **'Google\'s most advanced model with full multimodal capabilities'**
  String get geminiModelDescription;

  /// No description provided for @openaiCompatibleModelDescription.
  ///
  /// In en, this message translates to:
  /// **'Compatible with OpenAI API endpoints with configurable capabilities'**
  String get openaiCompatibleModelDescription;

  /// No description provided for @geminiModelDescriptionDetailed.
  ///
  /// In en, this message translates to:
  /// **'Google\'s most advanced model with full multimodal capabilities including document understanding.'**
  String get geminiModelDescriptionDetailed;

  /// No description provided for @openaiCompatibleModelDescriptionDetailed.
  ///
  /// In en, this message translates to:
  /// **'Compatible with OpenAI API endpoints. Configure the endpoint URL and select supported capabilities.'**
  String get openaiCompatibleModelDescriptionDetailed;

  /// No description provided for @geminiApiKeyDescription.
  ///
  /// In en, this message translates to:
  /// **'Get your API key from Google AI Studio'**
  String get geminiApiKeyDescription;

  /// No description provided for @openaiCompatibleApiKeyDescription.
  ///
  /// In en, this message translates to:
  /// **'Get your API key from your OpenAI-compatible service provider'**
  String get openaiCompatibleApiKeyDescription;

  /// No description provided for @errorConfiguringModel.
  ///
  /// In en, this message translates to:
  /// **'Error configuring model: {error}'**
  String errorConfiguringModel(Object error);

  /// No description provided for @recovery.
  ///
  /// In en, this message translates to:
  /// **'Recovery'**
  String get recovery;

  /// No description provided for @recoverySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Backup and restore your notes'**
  String get recoverySubtitle;

  /// No description provided for @exportAllNotes.
  ///
  /// In en, this message translates to:
  /// **'Export All Notes'**
  String get exportAllNotes;

  /// No description provided for @exportAllNotesDescription.
  ///
  /// In en, this message translates to:
  /// **'Create a complete backup of all your notes and attachments'**
  String get exportAllNotesDescription;

  /// No description provided for @exporting.
  ///
  /// In en, this message translates to:
  /// **'Exporting...'**
  String get exporting;

  /// No description provided for @exportLogs.
  ///
  /// In en, this message translates to:
  /// **'Export Logs'**
  String get exportLogs;

  /// No description provided for @previousExports.
  ///
  /// In en, this message translates to:
  /// **'Previous Exports'**
  String get previousExports;

  /// No description provided for @saveAgain.
  ///
  /// In en, this message translates to:
  /// **'Save Again'**
  String get saveAgain;

  /// No description provided for @backupAllNotes.
  ///
  /// In en, this message translates to:
  /// **'Backup All Notes'**
  String get backupAllNotes;

  /// No description provided for @backupAllNotesDescription.
  ///
  /// In en, this message translates to:
  /// **'Create a complete backup of all your notes and attachments. The backup will be saved as a zip file that you can download.'**
  String get backupAllNotesDescription;

  /// No description provided for @creatingBackup.
  ///
  /// In en, this message translates to:
  /// **'Creating Backup...'**
  String get creatingBackup;

  /// No description provided for @backupLogs.
  ///
  /// In en, this message translates to:
  /// **'Backup Logs'**
  String get backupLogs;

  /// No description provided for @previousBackups.
  ///
  /// In en, this message translates to:
  /// **'Previous Backups'**
  String get previousBackups;

  /// No description provided for @backup.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backup;

  /// No description provided for @startingBackupProcess.
  ///
  /// In en, this message translates to:
  /// **'Starting backup process...'**
  String get startingBackupProcess;

  /// No description provided for @createdTempDirectory.
  ///
  /// In en, this message translates to:
  /// **'Created temp directory: {path}'**
  String createdTempDirectory(Object path);

  /// No description provided for @forcingDatabaseCheckpoint.
  ///
  /// In en, this message translates to:
  /// **'Forcing database checkpoint...'**
  String get forcingDatabaseCheckpoint;

  /// No description provided for @databaseCopiedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Database copied successfully'**
  String get databaseCopiedSuccessfully;

  /// No description provided for @databaseFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Database file not found'**
  String get databaseFileNotFound;

  /// No description provided for @attachmentsDirectoryCopiedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Attachments directory copied successfully'**
  String get attachmentsDirectoryCopiedSuccessfully;

  /// No description provided for @noAttachmentsDirectoryFound.
  ///
  /// In en, this message translates to:
  /// **'No attachments directory found, creating empty one'**
  String get noAttachmentsDirectoryFound;

  /// No description provided for @updatingAttachmentPathsInCopiedDatabase.
  ///
  /// In en, this message translates to:
  /// **'Updating attachment paths in copied database...'**
  String get updatingAttachmentPathsInCopiedDatabase;

  /// No description provided for @databaseConsistencyVerified.
  ///
  /// In en, this message translates to:
  /// **'Database consistency verified'**
  String get databaseConsistencyVerified;

  /// No description provided for @creatingZipArchive.
  ///
  /// In en, this message translates to:
  /// **'Creating zip archive...'**
  String get creatingZipArchive;

  /// No description provided for @backupCompleted.
  ///
  /// In en, this message translates to:
  /// **'Backup completed: {path}'**
  String backupCompleted(Object path);

  /// No description provided for @backupFailed.
  ///
  /// In en, this message translates to:
  /// **'Backup failed: {error}'**
  String backupFailed(Object error);

  /// No description provided for @foundAttachmentsWithAbsolutePaths.
  ///
  /// In en, this message translates to:
  /// **'Found {count} attachments with absolute paths to update'**
  String foundAttachmentsWithAbsolutePaths(Object count);

  /// No description provided for @copiedAndUpdated.
  ///
  /// In en, this message translates to:
  /// **'Copied and updated: {original} -> {unique}'**
  String copiedAndUpdated(Object original, Object unique);

  /// No description provided for @warningSourceFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Warning: Source file not found: {path}'**
  String warningSourceFileNotFound(Object path);

  /// No description provided for @deletedBackup.
  ///
  /// In en, this message translates to:
  /// **'Deleted backup: {name}'**
  String deletedBackup(Object name);

  /// No description provided for @errorDeletingBackup.
  ///
  /// In en, this message translates to:
  /// **'Error deleting backup: {error}'**
  String errorDeletingBackup(Object error);

  /// No description provided for @backupFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'Backup file not found: {name}'**
  String backupFileNotFound(Object name);

  /// No description provided for @errorSavingBackupAgain.
  ///
  /// In en, this message translates to:
  /// **'Error saving backup again: {error}'**
  String errorSavingBackupAgain(Object error);

  /// No description provided for @importBackup.
  ///
  /// In en, this message translates to:
  /// **'Import Backup'**
  String get importBackup;

  /// No description provided for @importBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Restore your notes from a backup file'**
  String get importBackupDescription;

  /// No description provided for @importingBackup.
  ///
  /// In en, this message translates to:
  /// **'Importing Backup...'**
  String get importingBackup;

  /// No description provided for @importLogs.
  ///
  /// In en, this message translates to:
  /// **'Import Logs'**
  String get importLogs;

  /// No description provided for @selectBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Select Backup File'**
  String get selectBackupFile;

  /// No description provided for @selectBackupFileDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose a backup zip file to restore from'**
  String get selectBackupFileDescription;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String importFailed(Object error);

  /// No description provided for @invalidBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Invalid backup file format'**
  String get invalidBackupFile;

  /// No description provided for @backupVersionTooNew.
  ///
  /// In en, this message translates to:
  /// **'Backup is from a newer version of the app. Please update the app first.'**
  String get backupVersionTooNew;

  /// No description provided for @checkpointingDatabase.
  ///
  /// In en, this message translates to:
  /// **'Checkpointing current database...'**
  String get checkpointingDatabase;

  /// No description provided for @copyingDatabaseToStaging.
  ///
  /// In en, this message translates to:
  /// **'Copying database to staging directory...'**
  String get copyingDatabaseToStaging;

  /// No description provided for @extractingBackupFile.
  ///
  /// In en, this message translates to:
  /// **'Extracting backup file...'**
  String get extractingBackupFile;

  /// No description provided for @validatingBackupDatabase.
  ///
  /// In en, this message translates to:
  /// **'Validating backup database version...'**
  String get validatingBackupDatabase;

  /// No description provided for @migratingBackupDatabase.
  ///
  /// In en, this message translates to:
  /// **'Migrating backup database to current version...'**
  String get migratingBackupDatabase;

  /// No description provided for @mergingNotes.
  ///
  /// In en, this message translates to:
  /// **'Merging notes...'**
  String get mergingNotes;

  /// No description provided for @mergingSubNotes.
  ///
  /// In en, this message translates to:
  /// **'Merging sub-notes...'**
  String get mergingSubNotes;

  /// No description provided for @mergingTags.
  ///
  /// In en, this message translates to:
  /// **'Merging tags...'**
  String get mergingTags;

  /// No description provided for @mergingRelationships.
  ///
  /// In en, this message translates to:
  /// **'Merging relationships...'**
  String get mergingRelationships;

  /// No description provided for @mergingFilters.
  ///
  /// In en, this message translates to:
  /// **'Merging filters...'**
  String get mergingFilters;

  /// No description provided for @mergingUserApps.
  ///
  /// In en, this message translates to:
  /// **'Merging user apps...'**
  String get mergingUserApps;

  /// No description provided for @copyingAttachments.
  ///
  /// In en, this message translates to:
  /// **'Copying attachments...'**
  String get copyingAttachments;

  /// No description provided for @swappingDatabases.
  ///
  /// In en, this message translates to:
  /// **'Swapping databases...'**
  String get swappingDatabases;

  /// No description provided for @reloadingData.
  ///
  /// In en, this message translates to:
  /// **'Reloading data...'**
  String get reloadingData;

  /// No description provided for @undoBackup.
  ///
  /// In en, this message translates to:
  /// **'Undo Backup'**
  String get undoBackup;

  /// No description provided for @undoBackupDescription.
  ///
  /// In en, this message translates to:
  /// **'Restore the original database'**
  String get undoBackupDescription;

  /// No description provided for @undoBackupConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to undo the backup? This will restore your original database and lose any changes made since the import.'**
  String get undoBackupConfirmation;

  /// No description provided for @undoBackupCompleted.
  ///
  /// In en, this message translates to:
  /// **'Backup undone successfully!'**
  String get undoBackupCompleted;

  /// No description provided for @errorUndoingBackup.
  ///
  /// In en, this message translates to:
  /// **'Error undoing backup: {error}'**
  String errorUndoingBackup(Object error);

  /// No description provided for @backupRestored.
  ///
  /// In en, this message translates to:
  /// **'Backup restored successfully!'**
  String get backupRestored;

  /// No description provided for @errorRestoringBackup.
  ///
  /// In en, this message translates to:
  /// **'Error restoring backup: {error}'**
  String errorRestoringBackup(Object error);

  /// No description provided for @cloneApp.
  ///
  /// In en, this message translates to:
  /// **'Clone App'**
  String get cloneApp;

  /// No description provided for @appClonedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'App cloned successfully!'**
  String get appClonedSuccessfully;

  /// No description provided for @errorCloningApp.
  ///
  /// In en, this message translates to:
  /// **'Error cloning app: {error}'**
  String errorCloningApp(Object error);

  /// No description provided for @mcpSettings.
  ///
  /// In en, this message translates to:
  /// **'MCP Settings'**
  String get mcpSettings;

  /// No description provided for @mcpSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure Model Context Protocol endpoints'**
  String get mcpSettingsSubtitle;

  /// No description provided for @errorLoadingEndpoints.
  ///
  /// In en, this message translates to:
  /// **'Error loading endpoints: {error}'**
  String errorLoadingEndpoints(Object error);

  /// No description provided for @addMcpEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Add MCP Endpoint'**
  String get addMcpEndpoint;

  /// No description provided for @addMcpEndpointTitle.
  ///
  /// In en, this message translates to:
  /// **'Add MCP Endpoint'**
  String get addMcpEndpointTitle;

  /// No description provided for @nameHint.
  ///
  /// In en, this message translates to:
  /// **'My MCP Server'**
  String get nameHint;

  /// No description provided for @baseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get baseUrl;

  /// No description provided for @baseUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://api.example.com or https://server.smithery.ai/@user/server/mcp?api_key=xxx'**
  String get baseUrlHint;

  /// No description provided for @baseUrlHelperText.
  ///
  /// In en, this message translates to:
  /// **'Include query params for auth if needed (e.g., Smithery)'**
  String get baseUrlHelperText;

  /// No description provided for @transportType.
  ///
  /// In en, this message translates to:
  /// **'Transport Type'**
  String get transportType;

  /// No description provided for @bearerTokenOptional.
  ///
  /// In en, this message translates to:
  /// **'Bearer Token (Optional)'**
  String get bearerTokenOptional;

  /// No description provided for @bearerTokenHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty if auth is in URL params'**
  String get bearerTokenHint;

  /// No description provided for @bearerTokenHelperText.
  ///
  /// In en, this message translates to:
  /// **'Optional: For header-based authentication'**
  String get bearerTokenHelperText;

  /// No description provided for @pleaseProvideNameAndUrl.
  ///
  /// In en, this message translates to:
  /// **'Please provide name and URL'**
  String get pleaseProvideNameAndUrl;

  /// No description provided for @addedEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Added endpoint: {name}'**
  String addedEndpoint(Object name);

  /// No description provided for @errorAddingEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String errorAddingEndpoint(Object error);

  /// No description provided for @deleteEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Delete Endpoint'**
  String get deleteEndpoint;

  /// No description provided for @deleteEndpointConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"? This will also delete cached tools.'**
  String deleteEndpointConfirmation(Object name);

  /// No description provided for @deletedEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Deleted endpoint: {name}'**
  String deletedEndpoint(Object name);

  /// No description provided for @errorDeletingEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Error deleting endpoint: {error}'**
  String errorDeletingEndpoint(Object error);

  /// No description provided for @refreshedToolsFor.
  ///
  /// In en, this message translates to:
  /// **'Refreshed tools for {name}'**
  String refreshedToolsFor(Object name);

  /// No description provided for @errorRefreshingTools.
  ///
  /// In en, this message translates to:
  /// **'Error refreshing tools: {error}'**
  String errorRefreshingTools(Object error);

  /// No description provided for @tools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get tools;

  /// No description provided for @toolsFor.
  ///
  /// In en, this message translates to:
  /// **'Tools - {name}'**
  String toolsFor(Object name);

  /// No description provided for @fetched.
  ///
  /// In en, this message translates to:
  /// **'Fetched'**
  String get fetched;

  /// No description provided for @toolsCount.
  ///
  /// In en, this message translates to:
  /// **'Tools: {count}'**
  String toolsCount(Object count);

  /// No description provided for @noToolsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No tools available'**
  String get noToolsAvailable;

  /// No description provided for @noToolsCachedFor.
  ///
  /// In en, this message translates to:
  /// **'No tools cached for {name}. Click refresh to fetch tools.'**
  String noToolsCachedFor(Object name);

  /// No description provided for @refreshTools.
  ///
  /// In en, this message translates to:
  /// **'Refresh Tools'**
  String get refreshTools;

  /// No description provided for @viewTools.
  ///
  /// In en, this message translates to:
  /// **'View Tools'**
  String get viewTools;

  /// No description provided for @noMcpEndpointsConfigured.
  ///
  /// In en, this message translates to:
  /// **'No MCP endpoints configured'**
  String get noMcpEndpointsConfigured;

  /// No description provided for @clickAddMcpEndpointToGetStarted.
  ///
  /// In en, this message translates to:
  /// **'Click \"Add MCP Endpoint\" to get started'**
  String get clickAddMcpEndpointToGetStarted;

  /// No description provided for @noteActionApp.
  ///
  /// In en, this message translates to:
  /// **'Note Action App'**
  String get noteActionApp;

  /// No description provided for @noteActionAppSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This type of app will operate specifically on pre-selected notes'**
  String get noteActionAppSubtitle;

  /// No description provided for @imageAttachmentsOptional.
  ///
  /// In en, this message translates to:
  /// **'Image Attachments (Optional)'**
  String get imageAttachmentsOptional;

  /// No description provided for @imageAttachmentsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Attach images to help explain what you want the AI to create'**
  String get imageAttachmentsSubtitle;

  /// No description provided for @addImage.
  ///
  /// In en, this message translates to:
  /// **'Add Image'**
  String get addImage;

  /// No description provided for @noLibrariesAddedYet.
  ///
  /// In en, this message translates to:
  /// **'No libraries added yet. Click \"Add Library\" to get started.'**
  String get noLibrariesAddedYet;

  /// No description provided for @conversation.
  ///
  /// In en, this message translates to:
  /// **'Conversation'**
  String get conversation;

  /// No description provided for @newConversation.
  ///
  /// In en, this message translates to:
  /// **'New Conversation'**
  String get newConversation;

  /// No description provided for @aiConversation.
  ///
  /// In en, this message translates to:
  /// **'AI Conversation'**
  String get aiConversation;

  /// No description provided for @conversationTree.
  ///
  /// In en, this message translates to:
  /// **'Conversation Tree'**
  String get conversationTree;

  /// No description provided for @conversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get conversations;

  /// No description provided for @typeYourMessage.
  ///
  /// In en, this message translates to:
  /// **'Type your message...'**
  String get typeYourMessage;

  /// No description provided for @cancellingRequest.
  ///
  /// In en, this message translates to:
  /// **'Cancelling request...'**
  String get cancellingRequest;

  /// No description provided for @takePhotoAttachment.
  ///
  /// In en, this message translates to:
  /// **'Take photo'**
  String get takePhotoAttachment;

  /// No description provided for @mcpTools.
  ///
  /// In en, this message translates to:
  /// **'MCP Tools'**
  String get mcpTools;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'active'**
  String get active;

  /// No description provided for @toolsAvailable.
  ///
  /// In en, this message translates to:
  /// **'{count} tools available'**
  String toolsAvailable(Object count);

  /// No description provided for @manageNotes.
  ///
  /// In en, this message translates to:
  /// **'Manage Notes'**
  String get manageNotes;

  /// No description provided for @viewTree.
  ///
  /// In en, this message translates to:
  /// **'View Tree'**
  String get viewTree;

  /// No description provided for @noteIncluded.
  ///
  /// In en, this message translates to:
  /// **'{count} note(s) included'**
  String noteIncluded(Object count);

  /// No description provided for @messageCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Message copied to clipboard'**
  String get messageCopiedToClipboard;

  /// No description provided for @addToNote.
  ///
  /// In en, this message translates to:
  /// **'Add to Note'**
  String get addToNote;

  /// No description provided for @forkConversation.
  ///
  /// In en, this message translates to:
  /// **'Fork conversation'**
  String get forkConversation;

  /// No description provided for @forkConversationConfirm.
  ///
  /// In en, this message translates to:
  /// **'Fork this conversation?'**
  String get forkConversationConfirm;

  /// No description provided for @fork.
  ///
  /// In en, this message translates to:
  /// **'Fork'**
  String get fork;

  /// No description provided for @forkedConversationSuccess.
  ///
  /// In en, this message translates to:
  /// **'Conversation forked successfully'**
  String get forkedConversationSuccess;

  /// No description provided for @errorForkingConversation.
  ///
  /// In en, this message translates to:
  /// **'Error forking conversation: {error}'**
  String errorForkingConversation(Object error);

  /// No description provided for @selectNotesForConversation.
  ///
  /// In en, this message translates to:
  /// **'Select notes for conversation'**
  String get selectNotesForConversation;

  /// No description provided for @addNotesToConversation.
  ///
  /// In en, this message translates to:
  /// **'Add Notes'**
  String get addNotesToConversation;

  /// No description provided for @clearAllNotes.
  ///
  /// In en, this message translates to:
  /// **'Clear All'**
  String get clearAllNotes;

  /// No description provided for @notesAndContext.
  ///
  /// In en, this message translates to:
  /// **'Notes and Context'**
  String get notesAndContext;

  /// No description provided for @missingNotes.
  ///
  /// In en, this message translates to:
  /// **'Missing Notes'**
  String get missingNotes;

  /// No description provided for @missingNotesMessage.
  ///
  /// In en, this message translates to:
  /// **'This conversation references notes that no longer exist:'**
  String get missingNotesMessage;

  /// No description provided for @missingNotesWillCleanup.
  ///
  /// In en, this message translates to:
  /// **'These references will be automatically cleaned up.'**
  String get missingNotesWillCleanup;

  /// No description provided for @cleanUp.
  ///
  /// In en, this message translates to:
  /// **'Clean Up'**
  String get cleanUp;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @refreshTree.
  ///
  /// In en, this message translates to:
  /// **'Refresh tree'**
  String get refreshTree;

  /// No description provided for @noConversationsFound.
  ///
  /// In en, this message translates to:
  /// **'No conversations found. Start a new conversation to see the tree.'**
  String get noConversationsFound;

  /// No description provided for @treeRefreshedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Tree refreshed successfully'**
  String get treeRefreshedSuccessfully;

  /// No description provided for @errorRefreshingTree.
  ///
  /// In en, this message translates to:
  /// **'Error refreshing tree: {error}'**
  String errorRefreshingTree(Object error);

  /// No description provided for @selectInteractionToViewDetails.
  ///
  /// In en, this message translates to:
  /// **'Select an interaction to view details'**
  String get selectInteractionToViewDetails;

  /// No description provided for @deleteInteraction.
  ///
  /// In en, this message translates to:
  /// **'Delete Interaction'**
  String get deleteInteraction;

  /// No description provided for @deleteInteractionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this interaction and all its descendants? This action cannot be undone.'**
  String get deleteInteractionConfirm;

  /// No description provided for @interactionDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Interaction deleted successfully'**
  String get interactionDeletedSuccessfully;

  /// No description provided for @errorDeletingInteraction.
  ///
  /// In en, this message translates to:
  /// **'Error deleting interaction: {error}'**
  String errorDeletingInteraction(Object error);

  /// No description provided for @forkFromHere.
  ///
  /// In en, this message translates to:
  /// **'Fork from here'**
  String get forkFromHere;

  /// No description provided for @deleteInteractionAction.
  ///
  /// In en, this message translates to:
  /// **'Delete interaction'**
  String get deleteInteractionAction;

  /// No description provided for @saveSelectedNodesAsNote.
  ///
  /// In en, this message translates to:
  /// **'Save selected nodes as note'**
  String get saveSelectedNodesAsNote;

  /// No description provided for @createFromSelected.
  ///
  /// In en, this message translates to:
  /// **'Create from selected'**
  String get createFromSelected;

  /// No description provided for @exitMultiSelect.
  ///
  /// In en, this message translates to:
  /// **'Exit multi-select'**
  String get exitMultiSelect;

  /// No description provided for @pleaseSelectNodesFirst.
  ///
  /// In en, this message translates to:
  /// **'Please select nodes first'**
  String get pleaseSelectNodesFirst;

  /// No description provided for @interaction.
  ///
  /// In en, this message translates to:
  /// **'Interaction'**
  String get interaction;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// No description provided for @ai.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get ai;

  /// No description provided for @justNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get justNow;

  /// No description provided for @addNoteDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add to Note'**
  String get addNoteDialogTitle;

  /// No description provided for @addNoteDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'How would you like to add this content to your notes?'**
  String get addNoteDialogMessage;

  /// No description provided for @addAsIs.
  ///
  /// In en, this message translates to:
  /// **'Add as-is'**
  String get addAsIs;

  /// No description provided for @addAsIsDescription.
  ///
  /// In en, this message translates to:
  /// **'Add the content directly without modification'**
  String get addAsIsDescription;

  /// No description provided for @letAICreateNote.
  ///
  /// In en, this message translates to:
  /// **'Let AI create note'**
  String get letAICreateNote;

  /// No description provided for @letAICreateNoteDescription.
  ///
  /// In en, this message translates to:
  /// **'Use AI to summarize or transform the content'**
  String get letAICreateNoteDescription;

  /// No description provided for @noteTitle.
  ///
  /// In en, this message translates to:
  /// **'Note Title'**
  String get noteTitle;

  /// No description provided for @enterNoteTitlePrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter a title for the new note:'**
  String get enterNoteTitlePrompt;

  /// No description provided for @noteTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Note title'**
  String get noteTitleHint;

  /// No description provided for @multipleNotesCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'{count} notes created successfully'**
  String multipleNotesCreatedSuccessfully(Object count);

  /// No description provided for @aiNoteCreator.
  ///
  /// In en, this message translates to:
  /// **'AI Note Creator'**
  String get aiNoteCreator;

  /// No description provided for @aiNoteCreatorInstructions.
  ///
  /// In en, this message translates to:
  /// **'The AI will use the conversation content, along with any additional context you provide below, to create note(s) based on your prompt.'**
  String get aiNoteCreatorInstructions;

  /// No description provided for @prompt.
  ///
  /// In en, this message translates to:
  /// **'Prompt'**
  String get prompt;

  /// No description provided for @promptHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what you want the AI to do...'**
  String get promptHint;

  /// No description provided for @promptTip.
  ///
  /// In en, this message translates to:
  /// **'Tip: The default \"Summarize\" will create a concise summary. You can change this to any instruction like \"Extract action items\", \"Create a detailed outline\", etc.'**
  String get promptTip;

  /// No description provided for @additionalContextNotes.
  ///
  /// In en, this message translates to:
  /// **'Additional Context Notes ({count})'**
  String additionalContextNotes(Object count);

  /// No description provided for @addNotes.
  ///
  /// In en, this message translates to:
  /// **'Add Notes'**
  String get addNotes;

  /// No description provided for @noAdditionalNotesSelected.
  ///
  /// In en, this message translates to:
  /// **'No additional notes selected. The AI will only use the conversation content.'**
  String get noAdditionalNotesSelected;

  /// No description provided for @proceed.
  ///
  /// In en, this message translates to:
  /// **'Proceed'**
  String get proceed;

  /// No description provided for @pleaseEnterPrompt.
  ///
  /// In en, this message translates to:
  /// **'Please enter a prompt'**
  String get pleaseEnterPrompt;

  /// No description provided for @view.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get view;

  /// No description provided for @errorSavingNodes.
  ///
  /// In en, this message translates to:
  /// **'Error saving nodes: {error}'**
  String errorSavingNodes(Object error);

  /// No description provided for @cancelAiRequest.
  ///
  /// In en, this message translates to:
  /// **'Cancel AI request'**
  String get cancelAiRequest;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @attachedFiles.
  ///
  /// In en, this message translates to:
  /// **'Attached Files ({count})'**
  String attachedFiles(Object count);

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @errorLoadingData.
  ///
  /// In en, this message translates to:
  /// **'Error loading data'**
  String get errorLoadingData;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @errorProcessingSharedContent.
  ///
  /// In en, this message translates to:
  /// **'Error Processing Shared Content'**
  String get errorProcessingSharedContent;

  /// No description provided for @whatWouldYouLikeToDo.
  ///
  /// In en, this message translates to:
  /// **'What would you like to do?'**
  String get whatWouldYouLikeToDo;

  /// No description provided for @createNewNoteWithThisContent.
  ///
  /// In en, this message translates to:
  /// **'Create a new note with this content'**
  String get createNewNoteWithThisContent;

  /// No description provided for @addThisContentToExistingNote.
  ///
  /// In en, this message translates to:
  /// **'Add this content to an existing note'**
  String get addThisContentToExistingNote;

  /// No description provided for @selectNote.
  ///
  /// In en, this message translates to:
  /// **'Select a note...'**
  String get selectNote;

  /// No description provided for @showingNotes.
  ///
  /// In en, this message translates to:
  /// **'Showing {filteredCount} of {totalCount} notes'**
  String showingNotes(int filteredCount, int totalCount);

  /// No description provided for @noteDetails.
  ///
  /// In en, this message translates to:
  /// **'Note Details'**
  String get noteDetails;

  /// No description provided for @contentPreview.
  ///
  /// In en, this message translates to:
  /// **'Content Preview'**
  String get contentPreview;

  /// No description provided for @selectedTags.
  ///
  /// In en, this message translates to:
  /// **'Selected tags:'**
  String get selectedTags;

  /// No description provided for @availableTags.
  ///
  /// In en, this message translates to:
  /// **'Available tags:'**
  String get availableTags;

  /// No description provided for @webContentExtractionNotSupportedLinux.
  ///
  /// In en, this message translates to:
  /// **'Web content extraction is not supported on Linux.'**
  String get webContentExtractionNotSupportedLinux;

  /// No description provided for @pleaseUseOtherPlatformsForWebExtraction.
  ///
  /// In en, this message translates to:
  /// **'Please use Android, iOS, or Web to extract web content.'**
  String get pleaseUseOtherPlatformsForWebExtraction;

  /// No description provided for @extractWebContent.
  ///
  /// In en, this message translates to:
  /// **'Extract Web Content'**
  String get extractWebContent;

  /// No description provided for @extracting.
  ///
  /// In en, this message translates to:
  /// **'Extracting...'**
  String get extracting;

  /// No description provided for @extractContentUsingAiForBetterResults.
  ///
  /// In en, this message translates to:
  /// **'Extract content using AI for better results'**
  String get extractContentUsingAiForBetterResults;

  /// No description provided for @extractWithAi.
  ///
  /// In en, this message translates to:
  /// **'Extract with AI (Slower)'**
  String get extractWithAi;

  /// No description provided for @extractingWithAi.
  ///
  /// In en, this message translates to:
  /// **'Extracting with AI...'**
  String get extractingWithAi;

  /// No description provided for @asIs.
  ///
  /// In en, this message translates to:
  /// **'As-Is'**
  String get asIs;

  /// No description provided for @loadingWebPage.
  ///
  /// In en, this message translates to:
  /// **'Loading web page...'**
  String get loadingWebPage;

  /// No description provided for @imageDetected.
  ///
  /// In en, this message translates to:
  /// **'Image Detected'**
  String get imageDetected;

  /// No description provided for @extractImageContent.
  ///
  /// In en, this message translates to:
  /// **'Extract Image Content'**
  String get extractImageContent;

  /// No description provided for @extractingImageContent.
  ///
  /// In en, this message translates to:
  /// **'Extracting...'**
  String get extractingImageContent;

  /// No description provided for @pdfDetected.
  ///
  /// In en, this message translates to:
  /// **'PDF Detected'**
  String get pdfDetected;

  /// No description provided for @extractPdfContent.
  ///
  /// In en, this message translates to:
  /// **'Extract PDF Content'**
  String get extractPdfContent;

  /// No description provided for @extractingPdfContent.
  ///
  /// In en, this message translates to:
  /// **'Extracting...'**
  String get extractingPdfContent;

  /// No description provided for @sharedImage.
  ///
  /// In en, this message translates to:
  /// **'Shared Image'**
  String get sharedImage;

  /// No description provided for @pleaseSelectNoteToAppend.
  ///
  /// In en, this message translates to:
  /// **'Please select a note to append to'**
  String get pleaseSelectNoteToAppend;

  /// No description provided for @contentAppendedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Content appended successfully!'**
  String get contentAppendedSuccessfully;

  /// No description provided for @extractingWebContent.
  ///
  /// In en, this message translates to:
  /// **'Extracting Web Content'**
  String get extractingWebContent;

  /// No description provided for @sharedContentFrom.
  ///
  /// In en, this message translates to:
  /// **'Shared content from'**
  String get sharedContentFrom;

  /// No description provided for @sharedUrl.
  ///
  /// In en, this message translates to:
  /// **'Shared URL'**
  String get sharedUrl;

  /// No description provided for @unknownSource.
  ///
  /// In en, this message translates to:
  /// **'unknown source'**
  String get unknownSource;

  /// No description provided for @failedToPrepareNote.
  ///
  /// In en, this message translates to:
  /// **'Failed to prepare note: {error}'**
  String failedToPrepareNote(String error);

  /// No description provided for @errorExtractingWebContent.
  ///
  /// In en, this message translates to:
  /// **'Error extracting web content: {error}'**
  String errorExtractingWebContent(String error);

  /// No description provided for @failedToLoadWebPage.
  ///
  /// In en, this message translates to:
  /// **'Failed to load web page: {message}'**
  String failedToLoadWebPage(String message);

  /// No description provided for @extractionCancelledByUser.
  ///
  /// In en, this message translates to:
  /// **'Extraction cancelled by user'**
  String get extractionCancelledByUser;

  /// No description provided for @readabilityExtractionFailed.
  ///
  /// In en, this message translates to:
  /// **'Readability extraction failed: {error}'**
  String readabilityExtractionFailed(String error);

  /// No description provided for @failedToExtractContentFromWebPage.
  ///
  /// In en, this message translates to:
  /// **'Failed to extract content from the web page'**
  String get failedToExtractContentFromWebPage;

  /// No description provided for @processingWithAi.
  ///
  /// In en, this message translates to:
  /// **'Processing with AI...'**
  String get processingWithAi;

  /// No description provided for @checkingApiKey.
  ///
  /// In en, this message translates to:
  /// **'Checking API key...'**
  String get checkingApiKey;

  /// No description provided for @errorExtractingImageContent.
  ///
  /// In en, this message translates to:
  /// **'Error extracting image content: {error}'**
  String errorExtractingImageContent(String error);

  /// No description provided for @errorExtractingPdfContent.
  ///
  /// In en, this message translates to:
  /// **'Error extracting PDF content: {error}'**
  String errorExtractingPdfContent(String error);

  /// No description provided for @unknownImage.
  ///
  /// In en, this message translates to:
  /// **'Unknown image'**
  String get unknownImage;

  /// No description provided for @unknownPdf.
  ///
  /// In en, this message translates to:
  /// **'Unknown PDF'**
  String get unknownPdf;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
