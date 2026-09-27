# Liquid Glass for Omarchy

Apple-style Liquid Glass for your terminal on [Omarchy](https://omarchy.org): thick glass edges that bend what's behind them, light that follows your cursor, parallax tilt, a slow oil-film shimmer, and windows that bend into existence, all tunable live with sliders.

![Liquid Glass on Omarchy](assets/demo.gif)

[Watch the 20-second demo (MP4)](assets/demo.mp4)

## What you get

- **Glass terminals**: foot gets a see-through background, and the glass plugin turns what's behind it into frosted, refracting glass with a thick, curved rim.
- **Light that follows you**: a light source over your desktop lights each window's rim where it faces it. Move a window or your pointer and the highlight slides round the rim.
- **Parallax tilt**: the view behind the glass shifts as your cursor moves, like tilting thick glass.
- **Oil film**: slow iridescent swirls on the glass, like oil on water.
- **Click glow** and **materialize**: clicks energize the glass; new windows bend into existence.
- **Glass Tuner**: a small app with live sliders for all of it, named looks you can save and switch, and terminal text settings that follow your Omarchy theme.

It's built on [**HyprGlass**](https://github.com/hyprnux/hyprglass) by hyprnux, through the [**HyprGlass Liquid**](https://github.com/fasi96/hyprglass) fork that adds the motion.

## Requirements

- Dependencies: `hyprpm` (ships with Hyprland), `base-devel cmake meson cpio pkgconf git` (installed for you), `python3`, `jq`, `chromium` for the tuner window, `foot`.
- Omarchy with **Hyprland 0.56.2**. That's the tested version; others may not build yet.
- **foot** as your terminal (Omarchy's default). The glass shows through see-through windows, and Glass Tuner's terminal settings are for foot.
- A few minutes for `hyprpm` to build the plugin the first time. It asks for your password to install build tools and Hyprland headers.

## Install

**As an Omarchy plugin** (adds a glass button to your bar):

```bash
omarchy plugin add https://github.com/fasi96/omarchy-liquid-glass --enable
```

Click the new glass button on the bar. The first click opens a terminal that shows what Liquid Glass will change and asks before doing anything. After setup, the button opens Glass Tuner, and a right click turns the glass on and off. If a Hyprland update ever unloads the glass plugin, the button shows `!` and one click rebuilds it.

**Or with the script:**

```bash
git clone https://github.com/fasi96/omarchy-liquid-glass
cd omarchy-liquid-glass
./install.sh
```

Either way, open a **new terminal** afterwards, and press **Super+Ctrl+G** for Glass Tuner (or search "Glass Tuner" in the launcher).

Setup lists everything it will do and asks first; without a terminal to ask in it changes nothing unless you pass `--yes`. It builds the plugin with `hyprpm`, so it may install missing build tools (`base-devel cmake meson cpio pkgconf git`, shown in the list) and fetch Hyprland headers, which asks for your password and takes a few minutes the first time. Everything it adds to your config is fenced with `omarchy-liquid-glass` markers. Before it starts, it copies hyprland.lua, bindings.lua, autostart.lua and foot.ini, plus anything already sitting at a path it installs to, into `~/.config/omarchy-liquid-glass/backup-<time>/`. If you already have upstream HyprGlass in hyprpm, setup asks before replacing it (both provide the same plugin), and puts it back if the new build fails.

## Glass Tuner

| Section | What it's for |
|---|---|
| Thick glass rim | How wide and how strongly the glass edge bends, rainbow fringe, edge glow, top highlight |
| Glass body, Blur, Tone, Colour | Lens dome, blur, brightness and contrast, saturation, tint |
| Text | Brightens your theme's own text colour (still follows theme changes), font weight, bold-in-bright |
| Window look | Terminal transparency, padding, corner rounding, gaps, shadows |
| Outer line | A thin lit lip around windows (or the neon gradient) |
| Actions | Light follows you, Parallax tilt, Oil film, Click glow, Materialize, Drift. Each has its own on/off switch |

Changes show live; nothing sticks until you press **Save**. Use **Hold to compare** to see the glass off, **Open test window** to try it on a floating terminal, and **Saved looks** to keep several setups. The shipped look is saved as "Liquid Glass".

## Uninstall

```bash
~/.local/share/omarchy-liquid-glass/uninstall.sh            # removes what it added; keeps your saved looks
~/.local/share/omarchy-liquid-glass/uninstall.sh --purge    # also removes your saved looks and settings
```

Setup keeps a copy of `uninstall.sh` there, so it works however you installed. It removes only what is still exactly as Liquid Glass installed it, and lists anything you changed or added instead of deleting it. The backups of your own files in `~/.config/omarchy-liquid-glass/backup-*/` are never deleted, not even by `--purge`; remove that folder yourself when you don't need them.

Installed as a plugin? Run the uninstall first, then remove the bar button:

```bash
~/.local/share/omarchy-liquid-glass/uninstall.sh
omarchy plugin remove io.github.fasi96.liquid-glass
```

## After a Hyprland update

Hyprland plugins are compiled for one Hyprland version, so after an update the glass switches off until it's rebuilt. The bar button shows `!`; click it, or run `./install.sh --plugin-only`. Nothing else breaks meanwhile.

## What gets built, and what gets changed

- **The native plugin is pinned.** The installer fetches one reviewed commit of [HyprGlass Liquid](https://github.com/fasi96/hyprglass) (`HYPRGLASS_REV` in `install.sh`) into `~/.local/share/omarchy-liquid-glass/hyprglass-src`, checks the commit hash, and has `hyprpm` build that exact commit from the local copy. Newer commits on GitHub are never built until the pin is bumped in a new release.
- **Other HyprGlass installs are yours.** Only one `hyprglass` plugin can be loaded at a time. Setup replaces only the build Liquid Glass itself installed (it keeps a record, and checks that hyprpm built it from the pinned local copy). If you have upstream HyprGlass or your own copy of the fork in hyprpm, setup shows where it came from and asks before removing it; without a terminal to ask in, it stops and changes nothing (`--replace-hyprglass` answers yes). Uninstall only removes Liquid Glass's own build.
- **Glass Tuner only listens to itself.** Its local page (127.0.0.1) needs a random per-run token that only the tuner window gets (handed over through a private launch file, never on a command line where other users could see it), checks the Host and Origin, and every value is range-checked before it reaches the generated config.
- **Uninstall only deletes what it installed.** The installer records a sha256 of every file it installs (Glass Tuner, the desktop entry, the hooks), and Glass Tuner records one each time it writes `liquid_glass.lua`. `./uninstall.sh` removes a file only if it still matches; anything you changed or added is kept and listed. The pinned plugin source is removed only if git shows it is still exactly the pinned commit. If one of these paths already held something else at install time, the installer keeps a copy in its backup folder first.
- **Other hyprpm plugins are left alone.** `hyprpm update` (needed only when hyprpm's headers don't match your Hyprland) also updates every other hyprpm plugin, so setup skips it when the headers are current, and otherwise names your other plugins and asks first (`--hyprpm-update` answers yes).
- **Blocks you edit stay yours.** Every fenced block Liquid Glass writes (in hyprland.lua, autostart.lua, bindings.lua and foot.ini) is recorded by sha256. Uninstall removes a block only if it is still exactly what Liquid Glass wrote; if you changed it, it stays and is listed. Rewriting a block you changed (reinstall, or a Glass Tuner save) keeps a copy of your version in the backup folder first. Glass Tuner's browser profile in `~/.cache/omarchy-liquid-glass` is only deleted if you say yes.
- **Your foot config is only ever appended to.** Everything Glass Tuner sets (transparency, padding, text colour, font weight, bold-in-bright) lives in one fenced `omarchy-liquid-glass` block at the end of `foot.ini`; foot lets later values win, so your own lines are never edited. The Hyprland files get fenced blocks the same way. `./uninstall.sh` removes exactly those blocks.

## Credits

- [HyprGlass](https://github.com/hyprnux/hyprglass) by hyprnux (BSD-3-Clause): the Liquid Glass shader and plugin this is built on.
- Motion design follows Apple's [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/) (WWDC25): light and movement come from what you do.

This package (installer + Glass Tuner) is MIT-licensed. The plugin keeps HyprGlass's BSD-3-Clause license.
