import 'dart:convert';

import '../../models/protocol_study.dart';

/// Builds the document-start page-world probe used by Protocol Study.
///
/// The probe is deliberately one-way and non-blocking: it calls the site's
/// original fetch/XHR implementation immediately and delivers bounded copies
/// of observations to Flutter in the background. It does not use the plugin's
/// synchronous fetch/AJAX interception hooks, which can change page timing.
class ProtocolCaptureUserScript {
  const ProtocolCaptureUserScript._();

  static String build({
    required String handlerName,
    required ProtocolCaptureLimits limits,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_]{8,80}$').hasMatch(handlerName)) {
      throw ArgumentError.value(handlerName, 'handlerName', 'unsafe name');
    }
    final probe = _template
        .replaceAll('__HANDLER__', jsonEncode(handlerName))
        .replaceAll('__MAX_REQUEST__', '${limits.maxRequestBodyBytes}')
        .replaceAll('__MAX_RESPONSE__', '${limits.maxResponseBodyBytes}')
        .replaceAll('__MAX_EVENTS__', '${limits.maxEvents}')
        .replaceAll('__CAPTURE_BINARY__', '${limits.captureBinary}');
    // Android WebView's document-start API does not reliably execute user
    // scripts in subframes. A top-frame companion retries same-origin frames
    // after their load event. This cannot recover early iframe traffic, so the
    // probe emits a diagnostic and the UI must describe that traffic as
    // partial. It deliberately never relays cross-origin frame data through
    // the top page, which would weaken the browser's origin boundary.
    final frameCompanion = _sameOriginFrameCompanion.replaceAll(
      '__FRAME_PROBE_SOURCE__',
      jsonEncode(probe),
    );
    return '$probe\n$frameCompanion';
  }

  static const String _sameOriginFrameCompanion = r'''
(() => {
  'use strict';
  if (window.top !== window || window.__noteSynapseFrameFallbackV1) return;
  Object.defineProperty(window, '__noteSynapseFrameFallbackV1', {
    value: true, configurable: false, enumerable: false, writable: false
  });
  const frameProbeSource = __FRAME_PROBE_SOURCE__;
  const install = (frame) => {
    try {
      const child = frame && frame.contentWindow;
      if (!child || child.location.origin !== location.origin) return;
      if (child.__noteSynapseProtocolProbeV1) return;
      child.eval(frameProbeSource);
      // The child probe has its own bridge/outbox. This event only makes the
      // late Android fallback visible; it contains no captured page values.
      const report = window.__noteSynapseProtocolDiagnosticV1;
      if (typeof report === 'function') {
        report('same_origin_frame_late_injection');
      }
    } catch (_) {
      // Cross-origin and CSP-blocked frames are intentionally left alone.
    }
  };
  document.addEventListener('load', (event) => {
    const target = event.target;
    if (target && String(target.tagName || '').toLowerCase() === 'iframe') {
      install(target);
    }
  }, true);
  for (const frame of document.querySelectorAll('iframe')) install(frame);
})();
''';

  static const String _template = r'''
(() => {
  'use strict';
  if (window.__noteSynapseProtocolProbeV1) return;
  Object.defineProperty(window, '__noteSynapseProtocolProbeV1', {
    value: true, configurable: false, enumerable: false, writable: false
  });

  const HANDLER = __HANDLER__;
  const MAX_REQUEST = __MAX_REQUEST__;
  const MAX_RESPONSE = __MAX_RESPONSE__;
  const MAX_EVENTS = __MAX_EVENTS__;
  const CAPTURE_BINARY = __CAPTURE_BINARY__;
  const pageInstanceId = (globalThis.crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
  let sequence = 0;
  let emitted = 0;
  let flushing = false;
  const outbox = [];
  const originalFetch = typeof window.fetch === 'function'
    ? window.fetch
    : null;
  const OriginalXHR = window.XMLHttpRequest;
  let wrappedFetch = null;
  let wrappedXHROpen = null;
  let wrappedXHRSend = null;

  const utf8Length = (value) => {
    try { return new TextEncoder().encode(String(value)).length; }
    catch (_) { return String(value).length; }
  };

  const capText = (value, maxBytes) => {
    if (value === undefined || value === null) {
      return {text: null, byteLength: 0, truncated: false};
    }
    const text = String(value);
    const byteLength = utf8Length(text);
    if (byteLength <= maxBytes) {
      return {text, byteLength, truncated: false};
    }
    // UTF-16 slicing can slightly undershoot or overshoot a UTF-8 boundary;
    // Flutter performs the authoritative byte cap again.
    const ratio = Math.max(0, Math.min(1, maxBytes / byteLength));
    return {
      text: text.slice(0, Math.floor(text.length * ratio)),
      byteLength,
      truncated: true
    };
  };

  const readStreamText = async (stream, maxBytes) => {
    if (!stream || typeof stream.getReader !== 'function') {
      return {text: null, byteLength: null, truncated: false,
        omittedReason: 'bounded_stream_unavailable'};
    }
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let text = '';
    let capturedBytes = 0;
    let observedBytes = 0;
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        const value = next.value;
        const length = Number(value && value.byteLength || 0);
        observedBytes += length;
        const remaining = Math.max(0, maxBytes - capturedBytes);
        if (length > remaining) {
          if (remaining > 0) {
            text += decoder.decode(value.subarray(0, remaining), {stream: true});
            capturedBytes += remaining;
          }
          text += decoder.decode();
          try {
            const cancellation = reader.cancel('protocol capture body limit');
            if (cancellation && typeof cancellation.catch === 'function') cancellation.catch(() => {});
          } catch (_) {}
          return {text, byteLength: observedBytes, truncated: true};
        }
        capturedBytes += length;
        text += decoder.decode(value, {stream: true});
      }
      text += decoder.decode();
      return {text, byteLength: observedBytes, truncated: false};
    } catch (error) {
      try {
        const cancellation = reader.cancel('protocol capture read failed');
        if (cancellation && typeof cancellation.catch === 'function') cancellation.catch(() => {});
      } catch (_) {}
      return {text: null, byteLength: observedBytes || null, truncated: false,
        omittedReason: `unreadable:${error && error.name || 'error'}`};
    }
  };

  const headerPairs = (headers) => {
    const result = [];
    try {
      new Headers(headers || undefined).forEach((value, name) => {
        result.push([String(name), String(value)]);
      });
    } catch (_) {}
    return result;
  };

  const selectorHint = (node) => {
    if (!node || node.nodeType !== 1) return null;
    const tag = String(node.tagName || '').toLowerCase();
    const id = node.id ? `#${String(node.id).slice(0, 100)}` : '';
    const name = node.getAttribute && node.getAttribute('name');
    const named = name ? `[name="${String(name).slice(0, 100)}"]` : '';
    return `${tag}${id}${named}`.slice(0, 240);
  };

  const flush = () => {
    if (flushing || outbox.length === 0) return;
    const bridge = window.flutter_inappwebview;
    if (!bridge || typeof bridge.callHandler !== 'function') {
      setTimeout(flush, 50);
      return;
    }
    flushing = true;
    try {
      while (outbox.length > 0) {
        const event = outbox.shift();
        try {
          const delivery = bridge.callHandler(HANDLER, event);
          if (delivery && typeof delivery.catch === 'function') {
            delivery.catch(() => {});
          }
        } catch (_) { /* A navigation may destroy this page; never block it. */ }
      }
    } finally {
      flushing = false;
    }
  };

  const emit = (type, payload = {}) => {
    if (emitted >= MAX_EVENTS || outbox.length >= MAX_EVENTS) return;
    emitted += 1;
    outbox.push(Object.assign({
      schemaVersion: 1,
      type,
      pageInstanceId,
      sequence: ++sequence,
      timestampMs: Date.now(),
      documentUrl: String(location.href)
    }, payload));
    queueMicrotask(flush);
  };
  Object.defineProperty(window, '__noteSynapseProtocolDiagnosticV1', {
    value: (code) => emit('diagnostic', {
      code: String(code || 'probe_diagnostic').slice(0, 80)
    }),
    configurable: false, enumerable: false, writable: false
  });

  const emitBody = (prefix, exchangeId, body) => {
    if (!body || body.text === null || body.text === undefined) {
      emit(`${prefix}Body`, {exchangeId, body});
      return;
    }
    const text = body.text;
    const meta = Object.assign({}, body);
    delete meta.text;
    emit(`${prefix}BodyStart`, {exchangeId, body: meta});
    // 24K UTF-16 code units keeps individual bridge messages comfortably
    // below the Dart event cap even for multi-byte text.
    const chunkSize = 24 * 1024;
    for (let offset = 0, index = 0; offset < text.length; offset += chunkSize, index += 1) {
      emit(`${prefix}BodyChunk`, {exchangeId, index, text: text.slice(offset, offset + chunkSize)});
    }
    emit(`${prefix}BodyEnd`, {exchangeId});
  };

  const bodySnapshot = async (body, maxBytes) => {
    try {
      if (body === undefined || body === null) return null;
      if (typeof body === 'string') return capText(body, maxBytes);
      if (body instanceof URLSearchParams) return capText(body.toString(), maxBytes);
      if (body instanceof Request) {
        return readStreamText(body.body, maxBytes);
      }
      if (body instanceof FormData) {
        const values = [];
        for (const [name, value] of body.entries()) {
          values.push([String(name), typeof value === 'string'
            ? value
            : {fileName: value.name || '', type: value.type || '', size: value.size || 0}]);
        }
        return capText(JSON.stringify(values), maxBytes);
      }
      if (body instanceof Blob) {
        if (!CAPTURE_BINARY) {
          return {text: null, byteLength: body.size, truncated: false, omittedReason: 'binary_disabled'};
        }
        const text = await body.slice(0, maxBytes).text();
        return {text, byteLength: body.size, truncated: body.size > maxBytes};
      }
      if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
        return {text: null, byteLength: body.byteLength || 0, truncated: false, omittedReason: 'binary_body'};
      }
      return capText(String(body), maxBytes);
    } catch (error) {
      return {text: null, byteLength: null, truncated: false, omittedReason: `unreadable:${error && error.name || 'error'}`};
    }
  };

  const responseSnapshot = async (response) => {
    if (response.type === 'opaque' || response.type === 'opaqueredirect') {
      return {text: null, mimeType: null, byteLength: null, truncated: false,
        omittedReason: `opaque_response:${response.type}`};
    }
    const contentType = response.headers.get('content-type') || '';
    const contentLength = Number(response.headers.get('content-length') || 0);
    const textual = /(^text\/|json|xml|javascript|x-www-form-urlencoded|graphql)/i.test(contentType);
    if (!textual && !CAPTURE_BINARY) {
      return {text: null, mimeType: contentType, byteLength: contentLength || null,
        truncated: false, omittedReason: 'binary_disabled'};
    }
    const body = await readStreamText(response.body, MAX_RESPONSE);
    if (contentLength > 0) {
      body.byteLength = contentLength;
      if (contentLength > MAX_RESPONSE) body.truncated = true;
    }
    return Object.assign({mimeType: contentType}, body);
  };

  if (originalFetch) {
    wrappedFetch = function(resource, init) {
      const exchangeId = `${pageInstanceId}:fetch:${sequence + 1}`;
      // Invoke the site's implementation first, with the original receiver and
      // exact original arguments. In particular, do not clone a Request or tee
      // a ReadableStream before the browser has accepted it.
      let result;
      try {
        result = originalFetch.apply(this, arguments);
      } catch (error) {
        emit('request', {exchangeId, source: 'fetch', method: 'UNKNOWN',
          url: typeof resource === 'string' ? resource : String(resource && resource.url || ''),
          headers: [], metadata: {capture: 'original_fetch_threw'}});
        emit('error', {exchangeId, error: String(error && error.message || error)});
        throw error;
      }
      let requestCopy = null;
      let url = '';
      let method = 'GET';
      let headers = [];
      let metadata = {};
      try {
        const inspectedRequest = resource instanceof Request
          ? resource
          : new Request(resource, init);
        url = inspectedRequest.url;
        method = inspectedRequest.method || method;
        headers = headerPairs(inspectedRequest.headers);
        metadata = {
          cache: String(inspectedRequest.cache || ''),
          credentials: String(inspectedRequest.credentials || ''),
          destination: String(inspectedRequest.destination || ''),
          integrity: String(inspectedRequest.integrity || ''),
          keepalive: String(Boolean(inspectedRequest.keepalive)),
          mode: String(inspectedRequest.mode || ''),
          redirect: String(inspectedRequest.redirect || ''),
          referrer: String(inspectedRequest.referrer || ''),
          referrerPolicy: String(inspectedRequest.referrerPolicy || '')
        };
        try { requestCopy = inspectedRequest.clone(); }
        catch (_) { requestCopy = null; }
      } catch (_) {
        url = typeof resource === 'string' ? resource : String(resource && resource.url || '');
        method = String(init && init.method || method).toUpperCase();
        headers = headerPairs(init && init.headers);
        metadata = {capture: resource instanceof Request
          ? 'request_body_already_consumed'
          : 'request_normalization_unavailable'};
      }

      emit('request', {exchangeId, source: 'fetch', method, url, headers, metadata});
      if (requestCopy && method !== 'GET' && method !== 'HEAD') {
        bodySnapshot(requestCopy, MAX_REQUEST).then((body) => {
          emitBody('request', exchangeId, body);
        });
      } else if (method !== 'GET' && method !== 'HEAD') {
        emitBody('request', exchangeId, {text: null, byteLength: null,
          truncated: false, omittedReason: 'request_body_not_cloneable_after_dispatch'});
      }

      // Protocol Study is a deliberate deep-capture mode. Register the
      // observer before returning the unchanged promise so the response can be
      // cloned before a page callback consumes its body. Only clone and enqueue
      // metadata synchronously; bounded body reading remains asynchronous.
      Promise.resolve(result).then((response) => {
          let clone;
          try { clone = response.clone(); }
          catch (_) {
            emit('response', {
              exchangeId,
              status: response.status,
              url: response.url || url,
              redirected: Boolean(response.redirected),
              responseType: String(response.type || ''),
              headers: headerPairs(response.headers)
            });
            emitBody('response', exchangeId, {text: null, byteLength: null,
              truncated: false, omittedReason: 'response_not_cloneable_before_page_callback'});
            emit('complete', {exchangeId, omittedReason: 'response_not_cloneable_before_page_callback'});
            return;
          }
          emit('response', {
            exchangeId,
            status: response.status,
            url: response.url || url,
            redirected: Boolean(response.redirected),
            responseType: String(response.type || ''),
            headers: headerPairs(response.headers)
          });
          responseSnapshot(clone).then((body) => {
            emitBody('response', exchangeId, body);
            emit('complete', {exchangeId});
          });
        }, (error) => {
          emit('error', {exchangeId, error: String(error && error.message || error)});
        });
      return result;
    };
    window.fetch = wrappedFetch;
  }

  if (OriginalXHR && OriginalXHR.prototype) {
    const states = new WeakMap();
    const originalOpen = OriginalXHR.prototype.open;
    const originalSetRequestHeader = OriginalXHR.prototype.setRequestHeader;
    const originalSend = OriginalXHR.prototype.send;

    wrappedXHROpen = function(method, url, async) {
      const result = originalOpen.apply(this, arguments);
      states.set(this, {method: String(method || 'GET').toUpperCase(), url: String(url || ''),
        headers: [], synchronous: async === false});
      return result;
    };
    OriginalXHR.prototype.setRequestHeader = function(name, value) {
      const state = states.get(this);
      if (state) state.headers.push([String(name), String(value)]);
      return originalSetRequestHeader.apply(this, arguments);
    };
    wrappedXHRSend = function(body) {
      const state = states.get(this) || {method: 'GET', url: '', headers: []};
      const exchangeId = `${pageInstanceId}:xhr:${sequence + 1}`;
      state.exchangeId = exchangeId;
      emit('request', {exchangeId, source: 'xhr', method: state.method, url: state.url,
        headers: state.headers, metadata: {synchronous: String(Boolean(state.synchronous)),
          responseType: String(this.responseType || ''), withCredentials: String(Boolean(this.withCredentials))}});
      this.addEventListener('loadend', () => {
        const responseHeaders = [];
        try {
          const raw = this.getAllResponseHeaders() || '';
          for (const line of raw.trim().split(/[\r\n]+/)) {
            const split = line.indexOf(':');
            if (split > 0) responseHeaders.push([line.slice(0, split).trim(), line.slice(split + 1).trim()]);
          }
        } catch (_) {}
        const finalUrl = String(this.responseURL || state.url);
        emit('response', {exchangeId, status: Number(this.status || 0),
          url: finalUrl, redirected: finalUrl !== String(state.url), headers: responseHeaders});
        let snapshot = null;
        try {
          if (this.responseType === '' || this.responseType === 'text') {
            snapshot = capText(this.responseText, MAX_RESPONSE);
          } else {
            snapshot = {text: null, byteLength: null, truncated: false,
              omittedReason: CAPTURE_BINARY ? 'unsupported_xhr_response_type' : 'binary_disabled'};
          }
        } catch (error) {
          snapshot = {text: null, byteLength: null, truncated: false,
            omittedReason: `unreadable:${error && error.name || 'error'}`};
        }
        emitBody('response', exchangeId, snapshot);
        emit('complete', {exchangeId});
      }, {once: true});
      let result;
      try {
        result = originalSend.apply(this, arguments);
      } catch (error) {
        emit('error', {exchangeId, error: String(error && error.message || error)});
        throw error;
      }
      bodySnapshot(body, MAX_REQUEST).then((snapshot) => {
        if (snapshot) emitBody('request', exchangeId, snapshot);
      });
      return result;
    };
    OriginalXHR.prototype.open = wrappedXHROpen;
    OriginalXHR.prototype.send = wrappedXHRSend;
  }

  document.addEventListener('submit', (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    const fields = [];
    try {
      for (const [name, value] of new FormData(form).entries()) {
        fields.push([String(name), typeof value === 'string'
          ? value
          : {fileName: value.name || '', type: value.type || '', size: value.size || 0}]);
      }
    } catch (_) {}
    emit('form', {
      action: form.action || location.href,
      method: String(form.method || 'GET').toUpperCase(),
      fields,
      selectorHint: selectorHint(form)
    });
  }, true);

  document.addEventListener('click', (event) => {
    const target = event.target && event.target.closest
      ? event.target.closest('button,a,input[type="submit"],input[type="button"]')
      : null;
    if (!target) return;
    emit('interaction', {
      kind: 'click',
      label: String(target.innerText || target.value || target.getAttribute('aria-label') || '').trim().slice(0, 240),
      selectorHint: selectorHint(target)
    });
  }, true);

  emit('hello', {capabilities: {
    fetch: Boolean(originalFetch), xhr: Boolean(OriginalXHR), forms: true,
    binaryBodies: CAPTURE_BINARY, serviceWorkers: false, webSockets: false,
    wrapperIntegrity: true
  }});

  const checkWrapperIntegrity = () => {
    const fetchReplaced = Boolean(wrappedFetch) && window.fetch !== wrappedFetch;
    const xhrReplaced = Boolean(OriginalXHR && OriginalXHR.prototype) &&
      (OriginalXHR.prototype.open !== wrappedXHROpen || OriginalXHR.prototype.send !== wrappedXHRSend);
    if (fetchReplaced || xhrReplaced) {
      emit('diagnostic', {code: 'wrapper_replaced', fetchReplaced, xhrReplaced});
      return;
    }
    setTimeout(checkWrapperIntegrity, 1000);
  };
  setTimeout(checkWrapperIntegrity, 0);
})();
''';
}
