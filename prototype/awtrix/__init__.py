"""Prototype AWTRIX integration layer.

Validates the device-facing behaviour that the native macOS app will reproduce:
sending content, installing icons, and managing files on the device flash.
"""

from .client import AwtrixClient, AwtrixError, RemoteFile

__all__ = ["AwtrixClient", "AwtrixError", "RemoteFile"]
