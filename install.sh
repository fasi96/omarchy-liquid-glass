#!/usr/bin/env bash
# Liquid Glass for Omarchy — installer.
#
#   git clone https://github.com/fasi96/omarchy-liquid-glass
#   cd omarchy-liquid-glass && ./install.sh
#
# What it does (everything it adds to your config is fenced with
# "omarchy-liquid-glass" markers, and ./uninstall.sh removes exactly that):
#   1. builds the HyprGlass Liquid plugin with hyprpm from one pinned, verified commit
#   2. installs Glass Tuner to ~/.local/share/omarchy-liquid-glass (Super+Ctrl+G, or the app launcher)
#   3. writes ~/.config/hypr/liquid_glass.lua (generated), then adds a require, a login line
#      that loads hyprpm plugins, and the Super+Ctrl+G binding as fenced blocks
#   4. adds a fenced block to foot.ini (see-through background so the glass shows)
#   5. installs theme-set and font-set hooks so terminal text keeps following your theme
# It shows all of this and asks before changing anything. Copies of the files it
# edits go to ~/.config/omarchy-liquid-glass/backup-<time>/.
#
# Flags: --yes (no prompt), --plugin-only (rebuild the plugin), --replace-hyprglass,
#        --hyprpm-update (answer yes to those two questions without a terminal)

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.local/share/omarchy-liquid-glass"
CONF="$HOME/.config/omarchy-liquid-glass"
HYPR="$HOME/.config/hypr"
FOOT="$HOME/.config/foot/foot.ini"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/omarchy-liquid-glass"
FONT_HOOK="$HOME/.config/omarchy/hooks/font-set.d/omarchy-liquid-glass"
DESKTOP="$HOME/.local/share/applications/omarchy-liquid-glass-tuner.desktop"
MANIFEST="$CONF/installed.sha256"   # "sha256  path" of every file we install; uninstall.sh only removes exact matches
HYPRPM_DIR="${HYPRPM_CACHE:-/var/cache/hyprpm/$USER}"
PLUGIN_REPO="https://github.com/fasi96/hyprglass"
HYPRGLASS_REV="2ef828b66553a7cf763d3f01350f669fd3232ecb"   # reviewed plugin commit; bump deliberately
PLUGIN_SRC="$DEST/hyprglass-src"
BUILD_PKGS=(base-devel cmake meson cpio pkgconf git)
TESTED_HYPRLAND="0.56.2"
BEGIN="omarchy-liquid-glass >>>"
END="<<< omarchy-liquid-glass"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
ask()  {   # ask QUESTION: yes/no in a terminal; no terminal = no
    [ -t 0 ] || return 1
    if command -v gum >/dev/null; then gum confirm "$1"; else read -rp "$1 [y/N] " a; [[ $a == [yY]* ]]; fi
}

# add_block FILE COMMENT_PREFIX CONTENT: (re)write our fenced block at the end of FILE.
# lib/blocks.py records each block's sha256; if you changed the block, your version
# is saved to the backup folder first.
add_block() {
    local tmp; tmp=$(mktemp)
    printf '%s\n' "$3" > "$tmp"
    python3 "$SRC/lib/blocks.py" add "$1" "$2" "$tmp" "$BK"
    rm -f "$tmp"
}

# ours = the file is exactly what we installed last time (listed in the manifest)
ours() { [ -f "$MANIFEST" ] && grep -qxF "$(sha256sum "$1" | cut -d' ' -f1)  $1" "$MANIFEST"; }
# before writing a path we own: if something else is there, keep a copy of it (full path kept,
# so same-named files like the two hooks never overwrite each other's copy)
guard() {
    local f dest
    for f in "$@"; do
        [ -e "$f" ] || continue
        ours "$f" && continue
        dest="$BK/replaced$f"
        mkdir -p "$(dirname "$dest")"
        cp -a "$f" "$dest"
        warn "$f isn't in Liquid Glass's install record (or you changed it; versions before 1.2 kept no record); a copy is at $dest"
    done
}
# the pinned source is ours only if git shows exactly the recorded commit: nothing
# modified, added, stashed, and no other branches or refs
src_is_ours() {
    [ -s "$CONF/plugin-rev" ] || return 1
    [ "$(git -C "$1" rev-parse HEAD 2>/dev/null || true)" = "$(cat "$CONF/plugin-rev")" ] || return 1
    [ -z "$(git -C "$1" status --porcelain --ignored 2>/dev/null || echo dirty)" ] || return 1
    [ "$(git -C "$1" for-each-ref --format='%(refname)' 2>/dev/null || true)" = "refs/heads/main" ] || return 1
}
# a Lua string literal (for bindings.lua)
lua_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"; }

# ---------------------------------------------------------------- flags + checks
for arg in "$@"; do
    case "$arg" in
        --yes|-y) LG_YES=1 ;;
        --plugin-only) LG_PLUGIN_ONLY=1 ;;
        --replace-hyprglass) LG_REPLACE_HYPRGLASS=1 ;;
        --hyprpm-update) LG_YES_HYPRPM_UPDATE=1 ;;
        *) die "unknown option: $arg" ;;
    esac
done

for c in hyprctl hyprpm python3 jq git sha256sum; do
    command -v "$c" >/dev/null || die "missing: $c"
done
[ -n "${LG_PLUGIN_ONLY:-}" ] || for c in chromium foot; do command -v "$c" >/dev/null || die "missing: $c"; done
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || die "run this inside your Hyprland session"
[ -d "${OMARCHY_PATH:-/usr/share/omarchy}" ] || warn "Omarchy not found: the config hooks assume Omarchy's layout (~/.config/hypr/*.lua with the o helper)"

ver=$(hyprctl version -j | jq -r .tag | sed 's/^v//')
[ "$ver" = "$TESTED_HYPRLAND" ] || warn "Hyprland $ver: tested on $TESTED_HYPRLAND only; the plugin may not build on other versions"
if [ -z "${LG_PLUGIN_ONLY:-}" ]; then
    term=$(xdg-terminal-exec --print-id 2>/dev/null || true)
    case "$term" in *foot*) ;; *) warn "your default terminal is '${term:-unknown}': the glass shows through see-through windows, and Glass Tuner's terminal settings are for foot" ;; esac
fi

# build tools hyprpm needs that aren't installed yet
MISSING_PKGS=()
if [ -z "${LG_SKIP_PLUGIN:-}" ]; then
    mapfile -t MISSING_PKGS < <(pacman -T "${BUILD_PKGS[@]}" 2>/dev/null || true)
fi

# ---------------------------------------------------------------- consent
summary() {
    echo
    echo "Liquid Glass will:"
    [ ${#MISSING_PKGS[@]} -gt 0 ] && echo "  - install build tools with sudo: pacman -S --needed ${MISSING_PKGS[*]}"
    [ -z "${LG_SKIP_PLUGIN:-}" ] && echo "  - build HyprGlass Liquid ${HYPRGLASS_REV:0:12} with hyprpm and load it (hyprpm asks for your password at each step, so a few times)"
    if [ -z "${LG_PLUGIN_ONLY:-}" ]; then
        echo "  - write ~/.config/hypr/liquid_glass.lua, and add fenced blocks to hyprland.lua, autostart.lua and bindings.lua"
        echo "  - add a fenced block at the end of ~/.config/foot/foot.ini (your own lines are not edited)"
        echo "  - install Glass Tuner in ~/.local/share/omarchy-liquid-glass, its desktop entry, and theme-set/font-set hooks"
        echo "Copies of hyprland.lua, bindings.lua, autostart.lua and foot.ini, and of anything already at the paths"
        echo "above that Liquid Glass didn't install, go to ~/.config/omarchy-liquid-glass/backup-<time>/ first."
        echo "./uninstall.sh removes what it added and keeps anything you changed."
    fi
    echo
}
if [ -z "${LG_YES:-}" ]; then
    [ -t 0 ] || die "no terminal to ask in: nothing was changed. Run it in a terminal, or pass --yes"
    summary
    if [ -n "${LG_PLUGIN_ONLY:-}" ]; then ask "Rebuild the Liquid Glass plugin?" || { echo "nothing changed"; exit 0; }
    else ask "Set up Liquid Glass?" || { echo "nothing changed"; exit 0; }; fi
fi

# ---------------------------------------------------------------- backups
BK="$CONF/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p -m 700 "$BK"                       # backups hold copies of your config: private folder
for f in "$HYPR/hyprland.lua" "$HYPR/bindings.lua" "$HYPR/autostart.lua" "$FOOT"; do
    [ -f "$f" ] && cp -p "$f" "$BK/"          # keeps each file's own permissions
done
say "backups in $BK"

# ---------------------------------------------------------------- plugin
# The native plugin is built from ONE reviewed commit of the fork, never from a
# moving branch: fetch exactly that commit into a local repo that holds nothing
# newer, check its hash, and let hyprpm build from that local copy at that
# commit. `hyprpm update` can only ever pull from this pinned local repo.

# hyprpm repositories that provide a "hyprglass" plugin, one "name<TAB>url<TAB>rev" per line
state_val() { sed -n "s/^$1 = '\(.*\)'$/\1/p" "$2" 2>/dev/null || true; }
glass_repos() {
    local st rev
    for st in "$HYPRPM_DIR"/*/state.toml; do
        [ -f "$st" ] && grep -q '^\[hyprglass\]' "$st" || continue
        rev=$(state_val rev "$st"); [ -n "$rev" ] || rev=$(state_val hash "$st")
        printf '%s\t%s\t%s\n' "$(state_val name "$st")" "$(state_val url "$st")" "$rev"
    done
}

# Ours = recorded when we installed it AND hyprpm says it was built from our pinned local copy.
owns_repo() { [ "$1" = HyprGlassLiquid ] && [ "$2" = "$PLUGIN_SRC" ] && [ "$(cat "$CONF/hyprpm-repo" 2>/dev/null || true)" = "$1" ]; }

# Only one "hyprglass" plugin can be loaded. Our own earlier build is replaced
# silently; anything else was installed outside Liquid Glass, so ask first and
# leave it alone unless the user says yes (or passes --replace-hyprglass).
# Decides up front (before anything changes); the removal happens later.
REMOVE_REPOS=()     # "name<TAB>url<TAB>rev", so a failed build can put them back
decide_glass_repos() {
    local name url rev
    while IFS=$'\t' read -r name url rev; do
        [ -n "$name" ] || continue
        if owns_repo "$name" "$url"; then
            say "replacing Liquid Glass's earlier build ($name)"
        else
            warn "hyprpm has '$name' installed from ${url:-an unknown source}, which Liquid Glass did not install."
            warn "It provides the same 'hyprglass' plugin, so only one of them can be loaded."
            if [ -z "${LG_REPLACE_HYPRGLASS:-}" ]; then
                [ -t 0 ] || die "'$name' is installed outside Liquid Glass; run in a terminal, or pass --replace-hyprglass to replace it"
                ask "Remove '$name' from hyprpm so Liquid Glass can install its build? (it's put back if the build fails)" \
                    || die "left '$name' untouched; nothing was changed in hyprpm"
            fi
        fi
        REMOVE_REPOS+=("$name"$'\t'"$url"$'\t'"$rev")
    done < <(glass_repos)
}

# hyprpm needs headers for the running Hyprland. They are fetched with
# `hyprpm update`, which also updates every other hyprpm plugin, so run it only
# when the headers are out of date, and ask first if other plugins are installed.
NEED_HEADERS=""
decide_headers() {
    local running have others st name r skip
    running=$(hyprctl version -j | jq -r .commit)
    have=$(sed -n "s/^hash = '\([0-9a-f]*\).*/\1/p" "$HYPRPM_DIR/state.toml" 2>/dev/null || true)
    if [ -n "$running" ] && [ "$have" = "$running" ]; then say "hyprpm headers already match this Hyprland"; return; fi
    NEED_HEADERS=1
    others=""
    for st in "$HYPRPM_DIR"/*/state.toml; do
        [ -f "$st" ] || continue
        name=$(state_val name "$st"); skip=""
        for r in "${REMOVE_REPOS[@]}"; do [ "${r%%$'\t'*}" = "$name" ] && skip=1; done
        [ -n "$skip" ] || others+="$name "
    done
    [ -z "$others" ] && return
    warn "hyprpm needs headers for this Hyprland; fetching them runs 'hyprpm update', which also updates your other hyprpm plugins: $others"
    [ -n "${LG_YES_HYPRPM_UPDATE:-}" ] && return
    [ -t 0 ] || die "hyprpm headers are out of date and 'hyprpm update' would update your other plugins; run in a terminal, or pass --hyprpm-update"
    ask "Run 'hyprpm update' now?" || die "hyprpm left as it was; nothing changed"
}

# a failed update/build must not leave you with no glass plugin: put back what we removed
restore_removed() {
    local entry name url rev
    for entry in "${REMOVE_REPOS[@]}"; do
        IFS=$'\t' read -r name url rev <<<"$entry"
        owns_repo "$name" "$url" && continue          # our own old build: nothing to restore
        warn "putting back '$name' ($url${rev:+ @ ${rev:0:12}})"
        if hyprpm add "$url" ${rev:+"$rev"} && hyprpm enable hyprglass; then hyprpm reload -n || true
        else warn "could not re-add it; run: hyprpm add $url${rev:+ $rev} && hyprpm enable hyprglass"; fi
    done
}

plugin_step() {
    # decide about other hyprglass installs before touching anything
    decide_glass_repos
    decide_headers

    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        say "installing build tools: ${MISSING_PKGS[*]} (sudo)"
        if [ -t 0 ]; then sudo pacman -S --needed "${MISSING_PKGS[@]}"
        else sudo pacman -S --needed --noconfirm "${MISSING_PKGS[@]}"; fi   # --yes: you agreed to the list above
    fi

    say "fetching HyprGlass Liquid at the pinned commit ${HYPRGLASS_REV:0:12}"
    if [ -e "$PLUGIN_SRC" ]; then
        if src_is_ours "$PLUGIN_SRC"; then
            rm -rf "$PLUGIN_SRC"
        else
            mkdir -p "$(dirname "$BK/replaced$PLUGIN_SRC")"; mv "$PLUGIN_SRC" "$BK/replaced$PLUGIN_SRC"
            warn "$PLUGIN_SRC wasn't Liquid Glass's untouched copy; moved it to $BK/replaced$PLUGIN_SRC"
        fi
    fi
    mkdir -p "$PLUGIN_SRC"
    git -C "$PLUGIN_SRC" init -q -b main
    git -C "$PLUGIN_SRC" remote add origin "$PLUGIN_REPO"
    git -C "$PLUGIN_SRC" fetch -q origin "$HYPRGLASS_REV" || die "could not fetch commit $HYPRGLASS_REV from $PLUGIN_REPO"
    git -C "$PLUGIN_SRC" checkout -q -B main FETCH_HEAD
    git -C "$PLUGIN_SRC" remote remove origin
    [ "$(git -C "$PLUGIN_SRC" rev-parse HEAD)" = "$HYPRGLASS_REV" ] || die "fetched source is not commit $HYPRGLASS_REV"
    git -C "$PLUGIN_SRC" fsck --no-progress --no-dangling >/dev/null || die "fetched source failed git fsck"
    echo "$HYPRGLASS_REV" > "$CONF/plugin-rev"      # the source is ours only while it is still exactly this

    local entry
    for entry in "${REMOVE_REPOS[@]}"; do say "hyprpm: removing ${entry%%$'\t'*}"; hyprpm remove "${entry%%$'\t'*}"; done

    if [ -n "$NEED_HEADERS" ]; then
        say "hyprpm: fetching Hyprland headers (can take a few minutes)"
        hyprpm update || { restore_removed; die "hyprpm update failed"; }
    fi

    say "hyprpm: building HyprGlass Liquid ${HYPRGLASS_REV:0:12}"
    hyprpm add "$PLUGIN_SRC" "$HYPRGLASS_REV" || { restore_removed; die "building HyprGlass Liquid failed"; }
    echo HyprGlassLiquid > "$CONF/hyprpm-repo"      # ownership record, checked by owns_repo / uninstall.sh
    hyprpm enable hyprglass
    hyprpm reload -n
}

if [ -n "${LG_SKIP_PLUGIN:-}" ]; then say "LG_SKIP_PLUGIN set: skipping the plugin step (testing)"; else
    plugin_step
fi
[ -n "${LG_PLUGIN_ONLY:-}" ] && { say "plugin rebuilt"; exit 0; }

# ---------------------------------------------------------------- files
say "installing Glass Tuner"
mkdir -p "$DEST/tuner" "$DEST/lib" "$CONF"
TUNER_FILES=(tuner/tuner.py tuner/tuner.html lib/blocks.py defaults.json uninstall.sh)
for f in "${TUNER_FILES[@]}"; do guard "$DEST/$f"; install -m "$( [ "$f" = uninstall.sh ] && echo 755 || echo 644 )" "$SRC/$f" "$DEST/$f"; done
[ -f "$CONF/state.json" ] || cp "$SRC/defaults.json" "$CONF/state.json"
[ -f "$CONF/looks.json" ] || cp "$SRC/looks-default.json" "$CONF/looks.json"

mkdir -p "$(dirname "$DESKTOP")"
guard "$DESKTOP"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Name=Glass Tuner
Comment=Live sliders for Liquid Glass and the window look
Keywords=glass;liquid;blur;transparency;refraction;look;appearance;window;
Exec=python3 "$(printf '%s' "$DEST/tuner/tuner.py" | sed 's/[\\"`$]/\\\\&/g')"
Icon=preferences-desktop-theme
Type=Application
Categories=Settings;
EOF

# ---------------------------------------------------------------- foot
# Glass Tuner keeps everything it sets in foot.ini inside one fenced block at
# the end (later values win in foot); your own lines are never edited.
if [ -f "$FOOT" ] || command -v foot >/dev/null; then
    mkdir -p "$(dirname "$FOOT")"; touch "$FOOT"
    python3 "$SRC/tuner/tuner.py" --legacy-foot       # versions before 1.1 edited your pad= line: undo it if unchanged
fi

# ---------------------------------------------------------------- look
# liquid_glass.lua is written before anything requires it, so a failure here
# never leaves hyprland.lua pointing at a missing file
say "applying the Liquid Glass look"
[ -f "$CONF/generated.sha256" ] || guard "$HYPR/liquid_glass.lua"   # someone else's file at our path: keep a copy
python3 "$DEST/tuner/tuner.py" --save

# ---------------------------------------------------------------- hypr config
say "hooking into ~/.config/hypr"
add_block "$HYPR/hyprland.lua" "--" '-- Liquid Glass: glass on terminals + the window look (generated by Glass Tuner)
require("hypr.liquid_glass")'
add_block "$HYPR/autostart.lua" "--" '-- load hyprpm plugins (HyprGlass Liquid), then re-read the config so liquid_glass.lua sees it
o.launch_on_start("sh -c '"'"'hyprpm reload -n; hyprctl reload'"'"'")'
add_block "$HYPR/bindings.lua" "--" "o.bind(\"SUPER + CTRL + G\", \"Glass Tuner\", $(lua_str "python3 $(printf '%q' "$DEST/tuner/tuner.py")"))"

# ---------------------------------------------------------------- hooks
mkdir -p "$(dirname "$HOOK")" "$(dirname "$FONT_HOOK")"
guard "$HOOK" "$FONT_HOOK"
tuner_q=$(printf '%q' "$DEST/tuner/tuner.py")
printf '#!/bin/bash\n# omarchy-liquid-glass: keep terminal text following the new theme\n[ -f %s ] || exit 0\nexec python3 %s --theme-hook\n' "$tuner_q" "$tuner_q" > "$HOOK"
printf '#!/bin/bash\n# omarchy-liquid-glass: Omarchy rewrites every font= line on a font change; re-apply the glass font weight\n[ -f %s ] || exit 0\nexec python3 %s --foot-sync\n' "$tuner_q" "$tuner_q" > "$FONT_HOOK"
chmod +x "$HOOK" "$FONT_HOOK"

# record exactly what we installed, so uninstall.sh removes nothing else
{ for f in "${TUNER_FILES[@]}"; do echo "$DEST/$f"; done; echo "$DESKTOP"; echo "$HOOK"; echo "$FONT_HOOK"; } \
    | while IFS= read -r f; do [ -f "$f" ] && sha256sum "$f"; done > "$MANIFEST"

errs=$(hyprctl configerrors || true)
[ -z "$errs" ] || warn "Hyprland reports config errors:
$errs"

say "done. Open Glass Tuner with Super+Ctrl+G (or search \"Glass Tuner\")."
say "open a new terminal to see the glass."
say "to remove it: $DEST/uninstall.sh  (run it before 'omarchy plugin remove')"
