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
  /// **'Please enter your API key'**
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
  /// **'Attach Files'**
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
  /// **'Note created successfully!'**
  String get noteCreatedSuccessfully;

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
  /// **'Copy to Clipboard'**
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
