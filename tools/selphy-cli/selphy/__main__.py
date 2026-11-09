"""selphy — offline printing for Canon SELPHY CP1500.

  python -m selphy discover
  python -m selphy status [--host IP | --ipp URI]
  python -m selphy print photo.jpg [--finish satin] [--mask-text "Paris 2026"] [--dry-run]
"""
from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

from . import cpnp, imaging, ipp
from .media import FINISHES, PAPERS

USB_IPP = "ipp://localhost:60000/ipp/print"


def _host(args) -> str:
    if args.host:
        return args.host
    if os.environ.get("SELPHY_HOST"):
        return os.environ["SELPHY_HOST"]
    found = cpnp.discover()
    if not found:
        sys.exit("No SELPHY found on the network. Pass --host IP or use --via ipp for USB.")
    return found[0][0]


def cmd_discover(args) -> None:
    found = cpnp.discover(args.timeout)
    if not found:
        print("No printers answered on UDP 8609.")
    for ip, devid in found:
        model = dict(p.split(":", 1) for p in devid.split(";") if ":" in p).get("MDL", devid)
        print(f"{ip:16} {model}")


def cmd_status(args) -> None:
    if args.ipp:
        a = ipp.IppPrinter(args.ipp).attributes(
            "printer-state", "printer-state-reasons", "media-ready", "printer-firmware-string-version")
        print(f"state      {ipp.PRINTER_STATES.get(a['printer-state'][0])}")
        print(f"reasons    {', '.join(a.get('printer-state-reasons', []))}")
        print(f"media      {', '.join(a.get('media-ready', []))}")
        print(f"firmware   {a.get('printer-firmware-string-version', ['?'])[0]}")
        return
    host = _host(args)
    st = cpnp.Selphy(host).idle_status()
    print(f"printer    {host}")
    for k, v in st.describe().items():
        if v:
            print(f"{k:10} {v}")


def _build_mask(args, paper) -> imaging.Mask | None:
    if not (args.mask_text or args.mask_image or args.mask_pattern or args.mask_frame):
        return None
    m = imaging.Mask(paper)
    if args.mask_pattern:
        m.pattern(args.mask_pattern, spacing_mm=args.mask_spacing)
    if args.mask_frame:
        m.frame(args.mask_frame)
    if args.mask_image:
        m.image(args.mask_image, threshold=args.mask_threshold, scale=args.mask_scale)
    if args.mask_text:
        m.text(args.mask_text.replace("\\n", "\n"), size_mm=args.mask_text_size,
               position=args.mask_text_pos, angle=args.mask_text_angle)
    if args.mask_invert:
        m.invert()
    return m


def _status_line(st: cpnp.JobStatus) -> str:
    return f"  {st.status_name:24} request=0x{st.data_request:05x} spooled={st.spooled} printed={st.printed}"


def _watch_cpnp(host: str, timeout: float = 240) -> None:
    """Follow the print through the Y/M/C/overcoat passes via idle status."""
    p = cpnp.Selphy(host)
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            st = p.idle_status()
        except cpnp.CpnpError:
            time.sleep(1)
            continue
        state = (st.printer_status, st.error)
        if state != last:
            d = st.describe()
            print(f"  printer {d['state']}" + (f" — {d['error']}" if st.error else ""))
            last = state
        if st.printer_status == 1 and not st.error and last is not None:
            return
        time.sleep(1)


def cmd_print(args) -> None:
    paper = PAPERS[args.paper]
    layout = imaging.Layout(fit=args.fit, border_mm=args.border, background=args.background)
    if args.via == "ipp" and (args.finish != "gloss" or _build_mask(args, paper) or args.auto_correct):
        sys.exit("Finish, overcoat masks and auto-correct need --via cpnp (Wi-Fi).")
    if args.via == "cpnp" and args.copies > 1 and len(args.images) * args.copies > 20:
        sys.exit("CPNP spools at most 20 sheets per job.")

    pages, previews = [], []
    outdir = Path(args.out)
    for path in args.images:
        photo = imaging.render(imaging.load(path), paper, layout)
        mask = _build_mask(args, paper)
        stem = Path(path).stem
        if args.dry_run or args.save_preview:
            outdir.mkdir(parents=True, exist_ok=True)
            photo.save(outdir / f"{stem}_{paper.key}.jpg", quality=95)
            imaging.preview(photo, mask, paper).save(outdir / f"{stem}_{paper.key}_preview.png")
            if mask:
                mask.bitmap().save(outdir / f"{stem}_{paper.key}_mask.png")
                previews.append(f"{stem}: mask covers {mask.coverage():.1%}")
        jpeg = imaging.to_jpeg(photo)
        pages.append((photo, jpeg, mask, stem))

    if args.dry_run:
        print(f"Dry run — wrote previews to {outdir.resolve()}")
        for line in previews:
            print("  " + line)
        return

    if args.via == "ipp":
        printer = ipp.IppPrinter(args.ipp or USB_IPP)
        for photo, jpeg, _, stem in pages:
            if paper.landscape:      # IPP media sizes are portrait
                jpeg = imaging.to_jpeg(photo.rotate(90, expand=True))
            job = printer.print_jpeg(jpeg, paper, borderless=True, copies=args.copies, name=stem)
            print(f"Sent {stem} as IPP job {job}")
            while True:
                a = printer.job(job)
                state = ipp.JOB_STATES.get(a.get("job-state", [0])[0], "?")
                print(f"  job {job}: {state}", end="\r", flush=True)
                if state in ("completed", "canceled", "aborted"):
                    print()
                    break
                time.sleep(2)
        return

    if pages[0][2] is not None and args.finish != "gloss":
        print(f"note: a custom overcoat replaces the {args.finish} finish — only the design areas are textured,"
              " the rest prints glossy.")
    host = _host(args)
    sheets = [cpnp.PrintPage(jpeg=jpeg, width=photo.width, height=photo.height,
                             paper_code=paper.cpnp_size, finish=FINISHES[args.finish],
                             auto_correct=args.auto_correct,
                             mask=mask.pack() if mask else None,
                             mask_size=paper.mask if mask else (0, 0))
              for photo, jpeg, mask, _ in pages for _ in range(args.copies)]
    print(f"Printing {len(sheets)} sheet(s) on {paper.name} to {host} — finish {args.finish}"
          + (", custom overcoat" if sheets[0].mask else ""))
    last = [None]

    def show(st: cpnp.JobStatus) -> None:
        key = (st.status, st.data_request, st.spooled)
        if args.verbose or key != last[0]:
            print(_status_line(st))
            last[0] = key

    cpnp.Selphy(host).print_pages(sheets, on_status=show)
    print("All data sent; printer is printing.")
    _watch_cpnp(host)
    print("Done.")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="selphy", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("discover", help="find SELPHY printers on the LAN")
    d.add_argument("--timeout", type=float, default=2.0)
    d.set_defaults(func=cmd_discover)

    s = sub.add_parser("status", help="printer status")
    s.add_argument("--host")
    s.add_argument("--ipp", nargs="?", const=USB_IPP, help="query via IPP (default: USB)")
    s.set_defaults(func=cmd_status)

    p = sub.add_parser("print", help="print photos")
    p.add_argument("images", nargs="+")
    p.add_argument("--via", choices=("cpnp", "ipp"), default="cpnp",
                   help="cpnp = Wi-Fi with all features (default); ipp = standard (USB or network)")
    p.add_argument("--host", help="printer IP for cpnp (default: $SELPHY_HOST or auto-discover)")
    p.add_argument("--ipp", help=f"IPP URI (default {USB_IPP})")
    p.add_argument("--paper", choices=PAPERS, default="postcard")
    p.add_argument("--finish", choices=FINISHES, default="gloss")
    p.add_argument("--fit", choices=("fill", "fit"), default="fill")
    p.add_argument("--border", type=float, default=0.0, metavar="MM", help="white border width")
    p.add_argument("--background", default="white")
    p.add_argument("--auto-correct", action="store_true", help="printer-side image optimize")
    p.add_argument("--copies", type=int, default=1)
    g = p.add_argument_group("custom overcoat (cpnp only)")
    g.add_argument("--mask-text")
    g.add_argument("--mask-text-size", type=float, default=8.0, metavar="MM")
    g.add_argument("--mask-text-pos", default="bottom-right",
                   choices=[f"{v}-{h}" for v in ("top", "center", "bottom")
                            for h in ("left", "center", "right")] + ["center"])
    g.add_argument("--mask-text-angle", type=float, default=0.0)
    g.add_argument("--mask-image", help="logo/signature; dark pixels become texture")
    g.add_argument("--mask-threshold", type=int, default=128)
    g.add_argument("--mask-scale", type=float, default=0.5)
    g.add_argument("--mask-pattern", choices=("lines", "crosshatch", "dots", "checker", "waves", "linen"))
    g.add_argument("--mask-spacing", type=float, default=3.0, metavar="MM")
    g.add_argument("--mask-frame", type=float, metavar="MM", help="textured frame band")
    g.add_argument("--mask-invert", action="store_true")
    p.add_argument("--dry-run", action="store_true", help="only write print/preview/mask files")
    p.add_argument("--save-preview", action="store_true")
    p.add_argument("--out", default="out")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(func=cmd_print)

    args = ap.parse_args(argv)
    try:
        args.func(args)
    except (cpnp.CpnpError, ipp.IppError) as e:
        sys.exit(f"error: {e}")
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
