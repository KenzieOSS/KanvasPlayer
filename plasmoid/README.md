# KanvasPlayer (widget)

A fork of Plasma's `org.kde.plasma.mediacontroller` applet that shows the
Spotify Canvas video (fetched by [kanvasd](../kanvasd)) in the expanded
view instead of static album art, for tracks that have one. Falls back to
the normal album art automatically for tracks without a Canvas.

This is a plain KPackage plasmoid (metadata.json + QML, no compilation
needed) - install and manage it like any widget from the KDE Store.

## Install

The fast way is [`../install.sh`](../install.sh) from the repo root,
which installs this alongside the `kanvasd` backend. To install just the
widget on its own:

```sh
kpackagetool6 -t Plasma/Applet -i .
```

To pick up changes after editing, upgrade in place instead of reinstalling:

```sh
kpackagetool6 -t Plasma/Applet -u .
```

Then restart Plasma so it notices the new widget:

```sh
kquitapp6 plasmashell && kstart plasmashell
```

Add it via right-click panel → *Add Widgets* → search "KanvasPlayer".

## How it works

- `contents/ui/AlbumArtStackView.qml` - unmodified from upstream, still
  drives the blurred background and text-color logic in the expanded view.
- `contents/ui/CanvasVideoView.qml` - new. Plays
  `~/.cache/kanvasd/current.mp4` via `QtMultimedia`, and reports whether a
  playable video is currently loaded (`hasVideo`).
- `contents/ui/ExpandedRepresentation.qml` - modified. Layers
  `CanvasVideoView` directly on top of `AlbumArtStackView` with
  `visible: hasVideo`, so it's just album art underneath whenever there's
  no canvas.

`CanvasVideoView` polls (every second) rather than relying purely on
filesystem watch events, since a same-filename replace of `current.mp4`
isn't guaranteed to surface as a clean add/remove event through
`FolderListModel`.

## Notes

- **Applet id**: `io.github.KenzieOSS.kanvasplayer`, referenced in
  `metadata.json` and the source comments. `org.kde.*` is reserved for
  KDE's own packages.
- **`X-Plasma-Provides: org.kde.plasma.multimediacontrols`** in
  `metadata.json` lets this serve as *the* system tray media control. If
  you keep the stock Media Player widget installed too, Plasma will let
  you pick between them in system tray settings rather than silently
  overriding.
- Requires `kanvasd` running separately - this widget only ever reads
  `~/.cache/kanvasd/current.mp4`; it has no idea how it got there.
- Video playback needs Qt6Multimedia with a working codec stack
  (H.264/AAC). If it's missing, `hasVideo` in `CanvasVideoView.qml` just
  silently never becomes true and you'll always see album art instead -
  no error surfaces to the widget itself. `install.sh` checks for
  Qt6Multimedia and warns if it looks absent, but can't install
  distro-specific codec packages for you (e.g. Fedora needs RPM Fusion +
  `fedora-cisco-openh264` enabled for H.264).
