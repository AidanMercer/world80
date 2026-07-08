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
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

CACHE_DIR = os.path.expanduser("~/.cache/lyricvis")
UA = "lyricvis/0.1 (https://github.com/AidanMercer/world80)"
# a "no lyrics found" hit is only trusted this long — LRCLIB/AMLL fill lyrics in
# after the fact, so an empty result gets re-checked instead of sticking forever.
NEG_TTL_S = 14 * 86400
LRCLIB = "https://lrclib.net"
# AMLL community word-level TTML DB, keyed by spotify track id. Coverage is thin
# (CJK-skewed, ~thousands of entries) so this is an OPPORTUNISTIC source above
# LRCLIB: a hit yields real per-word onsets, a miss (the common case) falls
# straight through to LRCLIB line-level.
AMLL = "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main"

_STAMP = re.compile(r"\[(\d+):(\d+)(?:[.:](\d+))?\]")
_SPOTIFY_ID = re.compile(r"^[0-9A-Za-z]{22}$")


def spotify_id_of(raw):
    """'spotify:track:XXXX' or a bare 22-char base62 id -> the id, else ''."""
    if not raw:
        return ""
    s = raw.split("spotify:track:")[-1].strip()
    return s if _SPOTIFY_ID.match(s) else ""


# --- parenthetical adlibs ----------------------------------------------------
# Background adlibs like "(yeah)" are pulled out of the MAIN line so they never
# charge it timing budget, but kept IN SOURCE ORDER (interleaved) so the renderer
# can anchor each one to the word it follows. They sometimes ARE on the beat, so
# we don't drop them — just flag them bg and give them zero main-vocal weight.
_PAREN = re.compile(r"\(([^()]*)\)")
# structural repeat markers, not adlibs: "(x2)", "(2x)", "(repeat)"
_DROP = re.compile(r"^\s*(?:x\s*\d+|\d+\s*x|repeat.*)\s*$", re.I)
_PUNCT_ONLY = re.compile(r"^[^0-9A-Za-zÀ-￿]+$")


def split_adlibs(text):
    """Ordered token list [{'text','bg'}] preserving source position. Parenthetical
    runs become bg tokens; everything else is a main token. Main tokens carry no
    parens, so the main line's syllable budget excludes adlibs entirely."""
    tokens = []
    pos = 0

    def add_main(chunk):
        for w in re.split(r"\s+", chunk):
            if w and not _PUNCT_ONLY.match(w):
                tokens.append({"text": w, "bg": False})

    for m in _PAREN.finditer(text):
        add_main(text[pos:m.start()])
        inner = m.group(1).strip()
        if inner and not _DROP.match(inner):
            tokens.append({"text": inner, "bg": True})
        pos = m.end()
    add_main(text[pos:])
    # a wholly-parenthetical line ("(You got it, mag)") has no main words; promote
    # its adlibs to main so the line still gets a normal span instead of stacking.
    if tokens and all(t["bg"] for t in tokens):
        for t in tokens:
            t["bg"] = False
    return tokens


# --- enhanced-LRC inline word tags (A2 extension; LRCLIB rarely emits them) ---
_WORD_TAG = re.compile(r"<(\d+):(\d+)(?:[.:](\d+))?>")


def _stamp_ms(mm, ss, frac):
    ms = round(float("0." + frac) * 1000) if frac else 0
    return int(mm) * 60000 + int(ss) * 1000 + ms


def parse_enhanced_line(raw):
    """(line_t, [{t,text}]) if the line carries inline <mm:ss.xx> word tags, else
    None. These give real per-word onsets (no durations)."""
    lm = list(_STAMP.finditer(raw))
    if not lm:
        return None
    body = raw[lm[-1].end():]
    tags = list(_WORD_TAG.finditer(body))
    if not tags:
        return None
    line_t = _stamp_ms(lm[0].group(1), lm[0].group(2), lm[0].group(3) or "")
    words = []
    lead = body[:tags[0].start()].strip()
    if lead:
        words.append({"t": line_t, "text": lead})
    for i, m in enumerate(tags):
        seg_end = tags[i + 1].start() if i + 1 < len(tags) else len(body)
        txt = body[m.end():seg_end].strip()
        if txt:
            words.append({"t": _stamp_ms(m.group(1), m.group(2), m.group(3) or ""),
                          "text": txt})
    return (line_t, words)


# --- AMLL TTML (word-level, above LRCLIB) ------------------------------------
# Time strings are not uniform: 'SS.mmm', 'M:SS.mmm', 'MM:SS.xxx', 'HH:MM:SS.xxx',
# '.' or ':' fraction separator. Right-anchor seconds; the optional groups are
# (hours?)(minutes?)seconds.
_TIME = re.compile(r"^(?:(\d+):)?(?:(\d+):)?(\d+)(?:[.:](\d+))?$")


def ttml_ms(s):
    m = _TIME.match((s or "").strip())
    if not m:
        return None
    a, b, c, frac = m.groups()
    sec, mn, hr = int(c), int(b) if b else 0, int(a) if a else 0
    if b is None and a is not None:      # 'M:SS' -> a is minutes, not hours
        mn, hr = int(a), 0
    ms = round(float("0." + frac) * 1000) if frac else 0
    return ((hr * 60 + mn) * 60 + sec) * 1000 + ms


def _localname(tag):
    return tag.rsplit("}", 1)[-1]


def _role(el):
    for k, v in el.attrib.items():
        if _localname(k) == "role":
            return v
    return None


def _ttml_spans(el, bg, out):
    """Depth-aware walk: a leaf <span begin>word</span> is a word; an x-bg ancestor
    marks its whole subtree as background; x-translation / x-roman spans are skipped
    with their subtree. Nesting is honoured via the tree, so a background adlib can
    never swallow the lead-vocal spans that follow it on the same line."""
    for span in el:
        if _localname(span.tag) != "span":
            continue
        role = _role(span)
        if role in ("x-translation", "x-roman"):
            continue
        child_bg = bg or (role == "x-bg")
        if any(_localname(c.tag) == "span" for c in span):
            _ttml_spans(span, child_bg, out)
            continue
        txt = (span.text or "").strip()
        b = ttml_ms(span.get("begin"))
        if not txt or b is None:
            continue
        if child_bg and len(txt) > 2 and txt[0] == "(" and txt[-1] == ")":
            txt = txt[1:-1].strip()      # store bare text; the renderer re-wraps
        w = {"t": b, "text": txt}
        e = ttml_ms(span.get("end"))
        if e is not None and e > b:
            w["d"] = e - b
        if child_bg:
            w["bg"] = True
        out.append(w)


def parse_ttml(xml):
    try:
        root = ET.fromstring(xml)
    except ET.ParseError:
        return []
    lines = []
    for p in root.iter():
        if _localname(p.tag) != "p":
            continue
        lt = ttml_ms(p.get("begin"))
        if lt is None:
            continue
        words = []
        _ttml_spans(p, False, words)
        if not words:                    # <p> with plain text, no word spans
            txt = (p.text or "").strip()
            if txt:
                words = [{"t": lt, "text": txt}]
        if not words:
            continue
        words.sort(key=lambda w: w["t"])
        text = " ".join(w["text"] for w in words if not w.get("bg"))
        if not text:                     # wholly-background line -> promote to main
            for w in words:
                w.pop("bg", None)
            text = " ".join(w["text"] for w in words)
        lines.append({"t": lt, "text": text, "words": words})
    lines.sort(key=lambda x: x["t"])
    return lines


def http_text(url, attempts=2, timeout=12):
    last = None
    for _ in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError:
            raise            # 404 is a real "not in AMLL" answer
        except Exception as e:
            last = e
    raise last


def fetch_amll(sid):
    """Parsed word-level lines from AMLL, or None if not present / unparseable.
    Short timeout + single attempt so a slow CDN never holds up the LRCLIB path."""
    if not sid:
        return None
    try:
        xml = http_text(f"{AMLL}/spotify-lyrics/{sid}.ttml", attempts=1, timeout=6)
    except urllib.error.HTTPError:
        return None
    return parse_ttml(xml) or None


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


def artist_variants(artist):
    """The full credit, then narrower fallbacks: LRCLIB matches on a single
    primary artist, so "A, B", "A & B", "A feat. B" won't hit with the whole
    string but "A" will. Returns de-duped candidates, widest first."""
    out, seen = [], set()
    for v in (artist, re.split(r"\s*(?:,|&|/|\bfeat\.?\b|\bft\.?\b|\bx\b|×|\bwith\b)\s*",
                              artist, flags=re.I)[0]):
        v = v.strip()
        if v and v.lower() not in seen:
            seen.add(v.lower()); out.append(v)
    return out


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
    # fuzzy search fallback: try the full artist, then the primary artist alone
    # (multi-artist / producer credits don't match LRCLIB's artist filter).
    results = []
    for art in artist_variants(a.artist):
        q2 = urllib.parse.urlencode({"track_name": a.title, "artist_name": art})
        results = http_json(f"{LRCLIB}/api/search?{q2}")
        if isinstance(results, list) and results:
            break
    if not isinstance(results, list) or not results:
        return None
    # prefer synced, then the closest duration to the playing track
    results.sort(key=lambda r: (0 if r.get("syncedLyrics") else 1,
                                abs((r.get("duration") or 0) - want)))
    return results[0]


def normalize_amll(lines, key, sid):
    return {"id": key, "source": "amll", "amllId": sid,
            "synced": bool(lines), "instrumental": False,
            "wordLevel": True, "lines": lines, "plain": ""}


def normalize(data, key):
    """LRCLIB path. Now adlib-aware and word-emitting: every line carries a
    words[] (main tokens + bg adlib tokens, in source order) and `text` is the
    adlib-free main line. Old line-level consumers ignore the extra keys."""
    if not data:
        return {"id": key, "source": "lrclib", "synced": False,
                "instrumental": False, "wordLevel": False, "lines": [], "plain": ""}
    synced = data.get("syncedLyrics") or ""
    lines = []
    for raw in synced.splitlines():
        if not _STAMP.search(raw):
            continue
        enh = parse_enhanced_line(raw)
        if enh:                              # real inline word onsets (rare)
            lt, ws = enh
            lines.append({"t": lt, "text": " ".join(w["text"] for w in ws),
                          "words": ws})
            continue
        # one {t,text} per stamp on the line (multi-stamp lines repeat the text),
        # each adlib-split into interleaved main/bg word tokens.
        for ln in parse_lrc(raw):
            toks = split_adlibs(ln["text"])
            words = []
            for t in toks:
                w = {"t": ln["t"], "text": t["text"]}
                if t["bg"]:
                    w["bg"] = True
                words.append(w)
            text = " ".join(t["text"] for t in toks if not t["bg"])
            lines.append({"t": ln["t"], "text": text, "words": words})
    lines.sort(key=lambda x: x["t"])
    return {
        "id": key,
        "lrclibId": data.get("id"),
        "source": "lrclib",
        "synced": bool(lines),
        "instrumental": bool(data.get("instrumental")),
        # any word carrying a distinct onset or a duration => real per-word timing
        "wordLevel": any(("d" in w) or (w.get("t") != L["t"])
                         for L in lines for w in L.get("words", [])),
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
            "instrumental": False, "wordLevel": False, "lines": [], "plain": ""}
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
    # Found lyrics + confirmed-instrumental are kept forever; a plain "not found"
    # is re-checked after NEG_TTL_S, since a track often gets lyrics added later.
    if not a.force and os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as f:
                cached = json.load(f)
            missing = not cached.get("lines") and not cached.get("plain")
            stale = (missing and not cached.get("instrumental")
                     and time.time() - os.path.getmtime(path) > NEG_TTL_S)
            if not stale:
                emit(cached, a.id)
                return
        except (OSError, ValueError):
            pass

    if not a.title:
        emit(empty(key, error="no title"), a.id)
        return

    try:
        # AMLL word-level first (opportunistic), then LRCLIB line-level. The AMLL
        # attempt is isolated: a 404 or any transport error there degrades to
        # LRCLIB rather than blocking it — LRCLIB stays the real path.
        sid = spotify_id_of(a.id)
        amll = None
        if sid:
            try:
                amll = fetch_amll(sid)
            except Exception:
                amll = None
        result = normalize_amll(amll, key, sid) if amll else normalize(fetch(a), key)
    except Exception as e:
        # LRCLIB network/transport error — emit empty but DON'T cache, so it retries
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
