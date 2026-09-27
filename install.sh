#!/usr/bin/env bash
# Liquid Glass for Omarchy — installer.
#
#   git clone https://github.com/fasi96/omarchy-liquid-glass
#   cd omarchy-liquid-glass && ./install.sh
#
# What it does (everything it adds to your config is fenced with
# "omarchy-liquid-glass" markers, and ./uninstall.sh removes exactly that):
#   1. installs the HyprGlass Liquid plugin with hyprpm (replaces upstream HyprGlass if present)
#   2. installs Glass Tuner to ~/.local/share/omarchy-liquid-glass (Super+Ctrl+G, or the app launcher)
#   3. adds to ~/.config/hypr: liquid_glass.lua (generated) + a require, a login line that loads
#      hyprpm plugins, and the Super+Ctrl+G binding
#   4. makes foot see-through (alpha) so the glass shows, and applies the shipped look
#   5. installs a theme-set hook so terminal text keeps following your theme
# Backups of every file it touches go to ~/.config/omarchy-liquid-glass/backup-<time>/.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/omarchy-liquid-glass"
CONF="$HOME/.config/omarchy-liquid-glass"
HYPR="$HOME/.config/hypr"
FOOT="$HOME/.config/foot/foot.ini"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/omarchy-liquid-glass"
DESKTOP="$HOME/.local/share/applications/omarchy-liquid-glass-tuner.desktop"
MANIFEST="$CONF/installed.sha256"   # "sha256  path" of every file we install; uninstall.sh only removes exact matches
PLUGIN_REPO="https://github.com/fasi96/hyprglass"
HYPRGLASS_REV="d7d650e0208ab9b8ea7e9bf5afca6927a9ee6512"   # reviewed plugin commit; bump deliberately
PLUGIN_SRC="$DEST/hyprglass-src"
FONT_HOOK="$HOME/.config/omarchy/hooks/font-set.d/omarchy-liquid-glass"
TESTED_HYPRLAND="0.56.2"
BEGIN="omarchy-liquid-glass >>>"
END="<<< omarchy-liquid-glass"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# add_block FILE COMMENT_PREFIX CONTENT — append a fenced block once (replace it if already there)
add_block() {
    local file=$1 c=$2 content=$3
    mkdir -p "$(dirname "$file")"; touch "$file"
    remove_block "$file" "$c"
    printf '\n%s %s\n%s\n%s %s\n' "$c" "$BEGIN" "$content" "$c" "$END" >> "$file"
}
remove_block() {
    local file=$1 c=$2
    [ -f "$file" ] || return 0
    python3 - "$file" "$c $BEGIN" "$c $END" <<'EOF'
import re, sys
path, begin, end = sys.argv[1:4]
s = open(path).read()
s = re.sub(r"(?:\n|^)" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", s, flags=re.S)   # exactly what add_block appended
open(path, "w").write(s)
EOF
}

# ours = the file is exactly what we installed last time (listed in the manifest)
ours() { [ -f "$MANIFEST" ] && grep -qxF "$(sha256sum "$1" | cut -d' ' -f1)  $1" "$MANIFEST"; }
# before writing a path we own: if something else is there, keep a copy of it
guard() {
    local f
    for f in "$@"; do
        [ -e "$f" ] || continue
        ours "$f" && continue
        mkdir -p "$BK/replaced"
        cp -a "$f" "$BK/replaced/"
        warn "$f isn't in Liquid Glass's install record (or you changed it; versions before 1.2 kept no record); a copy is in $BK/replaced/"
    done
}

# ---------------------------------------------------------------- checks
for c in hyprctl hyprpm python3 jq chromium foot; do
    command -v "$c" >/dev/null || die "missing: $c"
done
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || die "run this inside your Hyprland session"
[ -d "${OMARCHY_PATH:-/usr/share/omarchy}" ] || warn "Omarchy not found: the config hooks assume Omarchy's layout (~/.config/hypr/*.lua with the o helper)"

ver=$(hyprctl version -j | jq -r .tag | sed 's/^v//')
[ "$ver" = "$TESTED_HYPRLAND" ] || warn "Hyprland $ver: tested on $TESTED_HYPRLAND only; the plugin may not build on other versions"

term=$(xdg-terminal-exec --print-id 2>/dev/null || true)
case "$term" in *foot*) ;; *) warn "your default terminal is '${term:-unknown}': the glass shows through see-through windows, and Glass Tuner's terminal settings are for foot" ;; esac

[[ " $* " == *" --plugin-only "* ]] && LG_PLUGIN_ONLY=1 && LG_YES=1
[[ " $* " == *" --replace-hyprglass "* ]] && LG_REPLACE_HYPRGLASS=1
[[ " $* " == *" --hyprpm-update "* ]] && LG_YES_HYPRPM_UPDATE=1

# ---------------------------------------------------------------- consent
[[ " $* " == *" --yes "* || " $* " == *" -y "* ]] && LG_YES=1
if [ -z "${LG_YES:-}" ] && [ -t 0 ]; then
    cat <<EOF

Liquid Glass will:
  - build and load the HyprGlass Liquid plugin with hyprpm (asks for your password)
  - add fenced blocks to ~/.config/hypr/hyprland.lua, autostart.lua and bindings.lua
  - make foot see-through ([colors-dark] alpha in ~/.config/foot/foot.ini)
  - install Glass Tuner (Super+Ctrl+G) and a theme hook
Every file it touches is backed up first, and ./uninstall.sh removes it all.

EOF
    if command -v gum >/dev/null; then
        gum confirm "Set up Liquid Glass?" || { echo "nothing changed"; exit 0; }
    else
        read -rp "Set up Liquid Glass? [y/N] " a; [[ $a == [yY]* ]] || { echo "nothing changed"; exit 0; }
    fi
fi

# ---------------------------------------------------------------- backups
BK="$CONF/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
for f in "$HYPR/hyprland.lua" "$HYPR/bindings.lua" "$HYPR/autostart.lua" "$FOOT"; do
    [ -f "$f" ] && cp "$f" "$BK/"
done
say "backups in $BK"

# ---------------------------------------------------------------- plugin
# The native plugin is built from ONE reviewed commit of the fork, never from a
# moving branch: fetch exactly that commit into a local repo that holds nothing
# newer, check its hash, and let hyprpm build from that local copy at that
# commit. `hyprpm update` can only ever pull from this pinned local repo.
# hyprpm repositories that provide a "hyprglass" plugin, one "name<TAB>url" per line
glass_repos() {
    local st
    for st in "${HYPRPM_CACHE:-/var/cache/hyprpm/$USER}"/*/state.toml; do
        [ -f "$st" ] && grep -q '^\[hyprglass\]' "$st" || continue
        printf '%s\t%s\n' "$(sed -n "s/^name = '\(.*\)'$/\1/p" "$st")" "$(sed -n "s/^url = '\(.*\)'$/\1/p" "$st")"
    done
}

# Ours = recorded when we installed it AND hyprpm says it was built from our pinned local copy.
owns_repo() { [ "$1" = HyprGlassLiquid ] && [ "$2" = "$PLUGIN_SRC" ] && [ "$(cat "$CONF/hyprpm-repo" 2>/dev/null)" = "$1" ]; }

# Only one "hyprglass" plugin can be loaded. Our own earlier build is replaced
# silently; anything else was installed outside Liquid Glass, so ask first and
# leave it alone unless the user says yes (or passes --replace-hyprglass).
# Decides up front (before anything changes); the removal happens later.
REMOVE_REPOS=()
decide_glass_repos() {
    local name url
    while IFS=$'\t' read -r name url; do
        [ -n "$name" ] || continue
        if owns_repo "$name" "$url"; then
            say "replacing Liquid Glass's earlier build ($name)"
        else
            warn "hyprpm has '$name' installed from ${url:-an unknown source}, which Liquid Glass did not install."
            warn "It provides the same 'hyprglass' plugin, so only one of them can be loaded."
            if [ -n "${LG_REPLACE_HYPRGLASS:-}" ]; then
                :
            elif [ -t 0 ] && command -v gum >/dev/null; then
                gum confirm "Remove '$name' from hyprpm so Liquid Glass can install its build?" \
                    || die "left '$name' untouched; nothing was changed in hyprpm"
            elif [ -t 0 ]; then
                read -rp "Remove '$name' from hyprpm so Liquid Glass can install its build? [y/N] " a
                [[ $a == [yY]* ]] || die "left '$name' untouched; nothing was changed in hyprpm"
            else
                die "'$name' is installed outside Liquid Glass; run in a terminal, or pass --replace-hyprglass to replace it"
            fi
        fi
        REMOVE_REPOS+=("$name")
    done < <(glass_repos)
}

# hyprpm needs headers for the running Hyprland. They are fetched with
# `hyprpm update`, which also updates every other hyprpm plugin, so run it only
# when the headers are out of date, and ask first if other plugins are installed.
NEED_HEADERS=""
decide_headers() {
    local cache="${HYPRPM_CACHE:-/var/cache/hyprpm/$USER}" running have others name
    running=$(hyprctl version -j | jq -r .commit)
    have=$(sed -n "s/^hash = '\([0-9a-f]*\).*/\1/p" "$cache/state.toml" 2>/dev/null)
    [ -n "$running" ] && [ "$have" = "$running" ] && { say "hyprpm headers already match this Hyprland"; return; }
    NEED_HEADERS=1
    others=$(for st in "$cache"/*/state.toml; do
                 [ -f "$st" ] || continue
                 name=$(sed -n "s/^name = '\(.*\)'$/\1/p" "$st")
                 [[ " ${REMOVE_REPOS[*]} " == *" $name "* ]] || echo "$name"
             done)
    [ -z "$others" ] && return
    warn "hyprpm needs headers for this Hyprland; fetching them runs 'hyprpm update', which also updates your other hyprpm plugins: $(echo $others)"
    if [ -n "${LG_YES_HYPRPM_UPDATE:-}" ]; then return
    elif [ -t 0 ] && command -v gum >/dev/null; then gum confirm "Run 'hyprpm update' now?" || die "hyprpm left as it was; nothing changed"
    elif [ -t 0 ]; then read -rp "Run 'hyprpm update' now? [y/N] " a; [[ $a == [yY]* ]] || die "hyprpm left as it was; nothing changed"
    else die "hyprpm headers are out of date and 'hyprpm update' would update your other plugins; run in a terminal, or pass --hyprpm-update"
    fi
}

plugin_step() {
    # decide about other hyprglass installs before touching anything
    decide_glass_repos
    decide_headers

    say "installing build tools for hyprpm (sudo)"
    sudo pacman -S --needed --noconfirm base-devel cmake meson cpio pkgconf git >/dev/null

    say "fetching HyprGlass Liquid at the pinned commit ${HYPRGLASS_REV:0:12}"
    if [ -e "$PLUGIN_SRC" ]; then
        # ours = still exactly the commit we recorded, nothing modified or added
        if [ -s "$CONF/plugin-rev" ] && [ "$(git -C "$PLUGIN_SRC" rev-parse HEAD 2>/dev/null)" = "$(cat "$CONF/plugin-rev")" ] \
           && [ -z "$(git -C "$PLUGIN_SRC" status --porcelain --ignored 2>/dev/null)" ]; then
            rm -rf "$PLUGIN_SRC"
        else
            mkdir -p "$BK/replaced"; mv "$PLUGIN_SRC" "$BK/replaced/"
            warn "$PLUGIN_SRC wasn't Liquid Glass's untouched copy; moved it to $BK/replaced/"
        fi
    fi
    mkdir -p "$PLUGIN_SRC"
    git -C "$PLUGIN_SRC" init -q
    git -C "$PLUGIN_SRC" remote add origin "$PLUGIN_REPO"
    git -C "$PLUGIN_SRC" fetch -q origin "$HYPRGLASS_REV" || die "could not fetch commit $HYPRGLASS_REV from $PLUGIN_REPO"
    git -C "$PLUGIN_SRC" checkout -q -B main FETCH_HEAD
    git -C "$PLUGIN_SRC" remote remove origin
    [ "$(git -C "$PLUGIN_SRC" rev-parse HEAD)" = "$HYPRGLASS_REV" ] || die "fetched source is not commit $HYPRGLASS_REV"
    git -C "$PLUGIN_SRC" fsck --no-progress --no-dangling >/dev/null || die "fetched source failed git fsck"

    local r
    for r in "${REMOVE_REPOS[@]}"; do say "hyprpm: removing $r"; hyprpm remove "$r"; done

    if [ -n "$NEED_HEADERS" ]; then
        say "hyprpm: fetching Hyprland headers (can take a few minutes)"
        hyprpm update
    fi

    say "hyprpm: building HyprGlass Liquid ${HYPRGLASS_REV:0:12}"
    hyprpm add "$PLUGIN_SRC" "$HYPRGLASS_REV"
    echo HyprGlassLiquid > "$CONF/hyprpm-repo"      # ownership record, checked by owns_repo / uninstall.sh
    echo "$HYPRGLASS_REV" > "$CONF/plugin-rev"      # uninstall.sh removes $PLUGIN_SRC only if still exactly this
    hyprpm enable hyprglass
    hyprpm reload -n
}

if [ -n "${LG_SKIP_PLUGIN:-}" ]; then say "LG_SKIP_PLUGIN set: skipping the plugin step (testing)"; else
    plugin_step
fi
[ -n "${LG_PLUGIN_ONLY:-}" ] && { say "plugin rebuilt"; exit 0; }

# ---------------------------------------------------------------- files
say "installing Glass Tuner"
mkdir -p "$DEST/tuner" "$CONF"
TUNER_FILES=(tuner.py tuner.html)
for f in "${TUNER_FILES[@]}"; do guard "$DEST/tuner/$f"; cp "$SRC/tuner/$f" "$DEST/tuner/$f"; done
guard "$DEST/defaults.json"
cp "$SRC/defaults.json" "$DEST/"
[ -f "$CONF/state.json" ] || cp "$SRC/defaults.json" "$CONF/state.json"
[ -f "$CONF/looks.json" ] || cp "$SRC/looks-default.json" "$CONF/looks.json"

mkdir -p "$(dirname "$DESKTOP")"
guard "$DESKTOP"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Name=Glass Tuner
Comment=Live sliders for Liquid Glass and the window look
Keywords=glass;liquid;blur;transparency;refraction;look;appearance;window;
Exec=python3 $DEST/tuner/tuner.py
Icon=preferences-desktop-theme
Type=Application
Categories=Settings;
EOF

# ---------------------------------------------------------------- hypr config
say "hooking into ~/.config/hypr"
add_block "$HYPR/hyprland.lua" "--" '-- Liquid Glass: glass on terminals + the window look (generated by Glass Tuner)
require("hypr.liquid_glass")'
add_block "$HYPR/autostart.lua" "--" '-- load hyprpm plugins (HyprGlass Liquid), then re-read the config so liquid_glass.lua sees it
o.launch_on_start("sh -c '"'"'hyprpm reload -n; hyprctl reload'"'"'")'
add_block "$HYPR/bindings.lua" "--" "o.bind(\"SUPER + CTRL + G\", \"Glass Tuner\", \"python3 $DEST/tuner/tuner.py\")"

# ---------------------------------------------------------------- foot
# Glass Tuner keeps everything it sets in foot.ini inside one fenced block at
# the end (later values win in foot); your own lines are never edited.
say "making foot see-through"
mkdir -p "$(dirname "$FOOT")"; touch "$FOOT"
if [ -s "$CONF/foot-pad.orig" ]; then       # versions before 1.1 edited your pad= line: put it back
    sed -i "0,/^pad=.*/s//$(cat "$CONF/foot-pad.orig")/" "$FOOT"; rm -f "$CONF/foot-pad.orig"
fi

# ---------------------------------------------------------------- look + hook
say "applying the Liquid Glass look"
[ -f "$CONF/generated.sha256" ] || guard "$HYPR/liquid_glass.lua"   # someone else's file at our path: keep a copy
python3 "$DEST/tuner/tuner.py" --save

mkdir -p "$(dirname "$HOOK")"
guard "$HOOK" "$FONT_HOOK"
cat > "$HOOK" <<EOF
#!/bin/bash
# omarchy-liquid-glass: keep terminal text following the new theme
python3 "$DEST/tuner/tuner.py" --theme-hook
EOF
chmod +x "$HOOK"
mkdir -p "$(dirname "$FONT_HOOK")"
cat > "$FONT_HOOK" <<EOF
#!/bin/bash
# omarchy-liquid-glass: Omarchy rewrites every font= line on a font change; re-apply the glass font weight
python3 "$DEST/tuner/tuner.py" --foot-sync
EOF
chmod +x "$FONT_HOOK"

# record exactly what we installed, so uninstall.sh removes nothing else
{ for f in "${TUNER_FILES[@]}"; do echo "$DEST/tuner/$f"; done; echo "$DEST/defaults.json"; echo "$DESKTOP"; echo "$HOOK"; echo "$FONT_HOOK"; } \
    | while IFS= read -r f; do [ -f "$f" ] && sha256sum "$f"; done > "$MANIFEST"

errs=$(hyprctl configerrors)
[ -z "$errs" ] || warn "Hyprland reports config errors:\n$errs"

say "done. Open Glass Tuner with Super+Ctrl+G (or search \"Glass Tuner\")."
say "open a new terminal to see the glass. Uninstall: ./uninstall.sh"
