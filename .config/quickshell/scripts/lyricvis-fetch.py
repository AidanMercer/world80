#!/usr/bin/env python3
"""Fetch + cache synced lyrics for the desktop lyric visualizer.

Shared by every theme's lyrics.qml (called over a Process). Given track
metadata it walks the source ladder, normalizes to a compact JSON the renderer
can consume directly, caches it under ~/.cache/lyricvis/<key>.json, and prints
it to stdout. Cache hit → print and exit (one fetch per track, ever).

Source: LRCLIB (line-level, no auth). /api/get exact match first, then
/api/search as a fallback. Network errors are NOT cached (so they retry);
"no lyrics found" IS cached (clear the cache dir if you want to re-look).

Output shape:
  {"id","lrclibId","source","synced","instrumental",
   "lines":[{"t": <ms int>, "text": str}, ...], "plain": str}
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

CACHE_DIR = os.path.expanduser("~/.cache/lyricvis")
UA = "lyricvis/0.1 (https://github.com/AidanMercer/hypr-dots)"
LRCLIB = "https://lrclib.net"

_STAMP = re.compile(r"\[(\d+):(\d+)(?:[.:](\d+))?\]")


def cache_key(a):
    if a.id:
        k = re.sub(r"[^A-Za-z0-9_.-]", "_", a.id)
        if k:
            return k
    raw = f"{a.artist}|{a.title}|{a.album}|{a.duration}".lower()
    return "h" + hashlib.sha1(raw.encode()).hexdigest()[:16]


def parse_lrc(synced):
    """[mm:ss.xx] text  ->  [{t: ms, text}], sorted. Repeated stamps on one
    line all map to the same text. Blank-text lines are kept as gap markers."""
    out = []
    for raw in synced.splitlines():
        stamps = list(_STAMP.finditer(raw))
        if not stamps:
            continue
        text = raw[stamps[-1].end():].strip()
        for m in stamps:
            mm, ss = int(m.group(1)), int(m.group(2))
            frac = m.group(3) or ""
            # frac is hundredths or thousandths depending on the file
            ms = round(float("0." + frac) * 1000) if frac else 0
            out.append({"t": mm * 60000 + ss * 1000 + ms, "text": text})
    out.sort(key=lambda x: x["t"])
    return out


def http_json(url, attempts=2, timeout=12):
    last = None
    for _ in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError:
            raise  # 404 etc. are real answers, not worth retrying
        except Exception as e:
            last = e
    raise last


def fetch(a):
    try:
        want = float(a.duration)
    except (TypeError, ValueError):
        want = 0.0
    # /api/get is an exact match — it needs all four fields and 400s on a missing
    # album. Only attempt it when we have album+duration; any HTTP answer (404
    # not-found, 400 bad-args) just means "fall through to fuzzy search".
    if a.album and want:
        q = urllib.parse.urlencode({
            "artist_name": a.artist, "track_name": a.title,
            "album_name": a.album, "duration": a.duration,
        })
        try:
            return http_json(f"{LRCLIB}/api/get?{q}")
        except urllib.error.HTTPError:
            pass
    # fuzzy search fallback, prefer synced + closest duration
    q2 = urllib.parse.urlencode({"track_name": a.title, "artist_name": a.artist})
    results = http_json(f"{LRCLIB}/api/search?{q2}")
    if not isinstance(results, list) or not results:
        return None
    results.sort(key=lambda r: (0 if r.get("syncedLyrics") else 1,
                                abs((r.get("duration") or 0) - want)))
    return results[0]


def normalize(data, key):
    if not data:
        return {"id": key, "source": "lrclib", "synced": False,
                "instrumental": False, "lines": [], "plain": ""}
    synced = data.get("syncedLyrics") or ""
    lines = parse_lrc(synced) if synced else []
    return {
        "id": key,
        "lrclibId": data.get("id"),
        "source": "lrclib",
        "synced": bool(lines),
        "instrumental": bool(data.get("instrumental")),
        "lines": lines,
        "plain": data.get("plainLyrics") or "",
    }


def emit(obj, reqid):
    """Print exactly one JSON object, stamped with the caller's raw request id so
    the renderer can match a result to the track still on screen (and ignore a
    late result for a track it has skipped past)."""
    obj = dict(obj)
    obj["reqId"] = reqid
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))


def empty(key, **extra):
    base = {"id": key, "source": "lrclib", "synced": False,
            "instrumental": False, "lines": [], "plain": ""}
    base.update(extra)
    return base


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--id", default="")
    p.add_argument("--artist", default="")
    p.add_argument("--title", default="")
    p.add_argument("--album", default="")
    p.add_argument("--duration", default="")
    p.add_argument("--force", action="store_true")
    a = p.parse_args()

    key = cache_key(a)
    path = os.path.join(CACHE_DIR, key + ".json")

    # cache hit — re-stamp reqId for the live track. A torn/unreadable file just
    # falls through to a fresh fetch (self-healing alongside the atomic write).
    if not a.force and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                emit(json.load(f), a.id)
            return
        except (OSError, ValueError):
            pass

    if not a.title:
        emit(empty(key, error="no title"), a.id)
        return

    try:
        result = normalize(fetch(a), key)
    except Exception as e:
        # network/transport error — emit empty but DON'T cache, so it retries
        emit(empty(key, error=str(e)), a.id)
        return

    # cache atomically: a kill mid-write must never leave a sticky bad hit
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=CACHE_DIR, suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(result, ensure_ascii=False))
        os.replace(tmp, path)
    except OSError:
        pass
    emit(result, a.id)


if __name__ == "__main__":
    main()
