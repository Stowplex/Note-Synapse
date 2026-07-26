/*
 * Browser-only stub of the Note Synapse `window.Synapse` API, for developing
 * dos_station.html outside the app. Loaded by test_harness.html — never
 * shipped with the plugin.
 *
 * Coverage: just the surface DOS Station uses. proxyFetch proxies to real
 * fetch (works for CORS-enabled CDNs), crypto.digest uses WebCrypto,
 * app state persists in localStorage, and note mutations are logged to the
 * harness panel (window.parent.harnessLog).
 *
 * URL switches (on the harness page):
 *   ?scenario=zipless   note with imports but no game zip
 *   ?scenario=block     launched on a selected block (isBlockScope)
 *   ?scenario=readonly  runQuery fails, so the note text is not writable
 *   ?reset=1            forget the stub's stored note text and attachments
 */
(function () {
  'use strict';

  const hlog = (m) => {
    try { (window.parent.harnessLog || console.log)(m); } catch (_) { console.log(m); }
  };

  // A srcdoc frame has no query string of its own; the harness hands ours over.
  const params = new URLSearchParams(window.__harnessQuery || location.search);
  const scenario = params.get('scenario') || '';
  const NOTE_KEY = 'dos-station-stub-note';
  const STUB_ATTS_KEY = 'dos-station-stub-attachments';
  if (params.get('reset') === '1') {
    localStorage.removeItem(NOTE_KEY);
    localStorage.removeItem(STUB_ATTS_KEY);
    hlog('stub: storage reset');
  }

  function u8ToB64(u8) {
    let s = '';
    const chunk = 0x8000;
    for (let i = 0; i < u8.length; i += chunk) {
      s += String.fromCharCode.apply(null, u8.subarray(i, i + chunk));
    }
    return btoa(s);
  }

  /* A note deliberately full of fence shapes the scanner has to survive:
   * an auto-imported block, a plain block to pick by hand, the config block,
   * a tilde fence, and a 4-backtick block wrapping a 3-backtick one. */
  const DEFAULT_CONTENT = [
    '# Space Quest (test)',
    '',
    'My favourite childhood game.',
    '',
    '```basic {dos-name="HELLO.BAS"}',
    '10 PRINT "HELLO FROM THE NOTE"',
    '20 GOTO 10',
    '```',
    '',
    'A batch file I have not imported yet:',
    '',
    '```bat',
    '@ECHO OFF',
    'ECHO RUNNING FROM THE NOTE',
    'DIR C:\\',
    '```',
    '',
    '```dosbox',
    '[cpu]',
    'cycles=fixed 8000',
    '```',
    '',
    '~~~text',
    'a tilde fence, not importable unless picked',
    '~~~',
    '',
    '````md',
    'a wrapper block that contains a fence:',
    '```js',
    'console.log("do not split me");',
    '```',
    '````',
    '',
  ].join('\n');

  const fakeNote = {
    id: 'note-test-1',
    title: 'Space Quest (test)',
    content: DEFAULT_CONTENT,
    tags: ['games'],
    isTask: false,
    pinned: false,
    isArchived: false,
    attachmentPaths: [],
  };
  try {
    const saved = localStorage.getItem(NOTE_KEY);
    if (saved !== null) fakeNote.content = saved;
  } catch (_) {}
  const persistNote = () => {
    try { localStorage.setItem(NOTE_KEY, fakeNote.content); } catch (_) {}
  };

  // Simulates the app's uuid-renaming of stored attachments. Attachments the
  // plugin adds (frame captures, dos-saves zips) carry their base64 payload
  // and persist in localStorage so save/restore survives a page reload.
  const levels = new Uint8Array(256);
  for (let i = 0; i < levels.length; i++) levels[i] = (i * 37) & 0xff;

  const storedAttachments = [];
  if (scenario !== 'zipless') {
    storedAttachments.push({
      id: 'att-zip', seeded: true, path: 'attachments/testgame.zip',
      fileName: 'testgame.zip', mimeType: 'application/zip',
    });
  }
  // A non-zip attachment to exercise the "pull a file in by hand" path. Its
  // stored path carries a uuid suffix, like the real app's.
  storedAttachments.push({
    id: 'att-levels', seeded: true, path: 'attachments/levels_9f21ab04.dat',
    fileName: 'levels.dat', mimeType: 'application/octet-stream',
    data: u8ToB64(levels),
  });
  try {
    for (const a of JSON.parse(localStorage.getItem(STUB_ATTS_KEY) || '[]')) {
      if (!storedAttachments.some((x) => x.path === a.path)) storedAttachments.push(a);
    }
  } catch (_) {}
  const syncNoteAttachments = () => {
    fakeNote.attachmentPaths = storedAttachments.map((a) => a.path);
    try {
      localStorage.setItem(STUB_ATTS_KEY,
        JSON.stringify(storedAttachments.filter((a) => a.data && !a.seeded)));
    } catch (e) { hlog('stub attachment persist failed: ' + e.message); }
  };
  syncNoteAttachments();

  /* What the host hands the plugin. In block scope this is a transient id for
   * the selected block: `content` is only that block's text, a SELECT of
   * `content` for that id comes back patched to the block's text, a content
   * replace rewrites only that region of the parent, and an attachment change is
   * refused outright (the host tells you to target parentNoteId).
   *
   * The block is tracked by its current text rather than by offsets, so a
   * replace can find it again after the parent moved around it. */
  const BLOCK_ID = 'block-tmp-1';
  let blockText = null;
  let selected;
  if (scenario === 'block') {
    // The whole ```basic import block, so the block scope has a file in it.
    const m = /```basic[\s\S]*?```/.exec(fakeNote.content);
    blockText = m ? m[0] : '';
    selected = {
      id: BLOCK_ID,
      isBlockScope: true,
      parentNoteId: fakeNote.id,
      title: fakeNote.title,
      content: blockText,
      attachmentPaths: fakeNote.attachmentPaths.slice(),
    };
  } else {
    selected = fakeNote;
  }

  /** Splices new block text into the parent, exactly like BlockNoteScopeService. */
  const writeBackBlock = (text) => {
    const at = fakeNote.content.indexOf(blockText);
    if (at < 0) return { ok: false, error: 'the block is no longer in the note' };
    fakeNote.content =
      fakeNote.content.slice(0, at) + text + fakeNote.content.slice(at + blockText.length);
    blockText = text;
    selected.content = text;
    return { ok: true };
  };

  const diff = (before, after) => {
    const a = before.split('\n');
    const b = after.split('\n');
    let head = 0;
    while (head < a.length && head < b.length && a[head] === b[head]) head++;
    let tail = 0;
    while (tail < a.length - head && tail < b.length - head &&
      a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail++;
    const out = [];
    for (const l of a.slice(head, a.length - tail)) out.push('  - ' + l);
    for (const l of b.slice(head, b.length - tail)) out.push('  + ' + l);
    return out.length ? out.join('\n') : '  (no change)';
  };

  window.Synapse = {
    Notes: [selected],
    Params: {},

    async runQuery(sql) {
      hlog('runQuery ' + sql.slice(0, 120));
      if (scenario === 'readonly') return { success: false, error: 'query refused (harness scenario)' };
      const m = /FROM\s+notes\s+WHERE\s+id\s*=\s*'([^']*)'/i.exec(sql);
      if (!m) return { success: true, data: [] };
      // The host rewrites a block id to its parent and then patches `content`
      // back to the block's text, so a plugin never sees the parent by accident.
      if (m[1] === BLOCK_ID) return { success: true, data: [{ content: blockText }] };
      if (m[1] === fakeNote.id) return { success: true, data: [{ content: fakeNote.content }] };
      return { success: true, data: [] };
    },

    async loadAppState() {
      try {
        const raw = localStorage.getItem('dos-station-state');
        return { success: true, data: raw ? JSON.parse(raw) : null };
      } catch (e) {
        return { success: false, error: String(e) };
      }
    },

    async storeAppState(state) {
      try {
        localStorage.setItem('dos-station-state', JSON.stringify(state));
        hlog('storeAppState: keys=' + Object.keys(state).join(',') +
          ' (~' + (JSON.stringify(state).length / 1024 | 0) + ' KB)');
        return { success: true };
      } catch (e) {
        // Engine cache (~3 MB) can exceed the localStorage quota — that is
        // fine for the harness, the plugin treats store failure as soft.
        hlog('storeAppState failed (ok in harness): ' + e.message);
        return { success: false, error: String(e) };
      }
    },

    async proxyFetch(url, options) {
      hlog('proxyFetch ' + url);
      try {
        const r = await fetch(url, { method: (options && options.method) || 'GET' });
        const buf = new Uint8Array(await r.arrayBuffer());
        return {
          status: 'success',
          statusCode: r.status,
          content: { mime: r.headers.get('content-type') || '', data: u8ToB64(buf) },
        };
      } catch (e) {
        return { status: 'error', error: String(e) };
      }
    },

    crypto: {
      async digest(algorithm, data) {
        try {
          let bytes;
          if (data.base64 !== undefined) {
            const bin = atob(data.base64);
            bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          } else {
            bytes = new TextEncoder().encode(data.text || '');
          }
          const algo = algorithm === 'sha1' ? 'SHA-1' : 'SHA-256';
          const d = await crypto.subtle.digest(algo, bytes);
          const hex = [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
          return { success: true, hex };
        } catch (e) {
          return { success: false, error: String(e) };
        }
      },
    },

    async readAttachment(path) {
      hlog('readAttachment ' + path);
      if (/testgame\.zip$/.test(path)) {
        const r = await fetch('testgame.zip');
        if (!r.ok) return { success: false, error: 'HTTP ' + r.status };
        const buf = new Uint8Array(await r.arrayBuffer());
        return { success: true, data: u8ToB64(buf), mimeType: 'application/zip' };
      }
      const hit = storedAttachments.find((a) => a.path === path && a.data);
      if (hit) return { success: true, data: hit.data, mimeType: hit.mimeType };
      return { success: false, error: 'not found' };
    },

    async exportNotes(ids) {
      hlog('exportNotes ' + JSON.stringify(ids));
      return {
        success: true,
        notes: [{
          id: fakeNote.id,
          title: fakeNote.title,
          // Deliberately NOT the raw column: the real host renders sub-notes and
          // linked notes into this, which is why the plugin must not write it back.
          markdown: fakeNote.content + '\n<!-- rendered by exportNotes -->\n',
          attachments: storedAttachments.map((a) => ({
            id: a.id, path: a.path, fileName: a.fileName, mimeType: a.mimeType,
          })),
        }],
      };
    },

    async pickNotes(options) {
      hlog('pickNotes ' + JSON.stringify(options || {}));
      return { success: true, notes: [{ id: fakeNote.id, title: fakeNote.title }] };
    },

    async updateNotes(notes) {
      hlog('updateNotes:\n' + JSON.stringify(notes, (k, v) =>
        typeof v === 'string' && v.length > 120 ? v.slice(0, 90) + '…[' + v.length + ' chars]' : v, 2));
      const n = notes && notes[0];
      const mod = n && n.modification;
      if (n && n.id !== fakeNote.id && n.id !== BLOCK_ID) {
        hlog('  !! write targeted unknown id ' + n.id);
        return { success: false, error: 'no such note' };
      }
      if (n && n.id === BLOCK_ID) {
        // The host refuses note-level fields on a block and applies the content
        // action to the block's text only.
        if (!mod || !mod.content) {
          hlog('  !! refused: a block update must include a content modification');
          return { success: false, error: 'A block update must include a content modification.' };
        }
        if (mod.attachments) hlog('  !! ignoring attachments on a block-scoped update');
        const act = mod.content.action;
        const before = fakeNote.content;
        const next = act === 'append' ? blockText + '\n' + mod.content.text
          : act === 'prepend' ? mod.content.text + '\n' + blockText
            : mod.content.text;
        const res = writeBackBlock(next);
        if (!res.ok) { hlog('  !! ' + res.error); return { success: false, error: res.error }; }
        persistNote();
        hlog('  -> block ' + act + ' (parent note spliced):\n' + diff(before, fakeNote.content));
        return { success: true, updatedCount: 1 };
      }
      if (mod && mod.attachments && mod.attachments.removed) {
        for (const path of mod.attachments.removed) {
          const i = storedAttachments.findIndex((a) => a.path === path);
          if (i >= 0) {
            hlog('  -> removed ' + path);
            storedAttachments.splice(i, 1);
          }
        }
        syncNoteAttachments();
      }
      if (mod && mod.attachments && mod.attachments.added) {
        for (const a of mod.attachments.added) {
          const base = (a.fileName || 'file.bin').replace(/\.([^.]+)$/, '');
          const ext = (a.fileName || '').split('.').pop();
          const unique = base + '_' + Math.random().toString(16).slice(2, 10) + '.' + ext;
          const raw = String(a.data || '');
          storedAttachments.push({
            id: 'att-' + unique,
            path: 'attachments/' + unique,
            fileName: a.fileName,
            mimeType: ext === 'zip' ? 'application/zip'
              : (ext === 'png' ? 'image/png' : 'application/octet-stream'),
            // keep the payload so readAttachment can serve it back
            data: raw.includes(',') ? raw.split(',').pop() : raw,
          });
          hlog('  -> stored as attachments/' + unique);
        }
        syncNoteAttachments();
      }
      if (mod && mod.content) {
        const before = fakeNote.content;
        if (mod.content.action === 'append') fakeNote.content += '\n' + mod.content.text;
        else if (mod.content.action === 'prepend') fakeNote.content = mod.content.text + '\n' + before;
        else if (mod.content.action === 'replace') fakeNote.content = mod.content.text;
        if (fakeNote.content !== before) {
          persistNote();
          hlog('  -> note body ' + mod.content.action + ':\n' + diff(before, fakeNote.content));
        }
      }
      return { success: true, updatedCount: 1 };
    },

    async chatAI(prompt, options) {
      hlog('chatAI: ' + prompt.slice(0, 80) + '… (attachments: ' +
        ((options && options.attachments) || []).length + ')');
      return {
        success: true,
        response: 'That looks like a DOS prompt right after boot. Try typing DIR to explore the disk.',
      };
    },
  };

  // Handy from the harness console: window.stubNote.content = '...'
  window.stubNote = fakeNote;

  hlog('Synapse stub installed' + (scenario ? ' [scenario=' + scenario + ']' : ''));
})();
