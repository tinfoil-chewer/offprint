# Canon SELPHY CP1500 — printing protocols

Notes for anyone building their own software for the SELPHY CP1500 (and likely other recent CP models).
Everything here was worked out for interoperability: by observing the printer, querying its standard
interfaces, and studying how Canon's SELPHY Photo Layout app (Android, v4.4.0) talks to it. No Canon code or
assets are included in this repository.

Tested printer: SELPHY CP1500, firmware 1.0.7.0 (internal 1.39).

## Overview

| Path | Link | Features |
|---|---|---|
| **IPP** (IPP Everywhere / Mopria 2.1 / AirPrint) | USB (IPP-over-USB) or network | JPEG / PWG raster / URF; Postcard, L, Card; bordered or borderless; colour or mono; copies 1–99; job status |
| **CPNP** (Canon's own protocol) | Network only (UDP/TCP) | Everything above **plus** finish (Gloss / Semi-gloss / Satin), **custom 1-bit overcoat masks**, printer-side auto-correct, up to 20 sheets per spool, live yellow/magenta/cyan/overcoat pass status, paper / ink / battery status |

Neither needs the internet.

---

## 1. IPP

On Linux, [`ipp-usb`](https://github.com/OpenPrinting/ipp-usb) exposes a USB-connected CP1500 at
`ipp://localhost:60000/ipp/print`. Over the network it is `ipp://<printer>/ipp/print`.
Full attribute dump: [`cp1500-ipp-attributes.txt`](cp1500-ipp-attributes.txt). Highlights:

```
document-format-supported  image/urf, application/octet-stream, image/jpeg, image/pwg-raster
media-supported            jpn_hagaki_100x148mm (Postcard), om_dsc-photo_89x119mm (L), om_card_54x86mm (Card)
media-col-database         each size with margins (bordered) and with 0 margins (borderless)
print-scaling-supported    auto, auto-fit, fill, fit, none
copies-supported           1-99
jpeg-k-octets-supported    0-32768
printer-resolution         300dpi
print-quality-supported    normal        (no finish control over IPP)
```

USB interfaces (`04a9:3302`): interface 0 alt 0 is a classic bidirectional printer interface (used by
Gutenprint's `canonselphyneo` backend); interface 0/1 alt 1 are IPP-over-USB (protocol 4).
`ipp-usb` and Gutenprint's USB backend can't use the device at the same time.

**Finishes over USB:** not possible as far as we can tell. Canon ships no computer driver for the CP1500
(Windows/macOS use their built-in driverless printing, which offers paper size, borders, orientation and
copies only). IPP exposes no finish attributes and the firmware image is encrypted.

---

## 2. CPNP

### 2.1 Framing

Every packet starts with a 16-byte **big-endian** header:

```
0   "CPNP"
4   u8   0x01 request, 0x81 response
5   u8   command
6   u16  error (responses; 0 = OK)
8   u16  packet id (incrementing)
10  u16  session id (0 outside a session)
12  u32  payload length
16  payload
```

| Cmd | Name | Transport | Notes |
|---|---|---|---|
| `0x30` | DeviceId | UDP 8609 | payload: 4 zero bytes. Reply: IEEE-1284 device id at payload+2. Broadcast it for discovery |
| `0x20` | Read | UDP 8609 (no session) / TCP (session) | status, see 2.4 |
| `0x10` | SessionStart | UDP 8609 | 408 bytes, see below. Reply: session id at byte 10, **TCP port** at bytes 20–21 |
| `0x11` | SessionEnd | UDP 8609 | header only, with session id |
| `0x52` / `0x51` | Set / GetMaxWriteSize | TCP | value is a BE u32 at byte 16 (Canon's app uses `0x8400` = 33 792) |
| `0x21` | Write | TCP | payload = print commands (2.2). Reply: BE u32 at byte 16 = bytes accepted; resend the rest |

**SessionStart (408 bytes):** header with length `0x188`; bytes 16–19 retry count and 20–23 timestamp
(both 0 on the first try); UTF-16BE strings: client name at 24 (≤ 64 bytes), user `"SPL v2.0"` at 88,
document `"Square"` at 152. A busy printer answers with error `0x8501`/`0x8502`; retry with the retry count
incremented and the timestamp copied from reply bytes 16–19.

In the printer's direct Wi-Fi mode (no router) it is always at **192.168.0.1**.

### 2.2 Print commands (inside Write payloads) — **little-endian**

Common header: `0x00 u16 type (0 = print)`, `0x02 u16 code`, `0x04 u32 size`.

| Code | Command | Size |
|---|---|---|
| 0 | StartPrint | 64 |
| 1 | PrintDataTransfer (JPEG chunk) | 104 + chunk |
| 2 | CancelPrint | 64 |
| 3 | EndPrint | 64 |
| 5 | OvercoatDataTransfer (mask chunk) | 104 + chunk |
| 6 | ResumePrint | 64 |
| 7 | StartSpool | 192 |
| 8 | ExecuteSpoolPrint | 64 |

**StartSpool (192 bytes)**

```
0x08 u32  data type        0 = JPEG
0x0C u16  sheet count      ≤ 20
0x0E u16  paper            2 Card | 3 L | 4 Postcard   (0 auto)
0x10 u8   overcoat setting 1 = per page
0x11 u8   image optimize   2 off | 3 on (printer-side auto-correct)
0x12 u8   border           2 = borderless (draw borders into the image yourself)
0x13 u8   finish           2 Gloss | 4 Semi-gloss | 5 Satin   (0 auto)
0x20+8n u32 JPEG size of sheet n
0x24+8n u32 overcoat mask size of sheet n (0 = none)
```

**PrintDataTransfer header (104 bytes):** `0x0C` u32 1, `0x14` JPEG total size, `0x18` width, `0x1C` height,
`0x20` u8 overcoat (`255` = a client mask follows, `2` = none), `0x60` chunk offset, `0x64` chunk size;
JPEG bytes follow.

**OvercoatDataTransfer header (104 bytes):** `0x08` u32 1 (1-bit bitmap), `0x0C` mask size, `0x10` width,
`0x14` height, `0x18`/`0x1C` offset x/y (0), `0x60` chunk offset, `0x64` chunk size; mask bytes follow.

### 2.3 Job flow

1. Read idle status over UDP; stop on an error.
2. SessionStart (UDP) → connect to the returned TCP port → SetMaxWriteSize / GetMaxWriteSize.
3. Poll Read until data-request = `0x10000` (START_PRINT), then Write **StartSpool**.
4. Poll Read. The printer **pulls** data: data-request `0x200nn` (JPEG of sheet nn) or `0x2FFnn` (mask of
   sheet nn), with the byte offset at status +24 and size at +28. Answer each new request with a
   PrintDataTransfer / OvercoatDataTransfer for exactly that range.
5. When it asks for `0x70000` (EXECUTE_SPOOL_PRINT) and every sheet has been sent, end the session; the
   printer prints on its own. Answer `0x30000` (END_PRINT) with EndPrint.
6. Follow progress with idle-status reads (state 2 = busy, back to 1 = idle).

### 2.4 Status

**Idle status** (UDP Read, 512-byte payload, little-endian): byte 0 state (1 idle, 2 busy, 241 error),
2 paper tray and 3 ink cassette (1 none, 2 Card, 3 L, 4 Postcard), 66 power (0 AC, 1 battery, 2 USB),
67 battery level (255 = n/a), 68 u32 error, 80 firmware as ASCII (e.g. `"1070"` = 1.0.7.0), 84 internal
firmware, 132–138 min/max JPEG width/height.

**Job status** (TCP Read): 2 device type, 8 u16 device status, 11 battery, 12 u32 error, 16 u32 data request,
20 retry, 24 offset, 28 size, 40 sheets spooled, 41 sheets printed.

Device status: `0x0000` idle, `0xFF01` preparing, `0xFF02/03` yellow heat/print, `0xFF04/05` magenta,
`0xFF06/07` cyan, `0xFF08/09` overcoat, `0xFF0A` finishing, `0xFF0C` paused on error, `0xFF10` feeding paper.

Errors (`error & 0xFFFF0000 == 0x10000` are recoverable, the printer waits): `0x10101` out of paper,
`0x10102` no paper tray, `0x10103` tray / cassette size mismatch, `0x10201` ribbon used up,
`0x10202` no ink cassette, `0xFF0104` paper jam.

### 2.5 Overcoat masks

The CP1500 takes a **1-bit bitmap for the clear overcoat layer**: raw, row-major, most significant bit
first, rows padded to whole bytes. Set bits print as a matte texture; everything else gets a glossy coat.

| Paper | Print JPEG (incl. bleed) | Visible paper | Mask | Mask bytes |
|---|---|---|---|---|
| Postcard | 1248 × 1872 | 1184 × 1752 | 1232 × 1800 | 277 200 |
| L | 1152 × 1472 | 1054 × 1409 | 1100 × 1456 | 200 928 |
| Card | 1088 × 668 | 1018 × 640 | 1040 × 668 | 86 840 |

The mask is centred on the print image (verified on Postcard prints).

**A mask overrides the finish:** tested on paper, Satin without a mask gives an even satin sheen; Satin
plus a mask gives a glossy sheet with only the mask areas textured (same as Gloss plus a mask). The whole
sheet is always coated either way.

### 2.6 Pairing QR code

The printer's smartphone-connection screen shows `SPLQR:2.0$<SSID>$<security>$<password>`:
SSID `CP1500-<6-character ID>-Q`, security `3` = WPA3 (otherwise WPA2), password 8–12 characters.

---

## 3. Background: what the official app sends to Canon

Observed in SELPHY Photo Layout 4.4.0 (Android): besides Firebase analytics and Canon account features,
the app reads the printer's usage counters (`http://<printer>:52280/scapi/prt_hist/`, network only) and
uploads them to a Canon log service. The counters include the printer serial number, firmware, prints by
source and paper size, which layouts and settings were used, error counts, Wi-Fi setup method and startup
temperature. Offprint talks only to the printer.

## 4. Related projects

- [Gutenprint / selphy_print](https://git.shaftnet.org/gitea/slp/selphy_print) — CUPS backend for SELPHY
  and other dye-sub printers (USB raster)
- [go-selphy-cp](https://github.com/gonzaloserrano/go-selphy-cp) — CPNP client for the CP900
- [selphy-pictbridge](https://github.com/KENJISHIH/selphy-pictbridge) — CP1300 printing from macOS
- [ipp-usb](https://github.com/OpenPrinting/ipp-usb) — IPP-over-USB daemon for Linux
