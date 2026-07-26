/*
 * SVG utilities and offline rasterisation for Diagram Studio.
 *
 * Turning an SVG into PNG/JPG inside a WebView with no network means routing
 * it through `<img src="data:image/svg+xml;base64,...">` onto a canvas. Four
 * things bite, and all four are handled here:
 *
 *   1. `<foreignObject>` does not render when an SVG is loaded through <img>
 *      in WebKit. Mermaid uses it for HTML labels by default, so labels
 *      silently vanish from the PNG. The Mermaid tab re-renders with
 *      htmlLabels:false for raster targets; `hasForeignObject` lets a caller
 *      detect the case it cannot re-render.
 *   2. Mermaid emits `style="max-width:..."` and often no width/height
 *      attribute, so the image has no intrinsic size and the canvas draws
 *      nothing. `ensureSvgSize` pins explicit dimensions from the viewBox.
 *   3. An <img>-loaded SVG cannot use fonts loaded by the page, so families
 *      are pinned to generics inside the SVG itself.
 *   4. JPEG has no alpha: without an opaque backdrop, transparency becomes
 *      black.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramRaster = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var SVG_NS = 'http://www.w3.org/2000/svg';
  var BG_RECT_ID = '__synapse_bg_rect__';

  function parseSvg(svgString) {
    var doc = new DOMParser().parseFromString(svgString, 'image/svg+xml');
    var el = doc.documentElement;
    if (!el || el.nodeName.toLowerCase() !== 'svg') return null;
    // A parse failure yields a <parsererror> document rather than throwing.
    if (doc.getElementsByTagName('parsererror').length) return null;
    return { doc: doc, el: el };
  }

  function serialize(el) {
    return new XMLSerializer().serializeToString(el);
  }

  /** True when the SVG relies on foreignObject, which <img> will not render. */
  function hasForeignObject(svgString) {
    return /<foreignObject[\s>]/i.test(String(svgString || ''));
  }

  /**
   * Gives the SVG an opaque backdrop so a diagram is not rendered black-on-
   * black in a dark note, or invisible white-on-white in a light one.
   */
  function ensureSvgBackground(svgString, color) {
    var parsed = parseSvg(svgString);
    if (!parsed) return svgString;
    var el = parsed.el;

    var rect = el.querySelector('#' + BG_RECT_ID);
    if (!rect) {
      rect = parsed.doc.createElementNS(SVG_NS, 'rect');
      rect.setAttribute('id', BG_RECT_ID);
      rect.setAttribute('x', '0');
      rect.setAttribute('y', '0');
      rect.setAttribute('width', '100%');
      rect.setAttribute('height', '100%');
      if (el.firstChild) el.insertBefore(rect, el.firstChild);
      else el.appendChild(rect);
    }
    rect.setAttribute('fill', color);

    if (!el.getAttribute('preserveAspectRatio')) {
      el.setAttribute('preserveAspectRatio', 'xMidYMid meet');
    }
    return serialize(el);
  }

  /**
   * Reads the SVG's intrinsic size, falling back to the viewBox.
   * Returns null when neither is present.
   */
  function svgSize(svgString) {
    var parsed = parseSvg(svgString);
    if (!parsed) return null;
    return sizeOf(parsed.el);
  }

  function sizeOf(el) {
    var w = parseFloat(el.getAttribute('width'));
    var h = parseFloat(el.getAttribute('height'));
    if (isFinite(w) && isFinite(h) && w > 0 && h > 0) return { width: w, height: h };

    var vb = el.getAttribute('viewBox');
    if (vb) {
      var parts = vb.split(/[\s,]+/).map(parseFloat);
      if (parts.length === 4 && isFinite(parts[2]) && isFinite(parts[3]) && parts[2] > 0 && parts[3] > 0) {
        return { width: parts[2], height: parts[3] };
      }
    }
    return null;
  }

  /**
   * Pins explicit pixel dimensions and drops the `max-width` style Mermaid
   * adds, which is what otherwise leaves the image with no intrinsic size.
   */
  function ensureSvgSize(svgString, fallback) {
    var parsed = parseSvg(svgString);
    if (!parsed) return { svg: svgString, width: 0, height: 0 };
    var el = parsed.el;

    var size = sizeOf(el) || fallback || { width: 800, height: 600 };
    el.setAttribute('width', String(size.width));
    el.setAttribute('height', String(size.height));
    if (!el.getAttribute('viewBox')) {
      el.setAttribute('viewBox', '0 0 ' + size.width + ' ' + size.height);
    }

    var style = el.getAttribute('style') || '';
    if (style) {
      var cleaned = style.replace(/max-width\s*:[^;]*;?/gi, '').trim();
      if (cleaned) el.setAttribute('style', cleaned);
      else el.removeAttribute('style');
    }

    return { svg: serialize(el), width: size.width, height: size.height };
  }

  /** UTF-8 safe base64; btoa alone corrupts any non-ASCII label. */
  function toBase64(text) {
    return btoa(unescape(encodeURIComponent(String(text))));
  }

  function svgDataUri(svgString) {
    return 'data:image/svg+xml;base64,' + toBase64(svgString);
  }

  function mimeFor(format) {
    if (format === 'png') return 'image/png';
    if (format === 'jpg' || format === 'jpeg') return 'image/jpeg';
    return 'image/svg+xml';
  }

  function loadImage(src) {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () { resolve(img); };
      img.onerror = function () {
        reject(new Error('The renderer could not load the diagram as an image.'));
      };
      img.src = src;
    });
  }

  /**
   * Rasterises an SVG string to a PNG or JPEG data URL.
   *
   * Rejects rather than returning a blank image, so the caller can fall back
   * to inserting the SVG and say so. Callers must treat a rejection as
   * "insert the SVG instead", never as a hard failure.
   */
  function rasterize(svgString, opts) {
    var options = opts || {};
    var format = options.format === 'jpg' || options.format === 'jpeg' ? 'jpg' : 'png';
    var scale = options.scale || 2;      // retina by default
    var background = options.background || null;
    var quality = options.quality == null ? 0.92 : options.quality;

    return Promise.resolve().then(function () {
      var sized = ensureSvgSize(svgString, options.fallbackSize);
      if (!sized.width || !sized.height) {
        throw new Error('The diagram has no measurable size.');
      }

      return loadImage(svgDataUri(sized.svg)).then(function (img) {
        var canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(sized.width * scale));
        canvas.height = Math.max(1, Math.round(sized.height * scale));

        var ctx = canvas.getContext('2d');
        if (!ctx) throw new Error('This device did not provide a 2D canvas.');

        // JPEG has no alpha channel; without this, transparency renders black.
        if (format === 'jpg' || background) {
          ctx.fillStyle = background || '#ffffff';
          ctx.fillRect(0, 0, canvas.width, canvas.height);
        }

        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);

        var data;
        try {
          data = canvas.toDataURL(mimeFor(format), quality);
        } catch (e) {
          // A tainted canvas means the SVG pulled in an external resource.
          throw new Error('The diagram referenced an external resource, so it could not be converted.');
        }
        if (!data || data.indexOf('data:') !== 0) {
          throw new Error('The conversion produced no image data.');
        }
        return { format: format, data: data, width: canvas.width, height: canvas.height };
      });
    });
  }

  /**
   * Produces the image payload for a chosen output format.
   *
   * SVG passes straight through as text; PNG/JPG go via the canvas. On a
   * rasterisation failure the caller gets the SVG back with `fellBack` set, so
   * the note still ends up with a working diagram and the UI can explain why.
   */
  function toImage(svgString, format, opts) {
    if (format !== 'png' && format !== 'jpg' && format !== 'jpeg') {
      return Promise.resolve({ format: 'svg', text: svgString });
    }
    return rasterize(svgString, Object.assign({}, opts || {}, { format: format }))
      .then(function (res) {
        return { format: res.format, data: res.data, width: res.width, height: res.height };
      })
      .catch(function (e) {
        return { format: 'svg', text: svgString, fellBack: true, reason: e && e.message ? e.message : String(e) };
      });
  }

  return {
    SVG_NS: SVG_NS,
    BG_RECT_ID: BG_RECT_ID,
    parseSvg: parseSvg,
    serialize: serialize,
    hasForeignObject: hasForeignObject,
    ensureSvgBackground: ensureSvgBackground,
    ensureSvgSize: ensureSvgSize,
    svgSize: svgSize,
    svgDataUri: svgDataUri,
    toBase64: toBase64,
    mimeFor: mimeFor,
    rasterize: rasterize,
    toImage: toImage,
  };
});
