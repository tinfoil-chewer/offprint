"""Paper geometry for SELPHY CP-series printers (300 dpi).

Values come from SELPHY Photo Layout's ``assets/paper.json`` (image/bleed sizes) and
the overcoat mask dimensions used in ``CPNPMakedata.OvercoatInfo``.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Paper:
    key: str
    name: str
    ipp_media: str            # IPP media keyword
    ipp_size: tuple[int, int]  # IPP media-size in 1/100 mm (portrait)
    cpnp_size: int            # CPNP StartSpool print-size code
    image: tuple[int, int]    # full borderless print image incl. bleed (px)
    paper: tuple[int, int]    # physically visible paper area (px)
    mask: tuple[int, int]     # overcoat mask size (px), centred on the image

    @property
    def landscape(self) -> bool:
        return self.image[0] > self.image[1]

    @property
    def bleed(self) -> tuple[int, int]:
        """Pixels of the image hidden past each edge (x, y)."""
        return ((self.image[0] - self.paper[0]) // 2, (self.image[1] - self.paper[1]) // 2)


POSTCARD = Paper("postcard", "Postcard 100x148 mm", "jpn_hagaki_100x148mm", (10000, 14800),
                 4, (1248, 1872), (1184, 1752), (1232, 1800))
L_SIZE = Paper("l", "L 89x119 mm", "om_dsc-photo_89x119mm", (8900, 11900),
               3, (1152, 1472), (1054, 1409), (1100, 1456))
CARD = Paper("card", "Card 54x86 mm", "om_card_54x86mm", (5400, 8600),
             2, (1088, 668), (1018, 640), (1040, 668))

PAPERS = {p.key: p for p in (POSTCARD, L_SIZE, CARD)}

# CPNP StartSpool "print finish" byte.  Names match the Canon app's SurfaceFinish enum.
FINISHES = {"gloss": 2, "semigloss": 4, "satin": 5}
