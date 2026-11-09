"""Minimal IPP/2.0 client (enough for SELPHY: print JPEG, query printer and jobs).

Works over the network (ipp://<printer>/ipp/print) and over USB through ipp-usb
(ipp://localhost:60000/ipp/print).
"""
from __future__ import annotations

import http.client
import struct
from urllib.parse import urlparse

from .media import Paper

# operations
PRINT_JOB, VALIDATE_JOB, CANCEL_JOB, GET_JOB_ATTRS, GET_PRINTER_ATTRS = 0x02, 0x04, 0x08, 0x09, 0x0B
# delimiter tags
OP, JOB, END, PRINTER, UNSUPPORTED = 0x01, 0x02, 0x03, 0x04, 0x05
# value tags
INTEGER, BOOLEAN, ENUM = 0x21, 0x22, 0x23
OCTET, DATETIME, RESOLUTION, RANGE = 0x30, 0x31, 0x32, 0x33
BEG_COLL, END_COLL, MEMBER = 0x34, 0x37, 0x4A
TEXT, NAME, KEYWORD, URI, CHARSET, LANG, MIME = 0x41, 0x42, 0x44, 0x45, 0x47, 0x48, 0x49

JOB_STATES = {3: "pending", 4: "held", 5: "processing", 6: "stopped", 7: "canceled",
              8: "aborted", 9: "completed"}
PRINTER_STATES = {3: "idle", 4: "processing", 5: "stopped"}


class IppError(Exception):
    pass


def _attr(tag: int, name: str, value: bytes) -> bytes:
    n = name.encode()
    return struct.pack(">BH", tag, len(n)) + n + struct.pack(">H", len(value)) + value


def _int(v: int) -> bytes:
    return struct.pack(">i", v)


def _member(tag: int, name: str, value: bytes) -> bytes:
    return _attr(MEMBER, "", name.encode()) + _attr(tag, "", value)


def _collection(name: str, members: bytes) -> bytes:
    return _attr(BEG_COLL, name, b"") + members + _attr(END_COLL, "", b"")


def _media_col(paper: Paper, borderless: bool) -> bytes:
    x, y = paper.ipp_size
    size = (_attr(MEMBER, "", b"media-size") + _attr(BEG_COLL, "", b"")
            + _member(INTEGER, "x-dimension", _int(x)) + _member(INTEGER, "y-dimension", _int(y))
            + _attr(END_COLL, "", b""))
    margins = b""
    if borderless:
        for side in ("top", "bottom", "left", "right"):
            margins += _member(INTEGER, f"media-{side}-margin", _int(0))
    return _collection("media-col", size + margins
                       + _member(KEYWORD, "media-type", b"photographic")
                       + _member(KEYWORD, "media-source", b"photo"))


def _decode_value(tag: int, v: bytes):
    if tag in (INTEGER, ENUM):
        return struct.unpack(">i", v)[0]
    if tag == BOOLEAN:
        return bool(v[0])
    if tag == RANGE:
        return struct.unpack(">ii", v)
    if tag == RESOLUTION:
        return struct.unpack(">iib", v)
    if tag in (OCTET, DATETIME):
        return v.hex()
    return v.decode("utf-8", "replace")


def parse(body: bytes) -> tuple[int, dict[str, list]]:
    """Return (status-code, {name: [values]}) — collections are flattened/skipped."""
    if len(body) < 8:
        raise IppError("short IPP response")
    status = struct.unpack(">H", body[2:4])[0]
    attrs: dict[str, list] = {}
    i, name, depth = 8, "", 0
    while i < len(body):
        tag = body[i]; i += 1
        if tag == END:
            break
        if tag < 0x10:
            continue
        nlen = struct.unpack(">H", body[i:i + 2])[0]; i += 2
        n = body[i:i + nlen].decode(); i += nlen
        vlen = struct.unpack(">H", body[i:i + 2])[0]; i += 2
        v = body[i:i + vlen]; i += vlen
        if tag == BEG_COLL:
            depth += 1
            if depth == 1:
                name = n or name
                attrs.setdefault(name, []).append("{collection}")
            continue
        if tag == END_COLL:
            depth -= 1
            continue
        if depth:
            continue
        if n:
            name = n
        attrs.setdefault(name, []).append(_decode_value(tag, v))
    return status, attrs


class IppPrinter:
    def __init__(self, uri: str, user: str = "selphy-cli", timeout: float = 30):
        u = urlparse(uri)
        self.uri = uri
        self.host = u.hostname or "localhost"
        self.port = u.port or 631
        self.path = u.path or "/ipp/print"
        self.user = user
        self.timeout = timeout
        self._rid = 0

    def _request(self, op: int, attrs: bytes, job_attrs: bytes = b"", data: bytes = b""):
        self._rid += 1
        body = (struct.pack(">BBHI", 2, 0, op, self._rid) + bytes([OP])
                + _attr(CHARSET, "attributes-charset", b"utf-8")
                + _attr(LANG, "attributes-natural-language", b"en")
                + _attr(URI, "printer-uri", self.uri.encode())
                + _attr(NAME, "requesting-user-name", self.user.encode())
                + attrs
                + (bytes([JOB]) + job_attrs if job_attrs else b"")
                + bytes([END]) + data)
        conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        try:
            conn.request("POST", self.path, body, {"Content-Type": "application/ipp"})
            resp = conn.getresponse()
            payload = resp.read()
            if resp.status != 200:
                raise IppError(f"HTTP {resp.status} {resp.reason}")
        finally:
            conn.close()
        status, out = parse(payload)
        if status >= 0x0400:
            msg = out.get("status-message", [""])[0]
            raise IppError(f"IPP status 0x{status:04x} {msg}")
        return status, out

    def attributes(self, *names: str) -> dict[str, list]:
        req = b"".join(_attr(KEYWORD, "requested-attributes" if i == 0 else "", n.encode())
                       for i, n in enumerate(names or ("all",)))
        return self._request(GET_PRINTER_ATTRS, req)[1]

    def _job_attrs(self, paper: Paper, borderless: bool, copies: int, color: str) -> bytes:
        return (_attr(INTEGER, "copies", _int(copies))
                + _attr(KEYWORD, "print-color-mode", color.encode())
                + _attr(KEYWORD, "print-scaling", b"fill")
                + _media_col(paper, borderless))

    def _op_attrs(self, name: str) -> bytes:
        return (_attr(NAME, "job-name", name.encode()[:255])
                + _attr(MIME, "document-format", b"image/jpeg"))

    def validate(self, paper: Paper, borderless: bool = True, copies: int = 1,
                 color: str = "color") -> int:
        return self._request(VALIDATE_JOB, self._op_attrs("validate"),
                             self._job_attrs(paper, borderless, copies, color))[0]

    def print_jpeg(self, jpeg: bytes, paper: Paper, borderless: bool = True, copies: int = 1,
                   color: str = "color", name: str = "photo") -> int:
        _, out = self._request(PRINT_JOB, self._op_attrs(name),
                               self._job_attrs(paper, borderless, copies, color), jpeg)
        return out["job-id"][0]

    def job(self, job_id: int) -> dict[str, list]:
        return self._request(GET_JOB_ATTRS, _attr(INTEGER, "job-id", _int(job_id)))[1]

    def cancel(self, job_id: int) -> None:
        self._request(CANCEL_JOB, _attr(INTEGER, "job-id", _int(job_id)))
