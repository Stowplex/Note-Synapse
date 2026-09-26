/*
 * Gantt UI localization (Cartograph pattern): one ZH table keyed by the
 * English source string. Note content, mirror lines and the fence are never
 * translated. The language is pushed in by app.js (from host.locale());
 * this module never reads the host and never touches the DOM.
 *
 * Every UI string of every module has an entry (M9 audit, dev/m9_spec.js).
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});

  var ZH = {
    'Gantt': '甘特图',
    'Undo': '撤销', 'Redo': '重做', 'Today': '今天', 'More': '更多',
    'Open note': '打开笔记', 'Remove from chart': '从图表中移除',
    'Unscheduled': '未排期', 'Missing note': '笔记缺失', 'Overdue': '逾期', 'Dropped': '已放弃',
    'No tasks on this chart yet': '此图表还没有任务',
    'Saved': '已保存', 'Saving…': '正在保存…',
    'Checklist': '清单', 'Untitled': '无标题',
    // M4: shell, home, chooser, states and banners.
    'D': '日', 'W': '周', 'M': '月',
    'Charts': '图表', 'Recents': '最近', 'Retry': '重试', 'Unsaved changes': '有未保存的更改',
    'No charts in this Space yet.': '此空间还没有图表。',
    'Couldn’t load the charts.': '无法加载图表列表。',
    'Charts with this note': '包含此笔记的图表',
    'This note is not on any chart yet.': '此笔记还不在任何图表中。',
    'Couldn’t look up charts for this note.': '无法查找包含此笔记的图表。',
    'Unsaved chart for this note.': '此笔记有一个未保存的图表。',
    'Select one note to open its chart.': '请选择一条笔记以打开它的图表。',
    'Chart not found': '找不到图表',
    'The chart note was deleted. Its unsaved chart is kept.': '图表笔记已被删除，其未保存的图表仍被保留。',
    'Back to charts': '返回图表列表',
    'Couldn’t read the note.': '无法读取笔记。',
    'This chart was made by a newer version of Gantt. It is read-only.': '此图表由更新版本的甘特图创建，只能查看。',
    'The chart block in this note is damaged, so nothing is shown.': '此笔记中的图表代码块已损坏，无法显示。',
    'Couldn’t check for unsaved changes.': '无法检查未保存的更改。',
    'Unsaved changes from an earlier session are kept for this chart.': '此图表保留了上次会话中未保存的更改。',
    'Unsaved chart edits exist for this note.': '此笔记有未保存的图表编辑。',
    'This chart can’t be saved. Your changes are kept and offered again next time.': '此图表无法保存。你的更改已保留，下次打开时会再次提供。',
    'This note has more than one chart. The first one is shown.': '此笔记包含多个图表，仅显示第一个。',
    // M5: navigation.
    'Zoom': '缩放', 'Zoom in': '放大', 'Zoom out': '缩小', 'Fit all': '显示全部',
    // M6: editing, the sheet and the save UI.
    'Add': '添加', 'Close': '关闭', 'Cancel': '取消', 'Skip': '跳过', 'Got it': '知道了',
    'Unsaved changes. Tap to save': '有未保存的更改，点按保存', 'Not saved. Tap to save': '未保存，点按保存',
    // The host's approval dialog labels (approval_dialog.dart, app_zh.arb:2099-2101).
    'Allow for this session': '在本次会话中允许', 'Approve': '允许',
    'Edit anyway': '仍然编辑', 'Restore': '恢复', 'Discard': '丢弃', 'Copy chart JSON': '复制图表 JSON',
    'Chart JSON copied': '已复制图表 JSON', 'Repair': '修复', 'Use the first block': '使用第一个代码块',
    'Repair this chart?': '修复此图表？', 'Use the first chart block?': '使用第一个图表代码块？',
    'Repair replaces the text below with an empty chart. The rest of the note is kept.': '修复会用一个空图表替换下面的文本，笔记的其余部分保持不变。',
    'The first chart block is saved in place. The other block stays in the note as text.': '第一个图表代码块会就地保存，另一个代码块作为文本保留在笔记中。',
    'Start': '开始', 'End': '结束', 'Date': '日期', 'Milestone': '里程碑', 'Colour': '颜色', 'Auto': '自动',
    'Completion': '完成度', 'Loading…': '正在加载…', 'No checklist section': '没有清单部分', 'No sub-items': '没有子项',
    'Indigo': '靛蓝', 'Blue': '蓝色', 'Sky': '天蓝', 'Teal': '青色', 'Emerald': '翠绿', 'Amber': '琥珀',
    'Orange': '橙色', 'Rose': '玫红', 'Pink': '粉色', 'Violet': '紫色', 'Slate': '灰色',
    'No group': '无分组', 'Add milestone': '添加里程碑', 'Expand all': '全部展开', 'Collapse all': '全部折叠',
    'Rename chart': '重命名图表', 'Chart title': '图表标题', 'Rename': '重命名',
    'The chart was not renamed: not approved': '图表未重命名：未获允许',
    'Couldn’t undo: not approved': '无法撤销：未获允许', 'Couldn’t undo: the note changed': '无法撤销：笔记已更改',
    'Move': '移动', 'Resize': '调整时长', 'Reorder': '调整顺序', 'Change dates': '修改日期',
    'This chart changed elsewhere': '此图表在别处也被修改了',
    'The same fields were changed here and in the note. Choose what to keep.': '此处和笔记中修改了相同的字段。请选择要保留的内容。',
    'Keep mine': '保留我的', 'Take theirs': '采用笔记中的', 'Keep mine for these': '全部保留我的', 'Save choices': '按选择保存',
    'Chart settings': '图表设置', 'Group': '分组', 'Depends on': '依赖', 'Note': '笔记', 'Sub-items': '子项',
    'Title': '标题', 'Removed': '已移除', 'None': '无', 'Yes': '是', 'No': '否', 'Kept': '保留',
    'The chart block was removed from the note. Your changes are kept.': '图表代码块已从笔记中移除。你的更改已保留。',
    // M7: chart membership, new charts, the chooser and the completion list.
    'New chart': '新建图表', 'Intro (optional)': '简介（可选）', 'Sub-items come from': '子项来自',
    'Sub-notes': '子笔记', 'Checklist section': '清单部分', 'Create': '创建',
    'Couldn’t create the chart.': '无法创建图表。', 'Recreate chart': '重新创建图表',
    'This note': '此笔记', 'Add to a chart…': '添加到图表…', 'Add to a chart': '添加到图表',
    'Turn this note into a chart': '将此笔记转为图表', 'New chart starting with this note': '以此笔记新建图表',
    'A chart is added at the end of this note. The rest of the note is kept.': '图表会添加到此笔记的末尾，笔记的其余部分保持不变。',
    'Turn into a chart': '转为图表',
    'Add existing notes': '添加已有笔记', 'Create a task note': '新建任务笔记', 'Add notes to the chart': '向图表添加笔记',
    'The note picker is not available here.': '此处无法使用笔记选择器。', 'The note picker could not be opened.': '无法打开笔记选择器。',
    'This chart can’t be edited right now.': '此图表现在无法编辑。', 'The notes were not added.': '笔记未添加。',
    'Those notes are already on the chart.': '这些笔记已在图表中。',
    'Add notes': '添加笔记', 'Create task note': '新建任务笔记', 'Remove': '移除', 'Toggle item': '切换子项',
    'Sub-notes, one per line': '子笔记，每行一条', 'Checklist items, one per line': '清单项，每行一项',
    'Link back to chart': '链接回图表', 'The task note could not be created.': '无法创建任务笔记。',
    'Removed from the chart. The note is kept.': '已从图表中移除，笔记仍保留。',
    'Tap again to remove': '再点一次以移除', 'Couldn’t load the items.': '无法加载子项。',
    'Ticking sub-notes': '勾选子笔记', 'Continue': '继续',
    'Not changed: not approved': '未更改：未获允许', 'Couldn’t change it: the note changed': '无法更改：笔记已变化',
    // M7 review round 1
    'Whole note': '整条笔记',
    'This note is too large to list here. Open the note to tick its items.': '此笔记太大，无法在这里列出。请打开笔记勾选其中的项目。',
    // M8: completion styles, colour modes, settings, display, legend and states.
    'All groups are collapsed': '所有分组都已折叠', 'Tap to schedule': '点按以排期', 'Schedule': '排期',
    'Legend': '图例', 'Hide legend': '隐藏图例', 'On': '开', 'Off': '关', 'Display': '显示', 'Appearance': '外观',
    'Theme': '主题', 'Light': '浅色', 'Dark': '深色', 'Done': '完成',
    'Status': '状态', 'Task': '任务', 'Count linked child tasks': '计入关联的子任务',
    'Completion display': '完成度显示', 'Fill': '填充', 'Segments': '分段', 'Dots': '圆点',
    'Colour bars by': '条形颜色依据', 'Default zoom': '默认缩放',
    'Day': '日', 'Week': '周', 'Month': '月', 'Quarter': '季度',
    'Week starts on': '每周开始于', 'Sunday': '星期日', 'Monday': '星期一',
    'Working days': '工作日', 'Holidays': '节假日', 'Add holiday': '添加节假日',
    'Readable task list in the note': '在笔记中显示可读的任务列表',
    'Show the chart inside the note': '在笔记中显示图表',
    'Write dates to task notes (shows in Calendar)': '将日期写入任务笔记（显示在日历中）',
    'Rows': '行高', 'Regular': '标准', 'Compact': '紧凑', 'Shade weekends': '周末底纹', 'Week numbers': '周数',
    'Reset name column': '重置名称列宽',
    'Note Synapse’s own dark mode is not visible to apps yet. If you use it, pick Dark here.':
      'Note Synapse 自身的深色模式目前对应用不可见。如果你在使用深色模式，请在这里选择“深色”。',
    'In progress': '进行中', 'To do': '待办', 'Weekend': '周末',
    'Each task keeps its own colour.': '每个任务使用自己的颜色。',
    // M8 review round 1
    'Open chart note': '打开图表笔记',
    'Couldn’t read the task notes. Their progress shows once they can be read.': '无法读取任务笔记。能读取后会显示它们的进度。',
    // M9: accessibility labels, the Task list view, the reconciliation banner.
    'Tasks': '任务', 'Task list': '任务列表', 'Zoom level': '缩放级别', 'Name column width': '名称列宽度',
    'Restore list': '恢复任务列表',
    'The task list above the chart was edited. It is kept as your text.': '图表上方的任务列表被编辑过，已作为你的文本保留。',
    // Device feedback round 1: colour overrides, the name column toggle.
    'Tasks with their own colour keep it.': '设置了颜色的任务保持自己的颜色。',
    'Collapse task names': '收起任务名', 'Expand task names': '展开任务名'
  };

  var language = 'en-US';
  // The host's own tag (for example en-GB): UI strings follow `language`,
  // but week start and weekend follow the user's region.
  var regionTag = 'en-US';

  function norm(tag) {
    var v = String(tag || '').replace(/_/g, '-').toLowerCase();
    return v === 'zh' || v.indexOf('zh-cn') === 0 || v.indexOf('zh-hans') === 0 || v === 'zh-sg' ? 'zh-CN' : 'en-US';
  }

  // Dates are formatted with the raw host tag (en-GB writes "3 Mar") when
  // it is a valid tag of the UI language; otherwise with the UI language,
  // so an English UI never shows another language's month names.
  var dateTag = 'en-US';
  function dateTagFor(raw, lang) {
    try {
      if (raw && typeof Intl !== 'undefined' && Intl.DateTimeFormat.supportedLocalesOf(raw).length &&
          raw.split('-')[0].toLowerCase() === lang.split('-')[0]) return raw;
    } catch (e) { /* not a tag */ }
    return lang;
  }
  function setLanguage(tag) {
    var next = norm(tag);
    regionTag = String(tag || '').replace(/_/g, '-') || next;
    var dt = dateTagFor(regionTag, next);
    if (next !== language || dt !== dateTag) { language = next; dateTag = dt; fmtCache = {}; }
    return language;
  }

  function text(value) {
    var s = String(value == null ? '' : value);
    if (language !== 'zh-CN') return s;
    if (Object.prototype.hasOwnProperty.call(ZH, s)) return ZH[s];
    return s;
  }

  // Patterns with {name} slots. English plurals use "(s)" after a count.
  var ZH_PATTERNS = {
    '{n} day(s)': '{n} 天',
    '{a} of {b} done': '已完成 {a}/{b}',
    '+{n}d': '+{n} 天',
    'Undo: {action} “{title}”': '撤销：{action}“{title}”',
    '{n} task(s)': '{n} 个任务',
    'Open in {title}': '在“{title}”中打开',
    // M6
    'Redo: {action} “{title}”': '重做：{action}“{title}”',
    '{n}d': '{n} 天',
    'Duration: {n} day(s)': '时长：{n} 天',
    'Ends {date}': '结束于 {date}',
    'Starts {date}': '开始于 {date}',
    'Unsaved changes from {when}.': '有来自{when}的未保存更改。',
    'Mine: {mine} · Theirs: {theirs}': '我的：{mine} · 笔记中：{theirs}',
    'Note Synapse asks before an app edits a note. Tick \'{allow}\', then {approve}, so the chart can save as you work.':
      'Note Synapse 在应用修改笔记前会先询问。请勾选“{allow}”，再点“{approve}”，图表就能在你编辑时保存。',
    // M7
    'Import {n} linked note(s) as tasks': '将 {n} 条链接的笔记导入为任务',
    'New chart with these {n} notes': '用这 {n} 条笔记新建图表',
    '{n} notes': '{n} 条笔记',
    'The chart starts with {n} task(s).': '图表从 {n} 个任务开始。',
    '{n} already on the chart': '{n} 条已在图表中',
    'Removed “{title}” from the chart': '已将“{title}”从图表中移除',
    'Dates not written to {n} task note(s)': '有 {n} 条任务笔记未写入日期',
    // M8
    'Colour by {by} · {style}': '颜色依据：{by} · {style}',
    'Sub-notes are saved with a database edit, so Note Synapse asks for approval before the first one. Tick \'{allow}\' there so the next ones save without asking.':
      '子笔记通过数据库修改来保存，所以第一次勾选时 Note Synapse 会再询问一次。请在那里勾选“{allow}”，之后的勾选就不会再询问。',
    // M9
    '{title}, {n} task(s)': '{title}，{n} 个任务',
    'Removed in the note: {titles}. Remove from chart?': '笔记中已删除：{titles}。要从图表中移除吗？',
    '{n} more': '另外 {n} 个'
  };
  function fmt(key, vars) {
    vars = vars || {};
    var pattern = language === 'zh-CN' && ZH_PATTERNS[key] ? ZH_PATTERNS[key] : key;
    // Plurals are resolved on the pattern, before values go in, so text in
    // a value (a note title with "(s)") is never rewritten.
    pattern = pattern.replace(/\{(\w+)\}([^{(]*?)\(s\)/g, function (m, k, word) {
      var n = Object.prototype.hasOwnProperty.call(vars, k) ? Number(vars[k]) : NaN;
      return '{' + k + '}' + word + (n === 1 ? '' : 's');
    });
    return pattern.replace(/\{(\w+)\}/g, function (m, k) {
      if (!Object.prototype.hasOwnProperty.call(vars, k)) return m;
      var v = vars[k];
      return typeof v === 'string' && k === 'action' ? text(v) : String(v);
    });
  }

  /* ---------------------------------------------------------------- dates */

  var fmtCache = {};
  function dtf(name, opts) {
    var k = dateTag + '|' + name;
    if (!fmtCache[k]) {
      var o = { timeZone: 'UTC' };
      Object.keys(opts).forEach(function (x) { o[x] = opts[x]; });
      fmtCache[k] = new Intl.DateTimeFormat(dateTag, o);
    }
    return fmtCache[k];
  }
  function at(day) { return new Date(day * 864e5); }

  var date = {
    monthYear: function (d) { return dtf('my', { year: 'numeric', month: 'long' }).format(at(d)); },
    monthShort: function (d) { return dtf('ms', { month: 'short' }).format(at(d)); },
    dayNum: function (d) { return String(at(d).getUTCDate()); },
    weekdayNarrow: function (d) { return dtf('wn', { weekday: 'narrow' }).format(at(d)); },
    // M9: the spoken name of a narrow weekday toggle ("Monday", "星期一").
    weekdayLong: function (d) { return dtf('wl', { weekday: 'long' }).format(at(d)); },
    short: function (d) { return dtf('sh', { month: 'short', day: 'numeric' }).format(at(d)); },
    long: function (d) {
      if (language === 'zh-CN') {
        return dtf('lz', { year: 'numeric', month: 'long', day: 'numeric' }).format(at(d)) + ' ' +
          dtf('lw', { weekday: 'short' }).format(at(d));
      }
      return dtf('lg', { weekday: 'short', year: 'numeric', month: 'short', day: 'numeric' }).format(at(d));
    },
    range: function (a, b) {
      // zh-CN (§15.1 "the same rule with 至"): ICU's range reads "10/5 – 10/6",
      // unlike the single date "10月5日"; written out instead: "10月5日至6日",
      // "10月30日至11月2日" (M9 review round 1).
      if (language === 'zh-CN') {
        var sameMonth = at(a).getUTCFullYear() === at(b).getUTCFullYear() && at(a).getUTCMonth() === at(b).getUTCMonth();
        return date.short(a) + '至' + (sameMonth ? at(b).getUTCDate() + '日' : date.short(b));
      }
      var f = dtf('sh', { month: 'short', day: 'numeric' });
      if (typeof f.formatRange === 'function') { try { return f.formatRange(at(a), at(b)); } catch (e) { /* fall through */ } }
      return date.short(a) + (language === 'zh-CN' ? '至' : ' to ') + date.short(b);
    },
    week: function (n) { return language === 'zh-CN' ? '第' + n + '周' : 'W' + n; },
    quarter: function (d) {
      var q = Math.floor(at(d).getUTCMonth() / 3) + 1;
      return language === 'zh-CN' ? '第' + q + '季度' : 'Q' + q;
    }
  };

  function weekInfoFor(tag) {
    try {
      if (typeof Intl !== 'undefined' && Intl.Locale) {
        var loc = new Intl.Locale(tag);
        var wi = typeof loc.getWeekInfo === 'function' ? loc.getWeekInfo() : loc.weekInfo;
        if (wi && typeof wi.firstDay === 'number') return wi;
      }
    } catch (e) { /* bad tag: fall back */ }
    return null;
  }
  function weekInfo() { return weekInfoFor(regionTag) || weekInfoFor(language); }

  // 0 = Sunday. settings.weekStart wins, then the locale, then en Sun / zh Mon.
  function weekStart(settings) {
    if (settings && typeof settings.weekStart === 'number') return settings.weekStart;
    var wi = weekInfo();
    if (wi) return wi.firstDay % 7;
    return language === 'zh-CN' ? 1 : 0;
  }

  function weekendDays() {
    var wi = weekInfo();
    if (wi && Array.isArray(wi.weekend) && wi.weekend.length) return wi.weekend.map(function (d) { return d % 7; });
    return [6, 0];
  }

  // "Sync engine, Oct 12 to Nov 6, 26 days, 6 of 10 done, overdue"
  function taskLabel(task, summary) {
    var parts = [task && task.title ? task.title : text('Untitled')];
    var D = GT.dates;
    if (task && task.start !== null && task.start !== undefined) {
      var end = task.end === null || task.end === undefined ? task.start : task.end;
      parts.push(end === task.start ? date.short(task.start) : date.range(task.start, end));
      if (!task.milestone && D) parts.push(fmt('{n} day(s)', { n: end - task.start + 1 }));
    } else parts.push(text('Unscheduled'));
    if (summary && summary.total > 0) parts.push(fmt('{a} of {b} done', { a: summary.done, b: summary.total }));
    if (summary && summary.overdue) parts.push(text('Overdue').toLowerCase());
    return parts.join(language === 'zh-CN' ? '，' : ', ');
  }

  // "A, B and C" / "A、B和C" (Intl.ListFormat), else joined with commas.
  var listCache = {};
  function list(items) {
    items = (items || []).map(String);
    try {
      if (typeof Intl !== 'undefined' && typeof Intl.ListFormat === 'function') {
        if (!listCache[language]) listCache[language] = new Intl.ListFormat(language, { style: 'long', type: 'conjunction' });
        return listCache[language].format(items);
      }
    } catch (e) { /* fall through */ }
    return items.join(language === 'zh-CN' ? '、' : ', ');
  }

  GT.i18n = {
    setLanguage: setLanguage, text: text, fmt: fmt, taskLabel: taskLabel, date: date, list: list,
    weekStart: weekStart, weekendDays: weekendDays,
    // The tag dates are formatted with (M9).
    get dateTag() { return dateTag; },
    PATTERNS: ZH_PATTERNS,
    // The UI language a host tag maps to ('en-US' or 'zh-CN').
    normTag: norm,
    get language() { return language; },
    ZH: ZH
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
