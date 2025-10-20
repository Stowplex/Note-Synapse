// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '笔记突触';

  @override
  String get settings => '设置';

  @override
  String get appearance => '外观';

  @override
  String get appearanceSubtitle => '主题和显示设置';

  @override
  String get aiApi => 'AI API';

  @override
  String get aiApiSubtitle => '配置您的AI API密钥';

  @override
  String get darkMode => '深色模式';

  @override
  String get darkModeSubtitle => '在浅色和深色主题之间切换';

  @override
  String get apiKey => 'API密钥';

  @override
  String get loading => '加载中...';

  @override
  String get noApiKeyConfigured => '未配置API密钥';

  @override
  String get updateApiKey => '更新API密钥';

  @override
  String get updateApiKeySubtitle => '输入新的API密钥';

  @override
  String get resetApiKey => '重置API密钥';

  @override
  String get resetApiKeySubtitle => '清除当前API密钥并返回设置';

  @override
  String get currentApiKey => '当前API密钥';

  @override
  String get close => '关闭';

  @override
  String get enterNewApiKey => '输入您的新Gemini API密钥：';

  @override
  String get apiKeyLabel => 'API密钥';

  @override
  String get apiKeyHint => '在此输入您的API密钥';

  @override
  String get cancel => '取消';

  @override
  String get update => '更新';

  @override
  String get reset => '重置';

  @override
  String get resetApiKeyConfirmation => '这将清除您当前的API密钥并返回设置屏幕。您确定吗？';

  @override
  String get apiKeyUpdatedSuccessfully => 'API密钥更新成功';

  @override
  String errorUpdatingApiKey(Object error) {
    return '更新API密钥时出错：$error';
  }

  @override
  String errorResettingApiKey(Object error) {
    return '重置API密钥时出错：$error';
  }

  @override
  String get welcomeToNoteSynapse => '欢迎使用笔记突触';

  @override
  String get aiPoweredNoteTaking => '您的AI驱动笔记助手';

  @override
  String get setupRequired => '需要设置';

  @override
  String get setupRequiredDescription =>
      '要使用AI功能，您需要来自Google AI Studio的Gemini API密钥。';

  @override
  String get getApiKey => '获取API密钥';

  @override
  String get geminiApiKey => 'Gemini API密钥';

  @override
  String get continueButton => '继续';

  @override
  String get apiKeySecurityNote => '您的API密钥安全存储在您的设备上，从不共享。';

  @override
  String get pleaseEnterApiKey => '请输入API密钥';

  @override
  String failedToSaveApiKey(Object error) {
    return '保存API密钥失败：$error';
  }

  @override
  String get notes => '笔记';

  @override
  String get calendar => '日历';

  @override
  String get addNewContent => '添加新内容';

  @override
  String get newAiAction => '新AI操作';

  @override
  String get newAiActionSubtitle => '使用AI创建内容';

  @override
  String get newNote => '新笔记';

  @override
  String get newNoteSubtitle => '创建常规笔记';

  @override
  String get newTask => '新任务';

  @override
  String get newTaskSubtitle => '创建新任务';

  @override
  String get newVoice => '新语音';

  @override
  String get newVoiceSubtitle => '录制语音笔记';

  @override
  String get newPicture => '新图片';

  @override
  String get newPictureSubtitle => '从相机或图库添加图片';

  @override
  String get attachment => '附件';

  @override
  String get attachmentSubtitle => '添加文件附件';

  @override
  String get newNoteFromClipboard => '从剪贴板新建笔记';

  @override
  String get newNoteFromClipboardSubtitle => '从剪贴板内容创建笔记';

  @override
  String get recordingStarted => '录音已开始';

  @override
  String get failedToStartRecording => '开始录音失败。请检查麦克风权限。';

  @override
  String get failedToStartRecordingLinux =>
      '开始录音失败。请检查是否安装了gstreamer和PulseAudio。';

  @override
  String errorStartingRecording(Object error) {
    return '开始录音时出错：$error';
  }

  @override
  String get audioNoteSavedSuccessfully => '语音笔记保存成功！';

  @override
  String errorStoppingRecording(Object error) {
    return '停止录音时出错：$error';
  }

  @override
  String get selectImageSource => '选择图片源';

  @override
  String get chooseImageSource => '选择您想要添加图片的方式';

  @override
  String get camera => '相机';

  @override
  String get takePhoto => '拍照';

  @override
  String get gallery => '图库';

  @override
  String get imageNoteCreatedSuccessfully => '图片笔记创建成功！';

  @override
  String errorCreatingImageNote(Object error) {
    return '创建图片笔记时出错：$error';
  }

  @override
  String errorPickingImage(Object error) {
    return '选择图片时出错：$error';
  }

  @override
  String get clipboardIsEmpty => '剪贴板为空';

  @override
  String errorAccessingClipboard(Object error) {
    return '访问剪贴板时出错：$error';
  }

  @override
  String get unableToAccessFileData => '无法访问文件数据';

  @override
  String errorPickingFile(Object error) {
    return '选择文件时出错：$error';
  }

  @override
  String get fileNoteCreatedSuccessfully => '文件笔记创建成功！';

  @override
  String errorCreatingFileNote(Object error) {
    return '创建文件笔记时出错：$error';
  }

  @override
  String get recording => '录音中...';

  @override
  String get voiceNoteRecording => '语音笔记录音';

  @override
  String get recordingTapStop => '录音中... 完成后点击停止';

  @override
  String get recordingWillContinue => '录音将持续到您点击\"停止录音\"为止';

  @override
  String get startRecordingVoiceNote => '开始录制您的语音笔记';

  @override
  String get startRecording => '开始录制';

  @override
  String get stopRecording => '停止录制';

  @override
  String get language => '语言';

  @override
  String get languageSubtitle => '选择您的首选语言';

  @override
  String get english => 'English';

  @override
  String get chineseSimplified => '简体中文';

  @override
  String get languageChanged => '语言更改成功';

  @override
  String errorChangingLanguage(Object error) {
    return '更改语言时出错：$error';
  }

  @override
  String get selected => '已选择';

  @override
  String get linkSelectedNotes => '链接选中的笔记';

  @override
  String get deleteSelectedNotes => '删除选中的笔记';

  @override
  String get openAIAction => '打开AI操作';

  @override
  String get exitMultiSelectMode => '退出多选模式';

  @override
  String get searchNotes => '搜索笔记...';

  @override
  String get allNotes => '所有笔记';

  @override
  String get defaultNotes => '默认';

  @override
  String get pinnedNotes => '置顶';

  @override
  String get archivedNotes => '归档';

  @override
  String get filter => '筛选';

  @override
  String get noNotesFound => '未找到笔记';

  @override
  String get createFirstNote => '创建您的第一条笔记';

  @override
  String get timeline => '时间线';

  @override
  String get todo => '待办事项';

  @override
  String get today => '今天';

  @override
  String get noTasksForToday => '今天没有任务';

  @override
  String get noNotesForToday => '今天没有笔记';

  @override
  String get createFirstTask => '创建您的第一个任务';

  @override
  String get createFirstTimelineNote => '创建您的第一条时间线笔记';

  @override
  String get taskCompletion => '任务完成度';

  @override
  String get completed => '已完成';

  @override
  String get pending => '待处理';

  @override
  String get inProgress => '进行中';

  @override
  String get overdue => '已逾期';

  @override
  String get dueToday => '今天到期';

  @override
  String get dueTomorrow => '明天到期';

  @override
  String get dueThisWeek => '本周到期';

  @override
  String get dueNextWeek => '下周到期';

  @override
  String get dueThisMonth => '本月到期';

  @override
  String get dueNextMonth => '下月到期';

  @override
  String get overdueTasks => '逾期任务';

  @override
  String get dueTodayTasks => '今天到期';

  @override
  String get dueTomorrowTasks => '明天到期';

  @override
  String get dueThisWeekTasks => '本周到期';

  @override
  String get dueNextWeekTasks => '下周到期';

  @override
  String get dueThisMonthTasks => '本月到期';

  @override
  String get dueNextMonthTasks => '下月到期';

  @override
  String get noOverdueTasks => '没有逾期任务';

  @override
  String get noDueTodayTasks => '今天没有到期任务';

  @override
  String get noDueTomorrowTasks => '明天没有到期任务';

  @override
  String get noDueThisWeekTasks => '本周没有到期任务';

  @override
  String get noDueNextWeekTasks => '下周没有到期任务';

  @override
  String get noDueThisMonthTasks => '本月没有到期任务';

  @override
  String get noDueNextMonthTasks => '下月没有到期任务';

  @override
  String get aiActions => 'AI操作';

  @override
  String get selectAIAction => '选择AI操作';

  @override
  String get noteQa => '笔记问答';

  @override
  String get noteQaDescription => '对您选中的笔记提问';

  @override
  String get transformNote => '转换笔记';

  @override
  String get transformNoteDescription => '重写、重组或修改您的笔记';

  @override
  String get createNewNotes => '创建新笔记';

  @override
  String get createNewNotesDescription => '根据您的提示和上下文生成新笔记';

  @override
  String get enterYourPrompt => '输入您的提示：';

  @override
  String get attachFiles => '附加文件';

  @override
  String get answerOnlyFromNotes => '仅从选中的笔记中回答';

  @override
  String get process => '处理';

  @override
  String get processing => '处理中...';

  @override
  String get clearResponse => '清除响应';

  @override
  String get response => '响应';

  @override
  String get copyResponse => '复制响应';

  @override
  String get createNotesFromResponse => '从响应创建笔记';

  @override
  String get noFilesAttached => '未附加文件';

  @override
  String get filesAttached => '已附加文件';

  @override
  String get removeFile => '移除文件';

  @override
  String get addFiles => '添加文件';

  @override
  String get processingRequest => '正在处理您的请求...';

  @override
  String errorProcessingRequest(Object error) {
    return '处理请求时出错：$error';
  }

  @override
  String get responseCopied => '响应已复制到剪贴板';

  @override
  String get notesCreatedSuccessfully => '笔记创建成功！';

  @override
  String errorCreatingNotes(Object error) {
    return '创建笔记时出错：$error';
  }

  @override
  String get sharedContent => '共享内容';

  @override
  String get createNote => '创建笔记';

  @override
  String get appendToNote => '追加到笔记';

  @override
  String get selectNoteToAppend => '选择要追加的笔记';

  @override
  String get searchNotesToAppend => '搜索要追加到的笔记...';

  @override
  String get title => '标题';

  @override
  String get tags => '标签';

  @override
  String get addNewTag => '添加新标签';

  @override
  String get extractContent => '提取内容';

  @override
  String get extractingContent => '正在提取内容...';

  @override
  String get contentExtracted => '内容提取成功！';

  @override
  String errorExtractingContent(Object error) {
    return '提取内容时出错：$error';
  }

  @override
  String get noApiKeyForExtraction => '内容提取需要API密钥';

  @override
  String get urlDetected => '检测到URL';

  @override
  String get extractFromUrl => '从URL提取';

  @override
  String get contentType => '内容类型';

  @override
  String get text => '文本';

  @override
  String get url => 'URL';

  @override
  String get image => '图片';

  @override
  String get file => '文件';

  @override
  String get unknown => '未知';

  @override
  String get noNotesAvailable => '没有可用的笔记';

  @override
  String errorLoadingNotes(Object error) {
    return '加载笔记时出错：$error';
  }

  @override
  String get noteCreatedSuccessfully => '笔记创建成功！';

  @override
  String errorCreatingNote(Object error) {
    return '创建笔记时出错：$error';
  }

  @override
  String get noteUpdatedSuccessfully => '笔记更新成功！';

  @override
  String errorUpdatingNote(Object error) {
    return '更新笔记时出错：$error';
  }

  @override
  String get pinNote => '置顶笔记';

  @override
  String get unpinNote => '取消置顶';

  @override
  String get archiveNote => '归档笔记';

  @override
  String get unarchiveNote => '取消归档';

  @override
  String get editNote => '编辑笔记';

  @override
  String get saveChanges => '保存更改';

  @override
  String get discardChanges => '丢弃更改';

  @override
  String get deleteNote => '删除笔记';

  @override
  String get confirmDeleteNote => '您确定要删除这条笔记吗？';

  @override
  String get noteDeletedSuccessfully => '笔记删除成功！';

  @override
  String errorDeletingNote(Object error) {
    return '删除笔记时出错：$error';
  }

  @override
  String get addSubNote => '添加子笔记';

  @override
  String get subNotes => '子笔记';

  @override
  String get noSubNotes => '没有子笔记';

  @override
  String get addNewSubNote => '添加新子笔记';

  @override
  String get editSubNote => '编辑子笔记';

  @override
  String get deleteSubNote => '删除子笔记';

  @override
  String get confirmDeleteSubNote => '您确定要删除这条子笔记吗？';

  @override
  String get subNoteAddedSuccessfully => '子笔记添加成功！';

  @override
  String get subNoteUpdatedSuccessfully => '子笔记更新成功！';

  @override
  String get subNoteDeletedSuccessfully => '子笔记删除成功！';

  @override
  String errorAddingSubNote(Object error) {
    return '添加子笔记时出错：$error';
  }

  @override
  String errorUpdatingSubNote(Object error) {
    return '更新子笔记时出错：$error';
  }

  @override
  String errorDeletingSubNote(Object error) {
    return '删除子笔记时出错：$error';
  }

  @override
  String get scheduledAt => '计划时间';

  @override
  String get completeBy => '完成时间';

  @override
  String get dateValidationError => '完成时间必须在计划时间之后';

  @override
  String get relationships => '关系';

  @override
  String get linkedNotes => '关联笔记';

  @override
  String get noLinkedNotes => '没有关联笔记';

  @override
  String get addRelationship => '添加关系';

  @override
  String get removeRelationship => '移除关系';

  @override
  String get confirmRemoveRelationship => '您确定要移除这个关系吗？';

  @override
  String get relationshipAddedSuccessfully => '关系添加成功！';

  @override
  String get relationshipRemovedSuccessfully => '关系移除成功！';

  @override
  String errorAddingRelationship(Object error) {
    return '添加关系时出错：$error';
  }

  @override
  String errorRemovingRelationship(Object error) {
    return '移除关系时出错：$error';
  }

  @override
  String get audioRecording => '音频录制';

  @override
  String get playAudio => '播放音频';

  @override
  String get pauseAudio => '暂停音频';

  @override
  String get recordingInProgress => '正在录制...';

  @override
  String get audioRecordedSuccessfully => '音频录制成功！';

  @override
  String errorRecordingAudio(Object error) {
    return '录制音频时出错：$error';
  }

  @override
  String errorPlayingAudio(Object error) {
    return '播放音频时出错：$error';
  }

  @override
  String get noAudioAttachments => '没有音频附件';

  @override
  String get audioAttachment => '音频附件';

  @override
  String get duration => '持续时间';

  @override
  String get position => '位置';

  @override
  String get autoSave => '自动保存';

  @override
  String get saved => '已保存';

  @override
  String get unsaved => '未保存';

  @override
  String get saving => '保存中...';

  @override
  String get unsavedChanges => '未保存的更改';

  @override
  String get confirmDiscardChanges => '您有未保存的更改。确定要丢弃它们吗？';

  @override
  String get yes => '是';

  @override
  String get no => '否';

  @override
  String get start => '开始';

  @override
  String get due => '到期';

  @override
  String get yesterday => '昨天';

  @override
  String daysAgo(Object count) {
    return '$count天前';
  }

  @override
  String get subNote => '子笔记';

  @override
  String get addTag => '添加标签';

  @override
  String get noTagsYet => '暂无标签。点击\"添加标签\"来添加一些。';

  @override
  String get addLink => '添加链接';

  @override
  String get attach => '附加';

  @override
  String get recordAudio => '录制音频';

  @override
  String get status => '状态';

  @override
  String get toDo => '待办';

  @override
  String get cancelled => '已取消';

  @override
  String get scheduled => '计划';

  @override
  String get content => '内容';

  @override
  String get checkbox => '复选框';

  @override
  String get bold => '粗体';

  @override
  String get created => '创建';

  @override
  String get updated => '更新';

  @override
  String get markComplete => '标记完成';

  @override
  String get markIncomplete => '标记未完成';

  @override
  String get noLinkedNotesYet => '暂无关联笔记';

  @override
  String get tasks => '任务';

  @override
  String get month => '月';

  @override
  String get week => '周';

  @override
  String get twoWeeks => '2周';

  @override
  String get january => '1月';

  @override
  String get february => '2月';

  @override
  String get march => '3月';

  @override
  String get april => '4月';

  @override
  String get may => '5月';

  @override
  String get june => '6月';

  @override
  String get july => '7月';

  @override
  String get august => '8月';

  @override
  String get september => '9月';

  @override
  String get october => '10月';

  @override
  String get november => '11月';

  @override
  String get december => '12月';

  @override
  String get noTasksWithSelectedTags => '没有选中标签的任务';

  @override
  String get noNotesWithSelectedTags => '没有选中标签的笔记';

  @override
  String get noTasksWithSelectedTagsForThisDay => '这一天没有选中标签的任务';

  @override
  String get noNotesWithSelectedTagsForThisDay => '这一天没有选中标签的笔记';

  @override
  String get trySelectingDifferentTags => '尝试选择不同的标签';

  @override
  String get cannotOpenLink => '无法打开链接';

  @override
  String get errorOpeningLink => '打开链接时出错';

  @override
  String subtasksCompleted(Object completed, Object total) {
    return '已完成$completed/$total个子任务';
  }

  @override
  String get audioNote => '音频笔记';

  @override
  String get audioRecordingFrom => '音频录制来自';

  @override
  String get attachments => '附件';

  @override
  String get removeAttachment => '删除附件';

  @override
  String removeAttachmentConfirm(Object fileName) {
    return '您确定要从这个笔记中删除\"$fileName\"吗？';
  }

  @override
  String get attachmentRemoved => '附件已删除';

  @override
  String get errorRemovingAttachment => '删除附件时出错';

  @override
  String addedAttachments(Object count) {
    return '已添加$count个附件';
  }

  @override
  String get errorAddingAttachment => '添加附件时出错';

  @override
  String get recordingSavedAsAttachment => '录音已保存为附件';

  @override
  String get photoAddedToNote => '照片已添加到笔记';

  @override
  String errorTakingPhoto(Object error) {
    return '拍照时出错：$error';
  }

  @override
  String get removeAttachmentTooltip => '删除附件';

  @override
  String get share => '分享';

  @override
  String get shareNote => '分享笔记';

  @override
  String get shareNotes => '分享笔记';

  @override
  String get shareAsText => '分享为文本';

  @override
  String get copyToClipboard => '复制到剪贴板';

  @override
  String get shareSubNotesAndLinkedNotes => '分享子笔记和关联笔记';

  @override
  String get shareDialogTitle => '分享笔记';

  @override
  String get shareDialogDescription => '选择您想要分享选中笔记的方式';

  @override
  String get textCopiedToClipboard => '文本已复制到剪贴板';

  @override
  String errorCopyingToClipboard(Object error) {
    return '复制到剪贴板时出错：$error';
  }

  @override
  String errorSharingText(Object error) {
    return '分享文本时出错：$error';
  }

  @override
  String get selectFileLocation => '选择文件位置';

  @override
  String get saveAsMarkdown => '保存为Markdown';

  @override
  String get fileSavedSuccessfully => '文件保存成功';

  @override
  String errorSavingFile(Object error) {
    return '保存文件时出错：$error';
  }

  @override
  String get shareSelectedNotes => '分享选中的笔记';

  @override
  String get type => '类型';

  @override
  String get note => '笔记';

  @override
  String get task => '任务';

  @override
  String get createFilter => '创建筛选器';

  @override
  String get editFilter => '编辑筛选器';

  @override
  String get filterName => '筛选器名称';

  @override
  String get filterNameHint => '为此筛选器输入名称';

  @override
  String get includeText => '包含文本';

  @override
  String get includeTextHint => '在笔记中搜索的文本';

  @override
  String get includeTags => '包含标签';

  @override
  String get includeTagsHint => '选择要筛选的标签';

  @override
  String get includeArchivedNotes => '包含已归档笔记';

  @override
  String get create => '创建';

  @override
  String get selectTags => '选择标签';

  @override
  String get apply => '应用';

  @override
  String get deleteFilter => '删除筛选器';

  @override
  String deleteFilterConfirm(Object filterName) {
    return '您确定要删除\"$filterName\"吗？';
  }

  @override
  String get addFilter => '添加筛选器';

  @override
  String get delete => '删除';

  @override
  String get manageTags => '管理标签';

  @override
  String get tagManagement => '标签管理';

  @override
  String tagUsageCount(Object count) {
    return '$count条笔记';
  }

  @override
  String get deleteTag => '删除标签';

  @override
  String confirmDeleteTag(Object tagName) {
    return '您确定要删除标签\"$tagName\"吗？';
  }

  @override
  String confirmDeleteTagWarning(Object count) {
    return '这将从所有$count条关联笔记中移除该标签。此操作无法撤销。';
  }

  @override
  String get tagDeletedSuccessfully => '标签删除成功！';

  @override
  String errorDeletingTag(Object error) {
    return '删除标签时出错：$error';
  }

  @override
  String get noTagsAvailable => '没有可用的标签';

  @override
  String get tagUsage => '使用情况';

  @override
  String get deleteTags => '删除标签';

  @override
  String get dedupTags => '去重标签';

  @override
  String get dedupRules => '去重规则';

  @override
  String get addDedupRule => '添加去重规则';

  @override
  String get leftTag => '左侧标签';

  @override
  String get rightTag => '右侧标签';

  @override
  String get selectLeftTag => '选择左侧标签';

  @override
  String get selectRightTag => '选择右侧标签';

  @override
  String get swapTags => '交换标签';

  @override
  String get executeDedup => '执行';

  @override
  String get aiSuggestDedup => 'AI建议';

  @override
  String get noDedupRules => '暂无去重规则';

  @override
  String get addFirstDedupRule => '添加您的第一个去重规则';

  @override
  String dedupRuleValidationError(Object error) {
    return '无效的去重规则：$error';
  }

  @override
  String get dedupRulesExecutedSuccessfully => '去重规则执行成功！';

  @override
  String errorExecutingDedupRules(Object error) {
    return '执行去重规则时出错：$error';
  }

  @override
  String get aiSuggestingDedupRules => 'AI正在建议去重规则...';

  @override
  String errorGettingAiSuggestions(Object error) {
    return '获取AI建议时出错：$error';
  }

  @override
  String get confirmExecuteDedupRules => '您确定要执行这些去重规则吗？这将用右侧标签替换所有左侧标签，且无法撤销。';

  @override
  String get dedupRuleLeftTagDuplicate => '左侧标签在多个规则中出现';

  @override
  String get dedupRuleRightTagDuplicate => '右侧标签在多个规则中出现';

  @override
  String get dedupRuleCircularReference => '检测到循环引用';

  @override
  String get dedupRuleSelfReference => '不能将标签替换为自身';

  @override
  String get myApps => '我的应用';

  @override
  String get myAppsSubtitle => '创建和管理自定义应用程序';

  @override
  String get noUserApps => '还没有自定义应用';

  @override
  String get createFirstApp => '创建您的第一个自定义应用';

  @override
  String get createNewApp => '创建新应用';

  @override
  String get appName => '应用名称';

  @override
  String get appNameHint => '为您的应用输入名称';

  @override
  String get appDescription => '描述';

  @override
  String get appDescriptionHint => '描述您的应用的功能';

  @override
  String get appSteps => '步骤';

  @override
  String get appStepsHint => '描述您的应用应遵循的步骤';

  @override
  String get addStep => '添加步骤';

  @override
  String get removeStep => '删除步骤';

  @override
  String get stepHint => '输入步骤描述';

  @override
  String get createApp => '创建应用';

  @override
  String get creatingApp => '正在创建应用...';

  @override
  String get appCreatedSuccessfully => '应用创建成功';

  @override
  String get appCreationFailed => '应用创建失败';

  @override
  String get appCreated => '已创建';

  @override
  String get appCantCreate => '无法创建';

  @override
  String get reason => '原因';

  @override
  String get toApp => '到应用';

  @override
  String get console => '控制台';

  @override
  String get edit => '编辑';

  @override
  String get confirmDeleteApp => '您确定要删除此应用吗？';

  @override
  String get appDeletedSuccessfully => '应用删除成功！';

  @override
  String errorDeletingApp(Object error) {
    return '删除应用时出错：$error';
  }

  @override
  String get webViewNotSupported => 'Linux不支持WebView';

  @override
  String get webViewNotSupportedDescription => '用户定义的应用需要WebView，但Linux平台不支持';

  @override
  String get editApp => '编辑应用';

  @override
  String get appCode => '应用代码';

  @override
  String get editSuggestion => '编辑建议';

  @override
  String get editSuggestionHint => '描述您想要进行的更改';

  @override
  String get submitEdit => '提交编辑';

  @override
  String get editingApp => '正在编辑应用...';

  @override
  String get appEditSubmitted => '编辑提交成功！';

  @override
  String get appEditFailed => '应用编辑失败';

  @override
  String get newAppCreatedFromEdit => '从编辑创建新应用';

  @override
  String errorCreatingAppFromEdit(Object error) {
    return '从编辑创建应用时出错：$error';
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
  String get consoleOutput => '控制台输出';

  @override
  String get noConsoleOutput => '暂无控制台输出';

  @override
  String get clearConsole => '清除控制台';

  @override
  String get consoleOutputCopied => '控制台输出已复制到剪贴板';

  @override
  String get appState => '应用状态';

  @override
  String get saveState => '保存状态';

  @override
  String get loadState => '加载状态';

  @override
  String get stateSaved => '状态保存成功！';

  @override
  String get stateLoaded => '状态加载成功！';

  @override
  String errorSavingState(Object error) {
    return '保存状态时出错：$error';
  }

  @override
  String errorLoadingState(Object error) {
    return '加载状态时出错：$error';
  }

  @override
  String appGenerationPrompt(Object description, Object name, Object steps) {
    return '根据以下要求创建单页自包含HTML应用程序：\n\n应用名称：$name\n描述：$description\n步骤：$steps\n\n要求：\n1. HTML必须完全自包含，嵌入CSS和JavaScript\n2. 不要引用任何外部资源\n3. 在注释中记录目的、要求和方法\n4. 使用以下API与Flutter应用交互：\n   - Synapse.runQuery(sql: string) - 查询应用数据库\n   - Synapse.storeAppState(state) - 存储JSON序列化状态\n   - Synapse.loadAppState() - 加载保存的状态\n   - Synapse.chatAI(prompt) - 发送提示到AI并获取响应\n\n现在生成完整的HTML应用程序。';
  }

  @override
  String get deleteApp => '删除应用';

  @override
  String get aiDebugOverlay => 'AI调试覆盖层';

  @override
  String get aiDebugOverlaySubtitle => '查看AI请求/响应日志';

  @override
  String get aiDebugOverlayTitle => 'AI调试覆盖层';

  @override
  String get refreshLogs => '刷新日志';

  @override
  String get clearLogs => '清除日志';

  @override
  String get basic => '基础';

  @override
  String get advanced => '高级';

  @override
  String get addLibrary => '添加库';

  @override
  String get libraryName => '库名称';

  @override
  String get libraryNameHint => '输入库名称';

  @override
  String get libraryUsage => '用法';

  @override
  String get libraryUsageHint => '描述如何使用此库';

  @override
  String get libraryLink => '库链接';

  @override
  String get libraryLinkHint => '输入JavaScript库URL';

  @override
  String get removeLibrary => '删除库';

  @override
  String get removeLink => '删除链接';

  @override
  String get noAiLogsAvailable => '没有AI日志可用';

  @override
  String get aiLogsDescription => 'AI请求和响应将显示在这里';

  @override
  String get headers => '请求头';

  @override
  String get body => '请求体';

  @override
  String get statusCode => '状态码';

  @override
  String get error => '错误';

  @override
  String get importApp => '导入应用';

  @override
  String get viewApp => '查看应用';

  @override
  String get exportApp => '导出应用';

  @override
  String get exportAppDescription => '在导出前查看和更新应用信息。应用将保存为YAML文件，可以与他人分享或导入。';

  @override
  String get nameRequired => '名称为必填项';

  @override
  String get name => '名称';

  @override
  String get description => '描述';

  @override
  String get author => '作者';

  @override
  String get license => '许可证';

  @override
  String get save => '保存';

  @override
  String get private => '私有';

  @override
  String get appExportedSuccessfully => '应用导出成功';

  @override
  String errorExportingApp(Object error) {
    return '导出应用时出错：$error';
  }

  @override
  String get importProgress => '导入进度';

  @override
  String get importLog => '导入日志';

  @override
  String get copyLog => '复制日志';

  @override
  String get logCopiedToClipboard => '日志已复制到剪贴板';

  @override
  String importingFromFile(Object filePath) {
    return '从文件导入：$filePath';
  }

  @override
  String downloading(Object item) {
    return '下载中：$item';
  }

  @override
  String downloaded(Object item) {
    return '已下载：$item';
  }

  @override
  String failedToDownload(Object item, Object status) {
    return '下载失败：$item（状态：$status）';
  }

  @override
  String errorDownloading(Object error, Object item) {
    return '下载 $item 时出错：$error';
  }

  @override
  String get importComplete => '导入完成！';

  @override
  String get importCompletedSuccessfully => '导入成功完成！';

  @override
  String get readingYamlFile => '读取 YAML 文件...';

  @override
  String get validatingYamlStructure => '验证 YAML 结构...';

  @override
  String get processingAppData => '处理应用数据...';

  @override
  String get checkingForExistingApp => '检查现有应用...';

  @override
  String get creatingNewApp => '创建新应用...';

  @override
  String get downloadingLibraries => '下载库文件...';

  @override
  String get yamlFileReadSuccessfully => 'YAML 文件读取成功';

  @override
  String get yamlStructureValidated => 'YAML 结构验证通过';

  @override
  String get appDataExtracted => '应用数据已提取';

  @override
  String processingLibrary(Object libraryName) {
    return '处理库：$libraryName';
  }

  @override
  String downloadingLibrary(Object libraryName) {
    return '下载库：$libraryName...';
  }

  @override
  String downloadingDependency(Object fileName) {
    return '下载中：$fileName...';
  }

  @override
  String get errorYamlFilePathEmpty => '错误：YAML 文件路径为空';

  @override
  String get errorInvalidYamlFormat => '错误：无效的 YAML 格式 - 期望映射';

  @override
  String get errorMissingRequiredFields => '错误：YAML 中缺少必需字段';

  @override
  String get errorAppAlreadyExists => '错误：具有此 UUID 的应用已存在';

  @override
  String errorCreatingApp(Object error) {
    return '创建应用时出错：$error';
  }

  @override
  String errorImportingApp(Object error) {
    return '导入应用时出错：$error';
  }

  @override
  String get aiModelSettings => 'AI模型设置';

  @override
  String get currentModel => '当前模型';

  @override
  String get noModelSelected => '未选择模型';

  @override
  String get availableModels => '可用模型';

  @override
  String get configured => '已配置';

  @override
  String get notConfigured => '未配置';

  @override
  String get current => '当前';

  @override
  String get useModel => '使用模型';

  @override
  String get configureModel => '配置模型';

  @override
  String get resetModel => '重置模型';

  @override
  String switchedToModel(Object modelName) {
    return '已切换到$modelName';
  }

  @override
  String errorSwitchingModel(Object error) {
    return '切换模型时出错：$error';
  }

  @override
  String modelConfigurationUpdatedSuccessfully(Object modelName) {
    return '$modelName配置更新成功';
  }

  @override
  String resetModelConfiguration(Object modelName) {
    return '重置$modelName配置';
  }

  @override
  String resetModelConfigurationConfirmation(Object modelName) {
    return '您确定要重置$modelName的配置吗？这将清除所有设置并允许您重新配置模型。';
  }

  @override
  String modelConfigurationResetSuccessfully(Object modelName) {
    return '$modelName配置重置成功';
  }

  @override
  String errorResettingConfiguration(Object error) {
    return '重置配置时出错：$error';
  }

  @override
  String configureModelTitle(Object modelName) {
    return '配置$modelName';
  }

  @override
  String get loadPreset => '加载预设';

  @override
  String get selectPreset => '选择预设';

  @override
  String get unknownPreset => '未知预设';

  @override
  String get apiEndpoint => 'API端点';

  @override
  String get apiEndpointDescription => '输入OpenAI兼容的API端点URL';

  @override
  String get endpointUrl => '端点URL';

  @override
  String get endpointUrlHint => 'https://api.openai.com/v1/chat/completions';

  @override
  String get pleaseEnterEndpointUrl => '请输入端点URL';

  @override
  String get pleaseEnterValidUrl => '请输入有效的URL';

  @override
  String get modelName => '模型名称';

  @override
  String get modelNameDescription =>
      '输入要使用的模型名称（例如：gpt-4、gpt-3.5-turbo、claude-3-sonnet）';

  @override
  String get modelNameHint => 'gpt-4';

  @override
  String get pleaseEnterModelName => '请输入模型名称';

  @override
  String get displayName => '显示名称';

  @override
  String get displayNameDescription => '在应用中为此模型显示的自定义名称';

  @override
  String get displayNameHint => '我的自定义模型';

  @override
  String get tokenLimits => '令牌限制';

  @override
  String get tokenLimitsDescription => '配置此模型的最大输入和输出令牌数';

  @override
  String get maxInputTokens => '最大输入令牌';

  @override
  String get maxInputTokensHint => '100000';

  @override
  String get maxOutputTokens => '最大输出令牌';

  @override
  String get maxOutputTokensHint => '4000';

  @override
  String get required => '必填';

  @override
  String get mustBePositiveNumber => '必须是正数';

  @override
  String get modelCapabilities => '模型功能';

  @override
  String get modelCapabilitiesDescription => '选择此模型支持的功能';

  @override
  String get imageProcessing => '图像处理';

  @override
  String get imageProcessingDescription => '可以分析和理解图像';

  @override
  String get documentUnderstanding => '文档理解';

  @override
  String get documentUnderstandingDescription => '可以处理PDF和文档';

  @override
  String get audioProcessing => '音频处理';

  @override
  String get audioProcessingDescription => '可以转录和分析音频';

  @override
  String get videoProcessing => '视频处理';

  @override
  String get videoProcessingDescription => '可以分析视频内容';

  @override
  String get geminiModelDescription => 'Google最先进的模型，具有完整的多模态功能';

  @override
  String get openaiCompatibleModelDescription => '兼容OpenAI API端点，具有可配置功能';

  @override
  String get geminiModelDescriptionDetailed =>
      'Google最先进的模型，具有完整的多模态功能，包括文档理解。';

  @override
  String get openaiCompatibleModelDescriptionDetailed =>
      '兼容OpenAI API端点。配置端点URL并选择支持的功能。';

  @override
  String get geminiApiKeyDescription => '从Google AI Studio获取您的API密钥';

  @override
  String get openaiCompatibleApiKeyDescription => '从您的OpenAI兼容服务提供商获取API密钥';

  @override
  String errorConfiguringModel(Object error) {
    return '配置模型时出错：$error';
  }

  @override
  String get recovery => '恢复';

  @override
  String get recoverySubtitle => '备份和恢复您的笔记';

  @override
  String get exportAllNotes => '导出所有笔记';

  @override
  String get exportAllNotesDescription => '创建所有笔记和附件的完整备份';

  @override
  String get exporting => '导出中...';

  @override
  String get exportLogs => '导出日志';

  @override
  String get previousExports => '之前的导出';

  @override
  String get saveAgain => '再次保存';

  @override
  String get backupAllNotes => '备份所有笔记';

  @override
  String get backupAllNotesDescription => '创建所有笔记和附件的完整备份。备份将保存为可下载的zip文件。';

  @override
  String get creatingBackup => '正在创建备份...';

  @override
  String get backupLogs => '备份日志';

  @override
  String get previousBackups => '之前的备份';

  @override
  String get backup => '备份';

  @override
  String get startingBackupProcess => '开始备份过程...';

  @override
  String createdTempDirectory(Object path) {
    return '创建临时目录：$path';
  }

  @override
  String get forcingDatabaseCheckpoint => '强制数据库检查点...';

  @override
  String get databaseCopiedSuccessfully => '数据库复制成功';

  @override
  String get databaseFileNotFound => '未找到数据库文件';

  @override
  String get attachmentsDirectoryCopiedSuccessfully => '附件目录复制成功';

  @override
  String get noAttachmentsDirectoryFound => '未找到附件目录，创建空目录';

  @override
  String get updatingAttachmentPathsInCopiedDatabase => '更新复制数据库中的附件路径...';

  @override
  String get databaseConsistencyVerified => '数据库一致性已验证';

  @override
  String get creatingZipArchive => '创建zip压缩包...';

  @override
  String backupCompleted(Object path) {
    return '备份完成：$path';
  }

  @override
  String backupFailed(Object error) {
    return '备份失败：$error';
  }

  @override
  String foundAttachmentsWithAbsolutePaths(Object count) {
    return '找到$count个需要更新的绝对路径附件';
  }

  @override
  String copiedAndUpdated(Object original, Object unique) {
    return '已复制并更新：$original -> $unique';
  }

  @override
  String warningSourceFileNotFound(Object path) {
    return '警告：未找到源文件：$path';
  }

  @override
  String deletedBackup(Object name) {
    return '已删除备份：$name';
  }

  @override
  String errorDeletingBackup(Object error) {
    return '删除备份时出错：$error';
  }

  @override
  String backupFileNotFound(Object name) {
    return '未找到备份文件：$name';
  }

  @override
  String errorSavingBackupAgain(Object error) {
    return '再次保存备份时出错：$error';
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
}
