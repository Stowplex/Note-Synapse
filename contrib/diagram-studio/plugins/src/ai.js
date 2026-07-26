/*
 * Diagram Studio's AI tab: image generation with iterative refinement.
 *
 * `Synapse.chatAI` is stateless — one prompt in, one response out, no history.
 * So the conversation lives here: every turn is kept, the previous image is
 * fed back as an attachment so the model can see what it is revising, and the
 * accumulated instructions are folded into the prompt text as well.
 *
 * That belt-and-braces design is deliberate. If the backend honours the input
 * image, refinement is a true edit ("make the arrows thicker" changes only the
 * arrows). If it does NOT, the flattened instruction history still makes the
 * next generation cumulative rather than a fresh unrelated picture. The tab
 * reports which behaviour it is getting via `lastTurnUsedPriorImage` so the UI
 * can be honest about it instead of implying an edit that did not happen.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramAi = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var MAX_THREADS = 20;      // storeAppState is one blob for the whole app
  var MAX_TURNS = 12;        // keep a prompt from growing without bound

  var STYLE_PREAMBLE =
    'Produce a clear, legible diagram illustration. Prefer high contrast, ' +
    'readable labels and generous spacing. Do not add a border or caption.';

  function emptyThread(prompt) {
    return { prompt: String(prompt || ''), turns: [], lastImageUri: null };
  }

  /**
   * Flattens a thread into a single prompt string.
   *
   * The first turn is the brief. Later turns restate the brief, list the
   * refinements already applied, and then give the new one — so the request is
   * self-contained even if the attached image is ignored.
   */
  function buildPrompt(thread, instruction) {
    var brief = String((thread && thread.prompt) || '').trim();
    var next = String(instruction || '').trim();
    var turns = (thread && thread.turns) || [];

    if (!turns.length) {
      var first = next || brief;
      return STYLE_PREAMBLE + '\n\n' + first;
    }

    var lines = [STYLE_PREAMBLE, ''];
    lines.push('You are revising a diagram you generated earlier.');
    if (brief) lines.push('The original brief was: ' + brief);

    var applied = [];
    for (var i = 0; i < turns.length; i++) {
      var t = String(turns[i].instruction || '').trim();
      if (t && t !== brief) applied.push(t);
    }
    if (applied.length) {
      lines.push('');
      lines.push('Revisions already applied, in order:');
      for (var j = 0; j < applied.length; j++) {
        lines.push('  ' + (j + 1) + '. ' + applied[j]);
      }
    }

    lines.push('');
    lines.push(
      'The previous version is attached. Keep everything else about it the ' +
        'same and apply only this change: ' + next
    );
    return lines.join('\n');
  }

  /** Pulls the first image and any text out of a multi_part chatAI response. */
  function extractParts(response) {
    var out = { image: null, text: '' };
    if (!response) return out;

    if (typeof response === 'string') {
      // String mode embeds the image as ![...](synapsetemp:///...).
      var m = /!\[[^\]]*\]\((synapsetemp:\/\/[^)]+)\)/.exec(response);
      if (m) out.image = { kind: 'uri', value: m[1] };
      out.text = response.replace(/!\[[^\]]*\]\([^)]*\)/g, '').trim();
      return out;
    }

    if (Object.prototype.toString.call(response) === '[object Array]') {
      var texts = [];
      for (var i = 0; i < response.length; i++) {
        var part = response[i];
        if (!part) continue;
        if (part.type === 'image' && !out.image) {
          out.image = { kind: 'dataUri', value: String(part.content || '') };
        } else if (part.type === 'text' && part.content) {
          texts.push(String(part.content));
        }
      }
      out.text = texts.join('\n').trim();
    }
    return out;
  }

  function mimeOfDataUri(dataUri) {
    var m = /^data:([^;,]+)[;,]/.exec(String(dataUri || ''));
    return m ? m[1] : 'image/png';
  }

  function base64OfDataUri(dataUri) {
    var s = String(dataUri || '');
    var comma = s.indexOf(',');
    return comma === -1 ? s : s.slice(comma + 1);
  }

  /**
   * Creates an AI session bound to one launch.
   *
   * env: {synapse, now}
   */
  function createSession(env) {
    var S = env.synapse;
    var now = env.now || function () { return Date.now(); };

    var threads = {};                 // key -> thread
    var order = [];                   // LRU, most recent last
    var lastTurnUsedPriorImage = false;

    function touch(key) {
      var at = order.indexOf(key);
      if (at !== -1) order.splice(at, 1);
      order.push(key);
      while (order.length > MAX_THREADS) {
        delete threads[order.shift()];
      }
    }

    function threadFor(key, prompt) {
      if (!threads[key]) threads[key] = emptyThread(prompt);
      else if (prompt && !threads[key].prompt) threads[key].prompt = String(prompt);
      touch(key);
      return threads[key];
    }

    /** Restores saved threads, tolerating anything malformed. */
    function load() {
      return Promise.resolve(S.loadAppState()).then(function (res) {
        var data = res && res.success ? res.data : null;
        var saved = data && data.aiThreads;
        if (!saved || typeof saved !== 'object') return;
        var keys = Object.keys(saved);
        for (var i = 0; i < keys.length; i++) {
          var t = saved[keys[i]];
          if (!t || typeof t !== 'object') continue;
          threads[keys[i]] = {
            prompt: String(t.prompt || ''),
            turns: Object.prototype.toString.call(t.turns) === '[object Array]' ? t.turns.slice(-MAX_TURNS) : [],
            lastImageUri: t.lastImageUri || null,
          };
          order.push(keys[i]);
        }
        while (order.length > MAX_THREADS) delete threads[order.shift()];
      }).catch(function () { /* a corrupt blob must not block the tab */ });
    }

    /**
     * Persists threads, merging into whatever else the app has stored.
     * storeAppState is a full overwrite of a single blob, so the existing
     * state has to be read back and merged rather than replaced.
     */
    function save() {
      return Promise.resolve(S.loadAppState()).then(function (res) {
        var state = (res && res.success && res.data) || {};
        state.aiThreads = threads;
        return S.storeAppState(state);
      }).catch(function () { /* persistence is best-effort */ });
    }

    function getThread(key) {
      return threads[key] || null;
    }

    /**
     * Runs one generation turn.
     *
     * Returns {imageUri, dataUri, text, usedPriorImage}. `imageUri` is a
     * synapsetemp URI suitable for both re-attaching on the next turn and
     * writing into the note.
     */
    function generate(key, instruction, opts) {
      var options = opts || {};
      var thread = threadFor(key, options.prompt);
      var text = String(instruction || '').trim();
      if (!text && !thread.prompt) {
        return Promise.reject(new Error('Describe the diagram you want first.'));
      }
      if (!thread.turns.length && !thread.prompt) thread.prompt = text;

      var prompt = buildPrompt(thread, text);
      var attachments = [];
      var usedPriorImage = false;
      if (thread.lastImageUri) {
        attachments.push(thread.lastImageUri);
        usedPriorImage = true;
      }

      var chatOptions = {
        model_hint: ['image_gen'],
        response_type: 'multi_part',
      };
      if (attachments.length) chatOptions.attachments = attachments;

      return Promise.resolve(S.chatAI(prompt, chatOptions)).then(function (res) {
        if (!res || !res.success) {
          throw new Error('The AI request failed: ' + ((res && res.error) || 'unknown error'));
        }
        var parts = extractParts(res.response);
        if (!parts.image) {
          throw new Error(
            'The model replied without an image' + (parts.text ? ': ' + parts.text : '.')
          );
        }

        // Normalise to a synapsetemp URI: it is what the note write and the
        // next turn's attachment both need.
        if (parts.image.kind === 'uri') {
          return { uri: parts.image.value, dataUri: null, text: parts.text };
        }
        var dataUri = parts.image.value;
        return Promise.resolve(
          S.saveTemp({ binary: base64OfDataUri(dataUri) }, mimeOfDataUri(dataUri))
        ).then(function (saved) {
          if (!saved || !saved.success) {
            throw new Error('The image could not be stored: ' + ((saved && saved.error) || 'unknown error'));
          }
          return { uri: saved.uri, dataUri: dataUri, text: parts.text };
        });
      }).then(function (result) {
        thread.turns.push({ instruction: text, imageUri: result.uri, at: now() });
        if (thread.turns.length > MAX_TURNS) thread.turns = thread.turns.slice(-MAX_TURNS);
        thread.lastImageUri = result.uri;
        lastTurnUsedPriorImage = usedPriorImage;
        touch(key);
        save();
        return {
          imageUri: result.uri,
          dataUri: result.dataUri,
          text: result.text,
          usedPriorImage: usedPriorImage,
          turn: thread.turns.length,
        };
      });
    }

    /** Drops a thread's history so the next turn starts clean. */
    function reset(key, prompt) {
      threads[key] = emptyThread(prompt);
      touch(key);
      save();
      return threads[key];
    }

    return {
      load: load,
      save: save,
      getThread: getThread,
      threadFor: threadFor,
      generate: generate,
      reset: reset,
      get lastTurnUsedPriorImage() { return lastTurnUsedPriorImage; },
      get threadCount() { return order.length; },
    };
  }

  return {
    MAX_THREADS: MAX_THREADS,
    MAX_TURNS: MAX_TURNS,
    STYLE_PREAMBLE: STYLE_PREAMBLE,
    emptyThread: emptyThread,
    buildPrompt: buildPrompt,
    extractParts: extractParts,
    mimeOfDataUri: mimeOfDataUri,
    base64OfDataUri: base64OfDataUri,
    createSession: createSession,
  };
});
