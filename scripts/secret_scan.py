#!/usr/bin/env python3
"""Fail if the token in $CLAUDE_CODE_OAUTH_TOKEN appears in the text on stdin,
or in any file under the directories given as arguments.

Checks clear text, base64 (standard and URL-safe, all three byte alignments,
also with line wrapping and diff prefixes removed) and hex. Prints only the
kind of match, never the match or the token.
"""
import base64
import os
import re
import sys

MIN_TOKEN_LEN = 20


def variants(text):
    yield text
    yield re.sub(r"\s+", "", text)
    yield re.sub(r"\s+", "", "".join(line[1:] for line in text.splitlines()))


def b64_needles(token):
    needles = set()
    for k, skip in ((0, 0), (1, 2), (2, 3)):
        raw = b"\0" * k + token
        end = (len(raw) * 8) // 6
        for enc in (base64.b64encode(raw), base64.urlsafe_b64encode(raw)):
            needle = enc.decode()[skip:end]
            if len(needle) >= 16:
                needles.add(needle)
    return needles


def main():
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "").strip().encode()
    if len(token) < MIN_TOKEN_LEN:
        print("secret scan: token missing or too short, refusing to scan blind", file=sys.stderr)
        return 2
    checks = {
        "clear": {token.decode()},
        "base64": b64_needles(token),
        "hex": {token.hex(), token.hex().upper()},
    }
    sources = [("diff", sys.stdin.read())] if not sys.argv[1:] else []
    for root in sys.argv[1:]:
        for d, _, names in os.walk(root):
            for name in names:
                path = os.path.join(d, name)
                if os.path.isfile(path) and not os.path.islink(path):
                    with open(path, "rb") as f:
                        sources.append(("tree", f.read().decode("latin-1")))
    for where, text in sources:
        for kind, needles in checks.items():
            for variant in variants(text):
                if any(n in variant for n in needles):
                    print(f"secret scan: token found in {where} ({kind}); nothing printed", file=sys.stderr)
                    return 1
    print("secret scan: clean")
    return 0


sys.exit(main())
