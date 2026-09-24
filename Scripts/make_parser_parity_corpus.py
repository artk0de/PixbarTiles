#!/usr/bin/env python3
"""Record what the prototype's parser makes of a corpus of real anecdotes.

The Swift dialogue parser was written from `prototype/demo_anecdote.py` and had
never been compared against it. A disagreement there does not read as a parsing
bug: the turn count decides how many lead-ins the pacing lays down, so a joke
split into a different number of turns has its pauses in the wrong places while
every pause constant still matches, and the only symptom is that the app sounds
worse than the demo.

This writes the fixture `theSwiftParserSplitsARealCorpusExactlyAsTheProtoypeDoes`
compares against, so the expected splits are the prototype's own output rather
than values somebody typed. The anecdote text is stored post-feed-normalisation
— what both parsers actually receive — which keeps the comparison about the
parser and not about the feed reader.

Run from the repository root:

    python3 Scripts/make_parser_parity_corpus.py

Rerunning replaces the corpus with today's feeds. Only do that on purpose: the
fixture is an acceptance set, and a fresh capture is a new one.
"""

from __future__ import annotations

import datetime
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROTOTYPE = os.path.join(ROOT, "prototype")
FIXTURE = os.path.join(
    ROOT, "Tests", "PixbarKitTests", "Fixtures", "parser_parity_corpus.json"
)

sys.path.insert(0, PROTOTYPE)
from demo_anecdote import ENTITIES, PINNED, parse_turns  # noqa: E402

# The three the connector cascades over, widest first.
FEEDS = [
    "https://www.anekdot.ru/rss/export_top.xml",
    "https://www.anekdot.ru/rss/export_bestday.xml",
    "https://www.anekdot.ru/rss/export_j.xml",
]


def fetch(url: str) -> list[tuple[str, str]]:
    """Feed items as (guid, text), normalised the way the prototype reads them."""
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    raw = urllib.request.urlopen(request, timeout=20).read().decode("utf-8", "replace")

    items = []
    for item in re.findall(r"<item>(.*?)</item>", raw, re.S):
        guid = re.search(r"<guid>(.*?)</guid>", item, re.S)
        description = re.search(
            r"<description>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</description>", item, re.S
        )
        if not (guid and description):
            continue
        text = re.sub(r"<br\s*/?>", "\n", description.group(1), flags=re.I)
        for entity, character in ENTITIES:
            text = text.replace(entity, character)
        lines = [line.strip() for line in text.split("\n")]
        text = "\n".join(line for line in lines if line)
        if text:
            items.append((guid.group(1), text))
    return items


def main() -> int:
    seen, corpus = set(), []
    for feed in FEEDS:
        try:
            items = fetch(feed)
        except Exception as error:  # a feed being down must not lose the others
            print(f"  skipped {feed}: {error}", file=sys.stderr)
            continue
        print(f"  {len(items):3} from {feed}")
        for guid, text in items:
            if guid in seen:
                continue
            seen.add(guid)
            corpus.append((guid, text))

    # The two curated ones as well: they are real anecdotes, and the helicopter
    # is the exact dialogue the female-speaker rule was built against.
    for guid, text in PINNED.values():
        corpus.append((guid, text))

    document = {
        "capturedOn": datetime.date.today().isoformat(),
        "source": "anekdot.ru export_top.xml, export_bestday.xml, export_j.xml,"
                  " plus the prototype's two pinned anecdotes",
        "splitBy": "prototype/demo_anecdote.py parse_turns",
        "anecdotes": [
            {
                "id": guid,
                "text": text,
                "turns": [
                    {"speaker": speaker, "text": line}
                    for speaker, line in parse_turns(text)
                ],
            }
            for guid, text in corpus
        ],
    }

    with open(FIXTURE, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, indent=1)

    turns = sum(len(a["turns"]) for a in document["anecdotes"])
    dialogues = sum(
        1
        for a in document["anecdotes"]
        if any(t["speaker"] != "narrator" for t in a["turns"])
    )
    print(f"{len(corpus)} anecdotes, {turns} turns, {dialogues} with dialogue -> {FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
