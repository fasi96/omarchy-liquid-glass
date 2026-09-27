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
DESKTOP="$HOME/.local/share/applications/omarchy-liquid-glass-tuner.desktop"
LEGACY_DESKTOP="$HOME/.local/share/applications/glass-tuner.desktop"   # versions before 1.2
MANIFEST="$CONF/installed.sha256"
GENERATED="$CONF/generated.sha256"
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

# Files: removed only if they are still exactly what we installed or generated
# (listed with their sha256 in $MANIFEST / $GENERATED). Anything you changed or
# added is kept and listed at the end.
KEPT=()
remove_if_ours() {   # remove_if_ours <file> <checksum list>
    [ -e "$1" ] || return 0
    if [ -f "$2" ] && grep -qxF "$(sha256sum "$1" | cut -d' ' -f1)  $1" "$2"; then
        rm -f "$1"
    else
        KEPT+=("$1")
    fi
}
if [ -f "$MANIFEST" ]; then
    while IFS= read -r line; do remove_if_ours "${line:66}" "$MANIFEST"; done < "$MANIFEST"
fi
[ -f "$MANIFEST" ] || for f in "$DESKTOP" "$HOOK" "$FONT_HOOK"; do remove_if_ours "$f" "$MANIFEST"; done   # no record: keep and list
remove_if_ours "$HYPR/liquid_glass.lua" "$GENERATED"

# the desktop entry versions before 1.2 wrote: removed only if byte-for-byte that
if [ -f "$LEGACY_DESKTOP" ]; then
    legacy="[Desktop Entry]
Name=Glass Tuner
Comment=Live sliders for Liquid Glass and the window look
Keywords=glass;liquid;blur;transparency;refraction;look;appearance;window;
Exec=python3 $DEST/tuner/tuner.py
Icon=preferences-desktop-theme
Type=Application
Categories=Settings;"
    if [ "$(cat "$LEGACY_DESKTOP")" = "$legacy" ]; then rm -f "$LEGACY_DESKTOP"; else KEPT+=("$LEGACY_DESKTOP"); fi
fi

# pinned plugin source: removed only if git says it is still exactly the pinned commit
src="$DEST/hyprglass-src"
if [ -d "$src" ]; then
    if [ -s "$CONF/plugin-rev" ] && [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" = "$(cat "$CONF/plugin-rev")" ] \
       && [ -z "$(git -C "$src" status --porcelain --ignored 2>/dev/null)" ]; then
        rm -rf "$src"
    else
        KEPT+=("$src")
    fi
fi
# folders we created go only if nothing else is left in them
[ -d "$DEST" ] && find "$DEST" -depth -type d -empty -delete
[ -d "$DEST" ] && KEPT+=("$DEST/ (has files Liquid Glass didn't install)")

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

rm -f "$MANIFEST" "$GENERATED" "$CONF/plugin-rev"   # bookkeeping for the files above

if [ ${#KEPT[@]} -gt 0 ]; then
    say "kept these because they aren't exactly what Liquid Glass installed (changed, added, or from an older version):"
    printf '    %s\n' "${KEPT[@]}"
fi

[ "${1:-}" = "--purge" ] && rm -rf "$CONF" && say "removed your saved settings"
hyprctl reload >/dev/null || true
say "done. Your pre-install files are in $CONF/backup-*/ if you want to compare."
