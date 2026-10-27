#!/usr/bin/env python3
"""Generates the app icon's layers and Design/AppIcon.svg.

The icon is a child's wooden sandbox, seen isometrically, with an agent (a
little blue robot) poking its head out of the sand. It follows the macOS 26
Liquid Glass style: flat, solid shapes in separate layers, with no drawn
shadows or highlights, since the system adds those itself.

Outputs:
- Design/AppIcon.icon/Assets/*.svg: the foreground layers of the Icon
  Composer icon, on its full-bleed 1024pt canvas. The background fill and how
  the layers are grouped, moved and lit live in Design/AppIcon.icon/icon.json,
  which Icon Composer edits.
- Design/AppIcon.svg: a flattened preview of the icon. It follows icon.json's
  layer order and offsets, so it matches what Icon Composer shows.
- Design/AppIconArtwork.svg: the preview's sandbox and agent without the
  background, cropped to the artwork, for the website's header. In it the
  agent peeks out of the sand when the page loads (see write_artwork).

The menu bar item draws a one-colour version of the same shapes in
NSImage.menuBarSandbox (Sources/Sandboxes/Views/MenuBarViews.swift), so
update it too when the shapes change.

Run from the repository root: python3 scripts/generate-app-icon.py
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DESIGN = ROOT / "Design"
ICON = DESIGN / "AppIcon.icon"
LAYERS = ICON / "Assets"

CANVAS = 1024
# The artwork is drawn on Apple's macOS icon grid: an 824pt rounded square
# centred on the canvas. Icon Composer's canvas is the icon shape itself, so
# the layers are scaled up by FULL_BLEED to fill it.
BODY = 824
INSET = (CANVAS - BODY) // 2
RADIUS = 185
FULL_BLEED = CANVAS / BODY

# The preview's background: the light fill from icon.json, a sky blue
# top-lit gradient, (top, bottom). The dark fill is the system's.
BACKGROUND = ("#D6ECFF", "#A9D3F7")
WOOD_TOP = "#E39B5B"
WOOD_LEFT = "#C47A3C"
WOOD_RIGHT = "#AE6530"
WOOD_INSIDE = "#9A5A2B"
WOOD_SEAM = "#8F5226"
SAND = "#EDC77F"
AGENT = "#2A6EEF"
ANTENNA = "#1C5CDB"
VISOR = "#132A5C"
EYES = "#A6D5FA"
# The light on top of the antenna, a terminal green to say the agent is running.
ANTENNA_LIGHT = "#5BE38F"

# The sandbox: a diamond W wide (half width) and W * SLOPE tall, with walls
# WALL deep. The sand sits SAND_DROP below the rim, inside a rim that's
# 1 - INNER of the box's width.
W = 330
SLOPE = 0.53
WALL = 124
INNER = 0.83
SAND_DROP = 22

# The agent peeks out of the sand: the sides of its head show HEAD_SHOWN
# above the sand, which it meets along a curve HEAD_DIP deep. HEAD_SHOWN
# keeps the visor clear of the sand, with a little of the face below it.
# HEAD_FORWARD moves the agent towards the front of the sandbox.
HEAD_WIDTH = 250
HEAD_RADIUS = 78
HEAD_SHOWN = 176
HEAD_DIP = 33
HEAD_FORWARD = 20
ANTENNA_HEIGHT = 70
LIGHT_RADIUS = 24
# The whole agent is drawn AGENT_SCALE times the size above, grown from where
# it meets the sand so it still comes out of the same spot.
AGENT_SCALE = 1.2


def head_bottom(cy):
    # The lowest point of the head is in front of the sand's centre.
    return cy + SAND_DROP / 2 + 20 + HEAD_FORWARD


def head_top(cy):
    return head_bottom(cy) - HEAD_SHOWN - HEAD_DIP


# Centre the artwork on the canvas, as Apple's icon grid expects: the
# antenna light at the top and the bottom of the walls are the same distance
# from the middle.
_LIGHT_TOP = head_top(0) - ANTENNA_HEIGHT - LIGHT_RADIUS
_REACH_UP = -(head_bottom(0) + (_LIGHT_TOP - head_bottom(0)) * AGENT_SCALE)
_REACH_DOWN = W * SLOPE + WALL
CENTRE = (512, CANVAS / 2 + (_REACH_UP - _REACH_DOWN) / 2)


def diamond(cx, cy, w, h):
    return [(cx, cy - h), (cx + w, cy), (cx, cy + h), (cx - w, cy)]


def polygon(points, fill):
    return f'<polygon points="{" ".join(f"{x:.1f},{y:.1f}" for x, y in points)}" fill="{fill}"/>'


def rect(x, y, width, height, radius, fill):
    return f'<rect x="{x:g}" y="{y:g}" width="{width:g}" height="{height:g}" rx="{radius:g}" fill="{fill}"/>'


def frame():
    cx, cy = CENTRE
    h = W * SLOPE
    top, right, bottom, left = diamond(cx, cy, W, h)

    def down(p, by):
        return (p[0], p[1] + by)

    shapes = [
        polygon([left, bottom, down(bottom, WALL), down(left, WALL)], WOOD_LEFT),
        polygon([bottom, right, down(right, WALL), down(bottom, WALL)], WOOD_RIGHT),
    ]
    # A seam between two planks, part way down each outside wall.
    seam, thickness = WALL * 0.48, 10
    for a, b in ((left, bottom), (bottom, right)):
        shapes.append(polygon([down(a, seam), down(b, seam), down(b, seam + thickness), down(a, seam + thickness)], WOOD_SEAM))
    shapes.append(polygon([top, right, bottom, left], WOOD_TOP))
    shapes.append(polygon(diamond(cx, cy, W * INNER, h * INNER), WOOD_INSIDE))
    return shapes


def sand():
    # The inside of the rim dropped by SAND_DROP, cut to the inside of the rim,
    # so the back walls show above the sand.
    cx, cy = CENTRE
    w, h = W * INNER, W * SLOPE * INNER
    side = w * (1 - SAND_DROP / 2 / h)
    return [polygon([(cx, cy - h + SAND_DROP), (cx + side, cy + SAND_DROP / 2), (cx, cy + h), (cx - side, cy + SAND_DROP / 2)], SAND)]


def agent_grow():
    # Grows the agent by AGENT_SCALE from where it meets the sand.
    cx, cy = CENTRE
    bottom = head_bottom(cy)
    return f"translate({cx:g} {bottom:g}) scale({AGENT_SCALE:g}) translate({-cx:g} {-bottom:g})"


def agent():
    # A rounded head with a visor and two eyes, and an antenna on top. Its
    # bottom is a shallow curve where it disappears into the sand.
    cx, cy = CENTRE
    top = head_top(cy)
    sides = top + HEAD_SHOWN
    left, right, r = cx - HEAD_WIDTH / 2, cx + HEAD_WIDTH / 2, HEAD_RADIUS
    head = (f"M{left:g},{sides:g} V{top + r:g} A{r},{r} 0 0 1 {left + r:g},{top:g} "
            f"H{right - r:g} A{r},{r} 0 0 1 {right:g},{top + r:g} "
            f"V{sides:g} A{HEAD_WIDTH / 2:g},{HEAD_DIP} 0 0 1 {left:g},{sides:g} Z")
    return [group([
        rect(cx - 7, top - ANTENNA_HEIGHT, 14, ANTENNA_HEIGHT + 10, 7, ANTENNA),
        f'<circle cx="{cx}" cy="{top - ANTENNA_HEIGHT:g}" r="{LIGHT_RADIUS}" fill="{ANTENNA_LIGHT}"/>',
        f'<path d="{head}" fill="{AGENT}"/>',
        *agent_face(),
    ], agent_grow(), indent="")]


def agent_face():
    # The visor and eyes.
    cx, cy = CENTRE
    top = head_top(cy)
    return [
        rect(cx - 98, top + 44, 196, 114, 52, VISOR),
        rect(cx - 38 - 19, top + 71, 38, 60, 19, EYES),
        rect(cx + 38 - 19, top + 71, 38, 60, 19, EYES),
    ]


def sand_line():
    # Everything above where the agent meets the sand: straight out from the
    # sides of its head, and along the curve of its bottom between them. In
    # the agent's own coordinates, before agent_grow.
    cx, cy = CENTRE
    sides = head_top(cy) + HEAD_SHOWN
    left, right = cx - HEAD_WIDTH / 2, cx + HEAD_WIDTH / 2
    return (f"M{left - W:g},0 H{right + W:g} V{sides:g} H{right:g} "
            f"A{HEAD_WIDTH / 2:g},{HEAD_DIP} 0 0 1 {left:g},{sides:g} H{left - W:g} Z")


# The website's animation: the agent pokes its head out of the sand, spots
# the visitor and ducks quickly until only its eyes show. It waits there a
# moment, then crouches and pops out, landing with a little bounce.
# Each step is (seconds from the start, how far below its resting place the
# agent is, its tilt in degrees, how far its face turns sideways, the easing
# into the next step). It plays
# once, after a short pause so the page has settled, and not at all with
# Reduce Motion on.
SUNK = HEAD_SHOWN + HEAD_DIP + ANTENNA_HEIGHT + LIGHT_RADIUS + 10
POKED = 25
# Low enough that the sand covers most of its eyes.
EYES_SHOWING = 115
# How far the visor and eyes slide, and narrow, when it turns its head. The
# visor has 27 units of head either side of it.
TURN = 18
PEEK_DELAY = 0.9
PEEK_STEPS = [
    (0.00, SUNK, 0, 0, "cubic-bezier(0.25, 0.8, 0.35, 1)"),  # rises slowly
    (0.70, POKED, 0, 0, "linear"),  # spots the visitor
    (0.85, POKED, 0, 0, "cubic-bezier(0.5, 0, 1, 0.6)"),  # ducks fast
    (0.97, EYES_SHOWING, 0, 0, "linear"),
    # Waits. To have it look left and right here instead, give these steps
    # a tilt such as -5 and 5, and a turn of -TURN and TURN.
    (1.20, EYES_SHOWING, 0, 0, "ease-in-out"),
    (1.75, EYES_SHOWING, 0, 0, "ease-in-out"),
    (2.45, EYES_SHOWING, 0, 0, "ease-in-out"),
    (2.95, EYES_SHOWING, 0, 0, "linear"),
    (3.15, EYES_SHOWING, 0, 0, "ease-in"),  # crouches
    (3.30, EYES_SHOWING + 22, 0, 0, "cubic-bezier(0.2, 0.9, 0.4, 1)"),  # pops out
    (3.54, -20, 0, 0, "ease-in"),  # lands
    (3.76, 0, 0, 0, "ease-out"),
    (3.86, -4, 0, 0, "ease-in"),
    (3.96, 0, 0, 0, None),
]


def peek_style():
    # Browsers run CSS inside an SVG even when it's shown with <img>. The tilt
    # turns the agent about the middle of its bottom edge. Turning its head
    # slides the face sideways and narrows it a little, as a face looks when
    # it turns away, while the round head stays where it is.
    total = PEEK_STEPS[-1][0]
    body, face = [], []
    for t, y, angle, turn, easing in PEEK_STEPS:
        at = f"        {t / total * 100:.1f}%"
        timing = f" animation-timing-function: {easing};" if easing else ""
        body.append(f"{at} {{ transform: translateY({y:g}px) rotate({angle:g}deg);{timing} }}")
        narrow = 1 - abs(turn) / TURN * 0.1
        face.append(f"{at} {{ transform: translateX({turn:g}px) scaleX({narrow:g});{timing} }}")
    body, face = "\n".join(body), "\n".join(face)
    return f"""<style>
      .peek {{ transform-box: fill-box; transform-origin: 50% 100%; animation: peek {total:g}s {PEEK_DELAY:g}s both; }}
      .face {{ transform-box: fill-box; transform-origin: 50% 50%; animation: turn {total:g}s {PEEK_DELAY:g}s both; }}
      @keyframes peek {{
{body}
      }}
      @keyframes turn {{
{face}
      }}
      @media (prefers-reduced-motion: reduce) {{
        .peek, .face {{ animation: none; }}
      }}
    </style>"""


LAYER_SHAPES = {"Frame": frame, "Sand": sand, "Agent": agent}


def svg(body, defs=""):
    defs = f"  <defs>\n    {defs}\n  </defs>\n" if defs else ""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS} {CANVAS}">
  <!-- Generated by scripts/generate-app-icon.py. Edit that script, not this file. -->
{defs}{body}
</svg>
"""


def group(shapes, transform, indent="  "):
    inner = "\n".join(f"{indent}  {s}" for s in shapes)
    return f'{indent}<g transform="{transform}">\n{inner}\n{indent}</g>'


def write_layers():
    LAYERS.mkdir(parents=True, exist_ok=True)
    scale = f"translate(512 512) scale({FULL_BLEED:.4f}) translate(-512 -512)"
    for name, shapes in LAYER_SHAPES.items():
        (LAYERS / f"{name}.svg").write_text(svg(group(shapes(), scale)))


def preview_layers():
    # Draw the layers bottom first, moved as icon.json moves them. Its offsets
    # are in full-bleed points, with y increasing downwards.
    groups = json.loads((ICON / "icon.json").read_text())["groups"]
    layers = []
    for g in reversed(groups):
        for layer in g["layers"]:
            name = Path(layer["image-name"]).stem
            if layer.get("hidden") or name not in LAYER_SHAPES:
                continue
            dx, dy = (v / FULL_BLEED for v in layer["position"]["translation-in-points"])
            layers.append(f'  <g id="{name.lower()}" transform="translate({dx:.1f} {dy:.1f})">\n'
                          + "\n".join(f"    {s}" for s in LAYER_SHAPES[name]()) + "\n  </g>")
    return "\n".join(layers)


def write_preview():
    top, bottom = BACKGROUND
    defs = (f'<linearGradient id="fill" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bottom}"/></linearGradient>\n'
            f'    <clipPath id="shape"><rect x="{INSET}" y="{INSET}" width="{BODY}" height="{BODY}" rx="{RADIUS}"/></clipPath>')
    body = (f'  <rect x="{INSET}" y="{INSET}" width="{BODY}" height="{BODY}" rx="{RADIUS}" fill="url(#fill)"/>\n'
            '  <g clip-path="url(#shape)">\n' + preview_layers() + "\n  </g>")
    (DESIGN / "AppIcon.svg").write_text(svg(body, defs))


def write_artwork():
    # Cropped to the sandbox's sides, the antenna light and the bottom of the
    # walls, with a margin for any offsets icon.json gives the layers.
    margin = 12
    x = CENTRE[0] - W - margin
    y = CENTRE[1] - _REACH_UP - margin
    width = 2 * (W + margin)
    height = _REACH_UP + _REACH_DOWN + 2 * margin
    viewbox = f"{x:.1f} {y:.1f} {width:.1f} {height:.1f}"
    # Clip the agent at the sand and wrap its shapes in a group to animate,
    # so it rises out of the sand rather than sliding over it.
    grown = f'<g transform="{agent_grow()}">'
    layers = preview_layers()
    end = "\n</g>\n  </g>"
    assert layers.count(grown) == 1 and layers.endswith(end)
    layers = layers.replace(grown, f'<g transform="{agent_grow()}" clip-path="url(#sand-line)">\n<g class="peek">', 1)
    layers = layers[:-len(end)] + "\n</g>" + end
    face = "\n  ".join(agent_face())
    assert layers.count(face) == 1
    layers = layers.replace(face, '<g class="face">\n    ' + face.replace("\n  ", "\n    ") + "\n  </g>", 1)
    defs = f'<clipPath id="sand-line"><path d="{sand_line()}"/></clipPath>\n    {peek_style()}'
    (DESIGN / "AppIconArtwork.svg").write_text(
        svg(layers, defs).replace(f"0 0 {CANVAS} {CANVAS}", viewbox, 1))


if __name__ == "__main__":
    write_layers()
    write_preview()
    write_artwork()
