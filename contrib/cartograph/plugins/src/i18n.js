/* Cartograph UI localization. Note content and tag names are never translated. */
(function (root) {
  'use strict';
  root.CG = root.CG || {};
  var ZH = {
    'Map': '导图', 'Outline': '大纲', 'Back': '返回', 'All maps': '所有导图',
    'Generate a map with AI': '用 AI 生成导图', 'Search': '搜索', 'Undo': '撤销', 'Fit': '适应画布',
    'Open full screen': '全屏打开', 'Find in this map': '在此导图中查找',
    'saving…': '正在保存…', 'saved': '已保存', 'unsaved changes': '有未保存更改', 'not saved': '未保存',
    'Undone': '已撤销', 'Comments': '评论', 'Nothing to map yet': '暂无可绘制内容',
    'Add the first node': '添加第一个节点', 'Generate with AI': '用 AI 生成',
    'Apply': '应用', 'Discard': '放弃', 'Tap nodes to select': '点按节点进行选择',
    'Merge': '合并', 'Group': '分组', 'Move': '移动', 'Unlink': '取消链接', 'Link': '链接',
    'Split': '拆分', 'Comment': '评论', 'Done': '完成', 'Edit': '编辑', 'Attach': '附加',
    'Detach': '分离', 'Delete': '删除', 'Open': '打开', 'Select': '选择', 'Child': '子节点',
    'Sibling': '同级节点', 'Out': '减少缩进', 'In': '增加缩进', 'Up': '上移', 'Down': '下移',
    'More': '更多', 'Note': '笔记', 'Focus': '聚焦', 'Notes': '笔记', 'Save': '保存',
    'Open note': '打开笔记', 'Note saved': '笔记已保存', 'Node': '节点', 'Body': '正文',
    'Import a map here': '在此导入导图', 'Bring another note’s outline in under this node': '将另一篇笔记的大纲导入此节点下',
    'Attach an existing note': '附加现有笔记', 'Pick a note and hang it off this node': '选择笔记并附加到此节点',
    'Create a note here': '在此创建笔记', 'Promote branch to a note': '将分支提升为笔记',
    'Move this whole branch into its own note': '将整个分支移入独立笔记', 'Move to…': '移动到…',
    'Put this branch under a different parent': '将此分支移到另一个父节点下', 'Link to…': '链接到…',
    'A dashed line to any other node': '用虚线连接到其他节点', 'Select several nodes': '选择多个节点',
    'Then merge or group them': '然后合并或分组', 'Add a floating comment': '添加浮动评论',
    'A free text box on the canvas, attached to nothing': '画布上不附着任何节点的文本框',
    'Export map…': '导出导图…', 'The whole map as a file attached to this note': '将完整导图作为文件附加到此笔记',
    'Reshape this branch with AI': '用 AI 重塑此分支', 'Regroup, or tidy the wording': '重新分组或整理措辞',
    'Expand branch': '展开分支', 'Collapse branch': '折叠分支', 'Show body': '显示正文',
    'The paragraphs, code and tables under this node': '此节点下的段落、代码和表格',
    'Make it a task': '设为任务', 'Remove the checkbox': '移除复选框', 'Unpin': '取消固定',
    'Let it rejoin the automatic layout': '重新加入自动布局', 'Export the map': '导出导图',
    'The whole map, expanded. Saved as an attachment on this note; exporting again replaces it.': '导出展开后的完整导图，并作为附件保存到此笔记；再次导出会替换它。',
    'To do': '待办', 'Has note': '有附加笔记', 'Recent': '最近', 'Maps': '导图',
    'Maps — looking…': '导图 — 正在查找…', 'Any note': '任意笔记',
    'Generate a map from a note…': '从笔记生成导图…', 'Open a note as a map…': '将笔记作为导图打开…',
    'Nothing is written until you change something': '只有修改后才会写入笔记',
    'No maps yet. Generate one above, or open any note as a map.': '还没有导图。请从上方生成，或将任意笔记作为导图打开。',
    'This note changed elsewhere': '此笔记已在其他地方更改',
    'The note was edited outside Cartograph while this map was open. Choose which version to keep — the other one is discarded.': '此导图打开期间，笔记已在其他地方编辑。请选择要保留的版本，另一个版本将被丢弃。',
    'Use the other version': '使用另一版本', 'Keep my map': '保留我的导图',
    'Reloaded from the note': '已从笔记重新加载', 'Overwrote the note': '已覆盖笔记',
    'Write a comment…': '写下评论…', 'Cancel': '取消', 'Read-only': '只读', 'Editing enabled': '已启用编辑'
  };
  var language = 'en-US';
  function setLanguage(tag) {
    var value = String(tag || '').replace(/_/g, '-').toLowerCase();
    language = value === 'zh' || value === 'zh-cn' ? 'zh-CN' : 'en-US';
    document.documentElement.lang = language;
  }
  function text(value) {
    var source = String(value == null ? '' : value);
    if (language !== 'zh-CN') return source;
    if (ZH[source]) return ZH[source];
    var selected = /^(\d+) selected(?: · (\d+) attached)?$/.exec(source);
    if (selected) return '已选择 ' + selected[1] + (selected[2] ? ' 个节点 · ' + selected[2] + ' 篇附加笔记' : ' 个节点');
    return source;
  }
  setLanguage((root.Synapse && root.Synapse.locale) || (root.navigator && root.navigator.language) || 'en-US');
  root.CG.i18n = { setLanguage: setLanguage, text: text, get language() { return language; } };
})(typeof window !== 'undefined' ? window : this);
