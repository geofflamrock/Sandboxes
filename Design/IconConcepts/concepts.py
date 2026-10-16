#!/usr/bin/env python3
"""Sandbox-with-agent icon concepts. Writes layered SVGs + flattened previews."""
import sys
from pathlib import Path

OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)

BODY, INSET, RADIUS = 824, 100, 185

LIGHT = dict(
    bg=("#FFFFFF", "#E4E4EA"),
    wood_top="#E39B5B", wood_left="#C47A3C", wood_right="#AE6530", wood_inner="#9A5A2B", groove="#8F5226",
    sand="#EDC77F", mound="#F3D597",
    head="#2A6EEF", head_side="#1C5CDB", visor="#132A5C", eye="#A6D5FA",
    paint_top="#5AACF2", paint_front="#2A6EEF", paint_inner="#1C5CDB", paint_groove="#1A4FBF", paint_seam="#143E9C",
    bot="#3A4150", screen="#12151C", prompt="#5BE38F", spade="#F0643C", spade_grip="#C94A27",
)
DARK = dict(LIGHT, bg=("#3A3A3E", "#1C1C1F"), sand="#D9B26A", mound="#E0BD7C", bot="#4A5262")


def mono(p):
    """Rough tinted-mode stand-in: each fill becomes white at an opacity set by its luminance."""
    def conv(hexc):
        r, g, b = (int(hexc[i:i + 2], 16) / 255 for i in (1, 3, 5))
        lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        v = round(48 + 207 * lum)
        return f"#{v:02X}{v:02X}{v:02X}"
    q = {k: conv(v) for k, v in p.items() if k != "bg"}
    q["bg"] = ("#2A2A2E", "#141416")
    return q


def poly(pts, fill):
    return f'<polygon points="{" ".join(f"{x:.1f},{y:.1f}" for x, y in pts)}" fill="{fill}"/>'


def diamond(cx, cy, w, h, dy=0):
    return [(cx, cy - h + dy), (cx + w, cy + dy), (cx, cy + h + dy), (cx - w, cy + dy)]


def robot_head(p, x0, x1, top, bottom, rx, visor, eyes, antenna_h=70, ball=24):
    cx = (x0 + x1) / 2
    vx0, vx1, vy0, vy1, vrx = visor
    s = [
        f'<rect x="{cx - 7}" y="{top - antenna_h}" width="14" height="{antenna_h + 10}" rx="7" fill="{p["head_side"]}"/>',
        f'<circle cx="{cx}" cy="{top - antenna_h}" r="{ball}" fill="{p["eye"]}"/>',
        f'<rect x="{x0}" y="{top}" width="{x1 - x0}" height="{bottom - top}" rx="{rx}" fill="{p["head"]}"/>',
        f'<rect x="{vx0}" y="{vy0}" width="{vx1 - vx0}" height="{vy1 - vy0}" rx="{vrx}" fill="{p["visor"]}"/>',
    ]
    for ex, ey, ew, eh in eyes:
        s.append(f'<rect x="{ex - ew / 2}" y="{ey - eh / 2}" width="{ew}" height="{eh}" rx="{ew / 2}" fill="{p["eye"]}"/>')
    return "".join(s)


# --- Concept A: isometric, echoes the current cube ---------------------------------
def iso_box(p, D, cy, top, left_c, right_c, inner_c, groove_c=None, uid="a"):
    cx, W, k = 512, 330, 0.53
    H = W * k
    out = diamond(cx, cy, W, H)
    left, bottom, right = out[3], out[2], out[1]
    frame = [
        poly([left, bottom, (bottom[0], bottom[1] + D), (left[0], left[1] + D)], p[left_c]),
        poly([bottom, right, (right[0], right[1] + D), (bottom[0], bottom[1] + D)], p[right_c]),
    ]
    if groove_c:
        # A seam between two planks, part way down each outside wall.
        g, t = D * 0.48, 10
        for a, b in ((left, bottom), (bottom, right)):
            frame.append(poly([(a[0], a[1] + g), (b[0], b[1] + g), (b[0], b[1] + g + t), (a[0], a[1] + g + t)], p[groove_c]))
    inner = diamond(cx, cy, W * 0.83, H * 0.83)
    frame += [poly(out, p[top]), poly(inner, p[inner_c])]
    # The sand is the inner diamond dropped by 22, cut to the inner diamond. Worked out as a
    # plain polygon rather than a clip path, so the layer imports cleanly into Icon Composer.
    iw, ih, drop = W * 0.83, H * 0.83, 22
    side = iw * (1 - drop / 2 / ih)
    sand = [poly([(cx, cy - ih + drop), (cx + side, cy + drop / 2), (cx, cy + ih), (cx - side, cy + drop / 2)], p["sand"])]
    # The agent is drawn for cy=580 and moved with the box.
    head = (f'<g transform="translate(0 {cy - 580})">'
            + robot_head(p, 387, 637, 318, 570, 78, (414, 610, 362, 476, 52),
                         [(474, 419, 38, 60), (550, 419, 38, 60)], antenna_h=70, ball=24) + "</g>")
    mound = f'<ellipse cx="{cx}" cy="{cy + 6}" rx="150" ry="44" fill="{p["mound"]}"/>'
    return [("Frame", "".join(frame)), ("Sand", "".join(sand)), ("Agent", head), ("Mound", mound)]


# --- Concept A: isometric, echoes the current cube ---------------------------------
def concept_a(p):
    return iso_box(p, 66, 580, "wood_top", "wood_left", "wood_right", "wood_inner")


# --- Concept D: A's isometric view with B/C's tall walls, painted blue ---------------
def concept_d(p):
    return iso_box(p, 124, 548, "paint_top", "paint_front", "paint_inner", "paint_groove", "paint_seam", uid="d")


# Shared front-on sandbox for B and C
def front_box(p, top, front, inner, groove, uid):
    ob, of = (218, 806, 520), (160, 864, 712)   # back edge x0,x1,y ; front edge
    ib, i_f = (258, 766, 548), (206, 818, 688)
    plank_bottom = 836
    outer = [(ob[0], ob[2]), (ob[1], ob[2]), (of[1], of[2]), (of[0], of[2])]
    inn = [(ib[0], ib[2]), (ib[1], ib[2]), (i_f[1], i_f[2]), (i_f[0], i_f[2])]
    frame = [
        poly(outer, p[top]),
        poly(inn, p[inner]),
        f'<path d="M{of[0]},{of[2]} H{of[1]} V{plank_bottom - 34} Q{of[1]},{plank_bottom} {of[1] - 34},{plank_bottom} '
        f'H{of[0] + 34} Q{of[0]},{plank_bottom} {of[0]},{plank_bottom - 34} Z" fill="{p[front]}"/>',
        f'<rect x="{of[0]}" y="772" width="{of[1] - of[0]}" height="10" fill="{p[groove]}"/>',
    ]
    # Sand sits a little below the rim, so the inner back wall shows above it.
    sand = [poly([(ib[0] - 8, ib[2] + 22), (ib[1] + 8, ib[2] + 22), (i_f[1], i_f[2]), (i_f[0], i_f[2])], p["sand"])]
    return frame, sand


# --- Concept B: "Peek" — wooden sandbox, agent peeking up to its eyes -------------
def concept_b(p):
    frame, sand = front_box(p, "wood_top", "wood_left", "wood_inner", "groove", "b")
    head = robot_head(p, 352, 672, 262, 640, 120, (380, 644, 340, 462, 61),
                      [(482, 401, 40, 66), (566, 401, 40, 66)], antenna_h=78, ball=26)
    mound = f'<ellipse cx="512" cy="616" rx="210" ry="46" fill="{p["mound"]}"/>'
    return [("Frame", "".join(frame)), ("Sand", "".join(sand)), ("Agent", head), ("Mound", mound)]


# --- Concept C: "Prompt" — painted sandbox, terminal-faced agent, toy spade -------
def concept_c(p):
    frame, sand = front_box(p, "paint_top", "paint_front", "paint_inner", "paint_groove", "c")
    cx = 470
    head = "".join([
        f'<rect x="{cx - 7}" y="196" width="14" height="80" rx="7" fill="#9AA3B2"/>',
        f'<circle cx="{cx}" cy="196" r="24" fill="{p["prompt"]}"/>',
        f'<rect x="{cx - 165}" y="268" width="330" height="360" rx="96" fill="{p["bot"]}"/>',
        f'<rect x="{cx - 132}" y="306" width="264" height="178" rx="48" fill="{p["screen"]}"/>',
        f'<polyline points="{cx - 82},{352} {cx - 38},{395} {cx - 82},{438}" fill="none" stroke="{p["prompt"]}" '
        f'stroke-width="24" stroke-linecap="round" stroke-linejoin="round"/>',
        f'<line x1="{cx - 6}" y1="438" x2="{cx + 70}" y2="438" stroke="{p["prompt"]}" stroke-width="24" stroke-linecap="round"/>',
    ])
    spade = (f'<g transform="rotate(14 728 600)">'
             f'<rect x="716" y="392" width="24" height="210" rx="12" fill="{p["spade"]}"/>'
             f'<rect x="690" y="372" width="76" height="34" rx="17" fill="{p["spade_grip"]}"/></g>')
    mound = (f'<ellipse cx="{cx}" cy="612" rx="200" ry="46" fill="{p["mound"]}"/>'
             f'<ellipse cx="736" cy="604" rx="46" ry="14" fill="{p["mound"]}"/>')
    return [("Frame", "".join(frame)), ("Sand", "".join(sand)), ("Agent", head + spade), ("Mound", mound)]


# --- Concept D2: D with C's graphite head, so the agent doesn't blend into the walls --
def concept_d2(p):
    return iso_box(dict(p, head=p["bot"], head_side="#9AA3B2", visor=p["screen"]), 124, 548,
                   "paint_top", "paint_front", "paint_inner", "paint_groove", "paint_seam", uid="d2")


# --- Concept E: D's tall walls in A's wood, with the blue agent ---------------------
def concept_e(p):
    return iso_box(p, 124, 548, "wood_top", "wood_left", "wood_right", "wood_inner", "groove", uid="e")


def flatten(layers, p):
    a, b = p["bg"]
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
        f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{a}"/>'
        f'<stop offset="1" stop-color="{b}"/></linearGradient>'
        f'<clipPath id="body"><rect x="{INSET}" y="{INSET}" width="{BODY}" height="{BODY}" rx="{RADIUS}"/></clipPath></defs>'
        f'<g clip-path="url(#body)"><rect x="{INSET}" y="{INSET}" width="{BODY}" height="{BODY}" fill="url(#bg)"/>'
        + "".join(f'<g id="{n}">{s}</g>' for n, s in layers) + "</g></svg>"
    )


def current(p):
    box = (f'<polygon points="512.0,251.4 748.9,377.8 512.0,504.1 275.1,377.8" fill="{p.get("c_top", "#5AACF2")}"/>'
           f'<polygon points="275.1,377.8 512.0,504.1 512.0,772.6 275.1,646.2" fill="{p.get("c_left", "#2A6EEF")}"/>'
           f'<polygon points="512.0,504.1 748.9,377.8 748.9,646.2 512.0,772.6" fill="{p.get("c_right", "#1C5CDB")}"/>')
    tape = (f'<polygon points="365.1,329.6 389.3,316.8 626.2,443.2 602.0,455.9" fill="{p.get("c_tape", "#A6D5FA")}"/>'
            f'<polygon points="397.8,312.4 422.0,299.6 658.9,425.9 634.7,438.7" fill="{p.get("c_tape", "#A6D5FA")}"/>')
    return [("Box", box), ("Tape", tape)]


CUR_LIGHT = dict(LIGHT, bg=("#F8ECD4", "#EDD7AA"))
CUR_MONO = mono(dict(LIGHT, c_top="#5AACF2", c_left="#2A6EEF", c_right="#1C5CDB", c_tape="#A6D5FA"))
for mode, pal in (("light", CUR_LIGHT), ("dark", DARK), ("tinted", CUR_MONO)):
    (OUT / f"current-{mode}.svg").write_text(flatten(current(pal), pal))

# Icon Composer's canvas is the icon shape itself, full bleed, while these drawings use
# Apple's 824pt body inside a 1024pt canvas, so layers are scaled up to fill it.
FULL_BLEED = 1024 / BODY


def write_icon(path, layers):
    """An Icon Composer bundle: one group per layer, on the system background."""
    import json
    assets = path / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for n, s in layers:
        (assets / f"{n}.svg").write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
            f'<g transform="translate(512 512) scale({FULL_BLEED:.4f}) translate(-512 -512)">{s}</g></svg>')
    groups = [{
        "layers": [{"image-name": f"{n}.svg", "name": n,
                    "position": {"scale": 1, "translation-in-points": [0, 0]}}],
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "translucency": {"enabled": True, "value": 0.3},
    } for n, _ in reversed(layers)]  # Icon Composer lists the top group first
    (path / "icon.json").write_text(json.dumps({
        "fill-specializations": [{"value": "system-light"}, {"appearance": "dark", "value": "system-dark"}],
        "groups": groups,
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }, indent=2) + "\n")


CONCEPTS = {"a-isometric": concept_a, "b-peek": concept_b, "c-prompt": concept_c, "d-iso-blue": concept_d, "d2-iso-graphite": concept_d2, "e-iso-wood": concept_e}
for name, fn in CONCEPTS.items():
    for mode, pal in (("light", LIGHT), ("dark", DARK), ("tinted", mono(LIGHT))):
        (OUT / f"{name}-{mode}.svg").write_text(flatten(fn(pal), pal))
    write_icon(OUT / "IconComposer" / f"{name}.icon", fn(LIGHT))
print("ok")
