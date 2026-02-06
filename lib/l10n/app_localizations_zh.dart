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
  String get untitled => '无标题';

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
  String get aiPrompts => '提示词';

  @override
  String get aiPromptsSubtitle => '自定义AI提示词注入与覆写';

  @override
  String get aiConversationSettings => 'AI 会话';

  @override
  String get aiConversationSettingsSubtitle => '调整AI对话参数';

  @override
  String get aiConversationSettingsDescription =>
      '设置默认的工具调用次数，超过此次数时会提示你确认。每个会话仍可单独调整。';

  @override
  String get iterationLimitLabel => '工具迭代上限';

  @override
  String get iterationLimitValueLabel => '当前上限';

  @override
  String iterationLimitValue(Object count) {
    return '$count 次迭代';
  }

  @override
  String iterationLimitPrompt(Object count) {
    return '已达到允许的工具调用次数（$count）。要继续吗？';
  }

  @override
  String get iterationLimitContinue => '继续';

  @override
  String get iterationLimitAbort => '停止';

  @override
  String get iterationLimitDialogTitle => '允许更多迭代';

  @override
  String iterationLimitDialogDescription(Object currentLimit) {
    return '输入一个大于 $currentLimit 的数值，以提升该会话的上限。';
  }

  @override
  String get iterationLimitInputLabel => '新的最大次数';

  @override
  String iterationLimitHelper(Object minLimit) {
    return '最小允许值：$minLimit';
  }

  @override
  String iterationLimitDialogError(Object minLimit) {
    return '请输入大于 $minLimit 的数值。';
  }

  @override
  String iterationLimitUpdated(Object count) {
    return '迭代上限已更新为 $count';
  }

  @override
  String get settingsSaved => '设置已保存';

  @override
  String get agenticSettings => '智能代理设置';

  @override
  String get agenticSettingsSubtitle => '配置智能代理模式参数';

  @override
  String get compactionThreshold => '上下文压缩阈值';

  @override
  String get compactionThresholdDescription =>
      '触发上下文压缩的最大令牌数。运行时使用此值与模型上下文窗口的较小值。';

  @override
  String get findingLimit => '发现数量限制';

  @override
  String get findingLimitDescription => '每个任务提取用于综合的最大发现数量。';

  @override
  String get findingMaxWords => '发现详情字数';

  @override
  String get findingMaxWordsDescription => '每个发现的要点详情的最大字数。';

  @override
  String get maxTurns => 'Max Turns';

  @override
  String get maxTurnsDescription =>
      'Maximum number of iterations allowed per task.';

  @override
  String get turnIncrement => 'Turn Increment';

  @override
  String get turnIncrementDescription =>
      'Number of turns to add when resuming a paused task.';

  @override
  String turnsValue(Object count) {
    return '$count turns';
  }

  @override
  String get maxSubtaskDepth => '子任务最大深度';

  @override
  String get maxSubtaskDepthDescription => '子任务嵌套的最大深度。设置为 0 禁用子任务生成。';

  @override
  String get aiLogEntriesLimit => 'AI 日志条目上限';

  @override
  String get aiLogEntriesLimitDescription => '保留的最大 AI 日志条目数。';

  @override
  String get aiLogEntriesDisabled => '禁用';

  @override
  String get aiLogEntriesUnlimited => '无限制';

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
  String get checkIn => '签到';

  @override
  String get enterCheckInNote => '输入签到备注';

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
  String get system => '系统';

  @override
  String get systemSubtitle => '系统行为设置';

  @override
  String get keepScreenOn => '保持屏幕常亮';

  @override
  String get keepScreenOnSubtitle => '防止屏幕自动关闭';

  @override
  String get network => '网络';

  @override
  String get networkSubtitle => 'HTTP协议与重试设置';

  @override
  String get protocolPreference => '协议偏好';

  @override
  String get protocolPreferenceSubtitle => '选择网络请求的HTTP协议模式';

  @override
  String get protocolAuto => '自动（升级到HTTP/3）';

  @override
  String get protocolHttp3Only => '仅HTTP/3';

  @override
  String get protocolHttp11Only => '仅HTTP/1.1';

  @override
  String get retryCount => '重试次数';

  @override
  String get retryCountSubtitle => '请求失败时的重试次数（0-5）';

  @override
  String get backoffBase => '退避基数';

  @override
  String get backoffBaseSubtitle => '指数退避的基础延迟秒数（1-10）';

  @override
  String retryPattern(String base, String second, String third) {
    return '重试间隔：$base秒 → $second秒 → $third秒';
  }

  @override
  String get networkSettingsUpdated => '网络设置已更新';

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
  String get transformNoteHint => '描述您想要如何转换此笔记...';

  @override
  String get createNewNotesHint => '描述您想要创建的新笔记...';

  @override
  String get enterYourPrompt => '输入您的提示：';

  @override
  String get attachFiles => '附加文件';

  @override
  String get attachFile => '附加文件';

  @override
  String get selectFromDevice => '从设备选择';

  @override
  String get enterUri => '输入 URI';

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
  String get add => '添加';

  @override
  String get processingRequest => '正在处理您的请求...';

  @override
  String executingToolStatus(Object service, Object tool) {
    return '执行工具：$service -> $tool';
  }

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
  String get extractingContent => '提取内容中...';

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
  String noteCreatedSuccessfully(Object title) {
    return '笔记\"$title\"创建成功';
  }

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
  String get convertToNote => '转换为笔记';

  @override
  String get convertToTask => '转换为任务';

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
  String get reparentSubNote => '设置父笔记';

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
  String get shareAsPdf => '分享为 PDF';

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
  String notesToShare(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '个笔记',
      one: '个笔记',
    );
    return '待分享 $count $_temp0';
  }

  @override
  String get textCopiedToClipboard => '文本已复制到剪贴板';

  @override
  String errorCopyingToClipboard(String error) {
    return '复制到剪贴板时出错：$error';
  }

  @override
  String errorSharingText(String error) {
    return '分享文本时出错：$error';
  }

  @override
  String pdfSavedToCache(String fileName) {
    return 'PDF 已保存到缓存：$fileName';
  }

  @override
  String errorGeneratingPdf(String error) {
    return '生成 PDF 时出错：$error';
  }

  @override
  String get attachmentMissing => '找不到附件。';

  @override
  String get attachmentUnavailable => '附件不可用';

  @override
  String get pdfPreviewUnavailable => '暂不支持预览 PDF，请通过已保存的附件查看。';

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
  String get addTags => '添加标签';

  @override
  String get filterTags => '筛选标签';

  @override
  String get filterTagsDialog => '筛选标签';

  @override
  String filterTagsCount(int count) {
    return '$count个标签';
  }

  @override
  String get clearFilters => '清除筛选';

  @override
  String get applyFilters => '应用筛选';

  @override
  String get clearTags => '清除标签';

  @override
  String applyTagsWithCount(int count) {
    return '应用$count个标签';
  }

  @override
  String get addTagsCapitalized => '添加标签';

  @override
  String addTagsWithCount(int count) {
    return '添加$count个标签';
  }

  @override
  String get searchTags => '搜索标签';

  @override
  String get searchTagsCapitalized => '搜索标签';

  @override
  String get addNewTagOrSearch => '添加新标签或搜索';

  @override
  String get tagManagement => '标签管理';

  @override
  String tagUsageCount(Object conversationCount, Object noteCount) {
    return '$noteCount条笔记 / $conversationCount个会话';
  }

  @override
  String get deleteTag => '删除标签';

  @override
  String confirmDeleteTag(Object tagName) {
    return '您确定要删除标签\"$tagName\"吗？';
  }

  @override
  String confirmDeleteTagWarning(Object conversationCount, Object noteCount) {
    return '这将从$noteCount条关联笔记和$conversationCount个会话中移除该标签。此操作无法撤销。';
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
  String get searchApps => '搜索应用...';

  @override
  String get noAppsFound => '未找到应用';

  @override
  String get tryAdjustingSearchTerms => '请尝试调整搜索词';

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
  String get saveCode => '保存代码';

  @override
  String get saveCodeDirectly => '直接保存代码';

  @override
  String get codeSavedSuccessfully => '代码保存成功！';

  @override
  String errorSavingCode(Object error) {
    return '保存代码时出错：$error';
  }

  @override
  String get editCodeDirectly => '直接编辑代码';

  @override
  String get editAppName => '编辑应用名称';

  @override
  String get appNameUpdated => '应用名称更新成功！';

  @override
  String errorUpdatingAppName(Object error) {
    return '更新应用名称时出错：$error';
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
  String get manageAppState => '管理应用状态';

  @override
  String get clearState => '清除状态';

  @override
  String get stateCleared => '状态清除成功！';

  @override
  String get noState => '无状态';

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
  String get aiLogs => 'AI 日志';

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
  String get supportedAttachmentMimeTypesLabel => '支持的附件 MIME 类型';

  @override
  String get supportedAttachmentMimeTypesHint => '例如 image/png、application/pdf';

  @override
  String get supportedAttachmentMimeTypesHelper => '使用逗号或换行分隔。留空则使用模型预设值。';

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
  String get promptSettingsTitle => '提示词配置';

  @override
  String get promptSettingsDescription =>
      '自定义 Note Synapse 生成提示词的方式。留空则使用默认说明。';

  @override
  String get promptSettingsSave => '保存';

  @override
  String get promptSettingsReset => '重置';

  @override
  String promptSettingsSaved(String entryTitle) {
    return '已保存$entryTitle的提示词';
  }

  @override
  String promptSettingsCleared(String entryTitle) {
    return '已清除$entryTitle的提示词';
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
  String get importBackup => '导入备份';

  @override
  String get importBackupDescription => '从备份文件恢复您的笔记';

  @override
  String get importingBackup => '正在导入备份...';

  @override
  String get importLogs => '导入日志';

  @override
  String get selectBackupFile => '选择备份文件';

  @override
  String get selectBackupFileDescription => '选择要恢复的备份zip文件';

  @override
  String importFailed(Object error) {
    return '导入失败：$error';
  }

  @override
  String get invalidBackupFile => '无效的备份文件格式';

  @override
  String get backupVersionTooNew => '备份来自较新版本的应用。请先更新应用。';

  @override
  String get checkpointingDatabase => '检查点当前数据库...';

  @override
  String get copyingDatabaseToStaging => '复制数据库到暂存目录...';

  @override
  String get extractingBackupFile => '提取备份文件...';

  @override
  String get validatingBackupDatabase => '验证备份数据库版本...';

  @override
  String get migratingBackupDatabase => '将备份数据库迁移到当前版本...';

  @override
  String get mergingNotes => '合并笔记...';

  @override
  String get mergingSubNotes => '合并子笔记...';

  @override
  String get mergingTags => '合并标签...';

  @override
  String get mergingRelationships => '合并关系...';

  @override
  String get mergingFilters => '合并筛选器...';

  @override
  String get mergingUserApps => '合并用户应用...';

  @override
  String get copyingAttachments => '复制附件...';

  @override
  String get swappingDatabases => '交换数据库...';

  @override
  String get reloadingData => '重新加载数据...';

  @override
  String get undoBackup => '撤销备份';

  @override
  String get undoBackupDescription => '恢复原始数据库';

  @override
  String get undoBackupConfirmation => '您确定要撤销备份吗？这将恢复您的原始数据库并丢失自导入以来所做的任何更改。';

  @override
  String get undoBackupCompleted => '备份撤销成功！';

  @override
  String errorUndoingBackup(Object error) {
    return '撤销备份时出错：$error';
  }

  @override
  String get backupRestored => '备份恢复成功！';

  @override
  String errorRestoringBackup(Object error) {
    return '恢复备份时出错：$error';
  }

  @override
  String get cloneApp => '复制应用';

  @override
  String get appClonedSuccessfully => '复制成功!';

  @override
  String errorCloningApp(Object error) {
    return '复制出错: $error';
  }

  @override
  String get mcpSettings => 'MCP设置';

  @override
  String get mcpSettingsSubtitle => '配置模型上下文协议端点';

  @override
  String errorLoadingEndpoints(Object error) {
    return '加载端点时出错：$error';
  }

  @override
  String get addMcpEndpoint => '添加MCP端点';

  @override
  String get addMcpEndpointTitle => '添加MCP端点';

  @override
  String get nameHint => '我的MCP服务器';

  @override
  String get baseUrl => '基础URL';

  @override
  String get baseUrlHint =>
      'https://api.example.com 或 https://server.smithery.ai/@user/server/mcp?api_key=xxx';

  @override
  String get baseUrlHelperText => '如需要，请包含认证查询参数（例如：Smithery）';

  @override
  String get builtInTools => 'Built-in Tools';

  @override
  String get transportType => '传输类型';

  @override
  String get bearerTokenOptional => 'Bearer令牌（可选）';

  @override
  String get bearerTokenHint => '如果认证在URL参数中，请留空';

  @override
  String get bearerTokenHelperText => '可选：用于基于头的认证';

  @override
  String get pleaseProvideNameAndUrl => '请提供名称和URL';

  @override
  String addedEndpoint(Object name) {
    return '已添加端点：$name';
  }

  @override
  String errorAddingEndpoint(Object error) {
    return '错误：$error';
  }

  @override
  String get deleteEndpoint => '删除端点';

  @override
  String deleteEndpointConfirmation(Object name) {
    return '您确定要删除\"$name\"吗？这将同时删除缓存的工具。';
  }

  @override
  String deletedEndpoint(Object name) {
    return '已删除端点：$name';
  }

  @override
  String errorDeletingEndpoint(Object error) {
    return '删除端点时出错：$error';
  }

  @override
  String get onboardingWelcomeTitle => '欢迎使用笔记突触';

  @override
  String get onboardingWelcomeSubtitle => '您的AI第二大脑';

  @override
  String get onboardingChooseModelTitle => '选择您的AI模型';

  @override
  String get onboardingChooseModelSubtitle => '选择最适合您需求的AI模型';

  @override
  String get onboardingStart => '开始使用';

  @override
  String get onboardingNext => '下一步';

  @override
  String get onboardingSkip => '跳过';

  @override
  String get onboardingLicenseTitle => '许可协议';

  @override
  String get onboardingLicenseSubtitle => '请阅读并接受许可协议';

  @override
  String get onboardingPrivacyTitle => '隐私政策';

  @override
  String get onboardingPrivacySubtitle => '我们如何处理您的数据';

  @override
  String get onboardingAccept => '接受并继续';

  @override
  String get onboardingConfigLater => '稍后配置';

  @override
  String get about => '关于';

  @override
  String get aboutSubtitle => '许可证、隐私政策与版本信息';

  @override
  String get version => '版本';

  @override
  String get info => '信息';

  @override
  String get applicationInfo => '应用信息';

  @override
  String get githubPage => 'GitHub 页面';

  @override
  String get viewLicense => '查看许可证';

  @override
  String get viewPrivacyPolicy => '查看隐私政策';

  @override
  String get stowplexCopyright => 'Stowplex LLC & Bruce Li 保留所有权利';

  @override
  String get noWarranty => '无担保声明';

  @override
  String get debugMenu => '调试菜单';

  @override
  String get resetOnboarding => '重置引导页标志';

  @override
  String get resetOnboardingSuccess => '引导页标志已重置';

  @override
  String get dependencyLicenses => '依赖库许可证';

  @override
  String refreshedToolsFor(Object name) {
    return '已刷新$name的工具';
  }

  @override
  String get bookmarkPage => 'Bookmark Page';

  @override
  String get page => 'Page';

  @override
  String get removeBookmark => 'Remove Bookmark';

  @override
  String get bookmarks => 'Bookmarks';

  @override
  String get addBookmark => 'Add Bookmark';

  @override
  String get editBookmark => 'Edit Bookmark';

  @override
  String get bookmarkAnnotationHint => 'Enter annotation (max 200 chars)';

  @override
  String get noBookmarksYet => 'No bookmarks yet';

  @override
  String get aiContextBookmarks => 'AI Context: Bookmarks';

  @override
  String get configureAiContext => 'Configure AI Context';

  @override
  String aiContext(String mode) {
    return 'AI Context: $mode';
  }

  @override
  String get aiContextFullPdf => 'Full PDF';

  @override
  String get aiContextWindow => 'Window';

  @override
  String get aiContextChapters => 'Chapters';

  @override
  String get windowSize => 'Window Size';

  @override
  String get pagesBeforeAfter => 'Pages before/after';

  @override
  String errorRefreshingTools(Object error) {
    return '刷新工具时出错：$error';
  }

  @override
  String get tools => '工具';

  @override
  String get markAllAs => '全部标记为';

  @override
  String get archiveAll => '全部归档';

  @override
  String get unarchiveAll => '全部取消归档';

  @override
  String get selectAll => '全选';

  @override
  String get deselectAll => '取消全选';

  @override
  String get noteType => 'Note Type';

  @override
  String get excludeTags => 'Exclude Tags';

  @override
  String get excludeTagsHint => 'Select tags to exclude';

  @override
  String get selectTagsToExclude => 'Select Tags to Exclude';

  @override
  String toolsFor(Object name) {
    return '工具 - $name';
  }

  @override
  String get fetched => '获取时间';

  @override
  String toolsCount(Object count) {
    return '工具：$count';
  }

  @override
  String get noToolsAvailable => '没有可用工具';

  @override
  String get multiFunction => '多功能';

  @override
  String get addToMultiFunction => '添加到多功能标签页';

  @override
  String get removeFromMultiFunction => '从多功能视图移除';

  @override
  String get setAsDefaultView => '设为默认视图';

  @override
  String get defaultView => '默认视图';

  @override
  String get appAddedToMultiFunction => '应用已添加到多功能标签页';

  @override
  String get appRemovedFromMultiFunction => '应用已从多功能标签页移除';

  @override
  String get defaultViewUpdated => '默认视图已更新';

  @override
  String get selectView => '选择视图';

  @override
  String get switchToCalendar => '切换到日历';

  @override
  String get rawDataManager => '原始数据管理';

  @override
  String get rawDataManagerSubtitle => '用于文件和数据库管理的高级工具';

  @override
  String get files => '文件';

  @override
  String get database => '数据库';

  @override
  String get tables => '表';

  @override
  String get query => '查询';

  @override
  String get executeQuery => '执行查询';

  @override
  String get noData => '无数据';

  @override
  String rowsAffected(Object count) {
    return '$count 行受影响';
  }

  @override
  String errorExecutingQuery(Object error) {
    return '执行查询时出错：$error';
  }

  @override
  String get tableSchema => '表结构';

  @override
  String get columns => '列';

  @override
  String get indexes => '索引';

  @override
  String get foreignKeys => '外键';

  @override
  String get browseTable => '浏览表';

  @override
  String get refresh => '刷新';

  @override
  String get download => '下载';

  @override
  String get deleteFile => '删除文件';

  @override
  String confirmDeleteFile(Object fileName) {
    return '您确定要删除 \"$fileName\" 吗？';
  }

  @override
  String get fileDeletedSuccessfully => '文件删除成功';

  @override
  String errorDeletingFile(Object error) {
    return '删除文件时出错：$error';
  }

  @override
  String get uploadFile => '上传文件';

  @override
  String get fileUploadedSuccessfully => '文件上传成功';

  @override
  String errorUploadingFile(Object error) {
    return '上传文件时出错：$error';
  }

  @override
  String get createDirectory => '创建目录';

  @override
  String get directoryName => '目录名称';

  @override
  String get directoryCreatedSuccessfully => '目录创建成功';

  @override
  String errorCreatingDirectory(Object error) {
    return '创建目录时出错：$error';
  }

  @override
  String get path => '路径';

  @override
  String get size => '大小';

  @override
  String get modified => '修改时间';

  @override
  String get chat => '聊天';

  @override
  String get chatWithDatabase => '与数据库聊天';

  @override
  String get askQuestionAboutDatabase => '询问关于数据库的问题...';

  @override
  String get send => '发送';

  @override
  String get aiResponse => 'AI 响应';

  @override
  String errorSendingMessage(Object error) {
    return '发送消息时出错：$error';
  }

  @override
  String get thinking => '思考中...';

  @override
  String noToolsCachedFor(Object name) {
    return '没有为$name缓存工具。点击刷新以获取工具。';
  }

  @override
  String get addContextNotes => '添加上下文笔记';

  @override
  String get libraries => '库';

  @override
  String get noLibraries => '没有库';

  @override
  String get usageInstructions => '使用说明';

  @override
  String get libraryLinks => '库链接';

  @override
  String get editUserApp => '编辑应用';

  @override
  String get viewCode => '查看代码';

  @override
  String get editCode => '编辑代码';

  @override
  String get code => '代码';

  @override
  String get aiEdit => 'AI 编辑';

  @override
  String get pleaseEnterSuggestion => '请输入建议';

  @override
  String get refreshTools => '刷新工具';

  @override
  String get viewTools => '查看工具';

  @override
  String get noMcpEndpointsConfigured => '未配置MCP端点';

  @override
  String get clickAddMcpEndpointToGetStarted => '点击\"添加MCP端点\"开始';

  @override
  String get noteActionApp => '笔记操作应用';

  @override
  String get noteActionApps => '笔记操作应用';

  @override
  String get noteActionAppSubtitle => '此类应用将专门对预选笔记进行操作';

  @override
  String get appType => '类型';

  @override
  String get appTypeHint => '选择此应用的行为方式';

  @override
  String get appTypeNormal => '普通';

  @override
  String get appTypeNoteAction => '笔记操作';

  @override
  String get appTypeAiTool => 'AI 工具';

  @override
  String get aiToolAppSubtitle => '暴露自定义 JavaScript 函数供 AI 调用，并在操场中测试';

  @override
  String get aiTools => 'AI 工具';

  @override
  String get modelFeatures => '模型功能';

  @override
  String get featureGoogleSearch => 'Google 搜索';

  @override
  String get featureCodeExecution => '代码执行';

  @override
  String get featureWebSearch => '网页搜索';

  @override
  String aiToolStartError(String appName, String error) {
    return '无法启动 AI 工具“$appName”：$error';
  }

  @override
  String get aiToolMissingRevision => '此 AI 工具尚未选择版本。';

  @override
  String get aiToolDefinitionParseError => '所选版本不包含有效的 AI 工具规范。';

  @override
  String get imageAttachmentsOptional => '图片附件（可选）';

  @override
  String get imageAttachmentsSubtitle => '附加图片以帮助解释您希望AI创建的内容';

  @override
  String get addImage => '添加图片';

  @override
  String get noLibrariesAddedYet => '尚未添加库。点击\"添加库\"开始。';

  @override
  String get conversation => '对话';

  @override
  String get aiConversation => 'AI对话';

  @override
  String get aiConversationDescription => '与AI就您的笔记开始对话';

  @override
  String get startConversation => '开始对话';

  @override
  String get conversationTree => '对话树';

  @override
  String get conversations => '对话';

  @override
  String conversationCount(int count) {
    return '$count个对话';
  }

  @override
  String get noConversations => '无对话';

  @override
  String get conversationsWithThisNote => '此笔记的对话';

  @override
  String get typeYourMessage => '输入您的消息...';

  @override
  String get immersiveMode => '沉浸模式';

  @override
  String get openInChatMode => '在聊天模式中打开';

  @override
  String get aiChat => 'AI 对话';

  @override
  String get outline => '大纲';

  @override
  String get expand => '展开';

  @override
  String get collapse => '收起';

  @override
  String get annotate => '标注';

  @override
  String get askAiHint => '向 AI 询问有关数据库架构或错误的信息...';

  @override
  String get startConversationHint => '先向 AI 询问关于你的笔记。';

  @override
  String unsupportedAttachment(String type) {
    return '不支持的附件类型（$type）。';
  }

  @override
  String get openAttachment => '打开附件';

  @override
  String get failedToLoadAttachment => '加载附件失败。';

  @override
  String failedToOpenAttachment(String error) {
    return '无法打开附件：$error';
  }

  @override
  String get cancellingRequest => '正在取消请求...';

  @override
  String get takePhotoAttachment => '拍照';

  @override
  String get mcpTools => 'MCP工具';

  @override
  String get mcpAndLocalTools => 'MCP和本地工具';

  @override
  String get active => '活动';

  @override
  String toolsAvailable(Object count) {
    return '$count个工具可用';
  }

  @override
  String get manageNotes => '管理笔记';

  @override
  String get viewTree => '查看树';

  @override
  String noteIncluded(Object count) {
    return '包含$count个笔记';
  }

  @override
  String get messageCopiedToClipboard => '消息已复制到剪贴板';

  @override
  String get addToNote => '添加到笔记';

  @override
  String get forkConversation => '创建分支对话';

  @override
  String get forkConversationConfirm => '创建分支对话？';

  @override
  String get fork => '分支对话';

  @override
  String get forkedConversationSuccess => '对话分支成功';

  @override
  String errorForkingConversation(Object error) {
    return '分支对话时出错：$error';
  }

  @override
  String get selectNotesForConversation => '选择对话笔记';

  @override
  String get selectNotesForNoteActionApp => '选择笔记操作应用的笔记';

  @override
  String get selectNotesToAddToContext => '选择要添加到上下文的笔记';

  @override
  String proceedWithNotes(int count) {
    return '继续 $count 个笔记';
  }

  @override
  String notesSelected(int count) {
    return '已选择 $count 个笔记';
  }

  @override
  String noNotesFoundMatching(String query) {
    return '未找到匹配 \"$query\" 的笔记';
  }

  @override
  String get notesAndContext => '笔记和上下文';

  @override
  String get addNotes => '添加笔记';

  @override
  String get addNotesToConversation => '添加笔记';

  @override
  String get clearAllNotes => '清除全部';

  @override
  String get missingNotes => '缺失的笔记';

  @override
  String get missingNotesMessage => '此对话引用了不再存在的笔记：';

  @override
  String get missingNotesWillCleanup => '这些引用将被自动清理。';

  @override
  String get cleanUp => '清理';

  @override
  String get ok => '确定';

  @override
  String get refreshTree => '刷新树';

  @override
  String get noConversationsFound => '未找到对话。开始新对话以查看树。';

  @override
  String get treeRefreshedSuccessfully => '树刷新成功';

  @override
  String errorRefreshingTree(Object error) {
    return '刷新树时出错：$error';
  }

  @override
  String get selectInteractionToViewDetails => '选择交互以查看详细信息';

  @override
  String get deleteInteraction => '删除交互';

  @override
  String get deleteInteractionConfirm => '您确定要删除此交互及其所有后代吗？此操作无法撤消。';

  @override
  String get interactionDeletedSuccessfully => '交互删除成功';

  @override
  String errorDeletingInteraction(Object error) {
    return '删除交互时出错：$error';
  }

  @override
  String get forkFromHere => '从这里分叉';

  @override
  String get deleteInteractionAction => '删除交互';

  @override
  String get deleteConversation => '删除会话';

  @override
  String get confirmDeleteConversation => '您确定要删除此会话吗？此操作无法撤消。';

  @override
  String get conversationDeletedSuccessfully => '会话删除成功';

  @override
  String errorDeletingConversation(Object error) {
    return '删除会话时出错：$error';
  }

  @override
  String get saveSelectedNodesAsNote => '将选中的节点保存为笔记';

  @override
  String get createFromSelected => '从选中创建';

  @override
  String get exitMultiSelect => '退出多选';

  @override
  String get pleaseSelectNodesFirst => '请先选择节点';

  @override
  String get interaction => '交互';

  @override
  String get open => '打开';

  @override
  String get user => '用户';

  @override
  String get ai => 'AI';

  @override
  String get justNow => '刚刚';

  @override
  String get addNoteDialogTitle => '添加到笔记';

  @override
  String get addNoteDialogMessage => '您想如何将此内容添加到笔记？';

  @override
  String get addAsIs => '原样添加';

  @override
  String get addAsIsDescription => '直接添加内容而不修改';

  @override
  String get letAICreateNote => '让AI创建笔记';

  @override
  String get letAICreateNoteDescription => '使用AI总结或转换内容';

  @override
  String get noteTitle => '笔记标题';

  @override
  String get enterNoteTitlePrompt => '输入新笔记的标题：';

  @override
  String get noteTitleHint => '笔记标题';

  @override
  String multipleNotesCreatedSuccessfully(Object count) {
    return '$count个笔记创建成功';
  }

  @override
  String get aiNoteCreator => 'AI笔记创建器';

  @override
  String get aiNoteCreatorInstructions =>
      'AI将使用对话内容以及您在下面提供的任何额外上下文，根据您的提示创建笔记。';

  @override
  String get prompt => '提示';

  @override
  String get promptHint => '描述您希望AI执行的操作...';

  @override
  String get promptTip =>
      '提示：默认的\"总结\"将创建简明摘要。您可以将其更改为任何指令，如\"提取行动项\"、\"创建详细大纲\"等。';

  @override
  String additionalContextNotes(num count) {
    return '额外上下文笔记（$count）';
  }

  @override
  String get noAdditionalNotesSelected => '未选择额外笔记。AI将仅使用对话内容。';

  @override
  String get proceed => '继续';

  @override
  String get pleaseEnterPrompt => '请输入提示';

  @override
  String get view => '查看';

  @override
  String errorSavingNodes(Object error) {
    return '保存节点时出错：$error';
  }

  @override
  String get cancelAiRequest => '取消AI请求';

  @override
  String get copy => '复制';

  @override
  String attachedFiles(Object count) {
    return '附加文件（$count）';
  }

  @override
  String get you => '您';

  @override
  String get errorLoadingData => '加载数据时出错';

  @override
  String get retry => '重试';

  @override
  String get errorProcessingSharedContent => '处理共享内容时出错';

  @override
  String get whatWouldYouLikeToDo => '您想要做什么？';

  @override
  String get createNewNoteWithThisContent => '创建包含此内容的新笔记';

  @override
  String get addThisContentToExistingNote => '将此内容添加到现有笔记';

  @override
  String get selectNote => '选择笔记...';

  @override
  String showingNotes(int filteredCount, int totalCount) {
    return '显示 $filteredCount / $totalCount 条笔记';
  }

  @override
  String get noteDetails => '笔记详情';

  @override
  String get contentPreview => '内容预览';

  @override
  String get selectedTags => '已选标签：';

  @override
  String get availableTags => '可用标签：';

  @override
  String get webContentExtractionNotSupportedLinux => 'Linux不支持网页内容提取。';

  @override
  String get pleaseUseOtherPlatformsForWebExtraction =>
      '请使用Android、iOS或Web版本来提取网页内容。';

  @override
  String get shareUrlChoiceTitle => '选择如何处理此链接。';

  @override
  String get shareUrlChoiceDescription => '“提取”允许你在保存前预览网页，或直接保留原始链接。';

  @override
  String get webExtractionStatusCheckingFileType => '正在检查文件类型...';

  @override
  String get webExtractionStatusDownloadingFile => '正在下载文件...';

  @override
  String get webExtractionStatusFileDownloaded => '文件下载成功';

  @override
  String webExtractionStatusDownloadFailed(String reason) {
    return '下载失败：$reason';
  }

  @override
  String get webExtractionStatusReady => '页面已就绪，可在提取前进行交互。';

  @override
  String get webExtractionStatusApplyingReadability => '正在启用阅读模式...';

  @override
  String get webExtractionStatusReloadingOriginal => '正在重新加载原始页面...';

  @override
  String get webExtractionStatusReadabilityEnabled => '已启用阅读模式。';

  @override
  String get webExtractionReadabilityLabel => '阅读模式';

  @override
  String get webExtractionReadabilityDescription => '在提取前简化页面，关闭后将重新加载原始页面。';

  @override
  String get webExtractionManualExtract => '提取';

  @override
  String get webExtractionAiExtract => 'AI提取';

  @override
  String get extractWebContent => '提取网页内容';

  @override
  String get extracting => '提取中...';

  @override
  String get extractContentUsingAiForBetterResults => '使用AI提取内容以获得更好的结果';

  @override
  String get extractWithAi => '使用AI提取（较慢）';

  @override
  String get extractingWithAi => 'AI提取中...';

  @override
  String get asIs => '原样';

  @override
  String get loadingWebPage => '加载网页中...';

  @override
  String get imageDetected => '检测到图片';

  @override
  String get extractImageContent => '提取图片内容';

  @override
  String get extractingImageContent => '提取中...';

  @override
  String get pdfDetected => '检测到PDF';

  @override
  String get extractPdfContent => '提取PDF内容';

  @override
  String get extractingPdfContent => '提取中...';

  @override
  String get sharedImage => '共享图片';

  @override
  String get pleaseSelectNoteToAppend => '请选择要追加的笔记';

  @override
  String get contentAppendedSuccessfully => '内容追加成功！';

  @override
  String get extractingWebContent => '提取网页内容';

  @override
  String get sharedContentFrom => '共享内容来自';

  @override
  String get sharedUrl => '共享URL';

  @override
  String get unknownSource => '未知来源';

  @override
  String failedToPrepareNote(String error) {
    return '准备笔记失败：$error';
  }

  @override
  String errorExtractingWebContent(String error) {
    return '提取网页内容时出错：$error';
  }

  @override
  String failedToLoadWebPage(String message) {
    return '加载网页失败：$message';
  }

  @override
  String get extractionCancelledByUser => '用户取消提取';

  @override
  String readabilityExtractionFailed(String error) {
    return 'Readability提取失败：$error';
  }

  @override
  String get failedToExtractContentFromWebPage => '无法从网页提取内容';

  @override
  String get processingWithAi => '使用AI处理中...';

  @override
  String get checkingApiKey => '检查API密钥中...';

  @override
  String errorExtractingImageContent(String error) {
    return '提取图片内容时出错：$error';
  }

  @override
  String errorExtractingPdfContent(String error) {
    return '提取PDF内容时出错：$error';
  }

  @override
  String get unknownImage => '未知图片';

  @override
  String get unknownPdf => '未知PDF';

  @override
  String get newConversation => '新对话';

  @override
  String get oneHourAgo => '1小时前';

  @override
  String get twelveHoursAgo => '12小时前';

  @override
  String get oneDayAgo => '1天前';

  @override
  String get threeDaysAgo => '3天前';

  @override
  String get sevenDaysAgo => '7天前';

  @override
  String get fifteenDaysAgo => '15天前';

  @override
  String get oneMonthAgo => '1个月前';

  @override
  String get sixMonthsAgo => '6个月前';

  @override
  String get allTime => '所有时间';

  @override
  String get custom => '自定义';

  @override
  String get first => '第一条';

  @override
  String get last => '最后一条';

  @override
  String get deleteInteractionWhatToDelete => '您想要删除什么？';

  @override
  String get deleteOnlyNodesInFilter => '仅删除此筛选器中的节点';

  @override
  String get deleteNodeAndDescendants => '删除此节点及其所有后代';

  @override
  String get tokenTab => '令牌';

  @override
  String get oauthTab => 'OAuth';

  @override
  String get autoConfigure => '自动配置';

  @override
  String get login => '登录';

  @override
  String get authorizationEndpoint => '授权端点';

  @override
  String get tokenEndpoint => '令牌端点';

  @override
  String get clientId => '客户端ID';

  @override
  String get clientSecretOptionalForPkce => '客户端密钥（PKCE可选）';

  @override
  String get scope => '作用域';

  @override
  String get usePkceNoClientSecret => '使用PKCE（无需客户端密钥）';

  @override
  String get oauthDiscoveryMetadataUrlOptional => 'OAuth发现页面：元数据URL（可选）';

  @override
  String get discover => '发现';

  @override
  String get registerClient => '注册客户端';

  @override
  String get register => '注册';

  @override
  String get editMcpEndpoint => '编辑MCP端点';

  @override
  String get metadataUrlOptional => '元数据URL（可选）';

  @override
  String get metadataUrlOptionalHint => '留空以使用RFC 9728自动检测';

  @override
  String get oauthDiscovery => 'OAuth发现';

  @override
  String get openInTree => '在树状图中打开';

  @override
  String get addConversationDialogTitle => '添加对话';

  @override
  String get addConversationDialogMessage => '您想如何创建此对话？';

  @override
  String get addDirectly => '直接添加';

  @override
  String get addDirectlyDescription => '直接创建对话，将所选节点作为上下文';

  @override
  String get addWithAIProcessing => '使用AI处理后添加';

  @override
  String get addWithAIProcessingDescription => '首先使用AI处理内容（例如总结），然后创建对话';

  @override
  String get conversationTitle => '对话标题';

  @override
  String get enterConversationTitlePrompt => '输入新对话的标题：';

  @override
  String get conversationTitleHint => '对话标题';

  @override
  String get createConversation => '创建对话';

  @override
  String conversationCreatedSuccessfully(String title) {
    return '对话\"$title\"创建成功';
  }

  @override
  String errorCreatingConversation(String error) {
    return '创建对话时出错：$error';
  }

  @override
  String get aiConversationCreator => 'AI对话创建器';

  @override
  String get aiConversationCreatorInstructions =>
      'AI将根据您的提示处理对话内容，以及您在下文提供的任何其他上下文，以创建对话。';

  @override
  String get selectRelationshipType => '选择关系类型';

  @override
  String selectRelationshipTypeForNotes(int noteCount) {
    return '为$noteCount条笔记选择关系类型：';
  }

  @override
  String get relationshipType => '关系类型';

  @override
  String linkNotes(int noteCount) {
    return '链接$noteCount条笔记';
  }

  @override
  String get customRelationshipType => '自定义关系类型';

  @override
  String get enterCustomRelationshipType => '输入自定义关系类型';

  @override
  String get customEllipsis => '自定义...';

  @override
  String get confirmRemoveLink => '您确定要移除此链接吗？';

  @override
  String get remove => '移除';

  @override
  String get linkNotesDialogTitle => '链接笔记';

  @override
  String get link => '链接';

  @override
  String linkNoteTo(String noteTitle) {
    return '将 \"$noteTitle\" 链接到：';
  }

  @override
  String get audioTranscription => '音频转录';

  @override
  String get transcribingAudio => '正在转录音频...';

  @override
  String get transcriptionAddedToNote => '转录已添加到笔记';

  @override
  String errorTranscribingAudio(String error) {
    return '转录音频时出错：$error';
  }

  @override
  String errorAddingTranscription(String error) {
    return '添加转录时出错：$error';
  }

  @override
  String get newNoteFromShareCreated => '分享的笔记创建成功！';

  @override
  String get mediaDownloadsHeader => '媒体附件';

  @override
  String get mediaDownloadsDescription => '选择要下载到本地的图片，以便离线使用。';

  @override
  String get clearAll => '全不选';

  @override
  String get noRemoteImagesDetected => '此内容中没有检测到网络图片。';

  @override
  String get mediaPreviewLabel => '预览';

  @override
  String get imageUrlLabel => '图片地址';

  @override
  String get downloadToLocalLabel => '下载到本地？';

  @override
  String mediaDownloadFailed(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# 张图片',
      one: '# 张图片',
    );
    return '未能下载$_temp0。';
  }

  @override
  String get mediaDownloadNoneAvailable => '此笔记中没有网络图片。';

  @override
  String get mediaDownloadAlreadyCached => '所有网络图片已缓存到本地。';

  @override
  String mediaDownloadSuccess(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# 张图片',
      one: '# 张图片',
    );
    return '已将$_temp0下载为附件。';
  }

  @override
  String mediaDownloadPartial(num successCount, num failureCount) {
    String _temp0 = intl.Intl.pluralLogic(
      successCount,
      locale: localeName,
      other: '# 张',
      one: '# 张',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failureCount,
      locale: localeName,
      other: '# 张',
      one: '# 张',
    );
    return '已下载$_temp0，失败$_temp1。';
  }

  @override
  String mediaDownloadFailedGeneric(Object error) {
    return '下载图片失败：$error';
  }

  @override
  String get fetchRemoteImages => '抓取网络图片';

  @override
  String get gettingStarted => '入门指南';

  @override
  String get gettingStartedSubtitle => '安装用户手册和入门应用';

  @override
  String get installUserManual => '安装用户手册';

  @override
  String get installUserManualSubtitle => '安装或更新用户手册笔记';

  @override
  String get installStarterApps => '安装入门应用';

  @override
  String get installStarterAppsSubtitle => '浏览并安装预配置的应用';

  @override
  String get userManualInfo => '用户手册信息';

  @override
  String get installed => '已安装';

  @override
  String get notInstalled => '未安装';

  @override
  String get currentVersion => '当前版本';

  @override
  String get latestVersion => '最新版本';

  @override
  String get lastUpdated => '最后更新';

  @override
  String get newVersionAvailable => '新版本可用！';

  @override
  String get updateUserManual => '更新用户手册';

  @override
  String get reinstallUserManual => '重新安装用户手册';

  @override
  String get installing => '安装中...';

  @override
  String updateUserManualConfirm(String oldVersion, String newVersion) {
    return '用户手册有新版本（$newVersion）可用。您当前的版本是$oldVersion。您想要更新吗？';
  }

  @override
  String get userManualInstalledSuccessfully => '用户手册安装成功！';

  @override
  String get userManualUpdatedSuccessfully => '用户手册更新成功！';

  @override
  String errorInstallingUserManual(String error) {
    return '安装用户手册时出错：$error';
  }

  @override
  String get whatIsUserManual => '什么是用户手册？';

  @override
  String get userManualDescription =>
      '用户手册是Note Synapse的综合指南。它包含详细的说明、提示和有效使用应用的最佳实践。';

  @override
  String get noStarterAppsAvailable => '没有可用的入门应用';

  @override
  String get noAppsSelected => '未选择任何应用';

  @override
  String appsSelected(int count) {
    return '已选择$count个应用';
  }

  @override
  String get proceedWithInstallation => '安装选中的应用';

  @override
  String starterAppsInstalledSuccessfully(int count) {
    return '$count个应用安装成功！';
  }

  @override
  String starterAppsInstallFailed(int count) {
    return '$count个应用安装失败';
  }

  @override
  String starterAppsPartialInstall(int successCount, int failureCount) {
    return '成功安装$successCount个应用，失败$failureCount个应用';
  }

  @override
  String errorInstallingStarterApps(String error) {
    return '安装入门应用时出错：$error';
  }

  @override
  String get rawDataManagerTitle => '原始数据管理器';

  @override
  String get advancedToolTitle => '高级工具';

  @override
  String get advancedToolWarning =>
      '此工具提供对应用程序数据和数据库的原始访问权限。使用不当可能导致永久性数据丢失或损坏。\n\n除非您知道自己在做什么或在支持人员的指导下，否则请勿使用此工具。';

  @override
  String get iUnderstand => '我明白';

  @override
  String get fileManagerTab => '文件管理器';

  @override
  String get databaseManagerTab => '数据库管理器';

  @override
  String get warningDataInstability => '警告：直接修改数据可能会导致应用程序不稳定。';

  @override
  String get cache => '缓存';

  @override
  String get root => '根目录';

  @override
  String itemsCount(int count) {
    return '$count 个项目';
  }

  @override
  String get selectUnused => '选择未使用';

  @override
  String get noFilesFound => '未找到文件';

  @override
  String get used => '已使用';

  @override
  String get unused => '未使用';

  @override
  String get renameFile => '重命名文件';

  @override
  String get newName => '新名称';

  @override
  String get rename => '重命名';

  @override
  String get deleteFilesTitle => '删除文件？';

  @override
  String deleteFilesConfirmation(int count) {
    return '您确定要删除 $count 个文件吗？此操作无法撤销。';
  }

  @override
  String deletedFilesMessage(int count) {
    return '已删除 $count 个文件';
  }

  @override
  String errorRenamingFile(String error) {
    return '重命名文件出错：$error';
  }

  @override
  String get queryAndResults => '查询与结果';

  @override
  String get aiAssistant => 'AI 助手';

  @override
  String get notConnected => '未连接';

  @override
  String connectedTo(String name) {
    return '已连接到：$name';
  }

  @override
  String errorOpeningDefaultDb(String error) {
    return '打开默认数据库出错：$error';
  }

  @override
  String errorOpeningDb(String error) {
    return '打开数据库出错：$error';
  }

  @override
  String get databaseExportedSuccess => '数据库导出成功';

  @override
  String exportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get sqlQueryLabel => 'SQL 查询';

  @override
  String get sqlQueryHint => 'SELECT * FROM notes LIMIT 5';

  @override
  String get runQueryTooltip => '运行查询';

  @override
  String get enterQueryMessage => '输入查询以查看结果';

  @override
  String get noResultsReturned => '未返回结果';

  @override
  String queryExecutedMessage(int count) {
    return '查询已执行。返回 $count 行。';
  }

  @override
  String updateExecutedMessage(int count) {
    return '更新已执行。影响 $count 行。';
  }

  @override
  String queryError(String error) {
    return '查询错误：$error';
  }

  @override
  String get askAiAboutNoteHint => '向 AI 询问这条笔记...';

  @override
  String get openDbFileTooltip => '打开数据库文件';

  @override
  String get resetToDefaultDbTooltip => '重置为默认数据库';

  @override
  String get exportDbTooltip => '导出数据库';

  @override
  String get undo => '撤销';

  @override
  String get taskRescheduled => '任务已重新安排';

  @override
  String get recoveryManager => 'Recovery Manager';

  @override
  String get backupAndRestore => 'Backup & Restore';

  @override
  String get databaseNotConnected => 'Database not connected';

  @override
  String get fileUsageUnavailable => 'File usage status unavailable';

  @override
  String get fileUsageDetails => 'File Usage Details';

  @override
  String get noReferencesFound => 'No references found in database';

  @override
  String usedByNotes(int count) {
    return 'Used by $count note(s)';
  }

  @override
  String usedByConversations(int count) {
    return 'Used in $count conversation message(s)';
  }

  @override
  String get noteNoLongerExists => 'Note no longer exists';

  @override
  String get messageNoLongerExists => 'Message no longer exists';

  @override
  String get showDetails => 'Show Details';

  @override
  String get saveFindings => '保存发现';

  @override
  String get saveFindingsToNote => '将发现保存到笔记';

  @override
  String get attachNotesToPlan => '添加笔记到计划';

  @override
  String get attachNotesToTask => '添加笔记到任务';

  @override
  String get globalContextNotes => '全局上下文笔记';

  @override
  String get taskContextNotes => '任务上下文笔记';

  @override
  String get globalContextDescription => '这些笔记将作为所有任务的上下文';

  @override
  String get taskContextDescription => '这些笔记仅作为此任务的上下文';

  @override
  String notesAttachedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已附加$count个笔记',
      one: '已附加1个笔记',
      zero: '未附加笔记',
    );
    return '$_temp0';
  }

  @override
  String get agentRunningNotificationTitle => '智能体运行中';

  @override
  String agentRunningNotificationBody(String objective) {
    return '正在处理: $objective';
  }

  @override
  String get agentCompleteNotificationTitle => '智能体完成';

  @override
  String get agentCompleteNotificationBody => '点击查看结果';

  @override
  String get agentPauseExecution => '暂停';

  @override
  String get agentResumeExecution => '继续';

  @override
  String get agentStopExecution => '停止';

  @override
  String get agentPausedStatus => '已暂停';

  @override
  String get agentConflictTitle => '智能体已在运行';

  @override
  String agentConflictMessage(String status) {
    return '智能体当前在另一个会话中$status。您可以停止它以启动新的智能体，或切换到该会话。';
  }

  @override
  String get agentConflictStop => '停止智能体';

  @override
  String get agentConflictSwitch => '切换到会话';

  @override
  String get editBlock => '编辑区块';

  @override
  String get deleteBlock => '删除区块';

  @override
  String get deleteBlockConfirmation => '您确定要删除此区块吗？此操作无法撤消。';

  @override
  String get expandSelectionAbove => '向上扩展';

  @override
  String get contractSelectionAbove => '向上收缩';

  @override
  String get expandSelectionBelow => '向下扩展';

  @override
  String get contractSelectionBelow => '向下收缩';

  @override
  String get editSelection => '编辑';

  @override
  String get deleteSelection => '删除区块';

  @override
  String confirmDeleteBlocks(int count) {
    return '确定要删除 $count 个区块吗？';
  }
}
