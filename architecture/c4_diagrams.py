"""Generate mcl-sec-guard's two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: what the service talks to
  c4-components.svg  Level 2: what it is made of

Drawn from the code, never from a template: the callbacks in
mcl_sec_guard_service.erl, the children mcl_sec_guard_sup.erl starts, the
subscriber the proposer and the recorder, the console in mcl_sec_guard_admin and
mcl_sec_guard_admin_handler, the run endpoint in mcl_sec_guard_trainer_api and
mcl_sec_guard_trainer_view, the dependencies in rebar.config, the port and the
mounts Containerfile and deploy/docker-compose.yml declare. When one of those
changes, the diagram changes in the same commit.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS custom
properties (rsvg-convert renders those black), so the SVGs render the same on
GitHub, in IDE previews and through rsvg-convert. After a change, render each
(rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at it; keep
architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        # A box that is too small for its own words renders as text on top of the
        # next box, which no test would catch and a reader would read as the
        # diagram saying something it does not. Fail here instead.
        need = 70 + 16 * max(len(desc) - 1, 0) + 18
        if h < need:
            raise ValueError(f"{self.name}: {name} needs height {need}, has {h}")
        for line in desc:
            if 16 + 6.2 * len(line) > w - 16:
                raise ValueError(f"{self.name}: {name}: '{line}' is wider than {w - 32}px")
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "mcl-sec-guard system context", 1100, 780)
    d.box("b-per", 60, 30, 280, 120, "Security reviewer", "[Person]",
          ["Reads the proposal log at /", "and the trainer scoreboard;",
           "decides nothing"], person=True)
    d.box("b-ext", 400, 30, 300, 120, "proposals.log and run sets", "[files it writes; compose mounts them]",
          ["MCL_SEC_GUARD_PROPOSAL_LOG", "gets one ~0p line per proposal;",
           "run sets land in trainer_runs/"])
    d.box("b-per", 770, 30, 270, 104, "Service operator", "[Person]",
          ["Deploys the release and sets", "the environment it boots with"], person=True)
    d.box("b-sys", 400, 220, 300, 150, "mcl-sec-guard", "[mcl_om mesh service, own box]",
          ["The guardian, P0 shadow: it", "observes, proposes, records,",
           "and applies nothing. Console", "on the admin port, no auth"])
    d.box("b-ext", 60, 460, 280, 140, "Guarded services", "[External system, mesh services]",
          ["Any mesh service with mcl-om's", "inbound guard publishes",
           "denials_observed per active window"])
    d.box("b-mac", 400, 460, 300, 120, "macula-realm", "[Macula infrastructure]",
          ["Endorses the node's identity key", "and grants the one scope it asks",
           "for, mcl-sec-guard"])
    d.box("b-mac", 770, 460, 270, 120, "Macula stations, mesh DHT", "[Macula infrastructure]",
          ["The pinned stations are its mesh", "entry points over QUIC; the DHT",
           "holds mcl_om's info and get_limits"])
    d.edge("M200 150V190H440V220")
    d.text("t-rel", 208, 168, "opens the console")
    d.edge("M905 134V200H660V220")
    d.text("t-rel", 712, 168, "deploys the release, sets the env")
    d.edge("M550 220V140")
    d.text("t-rel", 558, 178, "writes proposals.log and run sets")
    d.edge("M200 460V420H440V370")
    d.text("t-rel", 208, 400, "publishes denials_observed")
    d.text("t-rel", 208, 416, "once per active window")
    d.edge("M500 370V460")
    d.text("t-rel", 508, 412, "claims scope mcl-sec-guard")
    d.edge("M700 330H740V430H905V460")
    d.text("t-rel", 748, 348, "joins the mesh through the")
    d.text("t-rel", 748, 364, "pinned stations (QUIC)")
    d.text("t-desc", 60, 650, "P0 shadow: the guardian applies nothing. No set_limits call is in its namespace, and capabilities/0 declares")
    d.text("t-desc", 60, 668, "nothing of its own: mcl_om adds the info and get_limits every service carries. The console is an audit")
    d.text("t-desc", 60, 686, "window: it renders the log and the run sets, and its run button writes a run set. It decides nothing.")
    d.legend(730, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "mcl-sec-guard components", 1200, 1260)
    d.bound(16, 40, 1168, 954, "mcl-sec-guard [Container: one OTP release]")
    d.box("b-cmp", 40, 66, 490, 120, "mcl_sec_guard_app", "[application behaviour]",
          ["start/2 calls mcl_om:boot(mcl_sec_guard_service):", "the whole service starts from this one line"],
          code=True)
    d.box("b-cmp", 670, 66, 490, 120, "mcl_sec_guard_service", "[mcl_om_service behaviour]",
          ["info, start, stop, health, capabilities,", "identity_spec, subscriptions. capabilities/0",
           "is []; mcl_om adds info and get_limits"], code=True)
    d.box("b-cmp", 40, 210, 490, 104, "mcl_sec_guard_sup", "[supervisor, one_for_one]",
          ["Two children: mcl_sec_guard_recorder and", "mcl_sec_guard_admin; 5 restarts per 10 s"],
          code=True)
    d.box("b-cmp", 670, 210, 490, 104, "mcl_sec_guard_subscriber", "[macula_subscriber behaviour]",
          ["handle_event/4: decodes the fact, asks the", "proposer, hands a proposal to the recorder"],
          code=True)
    d.box("b-cmp", 40, 338, 490, 120, "mcl_sec_guard_recorder", "[gen_server, append-only]",
          ["One ~0p line per proposal, written", "synchronously so lines never interleave;",
           "the file is opened append at start"], code=True)
    d.box("b-cmp", 670, 338, 490, 120, "mcl_sec_guard_proposer", "[behaviour and the P0 rule]",
          ["propose/1 dispatches to the module named in", "{mcl_sec_guard, proposer}; the rule lowers",
           "per_caller_max to the over-limit count"], code=True)
    d.box("b-cmp", 40, 482, 490, 104, "mcl_sec_guard_admin", "[ranch listener, 0.0.0.0]",
          ["Listens on the port", "MCL_SEC_GUARD_ADMIN_PORT names; no authentication"], code=True)
    d.box("b-cmp", 670, 482, 490, 104, "mcl_sec_guard_admin_handler", "[cowboy handler, the console]",
          ["/, /proposals.ndjson, /trainer, /trainer.ndjson,", "/trainer/episode, POST /api/trainer/run"],
          code=True)
    d.box("b-cmp", 40, 610, 490, 104, "mcl_sec_guard_trainer_view", "[pure reader]",
          ["read_run_sets/1 file:consults the term files;", "scoreboard/1 formats the list it is given"],
          code=True)
    d.box("b-cmp", 670, 610, 490, 104, "mcl_sec_guard_trainer_api", "[the run endpoint's other half]",
          ["run/1: the baseline or one genome, one run", "at a time; a second call is 409"], code=True)
    d.box("b-cmp", 40, 738, 1120, 104, "mcl_sec_trainer", "[second OTP application, in the release, off by default]",
          ["The pure simulator, the eight scenarios, the episode runner and fitness vector, and mcl_sec_trainer_reporter:",
           "the term files it writes are the only bridge between the trainer and the console, which never loads it."],
          code=True)
    d.box("b-mac", 40, 866, 360, 104, "mcl_om", "[library, ~> 1.4]",
          ["boot/1 wires mesh, identity, health and one", "subscriber per declared topic"], code=True)
    d.box("b-mac", 420, 866, 360, 104, "macula", "[library, ~> 16.0]",
          ["QUIC transport, subscriber behaviour,", "decode_payload/1, the signed DHT records"],
          code=True)
    d.box("b-mac", 800, 866, 360, 104, "jsx, ranch, cowboy", "[jsx direct; ranch, cowboy via mcl_om]",
          ["jsx encodes the console's JSON; ranch and", "cowboy carry the admin listener"], code=True)
    d.box("b-ext", 40, 1024, 1120, 104, "the host environment", "[environment, read at boot; no secret here]",
          ["MCL_SEC_GUARD_ADMIN_PORT, MCL_SEC_GUARD_ALERT_TOPIC, MCL_SEC_GUARD_PROPOSAL_LOG, MCL_SEC_GUARD_TRAINER_RUNS;",
           "MCL_REALM, MCL_REALM_KEY and the station pins are read by mcl_om, not by these modules"], code=True)
    d.edge("M530 126H670"); d.text("t-rel", 600, 118, "boots", anchor="middle")
    d.edge("M670 160H600V262H530"); d.text("t-rel", 592, 216, "start/1", anchor="end")
    d.edge("M285 314V338"); d.text("t-rel", 293, 334, "supervises")
    d.edge("M915 186V210"); d.text("t-rel", 923, 206, "subscriptions/0")
    d.edge("M915 314V338"); d.text("t-rel", 923, 334, "hands each fact over")
    d.edge("M670 290H620V398H530"); d.text("t-rel", 600, 390, "the proposal", anchor="middle")
    d.edge("M530 534H670"); d.text("t-rel", 600, 526, "routes to", anchor="middle")
    d.edge("M670 560H600V662H530"); d.text("t-rel", 552, 568, "scoreboard/1")
    d.edge("M915 586V610"); d.text("t-rel", 923, 606, "run/1, 409 while busy")
    d.edge("M915 714V738"); d.text("t-rel", 923, 734, "baseline, genome, episodes")
    d.text("t-desc", 40, 1146, "The three libraries at the bottom are linked into this release; their arrows are left out because every module above")
    d.text("t-desc", 40, 1164, "reaches the mesh through mcl_om, and the console is the only caller of jsx. mcl_sec_trainer is in the release since")
    d.text("t-desc", 40, 1182, "#16, but faber is not, and the Containerfile refuses a build whose release carries it.")
    d.legend(1220)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()
