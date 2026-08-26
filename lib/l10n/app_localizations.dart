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

  /// No description provided for @untitled.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get untitled;

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
  /// **'AI Settings'**
  String get aiApi;

  /// No description provided for @aiApiSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure AI models and settings'**
  String get aiApiSubtitle;

  /// No description provided for @aiPrompts.
  ///
  /// In en, this message translates to:
  /// **'Prompts'**
  String get aiPrompts;

  /// No description provided for @aiPromptsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Customize AI prompt injections and overrides'**
  String get aiPromptsSubtitle;

  /// No description provided for @aiConversationSettings.
  ///
  /// In en, this message translates to:
  /// **'AI conversations'**
  String get aiConversationSettings;

  /// No description provided for @aiConversationSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Control AI conversation settings'**
  String get aiConversationSettingsSubtitle;

  /// No description provided for @aiConversationSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Set the default number of tool iterations before Note Synapse asks for approval. You can still adjust the limit per conversation when needed.'**
  String get aiConversationSettingsDescription;

  /// No description provided for @iterationLimitLabel.
  ///
  /// In en, this message translates to:
  /// **'Tool iteration limit'**
  String get iterationLimitLabel;

  /// No description provided for @iterationLimitValueLabel.
  ///
  /// In en, this message translates to:
  /// **'Current limit'**
  String get iterationLimitValueLabel;

  /// No description provided for @iterationLimitValue.
  ///
  /// In en, this message translates to:
  /// **'{count} iterations'**
  String iterationLimitValue(Object count);

  /// No description provided for @iterationLimitPrompt.
  ///
  /// In en, this message translates to:
  /// **'Reached the allowed tool iterations ({count}). Continue?'**
  String iterationLimitPrompt(Object count);

  /// No description provided for @iterationLimitContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get iterationLimitContinue;

  /// No description provided for @iterationLimitAbort.
  ///
  /// In en, this message translates to:
  /// **'Abort'**
  String get iterationLimitAbort;

  /// No description provided for @iterationLimitDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow more iterations'**
  String get iterationLimitDialogTitle;

  /// No description provided for @iterationLimitDialogDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter a value greater than {currentLimit} to extend this conversation\'s limit.'**
  String iterationLimitDialogDescription(Object currentLimit);

  /// No description provided for @iterationLimitInputLabel.
  ///
  /// In en, this message translates to:
  /// **'New maximum'**
  String get iterationLimitInputLabel;

  /// No description provided for @iterationLimitHelper.
  ///
  /// In en, this message translates to:
  /// **'Minimum allowed: {minLimit}'**
  String iterationLimitHelper(Object minLimit);

  /// No description provided for @iterationLimitDialogError.
  ///
  /// In en, this message translates to:
  /// **'Value must be greater than {minLimit}.'**
  String iterationLimitDialogError(Object minLimit);

  /// No description provided for @iterationLimitUpdated.
  ///
  /// In en, this message translates to:
  /// **'Iteration limit updated to {count}'**
  String iterationLimitUpdated(Object count);

  /// No description provided for @settingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved'**
  String get settingsSaved;

  /// No description provided for @agenticSettings.
  ///
  /// In en, this message translates to:
  /// **'Agentic Settings'**
  String get agenticSettings;

  /// No description provided for @agenticSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Configure agent mode parameters'**
  String get agenticSettingsSubtitle;

  /// No description provided for @compactionThreshold.
  ///
  /// In en, this message translates to:
  /// **'Compaction Threshold'**
  String get compactionThreshold;

  /// No description provided for @compactionThresholdDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum tokens before context compaction. Runtime uses min(this value, model\'s context window).'**
  String get compactionThresholdDescription;

  /// No description provided for @findingLimit.
  ///
  /// In en, this message translates to:
  /// **'Finding Limit'**
  String get findingLimit;

  /// No description provided for @findingLimitDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum number of findings to extract per task for synthesis.'**
  String get findingLimitDescription;

  /// No description provided for @findingMaxWords.
  ///
  /// In en, this message translates to:
  /// **'Finding Detail Words'**
  String get findingMaxWords;

  /// No description provided for @findingMaxWordsDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum words per finding\'s bullet point details.'**
  String get findingMaxWordsDescription;

  /// No description provided for @maxTurns.
  ///
  /// In en, this message translates to:
  /// **'Max Turns'**
  String get maxTurns;

  /// No description provided for @maxTurnsDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum number of iterations allowed per task.'**
  String get maxTurnsDescription;

  /// No description provided for @turnIncrement.
  ///
  /// In en, this message translates to:
  /// **'Turn Increment'**
  String get turnIncrement;

  /// No description provided for @turnIncrementDescription.
  ///
  /// In en, this message translates to:
  /// **'Number of turns to add when resuming a paused task.'**
  String get turnIncrementDescription;

  /// No description provided for @turnsValue.
  ///
  /// In en, this message translates to:
  /// **'{count} turns'**
  String turnsValue(Object count);

  /// No description provided for @maxSubtaskDepth.
  ///
  /// In en, this message translates to:
  /// **'Max Subtask Depth'**
  String get maxSubtaskDepth;

  /// No description provided for @maxSubtaskDepthDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum nesting depth for spawning subtasks. Set to 0 to disable spawning.'**
  String get maxSubtaskDepthDescription;

  /// No description provided for @aiLogEntriesLimit.
  ///
  /// In en, this message translates to:
  /// **'AI Log Entries Limit'**
  String get aiLogEntriesLimit;

  /// No description provided for @aiLogEntriesLimitDescription.
  ///
  /// In en, this message translates to:
  /// **'Maximum number of AI log entries to keep.'**
  String get aiLogEntriesLimitDescription;

  /// No description provided for @aiLogEntriesDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get aiLogEntriesDisabled;

  /// No description provided for @aiLogEntriesUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get aiLogEntriesUnlimited;

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

  /// No description provided for @checkIn.
  ///
  /// In en, this message translates to:
  /// **'Check-in'**
  String get checkIn;

  /// No description provided for @enterCheckInNote.
  ///
  /// In en, this message translates to:
  /// **'Enter check-in note'**
  String get enterCheckInNote;

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

  /// No description provided for @worldClip.
  ///
  /// In en, this message translates to:
  /// **'World Clip'**
  String get worldClip;

  /// No description provided for @worldClipSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Turn a video into a note'**
  String get worldClipSubtitle;

  /// No description provided for @worldClipProjects.
  ///
  /// In en, this message translates to:
  /// **'World Clip Projects'**
  String get worldClipProjects;

  /// No description provided for @worldClipImportVideo.
  ///
  /// In en, this message translates to:
  /// **'Import video'**
  String get worldClipImportVideo;

  /// No description provided for @worldClipImportPictures.
  ///
  /// In en, this message translates to:
  /// **'Import pictures'**
  String get worldClipImportPictures;

  /// No description provided for @worldClipScreenCapture.
  ///
  /// In en, this message translates to:
  /// **'Screen capture'**
  String get worldClipScreenCapture;

  /// No description provided for @worldClipScreenCaptureRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording your screen…'**
  String get worldClipScreenCaptureRecording;

  /// No description provided for @worldClipScreenCaptureHint.
  ///
  /// In en, this message translates to:
  /// **'Switch to the app you want to capture. When you\'re done, return here and tap Stop, or use the notification.'**
  String get worldClipScreenCaptureHint;

  /// No description provided for @worldClipScreenCaptureStop.
  ///
  /// In en, this message translates to:
  /// **'Stop & import'**
  String get worldClipScreenCaptureStop;

  /// No description provided for @worldClipNoFramesSelected.
  ///
  /// In en, this message translates to:
  /// **'Select at least one frame to continue'**
  String get worldClipNoFramesSelected;

  /// No description provided for @worldClipReview.
  ///
  /// In en, this message translates to:
  /// **'Review clips'**
  String get worldClipReview;

  /// No description provided for @worldClipCompile.
  ///
  /// In en, this message translates to:
  /// **'Create note'**
  String get worldClipCompile;

  /// No description provided for @worldClipOutputPdf.
  ///
  /// In en, this message translates to:
  /// **'As a PDF'**
  String get worldClipOutputPdf;

  /// No description provided for @worldClipOutputImages.
  ///
  /// In en, this message translates to:
  /// **'As inline images'**
  String get worldClipOutputImages;

  /// No description provided for @worldClipDeleteProject.
  ///
  /// In en, this message translates to:
  /// **'Delete project'**
  String get worldClipDeleteProject;

  /// No description provided for @worldClipNewFromSameVideo.
  ///
  /// In en, this message translates to:
  /// **'New project from this video'**
  String get worldClipNewFromSameVideo;

  /// No description provided for @worldClipEmptyProjects.
  ///
  /// In en, this message translates to:
  /// **'No saved World Clip projects'**
  String get worldClipEmptyProjects;

  /// No description provided for @worldClipColorAdjust.
  ///
  /// In en, this message translates to:
  /// **'Color adjustments'**
  String get worldClipColorAdjust;

  /// No description provided for @worldClipContrast.
  ///
  /// In en, this message translates to:
  /// **'Contrast'**
  String get worldClipContrast;

  /// No description provided for @worldClipSaturation.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get worldClipSaturation;

  /// No description provided for @worldClipTemperature.
  ///
  /// In en, this message translates to:
  /// **'Warmth'**
  String get worldClipTemperature;

  /// No description provided for @worldClipShapeTools.
  ///
  /// In en, this message translates to:
  /// **'Shape tools'**
  String get worldClipShapeTools;

  /// No description provided for @worldClipResetColor.
  ///
  /// In en, this message translates to:
  /// **'Reset colors'**
  String get worldClipResetColor;

  /// No description provided for @worldClipBrightness.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get worldClipBrightness;

  /// No description provided for @worldClipHighlights.
  ///
  /// In en, this message translates to:
  /// **'Highlights'**
  String get worldClipHighlights;

  /// No description provided for @worldClipShadows.
  ///
  /// In en, this message translates to:
  /// **'Shadows'**
  String get worldClipShadows;

  /// No description provided for @worldClipBlacks.
  ///
  /// In en, this message translates to:
  /// **'Blacks'**
  String get worldClipBlacks;

  /// No description provided for @worldClipWhites.
  ///
  /// In en, this message translates to:
  /// **'Whites'**
  String get worldClipWhites;

  /// No description provided for @worldClipCloneEditActions.
  ///
  /// In en, this message translates to:
  /// **'Clone edit actions'**
  String get worldClipCloneEditActions;

  /// No description provided for @worldClipSelectMultiple.
  ///
  /// In en, this message translates to:
  /// **'Select multiple'**
  String get worldClipSelectMultiple;

  /// No description provided for @worldClipDoneSelecting.
  ///
  /// In en, this message translates to:
  /// **'Done selecting'**
  String get worldClipDoneSelecting;

  /// No description provided for @worldClipNSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} selected'**
  String worldClipNSelected(int count);

  /// No description provided for @worldClipSelectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get worldClipSelectAll;

  /// No description provided for @worldClipDeselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect all'**
  String get worldClipDeselectAll;

  /// No description provided for @worldClipEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get worldClipEdit;

  /// No description provided for @worldClipCloneEdits.
  ///
  /// In en, this message translates to:
  /// **'Clone edits'**
  String get worldClipCloneEdits;

  /// No description provided for @worldClipCloneToSelected.
  ///
  /// In en, this message translates to:
  /// **'to {count} selected'**
  String worldClipCloneToSelected(int count);

  /// No description provided for @worldClipSelectPagesFirst.
  ///
  /// In en, this message translates to:
  /// **'select pages first'**
  String get worldClipSelectPagesFirst;

  /// No description provided for @worldClipDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get worldClipDelete;

  /// No description provided for @worldClipLevel.
  ///
  /// In en, this message translates to:
  /// **'Level'**
  String get worldClipLevel;

  /// No description provided for @worldClipRotateLeft.
  ///
  /// In en, this message translates to:
  /// **'Rotate left'**
  String get worldClipRotateLeft;

  /// No description provided for @worldClipRotateRight.
  ///
  /// In en, this message translates to:
  /// **'Rotate right'**
  String get worldClipRotateRight;

  /// No description provided for @worldClipAutoEdges.
  ///
  /// In en, this message translates to:
  /// **'Auto edges'**
  String get worldClipAutoEdges;

  /// No description provided for @worldClipAddHorizontalCrease.
  ///
  /// In en, this message translates to:
  /// **'Add horizontal crease'**
  String get worldClipAddHorizontalCrease;

  /// No description provided for @worldClipAddVerticalCrease.
  ///
  /// In en, this message translates to:
  /// **'Add vertical crease'**
  String get worldClipAddVerticalCrease;

  /// No description provided for @worldClipResetTool.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get worldClipResetTool;

  /// No description provided for @worldClipDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get worldClipDone;

  /// No description provided for @worldClipNoEdgesDetected.
  ///
  /// In en, this message translates to:
  /// **'No document edges detected'**
  String get worldClipNoEdgesDetected;

  /// No description provided for @worldClipNoFrames.
  ///
  /// In en, this message translates to:
  /// **'No frames'**
  String get worldClipNoFrames;

  /// No description provided for @worldClipSetKeyFrame.
  ///
  /// In en, this message translates to:
  /// **'Set key frame'**
  String get worldClipSetKeyFrame;

  /// No description provided for @worldClipRemoveKeyFrame.
  ///
  /// In en, this message translates to:
  /// **'Remove key frame'**
  String get worldClipRemoveKeyFrame;

  /// No description provided for @worldClipAutoButton.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get worldClipAutoButton;

  /// No description provided for @worldClipSuggestedKeyFrames.
  ///
  /// In en, this message translates to:
  /// **'Suggested {count} key frame(s)'**
  String worldClipSuggestedKeyFrames(int count);

  /// No description provided for @worldClipSuggestedKeyFramesScrolling.
  ///
  /// In en, this message translates to:
  /// **'Suggested {count} key frame(s) (scrolling capture)'**
  String worldClipSuggestedKeyFramesScrolling(int count);

  /// No description provided for @worldClipNoClearPages.
  ///
  /// In en, this message translates to:
  /// **'No clear pages found — try a slower pan'**
  String get worldClipNoClearPages;

  /// No description provided for @worldClipPreviousKeyFrame.
  ///
  /// In en, this message translates to:
  /// **'Previous key frame'**
  String get worldClipPreviousKeyFrame;

  /// No description provided for @worldClipNextKeyFrame.
  ///
  /// In en, this message translates to:
  /// **'Next key frame'**
  String get worldClipNextKeyFrame;

  /// No description provided for @worldClipPictureSequence.
  ///
  /// In en, this message translates to:
  /// **'Picture sequence'**
  String get worldClipPictureSequence;

  /// No description provided for @worldClipPsDone.
  ///
  /// In en, this message translates to:
  /// **'Done ({count})'**
  String worldClipPsDone(int count);

  /// No description provided for @worldClipPsAntiGlare.
  ///
  /// In en, this message translates to:
  /// **'Anti-glare'**
  String get worldClipPsAntiGlare;

  /// No description provided for @worldClipPsRetake.
  ///
  /// In en, this message translates to:
  /// **'Retake'**
  String get worldClipPsRetake;

  /// No description provided for @worldClipPsKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get worldClipPsKeep;

  /// No description provided for @worldClipPsRetakePage.
  ///
  /// In en, this message translates to:
  /// **'Retake this page'**
  String get worldClipPsRetakePage;

  /// No description provided for @worldClipPsDiscardPage.
  ///
  /// In en, this message translates to:
  /// **'Discard this page'**
  String get worldClipPsDiscardPage;

  /// No description provided for @worldClipPsDiscardTitle.
  ///
  /// In en, this message translates to:
  /// **'Discard sequence?'**
  String get worldClipPsDiscardTitle;

  /// No description provided for @worldClipPsDiscardBody.
  ///
  /// In en, this message translates to:
  /// **'This will discard {count} captured page(s).'**
  String worldClipPsDiscardBody(int count);

  /// No description provided for @worldClipPsDiscardShotsBody.
  ///
  /// In en, this message translates to:
  /// **'This will discard the shots taken for the current page.'**
  String get worldClipPsDiscardShotsBody;

  /// No description provided for @worldClipPsKeepEditing.
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get worldClipPsKeepEditing;

  /// No description provided for @worldClipPsDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get worldClipPsDiscard;

  /// No description provided for @worldClipPsCombining.
  ///
  /// In en, this message translates to:
  /// **'Combining shots…'**
  String get worldClipPsCombining;

  /// No description provided for @worldClipPsFuseFallback.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t combine those shots — used the first one'**
  String get worldClipPsFuseFallback;

  /// No description provided for @worldClipPsShotFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t take that shot: {error}'**
  String worldClipPsShotFailed(String error);

  /// No description provided for @worldClipPsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save that page: {error}'**
  String worldClipPsSaveFailed(String error);

  /// No description provided for @worldClipPsFlashFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change flash: {error}'**
  String worldClipPsFlashFailed(String error);

  /// No description provided for @worldClipPsCameraError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the camera'**
  String get worldClipPsCameraError;

  /// No description provided for @worldClipPsNoPages.
  ///
  /// In en, this message translates to:
  /// **'No pages yet'**
  String get worldClipPsNoPages;

  /// No description provided for @worldClipImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t import the pictures: {error}'**
  String worldClipImportFailed(String error);

  /// No description provided for @worldClipPicturesProjectName.
  ///
  /// In en, this message translates to:
  /// **'Pictures {date}'**
  String worldClipPicturesProjectName(String date);

  /// No description provided for @worldClipPsStepProgress.
  ///
  /// In en, this message translates to:
  /// **'{label} ({current}/{total})'**
  String worldClipPsStepProgress(String label, int current, int total);

  /// No description provided for @worldClipAgLabelCenter.
  ///
  /// In en, this message translates to:
  /// **'Center'**
  String get worldClipAgLabelCenter;

  /// No description provided for @worldClipAgLabelTopLeft.
  ///
  /// In en, this message translates to:
  /// **'Top-left'**
  String get worldClipAgLabelTopLeft;

  /// No description provided for @worldClipAgLabelTopRight.
  ///
  /// In en, this message translates to:
  /// **'Top-right'**
  String get worldClipAgLabelTopRight;

  /// No description provided for @worldClipAgLabelBottomLeft.
  ///
  /// In en, this message translates to:
  /// **'Bottom-left'**
  String get worldClipAgLabelBottomLeft;

  /// No description provided for @worldClipAgLabelBottomRight.
  ///
  /// In en, this message translates to:
  /// **'Bottom-right'**
  String get worldClipAgLabelBottomRight;

  /// No description provided for @worldClipAgInstructionCenter.
  ///
  /// In en, this message translates to:
  /// **'Hold the camera centered and level over the page'**
  String get worldClipAgInstructionCenter;

  /// No description provided for @worldClipAgInstructionTopLeft.
  ///
  /// In en, this message translates to:
  /// **'Move the camera — shift your hand, not just your wrist — toward the TOP-LEFT of the page, keeping the whole page in frame'**
  String get worldClipAgInstructionTopLeft;

  /// No description provided for @worldClipAgInstructionTopRight.
  ///
  /// In en, this message translates to:
  /// **'Now move toward the TOP-RIGHT of the page, keeping it all in frame'**
  String get worldClipAgInstructionTopRight;

  /// No description provided for @worldClipAgInstructionBottomLeft.
  ///
  /// In en, this message translates to:
  /// **'Now move toward the BOTTOM-LEFT of the page, keeping it all in frame'**
  String get worldClipAgInstructionBottomLeft;

  /// No description provided for @worldClipAgInstructionBottomRight.
  ///
  /// In en, this message translates to:
  /// **'Now move toward the BOTTOM-RIGHT of the page, keeping it all in frame'**
  String get worldClipAgInstructionBottomRight;

  /// No description provided for @worldClipAnalyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing {current}/{total}'**
  String worldClipAnalyzing(int current, int total);

  /// No description provided for @worldClipClonedEdits.
  ///
  /// In en, this message translates to:
  /// **'Cloned edits to {count} page(s)'**
  String worldClipClonedEdits(int count);

  /// No description provided for @worldClipAutoDetecting.
  ///
  /// In en, this message translates to:
  /// **'Auto-detecting {current}/{total}'**
  String worldClipAutoDetecting(int current, int total);

  /// No description provided for @worldClipAutoEdited.
  ///
  /// In en, this message translates to:
  /// **'Auto-edited {count} page(s)'**
  String worldClipAutoEdited(int count);

  /// No description provided for @worldClipClipsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} clips'**
  String worldClipClipsCount(int count);

  /// No description provided for @worldClipSkippedRawImages.
  ///
  /// In en, this message translates to:
  /// **'Skipped {count} RAW image(s) — RAW is not supported'**
  String worldClipSkippedRawImages(int count);

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

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @systemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'System behavior settings'**
  String get systemSubtitle;

  /// No description provided for @keepScreenOn.
  ///
  /// In en, this message translates to:
  /// **'Keep Screen On'**
  String get keepScreenOn;

  /// No description provided for @keepScreenOnSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Prevent screen from turning off automatically'**
  String get keepScreenOnSubtitle;

  /// No description provided for @network.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get network;

  /// No description provided for @networkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'HTTP protocol and retry settings'**
  String get networkSubtitle;

  /// No description provided for @protocolPreference.
  ///
  /// In en, this message translates to:
  /// **'Protocol Preference'**
  String get protocolPreference;

  /// No description provided for @protocolPreferenceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose HTTP protocol mode for network requests'**
  String get protocolPreferenceSubtitle;

  /// No description provided for @protocolAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto (Upgrade to HTTP/3)'**
  String get protocolAuto;

  /// No description provided for @protocolHttp3Only.
  ///
  /// In en, this message translates to:
  /// **'HTTP/3 Only'**
  String get protocolHttp3Only;

  /// No description provided for @protocolHttp11Only.
  ///
  /// In en, this message translates to:
  /// **'HTTP/1.1 Only'**
  String get protocolHttp11Only;

  /// No description provided for @retryCount.
  ///
  /// In en, this message translates to:
  /// **'Retry Count'**
  String get retryCount;

  /// No description provided for @retryCountSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Number of retry attempts for failed requests (0-5)'**
  String get retryCountSubtitle;

  /// No description provided for @backoffBase.
  ///
  /// In en, this message translates to:
  /// **'Backoff Base'**
  String get backoffBase;

  /// No description provided for @backoffBaseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Base delay for exponential backoff in seconds (1-10)'**
  String get backoffBaseSubtitle;

  /// No description provided for @retryPattern.
  ///
  /// In en, this message translates to:
  /// **'Retry delays: {base}s → {second}s → {third}s'**
  String retryPattern(String base, String second, String third);

  /// No description provided for @networkSettingsUpdated.
  ///
  /// In en, this message translates to:
  /// **'Network settings updated'**
  String get networkSettingsUpdated;

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
  /// **'Search notes'**
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

  /// No description provided for @searchInProgress.
  ///
  /// In en, this message translates to:
  /// **'Searching…'**
  String get searchInProgress;

  /// No description provided for @searchTryAdjustingTerms.
  ///
  /// In en, this message translates to:
  /// **'Try adjusting your search terms'**
  String get searchTryAdjustingTerms;

  /// No description provided for @searchTryDifferentTags.
  ///
  /// In en, this message translates to:
  /// **'Try selecting different tags'**
  String get searchTryDifferentTags;

  /// No description provided for @createFirstNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Tap the + button to create your first note'**
  String get createFirstNoteHint;

  /// No description provided for @buildingSearchIndex.
  ///
  /// In en, this message translates to:
  /// **'Building search index… {percent}%'**
  String buildingSearchIndex(int percent);

  /// No description provided for @searchBadgePdfPage.
  ///
  /// In en, this message translates to:
  /// **'PDF · p.{page}'**
  String searchBadgePdfPage(int page);

  /// No description provided for @searchBadgeAttachment.
  ///
  /// In en, this message translates to:
  /// **'Attachment'**
  String get searchBadgeAttachment;

  /// No description provided for @searchBadgeImage.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get searchBadgeImage;

  /// No description provided for @searchBadgeSubnote.
  ///
  /// In en, this message translates to:
  /// **'Sub-note'**
  String get searchBadgeSubnote;

  /// No description provided for @searchBadgeTag.
  ///
  /// In en, this message translates to:
  /// **'Tag'**
  String get searchBadgeTag;

  /// No description provided for @searchBadgeAnnotation.
  ///
  /// In en, this message translates to:
  /// **'Annotation'**
  String get searchBadgeAnnotation;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

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

  /// No description provided for @transformNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Describe how you want to transform this note...'**
  String get transformNoteHint;

  /// No description provided for @createNewNotesHint.
  ///
  /// In en, this message translates to:
  /// **'Describe what new notes you want to create...'**
  String get createNewNotesHint;

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

  /// No description provided for @attachFile.
  ///
  /// In en, this message translates to:
  /// **'Attach File'**
  String get attachFile;

  /// No description provided for @selectFromDevice.
  ///
  /// In en, this message translates to:
  /// **'Select from Device'**
  String get selectFromDevice;

  /// No description provided for @enterUri.
  ///
  /// In en, this message translates to:
  /// **'Enter URI'**
  String get enterUri;

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

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @processingRequest.
  ///
  /// In en, this message translates to:
  /// **'Processing your request...'**
  String get processingRequest;

  /// No description provided for @executingToolStatus.
  ///
  /// In en, this message translates to:
  /// **'Executing tool: {service} -> {tool}'**
  String executingToolStatus(Object service, Object tool);

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

  /// No description provided for @convertToNote.
  ///
  /// In en, this message translates to:
  /// **'Convert to Note'**
  String get convertToNote;

  /// No description provided for @convertToTask.
  ///
  /// In en, this message translates to:
  /// **'Convert to Task'**
  String get convertToTask;

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

  /// No description provided for @insertAttachmentLink.
  ///
  /// In en, this message translates to:
  /// **'Insert Attachment Link'**
  String get insertAttachmentLink;

  /// No description provided for @insertToolLink.
  ///
  /// In en, this message translates to:
  /// **'Insert Tool Link'**
  String get insertToolLink;

  /// No description provided for @selectAttachment.
  ///
  /// In en, this message translates to:
  /// **'Select Attachment'**
  String get selectAttachment;

  /// No description provided for @selectLocation.
  ///
  /// In en, this message translates to:
  /// **'Select Location'**
  String get selectLocation;

  /// No description provided for @noAttachments.
  ///
  /// In en, this message translates to:
  /// **'No attachments'**
  String get noAttachments;

  /// No description provided for @linkText.
  ///
  /// In en, this message translates to:
  /// **'Link Text'**
  String get linkText;

  /// No description provided for @pageN.
  ///
  /// In en, this message translates to:
  /// **'Page {n}'**
  String pageN(int n);

  /// No description provided for @noSpecificPage.
  ///
  /// In en, this message translates to:
  /// **'No specific page'**
  String get noSpecificPage;

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

  /// No description provided for @shareAsPdf.
  ///
  /// In en, this message translates to:
  /// **'Share as PDF'**
  String get shareAsPdf;

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

  /// No description provided for @notesToShare.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{Note} other{Notes}} to share'**
  String notesToShare(int count);

  /// No description provided for @textCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Text copied to clipboard'**
  String get textCopiedToClipboard;

  /// No description provided for @errorCopyingToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Error copying to clipboard: {error}'**
  String errorCopyingToClipboard(String error);

  /// No description provided for @errorSharingText.
  ///
  /// In en, this message translates to:
  /// **'Error sharing text: {error}'**
  String errorSharingText(String error);

  /// No description provided for @pdfSavedToCache.
  ///
  /// In en, this message translates to:
  /// **'PDF saved to cache: {fileName}'**
  String pdfSavedToCache(String fileName);

  /// No description provided for @errorGeneratingPdf.
  ///
  /// In en, this message translates to:
  /// **'Error generating PDF: {error}'**
  String errorGeneratingPdf(String error);

  /// No description provided for @attachmentMissing.
  ///
  /// In en, this message translates to:
  /// **'Attachment not found.'**
  String get attachmentMissing;

  /// No description provided for @attachmentUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Attachment unavailable'**
  String get attachmentUnavailable;

  /// No description provided for @pdfPreviewUnavailable.
  ///
  /// In en, this message translates to:
  /// **'PDF preview not available. Use the saved attachment to view.'**
  String get pdfPreviewUnavailable;

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

  /// No description provided for @addTags.
  ///
  /// In en, this message translates to:
  /// **'Add tags'**
  String get addTags;

  /// No description provided for @filterTags.
  ///
  /// In en, this message translates to:
  /// **'Filter tags'**
  String get filterTags;

  /// No description provided for @filterTagsDialog.
  ///
  /// In en, this message translates to:
  /// **'Filter Tags'**
  String get filterTagsDialog;

  /// No description provided for @filterTagsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{tag} other{tags}}'**
  String filterTagsCount(int count);

  /// No description provided for @clearFilters.
  ///
  /// In en, this message translates to:
  /// **'Clear Filters'**
  String get clearFilters;

  /// No description provided for @applyFilters.
  ///
  /// In en, this message translates to:
  /// **'Apply Filters'**
  String get applyFilters;

  /// No description provided for @clearTags.
  ///
  /// In en, this message translates to:
  /// **'Clear Tags'**
  String get clearTags;

  /// No description provided for @applyTagsWithCount.
  ///
  /// In en, this message translates to:
  /// **'Apply {count} {count, plural, =1{Tag} other{Tags}}'**
  String applyTagsWithCount(int count);

  /// No description provided for @addTagsCapitalized.
  ///
  /// In en, this message translates to:
  /// **'Add Tags'**
  String get addTagsCapitalized;

  /// No description provided for @addTagsWithCount.
  ///
  /// In en, this message translates to:
  /// **'Add {count} {count, plural, =1{Tag} other{Tags}}'**
  String addTagsWithCount(int count);

  /// No description provided for @searchTags.
  ///
  /// In en, this message translates to:
  /// **'Search tags'**
  String get searchTags;

  /// No description provided for @searchTagsToFilter.
  ///
  /// In en, this message translates to:
  /// **'Search tags to filter'**
  String get searchTagsToFilter;

  /// No description provided for @searchTagsCapitalized.
  ///
  /// In en, this message translates to:
  /// **'Search Tags'**
  String get searchTagsCapitalized;

  /// No description provided for @addNewTagOrSearch.
  ///
  /// In en, this message translates to:
  /// **'Add new tag or search'**
  String get addNewTagOrSearch;

  /// No description provided for @tagManagement.
  ///
  /// In en, this message translates to:
  /// **'Tag Management'**
  String get tagManagement;

  /// No description provided for @tagUsageCount.
  ///
  /// In en, this message translates to:
  /// **'{noteCount} notes / {conversationCount} conversations'**
  String tagUsageCount(Object conversationCount, Object noteCount);

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
  /// **'This will remove the tag from {noteCount} notes and {conversationCount} conversations. This action cannot be undone.'**
  String confirmDeleteTagWarning(Object conversationCount, Object noteCount);

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

  /// No description provided for @workflows.
  ///
  /// In en, this message translates to:
  /// **'Workflows'**
  String get workflows;

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

  /// No description provided for @searchApps.
  ///
  /// In en, this message translates to:
  /// **'Search apps...'**
  String get searchApps;

  /// No description provided for @noAppsFound.
  ///
  /// In en, this message translates to:
  /// **'No apps found'**
  String get noAppsFound;

  /// No description provided for @tryAdjustingSearchTerms.
  ///
  /// In en, this message translates to:
  /// **'Try adjusting your search terms'**
  String get tryAdjustingSearchTerms;

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

  /// No description provided for @manageAppState.
  ///
  /// In en, this message translates to:
  /// **'Manage App State'**
  String get manageAppState;

  /// No description provided for @clearState.
  ///
  /// In en, this message translates to:
  /// **'Clear State'**
  String get clearState;

  /// No description provided for @stateCleared.
  ///
  /// In en, this message translates to:
  /// **'State cleared successfully!'**
  String get stateCleared;

  /// No description provided for @noState.
  ///
  /// In en, this message translates to:
  /// **'No state'**
  String get noState;

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
  /// **'AI Debug Log'**
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

  /// No description provided for @aiLogs.
  ///
  /// In en, this message translates to:
  /// **'AI Logs'**
  String get aiLogs;

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
  /// **'AI Settings'**
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

  /// No description provided for @supportedAttachmentMimeTypesLabel.
  ///
  /// In en, this message translates to:
  /// **'Supported attachment MIME types'**
  String get supportedAttachmentMimeTypesLabel;

  /// No description provided for @supportedAttachmentMimeTypesHint.
  ///
  /// In en, this message translates to:
  /// **'image/png, application/pdf'**
  String get supportedAttachmentMimeTypesHint;

  /// No description provided for @supportedAttachmentMimeTypesHelper.
  ///
  /// In en, this message translates to:
  /// **'Comma or newline separated. Leave empty to use the model preset.'**
  String get supportedAttachmentMimeTypesHelper;

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

  /// No description provided for @promptSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Prompt Configuration'**
  String get promptSettingsTitle;

  /// No description provided for @promptSettingsDescription.
  ///
  /// In en, this message translates to:
  /// **'Customize how Note Synapse composes prompts. Empty fields use the default instructions.'**
  String get promptSettingsDescription;

  /// No description provided for @promptSettingsSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get promptSettingsSave;

  /// No description provided for @promptSettingsReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get promptSettingsReset;

  /// No description provided for @promptSettingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved prompt for {entryTitle}'**
  String promptSettingsSaved(String entryTitle);

  /// No description provided for @promptSettingsCleared.
  ///
  /// In en, this message translates to:
  /// **'Cleared prompt for {entryTitle}'**
  String promptSettingsCleared(String entryTitle);

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

  /// No description provided for @builtInTools.
  ///
  /// In en, this message translates to:
  /// **'Built-in Tools'**
  String get builtInTools;

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

  /// No description provided for @onboardingWelcomeTitle.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Note Synapse'**
  String get onboardingWelcomeTitle;

  /// No description provided for @onboardingWelcomeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Your AI second brain'**
  String get onboardingWelcomeSubtitle;

  /// No description provided for @onboardingChooseModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose Your AI Model'**
  String get onboardingChooseModelTitle;

  /// No description provided for @onboardingChooseModelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Select the AI model that best fits your needs'**
  String get onboardingChooseModelSubtitle;

  /// No description provided for @onboardingStart.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get onboardingStart;

  /// No description provided for @onboardingNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get onboardingNext;

  /// No description provided for @onboardingSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get onboardingSkip;

  /// No description provided for @onboardingLicenseTitle.
  ///
  /// In en, this message translates to:
  /// **'License Agreement'**
  String get onboardingLicenseTitle;

  /// No description provided for @onboardingLicenseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Please read and accept the license'**
  String get onboardingLicenseSubtitle;

  /// No description provided for @onboardingPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get onboardingPrivacyTitle;

  /// No description provided for @onboardingPrivacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'How we handle your data'**
  String get onboardingPrivacySubtitle;

  /// No description provided for @onboardingAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept & Continue'**
  String get onboardingAccept;

  /// No description provided for @onboardingConfigLater.
  ///
  /// In en, this message translates to:
  /// **'Config Later'**
  String get onboardingConfigLater;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @aboutSubtitle.
  ///
  /// In en, this message translates to:
  /// **'License, privacy, and version'**
  String get aboutSubtitle;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @info.
  ///
  /// In en, this message translates to:
  /// **'Info'**
  String get info;

  /// No description provided for @applicationInfo.
  ///
  /// In en, this message translates to:
  /// **'Application Information'**
  String get applicationInfo;

  /// No description provided for @githubPage.
  ///
  /// In en, this message translates to:
  /// **'GitHub Page'**
  String get githubPage;

  /// No description provided for @viewLicense.
  ///
  /// In en, this message translates to:
  /// **'View License'**
  String get viewLicense;

  /// No description provided for @viewPrivacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'View Privacy Policy'**
  String get viewPrivacyPolicy;

  /// No description provided for @stowplexCopyright.
  ///
  /// In en, this message translates to:
  /// **'Stowplex LLC & Bruce Li All Rights Reserved'**
  String get stowplexCopyright;

  /// No description provided for @noWarranty.
  ///
  /// In en, this message translates to:
  /// **'NO WARRANTY'**
  String get noWarranty;

  /// No description provided for @debugMenu.
  ///
  /// In en, this message translates to:
  /// **'Debug Menu'**
  String get debugMenu;

  /// No description provided for @debugMenuSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Developer options'**
  String get debugMenuSubtitle;

  /// No description provided for @resetOnboarding.
  ///
  /// In en, this message translates to:
  /// **'Reset Onboarding Flag'**
  String get resetOnboarding;

  /// No description provided for @resetOnboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset Onboarding Flag'**
  String get resetOnboardingTitle;

  /// No description provided for @resetOnboardingSuccess.
  ///
  /// In en, this message translates to:
  /// **'Onboarding flag reset'**
  String get resetOnboardingSuccess;

  /// No description provided for @dependencyLicenses.
  ///
  /// In en, this message translates to:
  /// **'Dependency Library Licenses'**
  String get dependencyLicenses;

  /// No description provided for @refreshedToolsFor.
  ///
  /// In en, this message translates to:
  /// **'Refreshed tools for {name}'**
  String refreshedToolsFor(Object name);

  /// No description provided for @bookmarkPage.
  ///
  /// In en, this message translates to:
  /// **'Bookmark Page'**
  String get bookmarkPage;

  /// No description provided for @page.
  ///
  /// In en, this message translates to:
  /// **'Page'**
  String get page;

  /// No description provided for @removeBookmark.
  ///
  /// In en, this message translates to:
  /// **'Remove Bookmark'**
  String get removeBookmark;

  /// No description provided for @bookmarks.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get bookmarks;

  /// No description provided for @addBookmark.
  ///
  /// In en, this message translates to:
  /// **'Add Bookmark'**
  String get addBookmark;

  /// No description provided for @editBookmark.
  ///
  /// In en, this message translates to:
  /// **'Edit Bookmark'**
  String get editBookmark;

  /// No description provided for @bookmarkAnnotationHint.
  ///
  /// In en, this message translates to:
  /// **'Enter annotation (max 200 chars)'**
  String get bookmarkAnnotationHint;

  /// No description provided for @noBookmarksYet.
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet'**
  String get noBookmarksYet;

  /// No description provided for @aiContextBookmarks.
  ///
  /// In en, this message translates to:
  /// **'AI Context: Bookmarks'**
  String get aiContextBookmarks;

  /// No description provided for @configureAiContext.
  ///
  /// In en, this message translates to:
  /// **'Configure AI Context'**
  String get configureAiContext;

  /// No description provided for @configureAiContextDescription.
  ///
  /// In en, this message translates to:
  /// **'Select which pages to include when AI processes this PDF:'**
  String get configureAiContextDescription;

  /// No description provided for @includeInAiContext.
  ///
  /// In en, this message translates to:
  /// **'Include in AI Context'**
  String get includeInAiContext;

  /// No description provided for @configureAiContextRange.
  ///
  /// In en, this message translates to:
  /// **'Configure AI Context Range'**
  String get configureAiContextRange;

  /// No description provided for @editAiContextRange.
  ///
  /// In en, this message translates to:
  /// **'Edit AI Context Range'**
  String get editAiContextRange;

  /// No description provided for @aiContext.
  ///
  /// In en, this message translates to:
  /// **'AI Context: {mode}'**
  String aiContext(String mode);

  /// No description provided for @aiContextFullPdf.
  ///
  /// In en, this message translates to:
  /// **'Full PDF'**
  String get aiContextFullPdf;

  /// No description provided for @aiContextWindow.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get aiContextWindow;

  /// No description provided for @aiContextChapters.
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get aiContextChapters;

  /// No description provided for @aiContextAllDocument.
  ///
  /// In en, this message translates to:
  /// **'All Document'**
  String get aiContextAllDocument;

  /// No description provided for @aiContextPagesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{page} other{pages}}'**
  String aiContextPagesCount(int count);

  /// No description provided for @aiContextWindowAroundCurrentPage.
  ///
  /// In en, this message translates to:
  /// **'Window Around Current Page'**
  String get aiContextWindowAroundCurrentPage;

  /// No description provided for @aiContextPagesCenteredOnReading.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{page} other{pages}} centered on where you are reading'**
  String aiContextPagesCenteredOnReading(int count);

  /// No description provided for @aiContextBookmarksAvailable.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{bookmark} other{bookmarks}} available'**
  String aiContextBookmarksAvailable(int count);

  /// No description provided for @aiContextPageNumber.
  ///
  /// In en, this message translates to:
  /// **'Page {pageNumber}'**
  String aiContextPageNumber(int pageNumber);

  /// No description provided for @aiContextSelectedChapters.
  ///
  /// In en, this message translates to:
  /// **'Selected Chapters'**
  String get aiContextSelectedChapters;

  /// No description provided for @aiContextChooseSpecificSections.
  ///
  /// In en, this message translates to:
  /// **'Choose specific sections'**
  String get aiContextChooseSpecificSections;

  /// No description provided for @aiContextChaptersSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{chapter} other{chapters}} selected'**
  String aiContextChaptersSelected(int count);

  /// No description provided for @aiContextPdfNoOutline.
  ///
  /// In en, this message translates to:
  /// **'This PDF has no outline'**
  String get aiContextPdfNoOutline;

  /// No description provided for @aiContextConfigurationSaved.
  ///
  /// In en, this message translates to:
  /// **'AI context configuration saved'**
  String get aiContextConfigurationSaved;

  /// No description provided for @windowSize.
  ///
  /// In en, this message translates to:
  /// **'Window Size'**
  String get windowSize;

  /// No description provided for @pages.
  ///
  /// In en, this message translates to:
  /// **'Pages'**
  String get pages;

  /// No description provided for @pagesBeforeAfter.
  ///
  /// In en, this message translates to:
  /// **'Pages before/after'**
  String get pagesBeforeAfter;

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

  /// No description provided for @markAllAs.
  ///
  /// In en, this message translates to:
  /// **'Mark all as'**
  String get markAllAs;

  /// No description provided for @archiveAll.
  ///
  /// In en, this message translates to:
  /// **'Archive All'**
  String get archiveAll;

  /// No description provided for @unarchiveAll.
  ///
  /// In en, this message translates to:
  /// **'Unarchive All'**
  String get unarchiveAll;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// No description provided for @deselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect All'**
  String get deselectAll;

  /// No description provided for @noteType.
  ///
  /// In en, this message translates to:
  /// **'Note Type'**
  String get noteType;

  /// No description provided for @excludeTags.
  ///
  /// In en, this message translates to:
  /// **'Exclude Tags'**
  String get excludeTags;

  /// No description provided for @excludeTagsHint.
  ///
  /// In en, this message translates to:
  /// **'Select tags to exclude'**
  String get excludeTagsHint;

  /// No description provided for @selectTagsToExclude.
  ///
  /// In en, this message translates to:
  /// **'Select Tags to Exclude'**
  String get selectTagsToExclude;

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

  /// No description provided for @multiFunction.
  ///
  /// In en, this message translates to:
  /// **'Multi-function'**
  String get multiFunction;

  /// No description provided for @addToMultiFunction.
  ///
  /// In en, this message translates to:
  /// **'Add to multi-function tab'**
  String get addToMultiFunction;

  /// No description provided for @removeFromMultiFunction.
  ///
  /// In en, this message translates to:
  /// **'Remove from multi-function view'**
  String get removeFromMultiFunction;

  /// No description provided for @setAsDefaultView.
  ///
  /// In en, this message translates to:
  /// **'Set as default view'**
  String get setAsDefaultView;

  /// No description provided for @defaultView.
  ///
  /// In en, this message translates to:
  /// **'Default View'**
  String get defaultView;

  /// No description provided for @appAddedToMultiFunction.
  ///
  /// In en, this message translates to:
  /// **'App added to multi-function tab'**
  String get appAddedToMultiFunction;

  /// No description provided for @appRemovedFromMultiFunction.
  ///
  /// In en, this message translates to:
  /// **'App removed from multi-function tab'**
  String get appRemovedFromMultiFunction;

  /// No description provided for @defaultViewUpdated.
  ///
  /// In en, this message translates to:
  /// **'Default view updated'**
  String get defaultViewUpdated;

  /// No description provided for @selectView.
  ///
  /// In en, this message translates to:
  /// **'Select View'**
  String get selectView;

  /// No description provided for @switchToCalendar.
  ///
  /// In en, this message translates to:
  /// **'Switch to Calendar'**
  String get switchToCalendar;

  /// No description provided for @rawDataManager.
  ///
  /// In en, this message translates to:
  /// **'Raw Data Manager'**
  String get rawDataManager;

  /// No description provided for @rawDataManagerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Inspect and modify raw database data'**
  String get rawDataManagerSubtitle;

  /// No description provided for @files.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get files;

  /// No description provided for @database.
  ///
  /// In en, this message translates to:
  /// **'Database'**
  String get database;

  /// No description provided for @tables.
  ///
  /// In en, this message translates to:
  /// **'Tables'**
  String get tables;

  /// No description provided for @query.
  ///
  /// In en, this message translates to:
  /// **'Query'**
  String get query;

  /// No description provided for @executeQuery.
  ///
  /// In en, this message translates to:
  /// **'Execute Query'**
  String get executeQuery;

  /// No description provided for @noData.
  ///
  /// In en, this message translates to:
  /// **'No data'**
  String get noData;

  /// No description provided for @rowsAffected.
  ///
  /// In en, this message translates to:
  /// **'{count} rows affected'**
  String rowsAffected(Object count);

  /// No description provided for @errorExecutingQuery.
  ///
  /// In en, this message translates to:
  /// **'Error executing query: {error}'**
  String errorExecutingQuery(Object error);

  /// No description provided for @tableSchema.
  ///
  /// In en, this message translates to:
  /// **'Table Schema'**
  String get tableSchema;

  /// No description provided for @columns.
  ///
  /// In en, this message translates to:
  /// **'Columns'**
  String get columns;

  /// No description provided for @indexes.
  ///
  /// In en, this message translates to:
  /// **'Indexes'**
  String get indexes;

  /// No description provided for @foreignKeys.
  ///
  /// In en, this message translates to:
  /// **'Foreign Keys'**
  String get foreignKeys;

  /// No description provided for @browseTable.
  ///
  /// In en, this message translates to:
  /// **'Browse Table'**
  String get browseTable;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @download.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get download;

  /// No description provided for @deleteFile.
  ///
  /// In en, this message translates to:
  /// **'Delete File'**
  String get deleteFile;

  /// No description provided for @confirmDeleteFile.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{fileName}\"?'**
  String confirmDeleteFile(Object fileName);

  /// No description provided for @fileDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'File deleted successfully'**
  String get fileDeletedSuccessfully;

  /// No description provided for @errorDeletingFile.
  ///
  /// In en, this message translates to:
  /// **'Error deleting file: {error}'**
  String errorDeletingFile(Object error);

  /// No description provided for @uploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload File'**
  String get uploadFile;

  /// No description provided for @fileUploadedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'File uploaded successfully'**
  String get fileUploadedSuccessfully;

  /// No description provided for @errorUploadingFile.
  ///
  /// In en, this message translates to:
  /// **'Error uploading file: {error}'**
  String errorUploadingFile(Object error);

  /// No description provided for @createDirectory.
  ///
  /// In en, this message translates to:
  /// **'Create Directory'**
  String get createDirectory;

  /// No description provided for @directoryName.
  ///
  /// In en, this message translates to:
  /// **'Directory Name'**
  String get directoryName;

  /// No description provided for @directoryCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Directory created successfully'**
  String get directoryCreatedSuccessfully;

  /// No description provided for @errorCreatingDirectory.
  ///
  /// In en, this message translates to:
  /// **'Error creating directory: {error}'**
  String errorCreatingDirectory(Object error);

  /// No description provided for @path.
  ///
  /// In en, this message translates to:
  /// **'Path'**
  String get path;

  /// No description provided for @size.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get size;

  /// No description provided for @modified.
  ///
  /// In en, this message translates to:
  /// **'Modified'**
  String get modified;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @chatWithDatabase.
  ///
  /// In en, this message translates to:
  /// **'Chat with Database'**
  String get chatWithDatabase;

  /// No description provided for @askQuestionAboutDatabase.
  ///
  /// In en, this message translates to:
  /// **'Ask a question about your database...'**
  String get askQuestionAboutDatabase;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @aiResponse.
  ///
  /// In en, this message translates to:
  /// **'AI Response'**
  String get aiResponse;

  /// No description provided for @errorSendingMessage.
  ///
  /// In en, this message translates to:
  /// **'Error sending message: {error}'**
  String errorSendingMessage(Object error);

  /// No description provided for @thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking...'**
  String get thinking;

  /// No description provided for @noToolsCachedFor.
  ///
  /// In en, this message translates to:
  /// **'No tools cached for {name}. Click refresh to fetch tools.'**
  String noToolsCachedFor(Object name);

  /// No description provided for @addContextNotes.
  ///
  /// In en, this message translates to:
  /// **'Add Context Notes'**
  String get addContextNotes;

  /// No description provided for @libraries.
  ///
  /// In en, this message translates to:
  /// **'Libraries'**
  String get libraries;

  /// No description provided for @noLibraries.
  ///
  /// In en, this message translates to:
  /// **'No libraries'**
  String get noLibraries;

  /// No description provided for @usageInstructions.
  ///
  /// In en, this message translates to:
  /// **'Usage Instructions'**
  String get usageInstructions;

  /// No description provided for @libraryLinks.
  ///
  /// In en, this message translates to:
  /// **'Library Links'**
  String get libraryLinks;

  /// No description provided for @editUserApp.
  ///
  /// In en, this message translates to:
  /// **'Edit App'**
  String get editUserApp;

  /// No description provided for @viewCode.
  ///
  /// In en, this message translates to:
  /// **'View Code'**
  String get viewCode;

  /// No description provided for @editCode.
  ///
  /// In en, this message translates to:
  /// **'Edit Code'**
  String get editCode;

  /// No description provided for @code.
  ///
  /// In en, this message translates to:
  /// **'Code'**
  String get code;

  /// No description provided for @aiEdit.
  ///
  /// In en, this message translates to:
  /// **'AI Edit'**
  String get aiEdit;

  /// No description provided for @aiEditPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'AI Edit Block'**
  String get aiEditPromptTitle;

  /// No description provided for @aiEditPromptHint.
  ///
  /// In en, this message translates to:
  /// **'Describe how to transform this block...'**
  String get aiEditPromptHint;

  /// No description provided for @aiEditDiffTitle.
  ///
  /// In en, this message translates to:
  /// **'Review Changes'**
  String get aiEditDiffTitle;

  /// No description provided for @aiEditAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get aiEditAccept;

  /// No description provided for @aiEditReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get aiEditReject;

  /// No description provided for @pleaseEnterSuggestion.
  ///
  /// In en, this message translates to:
  /// **'Please enter a suggestion'**
  String get pleaseEnterSuggestion;

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

  /// No description provided for @noteActionApps.
  ///
  /// In en, this message translates to:
  /// **'Note Action Apps'**
  String get noteActionApps;

  /// No description provided for @noteActionAppSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This type of app will operate specifically on pre-selected notes'**
  String get noteActionAppSubtitle;

  /// No description provided for @appType.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get appType;

  /// No description provided for @appTypeHint.
  ///
  /// In en, this message translates to:
  /// **'Select how this app should behave'**
  String get appTypeHint;

  /// No description provided for @appTypeNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get appTypeNormal;

  /// No description provided for @appTypeNoteAction.
  ///
  /// In en, this message translates to:
  /// **'Note Action'**
  String get appTypeNoteAction;

  /// No description provided for @appTypeAiTool.
  ///
  /// In en, this message translates to:
  /// **'AI Tool'**
  String get appTypeAiTool;

  /// No description provided for @aiToolAppSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Expose custom JavaScript functions that the AI can call or you can test in a playground'**
  String get aiToolAppSubtitle;

  /// No description provided for @aiTools.
  ///
  /// In en, this message translates to:
  /// **'AI Tools'**
  String get aiTools;

  /// No description provided for @modelFeatures.
  ///
  /// In en, this message translates to:
  /// **'Model Features'**
  String get modelFeatures;

  /// No description provided for @featureGoogleSearch.
  ///
  /// In en, this message translates to:
  /// **'Google Search'**
  String get featureGoogleSearch;

  /// No description provided for @featureCodeExecution.
  ///
  /// In en, this message translates to:
  /// **'Code Execution'**
  String get featureCodeExecution;

  /// No description provided for @featureWebSearch.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get featureWebSearch;

  /// No description provided for @aiToolStartError.
  ///
  /// In en, this message translates to:
  /// **'Failed to start AI tool \"{appName}\": {error}'**
  String aiToolStartError(String appName, String error);

  /// No description provided for @aiToolMissingRevision.
  ///
  /// In en, this message translates to:
  /// **'This AI tool does not have a selected revision yet.'**
  String get aiToolMissingRevision;

  /// No description provided for @aiToolDefinitionParseError.
  ///
  /// In en, this message translates to:
  /// **'The selected revision does not contain a valid AI tool specification.'**
  String get aiToolDefinitionParseError;

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

  /// No description provided for @aiConversation.
  ///
  /// In en, this message translates to:
  /// **'AI Conversation'**
  String get aiConversation;

  /// No description provided for @aiConversationDescription.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation with AI about your notes'**
  String get aiConversationDescription;

  /// No description provided for @startConversation.
  ///
  /// In en, this message translates to:
  /// **'Start Conversation'**
  String get startConversation;

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

  /// No description provided for @conversationCount.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{conversation} other{conversations}}'**
  String conversationCount(int count);

  /// No description provided for @noConversations.
  ///
  /// In en, this message translates to:
  /// **'No conversations'**
  String get noConversations;

  /// No description provided for @conversationsWithThisNote.
  ///
  /// In en, this message translates to:
  /// **'Conversations with this note'**
  String get conversationsWithThisNote;

  /// No description provided for @typeYourMessage.
  ///
  /// In en, this message translates to:
  /// **'Type your message...'**
  String get typeYourMessage;

  /// No description provided for @immersiveMode.
  ///
  /// In en, this message translates to:
  /// **'Immersive Mode'**
  String get immersiveMode;

  /// No description provided for @openInChatMode.
  ///
  /// In en, this message translates to:
  /// **'Open in Chat Mode'**
  String get openInChatMode;

  /// No description provided for @aiChat.
  ///
  /// In en, this message translates to:
  /// **'AI Chat'**
  String get aiChat;

  /// No description provided for @outline.
  ///
  /// In en, this message translates to:
  /// **'Outline'**
  String get outline;

  /// No description provided for @expand.
  ///
  /// In en, this message translates to:
  /// **'Expand'**
  String get expand;

  /// No description provided for @collapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get collapse;

  /// No description provided for @annotate.
  ///
  /// In en, this message translates to:
  /// **'Annotate'**
  String get annotate;

  /// No description provided for @askAiHint.
  ///
  /// In en, this message translates to:
  /// **'Ask AI about DB schema or errors...'**
  String get askAiHint;

  /// No description provided for @startConversationHint.
  ///
  /// In en, this message translates to:
  /// **'Start by asking the AI about your note.'**
  String get startConversationHint;

  /// No description provided for @unsupportedAttachment.
  ///
  /// In en, this message translates to:
  /// **'Unsupported attachment type ({type}).'**
  String unsupportedAttachment(String type);

  /// No description provided for @openAttachment.
  ///
  /// In en, this message translates to:
  /// **'Open attachment'**
  String get openAttachment;

  /// No description provided for @failedToLoadAttachment.
  ///
  /// In en, this message translates to:
  /// **'Failed to load attachment.'**
  String get failedToLoadAttachment;

  /// No description provided for @failedToOpenAttachment.
  ///
  /// In en, this message translates to:
  /// **'Failed to open attachment: {error}'**
  String failedToOpenAttachment(String error);

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

  /// No description provided for @mcpAndLocalTools.
  ///
  /// In en, this message translates to:
  /// **'MCP & Local Tools'**
  String get mcpAndLocalTools;

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

  /// No description provided for @selectNotesForNoteActionApp.
  ///
  /// In en, this message translates to:
  /// **'Select Notes for Note Action App'**
  String get selectNotesForNoteActionApp;

  /// No description provided for @selectNotesToAddToContext.
  ///
  /// In en, this message translates to:
  /// **'Select Notes to add to context'**
  String get selectNotesToAddToContext;

  /// No description provided for @proceedWithNotes.
  ///
  /// In en, this message translates to:
  /// **'Proceed with {count} {count, plural, =1{note} other{notes}}'**
  String proceedWithNotes(int count);

  /// No description provided for @notesSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, =1{note} other{notes}} selected'**
  String notesSelected(int count);

  /// No description provided for @noNotesFoundMatching.
  ///
  /// In en, this message translates to:
  /// **'No notes found matching \"{query}\"'**
  String noNotesFoundMatching(String query);

  /// No description provided for @notesAndContext.
  ///
  /// In en, this message translates to:
  /// **'Notes and Context'**
  String get notesAndContext;

  /// No description provided for @addNotes.
  ///
  /// In en, this message translates to:
  /// **'Add Notes'**
  String get addNotes;

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

  /// No description provided for @deleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete Conversation'**
  String get deleteConversation;

  /// No description provided for @confirmDeleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this conversation? This action cannot be undone.'**
  String get confirmDeleteConversation;

  /// No description provided for @conversationDeletedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Conversation deleted successfully'**
  String get conversationDeletedSuccessfully;

  /// No description provided for @errorDeletingConversation.
  ///
  /// In en, this message translates to:
  /// **'Error deleting conversation: {error}'**
  String errorDeletingConversation(Object error);

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
  String additionalContextNotes(num count);

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

  /// No description provided for @shareUrlChoiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose how to handle this link.'**
  String get shareUrlChoiceTitle;

  /// No description provided for @shareUrlChoiceDescription.
  ///
  /// In en, this message translates to:
  /// **'Extract lets you review the page before capturing it, or keep the URL as-is.'**
  String get shareUrlChoiceDescription;

  /// No description provided for @webExtractionStatusCheckingFileType.
  ///
  /// In en, this message translates to:
  /// **'Checking file type...'**
  String get webExtractionStatusCheckingFileType;

  /// No description provided for @webExtractionStatusDownloadingFile.
  ///
  /// In en, this message translates to:
  /// **'Downloading file...'**
  String get webExtractionStatusDownloadingFile;

  /// No description provided for @webExtractionStatusFileDownloaded.
  ///
  /// In en, this message translates to:
  /// **'File downloaded successfully'**
  String get webExtractionStatusFileDownloaded;

  /// No description provided for @webExtractionStatusDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {reason}'**
  String webExtractionStatusDownloadFailed(String reason);

  /// No description provided for @webExtractionStatusReady.
  ///
  /// In en, this message translates to:
  /// **'Page ready. Interact before extracting.'**
  String get webExtractionStatusReady;

  /// No description provided for @webExtractionStatusStopped.
  ///
  /// In en, this message translates to:
  /// **'Loading stopped. Page ready for extraction.'**
  String get webExtractionStatusStopped;

  /// No description provided for @webExtractionStopLoading.
  ///
  /// In en, this message translates to:
  /// **'Stop loading'**
  String get webExtractionStopLoading;

  /// No description provided for @webExtractionStatusApplyingReadability.
  ///
  /// In en, this message translates to:
  /// **'Applying readability view...'**
  String get webExtractionStatusApplyingReadability;

  /// No description provided for @webExtractionStatusReloadingOriginal.
  ///
  /// In en, this message translates to:
  /// **'Reloading original page...'**
  String get webExtractionStatusReloadingOriginal;

  /// No description provided for @webExtractionStatusReadabilityEnabled.
  ///
  /// In en, this message translates to:
  /// **'Readability view enabled.'**
  String get webExtractionStatusReadabilityEnabled;

  /// No description provided for @webExtractionReadabilityLabel.
  ///
  /// In en, this message translates to:
  /// **'Readability'**
  String get webExtractionReadabilityLabel;

  /// No description provided for @webExtractionReadabilityDescription.
  ///
  /// In en, this message translates to:
  /// **'Simplify the page before extracting. Turning it off reloads the page.'**
  String get webExtractionReadabilityDescription;

  /// No description provided for @webExtractionManualExtract.
  ///
  /// In en, this message translates to:
  /// **'Extract'**
  String get webExtractionManualExtract;

  /// No description provided for @webExtractionAiExtract.
  ///
  /// In en, this message translates to:
  /// **'AI-Extract'**
  String get webExtractionAiExtract;

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

  /// No description provided for @newConversation.
  ///
  /// In en, this message translates to:
  /// **'New Conversation'**
  String get newConversation;

  /// No description provided for @oneHourAgo.
  ///
  /// In en, this message translates to:
  /// **'1 hour ago'**
  String get oneHourAgo;

  /// No description provided for @twelveHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'12 hours ago'**
  String get twelveHoursAgo;

  /// No description provided for @oneDayAgo.
  ///
  /// In en, this message translates to:
  /// **'1 day ago'**
  String get oneDayAgo;

  /// No description provided for @threeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'3 days ago'**
  String get threeDaysAgo;

  /// No description provided for @sevenDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'7 days ago'**
  String get sevenDaysAgo;

  /// No description provided for @fifteenDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'15 days ago'**
  String get fifteenDaysAgo;

  /// No description provided for @oneMonthAgo.
  ///
  /// In en, this message translates to:
  /// **'1 month ago'**
  String get oneMonthAgo;

  /// No description provided for @sixMonthsAgo.
  ///
  /// In en, this message translates to:
  /// **'6 months ago'**
  String get sixMonthsAgo;

  /// No description provided for @allTime.
  ///
  /// In en, this message translates to:
  /// **'All time'**
  String get allTime;

  /// No description provided for @custom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get custom;

  /// No description provided for @first.
  ///
  /// In en, this message translates to:
  /// **'First'**
  String get first;

  /// No description provided for @last.
  ///
  /// In en, this message translates to:
  /// **'Last'**
  String get last;

  /// No description provided for @deleteInteractionWhatToDelete.
  ///
  /// In en, this message translates to:
  /// **'What do you want to delete?'**
  String get deleteInteractionWhatToDelete;

  /// No description provided for @deleteOnlyNodesInFilter.
  ///
  /// In en, this message translates to:
  /// **'Delete only nodes in this filter'**
  String get deleteOnlyNodesInFilter;

  /// No description provided for @deleteNodeAndDescendants.
  ///
  /// In en, this message translates to:
  /// **'Delete this node and all descendants'**
  String get deleteNodeAndDescendants;

  /// No description provided for @tokenTab.
  ///
  /// In en, this message translates to:
  /// **'Token'**
  String get tokenTab;

  /// No description provided for @oauthTab.
  ///
  /// In en, this message translates to:
  /// **'OAuth'**
  String get oauthTab;

  /// No description provided for @autoConfigure.
  ///
  /// In en, this message translates to:
  /// **'Auto Configure'**
  String get autoConfigure;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// No description provided for @authorizationEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Authorization Endpoint'**
  String get authorizationEndpoint;

  /// No description provided for @tokenEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Token Endpoint'**
  String get tokenEndpoint;

  /// No description provided for @clientId.
  ///
  /// In en, this message translates to:
  /// **'Client ID'**
  String get clientId;

  /// No description provided for @clientSecretOptionalForPkce.
  ///
  /// In en, this message translates to:
  /// **'Client Secret (Optional for PKCE)'**
  String get clientSecretOptionalForPkce;

  /// No description provided for @scope.
  ///
  /// In en, this message translates to:
  /// **'Scope'**
  String get scope;

  /// No description provided for @usePkceNoClientSecret.
  ///
  /// In en, this message translates to:
  /// **'Use PKCE (no client secret)'**
  String get usePkceNoClientSecret;

  /// No description provided for @oauthDiscoveryMetadataUrlOptional.
  ///
  /// In en, this message translates to:
  /// **'OAuth Discovery Page: Metadata URL (optional)'**
  String get oauthDiscoveryMetadataUrlOptional;

  /// No description provided for @discover.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get discover;

  /// No description provided for @registerClient.
  ///
  /// In en, this message translates to:
  /// **'Register Client'**
  String get registerClient;

  /// No description provided for @register.
  ///
  /// In en, this message translates to:
  /// **'Register'**
  String get register;

  /// No description provided for @editMcpEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Edit MCP Endpoint'**
  String get editMcpEndpoint;

  /// No description provided for @metadataUrlOptional.
  ///
  /// In en, this message translates to:
  /// **'Metadata URL (optional)'**
  String get metadataUrlOptional;

  /// No description provided for @metadataUrlOptionalHint.
  ///
  /// In en, this message translates to:
  /// **'Leave blank to auto-detect using RFC 9728'**
  String get metadataUrlOptionalHint;

  /// No description provided for @oauthDiscovery.
  ///
  /// In en, this message translates to:
  /// **'OAuth Discovery'**
  String get oauthDiscovery;

  /// No description provided for @openInTree.
  ///
  /// In en, this message translates to:
  /// **'Open in Tree'**
  String get openInTree;

  /// No description provided for @addConversationDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Add Conversation'**
  String get addConversationDialogTitle;

  /// No description provided for @addConversationDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'How would you like to create this conversation?'**
  String get addConversationDialogMessage;

  /// No description provided for @addDirectly.
  ///
  /// In en, this message translates to:
  /// **'Add directly'**
  String get addDirectly;

  /// No description provided for @addDirectlyDescription.
  ///
  /// In en, this message translates to:
  /// **'Create the conversation directly with selected nodes as context'**
  String get addDirectlyDescription;

  /// No description provided for @addWithAIProcessing.
  ///
  /// In en, this message translates to:
  /// **'Add with AI processing'**
  String get addWithAIProcessing;

  /// No description provided for @addWithAIProcessingDescription.
  ///
  /// In en, this message translates to:
  /// **'Use AI to process the content first (e.g., summarize) then create the conversation'**
  String get addWithAIProcessingDescription;

  /// No description provided for @conversationTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversation Title'**
  String get conversationTitle;

  /// No description provided for @enterConversationTitlePrompt.
  ///
  /// In en, this message translates to:
  /// **'Enter a title for the new conversation:'**
  String get enterConversationTitlePrompt;

  /// No description provided for @conversationTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Conversation title'**
  String get conversationTitleHint;

  /// No description provided for @createConversation.
  ///
  /// In en, this message translates to:
  /// **'Create Conversation'**
  String get createConversation;

  /// No description provided for @conversationCreatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'Conversation \"{title}\" created successfully'**
  String conversationCreatedSuccessfully(String title);

  /// No description provided for @errorCreatingConversation.
  ///
  /// In en, this message translates to:
  /// **'Error creating conversation: {error}'**
  String errorCreatingConversation(String error);

  /// No description provided for @aiConversationCreator.
  ///
  /// In en, this message translates to:
  /// **'AI Conversation Creator'**
  String get aiConversationCreator;

  /// No description provided for @aiConversationCreatorInstructions.
  ///
  /// In en, this message translates to:
  /// **'The AI will process the conversation content, along with any additional context you provide below, to create a conversation based on your prompt.'**
  String get aiConversationCreatorInstructions;

  /// No description provided for @selectRelationshipType.
  ///
  /// In en, this message translates to:
  /// **'Select Relationship Type'**
  String get selectRelationshipType;

  /// No description provided for @selectRelationshipTypeForNotes.
  ///
  /// In en, this message translates to:
  /// **'Select the type of relationship for {noteCount} {noteCount, plural, =1{note} other{notes}}:'**
  String selectRelationshipTypeForNotes(int noteCount);

  /// No description provided for @relationshipType.
  ///
  /// In en, this message translates to:
  /// **'Relationship Type'**
  String get relationshipType;

  /// No description provided for @linkNotes.
  ///
  /// In en, this message translates to:
  /// **'Link {noteCount} {noteCount, plural, =1{Note} other{Notes}}'**
  String linkNotes(int noteCount);

  /// No description provided for @customRelationshipType.
  ///
  /// In en, this message translates to:
  /// **'Custom Relationship Type'**
  String get customRelationshipType;

  /// No description provided for @enterCustomRelationshipType.
  ///
  /// In en, this message translates to:
  /// **'Enter custom relationship type'**
  String get enterCustomRelationshipType;

  /// No description provided for @customEllipsis.
  ///
  /// In en, this message translates to:
  /// **'Custom...'**
  String get customEllipsis;

  /// No description provided for @confirmRemoveLink.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to remove this link?'**
  String get confirmRemoveLink;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @linkNotesDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Link Notes'**
  String get linkNotesDialogTitle;

  /// No description provided for @link.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get link;

  /// No description provided for @linkNoteTo.
  ///
  /// In en, this message translates to:
  /// **'Link \"{noteTitle}\" to:'**
  String linkNoteTo(String noteTitle);

  /// No description provided for @audioTranscription.
  ///
  /// In en, this message translates to:
  /// **'Audio Transcription'**
  String get audioTranscription;

  /// No description provided for @transcribingAudio.
  ///
  /// In en, this message translates to:
  /// **'Transcribing audio...'**
  String get transcribingAudio;

  /// No description provided for @transcriptionAddedToNote.
  ///
  /// In en, this message translates to:
  /// **'Transcription added to note'**
  String get transcriptionAddedToNote;

  /// No description provided for @errorTranscribingAudio.
  ///
  /// In en, this message translates to:
  /// **'Error transcribing audio: {error}'**
  String errorTranscribingAudio(String error);

  /// No description provided for @errorAddingTranscription.
  ///
  /// In en, this message translates to:
  /// **'Error adding transcription: {error}'**
  String errorAddingTranscription(String error);

  /// No description provided for @newNoteFromShareCreated.
  ///
  /// In en, this message translates to:
  /// **'New note from share created successfully!'**
  String get newNoteFromShareCreated;

  /// No description provided for @mediaDownloadsHeader.
  ///
  /// In en, this message translates to:
  /// **'Media attachments'**
  String get mediaDownloadsHeader;

  /// No description provided for @mediaDownloadsDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose which images to download locally for offline use.'**
  String get mediaDownloadsDescription;

  /// No description provided for @clearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get clearAll;

  /// No description provided for @noRemoteImagesDetected.
  ///
  /// In en, this message translates to:
  /// **'No remote images detected in this content.'**
  String get noRemoteImagesDetected;

  /// No description provided for @mediaPreviewLabel.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get mediaPreviewLabel;

  /// No description provided for @imageUrlLabel.
  ///
  /// In en, this message translates to:
  /// **'Image URL'**
  String get imageUrlLabel;

  /// No description provided for @downloadToLocalLabel.
  ///
  /// In en, this message translates to:
  /// **'Download to local?'**
  String get downloadToLocalLabel;

  /// No description provided for @mediaDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to download {count, plural, one {# image} other {# images}}.'**
  String mediaDownloadFailed(num count);

  /// No description provided for @mediaDownloadNoneAvailable.
  ///
  /// In en, this message translates to:
  /// **'No remote images available in this note.'**
  String get mediaDownloadNoneAvailable;

  /// No description provided for @mediaDownloadAlreadyCached.
  ///
  /// In en, this message translates to:
  /// **'All remote images are already cached locally.'**
  String get mediaDownloadAlreadyCached;

  /// No description provided for @mediaDownloadSuccess.
  ///
  /// In en, this message translates to:
  /// **'Downloaded {count, plural, one {# image} other {# images}} to attachments.'**
  String mediaDownloadSuccess(num count);

  /// No description provided for @mediaDownloadPartial.
  ///
  /// In en, this message translates to:
  /// **'Downloaded {successCount, plural, one {# image} other {# images}}, failed {failureCount, plural, one {#} other {#}}.'**
  String mediaDownloadPartial(num successCount, num failureCount);

  /// No description provided for @mediaDownloadFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Failed to download images: {error}'**
  String mediaDownloadFailedGeneric(Object error);

  /// No description provided for @fetchRemoteImages.
  ///
  /// In en, this message translates to:
  /// **'Fetch remote images'**
  String get fetchRemoteImages;

  /// No description provided for @gettingStarted.
  ///
  /// In en, this message translates to:
  /// **'Getting Started'**
  String get gettingStarted;

  /// No description provided for @gettingStartedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Install user manual, starter apps, and starter skills'**
  String get gettingStartedSubtitle;

  /// No description provided for @installUserManual.
  ///
  /// In en, this message translates to:
  /// **'Install User Manual'**
  String get installUserManual;

  /// No description provided for @installUserManualSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Install or update the user manual note'**
  String get installUserManualSubtitle;

  /// No description provided for @installStarterApps.
  ///
  /// In en, this message translates to:
  /// **'Install Starter Apps'**
  String get installStarterApps;

  /// No description provided for @installStarterAppsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Browse and install pre-configured apps'**
  String get installStarterAppsSubtitle;

  /// No description provided for @userManualInfo.
  ///
  /// In en, this message translates to:
  /// **'User Manual Information'**
  String get userManualInfo;

  /// No description provided for @installed.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get installed;

  /// No description provided for @notInstalled.
  ///
  /// In en, this message translates to:
  /// **'Not Installed'**
  String get notInstalled;

  /// No description provided for @currentVersion.
  ///
  /// In en, this message translates to:
  /// **'Current Version'**
  String get currentVersion;

  /// No description provided for @latestVersion.
  ///
  /// In en, this message translates to:
  /// **'Latest Version'**
  String get latestVersion;

  /// No description provided for @lastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Last Updated'**
  String get lastUpdated;

  /// No description provided for @newVersionAvailable.
  ///
  /// In en, this message translates to:
  /// **'New version available!'**
  String get newVersionAvailable;

  /// No description provided for @updateUserManual.
  ///
  /// In en, this message translates to:
  /// **'Update User Manual'**
  String get updateUserManual;

  /// No description provided for @reinstallUserManual.
  ///
  /// In en, this message translates to:
  /// **'Reinstall User Manual'**
  String get reinstallUserManual;

  /// No description provided for @installing.
  ///
  /// In en, this message translates to:
  /// **'Installing...'**
  String get installing;

  /// No description provided for @updateUserManualConfirm.
  ///
  /// In en, this message translates to:
  /// **'A newer version ({newVersion}) of the User Manual is available. Your current version is {oldVersion}. Do you want to update?'**
  String updateUserManualConfirm(String oldVersion, String newVersion);

  /// No description provided for @userManualInstalledSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'User Manual installed successfully!'**
  String get userManualInstalledSuccessfully;

  /// No description provided for @userManualUpdatedSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'User Manual updated successfully!'**
  String get userManualUpdatedSuccessfully;

  /// No description provided for @errorInstallingUserManual.
  ///
  /// In en, this message translates to:
  /// **'Error installing User Manual: {error}'**
  String errorInstallingUserManual(String error);

  /// No description provided for @whatIsUserManual.
  ///
  /// In en, this message translates to:
  /// **'What is User Manual?'**
  String get whatIsUserManual;

  /// No description provided for @userManualDescription.
  ///
  /// In en, this message translates to:
  /// **'The User Manual is a comprehensive guide to Note Synapse. It includes detailed instructions, tips, and best practices for using the app effectively.'**
  String get userManualDescription;

  /// No description provided for @noStarterAppsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No starter apps available'**
  String get noStarterAppsAvailable;

  /// No description provided for @noAppsSelected.
  ///
  /// In en, this message translates to:
  /// **'No apps selected'**
  String get noAppsSelected;

  /// No description provided for @appsSelected.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one {app} other {apps}} selected'**
  String appsSelected(int count);

  /// No description provided for @proceedWithInstallation.
  ///
  /// In en, this message translates to:
  /// **'Install Selected Apps'**
  String get proceedWithInstallation;

  /// No description provided for @starterAppsInstalledSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one {app} other {apps}} installed successfully!'**
  String starterAppsInstalledSuccessfully(int count);

  /// No description provided for @starterAppsInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to install {count} {count, plural, one {app} other {apps}}'**
  String starterAppsInstallFailed(int count);

  /// No description provided for @starterAppsPartialInstall.
  ///
  /// In en, this message translates to:
  /// **'Installed {successCount} {successCount, plural, one {app} other {apps}}, failed {failureCount} {failureCount, plural, one {app} other {apps}}'**
  String starterAppsPartialInstall(int successCount, int failureCount);

  /// No description provided for @errorInstallingStarterApps.
  ///
  /// In en, this message translates to:
  /// **'Error installing starter apps: {error}'**
  String errorInstallingStarterApps(String error);

  /// No description provided for @installStarterSkills.
  ///
  /// In en, this message translates to:
  /// **'Install Starter Skills'**
  String get installStarterSkills;

  /// No description provided for @installStarterSkillsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Browse bundled skills and install them as transparent skill notes'**
  String get installStarterSkillsSubtitle;

  /// No description provided for @noStarterSkillsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No starter skills available'**
  String get noStarterSkillsAvailable;

  /// No description provided for @noStarterSkillsSelected.
  ///
  /// In en, this message translates to:
  /// **'No starter skills selected'**
  String get noStarterSkillsSelected;

  /// No description provided for @installSelectedSkills.
  ///
  /// In en, this message translates to:
  /// **'Install Selected Skills'**
  String get installSelectedSkills;

  /// No description provided for @starterSkillsInstalledSuccessfully.
  ///
  /// In en, this message translates to:
  /// **'{count} {count, plural, one {skill} other {skills}} installed successfully!'**
  String starterSkillsInstalledSuccessfully(int count);

  /// No description provided for @errorLoadingStarterSkills.
  ///
  /// In en, this message translates to:
  /// **'Error loading starter skills: {error}'**
  String errorLoadingStarterSkills(String error);

  /// No description provided for @errorInstallingStarterSkills.
  ///
  /// In en, this message translates to:
  /// **'Error installing starter skills: {error}'**
  String errorInstallingStarterSkills(String error);

  /// No description provided for @skillRefLabel.
  ///
  /// In en, this message translates to:
  /// **'skillRef: {ref}'**
  String skillRefLabel(String ref);

  /// No description provided for @sourceLabel.
  ///
  /// In en, this message translates to:
  /// **'Source: {source}'**
  String sourceLabel(String source);

  /// No description provided for @rawDataManagerTitle.
  ///
  /// In en, this message translates to:
  /// **'Raw Data Manager'**
  String get rawDataManagerTitle;

  /// No description provided for @advancedToolTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced Tool'**
  String get advancedToolTitle;

  /// No description provided for @advancedToolWarning.
  ///
  /// In en, this message translates to:
  /// **'This tool provides raw access to your application data and database. Improper use can lead to PERMANENT DATA LOSS or corruption.\n\nOnly use this if you know what you are doing or have been instructed by support.'**
  String get advancedToolWarning;

  /// No description provided for @iUnderstand.
  ///
  /// In en, this message translates to:
  /// **'I Understand'**
  String get iUnderstand;

  /// No description provided for @fileManagerTab.
  ///
  /// In en, this message translates to:
  /// **'File Manager'**
  String get fileManagerTab;

  /// No description provided for @databaseManagerTab.
  ///
  /// In en, this message translates to:
  /// **'Database Manager'**
  String get databaseManagerTab;

  /// No description provided for @warningDataInstability.
  ///
  /// In en, this message translates to:
  /// **'Warning: Direct data modification can cause app instability.'**
  String get warningDataInstability;

  /// No description provided for @cache.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get cache;

  /// No description provided for @root.
  ///
  /// In en, this message translates to:
  /// **'Root'**
  String get root;

  /// No description provided for @itemsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} items'**
  String itemsCount(int count);

  /// No description provided for @selectUnused.
  ///
  /// In en, this message translates to:
  /// **'Select Unused'**
  String get selectUnused;

  /// No description provided for @noFilesFound.
  ///
  /// In en, this message translates to:
  /// **'No files found'**
  String get noFilesFound;

  /// No description provided for @used.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get used;

  /// No description provided for @unused.
  ///
  /// In en, this message translates to:
  /// **'Unused'**
  String get unused;

  /// No description provided for @renameFile.
  ///
  /// In en, this message translates to:
  /// **'Rename File'**
  String get renameFile;

  /// No description provided for @newName.
  ///
  /// In en, this message translates to:
  /// **'New Name'**
  String get newName;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @deleteFilesTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Files?'**
  String get deleteFilesTitle;

  /// No description provided for @deleteFilesConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete {count} files? This cannot be undone.'**
  String deleteFilesConfirmation(int count);

  /// No description provided for @deletedFilesMessage.
  ///
  /// In en, this message translates to:
  /// **'Deleted {count} files'**
  String deletedFilesMessage(int count);

  /// No description provided for @errorRenamingFile.
  ///
  /// In en, this message translates to:
  /// **'Error renaming file: {error}'**
  String errorRenamingFile(String error);

  /// No description provided for @queryAndResults.
  ///
  /// In en, this message translates to:
  /// **'Query & Results'**
  String get queryAndResults;

  /// No description provided for @aiAssistant.
  ///
  /// In en, this message translates to:
  /// **'AI Assistant'**
  String get aiAssistant;

  /// No description provided for @notConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected'**
  String get notConnected;

  /// No description provided for @connectedTo.
  ///
  /// In en, this message translates to:
  /// **'Connected to: {name}'**
  String connectedTo(String name);

  /// No description provided for @errorOpeningDefaultDb.
  ///
  /// In en, this message translates to:
  /// **'Error opening default DB: {error}'**
  String errorOpeningDefaultDb(String error);

  /// No description provided for @errorOpeningDb.
  ///
  /// In en, this message translates to:
  /// **'Error opening DB: {error}'**
  String errorOpeningDb(String error);

  /// No description provided for @databaseExportedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Database exported successfully'**
  String get databaseExportedSuccess;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String exportFailed(String error);

  /// No description provided for @sqlQueryLabel.
  ///
  /// In en, this message translates to:
  /// **'SQL Query'**
  String get sqlQueryLabel;

  /// No description provided for @sqlQueryHint.
  ///
  /// In en, this message translates to:
  /// **'SELECT * FROM notes LIMIT 5'**
  String get sqlQueryHint;

  /// No description provided for @runQueryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Run Query'**
  String get runQueryTooltip;

  /// No description provided for @enterQueryMessage.
  ///
  /// In en, this message translates to:
  /// **'Enter a query to see results'**
  String get enterQueryMessage;

  /// No description provided for @noResultsReturned.
  ///
  /// In en, this message translates to:
  /// **'No results returned'**
  String get noResultsReturned;

  /// No description provided for @queryExecutedMessage.
  ///
  /// In en, this message translates to:
  /// **'Query executed. {count} rows returned.'**
  String queryExecutedMessage(int count);

  /// No description provided for @updateExecutedMessage.
  ///
  /// In en, this message translates to:
  /// **'Update executed. {count} rows affected.'**
  String updateExecutedMessage(int count);

  /// No description provided for @queryError.
  ///
  /// In en, this message translates to:
  /// **'Query Error: {error}'**
  String queryError(String error);

  /// No description provided for @askAiAboutNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Ask AI about this note...'**
  String get askAiAboutNoteHint;

  /// No description provided for @openDbFileTooltip.
  ///
  /// In en, this message translates to:
  /// **'Open DB File'**
  String get openDbFileTooltip;

  /// No description provided for @resetToDefaultDbTooltip.
  ///
  /// In en, this message translates to:
  /// **'Reset to Default DB'**
  String get resetToDefaultDbTooltip;

  /// No description provided for @exportDbTooltip.
  ///
  /// In en, this message translates to:
  /// **'Export DB'**
  String get exportDbTooltip;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// No description provided for @taskRescheduled.
  ///
  /// In en, this message translates to:
  /// **'Task rescheduled'**
  String get taskRescheduled;

  /// No description provided for @recoveryManager.
  ///
  /// In en, this message translates to:
  /// **'Recovery Manager'**
  String get recoveryManager;

  /// No description provided for @backupAndRestore.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get backupAndRestore;

  /// No description provided for @databaseNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Database not connected'**
  String get databaseNotConnected;

  /// No description provided for @fileUsageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'File usage status unavailable'**
  String get fileUsageUnavailable;

  /// No description provided for @fileUsageDetails.
  ///
  /// In en, this message translates to:
  /// **'File Usage Details'**
  String get fileUsageDetails;

  /// No description provided for @noReferencesFound.
  ///
  /// In en, this message translates to:
  /// **'No references found in database'**
  String get noReferencesFound;

  /// No description provided for @usedByNotes.
  ///
  /// In en, this message translates to:
  /// **'Used by {count} note(s)'**
  String usedByNotes(int count);

  /// No description provided for @usedByConversations.
  ///
  /// In en, this message translates to:
  /// **'Used in {count} conversation message(s)'**
  String usedByConversations(int count);

  /// No description provided for @noteNoLongerExists.
  ///
  /// In en, this message translates to:
  /// **'Note no longer exists'**
  String get noteNoLongerExists;

  /// No description provided for @messageNoLongerExists.
  ///
  /// In en, this message translates to:
  /// **'Message no longer exists'**
  String get messageNoLongerExists;

  /// No description provided for @showDetails.
  ///
  /// In en, this message translates to:
  /// **'Show Details'**
  String get showDetails;

  /// No description provided for @saveFindings.
  ///
  /// In en, this message translates to:
  /// **'Save Findings'**
  String get saveFindings;

  /// No description provided for @saveFindingsToNote.
  ///
  /// In en, this message translates to:
  /// **'Save findings to note'**
  String get saveFindingsToNote;

  /// No description provided for @attachNotesToPlan.
  ///
  /// In en, this message translates to:
  /// **'Attach Notes to Plan'**
  String get attachNotesToPlan;

  /// No description provided for @attachNotesToTask.
  ///
  /// In en, this message translates to:
  /// **'Attach Notes to Task'**
  String get attachNotesToTask;

  /// No description provided for @globalContextNotes.
  ///
  /// In en, this message translates to:
  /// **'Global Context Notes'**
  String get globalContextNotes;

  /// No description provided for @taskContextNotes.
  ///
  /// In en, this message translates to:
  /// **'Task Context Notes'**
  String get taskContextNotes;

  /// No description provided for @globalContextDescription.
  ///
  /// In en, this message translates to:
  /// **'These notes will be included as context for all tasks'**
  String get globalContextDescription;

  /// No description provided for @taskContextDescription.
  ///
  /// In en, this message translates to:
  /// **'These notes will be included as context for this task only'**
  String get taskContextDescription;

  /// No description provided for @notesAttachedCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No notes attached} =1{1 note attached} other{{count} notes attached}}'**
  String notesAttachedCount(int count);

  /// No description provided for @agentRunningNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent Running'**
  String get agentRunningNotificationTitle;

  /// No description provided for @agentRunningNotificationBody.
  ///
  /// In en, this message translates to:
  /// **'Working on: {objective}'**
  String agentRunningNotificationBody(String objective);

  /// No description provided for @agentCompleteNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent Complete'**
  String get agentCompleteNotificationTitle;

  /// No description provided for @agentCompleteNotificationBody.
  ///
  /// In en, this message translates to:
  /// **'Tap to view results'**
  String get agentCompleteNotificationBody;

  /// No description provided for @agentPauseExecution.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get agentPauseExecution;

  /// No description provided for @agentResumeExecution.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get agentResumeExecution;

  /// No description provided for @agentStopExecution.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get agentStopExecution;

  /// No description provided for @agentPausedStatus.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get agentPausedStatus;

  /// No description provided for @agentConflictTitle.
  ///
  /// In en, this message translates to:
  /// **'Agent Already Running'**
  String get agentConflictTitle;

  /// No description provided for @agentConflictMessage.
  ///
  /// In en, this message translates to:
  /// **'An agent is currently {status} in another conversation. You can stop it to start a new one, or switch to that conversation.'**
  String agentConflictMessage(String status);

  /// No description provided for @agentConflictStop.
  ///
  /// In en, this message translates to:
  /// **'Stop Agent'**
  String get agentConflictStop;

  /// No description provided for @agentConflictSwitch.
  ///
  /// In en, this message translates to:
  /// **'Switch to Conversation'**
  String get agentConflictSwitch;

  /// No description provided for @editBlock.
  ///
  /// In en, this message translates to:
  /// **'Edit Block'**
  String get editBlock;

  /// No description provided for @deleteBlock.
  ///
  /// In en, this message translates to:
  /// **'Delete Block'**
  String get deleteBlock;

  /// No description provided for @deleteBlockConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this block? This action cannot be undone.'**
  String get deleteBlockConfirmation;

  /// No description provided for @expandSelectionAbove.
  ///
  /// In en, this message translates to:
  /// **'Expand Above'**
  String get expandSelectionAbove;

  /// No description provided for @contractSelectionAbove.
  ///
  /// In en, this message translates to:
  /// **'Contract Above'**
  String get contractSelectionAbove;

  /// No description provided for @expandSelectionBelow.
  ///
  /// In en, this message translates to:
  /// **'Expand Below'**
  String get expandSelectionBelow;

  /// No description provided for @contractSelectionBelow.
  ///
  /// In en, this message translates to:
  /// **'Contract Below'**
  String get contractSelectionBelow;

  /// No description provided for @expandToTop.
  ///
  /// In en, this message translates to:
  /// **'To top'**
  String get expandToTop;

  /// No description provided for @expandToBottom.
  ///
  /// In en, this message translates to:
  /// **'To bottom'**
  String get expandToBottom;

  /// No description provided for @contractToStart.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get contractToStart;

  /// No description provided for @editSelection.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editSelection;

  /// No description provided for @runNoteActionAppOnSelection.
  ///
  /// In en, this message translates to:
  /// **'Run Note Action App'**
  String get runNoteActionAppOnSelection;

  /// No description provided for @approvalScopeBlockOnly.
  ///
  /// In en, this message translates to:
  /// **'Applies to the selected block only.'**
  String get approvalScopeBlockOnly;

  /// No description provided for @approvalScopeWholeNote.
  ///
  /// In en, this message translates to:
  /// **'Applies to the ENTIRE note, not just the selected block.'**
  String get approvalScopeWholeNote;

  /// No description provided for @blockSelectionOutOfSync.
  ///
  /// In en, this message translates to:
  /// **'This block cannot be targeted: its position in the note could not be confirmed, so no app was opened. The note was left unchanged.'**
  String get blockSelectionOutOfSync;

  /// No description provided for @deleteSelection.
  ///
  /// In en, this message translates to:
  /// **'Delete Blocks'**
  String get deleteSelection;

  /// No description provided for @confirmDeleteBlocks.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete {count} blocks?'**
  String confirmDeleteBlocks(int count);

  /// No description provided for @forceRefetchImages.
  ///
  /// In en, this message translates to:
  /// **'Force Refetch Images'**
  String get forceRefetchImages;

  /// No description provided for @fetchingImage.
  ///
  /// In en, this message translates to:
  /// **'Fetching image...'**
  String get fetchingImage;

  /// No description provided for @localModelDescription.
  ///
  /// In en, this message translates to:
  /// **'On-device AI, no API key needed'**
  String get localModelDescription;

  /// No description provided for @localModelDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get localModelDownload;

  /// No description provided for @localModelDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading...'**
  String get localModelDownloading;

  /// No description provided for @localModelReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get localModelReady;

  /// No description provided for @localModelNotDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded'**
  String get localModelNotDownloaded;

  /// No description provided for @localModelDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download Failed'**
  String get localModelDownloadFailed;

  /// No description provided for @localModelRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get localModelRetry;

  /// No description provided for @localModelDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete Model'**
  String get localModelDelete;

  /// No description provided for @localModelTokenWindow.
  ///
  /// In en, this message translates to:
  /// **'Token Window'**
  String get localModelTokenWindow;

  /// No description provided for @localModelEnableThinking.
  ///
  /// In en, this message translates to:
  /// **'Enable Thinking'**
  String get localModelEnableThinking;

  /// No description provided for @localModelBackend.
  ///
  /// In en, this message translates to:
  /// **'Preferred Backend'**
  String get localModelBackend;

  /// No description provided for @localModelBackendNpu.
  ///
  /// In en, this message translates to:
  /// **'NPU'**
  String get localModelBackendNpu;

  /// No description provided for @localModelBackendGpu.
  ///
  /// In en, this message translates to:
  /// **'GPU'**
  String get localModelBackendGpu;

  /// No description provided for @localModelBackendCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get localModelBackendCpu;

  /// No description provided for @localModelBackendRequired.
  ///
  /// In en, this message translates to:
  /// **'Select at least one backend'**
  String get localModelBackendRequired;

  /// No description provided for @localModelSettings.
  ///
  /// In en, this message translates to:
  /// **'Model Settings'**
  String get localModelSettings;

  /// No description provided for @localModelConstraintWarning.
  ///
  /// In en, this message translates to:
  /// **'This input may exceed the local model\'s token window. Consider switching to a cloud model.'**
  String get localModelConstraintWarning;

  /// No description provided for @localModelSwitchToCloud.
  ///
  /// In en, this message translates to:
  /// **'Switch to Cloud'**
  String get localModelSwitchToCloud;

  /// No description provided for @toolOrchestrationWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Tool Orchestration Not Supported'**
  String get toolOrchestrationWarningTitle;

  /// No description provided for @toolOrchestrationWarningBody.
  ///
  /// In en, this message translates to:
  /// **'{modelName} may not reliably execute tool calls. Performance can degrade significantly.'**
  String toolOrchestrationWarningBody(String modelName);

  /// No description provided for @toolOrchestrationSupportedBody.
  ///
  /// In en, this message translates to:
  /// **'{modelName} supports tool orchestration.'**
  String toolOrchestrationSupportedBody(String modelName);

  /// No description provided for @toolOrchestrationContinueAnyway.
  ///
  /// In en, this message translates to:
  /// **'Continue Anyway'**
  String get toolOrchestrationContinueAnyway;

  /// No description provided for @toolOrchestrationContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get toolOrchestrationContinue;

  /// No description provided for @toolOrchestrationStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get toolOrchestrationStop;

  /// No description provided for @toolOrchestrationSwitchModel.
  ///
  /// In en, this message translates to:
  /// **'Switch Model'**
  String get toolOrchestrationSwitchModel;

  /// No description provided for @localModelWorkflowWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Local Model Performance Warning'**
  String get localModelWorkflowWarningTitle;

  /// No description provided for @localModelWorkflowWarningBody.
  ///
  /// In en, this message translates to:
  /// **'This model may not deliver the best experience with tag workflows.'**
  String get localModelWorkflowWarningBody;

  /// No description provided for @localModelWorkflowWarningContinueNoWarn.
  ///
  /// In en, this message translates to:
  /// **'Continue, Don\'t Warn This Session'**
  String get localModelWorkflowWarningContinueNoWarn;

  /// No description provided for @nightMode.
  ///
  /// In en, this message translates to:
  /// **'Night Mode'**
  String get nightMode;

  /// No description provided for @dayMode.
  ///
  /// In en, this message translates to:
  /// **'Day Mode'**
  String get dayMode;

  /// No description provided for @userAppSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'User App'**
  String get userAppSettingsTitle;

  /// No description provided for @userAppSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Manage user app settings and libraries'**
  String get userAppSettingsSubtitle;

  /// No description provided for @addFromFilter.
  ///
  /// In en, this message translates to:
  /// **'Add from filter'**
  String get addFromFilter;

  /// No description provided for @insertUserApp.
  ///
  /// In en, this message translates to:
  /// **'Insert User App'**
  String get insertUserApp;

  /// No description provided for @insertUserAppTitle.
  ///
  /// In en, this message translates to:
  /// **'Embed a user app'**
  String get insertUserAppTitle;

  /// No description provided for @insertUserAppSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search apps…'**
  String get insertUserAppSearchHint;

  /// No description provided for @insertUserAppIncludeAllTypes.
  ///
  /// In en, this message translates to:
  /// **'Include note-action & AI-tool apps'**
  String get insertUserAppIncludeAllTypes;

  /// No description provided for @insertUserAppConfigureTitle.
  ///
  /// In en, this message translates to:
  /// **'Embed {appName}'**
  String insertUserAppConfigureTitle(String appName);

  /// No description provided for @insertUserAppSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get insertUserAppSize;

  /// No description provided for @insertUserAppSizeSmall.
  ///
  /// In en, this message translates to:
  /// **'Small (320×200)'**
  String get insertUserAppSizeSmall;

  /// No description provided for @insertUserAppSizeMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium (480×300)'**
  String get insertUserAppSizeMedium;

  /// No description provided for @insertUserAppSizeLarge.
  ///
  /// In en, this message translates to:
  /// **'Large (640×400)'**
  String get insertUserAppSizeLarge;

  /// No description provided for @insertUserAppSizeCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get insertUserAppSizeCustom;

  /// No description provided for @insertUserAppCustomWidth.
  ///
  /// In en, this message translates to:
  /// **'Width'**
  String get insertUserAppCustomWidth;

  /// No description provided for @insertUserAppCustomHeight.
  ///
  /// In en, this message translates to:
  /// **'Height'**
  String get insertUserAppCustomHeight;

  /// No description provided for @insertUserAppPassCurrentNote.
  ///
  /// In en, this message translates to:
  /// **'Pass current note to app'**
  String get insertUserAppPassCurrentNote;

  /// No description provided for @insertUserAppAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced: generate fenced block'**
  String get insertUserAppAdvanced;

  /// No description provided for @insertUserAppInsertButton.
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get insertUserAppInsertButton;

  /// No description provided for @insertUserAppBackButton.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get insertUserAppBackButton;

  /// No description provided for @insertUserAppNoAppsMessage.
  ///
  /// In en, this message translates to:
  /// **'You haven\'t installed any apps yet.'**
  String get insertUserAppNoAppsMessage;

  /// No description provided for @branchStripDocumentSwapMessage.
  ///
  /// In en, this message translates to:
  /// **'This branch is associated with a different document. Switch document?'**
  String get branchStripDocumentSwapMessage;

  /// No description provided for @branchStripDocumentSwapConfirm.
  ///
  /// In en, this message translates to:
  /// **'Switch'**
  String get branchStripDocumentSwapConfirm;

  /// No description provided for @modelPreferences.
  ///
  /// In en, this message translates to:
  /// **'Model Preferences'**
  String get modelPreferences;

  /// No description provided for @modelPreferencesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set capability-based model priority'**
  String get modelPreferencesSubtitle;

  /// No description provided for @viewFeatureMatrix.
  ///
  /// In en, this message translates to:
  /// **'View Feature Matrix'**
  String get viewFeatureMatrix;

  /// No description provided for @modelPreferenceDragDropHint.
  ///
  /// In en, this message translates to:
  /// **'Drag and drop to reorder models. The first model that matches the required capabilities will be used. If the list is empty or no match is found, the system default model is used.'**
  String get modelPreferenceDragDropHint;

  /// No description provided for @priorityList.
  ///
  /// In en, this message translates to:
  /// **'Priority List'**
  String get priorityList;

  /// No description provided for @noPreferencesSetMessage.
  ///
  /// In en, this message translates to:
  /// **'No preferences set.\nSystem default model will be used.'**
  String get noPreferencesSetMessage;

  /// No description provided for @unknownModel.
  ///
  /// In en, this message translates to:
  /// **'Unknown Model'**
  String get unknownModel;

  /// No description provided for @imageInputCapability.
  ///
  /// In en, this message translates to:
  /// **'Image Input'**
  String get imageInputCapability;

  /// No description provided for @videoInputCapability.
  ///
  /// In en, this message translates to:
  /// **'Video Input'**
  String get videoInputCapability;

  /// No description provided for @audioInputCapability.
  ///
  /// In en, this message translates to:
  /// **'Audio Input'**
  String get audioInputCapability;

  /// No description provided for @docsCapability.
  ///
  /// In en, this message translates to:
  /// **'Docs'**
  String get docsCapability;

  /// No description provided for @imageGenCapability.
  ///
  /// In en, this message translates to:
  /// **'Image Gen'**
  String get imageGenCapability;

  /// No description provided for @speechGenCapability.
  ///
  /// In en, this message translates to:
  /// **'Speech Gen'**
  String get speechGenCapability;

  /// No description provided for @codeGenCapability.
  ///
  /// In en, this message translates to:
  /// **'Code Gen'**
  String get codeGenCapability;

  /// No description provided for @modelFeatureMatrix.
  ///
  /// In en, this message translates to:
  /// **'Model Feature Matrix'**
  String get modelFeatureMatrix;

  /// No description provided for @modelNameColumn.
  ///
  /// In en, this message translates to:
  /// **'Model Name'**
  String get modelNameColumn;

  /// No description provided for @imageInColumn.
  ///
  /// In en, this message translates to:
  /// **'Image In'**
  String get imageInColumn;

  /// No description provided for @videoInColumn.
  ///
  /// In en, this message translates to:
  /// **'Video In'**
  String get videoInColumn;

  /// No description provided for @audioColumn.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get audioColumn;

  /// No description provided for @imgGenColumn.
  ///
  /// In en, this message translates to:
  /// **'Img Gen'**
  String get imgGenColumn;

  /// No description provided for @ttsGenColumn.
  ///
  /// In en, this message translates to:
  /// **'Speech Gen'**
  String get ttsGenColumn;

  /// No description provided for @codeGenColumn.
  ///
  /// In en, this message translates to:
  /// **'Code Gen'**
  String get codeGenColumn;

  /// No description provided for @docsColumn.
  ///
  /// In en, this message translates to:
  /// **'Docs'**
  String get docsColumn;

  /// No description provided for @errorLoadingModelPreferences.
  ///
  /// In en, this message translates to:
  /// **'Error loading model preferences: {error}'**
  String errorLoadingModelPreferences(String error);

  /// No description provided for @errorSavingModelPreferences.
  ///
  /// In en, this message translates to:
  /// **'Error saving preferences: {error}'**
  String errorSavingModelPreferences(String error);

  /// No description provided for @scratchpad.
  ///
  /// In en, this message translates to:
  /// **'Scratchpad'**
  String get scratchpad;

  /// No description provided for @sendToScratchpad.
  ///
  /// In en, this message translates to:
  /// **'Send to scratchpad'**
  String get sendToScratchpad;

  /// No description provided for @scratchpadEmpty.
  ///
  /// In en, this message translates to:
  /// **'Scratchpad is empty'**
  String get scratchpadEmpty;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @recallAnnotations.
  ///
  /// In en, this message translates to:
  /// **'Recall annotations'**
  String get recallAnnotations;

  /// No description provided for @includeScratchpadInChat.
  ///
  /// In en, this message translates to:
  /// **'Include scratchpad in chat context'**
  String get includeScratchpadInChat;

  /// No description provided for @selectTagsForNotes.
  ///
  /// In en, this message translates to:
  /// **'Select Tags for {count} {count, plural, =1{Note} other{Notes}}'**
  String selectTagsForNotes(int count);

  /// No description provided for @webLogins.
  ///
  /// In en, this message translates to:
  /// **'Web Logins'**
  String get webLogins;

  /// No description provided for @webLoginsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Save logins so you can clip pages that require signing in'**
  String get webLoginsSubtitle;

  /// No description provided for @webLoginsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No saved logins yet. Add one to clip pages that require signing in.'**
  String get webLoginsEmpty;

  /// No description provided for @addWebLogin.
  ///
  /// In en, this message translates to:
  /// **'Add login'**
  String get addWebLogin;

  /// No description provided for @webLoginBrowserHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a URL and sign in, then tap Save login'**
  String get webLoginBrowserHint;

  /// No description provided for @saveLogin.
  ///
  /// In en, this message translates to:
  /// **'Save login'**
  String get saveLogin;

  /// No description provided for @loginSaved.
  ///
  /// In en, this message translates to:
  /// **'Login saved for {domain}'**
  String loginSaved(String domain);

  /// No description provided for @deleteLogin.
  ///
  /// In en, this message translates to:
  /// **'Delete login'**
  String get deleteLogin;

  /// No description provided for @deleteLoginConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the saved login for {domain}? Clipping pages on this site will no longer be authenticated, and any apps you gave access to this login will lose it.'**
  String deleteLoginConfirm(String domain);

  /// No description provided for @deleteLoginFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not delete this login. Please try again.'**
  String get deleteLoginFailed;

  /// No description provided for @webLoginSecurityNote.
  ///
  /// In en, this message translates to:
  /// **'On this platform, saved logins are stored without OS-level encryption. Only save logins on a device you trust.'**
  String get webLoginSecurityNote;

  /// No description provided for @webLoginCaptureFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not capture a login session. Make sure you are signed in before saving. This feature is unavailable on the web build.'**
  String get webLoginCaptureFailed;

  /// No description provided for @requestDesktopSite.
  ///
  /// In en, this message translates to:
  /// **'Request desktop site'**
  String get requestDesktopSite;

  /// No description provided for @requestMobileSite.
  ///
  /// In en, this message translates to:
  /// **'Request mobile site'**
  String get requestMobileSite;

  /// No description provided for @webLoginAppsWithAccess.
  ///
  /// In en, this message translates to:
  /// **'Apps with access'**
  String get webLoginAppsWithAccess;

  /// No description provided for @revoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get revoke;

  /// No description provided for @revokeAppAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Revoke access'**
  String get revokeAppAccessTitle;

  /// No description provided for @revokeAppAccessConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{appName}\" access to your {domain} login?'**
  String revokeAppAccessConfirm(String appName, String domain);

  /// Placeholder shown in place of an image when a synapseresource://figure or attachment URI cannot be resolved
  ///
  /// In en, this message translates to:
  /// **'Figure no longer available — the source note or figure was removed'**
  String get figureUnavailable;

  /// Provenance label under a retrieved figure: owning note title and 1-based page
  ///
  /// In en, this message translates to:
  /// **'{title} · p.{page}'**
  String figureSourcePage(String title, int page);

  /// Tooltip/semantics label for the provenance button that opens the figure's source attachment
  ///
  /// In en, this message translates to:
  /// **'Open source'**
  String get figureOpenSource;

  /// Title of the search/index settings screen and of its Settings entry tile
  ///
  /// In en, this message translates to:
  /// **'Search & indexing'**
  String get searchSettings;

  /// No description provided for @searchSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Semantic search, OCR, and index maintenance'**
  String get searchSettingsSubtitle;

  /// Settings tile subtitle when no embedding provider is configured — keyword search only
  ///
  /// In en, this message translates to:
  /// **'Lexical only'**
  String get searchSubtitleLexicalOnly;

  /// No description provided for @searchSubtitleReady.
  ///
  /// In en, this message translates to:
  /// **'{provider} · semantic search on'**
  String searchSubtitleReady(String provider);

  /// No description provided for @searchSubtitleIndexing.
  ///
  /// In en, this message translates to:
  /// **'{provider} · indexing {percent}%'**
  String searchSubtitleIndexing(String provider, int percent);

  /// No description provided for @searchSubtitleSwitching.
  ///
  /// In en, this message translates to:
  /// **'Switching to {provider} — {percent}% re-indexed'**
  String searchSubtitleSwitching(String provider, int percent);

  /// Subtitle when the configured provider was explicitly stopped ("Stop using X now"): it stays unserved across sweeps and restarts until re-enabled, so reporting backfill progress would imply it comes back on its own
  ///
  /// In en, this message translates to:
  /// **'Semantic search off — re-enable {provider} to resume'**
  String searchSubtitleRevoked(String provider);

  /// Action on the revoked-provider row: re-selecting the same provider lifts the revocation
  ///
  /// In en, this message translates to:
  /// **'Re-enable'**
  String get searchProviderReEnable;

  /// No description provided for @searchSubtitleErrors.
  ///
  /// In en, this message translates to:
  /// **'{provider} · {count} errors'**
  String searchSubtitleErrors(String provider, int count);

  /// No description provided for @searchIndexStatus.
  ///
  /// In en, this message translates to:
  /// **'Index status'**
  String get searchIndexStatus;

  /// No description provided for @searchIndexIdle.
  ///
  /// In en, this message translates to:
  /// **'Up to date — {chunks} indexed chunks'**
  String searchIndexIdle(int chunks);

  /// No description provided for @searchStageChunks.
  ///
  /// In en, this message translates to:
  /// **'Indexing notes — {done}/{total}'**
  String searchStageChunks(int done, int total);

  /// No description provided for @searchStagePdfText.
  ///
  /// In en, this message translates to:
  /// **'Reading PDF text — {done}/{total} attachments'**
  String searchStagePdfText(int done, int total);

  /// No description provided for @searchStageOcr.
  ///
  /// In en, this message translates to:
  /// **'Recognizing text in PDFs — {done}/{total} pages'**
  String searchStageOcr(int done, int total);

  /// No description provided for @searchStageEmbed.
  ///
  /// In en, this message translates to:
  /// **'Creating embeddings — {done}/{total} chunks'**
  String searchStageEmbed(int done, int total);

  /// No description provided for @searchEmbeddingProvider.
  ///
  /// In en, this message translates to:
  /// **'Embedding provider'**
  String get searchEmbeddingProvider;

  /// No description provided for @searchProviderNone.
  ///
  /// In en, this message translates to:
  /// **'None (lexical only)'**
  String get searchProviderNone;

  /// No description provided for @searchProviderNoneSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keyword search only — nothing leaves the device'**
  String get searchProviderNoneSubtitle;

  /// No description provided for @searchProviderCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom (OpenAI-compatible)'**
  String get searchProviderCustom;

  /// No description provided for @searchProviderCustomSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Self-hosted or any OpenAI-compatible endpoint'**
  String get searchProviderCustomSubtitle;

  /// No description provided for @searchProviderCloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud'**
  String get searchProviderCloud;

  /// No description provided for @searchProviderOnDevice.
  ///
  /// In en, this message translates to:
  /// **'On-device'**
  String get searchProviderOnDevice;

  /// No description provided for @searchProviderDimensions.
  ///
  /// In en, this message translates to:
  /// **'{dims} dimensions'**
  String searchProviderDimensions(int dims);

  /// No description provided for @searchProviderServedBy.
  ///
  /// In en, this message translates to:
  /// **'Searches are still served by {provider}'**
  String searchProviderServedBy(String provider);

  /// No description provided for @searchProviderEndpoint.
  ///
  /// In en, this message translates to:
  /// **'Endpoint URL'**
  String get searchProviderEndpoint;

  /// No description provided for @searchProviderEndpointHelp.
  ///
  /// In en, this message translates to:
  /// **'Full base URL, e.g. http://localhost:11434/v1'**
  String get searchProviderEndpointHelp;

  /// No description provided for @searchProviderModelName.
  ///
  /// In en, this message translates to:
  /// **'Model name'**
  String get searchProviderModelName;

  /// No description provided for @searchProviderDimensionsField.
  ///
  /// In en, this message translates to:
  /// **'Dimensions'**
  String get searchProviderDimensionsField;

  /// No description provided for @searchProviderDimensionsHelp.
  ///
  /// In en, this message translates to:
  /// **'Verified by the connection test'**
  String get searchProviderDimensionsHelp;

  /// No description provided for @searchProviderApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get searchProviderApiKey;

  /// No description provided for @searchProviderApiKeyHelp.
  ///
  /// In en, this message translates to:
  /// **'Optional — leave empty for keyless self-hosted endpoints'**
  String get searchProviderApiKeyHelp;

  /// Shown when the key field was prefilled from an already-configured chat model that talks to the same provider
  ///
  /// In en, this message translates to:
  /// **'Prefilled from your {model} chat model — replace it if this endpoint needs a different key.'**
  String searchProviderApiKeyFromChat(String model);

  /// Validation hint for the custom-provider form: an empty endpoint or model name cannot be probed or stored
  ///
  /// In en, this message translates to:
  /// **'Enter an endpoint URL and a model name before testing.'**
  String get searchProviderFieldsRequired;

  /// No description provided for @searchGetApiKey.
  ///
  /// In en, this message translates to:
  /// **'Get an API key'**
  String get searchGetApiKey;

  /// No description provided for @searchTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get searchTestConnection;

  /// No description provided for @searchTestOk.
  ///
  /// In en, this message translates to:
  /// **'Connection OK — {dims}-dimensional vectors'**
  String searchTestOk(int dims);

  /// No description provided for @searchTestDimensionsCorrected.
  ///
  /// In en, this message translates to:
  /// **'Dimensions corrected to {dims} to match the endpoint'**
  String searchTestDimensionsCorrected(int dims);

  /// No description provided for @searchTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {error}'**
  String searchTestFailed(String error);

  /// No description provided for @searchTestRequired.
  ///
  /// In en, this message translates to:
  /// **'Run the connection test before enabling this provider.'**
  String get searchTestRequired;

  /// No description provided for @searchProviderEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get searchProviderEnable;

  /// No description provided for @searchProviderEnabled.
  ///
  /// In en, this message translates to:
  /// **'{provider} enabled'**
  String searchProviderEnabled(String provider);

  /// No description provided for @searchProviderTurnedOff.
  ///
  /// In en, this message translates to:
  /// **'Semantic search off — stored vectors were kept'**
  String get searchProviderTurnedOff;

  /// No description provided for @searchConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Send note text to {provider}?'**
  String searchConsentTitle(String provider);

  /// No description provided for @searchConsentBody.
  ///
  /// In en, this message translates to:
  /// **'About {chunks} chunks of note text will be sent to {provider} to build the semantic index.'**
  String searchConsentBody(int chunks, String provider);

  /// No description provided for @searchConsentBodyWithImages.
  ///
  /// In en, this message translates to:
  /// **'About {chunks} chunks of note text and {images} images will be sent to {provider} to build the semantic index.'**
  String searchConsentBodyWithImages(int chunks, int images, String provider);

  /// Consent body when nothing is chunked yet (fresh install): an estimate of 0 would understate what actually uploads once chunking runs
  ///
  /// In en, this message translates to:
  /// **'Your notes will be sent to {provider} as they are indexed, to build the semantic index.'**
  String searchConsentBodyUnknown(String provider);

  /// No description provided for @searchConsentLargePdfsExcluded.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 large PDF stays excluded and is not sent.} other{{count} large PDFs stay excluded and are not sent.}}'**
  String searchConsentLargePdfsExcluded(int count);

  /// No description provided for @searchConsentWifiOnly.
  ///
  /// In en, this message translates to:
  /// **'Bulk indexing runs on Wi-Fi only by default; search queries may use any network.'**
  String get searchConsentWifiOnly;

  /// No description provided for @searchConsentSwitchDisclosure.
  ///
  /// In en, this message translates to:
  /// **'Until re-indexing completes, searches will continue to use {provider}.'**
  String searchConsentSwitchDisclosure(String provider);

  /// No description provided for @searchConsentStopServing.
  ///
  /// In en, this message translates to:
  /// **'Stop using {provider} now'**
  String searchConsentStopServing(String provider);

  /// No description provided for @searchConsentStoppedServing.
  ///
  /// In en, this message translates to:
  /// **'{provider} is no longer used — keyword search until re-indexing completes'**
  String searchConsentStoppedServing(String provider);

  /// No description provided for @searchConsentAccept.
  ///
  /// In en, this message translates to:
  /// **'Send and index'**
  String get searchConsentAccept;

  /// No description provided for @searchErrorAuth.
  ///
  /// In en, this message translates to:
  /// **'{provider} rejected the key — indexing is halted until it is fixed'**
  String searchErrorAuth(String provider);

  /// No description provided for @searchErrorNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'{provider} is not on this device yet'**
  String searchErrorNotInstalled(String provider);

  /// No description provided for @searchErrorDimensions.
  ///
  /// In en, this message translates to:
  /// **'The endpoint\'s vector size does not match the configured dimensions'**
  String get searchErrorDimensions;

  /// No description provided for @searchErrorHalted.
  ///
  /// In en, this message translates to:
  /// **'Embedding halted'**
  String get searchErrorHalted;

  /// No description provided for @searchErrorFailedChunks.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 chunk could not be embedded} other{{count} chunks could not be embedded}}'**
  String searchErrorFailedChunks(int count);

  /// Explains why the per-chunk failure tile offers Rebuild index rather than a plain Retry: the retry path only clears stage-level halts
  ///
  /// In en, this message translates to:
  /// **'These are retried by a rebuild — nothing else re-checks them.'**
  String get searchErrorFailedChunksHint;

  /// No description provided for @searchFixKey.
  ///
  /// In en, this message translates to:
  /// **'Fix key'**
  String get searchFixKey;

  /// No description provided for @searchDownloadModel.
  ///
  /// In en, this message translates to:
  /// **'Download model'**
  String get searchDownloadModel;

  /// No description provided for @searchDownloadModelHint.
  ///
  /// In en, this message translates to:
  /// **'Download the model below, then test again.'**
  String get searchDownloadModelHint;

  /// No description provided for @searchRetryStarted.
  ///
  /// In en, this message translates to:
  /// **'Retrying indexing…'**
  String get searchRetryStarted;

  /// No description provided for @searchWifiOnly.
  ///
  /// In en, this message translates to:
  /// **'Index on Wi-Fi only'**
  String get searchWifiOnly;

  /// No description provided for @searchWifiOnlySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Bulk embedding waits for Wi-Fi. Searching always works.'**
  String get searchWifiOnlySubtitle;

  /// No description provided for @searchLocalModelSection.
  ///
  /// In en, this message translates to:
  /// **'On-device model'**
  String get searchLocalModelSection;

  /// No description provided for @searchLocalModelInstalled.
  ///
  /// In en, this message translates to:
  /// **'Installed on this device'**
  String get searchLocalModelInstalled;

  /// No description provided for @searchLocalModelNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded yet'**
  String get searchLocalModelNotInstalled;

  /// No description provided for @searchHuggingFaceToken.
  ///
  /// In en, this message translates to:
  /// **'HuggingFace access token'**
  String get searchHuggingFaceToken;

  /// No description provided for @searchHuggingFaceTokenHelp.
  ///
  /// In en, this message translates to:
  /// **'Required — this model\'s repository is gated'**
  String get searchHuggingFaceTokenHelp;

  /// No description provided for @searchGetHfToken.
  ///
  /// In en, this message translates to:
  /// **'Get a token'**
  String get searchGetHfToken;

  /// No description provided for @searchInstallModel.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get searchInstallModel;

  /// No description provided for @searchUninstallModel.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get searchUninstallModel;

  /// No description provided for @searchInstallProgress.
  ///
  /// In en, this message translates to:
  /// **'Downloading — {percent}%'**
  String searchInstallProgress(int percent);

  /// No description provided for @searchInstallAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'Download rejected — accept the model licence on HuggingFace and check your token. {error}'**
  String searchInstallAuthFailed(String error);

  /// No description provided for @searchInstallTransientFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed — check the connection and try again. {error}'**
  String searchInstallTransientFailed(String error);

  /// No description provided for @searchInstallFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {error}'**
  String searchInstallFailed(String error);

  /// No description provided for @searchModelInstalled.
  ///
  /// In en, this message translates to:
  /// **'Model downloaded'**
  String get searchModelInstalled;

  /// No description provided for @searchModelRemoved.
  ///
  /// In en, this message translates to:
  /// **'Model removed'**
  String get searchModelRemoved;

  /// No description provided for @searchRebuildIndex.
  ///
  /// In en, this message translates to:
  /// **'Rebuild index'**
  String get searchRebuildIndex;

  /// No description provided for @searchRebuildSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Re-check every note and attachment'**
  String get searchRebuildSubtitle;

  /// No description provided for @searchRebuildRunning.
  ///
  /// In en, this message translates to:
  /// **'Rebuilding — {percent}%'**
  String searchRebuildRunning(int percent);

  /// No description provided for @searchRebuildConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Rebuild the search index?'**
  String get searchRebuildConfirmTitle;

  /// No description provided for @searchRebuildConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'{notes} notes and {chunks} chunks will be re-checked.'**
  String searchRebuildConfirmBody(int notes, int chunks);

  /// No description provided for @searchRebuildConfirmCost.
  ///
  /// In en, this message translates to:
  /// **'Chunks whose text changed are sent to {provider} again; unchanged chunks are not re-embedded.'**
  String searchRebuildConfirmCost(String provider);

  /// No description provided for @searchRebuildStarted.
  ///
  /// In en, this message translates to:
  /// **'Rebuilding the search index…'**
  String get searchRebuildStarted;

  /// No description provided for @searchDeleteEmbeddings.
  ///
  /// In en, this message translates to:
  /// **'Delete stored embeddings'**
  String get searchDeleteEmbeddings;

  /// No description provided for @searchDeleteEmbeddingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Frees storage and erases every vector. Turning a provider off keeps them.'**
  String get searchDeleteEmbeddingsSubtitle;

  /// No description provided for @searchDeleteEmbeddingsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete every stored embedding? This also turns the embedding provider off, so nothing is re-uploaded behind your back — search falls back to keywords until you pick a provider again.'**
  String get searchDeleteEmbeddingsConfirm;

  /// No description provided for @searchEmbeddingsDeleted.
  ///
  /// In en, this message translates to:
  /// **'Stored embeddings deleted — provider turned off'**
  String get searchEmbeddingsDeleted;

  /// No description provided for @searchOcrEnabled.
  ///
  /// In en, this message translates to:
  /// **'Recognize text in PDFs and images'**
  String get searchOcrEnabled;

  /// No description provided for @searchOcrOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Runs on-device — nothing is uploaded'**
  String get searchOcrOnDevice;

  /// No description provided for @searchOcrScript.
  ///
  /// In en, this message translates to:
  /// **'Script'**
  String get searchOcrScript;

  /// No description provided for @searchOcrScriptAuto.
  ///
  /// In en, this message translates to:
  /// **'Automatic (follow device language)'**
  String get searchOcrScriptAuto;

  /// No description provided for @searchOcrScriptLatin.
  ///
  /// In en, this message translates to:
  /// **'Latin'**
  String get searchOcrScriptLatin;

  /// No description provided for @searchOcrScriptChinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese'**
  String get searchOcrScriptChinese;

  /// No description provided for @searchFigureIndexing.
  ///
  /// In en, this message translates to:
  /// **'Index figures and tables'**
  String get searchFigureIndexing;

  /// No description provided for @searchFigureIndexingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Extracts figures from PDFs so they can be found and shown in chat'**
  String get searchFigureIndexingSubtitle;

  /// No description provided for @searchFigureSkillHint.
  ///
  /// In en, this message translates to:
  /// **'Install the Figure Answers skill for better figure replies'**
  String get searchFigureSkillHint;

  /// No description provided for @searchPdfPageCap.
  ///
  /// In en, this message translates to:
  /// **'Large PDF limit'**
  String get searchPdfPageCap;

  /// No description provided for @searchPdfPageCapField.
  ///
  /// In en, this message translates to:
  /// **'Pages'**
  String get searchPdfPageCapField;

  /// No description provided for @searchPdfPageCapSubtitle.
  ///
  /// In en, this message translates to:
  /// **'PDFs longer than {pages} pages are skipped unless you opt them in'**
  String searchPdfPageCapSubtitle(int pages);

  /// No description provided for @searchLargePdfsSkipped.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 large PDF not indexed — review} other{{count} large PDFs not indexed — review}}'**
  String searchLargePdfsSkipped(int count);

  /// Overflow row when more skipped PDFs exist than the list renders
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more not shown} other{{count} more not shown}}'**
  String searchLargePdfsMore(int count);

  /// No description provided for @searchLargePdfPages.
  ///
  /// In en, this message translates to:
  /// **'{title} · {pages} pages'**
  String searchLargePdfPages(String title, int pages);

  /// No description provided for @searchIndexAnyway.
  ///
  /// In en, this message translates to:
  /// **'Index anyway'**
  String get searchIndexAnyway;

  /// No description provided for @searchLargePdfQueued.
  ///
  /// In en, this message translates to:
  /// **'{name} will be indexed'**
  String searchLargePdfQueued(String name);

  /// No description provided for @searchNoLargePdfs.
  ///
  /// In en, this message translates to:
  /// **'No PDFs are being skipped for size'**
  String get searchNoLargePdfs;

  /// Menu entry and dialog title for the per-attachment search index policy
  ///
  /// In en, this message translates to:
  /// **'Search indexing'**
  String get searchIndexOptions;

  /// Menu entry label when the attachment's search index policy differs from the defaults
  ///
  /// In en, this message translates to:
  /// **'Search indexing: customized'**
  String get searchIndexOptionsCustom;

  /// No description provided for @searchIndexOptionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose what may be extracted from {name} for search.'**
  String searchIndexOptionsSubtitle(String name);

  /// No description provided for @searchIndexPurgeWarning.
  ///
  /// In en, this message translates to:
  /// **'Turning an option off deletes what it already produced for this file — its search chunks, any figure crops rendered from it, and the vectors stored for semantic search.'**
  String get searchIndexPurgeWarning;

  /// No description provided for @searchIndexEmbedPurgeWarning.
  ///
  /// In en, this message translates to:
  /// **'Turning this off deletes the vectors already stored for this file, so it stops appearing in semantic search results.'**
  String get searchIndexEmbedPurgeWarning;

  /// No description provided for @searchIndexExtractText.
  ///
  /// In en, this message translates to:
  /// **'Extract the text layer'**
  String get searchIndexExtractText;

  /// No description provided for @searchIndexExtractTextSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Index the text already embedded in this PDF.'**
  String get searchIndexExtractTextSubtitle;

  /// No description provided for @searchIndexAnywayOverCap.
  ///
  /// In en, this message translates to:
  /// **'Index despite the page limit'**
  String get searchIndexAnywayOverCap;

  /// No description provided for @searchIndexOverCapSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{pages} pages — longer than the {cap}-page limit, so this PDF is skipped unless you opt it in.'**
  String searchIndexOverCapSubtitle(int pages, int cap);

  /// No description provided for @searchIndexAnywaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep indexing this PDF even when it is longer than the page limit.'**
  String get searchIndexAnywaySubtitle;

  /// No description provided for @searchIndexDeriveOnDevice.
  ///
  /// In en, this message translates to:
  /// **'Extract content on this device'**
  String get searchIndexDeriveOnDevice;

  /// No description provided for @searchIndexDeriveOnDeviceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Text recognition and figure crops, computed locally. Nothing is uploaded.'**
  String get searchIndexDeriveOnDeviceSubtitle;

  /// No description provided for @searchIndexEmbed.
  ///
  /// In en, this message translates to:
  /// **'Use for semantic search'**
  String get searchIndexEmbed;

  /// No description provided for @searchIndexEmbedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Send this file\'s indexed text to the embedding provider — or, when the provider accepts images, the images themselves: the figure crops rendered from it, or the image file.'**
  String get searchIndexEmbedSubtitle;

  /// No description provided for @searchIndexSvgOnly.
  ///
  /// In en, this message translates to:
  /// **'SVG attachments are indexed by file name and alt text only: there is no text layer to extract, and nothing to recognize or crop on this device. That text is still sent to the embedding provider unless you turn semantic search off below.'**
  String get searchIndexSvgOnly;

  /// No description provided for @searchIndexNotIndexable.
  ///
  /// In en, this message translates to:
  /// **'Note Synapse does not extract content from this file type. It stays findable through the note it is attached to.'**
  String get searchIndexNotIndexable;

  /// No description provided for @searchIndexUpdated.
  ///
  /// In en, this message translates to:
  /// **'Search indexing updated'**
  String get searchIndexUpdated;

  /// No description provided for @searchIndexUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update search indexing'**
  String get searchIndexUpdateFailed;

  /// No description provided for @searchExcludeNote.
  ///
  /// In en, this message translates to:
  /// **'Exclude from search'**
  String get searchExcludeNote;

  /// No description provided for @searchExcludeNoteConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Exclude this note from search?'**
  String get searchExcludeNoteConfirmTitle;

  /// No description provided for @searchExcludeNoteConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'The note and its attachments are removed from the search index, including text extracted from attachments and any figure crops rendered from them. Everything is indexed again if you turn this off.'**
  String get searchExcludeNoteConfirmBody;

  /// No description provided for @searchExcludeNoteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Exclude'**
  String get searchExcludeNoteConfirm;

  /// No description provided for @searchExcludeNoteExcluded.
  ///
  /// In en, this message translates to:
  /// **'Note excluded from search'**
  String get searchExcludeNoteExcluded;

  /// No description provided for @searchExcludeNoteIncluded.
  ///
  /// In en, this message translates to:
  /// **'Note will be indexed for search again'**
  String get searchExcludeNoteIncluded;

  /// No description provided for @searchExcludeNoteFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not update the search exclusion'**
  String get searchExcludeNoteFailed;
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
