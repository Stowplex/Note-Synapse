/*
 * Mermaid rendering for Diagram Studio.
 *
 * Two things here are not obvious:
 *
 *   htmlLabels — Mermaid renders node labels as <foreignObject> HTML by
 *   default. That looks fine in the live preview (a real DOM), but an SVG
 *   loaded through <img> for canvas rasterisation does NOT render
 *   foreignObject in WebKit, so every label silently disappears from the PNG.
 *   Rendering for a raster target therefore re-runs with htmlLabels:false so
 *   labels become plain <text>.
 *
 *   cleanup — mermaid.render leaves its scratch element in the document when a
 *   parse fails. Left alone they accumulate on every keystroke of the live
 *   preview, so they are swept explicitly.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramMermaid = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var ID_PREFIX = 'diagram-studio-mermaid-';
  var seq = 0;
  var currentHtmlLabels = null;

  function available() {
    return typeof mermaid !== 'undefined' && mermaid && typeof mermaid.render === 'function';
  }

  function baseConfig(htmlLabels, background) {
    return {
      startOnLoad: false,
      securityLevel: 'strict',
      theme: 'dark',
      // Pinned to a generic stack: an <img>-loaded SVG cannot use fonts the
      // page has loaded, so anything else silently falls back at raster time.
      fontFamily: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
      themeVariables: {
        background: background,
        primaryColor: '#3f51b5',
        primaryTextColor: '#ffffff',
        primaryBorderColor: '#7986cb',
        lineColor: '#9ea7b3',
        secondaryColor: '#455a64',
        tertiaryColor: '#37474f',
        mainBkg: background,
      },
      flowchart: { htmlLabels: htmlLabels, useMaxWidth: false },
      class: { htmlLabels: htmlLabels, useMaxWidth: false },
      state: { htmlLabels: htmlLabels, useMaxWidth: false },
      sequence: { useMaxWidth: false },
      gantt: { useMaxWidth: false },
      er: { useMaxWidth: false },
      journey: { useMaxWidth: false },
      pie: { useMaxWidth: false },
    };
  }

  function configure(htmlLabels, background) {
    if (!available() || typeof mermaid.initialize !== 'function') return false;
    if (currentHtmlLabels === htmlLabels) return true;
    try {
      mermaid.initialize(baseConfig(htmlLabels, background));
      currentHtmlLabels = htmlLabels;
      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * Removes scratch nodes mermaid leaves behind when a parse throws.
   *
   * Scoped to direct children of <body>, which is where mermaid parks its
   * scratch container. It must NOT match by id alone: mermaid gives the
   * successful output SVG the same render id, so an unscoped sweep deletes
   * the preview the caller just inserted.
   */
  function sweep() {
    try {
      var children = document.body ? document.body.children : [];
      for (var i = children.length - 1; i >= 0; i--) {
        var el = children[i];
        var id = el.id || '';
        if (id.indexOf(ID_PREFIX) === 0 || id.indexOf('d' + ID_PREFIX) === 0) {
          document.body.removeChild(el);
        }
      }
    } catch (e) { /* sweeping is best-effort */ }
  }

  /**
   * Renders Mermaid source to an SVG string.
   *
   * opts: {htmlLabels, background}. Pass htmlLabels:false whenever the result
   * will be rasterised.
   *
   * Rejects with the parser's message so the UI can show it (and offer to send
   * it to the AI for a fix).
   */
  function render(code, opts) {
    var options = opts || {};
    var htmlLabels = options.htmlLabels !== false;
    var background = options.background || '#282c34';

    return Promise.resolve().then(function () {
      if (!available()) {
        throw new Error('The Mermaid library did not load (synapse://mermaid.min.js).');
      }
      var source = String(code == null ? '' : code).trim();
      if (!source) throw new Error('There is no diagram source to render.');

      configure(htmlLabels, background);
      var id = ID_PREFIX + (++seq);

      return Promise.resolve(mermaid.render(id, source)).then(function (result) {
        // mermaid has returned both a bare string and {svg} across versions.
        var svg = typeof result === 'string' ? result : (result && result.svg);
        if (!svg || !svg.trim()) throw new Error('Mermaid produced an empty diagram.');
        sweep();
        return svg;
      }, function (e) {
        sweep();
        throw new Error(cleanParseError(e));
      });
    });
  }

  /** Mermaid's errors are verbose and often repeat the whole source back. */
  function cleanParseError(e) {
    var msg = (e && e.message ? e.message : String(e)) || 'Mermaid could not parse this diagram.';
    return msg.replace(/\s+/g, ' ').trim().slice(0, 400);
  }

  /**
   * Validates without keeping the output — used by the live preview to report
   * a syntax error without disturbing the last good render.
   */
  function validate(code) {
    return render(code).then(function () { return null; }, function (e) { return e.message; });
  }

  return {
    ID_PREFIX: ID_PREFIX,
    available: available,
    configure: configure,
    render: render,
    validate: validate,
    sweep: sweep,
    cleanParseError: cleanParseError,
  };
});
