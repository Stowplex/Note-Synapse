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

  /** Keeps a text box this far from the edge of the canvas when revealing it. */
  var REVEAL_MARGIN = 12;

  function available() {
    return typeof jsdraw !== 'undefined' && jsdraw && typeof jsdraw.Editor === 'function';
  }

  function isBackground(component) {
    return !!(component && component.constructor && /Background/.test(component.constructor.name));
  }

  /**
   * A bin, drawn the way js-draw draws its own icons (a stroked path in the
   * toolbar's icon colour). Its own delete icon is a plain ✕, which in a
   * toolbar reads as "close" rather than "clear the drawing".
   */
  function makeClearIcon() {
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 100 100');
    svg.innerHTML =
      '<path d="M22,28 H78 M40,28 V18 H60 V28 M30,28 L34,84 H66 L70,28 M42,42 V70 M58,42 V70" ' +
      'fill="none" stroke="var(--icon-color)" stroke-width="7" ' +
      'stroke-linecap="round" stroke-linejoin="round"/>';
    return svg;
  }

  /**
   * Mounts a drawing surface into `container`.
   *
   * The editor fills whatever height `container` has (its stylesheet's fixed
   * 400px is overridden by the shell), so the canvas grows and shrinks with
   * the page — including when the on-screen keyboard shrinks the WebView.
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

    // Clear goes at the end of the (sideways-scrolling) tool row rather than
    // in a row of its own under the canvas: on a phone every row below the
    // canvas is canvas the user does not get. It is not put beside undo/redo
    // either — those never scroll, and the width would come out of the tools
    // visible without a swipe.
    var clearButton = null;
    try {
      clearButton = toolbar.addActionButton(
        { label: 'Clear', icon: makeClearIcon() },
        clear,
        false
      );
      clearButton.setDisabled(true);
    } catch (e) { /* the button is a convenience; undo and the eraser remain */ }

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
    function changed() {
      dirty = true;
      if (clearButton) {
        try { clearButton.setDisabled(isEmpty()); } catch (e) { /* cosmetic */ }
      }
      if (typeof options.onChange === 'function') options.onChange();
    }
    if (editor.notifier && editor.notifier.on) {
      try {
        editor.notifier.on(jsdraw.EditorEventType.CommandDone, changed);
        editor.notifier.on(jsdraw.EditorEventType.CommandUndone, changed);
      } catch (e) { /* change notification is a nicety, not a requirement */ }
    }

    /*
     Keeping the text box on screen.

     On a phone the on-screen keyboard shrinks the whole WebView, and the
     chrome around the canvas (tab bar, toolbar) keeps its height, so the
     canvas is what gives. A text box started in the lower half of the canvas
     ends up below the visible area with its caret hidden — the user is typing
     into something they cannot see.

     The fix pans the DRAWING, not the page: the text tool anchors its input
     in canvas space, so moving the viewport moves the box into view and the
     committed text still lands where the user tapped. Undo is untouched
     because the pan is dispatched without going through history.
    */
    function revealTextInput() {
      var input = container.querySelector('.textEditorOverlay textarea');
      if (!input || document.activeElement !== input) return false;
      var area = container.querySelector('.imageEditorRenderArea');
      if (!area) return false;

      var box = input.getBoundingClientRect();
      var canvas = area.getBoundingClientRect();
      var frame = container.getBoundingClientRect();
      // The canvas may extend past the container (it is clipped there) and
      // the container past the viewport, so only the overlap counts as visible.
      var viewportBottom = document.documentElement.clientHeight || window.innerHeight;
      var top = Math.max(canvas.top, frame.top, 0) + REVEAL_MARGIN;
      var bottom = Math.min(canvas.bottom, frame.bottom, viewportBottom) - REVEAL_MARGIN;
      if (bottom - top < box.height) {
        // No room for the whole box: at least show where the caret starts.
        bottom = top + Math.max(box.height, 1);
      }

      var dy = 0;
      if (box.bottom > bottom) dy = bottom - box.bottom;   // move content up
      if (box.top + dy < top) dy = top - box.top;          // never hide the top line
      if (Math.abs(dy) < 1) return false;

      try {
        var shift = editor.viewport.screenToCanvasTransform.transformVec3(jsdraw.Vec2.of(0, dy));
        editor.dispatchNoAnnounce(jsdraw.Viewport.transformBy(jsdraw.Mat33.translation(shift)), false);
        return true;
      } catch (e) {
        return false;
      }
    }

    var revealTimer = null;
    function scheduleReveal() {
      if (revealTimer) clearTimeout(revealTimer);
      // The text tool focuses its box on a timeout of its own, and the
      // keyboard resize arrives over several frames; settle first.
      revealTimer = setTimeout(function () {
        revealTimer = null;
        revealTextInput();
      }, 60);
    }
    container.addEventListener('focusin', function (ev) {
      if (ev.target && ev.target.tagName === 'TEXTAREA') scheduleReveal();
    });
    // The keyboard shows up as a window resize; the footer hiding shows up
    // as the container resizing. Listen for both — the check is idempotent.
    window.addEventListener('resize', scheduleReveal);
    if (window.visualViewport) window.visualViewport.addEventListener('resize', scheduleReveal);
    if (typeof ResizeObserver === 'function') {
      new ResizeObserver(scheduleReveal).observe(container);
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
        if (clearButton) {
          try { clearButton.setDisabled(isEmpty()); } catch (e) { /* cosmetic */ }
        }
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
          // The background is not user content.
          if (isBackground(components[i])) continue;
          return false;
        }
        return true;
      } catch (e) {
        return false;
      }
    }

    /** Removes everything drawn, as a single undoable step. */
    function clear() {
      try {
        var components = editor.image.getAllComponents().filter(function (c) {
          return !isBackground(c);
        });
        if (!components.length) return;
        editor.dispatch(new jsdraw.Erase(components));
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
      revealTextInput: revealTextInput,
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
