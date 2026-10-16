#!/usr/bin/env python3
"""Builds the comparison page from the SVGs concepts.py wrote."""
import base64, sys
from pathlib import Path

SRC, DEST = Path(sys.argv[1]), Path(sys.argv[2])

ICONS = [
    ("current", "Current", "Taped container box on sand"),
    ("a-isometric", "A · Isometric", "Same isometric angle as today's cube"),
    ("b-peek", "B · Peek", "Front-on wooden sandbox, agent up to its eyes"),
    ("c-prompt", "C · Prompt", "Terminal-faced agent, painted box, toy spade"),
    ("d-iso-blue", "D · Isometric, blue", "A's angle with B/C's tall walls, painted blue"),
    ("d2-iso-graphite", "D2 · Isometric, graphite", "D with C's dark head so it stands off the walls"),
    ("e-iso-wood", "E · Isometric, wood", "D's tall walls in wood, with the blue agent"),
]


def uri(name, mode):
    data = (SRC / f"{name}-{mode}.svg").read_bytes()
    return "data:image/svg+xml;base64," + base64.b64encode(data).decode()


def img(name, mode, size, alt=""):
    return f'<img src="{uri(name, mode)}" width="{size}" height="{size}" alt="{alt}">'


hero = "".join(
    f'<figure class="{"cur" if k == "current" else ""}">{img(k, "light", 220, t)}'
    f'<figcaption><b>{t}</b><span>{d}</span></figcaption></figure>' for k, t, d in ICONS)

modes = "".join(
    f'<div class="rowlabel">{t}</div>'
    + "".join(f'<div class="cell {m}">{img(k, m, 150)}</div>' for m in ("light", "dark", "tinted"))
    for k, t, _ in ICONS)

sizes = "".join(
    f'<div class="rowlabel">{t}</div><div class="sizes">'
    + "".join(f'<div>{img(k, "light", s)}<small>{s}</small></div>' for s in (128, 64, 32, 16))
    + "</div>" for k, t, _ in ICONS)

dock = lambda m: '<div class="dock ' + m + '">' + "".join(img(k, m, 64, t) for k, t, _ in ICONS) + "</div>"

# (criterion, guideline, current, A, B, C) ; each verdict is (mark, note)
Y, P, N = "pass", "part", "fail"
ROWS = [
    ("Layered, flat artwork",
     "Liquid Glass icons are built in Icon Composer from flat foreground layers; the system adds the specular highlights, blur and shadow, so don't bake them in.",
     (Y, "2 flat layers"), (Y, "4 flat layers"), (Y, "4 flat layers"), (Y, "4 flat layers"), (Y, "4 flat layers"), (Y, "4 flat layers"), (Y, "4 flat layers")),
    ("Few groups",
     "Keep the foreground to a small number of groups (Icon Composer allows up to four) so depth reads cleanly.",
     (Y, "2 groups"), (Y, "Frame · Sand · Agent · Mound"), (Y, "Frame · Sand · Agent · Mound"), (P, "Spade shares the Agent group, a 5th element"), (Y, "Frame · Sand · Agent · Mound"), (Y, "Frame · Sand · Agent · Mound"), (Y, "Frame · Sand · Agent · Mound")),
    ("Stays inside the shape",
     "macOS 26 masks every icon to the rounded square. Artwork that breaks out of it, as older Mac icons did, gets put on a grey tile.",
     (Y, ""), (Y, ""), (Y, ""), (Y, ""), (Y, ""), (Y, ""), (Y, "")),
    ("One clear focal point",
     "Simple, centred, one idea. Don't make the icon a scene.",
     (Y, "Very simple"), (P, "Sandbox is the hero, agent is small"), (Y, "Agent is the hero, box frames it"), (P, "Agent + prompt + spade: three ideas"), (P, "Blue head blends into the blue walls"), (Y, "Bigger box, but the head still leads"), (Y, "Blue head contrasts with warm wood")),
    ("Readable at 16–32 pt",
     "The icon shows up small in Finder, Spotlight, the menu bar's app list and notifications.",
     (Y, "Cube holds up"), (N, "At 16 pt it's a brown diamond with a blue dot"), (Y, "Blue head + eyes survive to 16 pt"), (P, "Prompt glyph turns to mush below 32 pt"), (P, "Reads as a blue box; head merges at 16 pt"), (Y, "Dark head still shows at 16 pt"), (Y, "Blue head on brown box reads at 16 pt")),
    ("No text",
     "Avoid words and characters; use pictures.",
     (Y, ""), (Y, ""), (Y, ""), (P, "“>_” is a symbol, not text, but it's borderline"), (Y, ""), (Y, ""), (Y, "")),
    ("Works in Dark, Clear and Tinted",
     "Every icon is shown in Default, Dark, Clear and Tinted. In Clear and Tinted the system drops your colours and keeps only light and dark, so shapes must separate by value, not hue.",
     (Y, "Faces separate well"), (P, "Frame and sand merge; agent is small"), (P, "Head reads; rim and sand blend"), (P, "Dark head reads; rim and sand blend"), (P, "Head and walls go the same grey"), (P, "Head reads; rim and sand blend"), (P, "Head reads; rim and sand blend")),
    ("Distinct in the Dock",
     "Apple suggests a strong, unique colour or shape so people can spot your icon among others.",
     (Y, "Warm sand background stands out"), (P, "Plain system background blends with Apple's white-tile icons"), (P, "Same, though the blue head helps"), (P, "Same; dark head + blue box help most"), (Y, "Big blue shape keeps today\u2019s colour"), (Y, "Big blue shape keeps today\u2019s colour"), (P, "Wood stands out less than blue; the head helps")),
    ("Says what the app does",
     "The metaphor should hint at the app's job.",
     (P, "Reads as “package” or “container”"), (Y, "Sandbox + agent"), (Y, "Sandbox + agent, and it's fun"), (Y, "Sandbox + coding agent: the most literal"), (Y, "Sandbox + agent"), (Y, "Sandbox + agent"), (Y, "Sandbox + agent")),
]
MARK = {Y: "✓", P: "~", N: "✗"}


def verdict(v):
    m, note = v
    return f'<td class="{m}"><span class="mark">{MARK[m]}</span>{note}</td>'


table = "".join(
    f'<tr><th scope="row"><b>{c}</b><span>{g}</span></th>' + "".join(verdict(v) for v in vs) + "</tr>"
    for c, g, *vs in ROWS)
score = []
for i in range(len(ICONS)):
    marks = [r[2 + i][0] for r in ROWS]
    score.append(f"{marks.count(Y)} ✓ · {marks.count(P)} ~ · {marks.count(N)} ✗")
scorerow = "<tr class='score'><th scope='row'>Tally</th>" + "".join(f"<td>{s}</td>" for s in score) + "</tr>"

html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sandboxes Icon Concepts</title>
<style>
:root {{ --bg:#F5F5F7; --card:#FFFFFF; --ink:#1D1D1F; --muted:#6E6E73; --line:#E3E3E8;
  --pass:#1F8A4C; --part:#B26B00; --fail:#C0362C; --accent:#2A6EEF; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{ --bg:#141416; --card:#1F1F22; --ink:#F2F2F5; --muted:#9A9AA2; --line:#34343A;
  --pass:#4CC27E; --part:#E5A23A; --fail:#F0675B; }} }}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif; }}
main {{ max-width:1080px; margin:0 auto; padding:40px 16px 80px; }}
h1 {{ font-size:30px; margin:0 0 6px; letter-spacing:-.02em; }}
h2 {{ font-size:20px; margin:48px 0 6px; letter-spacing:-.01em; }}
p.lead, p.note {{ color:var(--muted); margin:0 0 18px; max-width:760px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:16px; padding:20px; }}
.hero {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:16px; }}
.hero figure {{ margin:0; text-align:center; background:var(--card); border:1px solid var(--line); border-radius:16px; padding:16px 8px; }}
.hero figure.cur {{ outline:2px dashed var(--line); outline-offset:-8px; }}
.hero img {{ max-width:100%; height:auto; }}
figcaption b {{ display:block; }} figcaption span {{ color:var(--muted); font-size:13px; }}
.modes {{ display:grid; grid-template-columns:130px repeat(3,1fr); gap:10px; align-items:center; }}
.modes .head {{ font-size:13px; color:var(--muted); text-align:center; }}
.rowlabel {{ font-weight:600; font-size:14px; }}
.cell {{ border-radius:14px; display:flex; justify-content:center; padding:6px; }}
.cell img {{ width:100%; max-width:150px; height:auto; }}
.cell.light {{ background:linear-gradient(135deg,#dfe7f3,#f3e9df); }}
.cell.dark, .cell.tinted {{ background:linear-gradient(135deg,#1b2333,#2b1f2a); }}
.sizegrid {{ display:grid; grid-template-columns:130px 1fr; gap:14px 10px; align-items:center; }}
.sizes {{ display:flex; gap:22px; align-items:flex-end; flex-wrap:wrap; }}
.sizes div {{ display:flex; flex-direction:column; align-items:center; gap:4px; }}
.sizes small {{ color:var(--muted); font-size:11px; }}
.dockwrap {{ border-radius:16px; padding:28px 16px; display:grid; gap:18px; justify-items:center;
  background:linear-gradient(160deg,#6b8fd6 0%,#b48ad8 50%,#f0b27a 100%); }}
.dock {{ display:flex; gap:10px; padding:10px 14px; border-radius:24px; backdrop-filter:blur(20px); max-width:100%; overflow:hidden; }}
.dock img {{ width:64px; height:64px; flex:0 1 64px; min-width:0; }}
.dock.light {{ background:rgba(255,255,255,.35); border:1px solid rgba(255,255,255,.5); }}
.dock.dark {{ background:rgba(20,20,24,.45); border:1px solid rgba(255,255,255,.12); }}
.tablewrap {{ overflow-x:auto; border:1px solid var(--line); border-radius:16px; background:var(--card); }}
table {{ border-collapse:collapse; width:100%; min-width:1180px; font-size:13.5px; }}
th, td {{ text-align:left; vertical-align:top; padding:12px; border-bottom:1px solid var(--line); }}
thead th {{ font-size:13px; position:sticky; top:0; background:var(--card); }}
thead img {{ display:block; margin-bottom:6px; }}
tbody th {{ width:30%; font-weight:normal; }}
tbody th b {{ display:block; }} tbody th span {{ color:var(--muted); font-size:12.5px; }}
.mark {{ font-weight:700; margin-right:6px; }}
td.pass .mark {{ color:var(--pass); }} td.part .mark {{ color:var(--part); }} td.fail .mark {{ color:var(--fail); }}
tr.score td, tr.score th {{ font-weight:600; border-bottom:none; }}
.rec {{ border-left:4px solid var(--accent); }}
.rec ul {{ margin:8px 0 0; padding-left:20px; }}
@media (max-width:640px) {{ .modes {{ grid-template-columns:72px repeat(3,1fr); gap:6px; }} .sizegrid {{ grid-template-columns:1fr; }} .rowlabel {{ font-size:12px; }} }}
</style></head><body><main>
<h1>A new Sandboxes icon</h1>
<p class="lead">Three takes on a child's sandbox with an agent's head poking out of the sand, on the plain macOS system background, next to today's icon. All are flat layers, ready to drop into Icon Composer. Glass highlights aren't drawn here; macOS adds those itself.</p>
<div class="hero">{hero}</div>

<h2>Appearance modes</h2>
<p class="note">Default, Dark and an approximation of Tinted. Tinted keeps only light and dark, so layers have to differ in value, not just colour. Clear behaves much like Tinted.</p>
<div class="card"><div class="modes"><div></div><div class="head">Default</div><div class="head">Dark</div><div class="head">Tinted (approx.)</div>{modes}</div></div>

<h2>Small sizes</h2>
<p class="note">Finder lists, Spotlight and notifications show the icon at 16–32 pt. This is where the details stop helping.</p>
<div class="card"><div class="sizegrid">{sizes}</div></div>

<h2>In the Dock</h2>
<p class="note">Left to right: current, A, B, C, D, D2, E.</p>
<div class="dockwrap">{dock("light")}{dock("dark")}</div>

<h2>Against the macOS 26 icon guidelines</h2>
<p class="note">Based on Apple's Human Interface Guidelines for app icons and the Liquid Glass / Icon Composer guidance from macOS 26.</p>
<div class="tablewrap"><table>
<thead><tr><th>Guideline</th>{"".join(f'<th>{img(k, "light", 44)}{t}</th>' for k, t, _ in ICONS)}</tr></thead>
<tbody>{table}{scorerow}</tbody></table></div>

<h2>Recommendation</h2>
<div class="card rec">
<p><b>D2 or B. They're the two strongest.</b> D2 scores best: its big blue box keeps today's colour and shape, so it stands out in the Dock even on the plain system background, and the graphite head still reads at 16 pt. B has more character, because the agent is bigger and peeking. Pick D2 if you want to keep continuity with the current icon, B if you want a mascot.</p>
<ul>
<li><b>E</b> is the warm version of D2. It scores the same as B and keeps the cheerful blue agent, but on a plain background it's less distinctive in the Dock than D2's blue box.</li>
<li><b>D needs the graphite head.</b> With the blue head on blue walls, the agent disappears into the box at small sizes and in Tinted.</li>
<li><b>Background:</b> a plain system background is allowed, but it puts B among Apple's white-tile apps. D2 gets away with it because the blue box does the job the sand background did.</li>
<li><b>A</b> keeps the current isometric look, but the agent is too small to carry the icon.</li>
<li><b>C</b> says “coding agent” most clearly, but the prompt glyph and spade are too much detail. If you like it, drop the spade and use C's dark head on B's layout.</li>
</ul></div>
</main></body></html>"""
DEST.write_text(html)
print(DEST, len(html))
