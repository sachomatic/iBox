#!/usr/bin/env python3
"""Plays every channel of an M3U playlist on a running iBox and records what happens.

For each channel: iBox's own stream probe (/api/debug/probe), then, if it says
playable, real playback (/api/debug/play) until the position advances or it fails.

    python tools/sweep_channels.py http://192.168.1.128:8080 https://iptv-org.github.io/iptv/countries/fr.m3u out.json
"""
import json
import re
import sys
import time
import urllib.request

VERDICTS = {0: "playable", 1: "incompatible", 2: "blocked", 3: "unreachable", -1: "timeout"}


def api(base, path, body=None, timeout=100):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def parse(text):
    channels, pending = [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF"):
            name = line.rsplit(",", 1)[-1]
            headers = {}
            m = re.search(r'http-user-agent="([^"]*)"', line)
            if m:
                headers["User-Agent"] = m.group(1)
            m = re.search(r'http-referrer="([^"]*)"', line)
            if m:
                headers["Referer"] = m.group(1)
            pending = {"name": name, "headers": headers}
        elif line.startswith("#EXTVLCOPT:") and pending:
            key, _, value = line[11:].partition("=")
            if key.lower() == "http-user-agent":
                pending["headers"]["User-Agent"] = value
            if key.lower() in ("http-referrer", "http-referer"):
                pending["headers"]["Referer"] = value
        elif line and not line.startswith("#"):
            channels.append(dict(pending or {"name": line, "headers": {}}, url=line))
            pending = None
    return channels


def play(base, ch, limit=40):
    api(base, "/api/debug/play", {"url": ch["url"], "headers": ch["headers"], "title": ch["name"]})
    start, last, advancing = time.time(), None, 0
    while time.time() - start < limit:
        time.sleep(2)
        st = api(base, "/api/state")
        toast = st.get("toast") or ""
        p = st.get("player")
        if toast and ch["name"][:20] in toast:
            return "failed", toast
        if p is None and time.time() - start > 4:
            return "failed", toast or "player closed"
        pos = (p or {}).get("position") or 0
        if last is not None and pos > last + 0.5:
            advancing += 1
            # A moving clock alone can be sound only: require a decoded picture
            # unless the stream has no video track at all (radio-style channel).
            picture = (p.get("width") or 0) > 0 or not p.get("videoTrack", True)
            if advancing >= 3 and pos > 5 and picture:
                return "plays", "%.0fs in %.0fs, %dx%d" % (pos, time.time() - start, p.get("width") or 0, p.get("height") or 0)
        last = pos
    return "stalled", "no progress in %ds" % limit


def main():
    base, playlist = sys.argv[1].rstrip("/"), sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else "sweep.json"
    only = set(json.load(open(sys.argv[4]))) if len(sys.argv) > 4 else None  # optional list of URLs to retest
    channels = parse(urllib.request.urlopen(playlist, timeout=30).read().decode("utf8", "replace"))
    results = []
    for i, ch in enumerate(channels):
        if only is not None and ch["url"] not in only:
            continue
        try:
            pr = api(base, "/api/debug/probe", {"url": ch["url"], "headers": ch["headers"]})
            verdict = VERDICTS.get(pr.get("verdict"), "?")
            res = {"name": ch["name"], "url": ch["url"], "headers": ch["headers"], "probe": verdict, "reason": pr.get("reason")}
            if verdict == "playable":
                res["play"], res["detail"] = play(base, ch)
                api(base, "/api/player", {"action": "stop"})
                time.sleep(1)
        except Exception as e:
            res = {"name": ch["name"], "url": ch["url"], "headers": ch["headers"], "probe": "error", "reason": str(e)}
        results.append(res)
        print("%3d %-38s %-12s %-8s %s" % (i, ch["name"][:38], res["probe"], res.get("play", ""),
                                           (res.get("detail") or res.get("reason") or "")[:90]), flush=True)
        json.dump(results, open(out, "w"), indent=1)
    plays = sum(1 for r in results if r.get("play") == "plays")
    print("summary: %d channels, %d play, %d failed/stalled after probe, %d filtered by probe" % (
        len(results), plays, sum(1 for r in results if r.get("play") in ("failed", "stalled")),
        sum(1 for r in results if r["probe"] != "playable")))


if __name__ == "__main__":
    main()
