(function () {
  'use strict';

  var Core = window.FormulaCore;
  var Evaluator = window.FormulaEvaluator;
  var Writeback = window.FormulaWriteback;
  var I18n = window.FormulaI18n;
  var EngineLibrary = window.ComputeEngine;
  var SynapseApi = window.Synapse;

  var translator = I18n
    ? I18n.createTranslator(navigator.language || document.documentElement.lang)
    : { language: 'en', text: function (key) { return key; } };
  var t = translator.text;
  var $ = function (id) { return document.getElementById(id); };

  var state = {
    notes: [],
    note: null,
    writer: null,
    content: '',
    units: [],
    target: null,
    currentUnit: null,
    originalBody: '',
    originalKind: 'display',
    draft: '',
    kind: 'display',
    dirty: false,
    pendingBelow: '',
    lastCalculation: null,
    selectedAction: null,
    inspection: { valid: false, variables: [] },
    precision: 10,
    angleUnit: 'radians',
    screen: null,
    returnToEditor: false,
    inspectTimer: null,
    saving: false,
  };

  var screens = ['notePicker', 'formulaPicker', 'noFormulaScreen', 'editorScreen'];
  var parameterActions = {
    substitute: true,
    solve: true,
    derivative: true,
    integral: true,
    definiteIntegral: true,
    numericIntegral: true,
    limit: true,
  };

  function applyTranslations() {
    document.documentElement.lang = translator.language;
    document.title = t('title');
    Array.prototype.forEach.call(document.querySelectorAll('[data-i18n]'), function (node) {
      node.textContent = t(node.getAttribute('data-i18n'));
    });
    Array.prototype.forEach.call(
      document.querySelectorAll('[data-i18n-aria-label]'),
      function (node) {
        node.setAttribute(
          'aria-label',
          t(node.getAttribute('data-i18n-aria-label'))
        );
      }
    );
  }

  function showScreen(id) {
    screens.forEach(function (screen) { $(screen).classList.toggle('hidden', screen !== id); });
    state.screen = id;
    $('editorFooter').classList.toggle('hidden', id !== 'editorScreen');
    $('pickerBack').classList.toggle(
      'hidden',
      !(id === 'formulaPicker' && (state.returnToEditor || state.notes.length > 1))
    );
  }

  function setStatus(message, kind) {
    var box = $('status');
    if (!message) {
      box.className = 'status hidden';
      box.textContent = '';
      return;
    }
    box.textContent = message;
    box.className = 'status' + (kind ? ' ' + kind : '');
  }

  function showBootError(message) {
    $('app').classList.add('hidden');
    $('bootError').textContent = message;
    $('bootError').classList.remove('hidden');
  }

  function formulaOptions() {
    return { legacySingleDollar: !!(state.note && state.note.isBlockScope) };
  }

  function rescan(content) {
    state.content = String(content == null ? '' : content);
    state.units = Core.scanFormulas(state.content, formulaOptions());
  }

  function noteScopeLabel(note) {
    return note && note.isBlockScope ? t('selectedBlock') : t('wholeNote');
  }

  function renderNotePicker() {
    var list = $('noteList');
    list.innerHTML = '';
    state.notes.forEach(function (note) {
      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'list-button';
      button.innerHTML =
        '<span class="list-main"><span class="list-title"></span>' +
        '<span class="list-subtitle"></span></span><span class="chevron">›</span>';
      button.querySelector('.list-title').textContent = note.title || t('title');
      button.querySelector('.list-subtitle').textContent = noteScopeLabel(note);
      button.addEventListener('click', function () { selectNote(note); });
      list.appendChild(button);
    });
    $('noteTitle').textContent = '';
    $('scopeBadge').textContent = '';
    $('formulaListButton').classList.add('hidden');
    showScreen('notePicker');
  }

  function freshWriter(note) {
    return Writeback.createWriter({
      synapse: SynapseApi,
      core: Core,
      note: note,
    });
  }

  function selectNote(selected) {
    $('noteTitle').textContent = selected.title || '';
    $('scopeBadge').textContent = noteScopeLabel(selected);
    var probe = freshWriter(selected);
    return probe.readFreshContent().then(function (fresh) {
      if (fresh == null) throw new Error(t('loadFailed'));
      state.note = Object.assign({}, selected, { content: fresh });
      state.writer = freshWriter(state.note);
      state.target = null;
      state.currentUnit = null;
      state.dirty = false;
      state.pendingBelow = '';
      rescan(fresh);
      routeSelectedNote();
    }).catch(function (error) {
      showBootError(error && error.message ? error.message : t('loadFailed'));
    });
  }

  function routeSelectedNote() {
    $('formulaListButton').classList.remove('hidden');
    if (!state.note.isBlockScope) {
      state.returnToEditor = false;
      renderFormulaPicker();
      return;
    }
    if (!state.content.trim()) {
      openNewFormula();
    } else if (state.units.length === 1) {
      openFormula(state.units[0]);
    } else if (state.units.length > 1) {
      state.returnToEditor = false;
      renderFormulaPicker();
    } else {
      showScreen('noFormulaScreen');
    }
  }

  function renderFormulaPicker() {
    var list = $('formulaList');
    list.innerHTML = '';
    $('formulaPickerHint').textContent = state.note ? (state.note.title || '') : '';
    state.units.forEach(function (unit, index) {
      var button = document.createElement('button');
      button.type = 'button';
      button.className = 'list-button';
      button.innerHTML =
        '<span class="list-main"><span class="list-title"></span>' +
        '<span class="list-subtitle"></span></span><span class="chevron">›</span>';
      button.querySelector('.list-title').textContent =
        (index + 1) + '. ' + (unit.kind === 'inline' ? t('inline') : t('display'));
      button.querySelector('.list-subtitle').textContent = Core.formulaPreview(unit);
      button.addEventListener('click', function () { openFormula(unit); });
      list.appendChild(button);
    });
    $('addFormulaButton').classList.toggle('hidden', !!state.note.isBlockScope);
    showScreen('formulaPicker');
  }

  function openFormula(unit) {
    state.currentUnit = unit;
    state.target = Core.createTarget(state.content, unit);
    state.originalBody = unit.body;
    state.originalKind = unit.kind;
    state.kind = unit.kind;
    state.draft = unit.body;
    state.pendingBelow = '';
    state.lastCalculation = null;
    state.dirty = false;
    state.returnToEditor = true;
    prepareEditor();
  }

  function openNewFormula() {
    state.currentUnit = null;
    state.target = { mode: 'append' };
    state.originalBody = '';
    state.originalKind = 'display';
    state.kind = 'display';
    state.draft = '';
    state.pendingBelow = '';
    state.lastCalculation = null;
    state.dirty = false;
    state.returnToEditor = true;
    prepareEditor();
  }

  function prepareEditor() {
    setStatus('', '');
    $('resultPanel').classList.add('hidden');
    $('parameterPanel').classList.add('hidden');
    $('pendingBelow').classList.add('hidden');
    $('legacyNotice').classList.toggle(
      'hidden',
      !(state.currentUnit && state.currentUnit.legacy)
    );
    setEditorMode('visual');
    setKind(state.kind, false);
    $('formulaField').value = state.draft;
    $('latexSource').value = state.draft;
    updateDirty();
    inspectDraft();
    showScreen('editorScreen');
    setTimeout(function () { $('formulaField').focus(); }, 0);
  }

  function setEditorMode(mode) {
    var visual = mode !== 'source';
    if (visual) $('formulaField').value = state.draft;
    else $('latexSource').value = state.draft;
    $('visualEditor').classList.toggle('hidden', !visual);
    $('latexSource').classList.toggle('hidden', visual);
    Array.prototype.forEach.call($('editorMode').querySelectorAll('button'), function (button) {
      button.classList.toggle('active', button.getAttribute('data-mode') === mode);
    });
    (visual ? $('formulaField') : $('latexSource')).focus();
  }

  function setKind(kind, markDirty) {
    state.kind = kind === 'inline' ? 'inline' : 'display';
    $('formulaField').classList.toggle('inline-mode', state.kind === 'inline');
    Array.prototype.forEach.call($('formulaKind').querySelectorAll('button'), function (button) {
      button.classList.toggle('active', button.getAttribute('data-kind') === state.kind);
    });
    if (markDirty !== false) updateDirty();
  }

  function setDraft(value) {
    state.draft = String(value == null ? '' : value);
    updateDirty();
    scheduleInspect();
  }

  function insertVisualTemplate(template) {
    setEditorMode('visual');
    var field = $('formulaField');
    field.insert(template, {
      insertionMode: 'replaceSelection',
      selectionMode: 'placeholder',
    });
    $('latexSource').value = field.value;
    setDraft(field.value);
    field.focus();
  }

  function updateDirty() {
    state.dirty =
      state.draft !== state.originalBody ||
      state.kind !== state.originalKind ||
      !!state.pendingBelow;
    var isNewAndEmpty = !state.currentUnit && !state.draft.trim();
    $('saveButton').disabled = state.saving || !state.dirty || isNewAndEmpty;
  }

  function scheduleInspect() {
    clearTimeout(state.inspectTimer);
    state.inspectTimer = setTimeout(inspectDraft, 120);
  }

  function inspectDraft() {
    state.inspection = Evaluator.inspect(
      EngineLibrary,
      state.draft,
      { precision: state.precision, angleUnit: state.angleUnit }
    );
    var valid = state.inspection.valid;
    Array.prototype.forEach.call($('actionGrid').querySelectorAll('[data-action]'), function (button) {
      var action = button.getAttribute('data-action');
      var needsVariable = !!parameterActions[action];
      button.disabled = !valid || (needsVariable && !state.inspection.variables.length);
    });

    var hint = $('calculationHint');
    if (valid || state.inspection.empty) {
      hint.classList.add('hidden');
    } else {
      hint.textContent = state.inspection.tooLarge
        ? t('tooLarge')
        : t('calculationUnavailable');
      hint.className = 'notice';
    }
    populateVariables();
    if (!valid) {
      $('parameterPanel').classList.add('hidden');
      $('resultPanel').classList.add('hidden');
      state.lastCalculation = null;
    }
  }

  function populateVariables() {
    var select = $('variable');
    var previous = select.value;
    select.innerHTML = '';
    (state.inspection.variables || []).forEach(function (variable) {
      var option = document.createElement('option');
      option.value = variable;
      option.textContent = variable;
      select.appendChild(option);
    });
    if (state.inspection.variables.indexOf(previous) !== -1) select.value = previous;
  }

  function chooseAction(action, button) {
    state.selectedAction = action;
    Array.prototype.forEach.call($('actionGrid').querySelectorAll('[data-action]'), function (item) {
      item.classList.toggle('active', item === button);
    });
    if (!parameterActions[action]) {
      $('parameterPanel').classList.add('hidden');
      calculate(action);
      return;
    }

    $('parameterPanel').classList.remove('hidden');
    $('valueRow').classList.toggle('hidden', action !== 'substitute');
    var bounded = action === 'definiteIntegral' || action === 'numericIntegral';
    $('lowerRow').classList.toggle('hidden', !bounded);
    $('upperRow').classList.toggle('hidden', !bounded);
    $('pointRow').classList.toggle('hidden', action !== 'limit');
    populateVariables();
  }

  function calculationParams() {
    return {
      variable: $('variable').value,
      value: $('substitutionValue').value.trim(),
      lower: $('lowerBound').value.trim(),
      upper: $('upperBound').value.trim(),
      point: $('limitPoint').value.trim(),
    };
  }

  function calculate(action) {
    if (!action) return;
    $('calculationHint').classList.add('hidden');
    $('resultPanel').classList.add('hidden');
    setTimeout(function () {
      var result = Evaluator.calculate(
        EngineLibrary,
        action,
        state.draft,
        calculationParams(),
        { precision: state.precision, angleUnit: state.angleUnit }
      );
      if (!result.ok) {
        state.lastCalculation = null;
        var hint = $('calculationHint');
        hint.textContent = result.tooLarge
          ? t('tooLarge')
          : (result.reason === 'timeout' ? t('timeout') : t('calculationFailed'));
        hint.className = 'notice';
        return;
      }
      state.lastCalculation = result;
      $('resultField').value = result.statementLatex;
      $('resultPanel').classList.remove('hidden');
      $('resultWarning').classList.toggle('hidden', !result.noClosedForm);
      $('resultWarning').textContent = result.noClosedForm ? t('noClosedForm') : '';
    }, 0);
  }

  function applyCalculation(mode) {
    if (!state.lastCalculation) return;
    var latex = Evaluator.applicationLatex(state.lastCalculation, mode);
    if (mode === 'below') {
      state.pendingBelow = latex;
      $('pendingBelow').classList.remove('hidden');
      updateDirty();
    } else {
      state.pendingBelow = '';
      $('pendingBelow').classList.add('hidden');
      state.draft = latex;
      $('formulaField').value = latex;
      $('latexSource').value = latex;
      updateDirty();
      inspectDraft();
    }
    setStatus(t('resultApplied'), 'success');
  }

  function persistedPreferences() {
    return {
      prefs: {
        precision: state.precision,
        angleUnit: state.angleUnit,
      },
    };
  }

  function loadPreferences() {
    if (!SynapseApi || typeof SynapseApi.loadAppState !== 'function') {
      return Promise.resolve();
    }
    return Promise.resolve(SynapseApi.loadAppState()).then(function (response) {
      var prefs = response && response.success && response.data && response.data.prefs;
      if (!prefs) return;
      state.precision = Evaluator.clampPrecision(prefs.precision);
      state.angleUnit = prefs.angleUnit === 'degrees' ? 'degrees' : 'radians';
    }).catch(function () { /* defaults remain */ });
  }

  function persistPreferences() {
    if (!SynapseApi || typeof SynapseApi.storeAppState !== 'function') return;
    Promise.resolve(SynapseApi.storeAppState(persistedPreferences()))
      .catch(function () { /* preferences are best-effort */ });
  }

  function refreshPreferenceControls() {
    $('precision').value = String(state.precision);
    $('angleUnit').value = state.angleUnit;
  }

  function save() {
    if (state.saving || !state.writer || !state.target) return;
    if (state.currentUnit && !state.draft.trim() && !window.confirm(t('removeConfirm'))) return;
    if (!state.currentUnit && !state.draft.trim()) return;

    state.saving = true;
    $('saveButton').textContent = t('saving');
    updateDirty();
    setStatus('', '');
    state.writer.save({
      target: state.target,
      body: state.draft,
      kind: state.kind,
      insertBelow: state.pendingBelow,
    }).then(function (result) {
      state.saving = false;
      $('saveButton').textContent = t('save');
      state.note.content = result.content;
      rescan(result.content);

      if (!state.draft.trim()) {
        state.dirty = false;
        state.pendingBelow = '';
        if (state.note.isBlockScope) showScreen('noFormulaScreen');
        else renderFormulaPicker();
        return;
      }

      var closest = null;
      state.units.forEach(function (unit) {
        if (unit.kind !== state.kind || unit.body !== state.draft) return;
        if (!closest ||
            Math.abs(unit.start - (state.target.originalOffset || 0)) <
            Math.abs(closest.start - (state.target.originalOffset || 0))) {
          closest = unit;
        }
      });
      if (closest) {
        state.currentUnit = closest;
        state.target = Core.createTarget(state.content, closest);
      }
      state.originalBody = state.draft;
      state.originalKind = state.kind;
      state.pendingBelow = '';
      state.dirty = false;
      $('pendingBelow').classList.add('hidden');
      updateDirty();
      var message = result.normalizedLegacy
        ? t('normalized')
        : (result.relocated ? t('relocated') : t('saved'));
      setStatus(message, 'success');
    }).catch(function (error) {
      state.saving = false;
      $('saveButton').textContent = t('save');
      updateDirty();
      setStatus(error && error.message ? error.message : t('calculationFailed'), 'error');
    });
  }

  function refreshFormulaPicker() {
    if (state.dirty && !window.confirm(t('discardConfirm'))) return;
    state.dirty = false;
    state.pendingBelow = '';
    state.writer.readFreshContent().then(function (fresh) {
      if (fresh == null) throw new Error(t('loadFailed'));
      state.note.content = fresh;
      state.writer = freshWriter(state.note);
      state.target = null;
      state.currentUnit = null;
      state.returnToEditor = false;
      rescan(fresh);
      renderFormulaPicker();
    }).catch(function (error) {
      setStatus(error && error.message ? error.message : t('loadFailed'), 'error');
    });
  }

  function wireEvents() {
    var formulaField = $('formulaField');
    formulaField.smartFence = true;
    formulaField.smartMode = true;
    formulaField.mathVirtualKeyboardPolicy = 'auto';

    formulaField.addEventListener('input', function () {
      $('latexSource').value = formulaField.value;
      setDraft(formulaField.value);
    });
    $('latexSource').addEventListener('input', function () {
      formulaField.value = $('latexSource').value;
      setDraft($('latexSource').value);
    });

    Array.prototype.forEach.call($('editorMode').querySelectorAll('button'), function (button) {
      button.addEventListener('click', function () {
        setEditorMode(button.getAttribute('data-mode'));
      });
    });
    Array.prototype.forEach.call($('formulaKind').querySelectorAll('button'), function (button) {
      button.addEventListener('click', function () {
        setKind(button.getAttribute('data-kind'), true);
      });
    });
    $('fractionButton').addEventListener('click', function () {
      insertVisualTemplate($('fractionButton').getAttribute('data-template'));
    });
    Array.prototype.forEach.call($('actionGrid').querySelectorAll('[data-action]'), function (button) {
      button.addEventListener('click', function () {
        if (!button.disabled) chooseAction(button.getAttribute('data-action'), button);
      });
    });

    $('calculateButton').addEventListener('click', function () {
      calculate(state.selectedAction);
    });
    $('appendResult').addEventListener('click', function () { applyCalculation('append'); });
    $('insertResultBelow').addEventListener('click', function () { applyCalculation('below'); });
    $('replaceWithResult').addEventListener('click', function () { applyCalculation('replace'); });
    $('clearBelow').addEventListener('click', function () {
      state.pendingBelow = '';
      $('pendingBelow').classList.add('hidden');
      updateDirty();
    });

    $('precision').addEventListener('change', function () {
      state.precision = Evaluator.clampPrecision($('precision').value);
      $('precision').value = String(state.precision);
      persistPreferences();
      inspectDraft();
    });
    $('angleUnit').addEventListener('change', function () {
      state.angleUnit = $('angleUnit').value === 'degrees' ? 'degrees' : 'radians';
      persistPreferences();
      inspectDraft();
    });

    $('saveButton').addEventListener('click', save);
    $('addFormulaButton').addEventListener('click', openNewFormula);
    $('createDisplayButton').addEventListener('click', openNewFormula);
    $('formulaListButton').addEventListener('click', refreshFormulaPicker);
    $('pickerBack').addEventListener('click', function () {
      if (state.returnToEditor && state.target) showScreen('editorScreen');
      else if (state.notes.length > 1) renderNotePicker();
    });

    window.addEventListener('beforeunload', function (event) {
      if (!state.dirty) return;
      event.preventDefault();
      event.returnValue = '';
    });
  }

  function start() {
    applyTranslations();
    if (!Core ||
        !Evaluator ||
        !Writeback ||
        !I18n ||
        !window.MathfieldElement ||
        !EngineLibrary ||
        typeof EngineLibrary.ComputeEngine !== 'function' ||
        !SynapseApi) {
      showBootError(t('missingLibraries'));
      return;
    }

    wireEvents();
    state.notes = Array.isArray(SynapseApi.Notes) ? SynapseApi.Notes.slice() : [];
    loadPreferences().then(function () {
      refreshPreferenceControls();
      if (!state.notes.length) {
        showBootError(t('noNotes'));
      } else if (state.notes.length > 1) {
        renderNotePicker();
      } else {
        selectNote(state.notes[0]);
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
