// Fills web APIs missing from iOS 6's WebKit so YouTube's official embedded player
// can run in iBox's web view. ES5 only. Each shim is skipped when the API exists.
(function (w) {
  if (w.ibShim) return;
  w.ibShim = true;
  var log = w.ibLog = w.ibLog || [];
  function L(m) { log.push(m); }
  w.onerror = function (m, u, l) { L('error: ' + m + ' @' + String(u).split('/').pop() + ':' + l); };
  w.addEventListener('unhandledrejection', function (e) { L('rejection: ' + (e.reason && (e.reason.stack || e.reason))); });

  // iOS 6's XHR.send() stringifies typed-array views ("[object Uint8Array]");
  // it does accept a plain ArrayBuffer.
  if (!XMLHttpRequest.prototype.ibSendPatched) {
    var nativeSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (body) {
      if (body && body.buffer instanceof ArrayBuffer && typeof body.byteLength === 'number' && !(body instanceof ArrayBuffer)) {
        body = body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength);
      }
      return nativeSend.call(this, body);
    };
    XMLHttpRequest.prototype.ibSendPatched = true;
  }

  w.queueMicrotask = w.queueMicrotask || function (f) { setTimeout(f, 0); };
  w.requestAnimationFrame = w.requestAnimationFrame || w.webkitRequestAnimationFrame ||
    function (f) { return setTimeout(function () { f(+new Date()); }, 16); };
  w.cancelAnimationFrame = w.cancelAnimationFrame || w.webkitCancelAnimationFrame || clearTimeout;
  w.MutationObserver = w.MutationObserver || w.WebKitMutationObserver;
  w.requestIdleCallback = w.requestIdleCallback || function (f) {
    return setTimeout(function () { f({ didTimeout: false, timeRemaining: function () { return 15; } }); }, 1);
  };
  w.cancelIdleCallback = w.cancelIdleCallback || clearTimeout;
  if (!w.performance) {
    var start = +new Date();
    w.performance = { now: function () { return +new Date() - start; }, timing: { navigationStart: start },
                      mark: function () {}, measure: function () {}, getEntriesByType: function () { return []; },
                      getEntriesByName: function () { return []; }, clearMarks: function () {} };
  }
  if (!w.performance.now) w.performance.now = function () { return +new Date(); };

  if (!w.TextEncoder) {
    w.TextEncoder = function () {};
    w.TextEncoder.prototype.encoding = 'utf-8';
    w.TextEncoder.prototype.encode = function (s) {
      var u = unescape(encodeURIComponent(String(s || ''))), a = new Uint8Array(u.length);
      for (var i = 0; i < u.length; i++) a[i] = u.charCodeAt(i);
      return a;
    };
  }
  if (!w.TextDecoder) {
    w.TextDecoder = function () {};
    w.TextDecoder.prototype.encoding = 'utf-8';
    w.TextDecoder.prototype.decode = function (b) {
      if (!b) return '';
      var a = b instanceof Uint8Array ? b : new Uint8Array(b.buffer || b), s = '';
      for (var i = 0; i < a.length; i += 4096) s += String.fromCharCode.apply(null, a.subarray(i, i + 4096));
      try { return decodeURIComponent(escape(s)); } catch (e) { return s; }
    };
  }

  if (!w.URLSearchParams) {
    var USP = function (init) {
      this._p = [];
      if (init && typeof init === 'object') { for (var k in init) if (init.hasOwnProperty(k)) this._p.push([k, String(init[k])]); return; }
      init = String(init || '').replace(/^\?/, '');
      var parts = init ? init.split('&') : [];
      for (var i = 0; i < parts.length; i++) {
        var kv = parts[i].split('='), dec = function (x) { return decodeURIComponent((x || '').replace(/\+/g, ' ')); };
        if (kv[0]) this._p.push([dec(kv[0]), dec(kv.slice(1).join('='))]);
      }
    };
    USP.prototype.get = function (k) { for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) return this._p[i][1]; return null; };
    USP.prototype.getAll = function (k) { var r = []; for (var i = 0; i < this._p.length; i++) if (this._p[i][0] === k) r.push(this._p[i][1]); return r; };
    USP.prototype.has = function (k) { return this.get(k) !== null; };
    USP.prototype.set = function (k, v) { this['delete'](k); this._p.push([k, String(v)]); };
    USP.prototype.append = function (k, v) { this._p.push([k, String(v)]); };
    USP.prototype['delete'] = function (k) { this._p = this._p.filter(function (p) { return p[0] !== k; }); };
    USP.prototype.forEach = function (f, t) { var p = this._p.slice(); for (var i = 0; i < p.length; i++) f.call(t, p[i][1], p[i][0], this); };
    USP.prototype.keys = function () { return this._p.map(function (p) { return p[0]; }); };
    USP.prototype.toString = function () {
      return this._p.map(function (p) { return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]); }).join('&');
    };
    w.URLSearchParams = USP;
  }

  var nativeURL = w.URL || w.webkitURL;
  var urlWorks = false;
  try { urlWorks = !!new nativeURL('https://a.b/c').pathname; } catch (e) {}
  if (!urlWorks) {
    var URLShim = function (url, base) {
      var doc = document.implementation.createHTMLDocument('');
      if (base) { var b = doc.createElement('base'); b.href = String(base); doc.head.appendChild(b); }
      var a = doc.createElement('a');
      a.href = String(url);
      doc.body.appendChild(a);
      if (!/^[a-z][a-z0-9+.-]*:/i.test(a.href)) throw new TypeError('Invalid URL: ' + url);
      this._a = a;
      this.searchParams = new w.URLSearchParams(a.search);
    };
    ['protocol', 'host', 'hostname', 'port', 'pathname', 'hash', 'username', 'password'].forEach(function (k) {
      Object.defineProperty(URLShim.prototype, k, { get: function () { return this._a[k]; }, set: function (v) { this._a[k] = v; } });
    });
    Object.defineProperty(URLShim.prototype, 'search', {
      get: function () { var s = this.searchParams.toString(); return s ? '?' + s : ''; },
      set: function (v) { this.searchParams = new w.URLSearchParams(v); }
    });
    Object.defineProperty(URLShim.prototype, 'origin', { get: function () { return this._a.protocol + '//' + this._a.host; } });
    Object.defineProperty(URLShim.prototype, 'href', {
      get: function () { return this._a.protocol + '//' + this._a.host + this._a.pathname + this.search + this._a.hash; },
      set: function (v) { this._a.href = v; this.searchParams = new w.URLSearchParams(this._a.search); }
    });
    URLShim.prototype.toString = URLShim.prototype.toJSON = function () { return this.href; };
    if (nativeURL) {
      URLShim.createObjectURL = function (o) { return nativeURL.createObjectURL(o); };
      URLShim.revokeObjectURL = function (u) { return nativeURL.revokeObjectURL(u); };
    }
    w.URL = URLShim;
  }

  if (!w.AbortController) {
    var Signal = function () { this.aborted = false; this.onabort = null; this._l = []; };
    Signal.prototype.addEventListener = function (t, f) { if (t === 'abort') this._l.push(f); };
    Signal.prototype.removeEventListener = function (t, f) { this._l = this._l.filter(function (x) { return x !== f; }); };
    Signal.prototype.throwIfAborted = function () { if (this.aborted) throw new Error('AbortError'); };
    w.AbortSignal = Signal;
    w.AbortController = function () { this.signal = new Signal(); };
    w.AbortController.prototype.abort = function () {
      var s = this.signal;
      if (s.aborted) return;
      s.aborted = true;
      var ev = { type: 'abort', target: s };
      if (s.onabort) s.onabort(ev);
      s._l.forEach(function (f) { f(ev); });
    };
  }

  if (!w.fetch && w.Promise) {
    var Headers = function (init) {
      this._h = {};
      if (init) {
        if (init instanceof Headers) init = init._h;
        for (var k in init) if (init.hasOwnProperty(k)) this._h[k.toLowerCase()] = String(init[k]);
      }
    };
    Headers.prototype.get = function (k) { var v = this._h[String(k).toLowerCase()]; return v === undefined ? null : v; };
    Headers.prototype.set = function (k, v) { this._h[String(k).toLowerCase()] = String(v); };
    Headers.prototype.append = Headers.prototype.set;
    Headers.prototype.has = function (k) { return String(k).toLowerCase() in this._h; };
    Headers.prototype.forEach = function (f, t) { for (var k in this._h) f.call(t, this._h[k], k, this); };
    w.Headers = Headers;
    var Response = function (body, init) {
      init = init || {};
      this._body = body;
      this.status = init.status || 200;
      this.ok = this.status >= 200 && this.status < 300;
      this.statusText = init.statusText || '';
      this.headers = new Headers(init.headers);
      this.url = init.url || '';
    };
    Response.prototype.text = function () { return Promise.resolve(typeof this._body === 'string' ? this._body : new w.TextDecoder().decode(this._body)); };
    Response.prototype.json = function () { return this.text().then(JSON.parse); };
    Response.prototype.arrayBuffer = function () {
      return Promise.resolve(typeof this._body === 'string' ? new w.TextEncoder().encode(this._body).buffer : this._body);
    };
    Response.prototype.clone = function () { return new Response(this._body, { status: this.status, headers: this.headers._h, url: this.url }); };
    w.Response = Response;
    w.Request = function (u, o) { this.url = String(u); o = o || {}; for (var k in o) this[k] = o[k]; };
    w.fetch = function (input, opts) {
      opts = opts || {};
      var url = typeof input === 'string' ? input : (input && input.url) || String(input);
      if (typeof input === 'object' && input && !(input instanceof URL)) { for (var k in input) if (!(k in opts) && k !== 'url') opts[k] = input[k]; }
      return new Promise(function (resolve, reject) {
        var x = new XMLHttpRequest();
        x.open(opts.method || 'GET', url, true);
        x.withCredentials = opts.credentials === 'include';
        var h = opts.headers instanceof Headers ? opts.headers._h : (opts.headers || {});
        for (var k in h) if (h.hasOwnProperty(k)) x.setRequestHeader(k, h[k]);
        var binary = opts.ibBinary;
        if (binary) x.responseType = 'arraybuffer';
        x.onload = function () {
          var headers = {};
          (x.getAllResponseHeaders() || '').split(/\r?\n/).forEach(function (line) {
            var i = line.indexOf(':'); if (i > 0) headers[line.substr(0, i).trim()] = line.substr(i + 1).trim();
          });
          resolve(new Response(binary ? x.response : x.responseText, { status: x.status, statusText: x.statusText, headers: headers, url: url }));
        };
        x.onerror = function () { reject(new TypeError('Network request failed')); };
        x.ontimeout = x.onerror;
        if (opts.signal) opts.signal.addEventListener('abort', function () { x.abort(); reject(new Error('AbortError')); });
        var body = opts.body;
        if (body instanceof w.URLSearchParams) body = body.toString();
        x.send(body === undefined ? null : body);
      });
    };
  }
  L('shim installed');
})(window);
