#!/usr/bin/env bash
# Liquid Glass for Omarchy — uninstaller. Removes exactly what install.sh added:
# the fenced "omarchy-liquid-glass" blocks, the generated config, Glass Tuner,
# the theme hook and the HyprGlass Liquid plugin. Your settings in
# ~/.config/omarchy-liquid-glass are kept unless you pass --purge.

set -euo pipefail

DEST="$HOME/.local/share/omarchy-liquid-glass"
CONF="$HOME/.config/omarchy-liquid-glass"
HYPR="$HOME/.config/hypr"
FOOT="$HOME/.config/foot/foot.ini"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/omarchy-liquid-glass"
FONT_HOOK="$HOME/.config/omarchy/hooks/font-set.d/omarchy-liquid-glass"
DESKTOP="$HOME/.local/share/applications/glass-tuner.desktop"
BEGIN="omarchy-liquid-glass >>>"
END="<<< omarchy-liquid-glass"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

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

say "removing config blocks"
for f in hyprland.lua autostart.lua bindings.lua; do remove_block "$HYPR/$f" "--"; done
# Everything Glass Tuner sets in foot.ini is inside its fenced block; your own
# lines were never edited, so removing the block is all it takes.
remove_block "$FOOT" "#"
# versions before 1.1 edited your pad= line: put back the value saved at install
if [ -f "$FOOT" ] && [ -s "$CONF/foot-pad.orig" ]; then
    sed -i "0,/^pad=.*/s//$(cat "$CONF/foot-pad.orig")/" "$FOOT"; rm -f "$CONF/foot-pad.orig"
fi
rm -f "$HYPR/liquid_glass.lua" "$HOOK" "$FONT_HOOK" "$DESKTOP"
rm -rf "$DEST"

say "removing the plugin"
# Only the build Liquid Glass installed: our ownership record plus hyprpm saying it
# was built from our pinned local copy. Any other hyprglass install is left alone.
st="${HYPRPM_CACHE:-/var/cache/hyprpm/$USER}/HyprGlassLiquid/state.toml"
url=$(sed -n "s/^url = '\(.*\)'$/\1/p" "$st" 2>/dev/null)
if [ -z "${LG_SKIP_PLUGIN:-}" ] && [ "$(cat "$CONF/hyprpm-repo" 2>/dev/null)" = HyprGlassLiquid ] \
   && [ "$url" = "$DEST/hyprglass-src" ]; then
    hyprpm remove HyprGlassLiquid
elif [ -f "$st" ]; then
    say "leaving hyprpm's HyprGlassLiquid alone: Liquid Glass didn't install it (source: ${url:-unknown})"
fi
rm -f "$CONF/hyprpm-repo"

[ "${1:-}" = "--purge" ] && rm -rf "$CONF" && say "removed your saved settings"
hyprctl reload >/dev/null || true
say "done. Your pre-install files are in $CONF/backup-*/ if you want to compare."
