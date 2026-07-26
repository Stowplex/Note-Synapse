/*
 * Diagram Studio write paths — everything that touches the note.
 *
 * The host gives this app two very different worlds and they are NOT
 * interchangeable:
 *
 *   BLOCK SCOPE (launched on a selected block; Synapse.Notes[0].isBlockScope)
 *     `Synapse.Notes[0]` is a transient note whose content is just the block.
 *     A content write splices back over exactly that block, and the host
 *     promotes any `synapsetemp:///` URI in the text to a permanent attachment
 *     on the PARENT note — and prunes renders it previously promoted that the
 *     note no longer references. So we embed the temp URI directly and let the
 *     host do the work: one call, self-cleaning.
 *     `modification.attachments` is IGNORED for a block-scoped id.
 *
 *   WHOLE NOTE (launched on a note)
 *     Content writes do NOT promote temp URIs — an embedded one would render
 *     until the OS clears its cache and then break for good. So we attach the
 *     bytes explicitly, rediscover the name the host stored them under, embed
 *     that bare filename, and clean up our own superseded attachment. Three
 *     calls, and the pruning is ours to do.
 *
 * Injected rather than imported so the offline tests can drive it with a stub.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramWriteback = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var TEMP_PREFIX = 'synapsetemp://';

  function baseName(path) {
    var s = String(path == null ? '' : path);
    var cut = s.lastIndexOf('/');
    return cut === -1 ? s : s.slice(cut + 1);
  }

  function isTempUri(ref) {
    return String(ref == null ? '' : ref).indexOf(TEMP_PREFIX) === 0;
  }

  function extensionFor(format) {
    if (format === 'png') return '.png';
    if (format === 'jpg' || format === 'jpeg') return '.jpg';
    return '.svg';
  }

  function mimeFor(format) {
    if (format === 'png') return 'image/png';
    if (format === 'jpg' || format === 'jpeg') return 'image/jpeg';
    return 'image/svg+xml';
  }

  /** Strips a `data:...;base64,` prefix if present. */
  function rawBase64(data) {
    var s = String(data == null ? '' : data);
    var comma = s.indexOf(',');
    return s.indexOf('data:') === 0 && comma !== -1 ? s.slice(comma + 1) : s;
  }

  /**
   * Creates a writer bound to one launch.
   *
   * `env` is the injection seam:
   *   synapse   the window.Synapse object (or a stub)
   *   blocks    the DiagramBlocks module
   *   note      Synapse.Notes[0]
   *   now       () => number, so tests get deterministic file names
   */
  function createWriter(env) {
    var S = env.synapse;
    var B = env.blocks;
    var note = env.note;
    var now = env.now || function () { return Date.now(); };

    var isBlock = !!note.isBlockScope;
    // Every attachment operation targets a REAL note id. In block scope the
    // transient id is not a database key, so note-level changes go to the
    // parent (the host ignores `attachments` on a block id outright).
    var attachmentNoteId = isBlock ? note.parentNoteId : note.id;

    // The content this writer believes the note holds: the snapshot it was
    // launched with, advanced to whatever each successful write produced.
    //
    // Tracked here rather than re-read from `note.content` on demand. The
    // staleness check compares the note on disk against THIS, so reading it
    // back out of a live object would make the comparison vacuous — and a
    // vacuous check means stale offsets get spliced into fresh content, which
    // shreds the note.
    var baseContent = String(note.content == null ? '' : note.content);

    // ------------------------------------------------------------------
    // Reading
    // ------------------------------------------------------------------

    /**
     * The note text this studio operates on: the block in block scope, the
     * whole note otherwise.
     *
     * Deliberately NOT `exportNotes().markdown` — that is a rendered
     * ShareService export with section labels and localisation applied, not
     * raw content.
     */
    function initialContent() {
      return baseContent;
    }

    /**
     * Re-reads the note's raw content immediately before a whole-note write,
     * so a note edited elsewhere since the studio opened is not clobbered.
     *
     * Returns null when the content cannot be read. Callers MUST treat that as
     * abort-save: `runQuery` has no chunked-TEXT handling, so a multi-MB note
     * can exceed Android's CursorWindow, and falling back to the stale
     * in-memory snapshot before a whole-content replace would silently revert
     * the user's other edits.
     */
    function readFreshContent() {
      var id = String(attachmentNoteId).replace(/'/g, "''");
      return Promise.resolve(
        S.runQuery("SELECT content FROM notes WHERE id = '" + id + "'")
      ).then(function (res) {
        if (!res || !res.success || !res.data || !res.data.length) return null;
        var row = res.data[0];
        var value = row.content;
        return value == null ? null : String(value);
      }).catch(function () {
        return null;
      });
    }

    /** Every attachment on the real note, with absolute, readable paths. */
    function listAttachments() {
      // exportNotes accepts a block-scoped id and resolves it to the parent,
      // and its `path` is absolute — which is what readAttachment needs.
      // Synapse.Notes[].attachmentPaths are relative and will not open.
      return Promise.resolve(
        S.exportNotes([note.id], { includeSubNotesAndLinkedNotes: false })
      ).then(function (res) {
        if (!res || !res.success || !res.notes || !res.notes.length) return [];
        return res.notes[0].attachments || [];
      });
    }

    /**
     * Resolves a render reference in the note back to the stored file, and
     * reads it. Used by the Draw tab, whose SVG *is* its source.
     *
     * Block-scope renders are content-addressed by the host as
     * `<parentNoteId>_<sha256(tempUri)><ext>`, and the temp URI is left in the
     * content on purpose so the renderer can find it the same way. Whole-note
     * renders are a bare filename we already know.
     */
    function readRender(ref) {
      if (!ref) return Promise.resolve(null);

      return listAttachments().then(function (atts) {
        return matchAttachment(atts, ref).then(function (hit) {
          if (!hit) return null;
          return Promise.resolve(S.readAttachment(hit.path)).then(function (res) {
            if (!res || !res.success) return null;
            // readAttachment always hands back base64. `text` is the decoded
            // form, which is what an SVG consumer (the Draw tab) wants.
            return {
              data: res.data,
              text: fromBase64(res.data),
              mimeType: res.mimeType,
              fileName: hit.fileName,
              path: hit.path,
            };
          });
        });
      });
    }

    function matchAttachment(atts, ref) {
      if (!isTempUri(ref)) {
        var wanted = baseName(ref);
        for (var i = 0; i < atts.length; i++) {
          if (baseName(atts[i].path) === wanted || atts[i].fileName === wanted) {
            return Promise.resolve(atts[i]);
          }
        }
        return Promise.resolve(null);
      }

      return Promise.resolve(S.crypto.digest('sha256', { text: ref })).then(function (res) {
        if (!res || !res.success || !res.hex) return null;
        var prefix = String(attachmentNoteId) + '_' + res.hex;
        for (var i = 0; i < atts.length; i++) {
          if (baseName(atts[i].path).indexOf(prefix) === 0) return atts[i];
        }
        return null;
      });
    }

    // ------------------------------------------------------------------
    // Writing
    // ------------------------------------------------------------------

    /**
     * Stores the rendered image and returns the reference to embed.
     *
     * Block scope returns a `synapsetemp:///` URI (the host promotes and
     * prunes it); whole-note returns the bare filename the host actually
     * stored, which the markdown renderer resolves against private storage.
     */
    function storeRender(image, kind) {
      return Promise.resolve().then(function () { return storeRenderInner(image, kind); });
    }

    function storeRenderInner(image, kind) {
      var format = image.format || 'svg';
      var mime = mimeFor(format);

      // The AI tab hands over an image the host has ALREADY stored: its
      // generation step needs a temp URI anyway, both to preview and to feed
      // back as the next turn's attachment. Re-deriving bytes for it would be
      // pointless, and `image.text`/`image.data` are simply absent.
      var existingUri = image.uri && isTempUri(image.uri) ? image.uri : null;

      if (isBlock) {
        // Already a temp URI: embed it as-is. The block write promotes it and
        // prunes the render it supersedes, exactly as for a fresh one.
        if (existingUri) return Promise.resolve(existingUri);

        var payload = format === 'svg' ? { text: image.text } : { binary: rawBase64(image.data) };
        if (payload.text == null && !payload.binary) {
          throw new Error('There is no rendered image to save.');
        }
        return Promise.resolve(S.saveTemp(payload, mime)).then(function (res) {
          if (!res || !res.success) {
            throw new Error('Could not save the render: ' + ((res && res.error) || 'unknown error'));
          }
          return res.uri;
        });
      }

      // Whole-note: attach the bytes under a name we choose. ALWAYS send the
      // original stem — the host appends a fresh uuid on every save, so
      // echoing back a stored name would grow another uuid each time.
      var stamp;
      var added;
      if (existingUri) {
        // `attachments.added` accepts a temp URI directly; the host promotes
        // it under the temp file's OWN name, so that is the stem to match on
        // afterwards rather than one of our choosing.
        stamp = baseName(existingUri).replace(/\.[A-Za-z0-9]+$/, '');
        added = existingUri;
      } else {
        stamp = 'diagram-' + kind + '-' + now();
        var data = format === 'svg' ? toBase64(image.text) : rawBase64(image.data);
        if (!data) throw new Error('There is no rendered image to save.');
        added = { type: 'base64', data: data, fileName: stamp + extensionFor(format), mimeType: mime };
      }

      return Promise.resolve(
        S.updateNotes([
          {
            id: attachmentNoteId,
            modification: { attachments: { added: [added] } },
          },
        ])
      ).then(function (res) {
        if (!res || !res.success || !res.updatedCount) {
          throw new Error('The attachment was declined: ' + ((res && res.error) || describeErrors(res)));
        }
        return listAttachments();
      }).then(function (atts) {
        // The stored name is `<stem>_<uuid36><ext>`, so match on the stem.
        for (var i = 0; i < atts.length; i++) {
          if (baseName(atts[i].path).indexOf(stamp) === 0) return baseName(atts[i].path);
        }
        throw new Error('The image was attached but could not be located afterwards.');
      });
    }

    function toBase64(text) {
      var s = String(text == null ? '' : text);
      if (typeof btoa === 'function') {
        // btoa is latin1-only; go through UTF-8 first or any non-ASCII label
        // in the SVG corrupts the file.
        return btoa(unescape(encodeURIComponent(s)));
      }
      /* global Buffer */
      return Buffer.from(s, 'utf8').toString('base64');
    }

    function fromBase64(data) {
      var s = rawBase64(data);
      try {
        if (typeof atob === 'function') {
          return decodeURIComponent(escape(atob(s)));
        }
        return Buffer.from(s, 'base64').toString('utf8');
      } catch (e) {
        return null;
      }
    }

    function describeErrors(res) {
      if (res && res.errors && res.errors.length) return res.errors.join(' ');
      return 'the block may have changed since this app was opened - go back, reselect it and try again.';
    }

    /**
     * Renders a unit into the note.
     *
     * `unit` is the scanned unit being replaced, or null to insert a new one.
     * `at` is {unit, where:'before'|'after'} for a new diagram, and is ignored
     * when replacing.
     */
    function saveUnit(opts) {
      var kind = opts.kind;
      var unit = opts.unit || null;
      var position = opts.position === 'below' ? 'below' : 'above';

      return storeRender(opts.image, kind).then(function (ref) {
        var markdown = B.composeUnit({
          kind: kind,
          ref: ref,
          body: opts.body,
          info: opts.info,
          fenced: opts.fenced,
          position: position,
        });
        return isBlock
          ? writeBlock(markdown, unit, opts, ref)
          : writeWholeNote(markdown, unit, opts, ref);
      });
    }

    /**
     * Block scope: the transient note's whole content IS the block, so we
     * rebuild it and replace. The host splices it back over the original span,
     * promotes the temp URI, and drops the render this one supersedes.
     */
    function writeBlock(markdown, unit, opts, ref) {
      var content = initialContent();
      var next;
      if (unit) {
        next = B.replaceUnit(content, unit, markdown);
      } else if (opts.at && opts.at.unit) {
        next = B.insertRelative(content, opts.at.unit, opts.at.where, markdown);
      } else {
        next = B.insertRelative(content, null, 'after', markdown);
      }

      // A content `replace` with empty text is a host-side no-op, so an empty
      // result would silently do nothing rather than clear the block.
      if (next.trim() === '') {
        return Promise.reject(new Error('Refusing to write an empty block.'));
      }

      return Promise.resolve(
        S.updateNotes([{ id: note.id, modification: { content: { action: 'replace', text: next } } }])
      ).then(function (res) {
        if (!res || !res.success) {
          throw new Error('Could not update the note: ' + ((res && res.error) || 'unknown error'));
        }
        // success:true only means the call ran; the host still refuses
        // individual writes whose span it can no longer find.
        if (!res.updatedCount) throw new Error('The note was not updated. ' + describeErrors(res));
        baseContent = next;
        return { content: next, ref: ref };
      });
    }

    /**
     * Whole note: re-read, splice into the full content, replace, and remove
     * the attachment our previous render left behind.
     */
    function writeWholeNote(markdown, unit, opts, ref) {
      return readFreshContent().then(function (fresh) {
        if (fresh === null) {
          // Never fall back to the stale snapshot before a whole-content
          // replace: that would revert edits made since the studio opened.
          throw new Error(
            'Could not re-read the note before saving, so nothing was written. ' +
              'Close and reopen the studio, then try again.'
          );
        }

        var expected = opts.baseContent == null ? initialContent() : opts.baseContent;
        var target = unit;
        var content = fresh;

        if (fresh !== expected) {
          // The note moved under us. Re-scan and re-locate the unit by its
          // source text; if it is gone, refuse rather than guess.
          var rescanned = B.scanBlocks(fresh);
          target = unit ? relocate(rescanned, unit) : null;
          if (unit && !target) {
            throw new Error(
              'The note changed since this diagram was opened and the block could ' +
                'no longer be found, so nothing was written.'
            );
          }
        }

        var next;
        if (target) {
          next = B.replaceUnit(content, target, markdown);
        } else if (opts.at && opts.at.unit) {
          var anchor = relocate(B.scanBlocks(content), opts.at.unit) || opts.at.unit;
          next = B.insertRelative(content, anchor, opts.at.where, markdown);
        } else {
          next = B.insertRelative(content, null, 'after', markdown);
        }

        // Only ever remove an attachment THIS app wrote, identified by the
        // render ref parsed out of the unit we are replacing. A user's own
        // attachment must never be collected.
        var stale = [];
        if (target && target.renderRef && !isTempUri(target.renderRef) && target.renderRef !== ref) {
          stale.push(target.renderRef);
        }

        var modification = { content: { action: 'replace', text: next } };
        if (stale.length) modification.attachments = { removed: stale };

        return Promise.resolve(
          S.updateNotes([{ id: attachmentNoteId, modification: modification }])
        ).then(function (res) {
          if (!res || !res.success) {
            throw new Error('Could not update the note: ' + ((res && res.error) || 'unknown error'));
          }
          if (!res.updatedCount) throw new Error('The note was not updated. ' + describeErrors(res));
          baseContent = next;
          return { content: next, ref: ref };
        });
      });
    }

    /**
     * Finds `unit` again in a freshly scanned note.
     *
     * Matched on source text and kind rather than offsets, because an edit
     * elsewhere in the note shifts every offset but leaves the block itself
     * intact. A unit with no body (a bare render) is matched by its ref.
     */
    function relocate(units, unit) {
      var i;
      if (unit.body) {
        for (i = 0; i < units.length; i++) {
          if (units[i].body === unit.body && units[i].kind === unit.kind) return units[i];
        }
        for (i = 0; i < units.length; i++) {
          if (units[i].body === unit.body) return units[i];
        }
      }
      if (unit.renderRef) {
        for (i = 0; i < units.length; i++) {
          if (units[i].renderRef === unit.renderRef) return units[i];
        }
      }
      return null;
    }

    return {
      isBlockScope: isBlock,
      attachmentNoteId: attachmentNoteId,
      initialContent: initialContent,
      readFreshContent: readFreshContent,
      listAttachments: listAttachments,
      readRender: readRender,
      storeRender: storeRender,
      saveUnit: saveUnit,
      relocate: relocate,
    };
  }

  return {
    createWriter: createWriter,
    baseName: baseName,
    isTempUri: isTempUri,
    extensionFor: extensionFor,
    mimeFor: mimeFor,
    rawBase64: rawBase64,
  };
});
