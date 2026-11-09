"""Canon Photo Network Protocol (CPNP) client for SELPHY CP-series printers.

Reverse-engineered from SELPHY Photo Layout 4.4.0 (classes in
``jp.co.canon.ic.photolayout.model.printer.internal.cpnp``). See docs/PROTOCOL.md.

Framing: every packet starts with a 16-byte big-endian header::

    0  "CPNP"
    4  u8  0x01 request / 0x81 response
    5  u8  command
    6  u16 error (responses)
    8  u16 packet id
    10 u16 session id
    12 u32 payload length

Session control and idle status go over UDP 8609; once a session is open the
printer hands out a TCP port that carries Read (status) and Write (job data).
The print commands inside Write payloads are little-endian.
"""
from __future__ import annotations

import socket
import struct
import time
from dataclasses import dataclass
from enum import IntEnum
from typing import Callable

PORT = 8609
MAGIC = b"CPNP"
_REQ, _RESP = 0x01, 0x81

SESSION_USER = "SPL v2.0"     # what the Canon app identifies as
SESSION_DOCUMENT = "Square"
DEFAULT_MAX_WRITE = 0x8400    # 33 792 bytes
SESSION_BUSY_ERRORS = (0x8501, 0x8502)


class Cmd(IntEnum):
    NIC_INFO = 0x01
    SESSION_START = 0x10
    SESSION_END = 0x11
    READ = 0x20
    WRITE = 0x21
    DEVICE_ID = 0x30
    GET_MAX_WRITE = 0x51
    SET_MAX_WRITE = 0x52


class DeviceStatus(IntEnum):
    IDLE = 0x0000
    WAIT_DISCONNECT_SESSION = 0x00F0
    NO_SESSION = 0x000F
    INIT = 0x00FF
    CHANGE_SETTING_PREPARED = 0x0101
    FIRMUP_INITIALIZING = 0x0201
    FIRMUP_PREPARED = 0x0202
    CANCEL_WAIT = 0xFF00
    PRINT_INITIALIZING = 0xFF01
    YELLOW_HEAT_WAITING = 0xFF02
    YELLOW_PRINTING = 0xFF03
    MAGENTA_HEAT_WAITING = 0xFF04
    MAGENTA_PRINTING = 0xFF05
    CYAN_HEAT_WAITING = 0xFF06
    CYAN_PRINTING = 0xFF07
    OVERCOAT_HEAT_WAITING = 0xFF08
    OVERCOAT_PRINTING = 0xFF09
    PRINT_FINALIZE = 0xFF0A
    BATTERY_HEAT_WAITING = 0xFF0B
    ERROR_PAUSING = 0xFF0C
    RESUME_WAITING = 0xFF0D
    PAPER_PICK_WAIT = 0xFF10
    CRITICAL_ERROR = 0xFFFF


class DataRequest(IntEnum):
    NONE = 0
    START_PRINT = 0x10000
    PRINT_DATA = 0x20000
    OC_DATA = 0x2FFFF          # matched as (request | 0xFF) == 0x2FFFF
    END_PRINT = 0x30000
    CANCEL_PRINT = 0x40000
    EXECUTE_SPOOL_PRINT = 0x70000


ERRORS = {
    0: "none",
    266: "waiting for paper pick",
    0x10101: "out of paper",
    0x10102: "paper tray missing",
    0x10103: "paper tray size differs from ink cassette",
    0x10106: "abnormal paper (width)",
    0x10107: "abnormal paper (height)",
    0x10109: "paper cover open",
    0x1010B: "paper feed sensor",
    0x1010C: "different paper size",
    0x1010D: "paper set incorrectly",
    0x10201: "ink ribbon used up",
    0x10202: "no ink cassette",
    0x10203: "ink cassette size differs",
    0x10204: "ink cassette type differs",
    0x10205: "unknown ink cassette",
    0x10302: "no paper tray and no ink cassette",
    0x10303: "paper tray and ink cassette mismatch",
    0x1FF03: "low battery",
    0x3FF05: "image decode error",
    0xFF0104: "paper jam",
    0xFF0202: "no ink cassette (fatal)",
    0xFF0206: "ink abnormal",
    0xFFFF00: "other error",
    0xFFFF04: "command error",
    0xFFFF06: "firmware file error",
    0xFFFF07: "battery error",
}
ERROR_RECOVERABLE = 0x010000      # error & 0xFFFF0000 — printer waits for the user
ERROR_FATAL = 0xFF0000

INK_CASSETTES = {0: "unknown", 1: "none", 2: "Card (KC)", 3: "L (KL)", 4: "Postcard (KP)",
                 5: "Postcard 54 sheets", 6: "Postcard HD", 255: "not supported"}
PAPER_TRAYS = {0: "unknown", 1: "none", 2: "Card", 3: "L", 4: "Postcard", 255: "not supported"}
PRINTER_STATES = {1: "idle", 2: "busy", 241: "error", 255: "none"}
POWER = {0: "AC adapter", 1: "battery", 2: "USB bus power"}


class CpnpError(Exception):
    pass


class PrinterBusy(CpnpError):
    pass


class PrinterError(CpnpError):
    def __init__(self, code: int):
        self.code = code
        super().__init__(f"printer error 0x{code:06x}: {ERRORS.get(code, 'unknown')}")


def _header(cmd: int, packet_id: int, session_id: int = 0, length: int = 0) -> bytes:
    return MAGIC + bytes((_REQ, cmd, 0, 0)) + struct.pack(">HHI", packet_id, session_id, length)


@dataclass
class Response:
    cmd: int
    error: int
    packet_id: int
    session_id: int
    payload: bytes
    raw: bytes


def _parse(data: bytes, cmd: int) -> Response:
    start = data.find(MAGIC + bytes((_RESP, cmd)))
    if start < 0 or len(data) - start < 16:
        raise CpnpError(f"no valid reply to command 0x{cmd:02x}: {data[:24].hex()}")
    raw = data[start:]
    err, pid, sid, length = struct.unpack(">HHHI", raw[6:16])
    return Response(cmd, err, pid, sid, raw[16:16 + length], raw)


def _u16(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 2], "little")


def _u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "little")


@dataclass
class IdleStatus:
    """Connectionless status (512-byte UDP Read reply, no session needed)."""
    printer_status: int
    paper_tray: int
    ink_cassette: int
    power: int
    battery: int
    error: int
    firmware_ext: str
    firmware_int: str
    min_jpeg: tuple[int, int]
    max_jpeg: tuple[int, int]
    serial: str

    @classmethod
    def parse(cls, b: bytes) -> "IdleStatus":
        if len(b) < 368:
            raise CpnpError(f"status reply too short ({len(b)} bytes)")
        return cls(
            printer_status=b[0], paper_tray=b[2], ink_cassette=b[3], power=b[66], battery=b[67],
            error=_u32(b, 68),
            firmware_ext=".".join(b[80:84].decode("ascii", "replace")),
            firmware_int=f"{b[84]}.{b[86]}",
            min_jpeg=(_u16(b, 132), _u16(b, 134)), max_jpeg=(_u16(b, 136), _u16(b, 138)),
            serial=b[336:368].split(b"\0", 1)[0].decode("ascii", "replace"),
        )

    def describe(self) -> dict[str, str]:
        return {
            "state": PRINTER_STATES.get(self.printer_status, f"0x{self.printer_status:02x}"),
            "paper tray": PAPER_TRAYS.get(self.paper_tray, f"0x{self.paper_tray:02x}"),
            "ink cassette": INK_CASSETTES.get(self.ink_cassette, f"0x{self.ink_cassette:02x}"),
            "power": POWER.get(self.power, str(self.power)),
            "battery": "n/a" if self.battery == 255 else f"level {self.battery}/4",
            "error": ERRORS.get(self.error, f"0x{self.error:06x}"),
            "firmware": f"{self.firmware_ext} (internal {self.firmware_int})",
            "JPEG limits": f"{self.min_jpeg[0]}x{self.min_jpeg[1]} .. {self.max_jpeg[0]}x{self.max_jpeg[1]}",
            "serial": self.serial,
        }


@dataclass
class JobStatus:
    """Status read over the session's TCP channel."""
    device_type: int
    power: int
    status: int
    battery: int
    error: int
    data_request: int
    retry: int
    offset: int
    size: int
    spooled: int
    printed: int

    @classmethod
    def parse(cls, b: bytes) -> "JobStatus":
        if len(b) < 64:
            raise CpnpError(f"job status too short ({len(b)} bytes)")
        return cls(b[2], b[6], _u16(b, 8), b[11], _u32(b, 12), _u32(b, 16), _u32(b, 20),
                   _u32(b, 24), _u32(b, 28), b[40], b[41])

    @property
    def is_print_data(self) -> bool:
        return (self.data_request & 0xFFFFFF00) == DataRequest.PRINT_DATA

    @property
    def is_oc_data(self) -> bool:
        return (self.data_request | 0xFF) == DataRequest.OC_DATA

    @property
    def page(self) -> int:
        return self.data_request & 0xFF

    @property
    def status_name(self) -> str:
        try:
            return DeviceStatus(self.status).name
        except ValueError:
            return f"0x{self.status:04x}"

    def request_key(self) -> tuple[int, int, int, int]:
        return (self.data_request, self.retry, self.offset, self.size)


@dataclass
class PrintPage:
    jpeg: bytes
    width: int
    height: int
    paper_code: int                 # media.Paper.cpnp_size
    finish: int = 2                 # media.FINISHES
    auto_correct: bool = False
    mask: bytes | None = None       # packed 1-bit overcoat mask
    mask_size: tuple[int, int] = (0, 0)


# Print command codes (little-endian block inside Write payloads)
_CODE_PRINT_DATA, _CODE_CANCEL, _CODE_END, _CODE_OC_DATA = 1, 2, 3, 5
_CODE_START_SPOOL, _CODE_EXECUTE_SPOOL = 7, 8
_TRANSFER_HDR = 104
_MAX_SPOOL = 20


def _le(buf: bytearray, off: int, size: int, value: int) -> None:
    buf[off:off + size] = value.to_bytes(size, "little")


def make_start_spool(pages: list[PrintPage]) -> bytes:
    first = pages[0]
    b = bytearray(192)
    _le(b, 2, 2, _CODE_START_SPOOL)
    _le(b, 4, 4, 192)
    _le(b, 8, 4, 0)                                   # JPEG "easy print"
    _le(b, 12, 2, min(len(pages), _MAX_SPOOL))
    _le(b, 14, 2, first.paper_code)
    b[16] = 1                                         # overcoat setting: per page
    b[17] = 3 if first.auto_correct else 2            # printer-side image optimize
    b[18] = 2                                         # borderless (borders are drawn into the image)
    b[19] = first.finish
    for i, p in enumerate(pages[:_MAX_SPOOL]):
        _le(b, 32 + 8 * i, 4, len(p.jpeg))
        if p.mask:
            _le(b, 36 + 8 * i, 4, len(p.mask))
    return bytes(b)


def make_simple(code: int) -> bytes:
    b = bytearray(64)
    _le(b, 2, 2, code)
    _le(b, 4, 4, 64)
    return bytes(b)


def make_print_data(page: PrintPage, offset: int, size: int) -> bytes:
    chunk = page.jpeg[offset:offset + size]
    b = bytearray(_TRANSFER_HDR)
    _le(b, 2, 2, _CODE_PRINT_DATA)
    _le(b, 4, 4, _TRANSFER_HDR + len(chunk))
    _le(b, 12, 4, 1)
    _le(b, 20, 4, len(page.jpeg))
    _le(b, 24, 4, page.width)
    _le(b, 28, 4, page.height)
    b[32] = 255 if page.mask else 2                   # client overcoat data / none
    _le(b, 96, 4, offset)
    _le(b, 100, 4, len(chunk))
    return bytes(b) + chunk


def make_oc_data(page: PrintPage, offset: int, size: int) -> bytes:
    assert page.mask is not None
    chunk = page.mask[offset:offset + size]
    b = bytearray(_TRANSFER_HDR)
    _le(b, 2, 2, _CODE_OC_DATA)
    _le(b, 4, 4, _TRANSFER_HDR + len(chunk))
    _le(b, 8, 4, 1)                                   # whole 1-bit bitmap
    _le(b, 12, 4, len(page.mask))
    _le(b, 16, 4, page.mask_size[0])
    _le(b, 20, 4, page.mask_size[1])
    _le(b, 96, 4, offset)
    _le(b, 100, 4, len(chunk))
    return bytes(b) + chunk


def discover(timeout: float = 2.0) -> list[tuple[str, str]]:
    """Broadcast a DeviceId request; returns [(ip, device-id string)]."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.3)
    s.sendto(_header(Cmd.DEVICE_ID, 1, 0, 4) + bytes(4), ("255.255.255.255", PORT))
    found: dict[str, str] = {}
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            data, (ip, _) = s.recvfrom(4096)
        except socket.timeout:
            continue
        try:
            found[ip] = _device_id_text(_parse(data, Cmd.DEVICE_ID))
        except CpnpError:
            pass
    s.close()
    return sorted(found.items())


def _device_id_text(r: Response) -> str:
    return r.payload[2:].split(b"\0", 1)[0].decode("ascii", "replace")


class Selphy:
    def __init__(self, host: str, timeout: float = 3.0, client_name: str = "selphy-cli"):
        self.host = host
        self.timeout = timeout
        self.client_name = client_name
        self._pid = 1
        self.session = 0
        self._tcp: socket.socket | None = None
        self.max_write = 4096

    # ---------- low level ----------
    def _next_pid(self) -> int:
        self._pid = self._pid + 1 if self._pid < 0x7FFF else 1
        return self._pid

    def _udp(self, packet: bytes, cmd: int) -> Response:
        last: Exception | None = None
        for _ in range(3):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.settimeout(self.timeout)
                s.connect((self.host, PORT))
                s.send(packet)
                try:
                    return _parse(s.recv(65535), cmd)
                except (socket.timeout, CpnpError) as e:
                    last = e
        raise CpnpError(f"no reply from {self.host}:{PORT} ({last})")

    def _recv_packet(self) -> bytes:
        assert self._tcp is not None
        buf = b""
        while True:
            chunk = self._tcp.recv(65535)
            if not chunk:
                raise CpnpError("connection closed by printer")
            buf += chunk
            start = buf.find(MAGIC)
            if start >= 0 and len(buf) - start >= 16:
                length = struct.unpack(">I", buf[start + 12:start + 16])[0]
                if len(buf) - start >= 16 + length:
                    return buf[start:start + 16 + length]

    def _tcp_call(self, cmd: int, payload: bytes = b"") -> Response:
        assert self._tcp is not None
        self._tcp.sendall(_header(cmd, self._next_pid(), self.session, len(payload)) + payload)
        r = _parse(self._recv_packet(), cmd)
        if r.error:
            raise CpnpError(f"command 0x{cmd:02x} failed with error 0x{r.error:04x}")
        return r

    # ---------- connectionless ----------
    def device_id(self) -> dict[str, str]:
        r = self._udp(_header(Cmd.DEVICE_ID, self._next_pid(), 0, 4) + bytes(4), Cmd.DEVICE_ID)
        fields = {}
        for part in _device_id_text(r).split(";"):
            if ":" in part:
                k, v = part.split(":", 1)
                fields[k.strip()] = v.strip()
        return fields

    def idle_status(self) -> IdleStatus:
        r = self._udp(_header(Cmd.READ, self._next_pid()), Cmd.READ)
        return IdleStatus.parse(r.payload)

    # ---------- session ----------
    def open(self, wait: float = 30.0) -> None:
        retry, stamp = 0, 0
        deadline = time.monotonic() + wait
        while True:
            pkt = bytearray(408)
            pkt[0:16] = _header(Cmd.SESSION_START, self._next_pid(), 0, 392)
            pkt[16:20] = retry.to_bytes(4, "big")
            pkt[20:24] = stamp.to_bytes(4, "big")
            name = self.client_name.encode("utf-16-be")[:64]
            pkt[24:24 + len(name)] = name
            for off, text in ((88, SESSION_USER), (152, SESSION_DOCUMENT)):
                enc = text.encode("utf-16-be")
                pkt[off:off + len(enc)] = enc
            r = self._udp(bytes(pkt), Cmd.SESSION_START)
            if r.error == 0:
                self.session = struct.unpack(">H", r.raw[10:12])[0]
                port = struct.unpack(">H", r.raw[20:22])[0]
                break
            if r.error not in SESSION_BUSY_ERRORS or time.monotonic() > deadline:
                raise PrinterBusy(f"session refused (0x{r.error:04x})")
            retry += 1
            stamp = struct.unpack(">I", r.raw[16:20])[0]
            time.sleep(1.0)
        if not self.session or not port:
            raise CpnpError("printer returned no session")
        self._tcp = socket.create_connection((self.host, port), timeout=self.timeout)
        self._tcp.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            self._tcp_call(Cmd.SET_MAX_WRITE, DEFAULT_MAX_WRITE.to_bytes(4, "big"))
        except CpnpError:
            pass
        try:
            r = self._tcp_call(Cmd.GET_MAX_WRITE)
            self.max_write = struct.unpack(">I", r.raw[16:20])[0] or 4096
        except CpnpError:
            self.max_write = 4096

    def close(self) -> None:
        if self._tcp:
            try:
                self._tcp.close()
            finally:
                self._tcp = None
        if self.session:
            try:
                self._udp(_header(Cmd.SESSION_END, self._next_pid(), self.session), Cmd.SESSION_END)
            except CpnpError:
                pass
            self.session = 0

    def __enter__(self) -> "Selphy":
        self.open()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def job_status(self) -> JobStatus:
        for _ in range(100):
            r = self._tcp_call(Cmd.READ)
            if r.payload:
                return JobStatus.parse(r.payload)
            time.sleep(0.01)
        raise CpnpError("printer sent no status")

    def write(self, data: bytes) -> None:
        sent = 0
        while sent < len(data):
            block = min(self.max_write, len(data) - sent)
            accepted = 0
            deadline = time.monotonic() + 30
            while accepted < block:
                r = self._tcp_call(Cmd.WRITE, data[sent + accepted:sent + block])
                accepted += struct.unpack(">I", r.raw[16:20])[0]
                if accepted < block:
                    if time.monotonic() > deadline:
                        raise CpnpError("printer stopped accepting data")
                    time.sleep(0.2)
            sent += block

    # ---------- printing ----------
    def print_pages(self, pages: list[PrintPage],
                    on_status: Callable[[JobStatus], None] | None = None,
                    timeout: float = 120.0) -> None:
        """Spool up to 20 pages. Returns once the printer has all data; printing
        continues on the printer (watch it with ``idle_status``)."""
        if not 1 <= len(pages) <= _MAX_SPOOL:
            raise ValueError(f"1..{_MAX_SPOOL} pages per job")
        if len({(p.paper_code, p.finish, p.auto_correct) for p in pages}) != 1:
            raise ValueError("all pages in one job must share paper size, finish and auto-correct")
        idle = self.idle_status()
        if idle.error & ERROR_FATAL == ERROR_FATAL or idle.error & 0xFFFF0000 == ERROR_RECOVERABLE:
            raise PrinterError(idle.error)

        with self:
            deadline = time.monotonic() + timeout
            while self.job_status().data_request != DataRequest.START_PRINT:
                if time.monotonic() > deadline:
                    raise CpnpError("printer never became ready to print")
                time.sleep(0.1)
            self.write(make_start_spool(pages))

            last_key = None
            requested: set[int] = set()
            while True:
                st = self.job_status()
                if on_status:
                    on_status(st)
                if st.status == DeviceStatus.WAIT_DISCONNECT_SESSION:
                    return
                if st.error and (st.error & 0xFFFF0000) not in (0, ERROR_RECOVERABLE):
                    raise PrinterError(st.error)
                key = st.request_key()
                if key != last_key and (st.is_print_data or st.is_oc_data):
                    last_key = key
                    page = pages[st.page]
                    requested.add(st.page)
                    maker = make_print_data if st.is_print_data else make_oc_data
                    self.write(maker(page, st.offset, st.size))
                    deadline = time.monotonic() + timeout
                    continue
                if st.data_request == DataRequest.EXECUTE_SPOOL_PRINT:
                    if len(requested) >= len(pages):
                        return
                    if key != last_key:
                        last_key = key
                        self.write(make_simple(_CODE_EXECUTE_SPOOL))
                elif st.data_request == DataRequest.END_PRINT and key != last_key:
                    last_key = key
                    self.write(make_simple(_CODE_END))
                elif st.data_request == DataRequest.START_PRINT and requested:
                    return
                if time.monotonic() > deadline:
                    raise CpnpError(f"timed out (status {st.status_name}, request 0x{st.data_request:x})")
                time.sleep(0.1)


def cancel(host: str) -> None:
    with Selphy(host) as p:
        p.write(make_simple(_CODE_CANCEL))

