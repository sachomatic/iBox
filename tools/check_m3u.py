#!/usr/bin/env python3
"""Checks which channels of an M3U playlist the iPhone 4 can play, using the same
rules as iBox (IBVariantProblem / checkStream): H.264 Baseline/Main <= level 3.1,
<= 720p, no HEVC/AV1/VP9/Dolby audio, reachable without a 4xx.

    python tools/check_m3u.py https://iptv-org.github.io/iptv/countries/fr.m3u
"""
import concurrent.futures
import re
import sys
import urllib.request


def variant_problem(line):
    m = re.search(r"RESOLUTION=(\d+)x(\d+)", line)
    if m and int(m.group(2)) > 720:
        return "%sp video" % m.group(2)
    m = re.search(r'CODECS="([^"]*)"', line)
    if not m:
        return None
    for codec in (c.strip().lower() for c in m.group(1).split(",")):
        if codec.startswith(("hvc1", "hev1")):
            return "HEVC"
        if codec.startswith(("av01", "vp09")):
            return codec[:4].upper()
        if codec.startswith(("ac-3", "ec-3")):
            return "Dolby audio"
        if codec.startswith(("avc1.", "avc3.")):
            parts = codec[5:].split(".")
            if len(parts) == 1 and len(parts[0]) >= 6:
                v = int(parts[0][:6], 16)
                profile, level = v >> 16, v & 0xFF
            elif len(parts) >= 2:
                profile, level = int(parts[0]), int(parts[1])
            else:
                continue
            if profile not in (66, 77):
                return "H.264 High" if profile == 100 else "H.264 profile %d" % profile
            if level > 31:
                return "H.264 level %.1f" % (level / 10)
    return None


def parse(text):
    channels, pending = [], None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#EXTINF"):
            ua = re.search(r'http-user-agent="([^"]*)"', line)
            pending = {"name": line.rsplit(",", 1)[-1], "headers": {"User-Agent": ua.group(1)} if ua else {}}
        elif line.startswith("#EXTVLCOPT:http-user-agent=") and pending:
            pending["headers"]["User-Agent"] = line.split("=", 1)[1]
        elif line and not line.startswith("#"):
            channels.append(dict(pending or {"name": line, "headers": {}}, url=line))
            pending = None
    return channels


def check(ch):
    if ".m3u8" not in ch["url"].lower():
        return "unknown (not HLS)"
    headers = {"User-Agent": "iBox/1.0"}
    headers.update(ch["headers"])
    try:
        with urllib.request.urlopen(urllib.request.Request(ch["url"], headers=headers), timeout=10) as r:
            text = r.read(2_000_000).decode("utf8", "replace")
    except urllib.error.HTTPError as e:
        return "blocked/offline (HTTP %d)" % e.code
    except Exception as e:
        return "unreachable"
    if "#EXTM3U" not in text:
        return "not a playlist"
    variants = [l for l in text.splitlines() if l.startswith("#EXT-X-STREAM-INF")]
    problems = [variant_problem(v) for v in variants]
    if variants and all(problems):
        return "incompatible: " + problems[0]
    return "ok"


def main():
    url = sys.argv[1] if len(sys.argv) > 1 else "https://iptv-org.github.io/iptv/countries/fr.m3u"
    channels = parse(urllib.request.urlopen(url, timeout=20).read().decode("utf8", "replace"))
    with concurrent.futures.ThreadPoolExecutor(16) as pool:
        results = list(pool.map(check, channels))
    summary = {}
    for ch, res in zip(channels, results):
        key = res.split(":")[0].split(" (")[0]
        summary[key] = summary.get(key, 0) + 1
        if "-v" in sys.argv:
            print("%-40s %s" % (ch["name"][:40], res))
    print("%d channels:" % len(channels), ", ".join("%s %d" % kv for kv in sorted(summary.items(), key=lambda kv: -kv[1])))


if __name__ == "__main__":
    main()
