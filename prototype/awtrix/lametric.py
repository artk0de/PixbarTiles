"""Access to the LaMetric icon catalogue that AWTRIX icons come from.

Two separate services, and only one of them is picky:

* the CDN at /content/apps/icon_thumbs/<id>.gif serves any icon by id, no auth;
* the search endpoint rejects a request unless ALL five query parameters are
  present — a missing `category` or `guest_icons` yields a framework error page
  rather than a validation message, which reads like a block.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request
from dataclasses import dataclass

BASE = "https://developer.lametric.com"
CDN = f"{BASE}/content/apps/icon_thumbs"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"
)

ICON_STATIC = 0
ICON_ANIMATED = 1


@dataclass(frozen=True)
class CatalogueIcon:
    id: int
    name: str
    category: str
    type: int

    @property
    def animated(self) -> bool:
        return self.type == ICON_ANIMATED


def _get(url: str, timeout: int = 20) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def search(term: str, *, page: int = 1, count: int = 80, category: str = "") -> list[CatalogueIcon]:
    """Search the catalogue by name. Matching is near-exact — 'lol' hits, 'laugh' does not."""
    params = urllib.parse.urlencode(
        {
            "page": page,
            "category": category,
            "search": term,
            "count": count,
            "guest_icons": "true",
        }
    )
    payload = json.loads(_get(f"{BASE}/api/v1/dev/preloadicons?{params}"))
    return [
        CatalogueIcon(id=i["id"], name=i["name"], category=i["category"], type=i["type"])
        for i in payload.get("icons", [])
    ]


def download(icon_id: int) -> bytes:
    """Fetch an 8x8 icon by id. Raises if the id resolves to an HTML error page."""
    blob = _get(f"{CDN}/{icon_id}.gif")
    if not blob.startswith(b"GIF"):
        raise ValueError(f"icon {icon_id} is not a GIF (id likely does not exist)")
    return blob
