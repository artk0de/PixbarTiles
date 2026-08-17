"""HTTP client for an AWTRIX 3 device.

Reference implementation for the three capabilities the native app will need:
sending content, managing icons, and managing files on the device flash.

Deliberately stdlib-only — every construct here has a direct Foundation
equivalent, so the port to Swift stays a translation rather than a redesign.
"""

from __future__ import annotations

import json
import mimetypes
import os
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any

DEFAULT_TIMEOUT = 15


class AwtrixError(RuntimeError):
    """Device returned a non-2xx response."""

    def __init__(self, status: int, body: str, endpoint: str) -> None:
        super().__init__(f"{endpoint} -> HTTP {status}: {body.strip()}")
        self.status = status
        self.body = body
        self.endpoint = endpoint


@dataclass(frozen=True)
class RemoteFile:
    name: str
    size: int
    is_dir: bool

    @classmethod
    def from_listing(cls, entry: dict[str, Any]) -> RemoteFile:
        return cls(name=entry["name"], size=int(entry["size"]), is_dir=entry["type"] == "dir")


class AwtrixClient:
    """Talks to one AWTRIX device over its local HTTP API."""

    def __init__(self, host: str, timeout: int = DEFAULT_TIMEOUT) -> None:
        self.host = host
        self.timeout = timeout

    # ---------------------------------------------------------------- transport

    def _url(self, path: str) -> str:
        return f"http://{self.host}{path}"

    def _request(
        self,
        method: str,
        path: str,
        *,
        data: bytes | None = None,
        content_type: str | None = None,
    ) -> str:
        headers = {"Content-Type": content_type} if content_type else {}
        req = urllib.request.Request(self._url(path), data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read().decode(errors="replace")
        except urllib.error.HTTPError as exc:
            raise AwtrixError(exc.code, exc.read().decode(errors="replace"), path) from exc

    def _get_json(self, path: str) -> Any:
        return json.loads(self._request("GET", path))

    def _post_json(self, path: str, payload: dict[str, Any]) -> str:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        return self._request("POST", path, data=body, content_type="application/json")

    # -------------------------------------------------------------- inspection

    def stats(self) -> dict[str, Any]:
        return self._get_json("/api/stats")

    def settings(self) -> dict[str, Any]:
        return self._get_json("/api/settings")

    def update_settings(self, **values: Any) -> str:
        return self._post_json("/api/settings", values)

    def screen(self) -> list[int]:
        """Current 32x8 matrix buffer as 256 packed 0xRRGGBB values."""
        return self._get_json("/api/screen")

    def loop(self) -> dict[str, int]:
        return self._get_json("/api/loop")

    # ----------------------------------------------------------------- sending

    def notify(
        self,
        text: str | None = None,
        *,
        icon: str | None = None,
        duration: int | None = None,
        color: str | None = None,
        rtttl: str | None = None,
        sound: str | None = None,
        repeat: int | None = None,
        scroll_speed: int | None = None,
        stack: bool | None = None,
        wakeup: bool | None = None,
        hold: bool | None = None,
        push_icon: int | None = None,
        **extra: Any,
    ) -> str:
        """Show a one-off notification. Every argument maps 1:1 to the API field."""
        payload: dict[str, Any] = {
            "text": text,
            "icon": icon,
            "duration": duration,
            "color": color,
            "rtttl": rtttl,
            "sound": sound,
            "repeat": repeat,
            "scrollSpeed": scroll_speed,
            "stack": stack,
            "wakeup": wakeup,
            "hold": hold,
            "pushIcon": push_icon,
            **extra,
        }
        return self._post_json("/api/notify", {k: v for k, v in payload.items() if v is not None})

    def dismiss_notification(self) -> str:
        return self._post_json("/api/notify/dismiss", {})

    def play_rtttl(self, melody: str) -> str:
        """Play a raw RTTTL string. The buzzer is monophonic — one tone at a time."""
        return self._request("POST", "/api/rtttl", data=melody.encode(), content_type="text/plain")

    def play_melody(self, name: str) -> str:
        """Play `/MELODIES/<name>.txt`. The device resolves RTTTL text files only."""
        return self._post_json("/api/sound", {"sound": name})

    def custom_app(self, name: str, payload: dict[str, Any] | None) -> str:
        """Create, update, or (payload=None) delete a persistent custom app slot."""
        body = json.dumps(payload or {}, ensure_ascii=False).encode("utf-8")
        return self._request(
            "POST", f"/api/custom?name={name}", data=body, content_type="application/json"
        )

    # ------------------------------------------------------------------- files

    def list_dir(self, path: str = "/") -> list[RemoteFile]:
        entries = self._get_json(f"/list?dir={path}")
        return [RemoteFile.from_listing(e) for e in entries]

    def upload(self, local_path: str, remote_path: str) -> str:
        """Upload a file to the device flash via the ESPAsyncWebServer editor."""
        with open(local_path, "rb") as fh:
            return self.upload_bytes(fh.read(), remote_path)

    def upload_bytes(self, blob: bytes, remote_path: str) -> str:
        boundary = uuid.uuid4().hex
        mime = mimetypes.guess_type(remote_path)[0] or "application/octet-stream"
        body = b"".join(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="file"; filename="{remote_path}"\r\n'.encode(),
                f"Content-Type: {mime}\r\n\r\n".encode(),
                blob,
                f"\r\n--{boundary}--\r\n".encode(),
            ]
        )
        return self._request(
            "POST", "/edit", data=body, content_type=f"multipart/form-data; boundary={boundary}"
        )

    def delete(self, remote_path: str) -> str:
        boundary = uuid.uuid4().hex
        body = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="path"\r\n\r\n'
            f"{remote_path}\r\n"
            f"--{boundary}--\r\n"
        ).encode()
        return self._request(
            "DELETE", "/edit", data=body, content_type=f"multipart/form-data; boundary={boundary}"
        )

    def exists(self, remote_path: str) -> bool:
        directory, _, name = remote_path.rpartition("/")
        return any(f.name == name for f in self.list_dir(directory or "/"))

    # ------------------------------------------------------------------- icons

    def upload_icon(self, local_path: str, name: str | None = None) -> str:
        """Install an 8x8 icon. The name (without extension) is how apps reference it."""
        base = name or os.path.splitext(os.path.basename(local_path))[0]
        ext = os.path.splitext(local_path)[1] or ".gif"
        return self.upload(local_path, f"/ICONS/{base}{ext}")

    def list_icons(self) -> list[RemoteFile]:
        return self.list_dir("/ICONS")

    def delete_icon(self, name: str, ext: str = ".gif") -> str:
        return self.delete(f"/ICONS/{name}{ext}")

    # ---------------------------------------------------------------- melodies

    def upload_melody(self, name: str, rtttl: str) -> str:
        return self.upload_bytes(rtttl.encode(), f"/MELODIES/{name}.txt")

    def list_melodies(self) -> list[RemoteFile]:
        return self.list_dir("/MELODIES")

    def delete_melody(self, name: str) -> str:
        return self.delete(f"/MELODIES/{name}.txt")
