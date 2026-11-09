# selphy-cli — reference implementation and command-line printer for Canon SELPHY CP1500

Proof-of-concept CLI. No Canon software, no cloud, only Python + Pillow.

Two transports:

| `--via` | Link | Features |
|---|---|---|
| `cpnp` (default) | Wi-Fi/LAN, Canon's own protocol | finish (gloss / semigloss / satin), **custom overcoat masks**, printer auto-correct, live Y/M/C/overcoat status, ≤20 sheets per job |
| `ipp` | USB via `ipp-usb` (`ipp://localhost:60000/ipp/print`) or network | standard borderless JPEG printing, copies |

```bash
cd ~/Documents/Selphy/cli
python3 -m selphy discover
python3 -m selphy status                 # CPNP (Wi-Fi)
python3 -m selphy status --ipp           # IPP over USB

# preview only — writes print JPEG, preview PNG and mask PNG to ./out
python3 -m selphy print photo.jpg --finish satin --mask-text "Paris\n2026" --dry-run

# real prints
python3 -m selphy print photo.jpg                                   # glossy, borderless postcard
python3 -m selphy print photo.jpg --finish semigloss --border 4     # 4 mm white border
python3 -m selphy print a.jpg b.jpg --paper card --copies 2
python3 -m selphy print photo.jpg --mask-image signature.png --mask-scale 0.3
python3 -m selphy print photo.jpg --mask-pattern linen --mask-frame 5
python3 -m selphy print photo.jpg --via ipp                         # over the USB cable
```

Set `SELPHY_HOST=<printer IP>` to skip discovery.

## Overcoat masks
White pixels in the mask get the textured overcoat; black stays the chosen finish.
Building blocks (combine freely): `--mask-text`, `--mask-image`, `--mask-pattern
{lines,crosshatch,dots,checker,waves,linen}`, `--mask-frame MM`, `--mask-invert`.

## Layout
- `selphy/cpnp.py` — CPNP protocol (discovery, status, session, spool, data pull)
- `selphy/ipp.py` — tiny IPP client
- `selphy/imaging.py` — fit/fill/borders at 300 dpi with bleed, overcoat mask builder, preview
- `selphy/media.py` — paper geometry (Postcard, L, Card)

Protocol notes: [`../../docs/PROTOCOL.md`](../../docs/PROTOCOL.md).
