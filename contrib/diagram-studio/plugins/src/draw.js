/*
 * Freeform drawing for Diagram Studio, on top of the vendored js-draw bundle.
 *
 * The Draw tab is the one tab whose exported SVG *is* its source — there is no
 * separate text fence to fall back on. That makes the round trip load-bearing,
 * and it was verified before this was written (dev/spike_jsdraw.html):
 * `loadFromSVG(toSVG())` preserves stroke geometry and converges after the
 * first cycle, so repeated edit/save passes do not drift.
 *
 * One artefact of that spike worth knowing: reloading an exported drawing
 * reports MORE components than were drawn, because the background is
 * materialised as its own component. Component counts are therefore not a
 * meaningful "is this empty?" test — `isEmpty()` compares against a freshly
 * exported blank instead.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramDraw = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function available() {
    return typeof jsdraw !== 'undefined' && jsdraw && typeof jsdraw.Editor === 'function';
  }

  /**
   * Mounts a drawing surface into `container`.
   *
   * opts: {background, onChange}
   */
  function createSurface(container, opts) {
    var options = opts || {};
    if (!available()) {
      throw new Error('The drawing library did not load.');
    }

    var editor = new jsdraw.Editor(container, {
      // Wheel events pan rather than scroll the page, which is what a finger
      // drag maps to inside a WebView.
      wheelEventsEnabled: 'only-if-focused',
    });

    var toolbar = editor.addToolbar();

    if (options.background) {
      try {
        editor.dispatch(
          editor.setBackgroundStyle({
            color: jsdraw.Color4.fromHex(options.background),
            autoresize: true,
          }),
          false
        );
      } catch (e) { /* a themed backdrop is cosmetic */ }
    }

    var dirty = false;
    if (typeof options.onChange === 'function' && editor.notifier && editor.notifier.on) {
      try {
        editor.notifier.on(jsdraw.EditorEventType.CommandDone, function () {
          dirty = true;
          options.onChange();
        });
        editor.notifier.on(jsdraw.EditorEventType.CommandUndone, function () {
          dirty = true;
          options.onChange();
        });
      } catch (e) { /* change notification is a nicety, not a requirement */ }
    }

    /** The drawing as an SVG string — this is what gets stored. */
    function toSvg() {
      var el = editor.toSVG();
      return el && el.outerHTML ? el.outerHTML : '';
    }

    /** Restores a previously exported drawing. */
    function loadSvg(svgText) {
      var text = String(svgText == null ? '' : svgText).trim();
      if (!text) return Promise.resolve(false);
      return Promise.resolve(editor.loadFromSVG(text)).then(function () {
        dirty = false;
        return true;
      });
    }

    /**
     * True when nothing has been drawn. Compared against a blank export
     * rather than a component count, because loading always materialises
     * background components that were never drawn by the user.
     */
    function isEmpty() {
      try {
        var components = editor.image.getAllComponents();
        for (var i = 0; i < components.length; i++) {
          var c = components[i];
          // The background is not user content.
          if (c && c.constructor && /Background/.test(c.constructor.name)) continue;
          return false;
        }
        return true;
      } catch (e) {
        return false;
      }
    }

    function clear() {
      try {
        var components = editor.image.getAllComponents();
        var removals = [];
        for (var i = 0; i < components.length; i++) {
          var c = components[i];
          if (c && c.constructor && /Background/.test(c.constructor.name)) continue;
          removals.push(editor.image.removeComponent(c));
        }
        for (var j = 0; j < removals.length; j++) editor.dispatch(removals[j], j === 0);
        dirty = true;
      } catch (e) { /* nothing to clear */ }
    }

    function destroy() {
      try {
        if (editor && typeof editor.remove === 'function') editor.remove();
        else if (container) container.innerHTML = '';
      } catch (e) {
        if (container) container.innerHTML = '';
      }
    }

    return {
      editor: editor,
      toolbar: toolbar,
      toSvg: toSvg,
      loadSvg: loadSvg,
      isEmpty: isEmpty,
      clear: clear,
      destroy: destroy,
      get dirty() { return dirty; },
      set dirty(v) { dirty = !!v; },
    };
  }

  return {
    available: available,
    createSurface: createSurface,
  };
});
