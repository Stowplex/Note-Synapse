/*
 * Browser-only stub of the Note Synapse `window.Synapse` API, for developing
 * dos_station.html outside the app. Loaded by test_harness.html — never
 * shipped with the plugin.
 *
 * Coverage: just the surface DOS Station uses. proxyFetch proxies to real
 * fetch (works for CORS-enabled CDNs), crypto.digest uses WebCrypto,
 * app state persists in localStorage, and note mutations are logged to the
 * harness panel (window.parent.harnessLog).
 */
(function () {
  'use strict';

  const hlog = (m) => {
    try { (window.parent.harnessLog || console.log)(m); } catch (_) { console.log(m); }
  };

  function u8ToB64(u8) {
    let s = '';
    const chunk = 0x8000;
    for (let i = 0; i < u8.length; i += chunk) {
      s += String.fromCharCode.apply(null, u8.subarray(i, i + chunk));
    }
    return btoa(s);
  }

  const fakeNote = {
    id: 'note-test-1',
    title: 'Space Quest (test)',
    content: [
      '# Space Quest (test)',
      '',
      'My favourite childhood game.',
      '',
      '```dosbox',
      '[cpu]',
      'cycles=fixed 8000',
      '```',
      '',
    ].join('\n'),
    tags: ['games'],
    isTask: false,
    pinned: false,
    isArchived: false,
    attachmentPaths: ['attachments/testgame.zip'],
  };

  // Simulates the app's uuid-renaming of stored attachments. Attachments the
  // plugin adds (frame captures, dos-saves zips) carry their base64 payload
  // and persist in localStorage so save/restore survives a page reload.
  const STUB_ATTS_KEY = 'dos-station-stub-attachments';
  const storedAttachments = [
    { id: 'att-1', path: 'attachments/testgame.zip', fileName: 'testgame.zip', mimeType: 'application/zip' },
  ];
  try {
    for (const a of JSON.parse(localStorage.getItem(STUB_ATTS_KEY) || '[]')) {
      storedAttachments.push(a);
    }
  } catch (_) {}
  const syncNoteAttachments = () => {
    fakeNote.attachmentPaths = storedAttachments.map((a) => a.path);
    try {
      localStorage.setItem(STUB_ATTS_KEY,
        JSON.stringify(storedAttachments.filter((a) => a.data)));
    } catch (e) { hlog('stub attachment persist failed: ' + e.message); }
  };
  syncNoteAttachments();

  window.Synapse = {
    Notes: [fakeNote],
    Params: {},

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
          markdown: fakeNote.content,
          attachments: storedAttachments.slice(),
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
            id: 'att-' + storedAttachments.length,
            path: 'attachments/' + unique,
            fileName: a.fileName,
            mimeType: ext === 'zip' ? 'application/zip' : 'image/png',
            // keep the payload so readAttachment can serve it back
            data: raw.includes(',') ? raw.split(',').pop() : raw,
          });
          hlog('  -> stored as attachments/' + unique);
        }
        syncNoteAttachments();
      }
      if (mod && mod.content && mod.content.action === 'append') {
        fakeNote.content += mod.content.text;
        hlog('  -> note content is now:\n' + fakeNote.content.split('\n').slice(-12).join('\n'));
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

  hlog('Synapse stub installed');
})();
