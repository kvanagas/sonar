"""Generates the white menu bar glyph, simplified from sonar-icon-chrome.svg:
a ring around a solid button face with the sonar arcs cut out.

sonar-menubar.svg                                       the glyph, drawn with a mask (for viewing/editing)
Sonar/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg  the same as one even-odd path (shipped)
"""
import math
from pathlib import Path

C = 50
RING_R, RING_W = 46, 6
FACE_R = 39
ARC_RADII, ARC_W = (9, 19, 29), 6


def arc(radius):
    """One arc radiating up-right, spanning 100° around the diagonal."""
    a0, a1 = math.radians(-95), math.radians(5)
    x0, y0 = C + radius * math.cos(a0), C + radius * math.sin(a0)
    x1, y1 = C + radius * math.cos(a1), C + radius * math.sin(a1)
    return f'<path d="M{x0:.2f} {y0:.2f}A{radius} {radius} 0 0 1 {x1:.2f} {y1:.2f}"/>'


def masked():
    arcs = "".join(arc(r) for r in ARC_RADII)
    return f"""<defs>
    <g id="w" fill="none" stroke="#000" stroke-width="{ARC_W}" stroke-linecap="round">{arcs}</g>
    <mask id="m">
      <rect width="100" height="100" fill="#fff"/>
      <use href="#w"/>
      <use href="#w" transform="rotate(180 {C} {C})"/>
    </mask>
  </defs>
  <circle cx="{C}" cy="{C}" r="{RING_R}" fill="none" stroke="#fff" stroke-width="{RING_W}"/>
  <circle cx="{C}" cy="{C}" r="{FACE_R}" fill="#fff" mask="url(#m)"/>"""


def svg(body, size=100):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" width="{size}" height="{size}">\n  {body}\n</svg>\n'


def circle_path(r):
    return f"M{C - r} {C}A{r} {r} 0 1 0 {C + r} {C}A{r} {r} 0 1 0 {C - r} {C}Z"


def arc_outline(radius, width, rotate):
    """A round-capped arc stroke as a closed shape, so it can be a hole in an even-odd fill."""
    h = width / 2
    a0, a1 = math.radians(-95 + rotate), math.radians(5 + rotate)

    def pt(r, a):
        return f"{C + r * math.cos(a):.2f} {C + r * math.sin(a):.2f}"

    ro, ri = radius + h, radius - h
    return (
        f"M{pt(ro, a0)}A{ro} {ro} 0 0 1 {pt(ro, a1)}"
        f"A{h} {h} 0 0 1 {pt(ri, a1)}"
        f"A{ri} {ri} 0 0 0 {pt(ri, a0)}"
        f"A{h} {h} 0 0 1 {pt(ro, a0)}Z"
    )


def flat():
    """The glyph as one even-odd path: asset catalogs don't render SVG masks."""
    parts = [circle_path(RING_R + RING_W / 2), circle_path(RING_R - RING_W / 2), circle_path(FACE_R)]
    parts += [arc_outline(r, ARC_W, rot) for r in ARC_RADII for rot in (0, 180)]
    return f'<path fill="#000" fill-rule="evenodd" d="{"".join(parts)}"/>'


here = Path(__file__).parent
(here / "sonar-menubar.svg").write_text(svg(masked()))
# 16pt, the natural size next to the menu bar's SF Symbols.
(here.parent / "Sonar/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg").write_text(svg(flat(), 16))
