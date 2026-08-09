#!/usr/bin/env python3
"""
hit_rate.py — measure how often a mirror's FILENAME gives us a usable comic title.

Question this answers
---------------------
StripZona posts label issues by code (MN_LMS_518), never by title. The mirror
filename usually carries the title ("LMS 518 - Mister No - Bubnjevi u dzungli").
If that holds at a high rate, the stripovi.com encyclopedia harvest is optional
enrichment. If it doesn't, the harvest is on the critical path.

SAFETY — read this before running
---------------------------------
  * ZERO requests are made to stripzona.com. Nothing is logged in. Nothing is
    liked. The forum account is never exposed. Input is HTML you saved from
    your own browser, from posts you had ALREADY unlocked.
  * Only MediaFire (and optionally Mega) are contacted, serially, with a
    jittered delay, a hard request cap, and backoff on 429/503.
  * Every resolution is cached to disk. Re-runs cost zero requests, so you can
    iterate on the title parser for free.
  * The comic files themselves are NEVER downloaded. We read a redirect header
    (a few hundred bytes). There is an explicit guard against ever requesting a
    download*.mediafire.com URL.

Usage
-----
  1. In your browser, open a few StripZona topics you have already liked, so the
     links are visible. Save each as "Web Page, HTML only" into ./pages/.
     Aim for 5-10 pages across DIFFERENT editions and DIFFERENT scanners --
     a sample from one uploader will flatter the result.

  2. python3 hit_rate.py --pages ./pages

     Options:
       --urls links.txt     also read bare mirror URLs, one per line
       --max-requests 150   hard cap on network calls        (default 150)
       --delay 2.5          seconds between requests, jittered (default 2.5)
       --dry-run            parse + report corpus, make no requests
       --no-mega            skip Mega resolution
       --cache cache.json   resolution cache path

Output
------
  Console report + results.csv for eyeballing.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
import re
import struct
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from html import unescape

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")

# MN_LMS_518, ZS_1234, VC_SD_12 ... letters/digits groups joined by underscores,
# ending in the issue number. Deliberately loose: skins change, this shouldn't.
ISSUE_CODE_RE = re.compile(r"\b([A-ZČĆŠŽĐ]{1,5}(?:_[A-ZČĆŠŽĐ0-9]{1,6}){0,3}_\d{1,5})\b")

MEDIAFIRE_RE = re.compile(r"https?://(?:www\.)?mediafire\.com/[^\s\"'<>\]]+", re.I)
MEGA_RE = re.compile(r"https?://mega(?:\.co)?\.nz/[^\s\"'<>\]]+", re.I)

ARCHIVE_EXT_RE = re.compile(r"\.(cbr|cbz|rar|zip|7z|pdf)$", re.I)
SCANNER_TAG_RE = re.compile(r"\s*[\(\[][^)\]]{1,40}[\)\]]\s*$")
# "LMS 518", "LMS - 518", "LMS518", "518"
EDITION_NUM_RE = re.compile(r"^\s*([A-Za-zČĆŠŽĐčćšžđ]{1,6})?\s*-?\s*(\d{1,5})\s*$")


# ---------------------------------------------------------------- corpus


def harvest_from_html(text: str) -> list[tuple[str | None, str]]:
    """Return [(issue_code_or_None, mirror_url)] from one saved topic page.

    Works on the visible text rather than CSS selectors, so an IPB skin change
    doesn't break it. Each URL is attributed to the nearest issue code that
    appears BEFORE it, which matches how the posts are laid out (red bold label,
    then that issue's code boxes).
    """
    text = re.sub(r"(?is)<(script|style).*?</\1>", " ", text)
    plain = unescape(re.sub(r"(?s)<[^>]+>", "\n", text))

    marks: list[tuple[int, str, str]] = []  # (pos, kind, value)
    for m in ISSUE_CODE_RE.finditer(plain):
        marks.append((m.start(), "code", m.group(1)))
    for rx in (MEDIAFIRE_RE, MEGA_RE):
        for m in rx.finditer(plain):
            marks.append((m.start(), "url", m.group(0).rstrip(".,;")))
    marks.sort()

    out: list[tuple[str | None, str]] = []
    current: str | None = None
    for _, kind, value in marks:
        if kind == "code":
            current = value
        else:
            out.append((current, value))
    return out


def load_corpus(pages_dir: str | None, urls_file: str | None):
    pairs: list[tuple[str | None, str]] = []
    if pages_dir:
        if not os.path.isdir(pages_dir):
            sys.exit(f"error: --pages directory not found: {pages_dir}")
        # Safari appends " 2" AFTER the extension on duplicate saves, so match
        # ".htm" anywhere in the name rather than requiring it at the end.
        names = sorted(n for n in os.listdir(pages_dir)
                       if ".htm" in n.lower()
                       and os.path.isfile(os.path.join(pages_dir, n)))
        if not names:
            sys.exit(f"error: no .html files in {pages_dir}. Save some topic "
                     f"pages from your browser first (see docstring).")
        for name in names:
            path = os.path.join(pages_dir, name)
            with open(path, encoding="utf-8", errors="replace") as fh:
                found = harvest_from_html(fh.read())
            print(f"  {name}: {len(found)} mirror links")
            pairs += found
    if urls_file:
        with open(urls_file, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    pairs.append((None, line))

    seen, uniq = set(), []
    for code, url in pairs:
        if url not in seen:
            seen.add(url)
            uniq.append((code, url))
    return uniq


# ---------------------------------------------------------------- fetching


class Fetcher:
    """Serial, throttled, capped, cached. Deliberately unclever."""

    def __init__(self, cache_path, delay, max_requests, dry_run):
        self.cache_path = cache_path
        self.delay = delay
        self.max_requests = max_requests
        self.dry_run = dry_run
        self.used = 0
        self.consecutive_errors = 0
        self.cache = {}
        if os.path.exists(cache_path):
            with open(cache_path, encoding="utf-8") as fh:
                self.cache = json.load(fh)
            print(f"  cache: {len(self.cache)} previously resolved links")

        opener_cls = type("NoRedirect", (urllib.request.HTTPRedirectHandler,),
                          {"redirect_request": lambda *a, **k: None})
        self.opener = urllib.request.build_opener(opener_cls())

    def save(self):
        tmp = self.cache_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.cache, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, self.cache_path)

    def budget_left(self):
        return self.max_requests - self.used

    def _pause(self):
        time.sleep(self.delay * random.uniform(0.6, 1.4))

    def raw(self, url, method="GET", data=None, headers=None, read_bytes=0):
        """One HTTP call. Returns (status, headers, body_bytes)."""
        if "download" in urllib.parse.urlsplit(url).netloc.lower():
            # Guard: that host serves the 90MB file itself. Never request it.
            raise RuntimeError(f"refusing to request file host: {url[:60]}")
        if self.used >= self.max_requests:
            raise RuntimeError("request budget exhausted")
        if self.consecutive_errors >= 3:
            raise RuntimeError("3 consecutive failures — stopping, host may be "
                               "rate-limiting us")

        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("User-Agent", UA)
        req.add_header("Accept-Language", "en-US,en;q=0.9,hr;q=0.8")
        for k, v in (headers or {}).items():
            req.add_header(k, v)

        self.used += 1
        try:
            resp = self.opener.open(req, timeout=25)
            status, hdrs = resp.status, dict(resp.headers)
            body = resp.read(read_bytes) if read_bytes else b""
            resp.close()
        except urllib.error.HTTPError as exc:
            status, hdrs, body = exc.code, dict(exc.headers or {}), b""
            exc.close()
            if status in (429, 503):
                self.consecutive_errors += 1
                back = 20 * self.consecutive_errors
                print(f"    !! HTTP {status} — backing off {back}s")
                time.sleep(back)
                self._pause()
                return status, hdrs, body
        except Exception as exc:                      # network/DNS/timeout
            self.consecutive_errors += 1
            self._pause()
            raise RuntimeError(f"{type(exc).__name__}: {exc}") from exc

        self.consecutive_errors = 0
        self._pause()
        return status, hdrs, body


def filename_from_path(path: str) -> str | None:
    for seg in reversed([s for s in path.split("/") if s]):
        seg = urllib.parse.unquote_plus(seg)
        if ARCHIVE_EXT_RE.search(seg):
            return seg
    return None


def resolve_mediafire(url, fetcher):
    """Follow at most 3 redirects, stopping as soon as a filename appears.

    MediaFire 302s /?key -> /file/<key>/<filename>/file, so this is normally a
    single request with no body at all.
    """
    current, hops = url, 0
    while hops < 3:
        status, hdrs, _ = fetcher.raw(current, method="GET")
        if status in (301, 302, 303, 307, 308):
            loc = hdrs.get("Location") or hdrs.get("location")
            if not loc:
                return None, f"redirect {status} without Location"
            current = urllib.parse.urljoin(current, loc)
            name = filename_from_path(urllib.parse.urlsplit(current).path)
            if name:
                return name, None
            hops += 1
            continue
        if status == 200:
            name = filename_from_path(urllib.parse.urlsplit(current).path)
            if name:
                return name, None
            # Fallback: <title> is the filename minus extension. Head of the
            # document only — we cap the read rather than pulling 300KB.
            _, _, body = fetcher.raw(current, method="GET", read_bytes=65536)
            m = re.search(r"(?is)<title>\s*(.*?)\s*</title>",
                          body.decode("utf-8", "replace"))
            if m and m.group(1).strip():
                return unescape(m.group(1).strip()), None
            return None, "200 but no filename in path or <title>"
        return None, f"HTTP {status}"
    return None, "too many redirects"


# ------------------------------------------------------- mega (best effort)

def _b64url(data: str) -> bytes:
    data = data.replace("-", "+").replace("_", "/")
    return __import__("base64").b64decode(data + "=" * (-len(data) % 4))


def resolve_mega(url, fetcher):
    """Filename from a Mega public link WITHOUT downloading the file.

    The `g` API returns encrypted attributes; the key lives in the URL fragment.
    VERIFIED against 6 links whose titles were known from the forum post text:
    all 6 decrypted to correct, sensible filenames. Handles both the current
    /file/<id>#<key> and the legacy #!<id>!<key> forms.
    AES via the openssl CLI to avoid a pip dependency.
    """
    m = (re.search(r"/file/([^#?]+)#([\w\-_]+)", url)
         or re.search(r"#!([^!]+)!([\w\-_]+)", url))
    if not m:
        return None, "unrecognised mega link shape"
    file_id, key_b64 = m.group(1), m.group(2)

    try:
        raw = _b64url(key_b64)
        if len(raw) < 32:
            return None, "key too short (folder link?)"
        k = struct.unpack(">8I", raw[:32])
        aes_key = struct.pack(">4I", k[0] ^ k[4], k[1] ^ k[5],
                              k[2] ^ k[6], k[3] ^ k[7])
    except Exception as exc:
        return None, f"key derivation failed: {exc}"

    body = json.dumps([{"a": "g", "p": file_id}]).encode()
    try:
        status, _, payload = fetcher.raw(
            f"https://g.api.mega.co.nz/cs?id={random.randint(0, 10**9)}",
            method="POST", data=body,
            headers={"Content-Type": "application/json"}, read_bytes=8192)
    except RuntimeError as exc:
        return None, str(exc)
    if status != 200:
        return None, f"api HTTP {status}"

    try:
        parsed = json.loads(payload.decode("utf-8", "replace"))
    except Exception:
        return None, "api returned non-JSON"
    if isinstance(parsed, int) or (parsed and isinstance(parsed[0], int)):
        code = parsed if isinstance(parsed, int) else parsed[0]
        return None, f"api error {code}" + (" (dead link)" if code == -9 else "")
    at = parsed[0].get("at")
    if not at:
        return None, "no attributes in response"

    try:
        blob = _b64url(at)
        out = subprocess.run(
            ["openssl", "enc", "-d", "-aes-128-cbc", "-nopad",
             "-K", aes_key.hex(), "-iv", "00" * 16],
            input=blob, capture_output=True, check=True).stdout
    except Exception as exc:
        return None, f"attr decrypt failed: {exc}"

    if not out.startswith(b"MEGA"):
        return None, "attr decrypt gave garbage (key derivation wrong?)"
    try:
        meta = json.loads(out[4:].rstrip(b"\0").decode("utf-8", "replace"))
        return meta.get("n"), None
    except Exception as exc:
        return None, f"attr JSON failed: {exc}"


# ---------------------------------------------------------------- titles


def fold(s: str) -> str:
    """Lowercase + strip diacritics, so 'čeljusti' and 'celjusti' unify."""
    s = s.replace("đ", "d").replace("Đ", "D")
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = re.sub(r"[^\w\s]", " ", s)    # "pazi, snima se!" == "pazi snima se"
    return re.sub(r"\s+", " ", s).strip()


def parse_title(filename: str):
    """filename -> (title, edition, number). Any may be None.

    'LMS 518 - Mister No - Bubnjevi u dzungli (drzeko).cbr'
      -> ('Bubnjevi u dzungli', 'LMS', 518)
    """
    name = urllib.parse.unquote_plus(filename)
    name = ARCHIVE_EXT_RE.sub("", name).strip()
    # Strip REPEATED trailing tags: "Crno zlato (Ostecene str 3 i 4)(300dpi)(drzeko & folpi)"
    while True:
        shorter = SCANNER_TAG_RE.sub("", name).strip()
        if shorter == name or not shorter:
            break
        name = shorter

    parts = [p.strip() for p in re.split(r"\s+-\s+|\s+–\s+", name) if p.strip()]
    if len(parts) < 2:
        # No " - " separators at all; underscores may be doing that job instead.
        parts = [p.strip() for p in
                 re.split(r"\s+-\s+|\s+–\s+", name.replace("_", " ")) if p.strip()]
    if len(parts) < 2:
        return None, None, None

    edition = number = None
    kept = []
    for part in parts:
        if not kept:                  # only strip LEADING edition/number noise
            m = EDITION_NUM_RE.match(part)
            if m:                     # "LMS 518" / "518" / "LMS-518"
                if m.group(1):
                    edition = m.group(1).upper()
                number = int(m.group(2))
                continue
            # Bare edition code as its own token: "LMS - 521 - Hero - Title".
            # Guarded by 'number is None' so a short hero name ("Zagor") that
            # follows an already-parsed number is kept, not eaten as an edition.
            if (edition is None and number is None
                    and re.fullmatch(r"[A-Za-zČĆŠŽĐčćšžđ]{1,6}", part)):
                edition = part.upper()
                continue
        kept.append(part)

    if not kept:
        return None, edition, number
    title = kept[-1].strip()          # EDITION - NUM - HERO - TITLE
    # Scanner credits are also appended with underscores rather than parens:
    # "Strah na Karibima_enwil_borke72" -> "Strah na Karibima"
    if "_" in title:
        title = title.split("_")[0].strip()
    return (title or None), edition, number


def is_plausible(title: str | None) -> bool:
    if not title:
        return False
    t = title.strip()
    letters = sum(c.isalpha() for c in t)
    # Threshold is 2, not 4: real titles get this short ("UFO", "Ku Kluks Klan").
    if len(t) < 2 or letters < 2:
        return False
    if letters / max(len(t), 1) < 0.5:
        return False
    if re.fullmatch(r"[A-Za-z]{1,6}\s*\d+", t):      # "LMS 518"
        return False
    if fold(t) in {"mister no", "zagor", "tex willer", "unknown", "scan"}:
        return False
    return True


# ---------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pages", help="directory of saved topic .html files")
    ap.add_argument("--urls", help="text file of mirror URLs, one per line")
    ap.add_argument("--cache", default="cache.json")
    ap.add_argument("--out", default="results.csv")
    ap.add_argument("--delay", type=float, default=2.5)
    ap.add_argument("--max-requests", type=int, default=150)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-mega", action="store_true")
    args = ap.parse_args()

    if not args.pages and not args.urls:
        ap.error("give --pages and/or --urls")

    print("corpus")
    corpus = load_corpus(args.pages, args.urls)
    if not corpus:
        sys.exit("error: no mirror links found. Are the posts actually unlocked "
                 "in the saved HTML? Hidden ones contain no URLs.")

    hosts = Counter("mediafire" if MEDIAFIRE_RE.match(u) else
                    "mega" if MEGA_RE.match(u) else "other"
                    for _, u in corpus)
    coded = sum(1 for c, _ in corpus if c)
    print(f"\n  {len(corpus)} unique mirrors, {len(set(c for c, _ in corpus if c))} "
          f"distinct issue codes")
    print(f"  attributed to a code: {coded}/{len(corpus)} "
          f"({100*coded/len(corpus):.0f}%)")
    print("  hosts: " + ", ".join(f"{k}={v}" for k, v in hosts.most_common()))

    if args.dry_run:
        print("\n(dry run — no requests made)")
        return

    fetcher = Fetcher(args.cache, args.delay, args.max_requests, args.dry_run)
    todo = [(c, u) for c, u in corpus if u not in fetcher.cache]
    if len(todo) > fetcher.budget_left():
        print(f"\n  {len(todo)} uncached links but budget is "
              f"{fetcher.budget_left()} — sampling at random.")
        random.shuffle(todo)
        todo = todo[:fetcher.budget_left()]

    eta = len(todo) * args.delay / 60
    print(f"\nresolving {len(todo)} links serially "
          f"(~{args.delay}s apart, ETA ~{eta:.1f} min) — Ctrl-C is safe\n")

    try:
        for i, (code, url) in enumerate(todo, 1):
            is_mega = bool(MEGA_RE.match(url))
            if is_mega and args.no_mega:
                continue
            try:
                if is_mega:
                    name, err = resolve_mega(url, fetcher)
                else:
                    name, err = resolve_mediafire(url, fetcher)
            except RuntimeError as exc:
                print(f"  [{i}/{len(todo)}] stopping: {exc}")
                break
            fetcher.cache[url] = {"filename": name, "error": err}
            flag = "ok " if name else "MISS"
            print(f"  [{i}/{len(todo)}] {flag} {(name or err or '')[:78]}")
            if i % 10 == 0:
                fetcher.save()
    except KeyboardInterrupt:
        print("\n  interrupted — saving cache")
    finally:
        fetcher.save()

    # ------------------------------------------------ report
    rows, per_edition = [], defaultdict(lambda: [0, 0])
    resolved = hits = agree = agree_possible = 0

    for code, url in corpus:
        entry = fetcher.cache.get(url)
        if not entry:
            continue
        fn, err = entry.get("filename"), entry.get("error")
        title = edition = number = None
        ok = False
        if fn:
            resolved += 1
            title, edition, number = parse_title(fn)
            ok = is_plausible(title)
            hits += ok
            key = edition or (code.split("_")[-2] if code and "_" in code else "?")
            per_edition[key][1] += 1
            per_edition[key][0] += ok
            if code and number is not None:
                m = re.search(r"_(\d{1,5})$", code)
                if m:
                    agree_possible += 1
                    agree += int(m.group(1)) == number
        rows.append({"issue_code": code or "", "url": url, "filename": fn or "",
                     "title": title or "", "edition": edition or "",
                     "number": number if number is not None else "",
                     "plausible": ok, "error": err or ""})

    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    attempted = sum(1 for _, u in corpus if u in fetcher.cache)
    print("\n" + "=" * 62)
    print("RESULT")
    print("=" * 62)
    if not attempted:
        print("  nothing resolved.")
        return
    print(f"  attempted            {attempted}")
    print(f"  filename recovered   {resolved}/{attempted} "
          f"({100*resolved/attempted:.0f}%)")
    if resolved:
        print(f"  plausible title      {hits}/{resolved} "
              f"({100*hits/resolved:.0f}%)   <-- the number that decides it")
    print(f"  end-to-end hit rate  {hits}/{attempted} "
          f"({100*hits/attempted:.0f}%)")
    if agree_possible:
        print(f"  code/filename issue number agreement  {agree}/{agree_possible} "
              f"({100*agree/agree_possible:.0f}%)")

    if len(per_edition) > 1:
        print("\n  by edition:")
        for ed, (good, tot) in sorted(per_edition.items()):
            print(f"    {ed:<8} {good:>3}/{tot:<3} ({100*good/tot:>3.0f}%)")

    bad = [r for r in rows if r["error"] or (r["filename"] and not r["plausible"])]
    if bad:
        print(f"\n  {len(bad)} failures — first 12 (fix the parser, re-run free):")
        for r in bad[:12]:
            print(f"    {r['issue_code'] or '?':<14} "
                  f"{(r['filename'] or r['error'])[:60]}")

    print(f"\n  full detail -> {args.out}")
    print("\n  Reading the result: >=90% means stripovi.com is optional polish "
          "for v1.\n  ~60-80% means harvest the encyclopedia first. Check the "
          "failures are\n  genuinely unparseable and not just my regex being "
          "too strict.")


if __name__ == "__main__":
    main()
