/* Big Bang UI localization. Note titles, note bodies, tags and board labels
 * are user content and deliberately pass through unchanged. */
(function (root) {
  'use strict';
  var BB = (root.BB = root.BB || {});
  var ZH = {
    'Big Bang': '大爆炸', 'Boards': '画板', 'Search this board': '搜索此画板',
    'Undo': '撤销', 'Redo': '重做', 'Fit the board': '适应画板', 'Done': '完成',
    'New board': '新建画板', 'An empty canvas, in a note of its own': '在一篇独立笔记中创建空白画布',
    'Open another note as a board': '将另一篇笔记作为画板打开', 'Its text is never touched': '不会修改笔记正文',
    'Recent boards': '最近画板', 'Recent boards — looking…': '最近画板 — 正在查找…',
    'Try again': '重试', 'Show more boards': '显示更多画板', '(untitled)': '（无标题）',
    'No boards yet. Make one above, or open any note as a board - a board IS a note, and every note can be one.': '还没有画板。请在上方新建画板，或将任意笔记作为画板打开——画板本身就是一篇笔记，每篇笔记都可以成为画板。',
    'The boards could not be listed.': '无法列出画板。', 'Looking for boards…': '正在查找画板…',
    'Apply': '应用', 'Discard': '放弃', 'Colour': '颜色', 'None': '无', 'Back': '返回',
    'blue': '蓝色', 'sky': '天蓝色', 'teal': '青色', 'green': '绿色', 'amber': '琥珀色',
    'rose': '玫瑰色', 'pink': '粉色', 'violet': '紫色',
    'Ends': '端点', 'Line': '线条', 'Label': '标签', 'Annotate': '批注', 'Link': '链接',
    'Arrow': '箭头', 'Both ends': '双向箭头', 'Solid': '实线', 'Dashed': '虚线', 'Dotted': '点线',
    'Group': '分组', 'Unlink': '取消链接', 'Unlink the notes': '取消笔记链接',
    'Also link the notes': '同时链接笔记', 'Rename': '重命名', 'Tag these notes': '为这些笔记添加标签',
    'Select cards': '选择卡片', 'Ungroup': '取消分组', 'Align': '对齐', 'Left': '左对齐',
    'Top': '顶部对齐', 'Row': '排列为一行', 'Column': '排列为一列', 'Merge': '合并',
    'Remove from board': '从画板移除', 'Actions': '操作', 'Open note': '打开笔记',
    'Focus': '聚焦', 'Unfocus': '取消聚焦', 'Edit text': '编辑文本', 'Make it a note': '转为笔记',
    'Detach': '分离', 'Export': '导出', '+ Add notes': '+ 添加笔记', 'Suggest links': '建议链接',
    'Show everything': '显示全部', 'The whole board, attached to this note. Exporting again replaces it.': '将完整画板附加到此笔记；再次导出会替换它。',
    'This note is gone. Its links stay until you remove the card.': '这篇笔记已不存在。移除卡片前，它的链接仍会保留。',
    'boards': '画板', 'not recorded': '未记录', 'read-only': '只读', 'merging…': '正在合并…',
    'thinking…': '正在思考…', 'exporting…': '正在导出…', 'saving…': '正在保存…',
    'unsaved': '未保存', 'saved': '已保存', 'board': '画板', 'mock host': '模拟宿主',
    'This board is empty.': '此画板为空。', 'This board is read-only.': '此画板为只读。',
    'Nothing is drawn here.': '这里没有任何内容。',
    'This board is empty. Add notes from the bar below, or press and hold anywhere to leave a sticky - its bar turns that sticky into a real note.': '此画板为空。请从下方工具栏添加笔记，或长按任意位置放置便签；便签工具栏可将它转为真正的笔记。',
    'Cancel': '取消', 'Keep mine': '保留我的版本', 'Use theirs': '使用另一版本',
    'Replace it': '替换', 'Leave anyway': '仍然离开', 'Overwrite': '覆盖',
    'The note picker is already open.': '笔记选择器已打开。',
    'Those notes could not be put on the board.': '无法将这些笔记放到画板上。',
    'That card is no longer on the board.': '该卡片已不在画板上。',
    'A link needs two different cards. Drop it on another one.': '链接需要两张不同的卡片。请拖到另一张卡片上。',
    'One of those is no longer on the board.': '其中一项已不在画板上。',
    'Those two are already linked.': '这两项已经链接。', 'That link could not be drawn.': '无法绘制该链接。',
    'The line is gone. The note link behind it was left alone.': '连线已移除，背后的笔记链接保持不变。',
    'A group needs at least two cards. Select some more.': '分组至少需要两张卡片。请再选择一些。',
    'That group could not be made.': '无法创建该分组。', 'Aligning needs at least two cards.': '对齐至少需要两张卡片。',
    'Those cards were already aligned.': '这些卡片已经对齐。', 'That could not be placed on the board.': '无法将它放到画板上。',
    'Nothing it was pointing at is on the board, so it floats free.': '它指向的内容都已不在画板上，因此现在成为浮动批注。',
    'The merge screen is open. Finish that first.': '合并页面已打开，请先完成合并。',
    'The merge screen is already open.': '合并页面已经打开。', 'One write at a time - the last one is still going.': '一次只能执行一个写入操作——上一个仍在进行。',
    'Select a sticky first.': '请先选择一张便签。', 'That card is already a note.': '该卡片已经是笔记。',
    'Only a sticky becomes a note.': '只有便签可以转为笔记。',
    'Write something in it first - an empty note is not worth making.': '请先写点内容——无需创建空笔记。',
    'Both ends have to be cards for two different notes. A sticky is not a note.': '两端必须是两篇不同笔记的卡片；便签不是笔记。',
    'One of those notes is gone, so there is nothing to link.': '其中一篇笔记已不存在，因此无法链接。',
    'Those notes are already linked.': '这些笔记已经链接。', 'Both ends have to be note cards.': '两端都必须是笔记卡片。',
    'No note relationship is recorded behind this line.': '这条线背后没有记录笔记关系。',
    'Name the group first: the tag is the group\'s name.': '请先为分组命名：标签将使用分组名称。',
    'Nothing in this group is a note card that still resolves, so there is nothing to tag.': '此分组中没有仍然有效的笔记卡片，因此无法添加标签。',
    'That card\'s note is gone, so there is nothing to tick.': '该卡片对应的笔记已不存在，因此无法勾选。',
    'Only a task can be ticked, and this note is not one.': '只有任务可以勾选，而这篇笔记不是任务。',
    'Merging works on note cards. A sticky and an annotation live only on the board, so they cannot merge.': '只有笔记卡片可以合并。便签和批注只存在于画板中，无法合并。',
    'One of those cards has no note behind it any more, so there is nothing to merge.': '其中一张卡片已没有对应笔记，因此无法合并。',
    'Merging needs two note cards. Drop one onto another, or select two and tap Merge.': '合并需要两张笔记卡片。请将一张拖到另一张上，或选择两张后点按“合并”。',
    'Those cards are the same note, so there is nothing to merge.': '这些卡片指向同一篇笔记，因此无需合并。',
    'Nothing came back from the merge, so the board is exactly as it was.': '合并没有返回内容，画板保持原样。',
    'Still thinking about the last one.': '仍在处理上一次请求。',
    'Apply or discard the suggestions already on the board first.': '请先应用或放弃画板上已有的建议。',
    'Those cards have changed since they were suggested, so there was nothing left to draw.': '提出建议后这些卡片已发生变化，因此没有可绘制的链接。',
    'None of those links could be drawn.': '这些链接都无法绘制。',
    'The suggestions are gone. Nothing was drawn and nothing was saved.': '建议已放弃；没有绘制或保存任何内容。',
    'There is no board here to export.': '这里没有可导出的画板。', 'The last export is still going.': '上一次导出仍在进行。',
    'Apply or discard the suggested links first - they are not part of the board.': '请先应用或放弃建议链接——它们尚不是画板的一部分。',
    'That is not a format this board can write.': '该画板不支持这种导出格式。',
    'There is nothing on this board to draw yet.': '此画板上还没有可绘制的内容。',
    'A picture of this note is still being made.': '仍在生成这篇笔记的图片。',
    'Drag this group handle onto another card to put the two in a visual group.': '将此分组手柄拖到另一张卡片上，以把两者放入可视分组。',
    'A group needs another card. The card is back where it started.': '分组还需要另一张卡片；卡片已回到原位。',
    'A link needs somewhere to land. Drag it onto another card.': '链接需要落点。请将它拖到另一张卡片上。',
    'Drag onto another card to group': '拖到另一张卡片上以分组', 'Drop this suggestion': '放弃此建议',
    'missing': '缺失', 'just now': '刚刚', 'nothing': '无结果', 'Big Bang board': '大爆炸画板'
  };

  var language = 'en-US';
  function setLanguage(tag) {
    var value = String(tag || '').replace(/_/g, '-').toLowerCase();
    language = value === 'zh' || value === 'zh-cn' ? 'zh-CN' : 'en-US';
    if (root.document && root.document.documentElement) root.document.documentElement.lang = language;
    return language;
  }

  function text(value) {
    var source = String(value == null ? '' : value);
    if (language !== 'zh-CN') return source;
    if (Object.prototype.hasOwnProperty.call(ZH, source)) return ZH[source];
    var m;
    if ((m = /^(\d+) of (\d+)$/.exec(source))) return m[1] + ' / ' + m[2];
    if ((m = /^(\d+) selected$/.exec(source))) return '已选择 ' + m[1] + ' 项';
    if ((m = /^(\d+) links? suggested$/.exec(source))) return '建议了 ' + m[1] + ' 条链接';
    if ((m = /^(\d+) boards?( shown)?$/.exec(source))) return m[1] + ' 个画板' + (m[2] ? '（已显示）' : '');
    if ((m = /^(\d+) cards?$/.exec(source))) return m[1] + ' 张卡片';
    if ((m = /^(\d+) minutes? ago$/.exec(source))) return m[1] + ' 分钟前';
    if ((m = /^(\d+) hours? ago$/.exec(source))) return m[1] + ' 小时前';
    if ((m = /^(\d+) days? ago$/.exec(source))) return m[1] + ' 天前';
    if ((m = /^(\d+) weeks? ago$/.exec(source))) return m[1] + ' 周前';
    if ((m = /^(\d+) months? ago$/.exec(source))) return m[1] + ' 个月前';
    if ((m = /^(\d+) years? ago$/.exec(source))) return m[1] + ' 年前';
    if ((m = /^(\d+) notes? are on the board/.exec(source))) return m[1] + ' 篇笔记已放到画板上。';
    if ((m = /^Linking joins exactly two cards\. (\d+) are selected\.$/.exec(source))) return '链接必须恰好连接两张卡片。当前已选择 ' + m[1] + ' 张。';
    if ((m = /^Nothing to suggest: (.+)$/.exec(source))) return '没有可建议的链接：' + m[1];
    if ((m = /^The note could not be read: (.+)$/.exec(source))) return '无法读取笔记：' + m[1];
    if ((m = /^Something went wrong opening this board: (.+)$/.exec(source))) return '打开画板时出错：' + m[1];
    if ((m = /^The boards could not be listed \((.+)\)\.$/.exec(source))) return '无法列出画板（' + m[1] + '）。';
    if ((m = /^The next page of boards could not be read \((.+)\)\.$/.exec(source))) return '无法读取下一页画板（' + m[1] + '）。';
    if ((m = /^(\d+) entr(?:y|ies) in this block could not be read and were left out\.$/.exec(source))) return '此区块中有 ' + m[1] + ' 项无法读取，已忽略。';
    return source;
  }

  setLanguage((root.Synapse && root.Synapse.locale) || (root.navigator && root.navigator.language) || 'en-US');
  BB.i18n = { setLanguage: setLanguage, text: text, get language() { return language; } };
})(typeof window !== 'undefined' ? window : globalThis);
