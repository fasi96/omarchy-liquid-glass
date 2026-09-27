#!/usr/bin/env bash
# Liquid Glass for Omarchy — uninstaller. Removes what install.sh added, and
# only that: the fenced "omarchy-liquid-glass" blocks, and files that are still
# exactly what it installed or generated (checked by sha256). Anything you
# changed or added is kept and listed. Your settings and the backups in
# ~/.config/omarchy-liquid-glass are kept; --purge removes the settings too
# (the backups always stay).
#
# install.sh also puts a copy of this script in ~/.local/share/omarchy-liquid-glass/,
# so it still works after the plugin folder is gone.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
CACHE="$HOME/.cache/omarchy-liquid-glass"                              # Glass Tuner's own browser profile
HYPRPM_DIR="${HYPRPM_CACHE:-/var/cache/hyprpm/$USER}"
BEGIN="omarchy-liquid-glass >>>"
END="<<< omarchy-liquid-glass"

PURGE=""
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

BLOCKS_PY="$HERE/lib/blocks.py"; [ -f "$BLOCKS_PY" ] || BLOCKS_PY="$DEST/lib/blocks.py"
KEPT=()
# remove our fenced block, but only if it is still exactly what Liquid Glass wrote
remove_block() {
    local rc=0
    [ -f "$BLOCKS_PY" ] || { grep -q "$BEGIN" "$1" 2>/dev/null && KEPT+=("the Liquid Glass block in $1 (can't verify it: lib/blocks.py is missing)"); return 0; }
    python3 "$BLOCKS_PY" remove "$1" "$2" || rc=$?
    [ "$rc" = 3 ] && KEPT+=("the Liquid Glass block in $1 (you changed it; delete the lines between the omarchy-liquid-glass markers yourself if you want it gone)")
    [ "$rc" = 0 ] || [ "$rc" = 3 ] || KEPT+=("the Liquid Glass block in $1 (couldn't check it)")
    return 0
}

# ---------------------------------------------------------------- config blocks
say "removing config blocks"
for f in hyprland.lua autostart.lua bindings.lua; do remove_block "$HYPR/$f" "--"; done
# Everything Glass Tuner sets in foot.ini is inside its fenced block; your own
# lines are never edited, so removing the block is all it takes.
remove_block "$FOOT" "#"
# versions before 1.1 edited your pad= line: undo it, but only if it's still what they wrote
TUNER_PY="$HERE/tuner/tuner.py"; [ -f "$TUNER_PY" ] || TUNER_PY="$DEST/tuner/tuner.py"
if [ -s "$CONF/foot-pad.orig" ] && [ -f "$TUNER_PY" ]; then
    python3 "$TUNER_PY" --legacy-foot || true
fi

# ---------------------------------------------------------------- files
# Removed only if they are still exactly what we installed or generated
# (listed with their sha256 in $MANIFEST / $GENERATED). Anything you changed or
# added is kept and listed at the end.
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
else
    for f in "$DESKTOP" "$HOOK" "$FONT_HOOK"; do remove_if_ours "$f" "$MANIFEST"; done   # no record: keep and list
fi
remove_if_ours "$HYPR/liquid_glass.lua" "$GENERATED"
for f in "$HYPR"/liquid_glass.lua.bak-*; do [ -e "$f" ] && KEPT+=("$f (your hand-edited version, saved by Glass Tuner)"); done

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

# pinned plugin source: removed only if git shows exactly the recorded commit,
# with nothing modified, added or stashed and no other branches or refs
src="$DEST/hyprglass-src"
if [ -d "$src" ]; then
    if [ -s "$CONF/plugin-rev" ] \
       && [ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" = "$(cat "$CONF/plugin-rev")" ] \
       && [ -z "$(git -C "$src" status --porcelain --ignored 2>/dev/null || echo dirty)" ] \
       && [ "$(git -C "$src" for-each-ref --format='%(refname)' 2>/dev/null || true)" = "refs/heads/main" ]; then
        rm -rf "$src"
    else
        KEPT+=("$src")
    fi
fi
# folders we created go only if nothing else is left in them
if [ -d "$DEST" ]; then
    find "$DEST" -depth -type d -empty -delete || true
    [ -d "$DEST" ] && KEPT+=("$DEST/ (has files Liquid Glass didn't install)")
fi
# Glass Tuner's browser profile: Chromium's own files, so we can't checksum them.
# Ask before deleting it; without a terminal, keep it and say where it is.
if [ -d "$CACHE/tuner-browser" ]; then
    a=""
    [ -t 0 ] && read -rp "Delete Glass Tuner's browser profile ($CACHE/tuner-browser)? [y/N] " a
    if [[ $a == [yY]* ]]; then rm -rf "$CACHE/tuner-browser"; else KEPT+=("$CACHE/tuner-browser (Glass Tuner's browser profile; safe to delete)"); fi
fi
[ -d "$CACHE" ] && rmdir "$CACHE" 2>/dev/null || true
[ -d "$CACHE" ] && [ ! -d "$CACHE/tuner-browser" ] && KEPT+=("$CACHE/ (has files Liquid Glass didn't create)")
[ -d "$HOME/.cache/glass-tuner" ] && KEPT+=("$HOME/.cache/glass-tuner (browser profile from versions before 1.3; safe to delete)")

# ---------------------------------------------------------------- plugin
say "removing the plugin"
# Only the build Liquid Glass installed: our ownership record plus hyprpm saying it
# was built from our pinned local copy. Any other hyprglass install is left alone.
st="$HYPRPM_DIR/HyprGlassLiquid/state.toml"
url=""
[ -f "$st" ] && url=$(sed -n "s/^url = '\(.*\)'$/\1/p" "$st" 2>/dev/null || true)
if [ -f "$st" ] && [ -z "${LG_SKIP_PLUGIN:-}" ] && [ "$(cat "$CONF/hyprpm-repo" 2>/dev/null || true)" = HyprGlassLiquid ] \
   && [ "$url" = "$DEST/hyprglass-src" ]; then
    hyprpm remove HyprGlassLiquid || say "hyprpm couldn't remove HyprGlassLiquid; run: hyprpm remove HyprGlassLiquid"
elif [ -f "$st" ]; then
    say "left hyprpm's HyprGlassLiquid alone: Liquid Glass didn't install it (source: ${url:-unknown})."
    say "if you want it gone too: hyprpm remove HyprGlassLiquid"
fi
rm -f "$CONF/hyprpm-repo" "$MANIFEST" "$GENERATED" "$CONF/plugin-rev"   # bookkeeping for the steps above
[ -s "$CONF/blocks.sha256" ] || rm -f "$CONF/blocks.sha256"                  # still lists any block you kept

if [ ${#KEPT[@]} -gt 0 ]; then
    say "kept these because they aren't exactly what Liquid Glass installed (changed, added, or from an older version):"
    printf '    %s\n' "${KEPT[@]}"
fi

# --purge: your saved settings go; the backups of your own files never do
if [ -n "$PURGE" ] && [ -d "$CONF" ]; then
    rm -rf "$CONF/state.json" "$CONF/looks.json" "$CONF/themes" "$CONF/.theme-look-active" "$CONF/.lock" "$CONF/foot-pad.orig"
    say "removed your saved settings"
fi
hyprctl reload >/dev/null 2>&1 || true
if compgen -G "$CONF/backup-*" >/dev/null; then
    say "done. Copies of your files from before each install are in $CONF/backup-*/ (delete that folder when you don't need them)."
else
    say "done."
fi
