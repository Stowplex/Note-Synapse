/*
 * Gantt app wiring (plan §10, §12.1, §15.1): boot, the launch matrix (M4),
 * the home screen, the chooser's "Open in <chart>", banners, navigation
 * (M5: gestures.js on #gantt, the zoom buttons, Today, Fit all, header
 * taps, keyboard keys, no page zoom) and editing (M6, §13): selection and
 * the task sheet, MOVE, RESIZE and REORDER drags with snapping, undo and
 * redo, the save pill, the one-time approval notice, the journal banners
 * (Restore, Discard, Copy chart JSON, Retry, Edit anyway), the conflict
 * sheet, Repair, chart rename and the FAB.
 * M7 (§8, §10.2, §10.3, §13.4, §13.5): chart membership (add existing
 * notes, create a task note, remove with undo), New chart, the full
 * plain-note chooser and the multi-note page, and the task sheet's
 * completion list with checkbox, subnote and child-task toggles.
 * M8 (§5.4, §12.6, §12.7, §13.5): the chart settings sheet (undoable,
 * saved), Display and Appearance prefs (device view state, D5), the
 * legend, the empty, all-collapsed, unscheduled, loading and read-only
 * states, the name column divider and reduced motion.
 *
 * Every chart edit is a pure model transform whose inverse goes on the undo
 * stack (D6); the chart goes to store.commit (a gesture saves at once,
 * bursty input after the debounce, §9.1.2). Read-only (journalHold, a
 * future or damaged block, a second block, the embed) refuses every edit.
 *
 * Only host.js reaches the host (D25): locale, theme and space arrive
 * through GT.host and are fed into i18n and theme from here. Note-derived
 * text goes into the DOM with textContent only. A literal </script> must
 * never appear in a string here (build.sh escapes it, the pin test checks).
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var A = (GT.app = {});

  var I = function () { return GT.i18n; };
  function T(s) { return GT.i18n.text(s); }
  function isObj(x) { return !!x && typeof x === 'object' && !Array.isArray(x); }

  A.SAVE_VIEW_MS = 600;          // debounce for the per-chart view state
  A.SKELETON_MS = 150;           // a chart read slower than this shows the skeleton (§12.6)
  A.HOME_RECENTS = 5;            // §10.2

  var S = (A.S = { booted: false, mode: null, store: null, view: null, host: null, session: null, route: null, launch: null });

  /* ------------------------------------------------------------- helpers */

  var doc = null, win = null;
  function $(id) { return doc.getElementById(id); }
  function el(tag, cls, text) {
    var e = doc.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }
  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  // "3 days ago" in the UI language.
  A.ago = function (ms, nowMs) {
    if (typeof ms !== 'number' || !isFinite(ms)) return '';
    var diff = (ms - nowMs) / 1000, abs = Math.abs(diff);
    var steps = [[60, 'second', 1], [3600, 'minute', 60], [86400, 'hour', 3600], [604800, 'day', 86400],
      [2629800, 'week', 604800], [31557600, 'month', 2629800], [Infinity, 'year', 31557600]];
    for (var i = 0; i < steps.length; i++) {
      if (abs < steps[i][0]) {
        var v = Math.round(diff / steps[i][2]);
        try { return new Intl.RelativeTimeFormat(I().language, { numeric: 'auto' }).format(v, steps[i][1]); } catch (e) { return ''; }
      }
    }
    return '';
  };

  // M9 (§15.1): each menu, form and list the app opens records how to open
  // it again, so a locale change can redraw it in place (sheet.relabel).
  function reg(again) { S.again = again; S.againSpec = S.sheet.spec(); }
  // Home, chooser and state pages record how to draw themselves again too.
  function redrawWith(fn) { S.redraw = fn; fn(); }

  function applyI18n() {
    doc.documentElement.lang = I().language === 'zh-CN' ? 'zh-CN' : 'en';
    Array.prototype.forEach.call(doc.querySelectorAll('[data-i18n]'), function (n) { n.textContent = T(n.getAttribute('data-i18n')); });
    Array.prototype.forEach.call(doc.querySelectorAll('[data-i18n-label]'), function (n) { n.setAttribute('aria-label', T(n.getAttribute('data-i18n-label'))); });
  }

  function setTitle(text) { $('title').textContent = text; }
  function chrome(mode) {
    S.mode = mode;
    var chart = mode === 'chart';
    var g = $('gantt'), shown = chart && g.hidden;
    g.hidden = !chart;
    $('home').hidden = chart;
    doc.body.classList.toggle('mode-chart', chart);
    // One size read when the chart appears (outside any frame): the
    // ResizeObserver reports it too, but only at the next rendering step.
    if (shown && S.view) { S.view.countLayoutRead(2); S.view.setSize(g.clientWidth, g.clientHeight); }
    $('btnHome').hidden = mode === 'home';
    $('btnToday').hidden = !chart;
    if (!chart) { hideBanner(); if (S.sheet && S.sheet.isOpen()) S.sheet.close(); hideNotice(); }
    syncUi();
  }

  /* ------------------------------------------------------------- banners */

  function hideBanner() {
    var b = $('banner'), had = b.contains(doc.activeElement);
    if (!b.hidden) { b.hidden = true; clear(b); }
    b.removeAttribute('data-kind');
    if (had) restoreFocus();
  }
  function banner(text, actions, kind) {
    var b = $('banner'), had = b.contains(doc.activeElement);
    clear(b);
    b.appendChild(el('div', 'b-text', text));
    (actions || []).forEach(function (a) {
      var btn = el('button', null, a.label);
      btn.type = 'button';
      if (a.id) btn.setAttribute('data-action', a.id);
      // The banner may be gone after its action: focus goes to the chart.
      btn.addEventListener('click', function () { a.run(); restoreFocus(); });
      b.appendChild(btn);
    });
    b.setAttribute('data-kind', kind || '');
    b.hidden = false;
    // A banner redrawn under the keyboard focus keeps it on its first button.
    if (had) { var f = b.querySelector('button'); if (f) f.focus(); else restoreFocus(); }
  }
  var BANNERS = {
    future: 'This chart was made by a newer version of Gantt. It is read-only.',
    malformed: 'The chart block in this note is damaged, so nothing is shown.',
    'check-failed': 'Couldn’t check for unsaved changes.',
    restore: 'Unsaved changes from an earlier session are kept for this chart.',
    kept: 'Unsaved chart edits exist for this note.',
    'read-only': 'This chart can’t be saved. Your changes are kept and offered again next time.'
  };
  A.bannerText = function (kind) { return BANNERS[kind] ? T(BANNERS[kind]) : ''; };
  var lastBanner = '';
  // "A, B, C and 2 more" for a banner (the first three titles).
  function titlesOf(ids) {
    var names = ids.slice(0, 3).map(function (id) { return titleOf(id); });
    if (ids.length > 3) names.push(I().fmt('{n} more', { n: ids.length - 3 }));
    return I().list(names);
  }
  function showBanner() {
    var s = S.session;
    if (S.mode !== 'chart' || !s || S.store.session !== s) return;
    var ui = S.store.ui(), J = S.store.journal;
    var kind = ui.banner, text = '', acts = [];
    if (kind === 'check-failed') {
      text = A.bannerText(kind);
      acts = [{ id: 'retry', label: T('Retry'), run: function () { J.retry().then(syncUi); } },
        { id: 'edit-anyway', label: T('Edit anyway'), run: function () { J.editAnyway(); syncUi(); } }];
    } else if (kind === 'restore') {
      text = ui.offer && typeof ui.offer.at === 'number' ? I().fmt('Unsaved changes from {when}.', { when: A.ago(ui.offer.at, S.now()) }) : A.bannerText(kind);
      acts = [{ id: 'restore', label: T('Restore'), run: A.restore },
        { id: 'discard', label: T('Discard'), run: A.discard },
        { id: 'copy', label: T('Copy chart JSON'), run: function () { A.copyJson(s.offer && s.offer.entry.chart); } }];
    } else if (kind === 'kept') {
      // Kept for a block that is not ok: the status first, then the entry.
      text = (s.status === 'future' || s.status === 'malformed' ? A.bannerText(s.status) + ' ' : '') + A.bannerText(kind);
      acts = [{ id: 'copy', label: T('Copy chart JSON'), run: function () { A.copyJson(s.kept && s.kept.chart); } }];
    } else if (kind === 'malformed') {
      text = A.bannerText(kind);
      if (!S.launch.embed) acts = [{ id: 'repair', label: T('Repair'), run: function () { A.confirmRepair('malformed'); } }];
    } else if (kind) {
      text = A.bannerText(kind);
    } else if (s.extra) {
      text = T('This note has more than one chart. The first one is shown.');
      if (!S.launch.embed) acts = [{ id: 'first', label: T('Use the first block'), run: function () { A.confirmRepair('extra'); } }];
      kind = 'extra';
    } else if (editable()) {
      // M9 reconciliation (§5.1): task lines the user deleted from the list
      // above the chart. Nothing changes until one of the buttons is tapped.
      var gap = S.store.mirrorGap();
      if (gap && gap.deleted.length) {
        kind = 'mirror-gone';
        text = I().fmt('Removed in the note: {titles}. Remove from chart?', { titles: titlesOf(gap.deleted) });
        acts = [{ id: 'remove-gone', label: T('Remove'), run: function () { A.removeGone(gap.deleted); } },
          { id: 'restore-list', label: T('Restore list'), run: function () { A.restoreList(); } }];
      } else if (gap && gap.edited.length && s.mirrorAck !== gap.edited.join(',')) {
        kind = 'mirror-edited';
        text = T('The task list above the chart was edited. It is kept as your text.');
        acts = [{ id: 'mirror-ok', label: T('Got it'), run: function () { s.mirrorAck = gap.edited.join(','); syncUi(); } }];
      }
    }
    if (!text) { lastBanner = ''; hideBanner(); return; }
    // Rebuilt only when it changed, so a button under a finger stays put.
    var key = kind + '|' + text + '|' + acts.map(function (a) { return a.id; }).join(',');
    if (key === lastBanner && !$('banner').hidden) return;
    lastBanner = key;
    banner(text, acts, kind);
  }

  /* --------------------------------------------------------- state pages */

  function page(title, text, actions) {
    chrome('state');
    var h = $('home');
    clear(h);
    var box = el('div', 'h-state');
    box.appendChild(el('strong', null, title));
    if (text) box.appendChild(el('div', null, text));
    (actions || []).forEach(function (a) {
      var btn = el('button', null, a.label);
      btn.type = 'button';
      btn.addEventListener('click', a.run);
      box.appendChild(btn);
    });
    h.appendChild(box);
  }

  var GLYPH = {
    chart: 'M4 6h9M7 12h11M5 18h7',
    add: 'M12 5v14M5 12h14',
    convert: 'M6 3h9l4 4v14H6zM9 12h7M9 16h4',
    create: 'M4 6h9M7 12h5M5 18h5M17 14v7M13.5 17.5h7'
  };
  function row(opts) {
    var b = el('button', 'h-row' + (opts.cls ? ' ' + opts.cls : ''));
    b.type = 'button';
    if (opts.id) b.setAttribute('data-id', opts.id);
    if (opts.icon !== false) {
      var ico = el('span', 'h-ico');
      // Constant path data only (never note text): a chart, or an action glyph.
      ico.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="' +
        (GLYPH[opts.icon] || GLYPH.chart) + '"/></svg>';
      b.appendChild(ico);
    }
    var main = el('span', 'h-main');
    main.appendChild(el('div', 'h-t', opts.title));
    if (opts.meta) main.appendChild(el('div', 'h-m', opts.meta));
    b.appendChild(main);
    if (opts.mark) b.appendChild(el('span', 'h-mark', opts.mark));
    if (opts.run) b.addEventListener('click', opts.run);
    return b;
  }

  /* ---------------------------------------------------------------- home */

  var homeSeq = 0;
  A.showHome = function (notice) {
    var seq = ++homeSeq;
    S.redraw = function () { A.showHome(notice); };
    chrome('home');
    setTitle(T('Gantt'));
    var h = $('home');
    clear(h);
    if (notice) h.appendChild(el('div', 'h-note', notice));
    // §10.2: "New chart" asks for a title, an intro and where sub-items come from.
    if (!S.launch.embed) {
      var nb = el('button', 'h-new', T('New chart'));
      nb.type = 'button';
      nb.setAttribute('data-action', 'new-chart');
      nb.addEventListener('click', function () { A.newChartForm(); });
      h.appendChild(nb);
    }
    var nowMs = S.now();
    var recents = S.store.recents().slice(0, A.HOME_RECENTS);
    if (recents.length) {
      h.appendChild(el('h2', null, T('Recents')));
      var rl = el('div', 'h-list');
      rl.setAttribute('data-list', 'recents');
      recents.forEach(function (r) {
        var pending = S.store.journal.pendingForNote(r.id);
        rl.appendChild(row({
          id: r.id, title: r.title || T('Untitled'), meta: A.ago(r.at, nowMs),
          mark: pending ? T('Unsaved changes') : '', run: function () { A.openChart({ noteId: r.id, title: r.title }); }
        }));
      });
      h.appendChild(rl);
    }
    h.appendChild(el('h2', null, T('Charts')));
    var list = el('div', 'h-list');
    list.setAttribute('data-list', 'charts');
    h.appendChild(list);
    var status = el('div', 'h-note', '');
    h.appendChild(status);
    function page2(offset) {
      return S.host.findCharts({ offset: offset }).then(function (r) {
        if (seq !== homeSeq) return r;
        var more = list.querySelector('.h-more');
        if (more) list.removeChild(more);
        if (!r.ok) {
          status.textContent = T('Couldn’t load the charts.');
          var retry = el('button', null, T('Retry'));
          retry.type = 'button';
          retry.addEventListener('click', function () { A.showHome(notice); });
          status.appendChild(retry);
          return r;
        }
        r.charts.forEach(function (c) {
          var bits = [];
          if (typeof c.tasks === 'number') bits.push(I().fmt('{n} task(s)', { n: c.tasks }));
          var when = A.ago(c.updatedAt, S.now());
          if (when) bits.push(when);
          list.appendChild(row({
            id: c.id, title: c.title || T('Untitled'), meta: bits.join(' · '),
            mark: S.store.journal.pendingForNote(c.id) ? T('Unsaved changes') : '',
            run: function () { A.openChart({ noteId: c.id, title: c.title }); }
          }));
        });
        if (r.more) {
          list.appendChild(row({ cls: 'h-more', icon: false, title: T('More'), run: function () { page2(r.next); } }));
        }
        if (!list.firstChild) status.textContent = T('No charts in this Space yet.');
        else status.textContent = '';
        return r;
      });
    }
    S.homeLoaded = page2(0);
    return S.homeLoaded;
  };

  /* ------------------------------------------------------------- chooser */

  function actRow(parent, acts) {
    acts.forEach(function (a) {
      var b = el('button', a.cls || null, a.label);
      b.type = 'button';
      b.setAttribute('data-action', a.id);
      b.addEventListener('click', a.run);
      parent.appendChild(b);
    });
  }
  // The linked notes of a plain note (for "Import N linked notes"): the
  // launch's own content when it is this whole note, else a guarded read.
  function linkCount(noteId) {
    var n = (S.launch.notes || []).filter(function (x) { return x.id === noteId && !x.blockScope; })[0];
    var p = n ? Promise.resolve({ ok: true, content: n.content }) : S.host.readNote(noteId);
    return p.then(function (r) { return r.ok ? GT.md.noteLinkIds(r.content, { exclude: noteId }).length : 0; });
  }

  /*
   * §10.3: item 0 (an unsaved chart for this note: Recreate, Copy chart
   * JSON, Discard), "Open in <chart>" for every chart in the Space that
   * holds the note, then "Add to a chart…", "Turn this note into a chart"
   * (importing its linked notes when it has any) and "New chart starting
   * with this note".
   */
  A.showChooser = function (noteId, title) {
    var seq = ++homeSeq;
    S.redraw = function () { A.showChooser(noteId, title); };
    chrome('chooser');
    setTitle(title || T('Untitled'));
    var h = $('home');
    clear(h);
    var pending = S.store.journal.pendingForNote(noteId);
    if (pending) {
      h.appendChild(el('div', 'h-note', T('Unsaved chart for this note.')));
      var pa = el('div', 'h-acts');
      pa.setAttribute('data-list', 'pending');
      actRow(pa, [
        { id: 'recreate', label: T('Recreate chart'), run: function () { A.recreate(noteId, title, pending); } },
        { id: 'copy', label: T('Copy chart JSON'), run: function () { A.copyJson(pending.chart); } },
        { id: 'discard', label: T('Discard'), cls: 'danger', run: function () { S.store.journal.discard(noteId); A.showChooser(noteId, title); } }
      ]);
      h.appendChild(pa);
    }
    h.appendChild(el('h2', null, T('Charts with this note')));
    var list = el('div', 'h-list');
    list.setAttribute('data-list', 'chooser');
    h.appendChild(list);
    var status = el('div', 'h-note', '');
    h.appendChild(status);
    h.appendChild(el('h2', null, T('This note')));
    var acts = el('div', 'h-list');
    acts.setAttribute('data-list', 'actions');
    var me = [{ id: noteId, title: title || '' }];
    acts.appendChild(row({ id: 'add-to', icon: 'add', title: T('Add to a chart…'), run: function () { A.pickChart(me); } }));
    var conv = row({ id: 'convert', icon: 'convert', title: T('Turn this note into a chart'), run: function () { A.convertForm(noteId, title, conv.links || 0); } });
    acts.appendChild(conv);
    acts.appendChild(row({ id: 'new-with', icon: 'create', title: T('New chart starting with this note'), run: function () { A.newChartForm({ notes: me, title: title || '' }); } }));
    h.appendChild(acts);
    S.chooserLinks = linkCount(noteId).then(function (n) {
      if (seq !== homeSeq) return n;
      conv.links = n;
      if (n > 0) {
        var m = el('div', 'h-m', I().fmt('Import {n} linked note(s) as tasks', { n: n }));
        conv.querySelector('.h-main').appendChild(m);
      }
      return n;
    });
    S.chooserLoaded = S.host.chartsReferencing(noteId).then(function (r) {
      if (seq !== homeSeq) return r;
      if (!r.ok) {
        status.textContent = T('Couldn’t look up charts for this note.');
        var retry = el('button', null, T('Retry'));
        retry.type = 'button';
        retry.addEventListener('click', function () { A.showChooser(noteId, title); });
        status.appendChild(retry);
        return r;
      }
      r.charts.forEach(function (c) {
        list.appendChild(row({
          id: c.id, title: I().fmt('Open in {title}', { title: c.title || T('Untitled') }), meta: A.ago(c.updatedAt, S.now()),
          run: function () { A.openChart({ noteId: c.id, title: c.title, focusNote: noteId }); }
        }));
      });
      if (!r.charts.length) status.textContent = T('This note is not on any chart yet.');
      return r;
    });
    return S.chooserLoaded;
  };

  // §10.1: several notes: a new chart with them, or add them to a chart.
  A.showMulti = function (notes) {
    ++homeSeq;
    S.redraw = function () { A.showMulti(notes); };
    chrome('chooser');
    setTitle(I().fmt('{n} notes', { n: notes.length }));
    var h = $('home');
    clear(h);
    var list = el('div', 'h-list');
    list.setAttribute('data-list', 'multi');
    list.appendChild(row({ id: 'new-with', icon: 'create', title: I().fmt('New chart with these {n} notes', { n: notes.length }), run: function () { A.newChartForm({ notes: notes }); } }));
    list.appendChild(row({ id: 'add-to', icon: 'add', title: T('Add to a chart…'), run: function () { A.pickChart(notes); } }));
    h.appendChild(list);
    var names = el('div', 'h-note', notes.map(function (n) { return n.title || T('Untitled'); }).join(' · '));
    h.appendChild(names);
  };

  // "Add to a chart…": the Space's charts in a menu; a pick opens that
  // chart and adds the notes (skipping any it already holds).
  A.pickChart = function (notes) {
    return S.host.findCharts({ offset: 0 }).then(function (r) {
      if (!r.ok) { A.toast(T('Couldn’t load the charts.')); return r; }
      if (!r.charts.length) { A.toast(T('No charts in this Space yet.')); return r; }
      function menu() {
        S.sheet.openMenu({
          title: T('Add to a chart'), items: r.charts.map(function (c) {
            return { id: c.id, label: c.title || T('Untitled'), hint: typeof c.tasks === 'number' ? I().fmt('{n} task(s)', { n: c.tasks }) : '',
              run: function () { A.addNotesTo(c, notes); } };
          })
        }, 'full');
        reg(menu);
      }
      menu();
      return r;
    });
  };
  A.addNotesTo = function (chart, notes) {
    var one = notes.length === 1 ? notes[0].id : null;
    return A.openChart({ noteId: chart.id, title: chart.title, focusNote: one }).then(function (res) {
      if (!res.ok) return res;
      var s = res.session;
      return s.checked.then(function () {
        if (S.session !== s) return { ok: false, reason: 'superseded' };
        return addNotes(notes);
      });
    });
  };

  // Recreate (item 0): append a fresh region holding the journaled chart.
  A.recreate = function (noteId, title, entry) {
    return openWith({ noteId: noteId, title: title }, function () {
      return S.store.convertNote(noteId, GT.store.chartOf(entry.chart), { title: title });
    }, function () { A.showChooser(noteId, title); });
  };
  A.convertForm = function (noteId, title, links) {
    S.sheet.openForm({
      kind: 'convert', title: T('Turn this note into a chart'),
      text: T('A chart is added at the end of this note. The rest of the note is kept.'),
      fields: links > 0 ? [{ name: 'import', type: 'switch', label: I().fmt('Import {n} linked note(s) as tasks', { n: links }), value: true }] : [],
      actions: [
        { id: 'convert', label: T('Turn into a chart'), primary: true, run: function (v) { A.convert(noteId, title, !!v.import); } },
        { id: 'cancel', label: T('Cancel') }
      ]
    }, 'peek');
    reg(function () { A.convertForm(noteId, title, links); });
  };
  A.convert = function (noteId, title, importLinks) {
    return openWith({ noteId: noteId, title: title }, function () {
      return S.store.convertNote(noteId, null, { importLinks: !!importLinks, title: title });
    }, function () { A.showChooser(noteId, title); });
  };

  /*
   * New chart (§10.2, §10.3 item 4, the multi-note page): a title, an
   * optional intro, where sub-items come from (default sub-notes, D14) and
   * the checklist section, defaulting to the UI language's ("Checklist" or
   * "清单", §15.1), which store.createChart writes into the chart.
   */
  A.newChartForm = function (o) {
    o = o || {};
    var notes = o.notes || [];
    S.sheet.openForm({
      kind: 'new-chart', title: T('New chart'),
      text: notes.length ? I().fmt('The chart starts with {n} task(s).', { n: notes.length }) : '',
      fields: [
        { name: 'title', type: 'text', label: T('Chart title'), value: o.title || '' },
        { name: 'intro', type: 'textarea', label: T('Intro (optional)') },
        { name: 'source', type: 'choice', label: T('Sub-items come from'), value: 'subnotes',
          options: [{ value: 'subnotes', label: T('Sub-notes') }, { value: 'checklist', label: T('Checklist') }] },
        { name: 'section', type: 'text', label: T('Checklist section'), value: GT.md.defaultSection(S.host.locale()),
          showIf: { name: 'source', value: 'checklist' } }
      ],
      actions: [
        { id: 'create', label: T('Create'), primary: true, run: function (v) { A.createChart(Object.assign({ notes: notes }, v)); } },
        { id: 'cancel', label: T('Cancel') }
      ]
    }, 'full');
    reg(function () { A.newChartForm(o); });
  };
  A.createChart = function (v) {
    v = v || {};
    var section = String(v.section == null ? '' : v.section).trim() || GT.md.defaultSection(S.host.locale());
    var spec = {
      title: String(v.title == null ? '' : v.title).trim() || T('New chart'), intro: v.intro || '', notes: v.notes || [],
      settings: { progressSource: v.source === 'checklist' ? 'checklist' : 'subnotes', progressSection: section }
    };
    return openWith({ title: spec.title }, function () { return S.store.createChart(spec); }, function () { A.createChart(v); });
  };

  /* --------------------------------------------------------------- chart */

  function collapsedOf(view) { return view && Array.isArray(view.collapsed) ? view.collapsed.slice() : []; }

  function renderSession(s) {
    if (S.session !== s) return;
    var chart = s.live;
    if (!chart) { S.view.setData({ chart: null }); renderLegend(); return; }
    S.lastEditable = editable();
    watchResolve(s);
    S.view.setData({
      chart: chart, summaries: s.summaries(chart), facts: s.facts,
      today: GT.dates.today(S.now()), collapsed: S.collapsed, editable: S.lastEditable, unknown: !!s.factsFailed
    });
    renderLegend();
  }
  /*
   * A resolve that fails (§7.5: a failed read resolves nothing) leaves
   * stale counts unread: those bars show a static track instead of a
   * shimmer, and a toast says so once per session (M8 review). The next
   * successful resolve (a resume, a commit) clears it.
   */
  function watchResolve(s) {
    var p = s.resolved;
    if (!p || s.watchedResolve === p) return;
    s.watchedResolve = p;
    p.then(function (r) {
      if (S.session !== s || s.resolved !== p) return;
      var failed = !!r && r.ok === false;
      if (failed === !!s.factsFailed) return;
      s.factsFailed = failed;
      if (failed && !s.factsToast) { s.factsToast = true; A.toast(T('Couldn’t read the task notes. Their progress shows once they can be read.')); }
      renderSession(s);
    });
  }

  function initialCamera(s, target) {
    var c = S.store.cache.get(s.noteId);
    var v = c && isObj(c.view) ? c.view : null;
    var spec;
    if (S.launch.embed) spec = { fit: true };
    else if (v && typeof v.ppd === 'number' && typeof v.scrollDay === 'number') spec = { ppd: v.ppd, day: v.scrollDay, sy: v.sy || 0 };
    else {
      var set = s.live ? s.live.settings : {};
      var ppd = GT.scale.PRESETS[set.scale] || GT.scale.PRESETS.week;
      var r = s.live ? GT.model.range(s.live) : null;
      var today = GT.dates.today(S.now());
      spec = { ppd: ppd, day: (r ? r.min : today) - 2, sy: 0 };
    }
    if (target && target.focusNote && s.live) {
      var t = s.live.tasks.filter(function (x) { return x.note === target.focusNote; })[0];
      if (t) spec.focus = t.id;
    }
    return spec;
  }

  var openSeq = 0;
  /*
   * openChart({noteId, read?, title?, focusNote?}): open through the store
   * (it reads the note when there is no read) and show the chart, or the
   * page the §10.1 matrix and the M3a resolve contract name for a failure.
   */
  A.openChart = function (target) {
    return openWith(target, function () { return S.store.open(target); }, function () { A.openChart(target); });
  };
  /*
   * openWith(target, opener, retry): leave the current chart, then show the
   * session opener() resolves: store.open, createChart or convertNote (M7).
   * A convert whose first save failed still shows its unsaved chart (the
   * pill offers the save, the journal keeps it).
   */
  function openWith(target, opener, retry) {
    var seq = ++openSeq;
    if (S.gestures) S.gestures.stop();
    if (S.session) { S.store.onHide('switch'); S.session = null; }
    resetEdit();
    homeSeq++;
    chrome('chart');
    setTitle(target.title || '');
    S.view.setData({ chart: null });
    // §12.6: six skeleton rows while the chart note is read, only when the
    // read takes longer than SKELETON_MS (M8 review: no flash on warm opens).
    var skelTimer = win.setTimeout(function () { if (seq === openSeq && !S.session) { S.skelShown = (S.skelShown || 0) + 1; skeleton(true); } }, A.SKELETON_MS);
    return opener().then(function (res) {
      if (seq !== openSeq) return res;
      win.clearTimeout(skelTimer);
      skeleton(false);
      if (!res.ok && res.session && S.store.session === res.session && res.session.live) res = { ok: true, session: res.session, reason: res.reason };
      if (!res.ok) {
        if (res.reason === 'superseded') return res;
        var id = target.noteId || res.id;
        if (res.reason === 'none') { A.showChooser(id, target.title); return res; }
        if (res.reason === 'already-chart') { A.openChart({ noteId: id, title: target.title }); return res; }
        if (res.reason === 'missing' || res.reason === 'bad-id') {
          redrawWith(function () {
            var acts = [{ label: T('Back to charts'), run: A.goHome }];
            // §9.1.5 Open step 0: the unsaved chart of a deleted note.
            if (res.entry) {
              acts.unshift({ label: T('Copy chart JSON'), run: function () { A.copyJson(res.entry.chart); } },
                { label: T('Discard'), run: function () { S.store.journal.discard(id); A.goHome(); } });
            }
            page(T('Chart not found'), res.entry ? T('The chart note was deleted. Its unsaved chart is kept.') : '', acts);
          });
          return res;
        }
        if (res.reason === 'create-failed' || res.reason === 'embed') {
          redrawWith(function () { page(T('Couldn’t create the chart.'), '', [{ label: T('Retry'), run: retry }, { label: T('Back to charts'), run: A.goHome }]); });
          return res;
        }
        redrawWith(function () { page(T('Couldn’t read the note.'), '', [{ label: T('Retry'), run: res.id ? function () { A.openChart({ noteId: res.id, title: target.title }); } : retry }]); });
        return res;
      }
      var s = res.session;
      S.session = s;
      var cached = S.store.cache.get(s.noteId);
      S.collapsed = collapsedOf(cached && cached.view);
      if (s.title) setTitle(s.title);
      else if (!target.title) setTitle(T('Gantt'));
      renderSession(s);
      S.view.home(initialCamera(s, target));
      syncUi();
      s.resolved.then(function () { renderSession(s); if (S.sheet.isOpen()) S.sheet.update(); });
      s.checked.then(function () { syncUi(); });
      return res;
    });
  };

  function skeleton(on) {
    var k = doc.querySelector('#gantt .g-skel');
    if (k && k.hidden === on) k.hidden = !on;
  }
  A.skeleton = skeleton;

  A.goHome = function () {
    // Nothing keeps moving a view that is about to be hidden.
    if (S.gestures) S.gestures.stop();
    if (S.session) { S.store.onHide('home'); S.session = null; }
    resetEdit();
    openSeq++;
    return A.showHome();
  };

  // View state per chart (D5): zoom, left day, scroll and collapsed groups.
  // One pending timer at most: a burst of wheel events only moves `viewDue`
  // (no clearTimeout/setTimeout per event, §14.3 rule 4).
  var viewTimer = null, viewDue = 0, viewFor = null;
  function noteCamera() {
    syncZoomSeg();
    if (!S.session || S.launch.embed) return;
    viewDue = Date.now() + A.SAVE_VIEW_MS;
    viewFor = S.session;
    if (viewTimer === null) viewTimer = win.setTimeout(saveView, A.SAVE_VIEW_MS);
  }
  function saveView() {
    viewTimer = null;
    var left = viewDue - Date.now();
    if (left > 0) { viewTimer = win.setTimeout(saveView, left); return; }
    var s = viewFor;
    if (!s || S.session !== s) return;
    var c = S.view.camera();
    S.store.cache.setView(s.noteId, { ppd: c.ppd, scrollDay: S.view.leftDay(), sy: c.sy, collapsed: S.collapsed.slice() });
  }
  var segMemo = '', segPpd = null, SEG = ['day', 'week', 'month'];
  function syncZoomSeg() {
    var ppd = S.view.camera().ppd;
    if (ppd === segPpd) return;
    segPpd = ppd;
    var P = GT.scale.PRESETS, best = 'week', d = Infinity;
    for (var i = 0; i < SEG.length; i++) { var x = Math.abs(Math.log(ppd / P[SEG[i]])); if (x < d) { d = x; best = SEG[i]; } }
    if (best === segMemo) return;
    segMemo = best;
    Array.prototype.forEach.call(doc.querySelectorAll('#zoomSeg [data-zoom]'), function (b) {
      b.setAttribute('aria-pressed', b.getAttribute('data-zoom') === best ? 'true' : 'false');
    });
  }
  A.toggleGroup = function (id) {
    var i = S.collapsed.indexOf(id);
    if (i >= 0) S.collapsed.splice(i, 1); else S.collapsed.push(id);
    S.view.setCollapsed(S.collapsed.slice());
    noteCamera();
  };
  A.setAllGroups = function (collapsed) {
    var s = S.session;
    if (!s || !s.live) return;
    S.collapsed = collapsed ? s.live.groups.map(function (g) { return g.id; }).concat([GT.layout.UNSCHED]) : [];
    S.view.setCollapsed(S.collapsed.slice());
    noteCamera();
  };

  /* ======================================================= editing (M6) */

  var M = function () { return GT.model; };
  function live() { var s = S.session; return s && S.store.session === s ? s.live : null; }
  // Edits are allowed only on the open, editable chart (not under
  // journalHold, not read-only, not with a second block, not in the embed).
  function editable() {
    var s = S.session;
    return S.mode === 'chart' && !!s && S.store.session === s && S.store.canEdit() && !s.extra;
  }
  A.editable = editable;
  function taskOf(id) { var c = live(); return c && id ? M().task(c, id) : null; }
  function titleOf(id) { var inf = S.view.info(id), t = taskOf(id); return inf ? inf.title : (t && t.title) || T('Untitled'); }

  // Undo labels carry the action and the title, joined by a unit separator.
  var SEP = String.fromCharCode(31);
  function labelOf(action, id) { return action + SEP + (id ? titleOf(id) : (S.session && S.session.title) || ''); }
  A.undoLabel = function (which) {
    var l = S.stack ? S.stack.label(which) : null;
    var base = which === 'redo' ? 'Redo' : 'Undo';
    if (!l) return T(base);
    var p = l.split(SEP);
    return I().fmt(which === 'redo' ? 'Redo: {action} “{title}”' : 'Undo: {action} “{title}”', { action: p[0], title: p[1] || '' });
  };

  function resetEdit() {
    S.fromList = false;
    S.sel = null;
    S.drag = null;
    S.items = null;
    itemsSeq++;
    S.stack = GT.undo.createStack({ cap: 100 });
    if (S.view) { S.view.setSelection(null); S.view.setPreview(null); }
    if (S.sheet && S.sheet.isOpen()) S.sheet.close();
    S.conflict = null;
  }

  /*
   * commitEdit(res, action, id, {save, coalesceKey}): res is a model
   * transform's {chart, inverse}. A no-op is not committed; a refused
   * commit (hold, read-only) pushes nothing. save: 'now' (a gesture,
   * default) or 'debounce' (keyboard nudges, sheet inputs).
   */
  function commitEdit(res, action, id, o) {
    o = o || {};
    if (!res || !res.inverse || !res.inverse.length || !editable()) return false;
    if (!S.store.commit(res.chart, { save: o.save || 'now' })) return false;
    S.stack.push({ label: labelOf(action, id), patches: res.inverse, coalesceKey: o.coalesceKey || null });
    afterChange();
    return true;
  }
  A.commitEdit = commitEdit;
  function afterChange() {
    if (S.session) renderSession(S.session);
    syncUi();
    refreshSettings();
  }

  /* ---- undo and redo (§13.6) ---- */

  function stepUndo(which) {
    if (!editable() || !S.stack) return Promise.resolve({ ok: false, reason: 'held' });
    var p = which === 'redo' ? S.store.redo(S.stack) : S.store.undo(S.stack);
    return p.then(function (r) {
      var s = S.session;
      if (s && s.title) setTitle(s.title);
      afterChange();
      if (!r.ok && r.reason !== 'empty' && r.reason !== 'held') {
        var msg = r.reason === 'denied' ? 'Couldn’t undo: not approved' : 'Couldn’t undo: the note changed';
        A.toast(T(msg), { label: T('Skip'), run: function () { S.stack.skip(which); syncUi(); } });
      }
      if (r.ok) {
        // §13.6: undo of a create removes the task and keeps the note.
        if (which === 'undo' && String(r.label || '').split(SEP)[0] === 'Create task note') A.toast(T('Removed from the chart. The note is kept.'));
        // A host effect changed the open task's items: read them again.
        var open = S.sheet.taskId();
        if (open && S.items && S.items.taskId === open) loadItems(open, true);
      }
      return r;
    });
  }
  A.undo = function () { return stepUndo('undo'); };
  A.redo = function () { return stepUndo('redo'); };

  /* ---- selection, sheet ---- */

  function syncHandles() { S.view.setSelection(S.sel, { handles: editable() }); }
  A.select = function (id) {
    S.sel = id && taskOf(id) ? id : null;
    // The name column's tab stop follows the selection (§15.2).
    if (S.view) S.view.setRove(null);
    syncHandles();
  };

  /* ---- M9: roving focus in the name column (§15.2) ---- */

  // Whether keyboard focus is on a row of the chart (a name row, a group
  // header or a bar), so a selection move takes the focus along.
  function focusInChart() {
    var a = doc.activeElement;
    return !!(a && a.closest && a.closest('#gantt .g-name, #gantt .g-grp, #gantt .g-bar'));
  }
  A.focusInChart = focusInChart;
  // Focus the name-column row of the selected task, else the first row.
  A.focusChart = function () {
    if (S.mode !== 'chart' || !S.view) return false;
    if (S.sel && taskOf(S.sel)) return S.view.focusRow('task', S.sel);
    var r = S.view.rows()[0];
    return r ? S.view.focusRow(r.kind === 'group' ? 'group' : 'task', r.id) : false;
  };
  /*
   * moveFocus(dir | 'first' | 'last', from): the next name-column row, task
   * or group header, from the focused one. A task row is selected (and an
   * open task sheet follows it); a group header only takes the focus.
   */
  A.moveFocus = function (dir, from) {
    var rows = S.view.rows();
    if (!rows.length) return false;
    var i = -1;
    for (var k = 0; k < rows.length; k++) if (from && rows[k].kind === from.kind && rows[k].id === from.id) i = k;
    var n = dir === 'first' ? 0 : dir === 'last' ? rows.length - 1 : Math.max(0, Math.min(rows.length - 1, (i < 0 ? 0 : i + dir)));
    var r = rows[n];
    if (r.kind === 'group') return S.view.focusRow('group', r.id);
    A.select(r.id);
    if (S.sheet.taskId()) S.sheet.openTask(r.id, S.sheet.detent());
    return S.view.focusRow('task', r.id);
  };
  // The row a keyboard event came from: {kind, id} or null.
  function rowOf(t) {
    var e = t && t.closest ? t.closest('#gantt .g-name, #gantt .g-grp') : null;
    if (!e) return null;
    return e.classList.contains('g-grp') ? { kind: 'group', id: e.getAttribute('data-group') } : { kind: 'task', id: e.getAttribute('data-id') };
  }
  A.openSheet = function (id, detent) {
    if (!taskOf(id)) return false;
    return S.sheet.openTask(id, detent || 'peek');
  };
  function progressText(sum) {
    if (!sum) return '';
    if (sum.missing) return T('Missing note');
    if (sum.loading) return T('Loading…');
    if (sum.total > 0) return I().fmt('{a} of {b} done', { a: sum.done, b: sum.total });
    if (sum.src === 'checklist' && sum.found === false) return T('No checklist section');
    return T('No sub-items');
  }
  // The task sheet's view model (sheet.js ctx.task).
  function taskVm(id) {
    var t = taskOf(id);
    if (!t) return null;
    var inf = S.view.info(id) || {};
    return {
      id: id, title: inf.title || t.title || T('Untitled'), hue: inf.hue || 'slate', start: t.start, end: t.end,
      milestone: t.milestone, color: t.color, note: !!t.note, readOnly: !editable(),
      progress: { ratio: typeof inf.ratio === 'number' ? inf.ratio : 0, text: progressText(inf.sum) },
      items: itemsFor(id)
    };
  }

  /* ---- the completion list (§13.4) and its toggles (§8) ---- */

  var itemsSeq = 0;
  // The open task's list, loaded when its sheet first asks for it.
  function itemsFor(id) {
    var t = taskOf(id), c = live();
    var src = t && t.note && c ? M().sourceOf(t, c.settings) : 'none';
    var it = S.items;
    if (!it || it.taskId !== id || it.note !== (t ? t.note : null) || it.src !== src) loadItems(id);
    return { state: S.items.state, list: S.items.list };
  }
  /*
   * loadItems(id, keep): store.loadItems for the task's note and source;
   * `keep` shows the current list until the new one arrives (after a toggle
   * or an undo). -> the load promise (also S.itemsLoaded, for the dev pages).
   */
  function loadItems(id, keep) {
    var t = taskOf(id), c = live(), seq = ++itemsSeq, old = S.items;
    var src = t && t.note && c ? M().sourceOf(t, c.settings) : 'none';
    var it = S.items = { taskId: id, note: t ? t.note : null, src: src, state: 'none', list: [] };
    if (src !== 'checklist' && src !== 'subnotes') { S.itemsLoaded = Promise.resolve(it); return S.itemsLoaded; }
    if (keep && old && old.taskId === id) { it.state = old.state; it.list = old.list; } else it.state = 'loading';
    S.itemsLoaded = S.store.loadItems(t.note, { src: src, section: c.settings.progressSection, childTasks: c.settings.childTasks !== false }).then(function (r) {
      if (seq !== itemsSeq || S.items !== it) return r;
      it.state = r.ok ? 'ok' : (r.reason === 'too-large' ? 'too-large' : 'failed');
      it.list = r.items || [];
      if (S.sheet.taskId() === id) S.sheet.update();
      return r;
    });
    return S.itemsLoaded;
  }
  A.loadItems = loadItems;

  // The one-time explanation before the first subnote toggle (§8, Q1): a
  // subnote is written with SQL, which the host approves separately.
  A.SUB_NOTICE = 'Sub-notes are saved with a database edit, so Note Synapse asks for approval before the first one. Tick \'{allow}\' there so the next ones save without asking.';
  function subnoteNotice(taskId, key) {
    var det = S.sheet.detent() || 'peek';
    S.sheet.openForm({
      kind: 'subnote-notice', title: T('Ticking sub-notes'), text: I().fmt(A.SUB_NOTICE, { allow: T('Allow for this session') }),
      actions: [
        { id: 'continue', label: T('Continue'), primary: true, run: function () {
          S.store.prefs.set({ subnoteNoticeSeen: true });
          A.openSheet(taskId, det);
          A.toggleItemAt(taskId, key);
          return true;
        } },
        { id: 'cancel', label: T('Cancel'), run: function () { A.openSheet(taskId, det); return true; } }
      ]
    }, det);
    reg(function () { subnoteNotice(taskId, key); });
  }

  /*
   * toggleItemAt(taskId, key): a tap in the completion list. The bar shows
   * the new state in the same frame (store.markItem), then the write:
   * store.toggleItem (replace_text with the full heading line, D17),
   * toggleSubnote (SQL, after the one-time explanation) or setChildStatus.
   * Success pushes the host patch (undo writes the reverse value, §6.1); a
   * failure puts the counts back and says why. The list is read again.
   */
  A.toggleItemAt = function (taskId, key) {
    var its = S.items, t = taskOf(taskId), s = S.session, stack = S.stack;
    if (!its || its.taskId !== taskId || !t || !t.note || !editable()) return Promise.resolve({ ok: false, reason: 'held' });
    var x = null;
    its.list.forEach(function (i) { if (i.key === key) x = i; });
    if (!x || x.busy) return Promise.resolve({ ok: false, reason: 'busy' });
    if (x.kind === 'sub' && !S.store.prefs.get('subnoteNoticeSeen')) { subnoteNotice(taskId, key); return Promise.resolve({ ok: false, reason: 'notice' }); }
    var done = !x.done;
    var pos = its.list.filter(function (i) { return i.kind === x.kind; }).indexOf(x);
    var revert = S.store.markItem(t.note, x.kind, pos, done);
    x.done = done;
    x.busy = true;
    if (S.sheet.taskId() === taskId) S.sheet.update();
    var p = x.kind === 'check' ? S.store.toggleItem(t.note, { index: x.index, line: x.line })
      : x.kind === 'sub' ? S.store.toggleSubnote(t.note, x.id, done)
        : S.store.setChildStatus(x.id, done ? 'complete' : 'todo', x.status, t.note);
    return p.then(function (r) {
      if (S.session !== s) return r;
      if (r.ok) stack.push({ label: labelOf('Toggle item', taskId), patches: r.inverse });
      else {
        if (revert) revert();
        A.toast(T(r.reason === 'denied' ? 'Not changed: not approved' : 'Couldn’t change it: the note changed'));
      }
      if (S.items === its) {
        // A checkbox toggle's own re-read already holds the new list.
        if (r.list) { its.list = r.list.items; its.state = 'ok'; if (S.sheet.taskId() === taskId) S.sheet.update(); }
        else loadItems(taskId, true);
      }
      syncUi();
      return r;
    });
  };
  function sheetAct(name, id, v) {
    var c = live();
    if (!c) return;
    if (name === 'open') {
      var t = taskOf(id);
      if (!t || !t.note) return;
      // §8: flush, then open the note (host.openNote arms the resume trigger).
      S.store.flush().then(function () { return S.host.openNote(t.note, false); });
      return;
    }
    if (name === 'remove') { A.removeTask(id); return; }
    if (name === 'item') { A.toggleItemAt(id, v); return; }
    if (name === 'openItem') {
      var kid = S.items && S.items.taskId === id ? S.items.list.filter(function (i) { return i.key === v; })[0] : null;
      if (kid && kid.kind === 'child') S.store.flush().then(function () { return S.host.openNote(kid.id, false); });
      return;
    }
    var done = false;
    if (name === 'dates') done = commitEdit(M().setDates(c, id, v.start, v.end), 'Change dates', id, { save: 'debounce' });
    else if (name === 'milestone') done = commitEdit(M().setTask(c, id, { milestone: !!v }), 'Milestone', id, { save: 'debounce' });
    else if (name === 'color') done = commitEdit(M().setTask(c, id, { color: v || null }), 'Colour', id, { save: 'debounce' });
    // A commit refreshes the sheet through syncUi; a refused one shows the chart again.
    if (!done && S.sheet.isOpen()) S.sheet.update();
  }

  /* ---- drags (§13.2, §13.3) ---- */

  /*
   * dragDates(kind, task, dxPx, ppd, settings) -> {start, end, delta}: the
   * dates a MOVE ('move') or RESIZE ('start' | 'end') of dxPx shows. Delta
   * snapping by the zoom tier (scale.snapDelta, §11.3); at day snapping the
   * dragged edge also skips non-working days in the direction of the drag
   * (dates.snap), unless it started on one. end is null for a one-day task.
   */
  A.dragDates = function (kind, task, dx, ppd, settings) {
    var SC = GT.scale, D = GT.dates;
    var step = SC.tierFor(ppd).snap, d = SC.snapDelta(dx, ppd, step);
    var dir = d > 0 ? 1 : (d < 0 ? -1 : 0);
    var start = task.start, end = task.end === null ? task.start : task.end;
    function work(day, orig) { return step === 1 && dir && D.isWork(orig, settings) ? D.snap(day, settings, dir) : day; }
    if (kind === 'move') {
      var ns = work(start + d, start), delta = ns - start;
      return { start: ns, end: task.milestone || task.end === null ? null : task.end + delta, delta: delta };
    }
    if (kind === 'end') {
      var ne = Math.max(start, work(end + d, end));
      return { start: start, end: ne === start ? null : ne, delta: ne - end };
    }
    var st0 = Math.min(end, work(start + d, start));
    return { start: st0, end: end === st0 ? null : end, delta: st0 - start };
  };

  // Client px to body px: #gantt starts at the page's left edge and ends at
  // its bottom (#app is fixed at inset 0 and #gantt is its last row).
  function bodyTop() { var vs = S.view.viewSize(); return win.innerHeight - vs.h + (vs.metrics ? vs.metrics.hdrH : 0); }

  var DSTATE = { MOVE: 'move', RESIZE_S: 'start', RESIZE_E: 'end' };
  function dragStart(state, id, x0, y0) {
    var t = taskOf(id);
    if (!t || !editable()) return false;
    if (state !== 'REORDER' && typeof t.start !== 'number') return false;       // nothing to move yet
    if ((state === 'RESIZE_S' || state === 'RESIZE_E') && t.milestone) return false;
    var cam = S.view.camera(), row = null, rows = S.view.rows();
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === 'task' && rows[i].id === id) { row = rows[i]; break; }
    if (!row) return false;
    S.drag = { state: state, id: id, x0: x0, y0: y0, sx0: cam.sx, sy0: cam.sy, top: bodyTop(), mid: row.y + row.h / 2, hd: row.h, res: null, target: null };
    if (S.sel !== id) A.select(id);
    if (S.sheet.isOpen()) S.sheet.close();
    return true;
  }
  function dragMove(state, x, y) {
    var d = S.drag, c = live();
    if (!d || d.state !== state || !c) return;
    var t = M().task(c, d.id);
    if (!t) return;
    var cam = S.view.camera(), nw = S.view.nameW();
    var bx = x - nw, by = y - d.top;
    if (state === 'REORDER') {
      var dy = (y - d.y0) + (cam.sy - d.sy0);
      var tg = GT.layout.reorderTarget(S.view.rows(), c, d.id, d.mid + dy);
      d.target = tg;
      var text = '';
      if (tg && tg.group !== undefined && tg.group !== t.group) {
        var g = tg.group ? M().group(c, tg.group) : null;
        text = '→ ' + (g ? g.title || T('Untitled') : T('No group'));
      }
      S.view.setPreview({ kind: 'reorder', id: d.id, dy: dy, from: tg ? tg.from : -1, lo: tg ? tg.lo : 0, hi: tg ? tg.hi : -1,
        dir: tg ? tg.dir : 0, hd: d.hd, bubble: text, bx: bx, by: by });
      return;
    }
    var dx = (x - d.x0) + (cam.sx - d.sx0);
    var r = A.dragDates(DSTATE[state], t, dx, cam.ppd, c.settings);
    d.res = r;
    S.view.setPreview({ kind: state === 'MOVE' ? 'move' : 'resize', id: d.id, start: r.start, end: r.end, edge: DSTATE[state],
      bubble: bubbleText(state, t, r), delta: deltaText(state, r), bx: bx, by: by });
  }
  function span(a, b) { return b === null || b === a ? I().date.short(a) : I().date.range(a, b); }
  // The bubble's delta, drawn in accent after the text (§13.3): "+2d".
  function deltaText(state, r) {
    if (state !== 'MOVE' || !r.delta) return '';
    return r.delta > 0 ? I().fmt('+{n}d', { n: r.delta }) : I().fmt('{n}d', { n: r.delta });
  }
  function bubbleText(state, t, r) {
    var I0 = I(), days = (r.end === null ? r.start : r.end) - r.start + 1;
    if (state === 'MOVE') return span(r.start, r.end) + (t.milestone ? '' : ' · ' + I0.fmt('{n}d', { n: days }));
    if (state === 'RESIZE_E') return I0.fmt('Ends {date}', { date: I0.date.short(r.end === null ? r.start : r.end) }) + ' · ' + I0.fmt('{n}d', { n: days });
    return I0.fmt('Starts {date}', { date: I0.date.short(r.start) }) + ' · ' + I0.fmt('{n}d', { n: days });
  }
  function drop(state) {
    var d = S.drag, c = live();
    S.drag = null;
    S.view.setPreview(null);
    if (!d || !c || state === 'ARMED') { syncHandles(); return; }
    var done = false;
    if (state === 'REORDER') {
      var tg = d.target;
      if (tg && tg.changed) done = commitEdit(M().reorder(c, d.id, tg.index, tg.group), 'Reorder', d.id);
    } else if (d.res && d.res.delta) {
      if (state === 'MOVE') done = commitEdit(M().moveTask(c, d.id, d.res.delta), 'Move', d.id);
      else if (state === 'RESIZE_E') done = commitEdit(M().resizeTask(c, d.id, 'end', d.res.end === null ? d.res.start : d.res.end), 'Resize', d.id);
      else done = commitEdit(M().resizeTask(c, d.id, 'start', d.res.start), 'Resize', d.id);
    }
    if (!done) syncHandles();
  }
  function cancelDrag() {
    if (!S.drag && !S.view.preview()) return;
    S.drag = null;
    S.view.setPreview(null);
  }
  function longPress(kind, id) {
    var t = taskOf(id);
    if (!t || S.launch.embed) return false;
    if (!editable()) { A.select(id); return false; }
    if (kind === 'bar') {
      if (typeof t.start !== 'number') return false;
      A.select(id);
      if (S.sheet.isOpen()) S.sheet.close();
      S.view.setPreview({ kind: 'lift', id: id });
      return true;
    }
    return kind === 'name';
  }
  function edgeRect(out) {
    var vs = S.view.viewSize(), m = vs.metrics;
    if (!m) return;
    var top = bodyTop();
    out.l = m.nameW; out.r = m.nameW + vs.bodyW; out.t = top; out.b = top + vs.bodyH;
  }

  /* ---- keyboard edits (§13.2) ---- */

  A.nudge = function (kind, dir) {
    var c = live(), t = taskOf(S.sel);
    if (!t || typeof t.start !== 'number' || !editable()) return false;
    var step = GT.scale.tierFor(S.view.camera().ppd).snap * dir;
    var end = t.end === null ? t.start : t.end;
    if (kind === 'move') return commitEdit(M().moveTask(c, t.id, step), 'Move', t.id, { save: 'debounce', coalesceKey: 'key-move:' + t.id });
    if (t.milestone) return false;
    if (kind === 'end') return commitEdit(M().resizeTask(c, t.id, 'end', end + step), 'Resize', t.id, { save: 'debounce', coalesceKey: 'key-end:' + t.id });
    return commitEdit(M().resizeTask(c, t.id, 'start', t.start + step), 'Resize', t.id, { save: 'debounce', coalesceKey: 'key-start:' + t.id });
  };
  function taskRows() { return S.view.rows().filter(function (r) { return r.kind === 'task'; }); }
  A.selectNext = function (dir) {
    var rows = taskRows();
    if (!rows.length) return;
    var i = -1;
    for (var k = 0; k < rows.length; k++) if (rows[k].id === S.sel) i = k;
    var n = i < 0 ? (dir > 0 ? 0 : rows.length - 1) : Math.max(0, Math.min(rows.length - 1, i + dir));
    var keep = focusInChart();
    A.select(rows[n].id);
    S.view.scrollIntoView(rows[n].id);
    if (S.sheet.taskId()) S.sheet.openTask(rows[n].id, S.sheet.detent());
    // Focus on a bar or row moves with the selection (M9).
    if (keep) S.view.focusRow('task', rows[n].id);
  };
  A.nudgeOrder = function (dir) {
    var c = live(), rows = S.view.rows(), from = -1;
    if (!c || !editable()) return false;
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === 'task' && rows[i].id === S.sel) from = i;
    var nb = rows[from + dir];
    if (from < 0 || !nb) return false;
    var hd = rows[from].h;
    var y = dir < 0 ? nb.y + (nb.h + hd) / 2 - 0.5 : nb.y - hd + (nb.h + hd) / 2 + 0.5;
    var tg = GT.layout.reorderTarget(rows, c, S.sel, y);
    if (!tg || !tg.changed) return false;
    return commitEdit(M().reorder(c, S.sel, tg.index, tg.group), 'Reorder', S.sel, { save: 'debounce', coalesceKey: 'key-order:' + S.sel });
  };

  /* ---- chart menus: FAB, More, rename ---- */

  A.addMilestone = function () {
    var c = live();
    if (!c || !editable()) return false;
    var res = M().addTasks(c, [{ milestone: true, title: T('Milestone'), start: GT.dates.today(S.now()) }]);
    var id = res.added && res.added[0];
    if (!commitEdit(res, 'Add milestone', null)) return false;
    A.select(id);
    S.view.scrollIntoView(id);
    S.view.flash(id);
    return true;
  };
  A.openFab = function () {
    if (!editable()) return;
    S.sheet.openMenu({
      title: T('Add'), items: [
        { id: 'existing', label: T('Add existing notes'), run: A.addExisting },
        { id: 'create', label: T('Create a task note'), run: A.createTaskForm },
        { id: 'milestone', label: T('Add milestone'), run: A.addMilestone }
      ]
    }, 'peek');
    reg(A.openFab);
  };

  // Where new rows go: after the selected task, in its group, starting the
  // day after it ends; else at the end, today (§8).
  function placement() {
    var c = live(), sel = taskOf(S.sel), o = {};
    if (!c || !sel) return o;
    o.index = c.tasks.indexOf(sel) + 1;
    o.group = sel.group;
    if (typeof sel.start === 'number') o.from = (sel.end === null ? sel.start : sel.end) + 1;
    return o;
  }
  // Rows just added: selected, scrolled into view and flashed.
  function showAdded(ids) {
    if (!ids.length) return;
    A.select(ids[0]);
    S.view.scrollIntoView(ids[0]);
    S.view.flash(ids);
  }

  /*
   * addNotes(notes): store.addToChart on the open chart (duplicates are
   * skipped, D20), one undo entry, the new rows shown. Used by "Add existing
   * notes" and by "Add to a chart…" from the chooser and the multi page.
   */
  function addNotes(notes) {
    var s = S.session, stack = S.stack;
    if (!s || !editable()) { A.toast(T('This chart can’t be edited right now.')); return Promise.resolve({ ok: false, reason: 'held' }); }
    return S.store.addToChart(s.noteId, notes, placement()).then(function (r) {
      if (S.session !== s) return r;
      if (!r.ok) { A.toast(T('The notes were not added.')); return r; }
      if (r.added.length) {
        stack.push({ label: labelOf('Add notes', r.added[0]), patches: r.inverse });
        afterChange();
        showAdded(r.added);
      }
      if (r.skipped) A.toast(r.added.length ? I().fmt('{n} already on the chart', { n: r.skipped }) : T('Those notes are already on the chart.'));
      return r;
    });
  }
  A.addNotes = addNotes;
  // §8 / §13.5: flush, then the host's picker with the chart's notes preselected.
  A.addExisting = function () {
    var c = live(), s = S.session;
    if (!c || !editable()) return Promise.resolve(null);
    var pre = c.tasks.filter(function (t) { return !!t.note; }).map(function (t) { return t.note; });
    return S.store.flush().then(function () {
      return S.host.pickNotes({ multiSelect: true, title: T('Add notes to the chart'), preselectedIds: pre });
    }).then(function (r) {
      if (S.session !== s) return r;
      if (!r.ok) { A.toast(T(r.reason === 'no_ui' ? 'The note picker is not available here.' : 'The note picker could not be opened.')); return r; }
      if (r.cancelled) return r;
      // The host's picker returns the whole selection, the preselected notes
      // included (note_selection_dialog.dart:78-88, 412): only the others are
      // new. Unticking a preselected note removes nothing (Remove does that).
      var fresh = r.notes.filter(function (n) { return pre.indexOf(n.id) < 0; });
      if (!fresh.length) return { ok: true, added: [], skipped: 0, picked: r.notes.length };
      return addNotes(fresh);
    });
  };

  /*
   * "Create a task note" (§8, §13.5): title, dates, steps (one per line) as
   * checklist items under the chart's progressSection, shown read-only
   * (§15.1, M7 review), or as sub-notes when the chart counts
   * sub-notes; "Link back to chart" is on by default (Q5).
   */
  A.createTaskForm = function () {
    var c = live();
    if (!c || !editable()) return;
    var set = c.settings, sub = set.progressSource === 'subnotes', pl = placement();
    var start = typeof pl.from === 'number' ? pl.from : GT.dates.today(S.now());
    var fields = [
      { name: 'title', type: 'text', label: T('Title') },
      { name: 'start', type: 'date', label: T('Start'), value: start },
      { name: 'end', type: 'date', label: T('End'), value: start + 4 },
      { name: 'steps', type: 'textarea', label: T(sub ? 'Sub-notes, one per line' : 'Checklist items, one per line') }
    ];
    // Read-only: the note must use the heading the chart counts (§15.1).
    // An empty setting means the whole note (§5.4): no heading is written.
    var head = GT.md.headingLine(set.progressSection).replace(/^#+[ \t]*/, '');
    if (!sub) fields.push({ name: 'section', type: 'note', label: T('Checklist section'), value: head || T('Whole note') });
    fields.push({ name: 'backlink', type: 'switch', label: T('Link back to chart'), value: true });
    S.sheet.openForm({
      kind: 'create', title: T('Create a task note'), fields: fields,
      actions: [
        { id: 'create', label: T('Create'), primary: true, run: function (v) {
          if (!String(v.title || '').trim()) return true;         // a title is needed; the sheet stays
          A.createTask(v);
          return false;
        } },
        { id: 'cancel', label: T('Cancel') }
      ]
    }, 'full');
    reg(A.createTaskForm);
  };
  A.createTask = function (v) {
    var s = S.session, stack = S.stack, pl = placement();
    var start = typeof v.start === 'number' ? v.start : GT.dates.today(S.now());
    var spec = {
      title: v.title, start: start, end: typeof v.end === 'number' ? v.end : undefined, steps: String(v.steps || '').split('\n'),
      backlink: v.backlink !== false,
      group: pl.group !== undefined ? pl.group : null, index: pl.index
    };
    return S.store.createTaskNote(spec).then(function (r) {
      if (S.session !== s) return r;
      if (!r.ok) {
        A.toast(T(r.reason === 'create-failed' ? 'The task note could not be created.' : 'This chart can’t be edited right now.'));
        return r;
      }
      stack.push({ label: labelOf('Create task note', r.added[0]), patches: r.inverse });
      afterChange();
      showAdded(r.added);
      return r;
    });
  };

  // Keyboard Delete "asks to remove" (§13.2): the first press opens the
  // task sheet with Remove armed, a second press (or tap) within ARM_MS removes.
  A.askRemove = function (id) {
    if (!editable() || !taskOf(id)) return false;
    if (S.sheet.taskId() === id && S.sheet.removeArmed()) return A.removeTask(id);
    if (S.sheet.taskId() !== id) A.openSheet(id, 'peek');
    return S.sheet.armRemove();
  };

  /*
   * M9 reconciliation banner: Remove takes the tasks whose lines were
   * deleted in the note off the chart (one undo step; the notes are kept);
   * Restore list writes the region again with every line.
   */
  A.removeGone = function (ids) {
    var c = live();
    if (!c || !editable()) return false;
    ids = (ids || []).filter(function (id) { return !!taskOf(id); });
    if (!ids.length) return false;
    var titles = ids.map(function (id) { return titleOf(id); }), chart = c, inv = [];
    ids.forEach(function (id) { var r = M().removeTask(chart, id); chart = r.chart; inv = r.inverse.concat(inv); });
    // The note's region lacks those lines: the save replaces it as it is.
    S.store.anchorToRead();
    if (!commitEdit({ chart: chart, inverse: inv }, 'Remove', ids[0])) return false;
    if (S.sel && ids.indexOf(S.sel) >= 0) A.select(null);
    A.toast(I().fmt('Removed “{title}” from the chart', { title: I().list(titles) }), { label: T('Undo'), run: A.undo });
    return true;
  };
  A.restoreList = function () {
    return S.store.restoreMirror().then(function (r) { syncUi(); return r; });
  };

  // Remove from chart (§8): the chart only, never the note; an undo toast.
  A.removeTask = function (id) {
    var c = live();
    if (!c || !editable() || !taskOf(id)) return false;
    var title = titleOf(id);
    if (!commitEdit(M().removeTask(c, id), 'Remove', id)) return false;
    if (S.sheet.isOpen()) S.sheet.close();
    A.select(null);
    A.toast(I().fmt('Removed “{title}” from the chart', { title: title }), { label: T('Undo'), run: A.undo });
    return true;
  };
  A.openMore = function () {
    var ed = editable();
    S.sheet.openMenu({
      title: T('More'), items: [
        { id: 'fit', label: T('Fit all'), run: A.fitAll },
        { id: 'expand', label: T('Expand all'), run: function () { A.setAllGroups(false); } },
        { id: 'collapse', label: T('Collapse all'), run: function () { A.setAllGroups(true); } },
        { id: 'legend', label: 'ⓘ ' + T('Legend'), hint: T(legendOn() ? 'On' : 'Off'), run: A.toggleLegend },
        { id: 'display', label: T('Display'), run: A.openDisplay },
        { id: 'settings', label: T('Chart settings'), run: A.openSettings },
        { id: 'appearance', label: T('Appearance'), hint: T(APPEARANCE[GT.theme.override()] || 'Auto'), run: A.openAppearance },
        { id: 'rename', label: T('Rename chart'), run: A.rename, disabled: !ed },
        { id: 'open-note', label: T('Open chart note'), run: A.openChartNote },
        // M9 (§15.2): every task as an accessible list.
        { id: 'tasklist', label: T('Task list'), run: function () { A.openTaskList(); } }
      ]
    }, 'peek');
    reg(A.openMore);
  };
  /*
   * M9 Task list view (More ▸ Task list, §13.5, §15.2): every task in chart
   * order (D15, collapsed groups included) with its dates, progress and
   * status, one button per task (sheet.openList). A pick opens its task
   * sheet; closing that sheet comes back here with the row focused.
   */
  A.openTaskList = function (detent, focusId) {
    var c = live();
    if (!c) return false;
    var LY = GT.layout, built = LY.buildRows(c, [], 'comfortable'), secs = [], cur = { title: null, rows: [] };
    secs.push(cur);
    built.rows.forEach(function (r) {
      if (r.kind === 'group') {
        cur = { title: r.unscheduled ? T('Unscheduled') : (r.group.title || T('Untitled')), rows: [] };
        secs.push(cur);
        return;
      }
      cur.rows.push(listRow(r.task));
    });
    // Collapsed groups are listed too (no collapsed set is passed above).
    S.sheet.openList({
      kind: 'tasklist', title: T('Task list'), empty: T('No tasks on this chart yet'), sections: secs,
      focusId: focusId || null,
      pick: function (id) { S.fromList = true; A.select(id); S.view.scrollIntoView(id); A.openSheet(id, S.sheet.detent() || 'full'); }
    }, detent || 'full');
    reg(function (det) { A.openTaskList(det); });
    return true;
  };
  function listRow(t) {
    var inf = S.view.info(t.id) || {}, sum = inf.sum || null, I0 = I();
    var key = inf.missing ? 'missing' : (inf.cls || 'none');
    var status = key === 'none' ? '' : T(GT.layout.CLASS_LABEL[key] || '');
    var when = typeof t.start !== 'number' ? T('Unscheduled') : span(t.start, t.milestone || t.end === null ? null : t.end);
    if (typeof t.start === 'number' && !t.milestone) when += ' · ' + I0.fmt('{n} day(s)', { n: (t.end === null ? t.start : t.end) - t.start + 1 });
    if (t.milestone) when += ' · ' + T('Milestone');
    var aria = inf.aria || inf.title || t.title || T('Untitled');
    if (status && key !== 'late' && key !== 'missing') aria += (I0.language === 'zh-CN' ? '，' : ', ') + status;
    return {
      id: t.id, title: inf.title || t.title || T('Untitled'), hue: inf.hue || 'slate', meta: when, status: status,
      ratio: typeof inf.ratio === 'number' ? inf.ratio : 0, ptext: progressText(sum), aria: aria
    };
  }

  // More ▸ Open chart note (§13.5): flush, then open the chart note itself.
  A.openChartNote = function () {
    var s = S.session;
    if (!s) return Promise.resolve(null);
    return S.store.flush().then(function () { return S.host.openNote(s.noteId, false); });
  };

  /* ---- M8: an unscheduled task's ghost bar (§12.6) ---- */

  // Schedules it at today for 5 days (a milestone on today): one undo step.
  A.schedule = function (id) {
    var c = live(), t = taskOf(id);
    if (!c || !t || typeof t.start === 'number' || !editable()) return false;
    var today = GT.dates.today(S.now());
    var res = M().setDates(c, id, today, t.milestone ? null : today + GT.layout.GHOST_DAYS - 1);
    if (!commitEdit(res, 'Schedule', id)) return false;
    A.select(id);
    S.view.scrollIntoView(id);
    S.view.flash(id);
    return true;
  };

  /* ---- M8: chart settings (§5.4, §13.5; undoable and saved, §13.6) ---- */

  var WEEKDAY0 = 3;               // day number 3 (1970-01-04) is a Sunday
  function settingsFields(set) {
    var I0 = I(), ws = I0.weekStart(set), days = [];
    for (var k = 0; k < 7; k++) {
      var d = (ws + k) % 7;
      // A narrow letter on the button, the full name for a screen reader (M9).
      days.push({ value: d, label: I0.date.weekdayNarrow(WEEKDAY0 + d), title: I0.date.weekdayLong(WEEKDAY0 + d) });
    }
    var style = GT.layout.styleOf(set);
    return [
      { name: 'progressSource', type: 'choice', label: T('Sub-items come from'), value: M().sourceOf(null, set),
        options: [{ value: 'subnotes', label: T('Sub-notes') }, { value: 'checklist', label: T('Checklist') },
          { value: 'status', label: T('Status') }, { value: 'none', label: T('None') }] },
      { name: 'progressSection', type: 'text', label: T('Checklist section'), value: GT.md.headingLine(set.progressSection || '').replace(/^#+[ \t]*/, ''),
        placeholder: T('Whole note'), showIf: { name: 'progressSource', value: 'checklist' } },
      { name: 'childTasks', type: 'switch', label: T('Count linked child tasks'), value: set.childTasks !== false,
        showIf: { name: 'progressSource', value: 'subnotes' } },
      { name: 'progressStyle', type: 'choice', label: T('Completion display'), value: style,
        options: [{ value: 'fill', label: T('Fill'), preview: 'fill' }, { value: 'segments', label: T('Segments'), preview: 'segments' },
          { value: 'dots', label: T('Dots'), preview: 'dots' }] },
      { name: 'colorBy', type: 'choice', label: T('Colour bars by'), value: ['status', 'group', 'task'].indexOf(set.colorBy) >= 0 ? set.colorBy : 'status',
        options: [{ value: 'status', label: T('Status') }, { value: 'group', label: T('Group') }, { value: 'task', label: T('Task') }] },
      { name: 'scale', type: 'choice', label: T('Default zoom'), value: GT.scale.PRESETS[set.scale] || set.scale === 'quarter' ? set.scale : 'week',
        options: [{ value: 'day', label: T('Day') }, { value: 'week', label: T('Week') }, { value: 'month', label: T('Month') }, { value: 'quarter', label: T('Quarter') }] },
      { name: 'weekStart', type: 'choice', label: T('Week starts on'), value: typeof set.weekStart === 'number' ? String(set.weekStart) : 'auto',
        options: [{ value: 'auto', label: T('Auto') }, { value: '0', label: T('Sunday') }, { value: '1', label: T('Monday') }] },
      { name: 'workdays', type: 'days', label: T('Working days'), value: (set.workdays || []).slice(), options: days },
      { name: 'holidays', type: 'dates', label: T('Holidays'), addLabel: T('Add holiday'),
        value: (set.holidays || []).map(GT.dates.parse).filter(function (x) { return typeof x === 'number'; }) },
      { name: 'mirror', type: 'switch', label: T('Readable task list in the note'), value: set.mirror !== false },
      { name: 'embed', type: 'switch', label: T('Show the chart inside the note'), value: !!set.embed },
      { name: 'syncDates', type: 'switch', label: T('Write dates to task notes (shows in Calendar)'), value: !!set.syncDates }
    ];
  }
  A.openSettings = function (detent) {
    var c = live();
    if (!c) return false;
    S.settingsShown = GT.model.stable(GT.model.settingsData(c.settings));
    S.sheet.openForm({
      kind: 'settings', title: T('Chart settings'), readOnly: !editable(), noFocus: true,
      text: editable() ? '' : T('This chart can’t be edited right now.'),
      fields: settingsFields(c.settings),
      onChange: function (name, v) { A.setSetting(name, v); },
      actions: [{ id: 'done', label: T('Done'), primary: true }]
    }, detent || 'full');
    reg(A.openSettings);
    return true;
  };
  /*
   * setSetting(key, value): one model.setSettings commit (§5.4 keys),
   * undoable (an {op:'settings'} inverse) and saved: at once for a tap,
   * after the debounce for typing, day toggles and holiday edits (§9.1.2).
   * A change of progressSource or progressSection makes store.commit mark
   * every fact stale and re-resolve (§7.5).
   */
  A.setSetting = function (key, v) {
    var c = live();
    if (!c || !editable()) return false;
    if (key === 'weekStart') v = v === 'auto' || v === null || v === undefined ? null : Number(v);
    else if (key === 'holidays') {
      v = (v || []).filter(function (x) { return typeof x === 'number'; }).map(GT.dates.format)
        .filter(function (x, i, a) { return a.indexOf(x) === i; }).sort();
    } else if (key === 'progressSection') {
      // The field shows bare heading text (as the create sheet does); the
      // same heading typed again changes nothing, a new one is stored as typed.
      v = String(v == null ? '' : v).trim();
      if (GT.md.normHeading(v) === GT.md.normHeading(c.settings.progressSection)) return false;
    } else if (key === 'workdays') v = (v || []).slice().sort();
    var f = {};
    f[key] = v;
    var bursty = key === 'workdays' || key === 'holidays' || key === 'progressSection';
    var res = M().setSettings(c, f), shown = S.settingsShown;
    // The open sheet already shows this value: no rebuild after the commit.
    S.settingsShown = GT.model.stable(GT.model.settingsData(res.chart.settings));
    var done = commitEdit(res, 'Chart settings', null, { save: bursty ? 'debounce' : 'now', coalesceKey: bursty ? 'settings:' + key : null });
    if (!done) S.settingsShown = shown;
    return done;
  };
  // An undo, redo or merge changed the settings under an open settings sheet.
  function refreshSettings() {
    var c = live();
    if (!c || S.sheet.kind() !== 'settings') return;
    if (GT.model.stable(GT.model.settingsData(c.settings)) === S.settingsShown) return;
    var a = doc.activeElement;
    if (a && a.closest && a.closest('#sheet') && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') && a.type !== 'checkbox') return;
    var body = doc.querySelector('#sheet .sheet-body'), top = body ? body.scrollTop : 0;
    A.openSettings(S.sheet.detent());
    body = doc.querySelector('#sheet .sheet-body');
    if (body) body.scrollTop = top;
  }

  /* ---- M8: Display and Appearance (device view state, D5, §5.4) ---- */

  A.PREFS = { density: 'comfortable', showWeekends: true, weekNumbers: false };
  var APPEARANCE = { auto: 'Auto', light: 'Light', dark: 'Dark' };
  // The prefs in force: stored ones, over the defaults, plus this
  // launch's own when appState cannot be written (the embed).
  A.prefs = function () {
    var p = Object.assign({}, A.PREFS, S.store ? S.store.prefs.all() : {}, S.localPrefs || {});
    if (p.density !== 'compact') p.density = 'comfortable';
    p.showWeekends = p.showWeekends !== false;
    p.weekNumbers = p.weekNumbers === true;
    return p;
  };
  function legendOn() {
    var v = A.prefs().legend;
    return v === undefined || v === null ? true : !!v;       // auto-shown until turned off (§12.7)
  }
  A.legendOn = legendOn;
  A.setPref = function (key, v) {
    var o = {};
    o[key] = v;
    S.localPrefs = Object.assign({}, S.localPrefs || {}, o);
    var w = S.launch.embed ? Promise.resolve(null) : S.store.prefs.set(o);
    applyPrefs();
    return w;
  };
  function applyPrefs() {
    var p = A.prefs();
    S.view.setDisplay({ density: p.density, showWeekends: p.showWeekends, weekNumbers: p.weekNumbers, nameW: isObj(p.nameW) ? p.nameW : null });
    renderLegend();
  }
  A.applyPrefs = applyPrefs;
  A.toggleLegend = function () { return A.setPref('legend', !legendOn()); };
  A.openDisplay = function () {
    var p = A.prefs();
    S.sheet.openForm({
      kind: 'display', title: T('Display'), noFocus: true,
      fields: [
        { name: 'density', type: 'choice', label: T('Rows'), value: p.density,
          options: [{ value: 'comfortable', label: T('Regular') }, { value: 'compact', label: T('Compact') }] },
        { name: 'showWeekends', type: 'switch', label: T('Shade weekends'), value: p.showWeekends },
        { name: 'weekNumbers', type: 'switch', label: T('Week numbers'), value: p.weekNumbers },
        { name: 'legend', type: 'switch', label: T('Legend'), value: legendOn() }
      ],
      onChange: function (name, v) { A.setPref(name, v); },
      actions: [
        { id: 'reset-names', label: T('Reset name column'), run: function () { A.setNameW(null, true); return true; } },
        { id: 'done', label: T('Done'), primary: true }
      ]
    }, 'peek');
    reg(A.openDisplay);
    return true;
  };
  A.openAppearance = function () {
    S.sheet.openForm({
      kind: 'appearance', title: T('Appearance'),
      // Only where the host publishes no theme (hosts before M10).
      text: typeof S.host.theme() === 'string' ? '' : T('Note Synapse’s own dark mode is not visible to apps yet. If you use it, pick Dark here.'),
      fields: [{ name: 'theme', type: 'choice', label: T('Theme'), value: GT.theme.override(),
        options: [{ value: 'auto', label: T('Auto') }, { value: 'light', label: T('Light') }, { value: 'dark', label: T('Dark') }] }],
      onChange: function (name, v) { A.setTheme(v); },
      actions: [{ id: 'done', label: T('Done'), primary: true }]
    }, 'peek');
    reg(A.openAppearance);
    return true;
  };
  // §12.1: the in-app override, stored in appState prefs.theme.
  A.setTheme = function (v) {
    v = v === 'light' || v === 'dark' ? v : 'auto';
    GT.theme.setOverride(v);
    return A.setPref('theme', v);
  };
  /*
   * setNameW(px, store): the name column for the current orientation
   * (§14.2): clamped to 56 px .. half the width, snapping to the 56 px mini
   * column below 88; null goes back to the default. store writes prefs.nameW.
   */
  A.setNameW = function (px, store, from) {
    var vs = S.view.viewSize(), m = vs.metrics, key = m && m.landscape ? 'l' : 'p', R = GT.render;
    var cur = A.prefs().nameW, nw = Object.assign({}, isObj(cur) ? cur : {});
    // A width set by hand replaces any width the toggle remembered (review
    // of device feedback round 1); a drag into the mini column remembers the
    // width the drag started from, so the toggle can expand back to it.
    if (px === null) delete nw[key];
    else nw[key] = R.clampNameW(px, vs.w || 390);
    if (px === null || nw[key] !== R.NAME_MIN) delete nw[key + 'r'];
    else if (typeof from === 'number' && from >= R.NAME_SNAP) nw[key + 'r'] = Math.round(from);
    var val = Object.keys(nw).length ? nw : null;
    if (store) return A.setPref('nameW', val);
    S.localPrefs = Object.assign({}, S.localPrefs || {}, { nameW: val });
    applyPrefs();
    return null;
  };

  /*
   * toggleNames(): the corner toggle (device feedback round 1). Collapses
   * the name column to the 56 px mini column, remembering the width it had
   * (prefs.nameW.pr / .lr, absent for the default), or restores it.
   */
  A.toggleNames = function () {
    var vs = S.view.viewSize(), m = vs.metrics;
    if (!m) return null;
    var key = m.landscape ? 'l' : 'p', rk = key + 'r', R = GT.render;
    var cur = A.prefs().nameW, nw = Object.assign({}, isObj(cur) ? cur : {});
    if (m.mini) {
      var back = nw[rk];
      delete nw[rk];
      if (typeof back === 'number' && isFinite(back) && back >= R.NAME_SNAP) nw[key] = R.clampNameW(back, vs.w || 390);
      else delete nw[key];
    } else {
      if (typeof nw[key] === 'number' && isFinite(nw[key])) nw[rk] = nw[key];
      else delete nw[rk];
      nw[key] = R.NAME_MIN;
    }
    return A.setPref('nameW', Object.keys(nw).length ? nw : null);
  };

  /* ---- M8: the legend (§12.7) ---- */

  var legendKey = '';
  var STYLE_LABEL = { fill: 'Fill', segments: 'Segments', dots: 'Dots' };
  var BY_LABEL = { status: 'Status', group: 'Group', task: 'Task' };
  function renderLegend() {
    var box = $('legend');
    if (!box || !S.view) return;
    var c = S.mode === 'chart' && S.session && S.store.session === S.session ? S.session.live : null;
    var on = !!c && !S.launch.embed && c.tasks.length > 0 && legendOn();
    if (!on) { if (!box.hidden) box.hidden = true; legendKey = ''; return; }
    var classes = [], gone = {};
    c.tasks.forEach(function (t) {
      var inf = S.view.info(t.id);
      var k = inf ? (inf.missing ? 'missing' : inf.cls) : null;
      if (k && classes.indexOf(k) < 0) classes.push(k);
      if (inf && inf.missing) gone[t.id] = 1;
    });
    var lg = GT.layout.legend(c, classes, c.settings, { weekends: A.prefs().showWeekends, missing: gone });
    var key = JSON.stringify([I().language, lg]);
    if (key === legendKey && !box.hidden) return;
    legendKey = key;
    clear(box);
    var head = el('div', 'lg-head');
    head.appendChild(el('span', null, T('Legend')));
    var x = el('button', 'lg-close', '×');
    x.type = 'button';
    x.setAttribute('aria-label', T('Hide legend'));
    x.setAttribute('data-action', 'legend-close');
    x.addEventListener('click', function () { A.setPref('legend', false); });
    head.appendChild(x);
    box.appendChild(head);
    // Two columns, so the card stays short on a phone.
    var grid = el('div', 'lg-grid');
    box.appendChild(grid);
    function line(swCls, label, kind) {
      var r = el('div', 'lg-row');
      if (kind) r.setAttribute('data-kind', kind);
      r.appendChild(el('span', swCls));
      r.appendChild(el('span', 'lg-l', label));
      grid.appendChild(r);
    }
    lg.rows.forEach(function (r) {
      if (r.kind === 'class') line('lg-sw c-' + r.hue + ' k-' + r.key, T(r.label), 'class-' + r.key);
      else if (r.kind === 'cue') line('lg-sw k-cue-' + r.key, T(r.label), 'cue-' + r.key);
      else line('lg-sw c-' + r.hue, r.nogroup ? T('No group') : (r.label || T('Untitled')), 'group');
    });
    if (lg.by === 'task') box.insertBefore(el('div', 'lg-foot', T('Each task keeps its own colour.')), grid);
    else if (lg.owned) box.insertBefore(el('div', 'lg-foot lg-owned', T('Tasks with their own colour keep it.')), grid);
    var EXTRA = { today: 'Today', weekend: 'Weekend', milestone: 'Milestone' };
    lg.extras.forEach(function (k) { line('lg-sw k-' + k, T(EXTRA[k]), k); });
    box.appendChild(el('div', 'lg-foot', I().fmt('Colour by {by} · {style}', { by: T(BY_LABEL[lg.by]), style: T(STYLE_LABEL[lg.style]) })));
    box.hidden = false;
  }
  A.renderLegend = renderLegend;

  /* ---- M8: reduced motion (§12.5) ---- */

  // html.reduce-motion mirrors prefers-reduced-motion, so the same rules
  // hold when the media query cannot be emulated (and in the dev pages).
  A.syncMotion = function () {
    var on = mediaReduced();
    doc.documentElement.classList.toggle('reduce-motion', on);
    return on;
  };
  A.rename = function () {
    var s = S.session;
    if (!s || !editable()) return;
    S.sheet.openForm({
      kind: 'rename', title: T('Rename chart'),
      fields: [{ name: 'title', label: T('Chart title'), type: 'text', value: s.title || $('title').textContent }],
      actions: [
        { id: 'save', label: T('Rename'), primary: true, run: function (v) { A.renameTo(v.title); } },
        { id: 'cancel', label: T('Cancel') }
      ]
    }, 'peek');
    reg(A.rename);
  };
  A.renameTo = function (title) {
    var s = S.session;
    title = String(title || '').replace(/\s+/g, ' ').trim();
    if (!s || !title || title === s.title || !editable()) return Promise.resolve({ ok: false });
    // The entry belongs to this session's stack: a chart switch during the
    // round trip must not put it on another chart's stack (M6 review).
    var stack = S.stack;
    return S.store.renameChart(title).then(function (r) {
      if (S.session !== s || S.stack !== stack) return { ok: r.ok, reason: 'superseded' };
      if (r.ok) {
        stack.push({ label: 'Rename' + SEP + title, patches: r.inverse });
        setTitle(title);
      } else if (r.reason === 'denied') A.toast(T('The chart was not renamed: not approved'));
      syncUi();
      return r;
    });
  };

  /* ---- the save UI: pill, notice, banners, conflicts (§9.1, §9.4) ---- */

  var PILL = A.PILL = { saved: 'Saved', saving: 'Saving…', unsaved: 'Unsaved changes. Tap to save', 'not-saved': 'Not saved. Tap to save' };
  function updatePill() {
    var p = $('pill'), s = S.session;
    if (!p) return;
    var on = S.mode === 'chart' && !S.launch.embed && !!s && S.store.session === s && s.status === 'ok' && !s.readOnly;
    p.hidden = !on;
    if (!on) return;
    var ui = S.store.ui(), state = ui.pill;
    // Autosave shows only Saved and Saving… (§9.1.3): an edit waiting for
    // its debounced save is Saving…; "Tap to save" appears in auto only
    // after a save that failed.
    if (ui.mode === 'auto' && state === 'unsaved' && (s.debounce !== null || !s.lastResult || s.lastResult.ok)) state = 'saving';
    p.textContent = T(PILL[state] || 'Saved');
    p.className = 'pill ' + state;
    p.setAttribute('data-state', state);
    p.setAttribute('data-mode', ui.mode);
    p.disabled = s.journalHold || !(state === 'unsaved' || state === 'not-saved');
  }
  A.tapPill = function () {
    var s = S.session;
    if (!s || s.journalHold) return Promise.resolve(null);
    var p = S.store.save();
    syncUi();
    return p;
  };
  function updateToolbar() {
    var chart = S.mode === 'chart' && !S.launch.embed, ed = editable();
    [['btnUndo', 'undo'], ['btnRedo', 'redo']].forEach(function (x) {
      var b = $(x[0]);
      b.hidden = !chart;
      var can = ed && !!S.stack && (x[1] === 'undo' ? S.stack.canUndo() : S.stack.canRedo());
      b.disabled = !can;
      b.setAttribute('aria-label', A.undoLabel(x[1]));
    });
    $('btnMore').hidden = !chart;
    // Read-only (a future version, a damaged block, a write failure): the
    // FAB is hidden (§12.6); under journalHold it is only disabled (M6).
    var s = S.session, hard = !!s && S.store.session === s && (s.readOnly || s.status !== 'ok');
    var fab = $('fab'), add = $('btnAdd');
    fab.hidden = !chart || hard;
    fab.disabled = !ed;
    if (add) { add.hidden = !chart || hard; add.disabled = !ed; }
    $('title').classList.toggle('editable', ed);
    // The empty chart's call to action (§12.6): only where it can act.
    var acts = doc.querySelector('#empty .e-acts');
    if (acts) {
      acts.hidden = !chart || hard;
      Array.prototype.forEach.call(acts.querySelectorAll('button'), function (b) { b.disabled = !ed; });
    }
  }
  // One place that follows store.ui(): banner, pill, toolbar, handles, sheet.
  function syncUi() {
    if (!S.store || !S.view) return;
    // Ghost bars read "Tap to schedule" only while the chart is editable.
    if (S.mode === 'chart' && S.session && S.lastEditable !== editable()) renderSession(S.session);
    if (S.mode === 'chart') showBanner();
    updatePill();
    updateToolbar();
    if (S.mode === 'chart') syncHandles();
    if (S.sheet && S.sheet.taskId()) S.sheet.update();
    // §9.1.3: the notice shows when an editable chart first opens, before
    // any edit can start a save (M6 review round 1).
    if (editable()) noticeCheck();
  }
  A.syncUi = syncUi;

  // The one-time approval notice (§9.1.3), shown when an editable chart
  // opens, above the save pill (it covers no row of the chart's top).
  A.NOTICE = 'Note Synapse asks before an app edits a note. Tick \'{allow}\', then {approve}, so the chart can save as you work.';
  A.noticeText = function () { return I().fmt(A.NOTICE, { allow: T('Allow for this session'), approve: T('Approve') }); };
  function noticeCheck(force) {
    if (S.launch.embed || (!force && (S.noticeShown || S.store.prefs.get('approvalNoticeSeen')))) return;
    S.noticeShown = true;
    var n = $('notice');
    clear(n);
    n.appendChild(el('div', 'n-text', A.noticeText()));
    var b = el('button', null, T('Got it'));
    b.type = 'button';
    b.setAttribute('data-action', 'dismiss');
    b.addEventListener('click', A.dismissNotice);
    n.appendChild(b);
    n.hidden = false;
  }
  // Shows the notice now (the dev pages' screenshots), whatever prefs say.
  A.showNotice = function () { noticeCheck(true); };
  // Hidden (Got it, or leaving the chart): the next editable chart shows it
  // again unless Got it stored approvalNoticeSeen.
  function hideNotice() { var n = $('notice'); S.noticeShown = false; if (n && !n.hidden) n.hidden = true; }
  A.dismissNotice = function () {
    hideNotice();
    restoreFocus();
    return S.store.prefs.set({ approvalNoticeSeen: true });
  };

  var toastTimer = null;
  A.toast = function (text, action) {
    var t = $('toast');
    clear(t);
    t.appendChild(el('span', null, text));
    if (action) {
      var b = el('button', null, action.label);
      b.type = 'button';
      b.addEventListener('click', function () { t.hidden = true; action.run(); restoreFocus(); });
      t.appendChild(b);
    }
    t.hidden = false;
    if (toastTimer !== null) win.clearTimeout(toastTimer);
    toastTimer = win.setTimeout(function () { toastTimer = null; t.hidden = true; }, action ? 6000 : 3000);
  };

  A.restore = function () {
    var r = S.store.journal.restore();
    if (r.ok) afterRestore(r);
    else if (r.reason === 'conflict') conflictSheet('restore', r.conflicts);
    return r;
  };
  function afterRestore(r) {
    // Restore clears the undo stack (§9.1.5 Restore row).
    if (r.clearUndo) S.stack.clear();
    afterChange();
    if (r.save) r.save.then(syncUi);
  }
  A.discard = function () {
    var r = S.store.journal.discard();
    afterChange();
    return r;
  };
  A.copyJson = function (chart) {
    if (!chart) return;
    var text = JSON.stringify(chart);
    var done = function () { A.toast(T('Chart JSON copied')); };
    function fallback() {
      var ta = el('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed'; ta.style.opacity = '0';
      doc.body.appendChild(ta);
      ta.select();
      try { doc.execCommand('copy'); } catch (e) { /* nothing more to try */ }
      doc.body.removeChild(ta);
      done();
    }
    A.lastCopied = text;
    try {
      if (win.navigator.clipboard && win.navigator.clipboard.writeText) { win.navigator.clipboard.writeText(text).then(done, fallback); return; }
    } catch (e) { /* fall back */ }
    fallback();
  };

  // Repair (malformed) and "Use the first block" (extra): a second,
  // explicit confirmation that shows the exact text replaced (§5.5).
  A.confirmRepair = function (what) {
    var s = S.session;
    if (!s || S.launch.embed) return;
    var malformed = what === 'malformed';
    S.sheet.openForm({
      kind: 'repair', title: T(malformed ? 'Repair this chart?' : 'Use the first chart block?'),
      text: T(malformed ? 'Repair replaces the text below with an empty chart. The rest of the note is kept.'
        : 'The first chart block is saved in place. The other block stays in the note as text.'),
      fields: [{ type: 'code', name: 'span', value: s.region || '' }],
      actions: [
        { id: 'confirm', label: T(malformed ? 'Repair' : 'Use the first block'), danger: malformed, primary: !malformed,
          run: function () { S.store.repair(what).then(function () { afterChange(); }); } },
        { id: 'cancel', label: T('Cancel') }
      ]
    }, 'full');
    reg(function () { A.confirmRepair(what); });
  };

  var FIELD = A.FIELD = { start: 'Start', end: 'End', group: 'Group', color: 'Colour', milestone: 'Milestone', after: 'Depends on',
    note: 'Note', progress: 'Sub-items', title: 'Title', removed: 'Removed' };
  function conflictLabel(c) {
    var k = String(c.key), dot = k.indexOf('.'), id = dot < 0 ? k : k.slice(0, dot), field = dot < 0 ? '' : k.slice(dot + 1);
    if (id === 'settings') return T('Chart settings') + ' · ' + field;
    var chart = live(), name = id;
    var t = chart ? M().task(chart, id) : null, g = chart ? M().group(chart, id) : null;
    if (t) name = titleOf(id);
    else if (g) name = g.title || T('Untitled');
    else if (c.base && typeof c.base === 'object' && c.base.title) name = c.base.title;
    return name + ' · ' + (FIELD[field] ? T(FIELD[field]) : field);
  }
  function conflictValue(c, v) {
    var field = String(c.key).split('.').pop();
    if (v === null || v === undefined) return T(field === 'removed' ? 'Removed' : 'None');
    if ((field === 'start' || field === 'end') && typeof v === 'number') return I().date.short(v);
    if (typeof v === 'boolean') return T(v ? 'Yes' : 'No');
    if (typeof v === 'object') return Array.isArray(v) ? v.join(', ') : T('Kept');
    return String(v);
  }
  /*
   * The conflict sheet (§9.4): per-field Keep mine / Take theirs, or all at
   * once. 'save' conflicts feed store.saveOnce(s, {resolutions}); 'restore'
   * conflicts feed journal.restore(resolutions), only while store.ui().sheet
   * says the store's sheet for that offer is still open.
   */
  function conflictSheet(source, conflicts) {
    if (!conflicts || !conflicts.length) return;
    S.conflict = { source: source };
    function resolve(res) {
      if (source === 'restore') {
        if (!S.store.ui().sheet) return false;
        var r = S.store.journal.restore(res);
        if (r.ok) { S.conflict = null; afterRestore(r); return false; }
        if (r.reason === 'conflict') { conflictSheet('restore', r.conflicts); return true; }
        return false;
      }
      var s = S.session;
      S.conflict = null;
      S.store.saveOnce(s, { resolutions: res }).then(function () { afterChange(); });
      return false;
    }
    function all(v) { var o = {}; conflicts.forEach(function (c) { o[c.key] = v; }); return o; }
    S.sheet.openForm({
      kind: 'conflict', title: T('This chart changed elsewhere'),
      text: T('The same fields were changed here and in the note. Choose what to keep.'),
      fields: conflicts.map(function (c) {
        return {
          name: c.key, type: 'choice', label: conflictLabel(c), value: 'mine',
          detail: I().fmt('Mine: {mine} · Theirs: {theirs}', { mine: conflictValue(c, c.mine), theirs: conflictValue(c, c.theirs) }),
          options: [{ value: 'mine', label: T('Keep mine') }, { value: 'theirs', label: T('Take theirs') }]
        };
      }),
      actions: [
        { id: 'mine', label: T('Keep mine for these'), primary: true, run: function () { return resolve(all('mine')); } },
        { id: 'theirs', label: T('Take theirs'), run: function () { return resolve(all('theirs')); } },
        { id: 'rows', label: T('Save choices'), run: function (v) { return resolve(v); } },
        { id: 'cancel', label: T('Cancel') }
      ]
    }, 'full');
    reg(function () { conflictSheet(source, conflicts); });
  }
  A.conflictSheet = conflictSheet;
  function onSheetClose(kind, id) {
    // Closing the Restore conflict sheet any way but a resolution cancels it.
    if (S.conflict && S.conflict.source === 'restore' && S.store.ui().sheet) S.store.journal.cancelSheet();
    S.conflict = null;
    syncUi();
    // M9 focus (§15.2): a task sheet opened from the Task list goes back to
    // the list with its row focused.
    if (kind === 'task' && S.fromList) { S.fromList = false; if (live()) { A.openTaskList(null, id); return; } }
    // Focus went back to a pooled row that now shows another task (the
    // column scrolled while the sheet was open): focus the task's own row.
    var a = doc.activeElement;
    if (kind === 'task' && id && a && a.closest && a.closest('#gantt .g-name, #gantt .g-bar') && a.getAttribute('data-id') !== id && taskOf(id)) S.view.focusRow('task', id);
    else if (!a || a === doc.body) restoreFocus();
  }
  /*
   * After a banner, toast, notice or sheet action removed the focused
   * control, focus goes to the chart's roving row (or the top bar), never
   * to the document body (§15.2).
   */
  function restoreFocus() {
    // Only for keyboard use: after a tap nothing takes the focus (and the
    // chart never scrolls to a row on its own).
    if (!S.kbd) return;
    var a = doc.activeElement;
    if (a && a !== doc.body && a.isConnected && !a.closest('[hidden]')) return;
    if (S.mode === 'chart' && A.focusChart()) return;
    var b = $(S.mode === 'chart' ? 'btnMore' : 'btnHome');
    if (b && !b.hidden) { try { b.focus({ preventScroll: true }); } catch (e) { /* no focus */ } }
  }
  A.restoreFocus = restoreFocus;
  function onSave(r) {
    syncUi();
    // §9.2: a failed date entry never fails the chart save; it is kept and said.
    if (r && r.ok && S.mode === 'chart' && r.datesFailed > 0) {
      A.toast(I().fmt('Dates not written to {n} task note(s)', { n: r.datesFailed }));
    }
    if (!r || r.ok || S.mode !== 'chart') return;
    if (r.reason === 'conflict' && r.conflicts && r.conflicts.length) conflictSheet('save', r.conflicts);
    else if (r.reason === 'removed') A.toast(T('The chart block was removed from the note. Your changes are kept.'));
  }

  /* ------------------------------------------------ navigation input (M5) */

  // What a pointer landed on, from the event target (no layout read, §13.1).
  // Buttons (D/W/M, zoom) and the column divider keep their own clicks.
  function hit(target, x, y, out) {
    var t = target && target.closest ? target : null;
    if (!t || t.closest('button, .g-corner, .g-divider, .g-zoom')) return null;
    var e;
    if (t.closest('.g-hdr-cv')) { out.kind = 'header'; return out; }
    if ((e = t.closest('.g-grp'))) { out.kind = 'group'; out.id = e.getAttribute('data-group'); return out; }
    if ((e = t.closest('.g-name'))) { out.kind = 'name'; out.id = e.getAttribute('data-id'); return out; }
    if (t.closest('.g-names')) { out.kind = 'rows'; return out; }
    // M6: the resize handles of the selected bar, and the selected bar itself.
    if ((e = t.closest('.g-handle'))) { out.kind = 'handle'; out.id = e.getAttribute('data-id'); out.edge = e.getAttribute('data-edge'); return out; }
    if ((e = t.closest('.g-bar'))) {
      out.id = e.getAttribute('data-id');
      out.kind = out.id && out.id === S.sel ? 'barSel' : 'bar';
      return out;
    }
    if (t.closest('.g-body')) { out.kind = 'bg'; return out; }
    return null;
  }

  // Taps (§13.2): a bar selects and peeks, the selected bar toggles the
  // sheet, a name selects and scrolls its bar into view, the grid clears.
  function tap(kind, id, x) {
    var view = S.view;
    if (kind === 'group' && id) { A.toggleGroup(id); return; }
    if (kind === 'header') { view.jumpToUnit(x); noteCamera(); return; }
    if (S.launch.embed) return;
    // An unscheduled task's ghost bar: a tap schedules it (§12.6).
    if ((kind === 'bar' || kind === 'barSel') && id && editable() && taskOf(id) && typeof taskOf(id).start !== 'number') { A.schedule(id); return; }
    if (kind === 'bar' && id) { A.select(id); A.openSheet(id, 'peek'); return; }
    if (kind === 'barSel' && id) {
      if (S.sheet.taskId() === id) S.sheet.close(); else A.openSheet(id, 'peek');
      return;
    }
    if (kind === 'name' && id) { A.select(id); view.scrollIntoView(id); A.openSheet(id, 'peek'); return; }
    if (kind === 'bg') {
      A.select(null);
      if (S.sheet.taskId() && S.sheet.detent() === 'peek') S.sheet.close();
    }
  }

  function mediaReduced() {
    try { return !!(win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)').matches); } catch (e) { return false; }
  }
  // html.reduce-motion is the one switch (M9): the media query sets it
  // (syncMotion), and every animation in CSS and JS follows it.
  function reducedMotion() { return mediaReduced() || doc.documentElement.classList.contains('reduce-motion'); }
  A.ZOOM_STEP = 1.6;             // + and - (§11.4)
  A.ZOOM_MS = 180;
  // Toolbar and key actions take the camera: a running fling stops first,
  // or its next frame would pan away from (or cancel) what was asked for.
  function takeCamera() { if (S.gestures) S.gestures.stopFling(); }
  A.zoomIn = function () { takeCamera(); S.view.zoomBy(A.ZOOM_STEP, reducedMotion() ? 0 : A.ZOOM_MS); };
  A.zoomOut = function () { takeCamera(); S.view.zoomBy(1 / A.ZOOM_STEP, reducedMotion() ? 0 : A.ZOOM_MS); };
  A.fitAll = function () { takeCamera(); S.view.fitAll(); noteCamera(); };
  A.today = function () { takeCamera(); S.view.goToday(); noteCamera(); };
  A.preset = function (name) { takeCamera(); S.view.setPreset(name); noteCamera(); };

  function wireInput(root) {
    var view = S.view;
    // #gantt starts at the left edge of the page (#app is fixed at inset 0),
    // so the timeline body starts at the name column's width.
    function toX(clientX) { return clientX - view.nameW(); }
    var liveMemo = false;
    S.gestures = GT.gestures.attach(root, {
      hit: hit,
      toX: toX,
      panBy: function (dx, dy) { return view.panBy(dx, dy); },
      zoomAt: function (f, x) { return view.zoomAt(f, x); },
      settle: noteCamera,
      // One class write when a gesture starts and ends, never per move (§12.5).
      live: function (on) { if (on !== liveMemo) { liveMemo = on; root.classList.toggle('live', on); } },
      tap: tap,
      longPress: longPress,
      dragStart: dragStart,
      dragMove: dragMove,
      drop: drop,
      edgeRect: edgeRect,
      cancelDrag: cancelDrag
    }, { frame: S.frame, cancelFrame: S.cancelFrame });

    // Hardware keyboards and the harness (§13.2).
    doc.addEventListener('keydown', function (e) {
      if (S.mode !== 'chart') return;
      var t = e.target;
      if (t && t.closest && t.closest('input, textarea, select, [contenteditable]')) return;
      var k = e.key, mod = e.ctrlKey || e.metaKey;
      if (mod && (k === 'z' || k === 'Z')) { if (e.shiftKey) A.redo(); else A.undo(); e.preventDefault(); return; }
      if (mod && (k === 'y' || k === 'Y')) { A.redo(); e.preventDefault(); return; }
      if (mod) return;
      if (k === 'Escape') {
        if (S.sheet.isOpen()) S.sheet.close(); else if (S.sel) A.select(null); else return;
        e.preventDefault();
        return;
      }
      // Keys on a control (a button, the sheet, a banner) are the control's,
      // and a modal sheet (FULL, a menu or a form) takes no chart edits.
      var control = !!(t && t.closest && t.closest('#sheet, #banner, #notice, #toast, #topbar, button, a, [role="dialog"]'));
      // Delete asks to remove (§13.2); its sheet takes focus on its title, so
      // the second press comes from there.
      var onTitle = !!(t && t.closest && t.closest('#sheet .sh-title'));
      if ((k === 'Delete' || k === 'Backspace') && S.sel && !S.launch.embed && (!control || onTitle)) {
        A.askRemove(S.sel);
        e.preventDefault();
        return;
      }
      if (control) return;
      if (S.sheet.isOpen() && (S.sheet.detent() === 'full' || !S.sheet.taskId())) return;
      // M9 roving focus (§15.2): on a name row or group header, arrows,
      // Home and End move the focused row; Enter or Space opens a task's
      // sheet or toggles a group; Left and Right fold a group. On a task
      // row Left and Right keep moving or resizing the task (below).
      var rw = rowOf(t);
      if (rw) {
        if (k === 'ArrowDown' || k === 'ArrowUp') {
          if (e.altKey && rw.kind === 'task') { A.nudgeOrder(k === 'ArrowDown' ? 1 : -1); S.view.focusRow('task', S.sel || rw.id); }
          else A.moveFocus(k === 'ArrowDown' ? 1 : -1, rw);
          e.preventDefault();
          return;
        }
        if (k === 'Home' || k === 'End') { A.moveFocus(k === 'Home' ? 'first' : 'last', rw); e.preventDefault(); return; }
        if (rw.kind === 'group') {
          var shut = S.collapsed.indexOf(rw.id) >= 0;
          if (k === 'Enter' || k === ' ' || (k === 'ArrowLeft' && !shut) || (k === 'ArrowRight' && shut)) A.toggleGroup(rw.id);
          else return;
          S.view.focusRow('group', rw.id);
          e.preventDefault();
          return;
        }
        if (rw.id !== S.sel) A.select(rw.id);
        if (k === ' ' && !S.launch.embed) { A.openSheet(rw.id, 'peek'); e.preventDefault(); return; }
      }
      if (k === 'Enter' && S.sel && !S.launch.embed) { A.openSheet(S.sel, 'peek'); e.preventDefault(); return; }
      if ((k === 'ArrowLeft' || k === 'ArrowRight') && S.sel) {
        var dx = k === 'ArrowRight' ? 1 : -1;
        A.nudge(e.shiftKey ? 'end' : (e.altKey ? 'start' : 'move'), dx);
        e.preventDefault();
        return;
      }
      if (k === 'ArrowUp' || k === 'ArrowDown') {
        var dy = k === 'ArrowDown' ? 1 : -1;
        if (e.altKey) { var had = focusInChart(); A.nudgeOrder(dy); if (had && S.sel) S.view.focusRow('task', S.sel); } else A.selectNext(dy);
        e.preventDefault();
        return;
      }
      if (e.altKey) return;
      if (k === '+' || k === '=') A.zoomIn();
      else if (k === '-' || k === '_') A.zoomOut();
      else if (k === 't' || k === 'T') A.today();
      else if (k === 'd' || k === 'w' || k === 'm') A.preset({ d: 'day', w: 'week', m: 'month' }[k]);
      else return;
      e.preventDefault();
    });

    // The last input was a key (focus is restored only then) or a pointer.
    doc.addEventListener('keydown', function () { S.kbd = true; }, { capture: true, passive: true });
    doc.addEventListener('pointerdown', function () { S.kbd = false; }, { capture: true, passive: true });
    // A name row that takes the focus (Tab) selects its task (§15.2).
    root.addEventListener('focusin', function (e) {
      var rw = rowOf(e.target);
      if (rw && rw.kind === 'task' && rw.id !== S.sel && !S.launch.embed && S.mode === 'chart') A.select(rw.id);
    });

    // The page itself never zooms (§13.1, supportZoom is on in the WebView):
    // ctrl-wheel anywhere and WebKit's gesture events are refused. These two
    // listeners are non-passive because they must preventDefault.
    win.addEventListener('wheel', function (e) { if (e.ctrlKey) e.preventDefault(); }, { passive: false });
    ['gesturestart', 'gesturechange', 'gestureend'].forEach(function (n) {
      doc.addEventListener(n, function (e) { e.preventDefault(); }, { passive: false });
    });
  }

  /*
   * The name column divider (§14.2): a drag resizes the column between
   * 56 px and half the width (snapping to the mini column below 88 px);
   * the width is stored per orientation when the drag ends. The gesture
   * layer leaves the divider alone (a control, §13.1).
   */
  function wireDivider(dv) {
    if (!dv) return;
    var drag = null;
    dv.addEventListener('pointerdown', function (e) {
      if (S.mode !== 'chart' || (e.pointerType === 'mouse' && e.button !== 0)) return;
      drag = { id: e.pointerId, x0: e.clientX, w0: S.view.nameW(), w: null };
      try { dv.setPointerCapture(e.pointerId); } catch (x) { /* synthetic */ }
      e.preventDefault();
    });
    dv.addEventListener('pointermove', function (e) {
      if (!drag || e.pointerId !== drag.id) return;
      drag.w = drag.w0 + (e.clientX - drag.x0);
      A.setNameW(drag.w, false);
    });
    function end(e) {
      if (!drag || e.pointerId !== drag.id) return;
      var d = drag;
      drag = null;
      if (d.w !== null) A.setNameW(d.w, true, d.w0);
    }
    dv.addEventListener('pointerup', end);
    dv.addEventListener('pointercancel', end);
  }

  /*
   * M9 live locale switch (§15.1): every string on screen follows the new
   * language in place. Selection, camera, collapsed groups, the open sheet
   * (its detent, scroll, focus and typed text), the banner, the legend and
   * the page shown all stay; nothing is re-read except a chooser's lists.
   */
  A.setLocale = function (tag) {
    I().setLanguage(tag);
    applyI18n();
    S.view.invalidate(GT.render.FLAGS.LOCALE);
    // One frame now, so the task labels a sheet or list reads are relabelled.
    S.view.flushNow();
    lastBanner = '';
    if (S.mode !== 'chart' && S.redraw) S.redraw();
    if (S.sheet.isOpen()) {
      if (S.sheet.kind() === 'task') S.sheet.relabel();
      else if (S.again && S.againSpec === S.sheet.spec()) S.sheet.relabel(S.again);
    }
    if (S.noticeShown && !$('notice').hidden) { var nt = $('notice').querySelector('.n-text'), nb = $('notice').querySelector('button'); if (nt) nt.textContent = A.noticeText(); if (nb) nb.textContent = T('Got it'); }
    renderLegend();
    syncUi();
    return I().language;
  };

  /* ---------------------------------------------------------------- boot */

  /*
   * boot(opts): opts {host, now, theme ('light'|'dark', not stored),
   * frame, cancelFrame (the frame scheduler for render and gestures), dpr
   * (canvas pixel ratio; default the device's)}. Dev pages pass the mock's
   * host and a fixed clock.
   * -> Promise that resolves once the first screen is shown.
   */
  A.boot = function (opts) {
    opts = opts || {};
    doc = global.document;
    win = global;
    var H = (S.host = opts.host || GT.host);
    S.frame = opts.frame;
    S.cancelFrame = opts.cancelFrame;
    S.now = opts.now || function () { return Date.now(); };
    var L = (S.launch = H.launch());
    I().setLanguage(L.locale);
    applyI18n();
    GT.theme.init({ doc: doc, win: win, hostTheme: H.theme(), override: opts.theme });
    if (L.embed) { doc.body.classList.add('embed'); doc.body.classList.remove('standalone'); }

    // The store's journal frame runs on the same scheduler as the view.
    var store = (S.store = GT.store.create({ host: H, now: S.now, frame: opts.frame, cancelFrame: opts.cancelFrame }));
    var root = $('gantt');
    var view = (S.view = GT.render.create(root, {
      now: S.now, frame: opts.frame, cancelFrame: opts.cancelFrame, dpr: opts.dpr,
      onDay: function () { if (S.session) renderSession(S.session); },
      onSettle: function () { noteCamera(); }
    }));
    S.collapsed = [];
    if (typeof win.ResizeObserver === 'function') {
      new win.ResizeObserver(function (entries) {
        var r = entries[entries.length - 1].contentRect;
        view.setSize(r.width, r.height);
      }).observe(root);
    }
    GT.theme.onChange(function () { view.invalidate(GT.render.FLAGS.THEME); });
    resetEdit();
    S.sheet = GT.sheet;
    S.sheet.init({
      doc: doc, win: win, el: $('sheet'), scrim: $('scrim'),
      ctx: {
        text: T, fmt: function (k, v) { return I().fmt(k, v); },
        day: function (d) { return GT.dates.format(d); },
        parse: function (v) { return v ? GT.dates.parse(v) : null; },
        task: taskVm, act: sheetAct, onClose: onSheetClose, colors: GT.model.COLORS
      }
    });
    function onLive() {
      if (!S.session || store.session !== S.session) return;
      // A merge, Restore or reload can drop the selected task.
      if (S.sel && !taskOf(S.sel)) { S.sel = null; if (S.sheet.taskId()) S.sheet.close(); }
      renderSession(S.session);
      syncUi();
      refreshSettings();
    }
    store.on('live', onLive);
    store.on('facts', onLive);
    store.on('ui', syncUi);
    store.on('mode', syncUi);
    store.on('save', onSave);
    // The store closed its Restore conflict sheet (another instance's entry).
    store.on('sheet', function (sh) { if (!sh && S.conflict && S.conflict.source === 'restore' && S.sheet.kind() === 'conflict') S.sheet.close(); });
    H.on('themechanged', function (v) { GT.theme.setHostTheme(v); });
    // A resume read the chart note (M9): the reconciliation banner may change.
    store.on('read', syncUi);
    H.on('localechanged', function (v) { A.setLocale(v || H.locale()); });
    H.on('spacechanged', function () { if (S.mode === 'home') A.showHome(); });

    $('btnHome').addEventListener('click', A.goHome);
    $('btnToday').addEventListener('click', A.today);
    Array.prototype.forEach.call(doc.querySelectorAll('#zoomSeg [data-zoom]'), function (b) {
      b.addEventListener('click', function () { A.preset(b.getAttribute('data-zoom')); });
    });
    $('btnZoomIn').addEventListener('click', A.zoomIn);
    $('btnZoomOut').addEventListener('click', A.zoomOut);
    $('btnFit').addEventListener('click', A.fitAll);
    $('btnUndo').addEventListener('click', A.undo);
    $('btnRedo').addEventListener('click', A.redo);
    $('btnMore').addEventListener('click', A.openMore);
    $('fab').addEventListener('click', A.openFab);
    if ($('btnAdd')) $('btnAdd').addEventListener('click', A.openFab);
    $('pill').addEventListener('click', A.tapPill);
    $('title').addEventListener('click', function () { if (S.mode === 'chart' && editable()) A.rename(); });
    wireInput(root);
    // M8: the empty chart's actions, "Expand all", the name column divider.
    doc.querySelector('#empty [data-action="empty-add"]').addEventListener('click', function () { A.addExisting(); });
    doc.querySelector('#empty [data-action="empty-create"]').addEventListener('click', function () { A.createTaskForm(); });
    doc.querySelector('#gantt .g-allc [data-action="expand-all"]').addEventListener('click', function () { A.setAllGroups(false); });
    wireDivider(root.querySelector('.g-divider'));
    var ntog = root.querySelector('.g-ntog');
    if (ntog) ntog.addEventListener('click', function () { if (S.mode === 'chart') A.toggleNames(); });
    A.syncMotion();
    try {
      var rmq = win.matchMedia && win.matchMedia('(prefers-reduced-motion: reduce)');
      if (rmq && rmq.addEventListener) rmq.addEventListener('change', A.syncMotion);
    } catch (e) { /* no media queries */ }
    // Hidden: stop the fling and timers, free the canvases (§11.7, §14.3 rule 9).
    function hide(kind) { S.gestures.stop(); store.onHide(kind); view.suspend(); }
    doc.addEventListener('visibilitychange', function () {
      if (doc.visibilityState === 'hidden') hide('hidden'); else view.resume();
    });
    win.addEventListener('pagehide', function () { hide('pagehide'); });
    win.addEventListener('pageshow', function () { view.resume(); });

    return store.boot().then(function () {
      if (!opts.theme) {
        var p = store.prefs.get('theme');
        if (p === 'light' || p === 'dark') GT.theme.setOverride(p);
      }
      applyPrefs();
      var route = (S.route = H.route(L));
      var first = L.notes[0] || null;
      var title = first && route.noteId === first.id ? first.title : '';
      if (route.kind === 'home') return A.showHome();
      if (route.kind === 'multi') return A.showMulti(L.notes.map(function (n) { return { id: n.id, title: n.title }; }));
      if (route.kind === 'chooser') return A.showChooser(route.noteId, title);
      // chart, embed and resolve go straight to the store (M3a contract).
      return A.openChart({ noteId: route.noteId, read: route.read || null, title: title });
    }).then(function () {
      S.booted = true;
      doc.documentElement.classList.remove('boot');
      return S;
    });
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
