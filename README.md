# iBox — an iPhone 4 TV box

## ⚠️Warning : this has been mostly made with AI, I did *NOT* check the code. Use at your own risk!

iBox turns a jailbroken **iPhone 4 (iOS 6)** and an official Apple 30-pin AV adapter into a
stand-alone TV box. Everything runs on the phone; no PC or server is needed.

Release 1.0: [download the .deb](https://github.com/sachomatic/iBox/releases/tag/v1.0). Write-ups:
[YouTube at 720p on iOS 6](https://github.com/sachomatic/ios6-youtube-720p) ·
[iPhone 4 → TV, natively (iOS 6 field notes)](https://github.com/sachomatic/iphone4-tv-notes).

| Feature | How it works on the iPhone |
|---|---|
| **Jellyfin** | Finds servers on your LAN automatically. Has home rows (continue watching, next up), libraries, shows › seasons › episodes (episodes keep playing through the season), music albums and search. Lets you pick audio and subtitle tracks, before playing or from the player's options. Text subtitles (SRT, ASS, WebVTT…) are drawn by iBox, so the video can still direct-play; picture subtitles (PGS, DVD) are burned in by the server. Reports progress back to Jellyfin. Uses a device profile matched to the A4 (H.264 Main ≤ 720p, AAC stereo), so compatible files direct-play and the rest are transcoded to HLS. |
| **YouTube** | Search, categories, playlists and links cast from your phone, played in **YouTube's own embedded player** at up to **720p** (480p/720p through iBox's MediaSource bridge, see below), with pause, seek, next and ads handled. Subtitles (YouTube's captions, any language, remembered for the next videos) from the player's options. No API key needed: the official YouTube Data API is used when you add a key, otherwise YouTube's public search page. |
| **Spotify** | Open any playlist, album, artist or track link, search (with your own client ID), and a "recently opened" list. Each track plays **in full as its YouTube video**; Spotify's 30-second preview is used only if YouTube has no match. |
| **Screen sharing** | **Browser cast:** open `https://<iphone-ip>:8443/cast` on a computer and share a screen, window or tab. **VNC viewer:** works with Android (droidVNC-NG), Windows (TightVNC/UltraVNC), macOS and Linux. Supports Raw, CopyRect, Hextile, Zlib and ZRLE. |
| **Radio** | More than 30,000 stations from radio-browser.info: popular in your country, worldwide, by genre, and search. |
| **Live TV** | Free IPTV channels (iptv-org playlist for your country) or any M3U playlist, grouped by category. |
| **Play a link** | Any `.mp4` / `.m3u8` / `.mp3` / `.m3u` / YouTube / Spotify URL, from the TV or the remote. |
| **Remotes** | **iPhone screen as a trackpad:** drag to move, tap = OK, two fingers = Back, hold = Home. **Web remote:** `http://<iphone-ip>:8080` on any phone or computer, with D-pad, live typing, search, link casting, now playing with seek, volume and settings. **Keyboard:** arrow keys work in the web remote. |
| **Player options** | Press **Down**, or the **Options** button on the iPhone remote or the web remote, while a video plays (the info bar shows the hint): audio language, subtitles, quality and picture (fit / fill / stretch). See [Player options](#player-options). |
| **Screensaver** | After 5 idle minutes on menus or the music screen (never over a video), the TV goes black with a dim clock that moves every 8 s, to spare old TVs. Any key wakes it without acting. Settings › Screensaver: Off / 2 / 5 / 10 / 15 min (`screensaver` setting). |
| **Battery** | Charge level next to the clock (and in the web remote), with warnings on the TV at 20 %, 10 % and 5 % when the iPhone isn't plugged in. |
| **Extras** | Clock (local time from your IP), live weather, queue with next/previous, background audio, Bonjour, auto-start and relaunch (watchdog), and the phone screen dims while the TV is in use. |

## Hardware

* An iPhone 4 on iOS 6.x, jailbroken, with OpenSSH.
* One official Apple AV adapter:
  * **Apple Digital AV Adapter (30-pin → HDMI)** gives up to 720p and has a charging port.
  * **Apple Composite AV Cable** or **Component AV Cable** gives 480i/576i (analog TVs).
    iBox corrects the non-square pixels and the overscan of these outputs.
* Keep the phone charging. The Digital AV adapter and the composite/component cables all have a USB charging lead.

The iPhone 4 **can't mirror its screen** (that came with the 4S). iBox draws its own interface on
the adapter's external screen instead, using the iOS external-display API, and turns the phone's
screen into a remote. Without an adapter, the TV interface is shown rotated on the phone itself
("preview").

## First steps

1. Plug in the adapter and start iBox. It also starts on boot and relaunches itself if it crashes.
2. Open the address shown at the top of the TV (`http://192.168.x.x:8080`) on your phone to get the web remote.
3. Open **Settings** (on the TV, or *Accounts & options* in the web remote) for:
   * **Jellyfin.** Pick a discovered server, or enter `http://server:8096`, then your user and password.
   * **YouTube Data API key**, optional. YouTube search works without one; a key gives the
     official "most popular" charts. Create one at console.cloud.google.com → *APIs & Services* →
     enable *YouTube Data API v3* → *Credentials*.
   * **Spotify client ID and secret**, optional, for Spotify search. Create an app at developer.spotify.com.
     Opening Spotify links works without it.
   * **Live TV playlist**, **country code** and **weather location**, if the automatic choices are wrong.

### YouTube playback

Videos play in **YouTube's official embedded player**, running in a web view on the TV. That is
the same player websites embed, so nothing imitates YouTube's apps or gets around its checks.
Three things make it run on iOS 6:

* `res/ytshim.js` fills in the browser features iOS 6's WebKit lacks: `queueMicrotask`, `fetch`,
  `URL`, `TextEncoder` and others. It also fixes iOS 6's XHR, which sent typed arrays as the text
  "[object Uint8Array]".
* The embed is loaded with `Referer: https://com.ibox.tv`. That is the app identity Google's
  documentation asks web-view embeds to send; without it the player shows "Video player
  configuration error".
* `res/msebridge.js` gives the page the MediaSource that iOS 6 lacks, so the player can use its
  480p/720p streams (see below). Without it the player only has YouTube's 360p MP4.

The A4 has no JavaScript JIT, so YouTube's player takes 30–60 s to start from scratch. iBox
builds it in the background about 20 s after launch and keeps it alive between videos, so a video
normally starts in a few seconds. Ads play like on any embed. The player has to stay visible
(YouTube's terms), so Spotify tracks show their music video.

**480p / 720p: the MediaSource bridge.** YouTube serves its higher qualities as separate video
and audio streams that the player joins through MediaSource, which iOS 6's WebKit doesn't have;
without it the embed offers only its 360p MP4. Taking those streams out of the player to play
them ourselves would bypass YouTube's player and break its terms, so iBox does the opposite:
it gives the page the missing browser feature and leaves everything else to YouTube's player
(choosing and fetching streams, ads, quality, captions).

* `res/msebridge.js` defines `MediaSource` / `SourceBuffer`. It accepts only what the A4
  decodes (H.264 Baseline/Main up to level 3.1, AAC-LC), so the player picks those streams.
  Whatever the player appends is posted to iBox, and `URL.createObjectURL(mediaSource)` returns
  an HLS address on iBox, which the page's own `<video>` plays natively.
* `src/IBMSE.m` parses the fragmented MP4 (init segments, `moof`/`mdat`, edit lists), keeps the
  samples and reports buffered ranges back. It serves them as a VOD HLS playlist of MPEG-TS
  segments: H.264 in Annex B with SPS/PPS per keyframe (kept per frame, since the player can
  switch quality inside one stream), AAC with ADTS headers. Segments are cut on keyframes, about
  every 6 s:
  * a segment waits until the player has appended its data;
  * a stretch inside a long keyframe interval repeats that group of pictures, so a seek always
    starts on a picture;
  * a stream that starts mid-video (resume, seek, quality switch) is anchored on its first
    keyframe, with silence before it. The bridge then moves the `<video>` there, because iOS 6
    ignores a seek made before the video has loaded;
  * video already played is freed (about 15 MB stays in memory for 720p).
* Seeking reloads the video at the new time (`loadVideoById({videoId, startSeconds})`); YouTube's
  player then starts a fresh stream there, playing within about 5–10 s. Remote presses in a row
  are combined into one seek.
* Videos whose H.264 versions stop at 240p (their higher qualities exist only in VP9/AV1)
  switch to YouTube's 360p MP4. If the bridge fails for a video (media error, or no progress for
  40 s), the video restarts at 360p where it was. After three failures the bridge is off until
  iBox restarts; setting `youtubeHD` to `0` turns it off for good.
* The player's quality choice (Options › Quality) is remembered and requested before each video
  loads. The on-screen bar shows the current quality ("YouTube • 720p").
* On the TV, iOS shows web video in a window of its own (`MPTVOutWindow`) above iBox's, so
  the YouTube info bar, options panel, messages and captions are drawn in a transparent window
  above it (`-[IBTV chrome]`); captions are copied from YouTube's player into that layer.
* The iPhone 4's HLS reports 720p streams as 853×480 (as for live TV); the decoder receives the
  720p stream.

Investigation notes (November 2026): no HLS for regular videos from the embed; presenting the
web view as a newer iPhone (iOS 9 / 12) gives the same formats; as iOS 16, YouTube sends a modern
(ES6) player that iOS 6 can't run.

### Spotify

Spotify's full-length audio is DRM-protected and has no client for iOS 6. iBox reads the catalog
from Spotify's public embed pages and the Web API. Each track then plays in full as its YouTube
video, found by "artist title" and shown with Spotify's title and artist. Spotify's 30-second
preview is used only when YouTube has no match.

### Live TV channels

Free IPTV lists mix in many streams the iPhone 4 can't play. Before playing an HLS channel,
iBox checks the actual stream (`src/IBStreamProbe.m`):
1. its playlist;
2. the variant iOS will start with;
3. that variant's segment format: fragmented MP4/CMAF needs iOS 10, and SAMPLE-AES is DRM;
4. the first 256 KB of a real segment. iBox reads its MPEG-TS stream types (HEVC, MPEG-2,
   Dolby-only audio) and the H.264 header, which gives the exact profile and level.

What this means for you:
* Channels that are **blocked or offline** (HTTP 403/404, often geo-locked) fail at once with that reason.
* Channels that **only** offer 1080p, 720p at 50/60 fps, H.264 High profile, HEVC, CMAF and so on fail at once with "the iPhone 4 can't decode".
* For mixed channels, the proxy hides the incompatible variants and plays a compatible one.
  For example, C Star plays its Baseline 288p variant.
* Long live windows (hours of DVR) are trimmed to the newest ~45 s, so the A4 keeps up.

The proxy sends per-channel `http-user-agent` / `http-referrer` (and `#EXTVLCOPT`) headers.
A failing channel no longer skips to the next one.

Every playlist (`.m3u8`) goes through the proxy, which adapts it to iOS 6. The video itself is
never touched. iOS 6 refuses HLS playlists above protocol version 4, while BFM, MediaTailor
streams and others use versions 6–7, so the proxy:
* relabels the version when no newer features are used;
* drops WebVTT subtitle, closed-caption, I-frame, low-latency and ad-marker lines;
* keeps only one audio rendition (the one chosen in the player's options, else the default);
* drops `#EXT-X-DISCONTINUITY-SEQUENCE`: iOS 6 reads it as a plain `#EXT-X-DISCONTINUITY`,
  which reset the timeline at every reload of a live playlist. The picture jumped back every
  few seconds and segments were fetched twice or skipped (RMC Découverte and other
  MediaTailor channels);
* raises `#EXT-X-TARGETDURATION` when segments are longer than announced.

Plain-HTTP segments are still fetched directly.

The iPhone 4 has a single hardware video decoder. When the YouTube player stops, iBox empties
its `<video>` element, so TV channels and Jellyfin always find the decoder free.

When a channel list opens, iBox checks every channel in the background, three at a time. The
title shows "checking 45/199". The check pauses while a video is on screen. Channels that can't
play disappear from the list, and **Show N hidden channels** at the bottom lists them with the
reason, so you can still try them. Results are cached on the phone, so the next visit opens
already filtered:
* playable and can't-decode results are kept for 3 days;
* offline/blocked results for 12 hours;
* unreachable results for 2 hours.

To see which channels of a list work, the sweep tool makes the phone itself probe and then
really play every channel, writing a JSON report:

```bash
python tools/sweep_channels.py http://192.168.1.128:8080 https://iptv-org.github.io/iptv/countries/fr.m3u sweep.json
```

`tools/check_m3u.py` does a quicker check from a computer, playlist level only.

### Player options

Press **Down** (or Info, or **Options** on the iPhone remote / web remote) while a video plays. The web remote reloads itself after iBox is updated, so its buttons are always current. ↑ ↓ pick a row,
← → change it. A change applies after a short pause, so you can step through choices without
restarting the stream each time. OK or Back closes the panel.

| Row | Where | How |
|---|---|---|
| Audio | HLS channels with several languages | The proxy keeps the chosen rendition (iOS 6 gets one at a time); the stream restarts. |
| Audio | Files with several audio tracks | Switches the track in place. |
| Audio | Jellyfin | Restarts with the chosen `AudioStreamIndex`, at the same position. |
| Subtitles | Jellyfin | Text subtitles are drawn by iBox, instantly. Picture subtitles restart the stream with the server burning them in. |
| Subtitles | YouTube | YouTube's own captions, larger than default. The language is remembered for the next videos. |
| Quality | HLS | Auto or a maximum height (the proxy filters the variants); the stream restarts. |
| Quality | Jellyfin | 4 / 2 / 1 / 0.5 Mbps (the server transcodes when needed). |
| Quality, Speed, Audio | YouTube | What YouTube's player offers for that video (up to 720p through the bridge). Quality is remembered. |
| Picture | Everything but YouTube | Fit, Fill (crops the edges) or Stretch. Remembered. |

### Video formats

The A4 decodes **H.264 Main/Baseline up to 720p30** with AAC or MP3 audio, in MP4 or HLS. It
can't decode H.264 High profile, HEVC, VP9 or AV1. Jellyfin transcodes for you. Direct links in
other formats show "format not supported by the iPhone 4".

## Build and install (from Windows with WSL, or Linux)

```bash
bash tools/setup-toolchain.sh        # once: Theos Linux toolchain + iOS 10.3/9.3 SDKs into ~/ibox-tc
bash build.sh                        # -> dist/ibox.deb and dist/iBox.app
bash deploy.sh                       # scp + dpkg -i + launch over SSH (root@iphone4 by default)
```

`build.sh` needs `ldid`, `openssl` and `dpkg-deb`. It builds BearSSL once, compiles with ARC
for `armv7-apple-ios6.0`, and generates a self-signed certificate for the HTTPS cast page.

**Over USB** (when the phone's Wi-Fi sleeps), forward ports through Apple Mobile Device Service:

```bash
python tools/usbproxy.py 22022:22 28080:8080
```

```bash
IBOX_HOST=root@127.0.0.1 IBOX_PORT=22022 bash deploy.sh
```

The package installs `/Applications/iBox.app`, `/usr/bin/ibox-launch` and the
`com.ibox.watchdog` LaunchDaemon. The watchdog runs outside the app and:
* brings iBox back whenever the phone is on its home screen (after a crash or reboot);
* pings iBox every 15 s while it is on screen, and restarts it if it stays frozen for about a minute;
* serves a restart page at `http://<iphone-ip>:8081`. It works even when iBox is frozen,
  since iBox's own remote lives inside the app.

To restart iBox by hand, use **Restart iBox** in the web remote (bottom), in Settings on the
TV, or on the 8081 page. From SSH, run `ibox-launch --restart`. To turn the watchdog off:

```bash
launchctl unload /Library/LaunchDaemons/com.ibox.watchdog.plist
```

## HTTP API (port 8080)

| Endpoint | Purpose |
|---|---|
| `GET /` | Web remote |
| `GET /cast` | Screen cast page (use the HTTPS port 8443) |
| `GET /api/state` | Page, focus, prompt, player (with its open options panel), battery, last message |
| `POST /api/key` | `{"key": "up|down|left|right|select|back|home|playpause|next|prev|info"}` |
| `POST /api/text` | `{"text": "...", "submit": true}`: types into the TV's text prompt |
| `POST /api/cast` | `{"url": "..."}`: plays or opens any supported link |
| `POST /api/search` | `{"service": "youtube|jellyfin|spotify|radio", "q": "..."}` |
| `POST /api/player` | `{"action": "playpause|stop|next|prev|seek|seekby|show", "value": 30}` |
| `POST /api/volume` | `{"delta": 0.1}` |
| `GET/POST /api/settings` | Read or save settings (secrets are never returned) |
| `POST /api/screen/frame` | JPEG body: shows one frame of a screen cast |
| `POST /api/vnc` | `{"spec": "host[:port] [password]"}` |
| `GET /proxy?u=` | Media proxy: modern TLS, byte ranges, HLS rewriting, drops variants above 720p |
| `GET /api/screenshot.png` | Picture of the TV interface (the video layer isn't captured) |
| `GET /api/debug/fetch?u=` | Fetches a URL with iBox's HTTP/TLS stack (diagnostics) |
| `POST /api/debug/probe` | `{"url", "headers"}`: runs the stream check and returns the verdict |
| `POST /api/debug/play` | `{"url", "headers", "title"}`: plays a stream like a Live TV channel |
| `GET /api/debug/web?u=&ref=` | Opens a page in a web view on the TV |
| `GET /api/debug/js?c=` | Runs JavaScript in that web view, or in the YouTube player |
| `GET /api/debug/proxylog` | The last 200 proxied requests: file, time taken, bytes, playlist sequence numbers |
| `GET /api/debug/hls?flags=` | Playlist experiments: `nopdt`, `nodiscseq`, `td=N`, `keep=N`, `onevariant` (clears the log) |
| `GET /api/debug/captions?u=` | Draws subtitles from a WebVTT/SRT URL over the current video (`/debug/sample.vtt` is a test track) |
| `GET /api/debug/ua?ua=` | Restarts iBox with another web-view user agent (empty = default) |
| `GET /api/debug/mse` | MediaSource bridge sessions: buffered ranges, codecs, segment log |
| `GET /api/debug/videolayers` | Video layers on screen (web video too): drawing frames, time, size, URL |
| `GET /api/debug/bridge` | Installs the shim and the MediaSource bridge in the `/api/debug/web` page |
| `POST|GET /mse/<id>/…` | The bridge itself (append, remove, duration, eos; `index.m3u8`, `seg<n>.ts`) |

## How it's built

```
src/IBApp.m              app delegate, external screen (TV) handling, iPhone remote/trackpad
src/IBTV.m               10-foot UI: pages, cards, spatial focus navigation, prompts, toasts
src/IBPlayer.m           AVPlayer + OSD + queue + now-playing screen
src/IBCore.m             items/pages/media models, settings, image loader
src/IBServices.m         home, settings, weather, link router, Radio, Live TV
src/IBRemoteAPI.m        HTTP routes, web remote API, media proxy with HLS rewriting
src/net/ibnet.c          TCP + BearSSL TLS (client and server)
src/net/IBHTTP.m         HTTP/1.1 client and threaded HTTP server
src/IBStreamProbe.m      stream check: playlist, variant, segment format, TS / H.264 header
src/services/*.m         Jellyfin, YouTube (embedded player), Spotify, Screen share (cast + VNC)
src/launcher/            ibox-launch (SpringBoardServices launcher / watchdog)
res/                     Info.plist, web remote, cast page, ytshim.js, CA bundle, icons
tools/                   usbproxy, toolchain setup, icon generator, VNC test server, channel sweep
third_party/bearssl-0.6  BearSSL (MIT)
```

iOS 6's own TLS stack fails against many current servers (no AES-GCM or ChaCha20, outdated
root certificates). So every HTTPS request goes through BearSSL with Mozilla's CA bundle. Media
that AVPlayer would fetch over such HTTPS is routed through the local proxy instead. Google's
servers still work with iOS 6 TLS, so they are streamed directly.
