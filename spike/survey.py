#!/usr/bin/env python3
"""
survey.py — classify every saved topic page by its post convention.

Purely offline. Makes no network requests of any kind.

For each page it reports which extraction strategy accounts for the links, and
— the useful part — dumps context for links NO strategy could attribute. Those
are new conventions that need a parser.

It also reports the host distribution across ALL external links, so a file host
we haven't met yet (Drive, pixeldrain, 1fichier...) shows up rather than being
silently skipped.

Usage:  python3 survey.py [--pages ./pages] [--context 6]
"""

import argparse
import html
import os
import re
import sys
from collections import Counter, defaultdict

# Hosts that are page furniture, not comic downloads.
NOISE = ("stripzona.com", "stripovi.com", "invisionpower.com", "ibskin.com",
         "gravatar.com", "schema.org", "data-vocabulary.org", "googlesyndication",
         "google-analytics", "facebook.com", "twitter.com", "youtube.com",
         "doubleclick", "adsbygoogle", "w3.org", "mozilla.org")

# Inline cover/preview images posted in the body — NOT comic downloads. Counting
# these as links inflated the corpus and faked "unattributed" hits.
IMAGE_HOSTS = ("postimg.cc", "postimg.org", "tinypic.com", "imageshack.us",
               "imgur.com", "imagevenue", "imagebam", "servimg.com",
               "photobucket", "ibb.co", "picpaste", "slika.rs")

URL_ANY = re.compile(r"https?://[^\s\"'<>\]\)]+")
# Label forms seen so far, plus room for variants:
#   "013-Nasilje u Darkvudu" / "ZS 0418 - ZAGOR - Title" / "001 (SSB 089/001) - Title"
LBL_NUM = re.compile(r"^(?:[A-ZČĆŠŽĐ]{2,5}\s+)?(\d{1,4})\s*(?:\([^)]*\))?\s*[-–.]\s*(.+?)\s*$")
# "MN_LMS_511" style codes alone on a line; TN_* are cover thumbnails, not labels.
LBL_CODE = re.compile(r"^(?!TN_)([A-ZČĆŠŽĐ][A-Z0-9ČĆŠŽĐ_]*_(\d{1,5}))$")

# FIBRA magazines and Alef put the NAME before the number, and the title (if any)
# after it, with trailing (author) (date) groups:
#     "Kolorka 2 Čovjek s Filipina (Berardi & Milazzo) (02.12.2008)"
#     "Orka specijal 1 - Eternaut (19.03.2008)"
#     "Alef 01 -"                      <- no title at all
L = "A-Za-zČĆŠŽĐčćšžđ"
LBL_NAMENUM = re.compile(rf"^([{L}][{L}]{{1,14}}(?:\s+[{L}]{{2,14}}){{0,2}})\s+"
                         rf"(\d{{1,4}})\s*[-–_.:]?\s*(.*)$")
TRAILING_PARENS = re.compile(r"(?:\s*[\(\[][^)\]]*[\)\]])+\s*$")
# Lines that look like labels but are forum chrome. Without this, every
# "Posted 06 March 2011 - 09:26 PM" becomes a bogus label.
FURNITURE = {"posted", "edited", "brojevi", "broj", "hvala", "format", "izlazilo",
             "popular", "attached", "quote", "report", "download", "novo",
             "update", "edit", "uploader", "scan", "str", "strana", "page"}


def match_namenum(ln: str):
    """-> (number, title_or_None, name) for the name-first convention."""
    if len(ln) > 120 or "http" in ln.lower():
        return None
    m = LBL_NAMENUM.match(ln)
    if not m or m.group(1).split()[0].lower() in FURNITURE:
        return None
    title = TRAILING_PARENS.sub("", m.group(3)).strip(" -–_.:")
    return m.group(2), (title or None), m.group(1)


# Matches a tag even when an attribute value contains '>' (IPB's onerror
# handlers do: `onerror='...indexOf(x)>-1...'`), which naive <[^>]+> splits on.
TAG = r"<[a-zA-Z/!][^>\"']*(?:\"[^\"]*\"[^>\"']*|'[^']*'[^>\"']*)*>"
INLINE_TAGS = "a|b|strong|i|em|u|span|font|small|big|sub|sup|code|tt|s|strike|mark|abbr"


def plain_lines(raw: str) -> list[str]:
    """Reconstruct visible lines.

    Two things here are load-bearing:
      * ENTITY UNESCAPE — IPB writes 'http&#58;//www.mediafire.com/...', so a
        URL regex finds nothing without it.
      * INLINE tags are DELETED, block tags become newlines. Turning every tag
        into a newline shreds '<b>Orka specijal 1</b> - <i>Eternaut</i>' into
        four separate "lines" and destroys the label/title relationship.
    """
    raw = re.sub(r"(?is)<(script|style).*?</\1>", " ", raw)
    # Anchors FIRST, as insurance: IF a post ever hyperlinks a title instead of
    # pasting a bare URL, deleting <a> with the other inline tags would lose the
    # href. UNPROVEN on the current corpus — every download link so far is bare
    # text, and this rewrite changed nothing (909 links before and after). Kept
    # because it costs nothing; do not cite it as a fix for anything observed.
    raw = re.sub(r'(?is)<a\s[^>]*?href\s*=\s*["\']([^"\']+)["\'][^>]*>(.*?)</a>',
                 lambda m: f" {m.group(2)} {m.group(1)} ", raw)
    raw = re.sub(rf"(?is)</?(?:{INLINE_TAGS})(?:\s[^>]*?)?>", "", raw)
    text = html.unescape(re.sub(rf"(?is){TAG}", "\n", raw))
    return [l.strip() for l in text.split("\n") if l.strip()]


def host_of(url: str) -> str:
    try:
        h = url.split("/")[2].lower()
    except IndexError:
        return "?"
    return h[4:] if h.startswith("www.") else h


MAX_CLAIM = 4   # mirrors per label; more than this means the label is stale


def classify(lines):
    """Attribute each download link to a label.

    Rule: a label owns every URL until the NEXT label appears. Line distance is
    a bad proxy — 3 lines is too strict for labeled-block posts and too loose
    for dense lists.

    The failure mode this guards against is an UNRECOGNISED format: no line
    matches the label regex, so one stale label silently claims hundreds of
    links and every title is wrong. Any label instance claiming more than
    MAX_CLAIM URLs is therefore reported as 'suspect', not as a success.
    """
    recs, pending_num, pending_code = [], None, None
    instance = 0
    for idx, ln in enumerate(lines):
        urls = [u for u in URL_ANY.findall(ln) if not any(n in u for n in NOISE)]
        urls = [u for u in urls if not any(h in u for h in IMAGE_HOSTS)]
        urls = list(dict.fromkeys(urls))   # anchor text may repeat its own href
        if urls:
            for u in urls:
                before = ln[: ln.index(u)].strip(" -–|.")
                m = LBL_NUM.match(before) if before else None
                # "MM_LMS_031 - http://..." puts the CODE and the URL on one
                # line. LBL_CODE anchors to end-of-line, so without this the
                # previous label stays pending and swallows the whole block.
                mc = LBL_CODE.match(before) if before else None
                if mc:
                    instance += 1
                    recs.append((u, "labeled", mc.group(1), ("c", instance)))
                elif m:
                    instance += 1
                    recs.append((u, "same-line", m.group(2), ("s", instance)))
                elif pending_num:
                    recs.append((u, "prev-line", pending_num[1], ("n", pending_num[2])))
                elif pending_code:
                    recs.append((u, "labeled", pending_code[0], ("c", pending_code[1])))
                else:
                    recs.append((u, "none", None, None))
            continue
        # attribute-soup lines leak from IPB's onerror handlers; never labels
        if "src=" in ln or ".jpg" in ln or "this.src" in ln:
            continue
        m = LBL_CODE.match(ln)
        if m:
            instance += 1
            pending_code, pending_num = (m.group(1), instance), None
            continue
        m = LBL_NUM.match(ln)
        if m and len(m.group(2)) > 2 and not m.group(2).lower().startswith("http"):
            instance += 1
            pending_num, pending_code = (m.group(1), m.group(2), instance), None
            continue
        nn = match_namenum(ln)
        if nn:
            instance += 1
            pending_num, pending_code = (nn[0], nn[1] or f"{nn[2]} {nn[0]}", instance), None
    return recs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", default="pages")
    ap.add_argument("--context", type=int, default=6, help="lines of context per unknown")
    args = ap.parse_args()

    if not os.path.isdir(args.pages):
        sys.exit(f"error: no {args.pages}/ directory")
    files = sorted(n for n in os.listdir(args.pages)
                   if ".htm" in n.lower() and os.path.isfile(os.path.join(args.pages, n)))
    if not files:
        sys.exit(f"error: no pages in {args.pages}/")

    all_hosts, dominant, locked, unknown_pages = Counter(), Counter(), [], []
    grand_links = grand_attr = 0

    for name in files:
        raw = open(os.path.join(args.pages, name), encoding="utf-8", errors="replace").read()
        hidden = len(re.findall(r"(?i)hidden content", raw))
        lines = plain_lines(raw)
        recs = classify(lines)

        if not recs:
            locked.append((name, hidden))
            print(f"\n### {name[:64]}\n    LOCKED — 0 links, {hidden} hidden blocks. "
                  f"Like the posts, force-reload (Cmd-Opt-R), save again.")
            continue

        hosts = Counter(host_of(u) for u, _, _, _ in recs)
        all_hosts.update(hosts)
        claims = Counter(r[3] for r in recs if r[3])
        suspect = sum(1 for r in recs if r[3] and claims[r[3]] > MAX_CLAIM)
        how = Counter(k for _, k, _, _ in recs)
        attributed = len(recs) - how["none"] - suspect
        grand_links += len(recs)
        grand_attr += attributed
        best = max(("same-line", "prev-line", "labeled"), key=lambda k: how[k])
        dominant[best if how[best] else "unattributed"] += 1

        pct = 100 * attributed / len(recs)
        print(f"\n### {name[:64]}")
        print(f"    links {len(recs):>4}   attributed {attributed:>4} ({pct:>3.0f}%)"
              f"   [same-line={how['same-line']} prev-line={how['prev-line']} "
              f"labeled={how['labeled']} none={how['none']} suspect={suspect}]")
        print(f"    hosts: " + ", ".join(f"{h}={c}" for h, c in hosts.most_common(6)))
        if hidden:
            print(f"    note: {hidden} blocks still hidden — page only partly unlocked")

        if how["none"] or suspect:
            unknown_pages.append(name)
            print(f"    !! {how['none']} unattributed + {suspect} suspect — probable NEW CONVENTION:")
            firsts = [r[0] for r in recs if r[1] == "none"][:2]
            for u in firsts:
                for i, ln in enumerate(lines):
                    if u in ln:
                        lo = max(0, i - args.context)
                        for c in lines[lo:i + 2]:
                            print(f"        | {c[:96]}")
                        print("        |" + "-" * 40)
                        break

    print("\n" + "=" * 66)
    print("SUMMARY")
    print("=" * 66)
    print(f"  pages surveyed        {len(files)}   (locked/unusable: {len(locked)})")
    if grand_links:
        print(f"  download links        {grand_links}")
        print(f"  attributed to a label {grand_attr}/{grand_links} "
              f"({100*grand_attr/grand_links:.0f}%)")
    print(f"  dominant convention   " + ", ".join(f"{k}={v}" for k, v in dominant.most_common()))
    print(f"\n  host distribution (all pages):")
    for h, c in all_hosts.most_common(15):
        known = "" if h in ("mediafire.com", "mega.nz", "mega.co.nz") else "   <-- NEW HOST"
        print(f"    {h:<28} {c:>5}{known}")
    if unknown_pages:
        print(f"\n  pages with unattributed links (need a parser): {len(unknown_pages)}")
        for n in unknown_pages:
            print(f"    - {n[:70]}")
    if locked:
        print(f"\n  pages needing a re-save: {len(locked)}")
        for n, h in locked:
            print(f"    - {n[:70]} ({h} hidden blocks)")


if __name__ == "__main__":
    main()
