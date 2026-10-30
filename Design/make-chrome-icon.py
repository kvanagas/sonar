"""Generates sonar-icon-chrome.svg: a spun-aluminium cue button with engraved sonar arcs.

SVG has no conic gradient, so the anisotropic reflection of spun metal is built from
thin wedges, and the machining grooves from faint concentric rings.
"""
import math
import random
from pathlib import Path

C = 512  # canvas centre
FACE_R = 322
GROOVE_R = 334
BEZEL_R = 372


def spun_brightness(deg, light_deg):
    """Spun metal reflects in a bowtie: bright along one diameter, dark across it."""
    c = math.cos(math.radians(2 * (deg - light_deg)))
    side = 1 + 0.08 * math.cos(math.radians(deg - light_deg))  # lit side slightly brighter
    return (0.58 + 0.22 * c + 0.18 * max(c, 0) ** 10) * side


def gray(level):
    level = max(0.0, min(1.0, level))
    r, g, b = (round(level * v) for v in (246, 248, 252))
    return f"#{r:02x}{g:02x}{b:02x}"


def conic(radius, light_deg, steps=180):
    wedges = []
    step = 360 / steps
    for i in range(steps):
        a0, a1 = i * step - 0.4, (i + 1) * step + 0.4  # overlap hides seams
        p0 = (C + radius * math.cos(math.radians(a0)), C + radius * math.sin(math.radians(a0)))
        p1 = (C + radius * math.cos(math.radians(a1)), C + radius * math.sin(math.radians(a1)))
        fill = gray(spun_brightness(i * step + step / 2, light_deg))
        wedges.append(
            f'<path d="M{C} {C}L{p0[0]:.2f} {p0[1]:.2f}A{radius} {radius} 0 0 1 {p1[0]:.2f} {p1[1]:.2f}Z" fill="{fill}"/>'
        )
    return "\n      ".join(wedges)


def spun_rings(radius, seed):
    rng = random.Random(seed)
    rings = []
    r = 3.0
    while r < radius:
        color = "#fff" if rng.random() < 0.5 else "#000"
        rings.append(
            f'<circle cx="{C}" cy="{C}" r="{r:.1f}" stroke="{color}" stroke-opacity="{rng.uniform(0.02, 0.09):.3f}"/>'
        )
        r += rng.uniform(1.2, 2.6)
    return "\n      ".join(rings)


def arc(radius):
    """One arc radiating up-right, spanning 100° around the diagonal."""
    a0, a1 = math.radians(-95), math.radians(5)
    x0, y0 = C + radius * math.cos(a0), C + radius * math.sin(a0)
    x1, y1 = C + radius * math.cos(a1), C + radius * math.sin(a1)
    return f'<path d="M{x0:.2f} {y0:.2f}A{radius} {radius} 0 0 1 {x1:.2f} {y1:.2f}"/>'


ARCS = "\n      ".join(arc(r) for r in (80, 160, 240))
LIGHT = -135  # upper-left, in SVG angles (y down)

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2B2E34"/>
      <stop offset="1" stop-color="#0C0D10"/>
    </linearGradient>
    <radialGradient id="faceEdge" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0.86" stop-color="#000" stop-opacity="0"/>
      <stop offset="1" stop-color="#000" stop-opacity="0.35"/>
    </radialGradient>
    <linearGradient id="groove" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#050506"/>
      <stop offset="1" stop-color="#2A2C30"/>
    </linearGradient>
    <clipPath id="iconClip"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
    <clipPath id="faceClip"><circle cx="{C}" cy="{C}" r="{FACE_R}"/></clipPath>
    <clipPath id="bezelClip"><circle cx="{C}" cy="{C}" r="{BEZEL_R}"/></clipPath>
    <filter id="soften" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur stdDeviation="3"/>
    </filter>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000" flood-opacity="0.65"/>
    </filter>
    <g id="waves" fill="none" stroke-width="30" stroke-linecap="round">
      {ARCS}
    </g>
  </defs>

  <!-- macOS icon grid: 824pt rounded square centred in 1024. -->
  <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/>

  <!-- Bezel ring: spun with the highlight rotated so it contrasts with the face. -->
  <g clip-path="url(#iconClip)"><g filter="url(#shadow)">
    <circle cx="{C}" cy="{C}" r="{BEZEL_R}" fill="#9aa0a8"/>
  </g></g>
  <g clip-path="url(#bezelClip)">
    <g filter="url(#soften)">
      {conic(BEZEL_R + 20, LIGHT + 90)}
    </g>
  </g>
  <circle cx="{C}" cy="{C}" r="{BEZEL_R - 1.5}" fill="none" stroke="#fff" stroke-opacity="0.35" stroke-width="3"/>

  <!-- Dark gap between bezel and button. -->
  <circle cx="{C}" cy="{C}" r="{GROOVE_R}" fill="url(#groove)"/>

  <!-- Button face. -->
  <g clip-path="url(#faceClip)">
    <g filter="url(#soften)">
      {conic(FACE_R + 20, LIGHT)}
    </g>
    <g fill="none" stroke-width="1">
      {spun_rings(FACE_R, seed=7)}
    </g>
    <circle cx="{C}" cy="{C}" r="{FACE_R}" fill="url(#faceEdge)"/>
  </g>
  <circle cx="{C}" cy="{C}" r="{FACE_R - 1}" fill="none" stroke="#fff" stroke-opacity="0.5" stroke-width="2"/>

  <!-- Engraved arcs, lit from above: highlight on the lower lip, dark recess on top. -->
  <use href="#waves" stroke="#fff" stroke-opacity="0.7" transform="translate(0 3)"/>
  <use href="#waves" stroke="#fff" stroke-opacity="0.7" transform="rotate(180 {C} {C}) translate(0 -3)"/>
  <use href="#waves" stroke="#2E3136"/>
  <use href="#waves" stroke="#2E3136" transform="rotate(180 {C} {C})"/>
</svg>
"""

Path(__file__).with_name("sonar-icon-chrome.svg").write_text(svg)
