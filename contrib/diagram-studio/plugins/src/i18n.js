/* Diagram Studio localization. The host language can change while editing. */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.DiagramI18n = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var STRINGS = {
    'en-US': {
      diagrams: 'Diagrams', newDiagram: '+ New diagram', diagramSource: 'Diagram source',
      draw: 'Draw',
      preview: 'Preview', characters: 'Characters', art: 'Art', describe: 'Describe the diagram',
      generate: 'Generate', startOver: 'Start over', refinements: 'Refinements',
      padRectangle: 'Pad to rectangle', above: 'Above source', below: 'Below source',
      imageFormat: 'Image format', imagePosition: 'Where the image goes', showDiagrams: 'Show diagrams in this note',
      addToNote: 'Add to note', replace: 'Replace this {what}', block: 'block', diagram: '{kind} diagram',
      noBlockDiagram: 'This block has no diagram yet — pick a tab and start one.',
      noDiagrams: 'No diagrams found in this note yet.', imageOnly: '(image only)', empty: '(empty)', textBlock: 'text block',
      insertQuestion: 'Where should the new diagram go?', before: 'Before the {name}', after: 'After the {name}', end: 'At the end of the note',
      insertChosen: 'New diagram will be added {where}.', newKind: 'Starting a new {kind} diagram. The “Save” button adds it to the note and leaves the block you were viewing alone.',
      fixAi: 'Fix with AI', asking: 'Asking…', couldNotFix: 'Could not get a fix: {error}',
      rowCol: 'row {row}, col {col}', drawUnavailable: 'The drawing library did not load, so the Draw tab is unavailable.',
      drawStartError: 'The drawing surface could not start: {error}', loading: 'Loading…',
      drawingUnreadable: "This drawing's image could not be read back, so it cannot be edited here. The image in your note is untouched.",
      drawingLoadError: 'Could not load the drawing: {error}', brief: 'brief', revision: 'revision {number}',
      describeFirst: 'Describe the diagram you want first.', generating: 'Generating…', generatedAlt: 'Generated diagram',
      refined: 'Refined from the previous image. If the result looks unrelated rather than edited, this backend may not support image-to-image editing — the instructions are still being accumulated, so keep describing the whole diagram you want.',
      accumulated: 'Generated from the accumulated description.', saving: 'Saving…',
      rasterFallback: 'Could not convert to {format} ({reason}), so the diagram was inserted as SVG.', saved: 'Saved to the note.',
      noNote: 'no note', openOnNote: 'Open Diagram Studio on a note, or on a selected block within one.', selectedBlock: 'selected block', wholeNote: 'whole note',
      mermaidPlaceholder: 'graph TD\n  A[Start] --> B{Choice}\n  B -->|yes| C[Do it]\n  B -->|no| D[Stop]',
      asciiPlaceholder: '+--------+      +--------+\n| Client |----->| Server |\n+--------+      +--------+',
      aiPlaceholder: 'a system architecture diagram with a mobile app, an API gateway and two services',
      clear: 'Clear'
    },
    'zh-CN': {
      diagrams: '图表', newDiagram: '+ 新建图表', diagramSource: '图表源码', preview: '预览', characters: '字符', art: '字符画',
      draw: '手绘',
      describe: '描述图表', generate: '生成', startOver: '重新开始', refinements: '修改记录', padRectangle: '补齐为矩形',
      above: '源码上方', below: '源码下方', imageFormat: '图片格式', imagePosition: '图片插入位置', showDiagrams: '显示此笔记中的图表',
      addToNote: '添加到笔记', replace: '替换此{what}', block: '文本块', diagram: '{kind} 图表',
      noBlockDiagram: '此文本块还没有图表——选择一个标签页开始创建。', noDiagrams: '此笔记中尚未找到图表。', imageOnly: '（仅图片）', empty: '（空）', textBlock: '文本块',
      insertQuestion: '新图表应放在哪里？', before: '放在{name}之前', after: '放在{name}之后', end: '笔记末尾', insertChosen: '新图表将添加到{where}。',
      newKind: '正在新建 {kind} 图表。“保存”会将它添加到笔记，并保留刚才查看的文本块。', fixAi: '用 AI 修复', asking: '正在询问…', couldNotFix: '无法获取修复结果：{error}',
      rowCol: '第 {row} 行，第 {col} 列', drawUnavailable: '绘图库未能加载，手绘标签页不可用。', drawStartError: '无法启动绘图画布：{error}', loading: '正在加载…',
      drawingUnreadable: '无法读取此手绘图的图片，因此不能在这里编辑。笔记中的图片未被修改。', drawingLoadError: '无法加载手绘图：{error}', brief: '初始描述', revision: '修改 {number}',
      describeFirst: '请先描述你想要的图表。', generating: '正在生成…', generatedAlt: '生成的图表',
      refined: '已基于上一张图片细化。如果结果看起来是全新生成而非修改，当前后端可能不支持图生图；系统仍会累积说明，请继续描述完整目标。',
      accumulated: '已根据累积描述生成。', saving: '正在保存…', rasterFallback: '无法转换为 {format}（{reason}），已改用 SVG 插入。', saved: '已保存到笔记。',
      noNote: '无笔记', openOnNote: '请在笔记或其中选中的文本块上打开图表工作室。', selectedBlock: '选中文本块', wholeNote: '整篇笔记',
      mermaidPlaceholder: 'graph TD\n  A[开始] --> B{选择}\n  B -->|是| C[执行]\n  B -->|否| D[停止]',
      asciiPlaceholder: '+--------+      +--------+\n| 客户端 |----->| 服务端 |\n+--------+      +--------+',
      aiPlaceholder: '包含移动应用、API 网关和两个服务的系统架构图', clear: '清空'
    }
  };

  var language = 'en-US';
  function pick(tag) {
    var normalized = String(tag || '').replace(/_/g, '-').toLowerCase();
    if (normalized === 'zh-cn' || normalized === 'zh') return 'zh-CN';
    return 'en-US';
  }
  function t(key, vars) {
    var value = (STRINGS[language] && STRINGS[language][key]) || STRINGS['en-US'][key] || key;
    Object.keys(vars || {}).forEach(function (name) {
      value = value.replace(new RegExp('\\{' + name + '\\}', 'g'), String(vars[name]));
    });
    return value;
  }
  function setLanguage(tag) {
    language = pick(tag);
    document.documentElement.lang = language;
    return language;
  }
  function editorLocalization() {
    try {
      return typeof jsdraw !== 'undefined' && jsdraw.getLocalizationTable
        ? jsdraw.getLocalizationTable([language]) : undefined;
    } catch (_) { return undefined; }
  }
  setLanguage((typeof window !== 'undefined' && window.Synapse && window.Synapse.locale) ||
    (typeof navigator !== 'undefined' && navigator.language) || 'en-US');
  return { STRINGS: STRINGS, t: t, setLanguage: setLanguage, editorLocalization: editorLocalization, get language() { return language; } };
});
