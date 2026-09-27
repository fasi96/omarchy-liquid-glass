#!/usr/bin/env python3
"""
Glass Tuner (omarchy-liquid-glass): live sliders for HyprGlass Liquid and the window look.

Serves a small control page on 127.0.0.1 and opens it as a floating chromium
app window. Every slider change is pushed to Hyprland straight away with
`hyprctl eval`; foot's transparency is pushed to every open foot window with an
OSC 11 escape. Nothing touches your config until you press Save, which writes
~/.config/hypr/liquid_glass.lua and the managed lines in ~/.config/foot/foot.ini.
The server quits when the tuner window is closed.
"""

import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
CONF_DIR = os.path.join(HOME, ".config/omarchy-liquid-glass")
STATE_FILE = os.path.join(CONF_DIR, "state.json")
LOOKS_FILE = os.path.join(CONF_DIR, "looks.json")                           # named looks
LUA_FILE = os.path.join(HOME, ".config/hypr/liquid_glass.lua")
FOOT_INI = os.path.join(HOME, ".config/foot/foot.ini")
PORT = 47613
TITLE = "Glass Tuner"
THEME_COLORS = os.path.join(HOME, ".local/state/omarchy/current/theme/colors.toml")


def theme_color(key, fallback):
    try:
        with open(THEME_COLORS) as f:
            m = re.search(rf'(?m)^{key}\s*=\s*"#([0-9a-fA-F]{{6}})"', f.read())
            if m:
                return m.group(1).lower()
    except OSError:
        pass
    return fallback


def text_color(boost):
    """The current theme's text colour, blended toward white by `boost`, so text
    stays themed but reads better on glass. 0 = exactly the theme colour."""
    fg = theme_color("foreground", "d8d8d8")
    rgb = [int(fg[i:i + 2], 16) for i in (0, 2, 4)]
    return "".join(f"{round(c + (255 - c) * boost):02x}" for c in rgb)


def foot_bg():
    """Current theme's terminal background, so pushing alpha never recolours."""
    try:
        with open(THEME_COLORS) as f:
            m = re.search(r'(?m)^background\s*=\s*"#([0-9a-fA-F]{6})"', f.read())
            if m:
                return m.group(1)
    except OSError:
        pass
    return "000000"

# name: (min, max, default). The page builds its sliders from this too.
# Past the plugin's documented 0-1 ranges on purpose ("overclocked"): the shader
# doesn't clamp, and at 1.0 edge bend is only 50 px, lens dome ~0.6% of the window,
# edge glow x0.15 and highlight x0.08, which is far too weak for an Apple look.
GLASS = {
    "blur_strength":        (0.0, 4.0, 2.0),
    "blur_iterations":      (1, 5, 3),
    "refraction_strength":  (-6.0, 6.0, 0.8),  # negative = bends outward (concave)
    "chromatic_aberration": (0.0, 2.5, 0.6),
    "lens_distortion":      (0.0, 15.0, 0.5),
    "edge_thickness":       (0.0, 0.4, 0.08),
    "fresnel_strength":     (0.0, 6.0, 0.6),
    "specular_strength":    (0.0, 10.0, 0.9),
    "glass_opacity":        (0.0, 1.0, 1.0),
    "brightness":           (0.3, 1.6, 1.0),
    "contrast":             (0.5, 1.5, 0.9),
    "saturation":           (0.0, 1.6, 1.0),
    "vibrancy":             (0.0, 1.0, 0.3),
    "vibrancy_darkness":    (0.0, 1.0, 0.0),
    "adaptive_dim":         (0.0, 1.0, 0.2),
    "adaptive_boost":       (0.0, 1.0, 0.0),
    "tint_strength":        (0, 255, 34),
}
# Liquid Glass motion (Apple-style: motion comes from what you do). Needs the
# HyprGlass Liquid fork (github.com/fasi96/hyprglass). Tuner keys are the plugin's
# own keys. name: (min, max, default)
LIGHT = {
    "light_strength":       (0.0, 4.0, 1.5),     # light added on the rim (0 = glass motion only)
    "light_x":              (-0.5, 1.5, 0.25),   # across all monitors: 0 left edge, 1 right edge
    "light_y":              (-2.0, 1.0, -0.35),  # 0 = top of the monitors, below 0 = above them
    "light_sharpness":      (0.5, 16.0, 4.0),
    "light_width":          (2, 80, 20),         # px into the glass
    "light_far":            (0.0, 1.0, 0.35),    # reflection on the side away from the light
    "light_bend":           (-4.0, 4.0, 1.2),
    "light_cursor":         (0.0, 1.0, 0.6),     # how far the light leans toward the cursor
    "light_inactive":       (0.0, 1.0, 0.6),     # unfocused windows' share
    "light_drift":          (0.0, 0.5, 0.12),    # how far the light slowly wanders (0 = still)
    "light_drift_period":   (10.0, 180.0, 45.0), # seconds per wander
    "light_lag":            (0.0, 1.5, 0.25),    # seconds light + parallax take to catch the cursor
    "parallax_strength":    (0.0, 80.0, 12.0),   # px the view behind the glass shifts with the cursor
    "parallax_depth":       (0.0, 3.0, 0.8),     # extra shift toward the rim (thick glass)
    "oil_amount":           (0.0, 1.5, 0.35),    # oil-film sheen: slow iridescent swirls
    "oil_speed":            (0.02, 2.0, 0.3),
    "oil_scale":            (40, 800, 220),      # swirl size, px
    "oil_color":            (0.0, 1.0, 1.0),     # 0 clear sheen .. 1 full iridescence
    "oil_warp":             (0.0, 4.0, 0.6),     # ripple of the view behind
    "oil_inactive":         (0.0, 1.0, 1.0),     # unfocused windows' share (0 = focused only)
    "oil_fps":              (5, 60, 30),
    "glow_strength":        (0.0, 4.0, 1.3),     # light added by the click glow (0 = flex only)
    "glow_duration":        (0.1, 3.0, 0.8),
    "glow_spread":          (0.2, 3.0, 1.2),     # share of the window size
    "glow_ring":            (5, 200, 50),        # px
    "glow_flex":            (-4.0, 4.0, 1.2),
    "materialize_duration": (0.05, 2.0, 0.45),   # seconds
}
# Edge shaping from hyprglass v0.9.0 (sent only when the loaded plugin has them).
# The defaults are the plugin's own, so a saved look without them doesn't change.
EDGE = {
    "refraction_flow":      (0.0, 1.0, 0.0),     # 0 bends toward the centre, 1 along the edges
    "refraction_spread":    (0.0, 1.0, 1.0),     # 1 bends across the window, 0 only a rim with a flat middle
    "fresnel_tint":         (0.0, 1.0, 0.0),     # edge glow colour: 0 white, 1 the colours behind the glass
    "specular_angle":       (0, 360, 0),         # top highlight direction, degrees clockwise from the top
    "bevel_strength":       (0.0, 2.0, 0.0),     # thin lit line along the glass edge
    "bevel_size":           (1.0, 24.0, 6.0),    # px
    "bevel_angle":          (0, 360, 315),       # where the line's light comes from
    "bevel_shadow":         (0.0, 1.0, 0.0),     # darker on the side away from the light
    "bevel_tint":           (0.0, 1.0, 0.0),     # 0 its own colour, 1 the colours behind the glass
    "self_sample":          (0.0, 1.0, 0.0),     # mixes the window's own content into the glass
}
# Text in foot (applies to terminals, not the glass plugin)
FONT_WEIGHTS = ["regular", "medium", "semibold", "bold"]

LOOK = {
    "text_boost":  (0.0, 1.0, 0.35),     # theme text colour blended toward white (0 = theme colour)
    "foot_alpha":  (0.0, 1.0, 0.45),
    "foot_pad":    (0, 90, 14),          # text inset, keeps text off the glass rim
    "rounding":    (0, 30, 12),
    "gaps_in":     (0, 30, 8),
    "gaps_out":    (0, 60, 16),
    "border_size": (0, 6, 2),
    # glass rim: a see-through border lit from one side
    "rim_lit":      (0.0, 1.0, 0.7),     # opacity of the bright (lit) corner
    "rim_side":     (0.0, 1.0, 0.06),    # opacity along the sides in between
    "rim_far":      (0.0, 1.0, 0.3),     # opacity of the reflection on the opposite corner
    "rim_angle":    (0, 360, 45),        # where the light comes from: 45 top-left, 135 top-right, 225 bottom-right, 315 bottom-left
    "rim_inactive": (0.0, 1.0, 0.45),    # unfocused windows get this fraction of it
}
BOOLS = {"bold_bright": True, "glass_on": True, "shadow": True, "border_spin": False, "glass_border": True,
         "light_on": True, "glow_on": True, "materialize_on": True,
         "parallax_on": True, "drift_on": False, "oil_on": True}
INT_KEYS = {"specular_angle", "bevel_angle", "oil_scale", "oil_fps", "light_width", "glow_ring", "foot_pad", "blur_iterations", "tint_strength", "rounding", "gaps_in", "gaps_out", "border_size", "rim_angle"}


def defaults():
    """Built-in values, overlaid with the look shipped in ../defaults.json."""
    d = {k: v[2] for k, v in {**GLASS, **LIGHT, **EDGE, **LOOK}.items()}
    d.update(_shipped())
    d.update(BOOLS)
    d["font_weight"] = "medium"
    d.update(tint="8899aa", rim_color="ffffff", light_color="ffffff", bevel_color="ffffff")
    return d


def _shipped():
    try:
        with open(os.path.join(HERE, "..", "defaults.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def clean(raw):
    """Clamp and type-check everything: these values end up inside Lua code."""
    s = defaults()
    for k, (lo, hi, _) in {**GLASS, **LIGHT, **EDGE, **LOOK}.items():
        if k in raw:
            try:
                v = min(max(float(raw[k]), lo), hi)
            except (TypeError, ValueError):
                continue
            s[k] = int(round(v)) if k in INT_KEYS else round(v, 3)
    for k in BOOLS:
        if k in raw:
            s[k] = bool(raw[k])
    if raw.get("font_weight") in FONT_WEIGHTS:
        s["font_weight"] = raw["font_weight"]
    for k in ("tint", "rim_color", "light_color", "bevel_color"):
        if isinstance(raw.get(k), str) and re.fullmatch(r"[0-9a-fA-F]{6}", raw[k]):
            s[k] = raw[k].lower()
    return s


# A theme can ship its own glass look (liquid-glass.json next to its colors.toml).
# While such a theme is active, the tuner shows that look, and Save keeps your
# tweaks per theme (themes/<theme>.json) so your own look in state.json stays put.
THEME_DIR = os.path.join(HOME, ".local/state/omarchy/current/theme")
THEME_NAME_FILE = os.path.join(HOME, ".local/state/omarchy/current/theme.name")


def theme_name():
    try:
        with open(THEME_NAME_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def theme_state_file():
    """Where the active theme's look is saved, or None when the theme has no look."""
    name = theme_name()
    mine = os.path.join(CONF_DIR, "themes", re.sub(r"[^A-Za-z0-9._-]+", "-", name) + ".json")
    if name and os.path.exists(mine):
        return mine
    if os.path.exists(os.path.join(THEME_DIR, "liquid-glass.json")):
        return mine
    return None


def _read(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_state():
    base = _read(STATE_FILE)
    s = clean(base) if isinstance(base, dict) else defaults()
    tf = theme_state_file()
    if tf:
        look = _read(tf) if os.path.exists(tf) else _read(os.path.join(THEME_DIR, "liquid-glass.json"))
        if isinstance(look, dict):
            s = clean({**s, **look})
    return s


# ---------------- named looks ----------------

def load_looks():
    try:
        with open(LOOKS_FILE) as f:
            data = json.load(f)
        looks = {n: clean(v) for n, v in (data.get("looks") or {}).items() if isinstance(v, dict)}
        active = data.get("active") if data.get("active") in looks else None
        return {"looks": looks, "active": active}
    except (OSError, ValueError, AttributeError):
        return {"looks": {}, "active": None}


def write_looks(data):
    os.makedirs(CONF_DIR, exist_ok=True)
    with open(LOOKS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def look_name(raw):
    name = raw.strip() if isinstance(raw, str) else ""
    if not 1 <= len(name) <= 40 or any(ord(c) < 32 for c in name):
        return None
    return name


# ---------------- Lua ----------------

THEMED = {"brightness", "contrast", "saturation", "vibrancy", "vibrancy_darkness", "adaptive_dim", "adaptive_boost"}


_light_ok = [None]


def light_supported():
    """True when the loaded hyprglass has the Liquid Glass motion options (the fork)."""
    if _light_ok[0] is None:
        out = subprocess.run(["hyprctl", "getoption", "plugin:hyprglass:light_strength"],
                             capture_output=True, text=True).stdout
        _light_ok[0] = bool(out) and "no such option" not in out
    return _light_ok[0]


def edge_supported():
    """True when the loaded hyprglass has the v0.9.0 edge options."""
    if _edge_ok[0] is None:
        out = subprocess.run(["hyprctl", "getoption", "plugin:hyprglass:refraction_flow"],
                             capture_output=True, text=True).stdout
        _edge_ok[0] = bool(out) and "no such option" not in out
    return _edge_ok[0]


_edge_ok = [None]


def edge_lua(s, preview_off=False):
    vals = {k: s[k] for k in EDGE}
    if preview_off or not s["glass_on"]:
        vals["bevel_strength"] = vals["self_sample"] = 0.0
    body = ", ".join(f"{k} = {float(v)}" for k, v in vals.items())
    # white = the plugin's own default (alpha 0); any other colour replaces white fully
    col = "0xffffff00" if s["bevel_color"] == "ffffff" else f"0x{s['bevel_color']}ff"
    return f"hl.plugin.hyprglass.config({{ {body}, bevel_color = {col} }})\n"


def light_lua(s, preview_off=False):
    live = s["glass_on"] and not preview_off
    vals = {k: s[k] for k in LIGHT}
    # the switches turn an effect off entirely; the sliders only shape it
    if not (live and s["light_on"]):
        vals["light_strength"] = vals["light_bend"] = 0.0
    if not (live and s["glow_on"]):
        vals["glow_strength"] = vals["glow_flex"] = 0.0
    if not s["materialize_on"]:
        vals["materialize_duration"] = 0.0
    if not (live and s["parallax_on"]):
        vals["parallax_strength"] = 0.0
    if not (live and s["oil_on"]):
        vals["oil_amount"] = 0.0
    if not (live and s["drift_on"]):
        vals["light_drift"] = 0.0
    body = ", ".join(f"{k} = {float(v)}" for k, v in vals.items())
    return f"hl.plugin.hyprglass.config({{ {body}, light_color = 0x{s['light_color']} }})\n"


def glass_lua(s, preview_off=False):
    # Global values, not a preset: re-defining a preset through `hyprctl eval`
    # never reaches the screen, global config does. The plugin ships dark-theme
    # defaults for the THEMED keys that beat plain globals, so those go in `dark`.
    plain, themed = [], []
    for k in GLASS:
        if k == "tint_strength":
            continue
        v = 0.0 if (k == "glass_opacity" and (preview_off or not s["glass_on"])) else s[k]
        (themed if k in THEMED else plain).append(f"{k} = {v}")
    plain.append(f"tint_color = 0x{s['tint']}{s['tint_strength']:02x}")
    return (
        "hl.plugin.hyprglass.config({ enabled = false, default_theme = \"dark\", default_preset = \"default\",\n"
        f"  {', '.join(plain)},\n"
        f"  dark = {{ {', '.join(themed)} }} }})\n"
    )


NEON = ('{ colors = { "rgba(22d3eeff)", "rgba(8b5cf6ff)", "rgba(ec4899ff)" }, angle = 45 }', '"rgba(ffffff18)"')


def rim(s, scale):
    """See-through gradient border: bright at the lit corner, faint along the
    sides, a softer reflection on the far corner."""
    a = lambda v: f"rgba({s['rim_color']}{int(round(min(v * scale, 1) * 255)):02x})"
    stops = [a(s["rim_lit"]), a(s["rim_side"]), a(s["rim_side"]), a(s["rim_far"])]
    return f'{{ colors = {{ {", ".join(f"{c!r}".replace("'", '"') for c in stops)} }}, angle = {s["rim_angle"]} }}'


def look_lua(s):
    active, inactive = (rim(s, 1), rim(s, s["rim_inactive"])) if s["glass_border"] else NEON
    return (
        "hl.config({\n"
        f"  general = {{ gaps_in = {s['gaps_in']}, gaps_out = {s['gaps_out']}, border_size = {s['border_size']},\n"
        f"    col = {{ active_border = {active}, inactive_border = {inactive} }} }},\n"
        f"  decoration = {{ rounding = {s['rounding']}, shadow = {{ enabled = {str(s['shadow']).lower()} }} }},\n"
        "})\n"
        f'hl.animation({{ leaf = "borderangle", enabled = {str(s["border_spin"]).lower()}, '
        'speed = 60, bezier = "linear", style = "loop" })\n'
    )


def hypr_eval(code):
    r = subprocess.run(["hyprctl", "eval", code], capture_output=True, text=True)
    return r.stdout.strip()


# ---------------- foot ----------------

def foot_ttys():
    """ptys of every running foot window (the tty of each foot's child shell)."""
    ttys = set()
    pids = subprocess.run(["pgrep", "-x", "foot"], capture_output=True, text=True).stdout.split()
    for pid in pids:
        out = subprocess.run(["ps", "-o", "tty=", "--ppid", pid], capture_output=True, text=True).stdout
        for t in out.split():
            if t.startswith("pts/"):
                ttys.add("/dev/" + t)
    return ttys


def push_foot_text(boost):
    """Recolour the text of every open foot window (OSC 10)."""
    seq = f"\033]10;#{text_color(boost)}\033\\"
    for t in foot_ttys():
        try:
            with open(t, "w") as f:
                f.write(seq)
        except OSError:
            pass


FOOT_BEGIN = "# omarchy-liquid-glass >>>"
FOOT_END = "# <<< omarchy-liquid-glass"
_FOOT_BLOCK = re.compile(r"\n?" + re.escape(FOOT_BEGIN) + r".*?" + re.escape(FOOT_END) + r"\n?", re.S)


def write_foot(s, ini):
    """Everything we set in foot.ini lives in one fenced block at the end of
    the file (later values win in foot). The user's own lines are never
    edited or removed, and uninstall.sh just drops the block."""
    user = _FOOT_BLOCK.sub("\n", ini).rstrip("\n")
    main = ["[main]"]
    m = re.search(r"(?m)^font=([^\n]*)$", user)             # the user's font (Omarchy keeps it current)
    if m and s["font_weight"] != "regular":
        opts = [o for o in m.group(1).split(":") if not o.startswith("weight=")]
        main.append("font=" + ":".join(opts + [f"weight={s['font_weight']}"]))
    main.append(f"pad={s['foot_pad']}x{s['foot_pad']}")
    main.append(f"bold-text-in-bright={'yes' if s['bold_bright'] else 'no'}")
    colors = ["[colors-dark]", f"alpha={s['foot_alpha']}"]
    if s["text_boost"] > 0.001:
        colors.append(f"foreground={text_color(s['text_boost'])}")
    block = "\n".join([FOOT_BEGIN, "# Liquid Glass (managed by Glass Tuner; ./uninstall.sh removes this block)"]
                      + main + colors + [FOOT_END])
    return user + "\n\n" + block + "\n"


def push_foot_alpha(alpha):
    seq = f"\033]11;[{int(round(alpha * 100))}]#{foot_bg()}\033\\"
    for t in foot_ttys():
        try:
            with open(t, "w") as f:
                f.write(seq)
        except OSError:
            pass


# ---------------- apply / save ----------------

_last_alpha = [None]
_last_text = [None]


_live = {"state": None}   # what's on screen right now, saved or not


def apply(s, preview_off=False):
    _live["state"] = s
    hypr_eval(glass_lua(s, preview_off) + (edge_lua(s, preview_off) if edge_supported() else "")
              + (light_lua(s, preview_off) if light_supported() else "") + look_lua(s))
    if _last_alpha[0] != s["foot_alpha"]:
        push_foot_alpha(s["foot_alpha"])
        _last_alpha[0] = s["foot_alpha"]
    if _last_text[0] != s["text_boost"]:
        push_foot_text(s["text_boost"])
        _last_text[0] = s["text_boost"]


def save(s, persist=True):
    """Write the config for s. persist=False (theme hook) only writes the
    generated config, not your saved values."""
    _live["state"] = s
    os.makedirs(CONF_DIR, exist_ok=True)
    if persist:
        target = theme_state_file() or STATE_FILE
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w") as f:
            json.dump(s, f, indent=2)

    glass_block = glass_lua(s).replace("\n", "\n  ").rstrip()
    light_block = light_lua(s).replace("\n", "\n  ").rstrip()
    edge_block = edge_lua(s).replace("\n", "\n  ").rstrip()
    lua = (
        "-- Liquid Glass for Omarchy: glass on terminals + the window look.\n"
        "-- GENERATED by Glass Tuner (Super+Ctrl+G, Save). Edit with the tuner, not by hand:\n"
        "-- values live in ~/.config/omarchy-liquid-glass/state.json.\n"
        "-- https://github.com/fasi96/omarchy-liquid-glass\n"
        "if hl.plugin.hyprglass then\n"
        f"  {glass_block}\n"
        + (f"  -- edge shaping (hyprglass v0.9.0)\n  {edge_block}\n" if edge_supported() else "")
        + (f"  -- Liquid Glass motion (HyprGlass Liquid fork)\n  {light_block}\n" if light_supported() else "")
        + "end\n\n"
        + look_lua(s)
        + ("\no.window({ tag = \"terminal\" }, { tag = \"+hyprglass_enabled\" })\n" if s["glass_on"] else "")
    )
    with open(LUA_FILE, "w") as f:
        f.write(lua)

    with open(FOOT_INI) as f:
        ini = f.read()
    ini = write_foot(s, ini)
    with open(FOOT_INI, "w") as f:
        f.write(ini)

    subprocess.run(["hyprctl", "reload"], capture_output=True)
    errs = subprocess.run(["hyprctl", "configerrors"], capture_output=True, text=True).stdout.strip()
    return errs


def revert():
    _live["state"] = None   # don't let the reload watcher put the unsaved values back
    subprocess.run(["hyprctl", "reload"], capture_output=True)
    s = load_state()
    push_foot_alpha(s["foot_alpha"])
    _last_alpha[0] = s["foot_alpha"]
    return s


# ---------------- actions ----------------

def clients():
    return json.loads(subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True).stdout or "[]")


def dsp(cmd):
    subprocess.run(["hyprctl", "dispatch", cmd], capture_output=True)


def wait_title(title, secs=6, key="title"):
    for _ in range(int(secs * 10)):
        for c in clients():
            if c.get(key) == title:
                return c
        time.sleep(0.1)
    return None


def float_center(addr, w, h, right=False):
    mon = json.loads(subprocess.run(["hyprctl", "activeworkspace", "-j"], capture_output=True, text=True).stdout)
    mons = json.loads(subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True, text=True).stdout)
    m = next((m for m in mons if m["id"] == mon.get("monitorID")), mons[0])
    mw, mh = int(m["width"] / m["scale"]), int(m["height"] / m["scale"])
    w, h = min(w, mw - 48), min(h, mh - 48)   # fit short or scaled screens (e.g. a 4K TV at 2.5x is 864 tall)
    x, y = m["x"] + (mw - w) // 2, m["y"] + (mh - h) // 2
    if right:   # tuner docks to the right edge so it never covers the test window
        x = m["x"] + mw - w - 24
    sel = f'window = "address:{addr}"'
    dsp(f'hl.dsp.window.float({{ action = "enable", {sel} }})')
    dsp(f"hl.dsp.window.resize({{ x = {w}, y = {h}, {sel} }})")
    dsp(f"hl.dsp.window.move({{ x = {x}, y = {y}, {sel} }})")


TEST_CLASS = "org.omarchy.glass-test"


def test_window(pad):
    subprocess.Popen(
        ["uwsm-app", "--", "foot", f"--app-id={TEST_CLASS}", f"--override=pad={pad}x{pad}",
         "sh", "-c", "fastfetch; exec ${SHELL:-bash}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    c = wait_title(TEST_CLASS, key="class")
    if c:
        float_center(c["address"], 1100, 700)


def next_wallpaper():
    subprocess.run(["omarchy-theme-bg-next"], capture_output=True)


# ---------------- http ----------------

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/":
            with open(os.path.join(HERE, "tuner.html"), "rb") as f:
                self.send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/looks":
            self.send(200, json.dumps(load_looks()))
        elif self.path == "/state":
            meta = {"glass": {**GLASS, **LIGHT, **EDGE}, "look": LOOK, "defaults": defaults(),
                    "light": light_supported(), "edge": edge_supported()}
            self.send(200, json.dumps({"state": load_state(), "meta": meta}))
        else:
            self.send(404, "{}")

    def do_POST(self):
        # Only accept same-origin requests from the tuner page itself.
        if self.headers.get("Origin") not in (None, f"http://127.0.0.1:{PORT}"):
            return self.send(403, "{}")
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self.send(400, "{}")
        s = clean(body.get("state") or {})
        if self.path == "/apply":
            apply(s, preview_off=bool(body.get("compare")))
            self.send(200, "{}")
        elif self.path == "/looks/save":
            name = look_name(body.get("name"))
            if not name:
                return self.send(400, json.dumps({"error": "Name must be 1-40 characters"}))
            data = load_looks()
            data["looks"][name] = s
            write_looks(data)
            self.send(200, json.dumps(data))
        elif self.path == "/looks/delete":
            data = load_looks()
            data["looks"].pop(body.get("name"), None)
            if data["active"] not in data["looks"]:
                data["active"] = None
            write_looks(data)
            self.send(200, json.dumps(data))
        elif self.path == "/save":
            data = load_looks()   # remember which named look is the saved one (if it's unchanged)
            data["active"] = body.get("look") if body.get("look") in data["looks"] else None
            write_looks(data)
            errs = save(s)
            self.send(200, json.dumps({"errors": errs}))
        elif self.path == "/revert":
            self.send(200, json.dumps({"state": revert()}))
        elif self.path == "/test-window":
            threading.Thread(target=test_window, args=(s["foot_pad"],), daemon=True).start()
            self.send(200, "{}")
        elif self.path == "/wallpaper":
            next_wallpaper()
            self.send(200, "{}")
        else:
            self.send(404, "{}")


def open_window():
    subprocess.Popen(
        ["uwsm-app", "--", "chromium", f"--user-data-dir={HOME}/.cache/glass-tuner", "--no-first-run",
         "--ozone-platform=wayland", f"--app=http://127.0.0.1:{PORT}/"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    c = wait_title(TITLE, 15)
    if not c:
        return
    addr = c["address"]
    float_center(addr, 460, 940, right=True)
    # quit once the window is gone
    while any(x.get("address") == addr for x in clients()):
        time.sleep(1.5)
    os._exit(0)


def watch_reloads():
    """A theme change (or anything else) runs `hyprctl reload`, which puts the
    saved config back. While the tuner is open, put the values you're still
    dialling in back on screen, and re-send terminal transparency with the new
    theme's background colour."""
    path = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "hypr",
                        os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", ""), ".socket2.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except OSError:
        return
    buf = b""
    while True:
        data = sock.recv(4096)
        if not data:
            return
        buf += data
        *lines, buf = buf.split(b"\n")
        if any(l.startswith(b"configreloaded>>") for l in lines):
            time.sleep(1.2)   # let theme-set finish recolouring terminals first
            s = _live["state"]
            if s is not None:
                hypr_eval(glass_lua(s) + (edge_lua(s) if edge_supported() else "")
                          + (light_lua(s) if light_supported() else "") + look_lua(s))
            push_foot_alpha((s or load_state())["foot_alpha"])
            push_foot_text((s or load_state())["text_boost"])


def theme_hook():
    """Run by the Omarchy theme-set hook. A theme that ships a glass look gets
    it (and a regular theme gets your own look back); either way the text
    colour is re-derived from the new theme and pushed to open terminals."""
    s = load_state()
    if theme_state_file() or _glass_was_themed():
        save(s, persist=False)                    # writes liquid_glass.lua + foot.ini, reloads
        _mark_themed(bool(theme_state_file()))
        push_foot_alpha(s["foot_alpha"])
    else:
        with open(FOOT_INI) as f:
            ini = f.read()
        new = write_foot(s, ini)
        if new != ini:
            with open(FOOT_INI, "w") as f:
                f.write(new)
    push_foot_text(s["text_boost"])


THEMED_MARK = os.path.join(CONF_DIR, ".theme-look-active")


def _glass_was_themed():
    return os.path.exists(THEMED_MARK)


def _mark_themed(on):
    if on:
        open(THEMED_MARK, "w").close()
    elif os.path.exists(THEMED_MARK):
        os.remove(THEMED_MARK)


def main():
    if "--theme-hook" in sys.argv:
        return theme_hook()
    if "--foot-sync" in sys.argv:     # font-set hook
        with open(FOOT_INI) as f:
            ini = f.read()
        new = write_foot(load_state(), ini)
        if new != ini:
            with open(FOOT_INI, "w") as f:
                f.write(new)
        return
    if "--toggle" in sys.argv:        # bar button: glass on/off, saved so it sticks
        s = load_state()
        s["glass_on"] = not s["glass_on"]
        errs = save(s)
        apply(s)
        print(errs or ("glass on" if s["glass_on"] else "glass off"))
        return
    if "--save" in sys.argv:          # installer: write the config from the saved (or shipped) look
        errs = save(load_state())
        print(errs or "saved")
        return
    for c in clients():   # already open: just focus it
        if c.get("title") == TITLE:
            dsp(f'hl.dsp.focus({{ window = "address:{c["address"]}" }})')
            return
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    apply(load_state())   # screen matches the sliders from the start
    threading.Thread(target=open_window, daemon=True).start()
    threading.Thread(target=watch_reloads, daemon=True).start()
    srv.serve_forever()


if __name__ == "__main__":
    main()
