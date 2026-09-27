import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Liquid Glass on the Omarchy bar.
//
//   not set up yet     click runs the installer in a terminal (it asks first)
//   glass plugin gone  (e.g. after a Hyprland update) click rebuilds it with hyprpm
//   ready              click opens Glass Tuner, right click turns the glass on/off
//
// The installer lives next to this file: omarchy plugin add clones the whole
// omarchy-liquid-glass repo into ~/.config/omarchy/plugins/<id>.
BarWidget {
  id: root
  moduleName: "io.github.fasi96.liquid-glass"

  readonly property string home: Quickshell.env("HOME")
  // the plugin folder (Qt gives a percent-encoded file:// URL)
  readonly property string repoDir: decodeURIComponent(String(Qt.resolvedUrl("..")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string tuner: home + "/.local/share/omarchy-liquid-glass/tuner/tuner.py"

  property bool installed: false
  property bool pluginLoaded: true
  property bool glassOn: true

  readonly property string mode: !installed ? "setup" : (!pluginLoaded ? "rebuild" : "ready")

  // installed = the installer has put Glass Tuner in place
  FileView {
    path: root.tuner
    watchChanges: true
    printErrors: false
    onLoaded: root.installed = true
    onLoadFailed: root.installed = false
    onFileChanged: reload()
  }

  // glass on/off, as saved by the tuner
  FileView {
    path: root.home + "/.config/omarchy-liquid-glass/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.glassOn = JSON.parse(text()).glass_on !== false } catch (e) {}
    }
  }

  // is the HyprGlass Liquid plugin loaded right now?
  Process {
    id: probe
    command: ["hyprctl", "getoption", "plugin:hyprglass:light_strength"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pluginLoaded = text.length > 0 && text.indexOf("no such option") < 0
    }
  }
  Timer {
    interval: 30000
    repeat: true
    running: root.installed
    triggeredOnStart: true
    onTriggered: probe.running = true
  }

  function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }   // shell-quote

  function terminal(cmd) {
    Util.execArgv(["omarchy-launch-floating-terminal-with-presentation", cmd])
  }

  function clicked(b) {
    if (mode === "setup") {
      terminal("cd " + q(repoDir) + " && ./install.sh")
    } else if (mode === "rebuild") {
      terminal("cd " + q(repoDir) + " && ./install.sh --plugin-only && hyprctl reload")
    } else if (b === Qt.RightButton) {
      Util.execArgv(["python3", tuner, "--toggle"])
    } else {
      Util.execArgv(["python3", tuner])
    }
  }

  readonly property string tooltip: {
    if (mode === "setup") return "Liquid Glass: click to set up (shows what it changes and asks first)"
    if (mode === "rebuild") return "Liquid Glass: the glass plugin isn't loaded (Hyprland updated?). Click to rebuild it"
    return "Liquid Glass: click for Glass Tuner, right click to turn the glass " + (glassOn ? "off" : "on")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.fasi96.liquid-glass"
    function openTuner(): void { root.clicked(Qt.LeftButton) }
    function toggle(): void { if (root.mode === "ready") root.clicked(Qt.RightButton) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.mode === "rebuild" ? String.fromCodePoint(0xF00B5) + " !" : String.fromCodePoint(0xF00B5)
    active: root.mode === "ready" && root.glassOn
    opacity: root.mode === "setup" ? 0.55 : 1.0
    tooltipText: root.tooltip
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(b) { root.clicked(b) }
  }
}
