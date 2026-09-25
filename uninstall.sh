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
s = re.sub(r"\n?" + re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "\n", s, flags=re.S)
open(path, "w").write(s)
EOF
}

say "removing config blocks"
for f in hyprland.lua autostart.lua bindings.lua; do remove_block "$HYPR/$f" "--"; done
remove_block "$FOOT" "#"
# lines Glass Tuner manages outside the block: text colour, bold-in-bright, font weight
if [ -f "$FOOT" ]; then
    sed -i -e '/^foreground=[0-9a-fA-F]\{6\}$/d' -e '/^bold-text-in-bright=/d' -e 's/^\(font=.*\):weight=[a-z]*/\1/' "$FOOT"
    if [ -s "$CONF/foot-pad.orig" ]; then
        sed -i "s/^pad=.*/$(cat "$CONF/foot-pad.orig")/" "$FOOT"; rm -f "$CONF/foot-pad.orig"
    fi
fi
rm -f "$HYPR/liquid_glass.lua" "$HOOK" "$DESKTOP"
rm -rf "$DEST"

say "removing the plugin"
if [ -z "${LG_SKIP_PLUGIN:-}" ] && hyprpm list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Repository HyprGlassLiquid"; then
    hyprpm disable hyprglass || true
    hyprpm remove HyprGlassLiquid
fi

[ "${1:-}" = "--purge" ] && rm -rf "$CONF" && say "removed your saved settings"
hyprctl reload >/dev/null || true
say "done. Your pre-install files are in $CONF/backup-*/ if you want to compare."
