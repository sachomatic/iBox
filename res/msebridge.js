// MediaSource for iOS 6's web view, so YouTube's own player can use its 480p/720p
// streams. SourceBuffers send what the player appends (fragmented MP4: H.264 / AAC)
// to iBox (src/IBMSE.m), which serves it back as an HLS stream; the page's <video>
// plays that stream natively. Load after ytshim.js and before the player is built.
(function (w) {
  if (w.ibMSE || w.ibNoMSE) return;
  var log = w.ibLog = w.ibLog || [];
  function L(m) { log.push('MSE ' + m); if (log.length > 300) log.shift(); }
  var BASE = 'http://127.0.0.1:8080/mse/';
  var counter = 0;
  var stats = w.ibMSEStats = { appends: 0, bytes: 0, errors: 0, sessions: 0, last: '' };

  function later(f) { setTimeout(f, 0); }
  function domError(name, msg) { var e = new Error(msg || name); e.name = name; return e; }

  function Ranges(r) {
    r = r || [];
    return {
      length: r.length,
      start: function (i) { if (i >= r.length) throw domError('IndexSizeError'); return r[i][0]; },
      end: function (i) { if (i >= r.length) throw domError('IndexSizeError'); return r[i][1]; }
    };
  }

  function Target() {}
  Target.prototype.addEventListener = function (t, f) {
    var l = this._l || (this._l = {});
    (l[t] = l[t] || []).push(f);
  };
  Target.prototype.removeEventListener = function (t, f) {
    var a = this._l && this._l[t];
    if (!a) return;
    for (var i = 0; i < a.length; i++) if (a[i] === f) { a.splice(i, 1); break; }
  };
  Target.prototype.dispatchEvent = function (e) {
    var a = (this._l && this._l[e.type] || []).slice();
    for (var i = 0; i < a.length; i++) {
      try { if (typeof a[i] === 'function') a[i].call(this, e); else if (a[i] && a[i].handleEvent) a[i].handleEvent(e); }
      catch (x) { L('listener error ' + e.type + ': ' + x); }
    }
    var h = this['on' + e.type];
    if (typeof h === 'function') { try { h.call(this, e); } catch (x) { L('handler error ' + e.type + ': ' + x); } }
    return true;
  };
  function fire(target, type) {
    target.dispatchEvent({ type: type, target: target, currentTarget: target, srcElement: target,
                           preventDefault: function () {}, stopPropagation: function () {} });
  }

  function post(url, body, done) {
    var x = new XMLHttpRequest();
    x.open('POST', url, true);
    x.onreadystatechange = function () {
      if (x.readyState !== 4) return;
      var r = null;
      try { r = JSON.parse(x.responseText); } catch (e) {}
      if (done) done(x.status, r);
    };
    x.send(body === undefined ? null : body);
  }

  // H.264 Baseline/Main up to level 3.1 (720p30) and AAC-LC: what the A4 decodes.
  function supported(type) {
    if (w.ibMSEOff) return false;  // this video is better as YouTube's progressive 360p
    var t = String(type || '').toLowerCase();
    var mime = t.split(';')[0].replace(/\s/g, '');
    var m = /codecs\s*=\s*"?([^";]+)"?/.exec(t);
    var codecs = m ? m[1].split(',') : [];
    var param = function (name) { var r = new RegExp(name + '\\s*=\\s*"?([0-9.]+)').exec(t); return r ? parseFloat(r[1]) : 0; };
    if (param('framerate') > 31 || param('height') > 720 || param('width') > 1280) return false;
    if (mime === 'video/mp4') {
      if (!codecs.length) return true;
      for (var i = 0; i < codecs.length; i++) {
        var c = codecs[i].replace(/\s/g, '');
        var a = /^avc[13]\.([0-9a-f]{2})[0-9a-f]{2}([0-9a-f]{2})$/.exec(c);
        if (a) { if ((a[1] !== '42' && a[1] !== '4d') || parseInt(a[2], 16) > 31) return false; continue; }
        if (/^mp4a\.40\.2$/.test(c)) continue;
        return false;
      }
      return true;
    }
    if (mime === 'audio/mp4') {
      for (var j = 0; j < codecs.length; j++) if (!/^mp4a\.40\.2$/.test(codecs[j].replace(/\s/g, ''))) return false;
      return true;
    }
    return false;
  }

  function SourceBuffer(ms, id, type) {
    this._ms = ms; this._id = id; this._ranges = [];
    this.type = type; this.mode = 'segments'; this.updating = false;
    this.timestampOffset = 0; this.appendWindowStart = 0; this.appendWindowEnd = Infinity;
    this.audioTracks = []; this.videoTracks = []; this.textTracks = [];
  }
  SourceBuffer.prototype = new Target();
  SourceBuffer.prototype.constructor = SourceBuffer;
  Object.defineProperty(SourceBuffer.prototype, 'buffered', { get: function () { return Ranges(this._ranges); } });
  SourceBuffer.prototype._request = function (action, query, body) {
    var self = this;
    if (self.updating) throw domError('InvalidStateError', 'SourceBuffer is updating');
    if (self._ms.readyState === 'closed') throw domError('InvalidStateError', 'MediaSource is closed');
    if (self._ms.readyState === 'ended') { self._ms.readyState = 'open'; fire(self._ms, 'sourceopen'); }
    self.updating = true;
    later(function () { fire(self, 'updatestart'); });
    post(BASE + self._ms._sid + '/' + action + '?sb=' + self._id + query, body, function (status, r) {
      self.updating = false;
      if (status === 200 && r) {
        self._ranges = r.buffered || [];
        fire(self, 'update');
      } else {
        stats.errors++;
        L(action + ' failed: HTTP ' + status);
        fire(self, 'error');
      }
      fire(self, 'updateend');
    });
  };
  SourceBuffer.prototype.appendBuffer = function (data) {
    var src = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
    var copy = new Uint8Array(src.length);
    copy.set(src);
    stats.appends++; stats.bytes += copy.length;
    this._request('append', '&off=' + (this.timestampOffset || 0), copy.buffer);
  };
  SourceBuffer.prototype.remove = function (start, end) {
    this._request('remove', '&s=' + start + '&e=' + (isFinite(end) ? end : 1e9), null);
  };
  SourceBuffer.prototype.abort = function () {
    post(BASE + this._ms._sid + '/abort?sb=' + this._id, null, null);
  };
  SourceBuffer.prototype.changeType = function (type) { this.type = type; };

  // iOS 6 ignores a seek made before the <video> has loaded anything, so a stream that
  // starts mid-video (resume, quality switch, ad break) would play from 0: once the
  // element can seek, move it to the stream's first data.
  var attached = w.ibMSEAttached = [];
  setInterval(function () {
    for (var i = attached.length - 1; i >= 0; i--) {
      var ms = attached[i];
      var age = Date.now() - ms._attachedAt;
      if (ms._jumped || age > 60000 || (ms.readyState === 'closed' && age > 5000)) { attached.splice(i, 1); continue; }
      var vids = document.getElementsByTagName('video'), el = null;
      for (var j = 0; j < vids.length; j++) if (vids[j].src === ms._url) el = vids[j];
      if (!el || el.readyState < 1) continue;  // even while 'seeking': iOS 6 never completes a seek made too early
      var first = -Infinity;
      for (var k = 0; k < ms.sourceBuffers.length; k++) {
        var r = ms.sourceBuffers[k]._ranges;
        if (r && r.length) first = Math.max(first, r[0][0]);  // where picture and sound both start
      }
      if (first === -Infinity) continue;
      if (el.currentTime >= first - 1) {
        if (ms._jumpAt) ms._jumped = true;  // landed (or the stream started where the <video> is)
        continue;
      }
      // Too early, iOS ignores the seek: try again every 2 s until it takes.
      if (ms._jumpAt && Date.now() - ms._jumpAt < 2000) continue;
      L('start jump ' + el.currentTime.toFixed(1) + ' -> ' + first.toFixed(2));
      ms._jumpAt = Date.now();
      try { el.currentTime = first + 0.05; } catch (e) { L('jump failed ' + e); }
    }
  }, 400);

  function MediaSource() {
    this._sid = Date.now().toString(36) + '-' + (counter++);
    this._duration = NaN;
    this.readyState = 'closed';
    this.sourceBuffers = [];
    this.activeSourceBuffers = [];
    stats.sessions++;
    L('new MediaSource ' + this._sid);
  }
  MediaSource.prototype = new Target();
  MediaSource.prototype.constructor = MediaSource;
  Object.defineProperty(MediaSource.prototype, 'duration', {
    get: function () { return this._duration; },
    set: function (d) {
      this._duration = d;
      post(BASE + this._sid + '/duration?d=' + d, null, null);
      var self = this;
      later(function () { fire(self, 'durationchange'); });
    }
  });
  MediaSource.prototype.addSourceBuffer = function (type) {
    if (!supported(type)) throw domError('NotSupportedError', 'unsupported ' + type);
    if (this.readyState !== 'open') throw domError('InvalidStateError', 'MediaSource not open');
    var sb = new SourceBuffer(this, this.sourceBuffers.length, type);
    this.sourceBuffers.push(sb);
    this.activeSourceBuffers.push(sb);
    L('addSourceBuffer ' + type);
    var self = this;
    later(function () { fire(self, 'addsourcebuffer'); });
    return sb;
  };
  MediaSource.prototype.removeSourceBuffer = function (sb) {
    var a = this.sourceBuffers, b = this.activeSourceBuffers, i;
    for (i = 0; i < a.length; i++) if (a[i] === sb) { a.splice(i, 1); break; }
    for (i = 0; i < b.length; i++) if (b[i] === sb) { b.splice(i, 1); break; }
  };
  MediaSource.prototype.endOfStream = function (error) {
    this.readyState = 'ended';
    if (!error) post(BASE + this._sid + '/eos', null, null);
    var self = this;
    later(function () { fire(self, 'sourceended'); });
  };
  MediaSource.prototype.setLiveSeekableRange = function () {};
  MediaSource.prototype.clearLiveSeekableRange = function () {};
  MediaSource.isTypeSupported = function (type) {
    var ok = supported(type);
    stats.last = type + ' -> ' + ok;
    return ok;
  };

  w.MediaSource = MediaSource;
  w.SourceBuffer = SourceBuffer;
  w.ibMSE = MediaSource;

  // The player attaches a MediaSource with video.src = URL.createObjectURL(ms):
  // hand it the HLS address of that session instead.
  function wrap(U) {
    if (!U || U.ibMSEWrapped) return;
    var create = U.createObjectURL, revoke = U.revokeObjectURL;
    U.createObjectURL = function (o) {
      if (o instanceof MediaSource) {
        var url = BASE + o._sid + '/index.m3u8';
        L('attach ' + o._sid);
        o._url = url;
        o._attachedAt = Date.now();
        attached.push(o);
        later(function () { o.readyState = 'open'; fire(o, 'sourceopen'); });
        return url;
      }
      return create ? create.apply(U, arguments) : '';
    };
    U.revokeObjectURL = function (u) {
      if (String(u).indexOf(BASE) === 0) return;
      if (revoke) return revoke.apply(U, arguments);
    };
    U.ibMSEWrapped = true;
  }
  wrap(w.URL);
  wrap(w.webkitURL);
  L('bridge installed');
})(window);
