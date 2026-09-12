/*
 * A fake `window.Synapse` for Diagram Studio's offline tests and browser
 * harness.
 *
 * It models the host behaviours the plugin actually depends on, including the
 * ones that are easy to get wrong and impossible to see without a device:
 *
 *   - block scope: a content write on a transient block id splices back over
 *     the block's span in the parent note, promotes every `synapsetemp:///`
 *     URI in the text to `attachments/<parentId>_<sha256(uri)><ext>`, and
 *     prunes renders it previously promoted that the text no longer mentions
 *   - whole note: content writes promote NOTHING, and every saved attachment
 *     is renamed `<stem>_<uuid36><ext>`
 *   - `exportNotes` resolves a block id to its parent and returns ABSOLUTE
 *     attachment paths; `Notes[].attachmentPaths` stay relative and unreadable
 *   - `updateNotes` can return `success:true` with `updatedCount:0`
 *
 * Usage:
 *   const stub = createSynapseStub({ mode: 'block', content, sha256 });
 *   stub.synapse   // the window.Synapse lookalike
 *   stub.note      // what Synapse.Notes[0] would be
 *   stub.parent    // the fake parent note, for assertions
 */
(function (root, factory) {
  var mod = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = mod;
  }
  if (root) {
    root.SynapseStub = mod;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var ATTACH_DIR = '/private/attachments/';

  function baseName(p) {
    var cut = String(p).lastIndexOf('/');
    return cut === -1 ? String(p) : String(p).slice(cut + 1);
  }

  function extOf(name) {
    var m = /\.[A-Za-z0-9]+$/.exec(String(name));
    return m ? m[0] : '';
  }

  /**
   * @param opts.mode      'block' | 'note'
   * @param opts.content   note content ('note' mode) or block text ('block')
   * @param opts.parentContent  full parent content when mode==='block'
   * @param opts.sha256    (text) => hex, required; injected so this works in
   *                       both node and the browser
   */
  function createSynapseStub(opts) {
    var options = opts || {};
    var mode = options.mode === 'block' ? 'block' : 'note';
    var sha256 = options.sha256;
    if (typeof sha256 !== 'function') throw new Error('createSynapseStub needs a sha256(text) function');

    var seq = 0;
    var uuidSeq = 0;
    var temps = {};        // uri -> {bytes, mime}
    var files = {};        // absolute path -> string contents (base64 for binary)
    var log = [];          // every call, for assertions

    var parentId = 'parent-note-1';
    var parentContent = mode === 'block'
      ? String(options.parentContent == null ? options.content : options.parentContent)
      : String(options.content == null ? '' : options.content);

    var attachments = [];  // {id, filePath (relative), fileName}
    // Renders this stub promoted, mirroring BlockNoteScopeService's
    // _promotedByParent: only these may be pruned.
    var promoted = {};

    var blockSpan = null;
    if (mode === 'block') {
      var blockText = String(options.content == null ? '' : options.content);
      var at = parentContent.indexOf(blockText);
      if (at === -1) throw new Error('stub: block content not found inside parentContent');
      blockSpan = { start: at, end: at + blockText.length, text: blockText };
    }

    var note = mode === 'block'
      ? {
          id: 'block-scope-temp-id',
          parentNoteId: parentId,
          isBlockScope: true,
          title: 'Fake Note',
          content: blockSpan.text,
          // Relative on purpose: readAttachment cannot open these.
          attachmentPaths: attachments.map(function (a) { return a.filePath; }),
        }
      : {
          id: parentId,
          isBlockScope: false,
          title: 'Fake Note',
          content: parentContent,
          attachmentPaths: attachments.map(function (a) { return a.filePath; }),
        };

    function realNoteId(id) {
      return id === 'block-scope-temp-id' ? parentId : id;
    }

    // Everything on disk is stored base64, because that is the only form
    // `readAttachment` ever hands back — text and binary alike.
    function tempBase64(uri) {
      var t = temps[uri];
      if (!t) return null;
      if (!t.isText) {
        var raw = String(t.raw);
        var comma = raw.indexOf(',');
        return raw.indexOf('data:') === 0 && comma !== -1 ? raw.slice(comma + 1) : raw;
      }
      if (typeof btoa === 'function') return btoa(unescape(encodeURIComponent(t.raw)));
      /* global Buffer */
      return Buffer.from(String(t.raw), 'utf8').toString('base64');
    }

    function addAttachment(fileName, contents) {
      // The host renames every saved file (generateUniqueFileName).
      var stem = fileName.replace(/\.[A-Za-z0-9]+$/, '');
      var unique = stem + '_' + ('uuid' + (++uuidSeq)) + extOf(fileName);
      var rel = 'attachments/' + unique;
      files[ATTACH_DIR + unique] = contents;
      attachments.push({ id: 'att-' + attachments.length, filePath: rel, fileName: unique });
      return rel;
    }

    /** Mirrors ConversationAttachmentService.processContentForAttachments. */
    function promoteTempUris(text) {
      var added = [];
      var re = /synapsetemp:\/\/[^\s)\]]+/g;
      var m;
      while ((m = re.exec(text)) !== null) {
        var uri = m[0];
        var temp = temps[uri];
        if (!temp) continue;
        var hash = sha256(uri);
        // Content-addressed and deterministic: same URI, same file, no rename.
        var name = parentId + '_' + hash + extOf(uri);
        var rel = 'attachments/' + name;
        if (!files[ATTACH_DIR + name]) {
          files[ATTACH_DIR + name] = tempBase64(uri);
          attachments.push({ id: 'att-' + attachments.length, filePath: rel, fileName: name });
        }
        promoted[rel] = true;
        added.push(rel);
      }
      return added;
    }

    /** Mirrors the prune in BlockNoteScopeService._writeBackLocked. */
    function prunePromoted(fullContent) {
      var referenced = {};
      var re = /synapsetemp:\/\/[^\s)\]]+/g;
      var m;
      while ((m = re.exec(fullContent)) !== null) {
        referenced[parentId + '_' + sha256(m[0])] = true;
      }
      attachments = attachments.filter(function (a) {
        if (!promoted[a.filePath]) return true;
        if (fullContent.indexOf(a.filePath) !== -1 || fullContent.indexOf(a.fileName) !== -1) return true;
        var stem = a.fileName.replace(/\.[A-Za-z0-9]+$/, '');
        return !!referenced[stem];
      });
    }

    function syncNoteView() {
      note.attachmentPaths = attachments.map(function (a) { return a.filePath; });
      if (mode === 'block') note.content = blockSpan.text;
      else note.content = parentContent;
    }

    var synapse = {
      locale: options.locale || 'en-US',
      Notes: [note],
      Params: {},

      saveTemp: function (data, mimeType) {
        var ext = mimeType === 'image/png' ? '.png'
          : mimeType === 'image/jpeg' ? '.jpg'
          : '.svg';
        var uri = 'synapsetemp:///syn_' + (++seq) + ext;
        var isText = data.text != null;
        temps[uri] = {
          raw: isText ? data.text : data.binary,
          isText: isText,
          mime: mimeType,
        };
        log.push({ call: 'saveTemp', uri: uri, mimeType: mimeType });
        return Promise.resolve({ success: true, uri: uri });
      },

      crypto: {
        digest: function (algorithm, data) {
          if (algorithm !== 'sha256') return Promise.resolve({ success: false, error: 'unsupported' });
          return Promise.resolve({ success: true, hex: sha256(String(data.text)) });
        },
      },

      runQuery: function (sql) {
        log.push({ call: 'runQuery', sql: sql });
        if (options.failRunQuery) return Promise.resolve({ success: false, error: 'CursorWindow overflow' });
        if (/SELECT\s+content\s+FROM\s+notes/i.test(sql)) {
          return Promise.resolve({ success: true, data: [{ content: parentContent }] });
        }
        return Promise.resolve({ success: true, data: [] });
      },

      exportNotes: function (ids) {
        var id = realNoteId(ids[0]);
        log.push({ call: 'exportNotes', id: id });
        if (id !== parentId) return Promise.resolve({ success: true, notes: [] });
        return Promise.resolve({
          success: true,
          notes: [
            {
              id: parentId,
              title: note.title,
              // Rendered export, NOT raw content — the plugin must not use it.
              markdown: '## Fake Note\n\n' + parentContent,
              attachments: attachments.map(function (a) {
                return {
                  id: a.id,
                  path: ATTACH_DIR + a.fileName, // absolute
                  fileName: a.fileName,
                  mimeType: extOf(a.fileName).slice(1),
                };
              }),
            },
          ],
        });
      },

      readAttachment: function (path) {
        log.push({ call: 'readAttachment', path: path });
        // Only absolute paths open, exactly like the host.
        if (String(path).indexOf('/') !== 0) {
          return Promise.resolve({ success: false, error: 'file not found in database' });
        }
        if (!Object.prototype.hasOwnProperty.call(files, path)) {
          return Promise.resolve({ success: false, error: 'file not found' });
        }
        return Promise.resolve({ success: true, data: files[path], mimeType: 'image/svg+xml' });
      },

      updateNotes: function (list) {
        var entry = list[0];
        var mod = entry.modification || {};
        log.push({ call: 'updateNotes', id: entry.id, modification: mod });

        if (options.declineWrites) {
          return Promise.resolve({ success: true, updatedCount: 0, errors: ['declined by stub'] });
        }

        var isBlockWrite = entry.id === 'block-scope-temp-id';

        if (isBlockWrite) {
          // The host ignores attachments on a block id.
          if (!mod.content) return Promise.resolve({ success: true, updatedCount: 0, errors: ['block writes only change content'] });
          var text = String(mod.content.text == null ? '' : mod.content.text);
          if (mod.content.action === 'replace' && text.trim() === '') {
            return Promise.resolve({ success: true, updatedCount: 0, errors: ['empty replace is a no-op'] });
          }
          promoteTempUris(text);
          parentContent = parentContent.slice(0, blockSpan.start) + text + parentContent.slice(blockSpan.end);
          blockSpan = { start: blockSpan.start, end: blockSpan.start + text.length, text: text };
          prunePromoted(parentContent);
          syncNoteView();
          return Promise.resolve({ success: true, updatedCount: 1 });
        }

        // Whole-note path.
        if (mod.attachments && mod.attachments.added) {
          for (var i = 0; i < mod.attachments.added.length; i++) {
            var add = mod.attachments.added[i];
            if (typeof add === 'string') {
              if (temps[add]) addAttachment(baseName(add), tempBase64(add));
            } else if (add && add.type === 'base64') {
              addAttachment(add.fileName, add.data);
            }
          }
        }
        if (mod.attachments && mod.attachments.removed) {
          for (var r = 0; r < mod.attachments.removed.length; r++) {
            var wanted = baseName(mod.attachments.removed[r]);
            attachments = attachments.filter(function (a) {
              return a.fileName !== wanted && baseName(a.filePath) !== wanted;
            });
          }
        }
        if (mod.content) {
          var body = String(mod.content.text == null ? '' : mod.content.text);
          if (mod.content.action === 'replace' && body.trim() === '') {
            return Promise.resolve({ success: true, updatedCount: 0, errors: ['empty replace is a no-op'] });
          }
          // Crucially: NO temp-uri promotion here.
          if (mod.content.action === 'replace') parentContent = body;
          else if (mod.content.action === 'append') parentContent = parentContent + '\n' + body;
          else if (mod.content.action === 'prepend') parentContent = body + '\n' + parentContent;
        }
        syncNoteView();
        return Promise.resolve({ success: true, updatedCount: 1 });
      },

      chatAI: function (prompt, opts2) {
        log.push({ call: 'chatAI', prompt: prompt, options: opts2 });
        var reply = options.chatAIResponse;
        if (typeof reply === 'function') return Promise.resolve(reply(prompt, opts2));
        return Promise.resolve(reply || { success: true, response: [{ type: 'text', content: 'ok' }] });
      },

      storeAppState: function (state) {
        options.appState = state;
        log.push({ call: 'storeAppState' });
        return Promise.resolve({ success: true });
      },
      loadAppState: function () {
        return Promise.resolve({ success: true, data: options.appState || null });
      },
    };

    return {
      synapse: synapse,
      setLocale: function (tag) {
        synapse.locale = tag;
        if (typeof window !== 'undefined' && typeof window.dispatchEvent === 'function') {
          window.dispatchEvent(new CustomEvent('synapse:localechanged', { detail: tag }));
        }
      },
      note: note,
      log: log,
      get parentContent() { return parentContent; },
      get attachments() { return attachments.slice(); },
      get files() { return files; },
      get temps() { return temps; },
    };
  }

  return { createSynapseStub: createSynapseStub, ATTACH_DIR: ATTACH_DIR };
});
