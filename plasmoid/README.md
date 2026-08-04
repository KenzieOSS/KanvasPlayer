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

- `contents/ui/AlbumArtStackView.qml` - logic unmodified from upstream
  (two typed-function-return annotations stripped for older-Qt
  compatibility, see note below), still drives the blurred background
  and text-color logic in the expanded view.
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

A pin button in the expanded view toggles `PlasmoidItem.hideOnWindowDeactivate`
(a real Plasma property, default `true`) so the expanded popup stays open
when you click into another window instead of auto-closing - handy for
actually watching a canvas play rather than it vanishing the instant you
alt-tab away. Resets to off each time the popup is reopened; not
persisted across sessions.

### Compact mode

Right-click the widget → *Configure KanvasPlayer* → *Appearance* has a
"Compact mode" toggle. Off (default) is the current side-by-side layout
unchanged. On, `AlbumArtStackView`/`CanvasVideoView` span the full width
instead of just the left half, and the track title/artist/album
(`detailsColumn` in `ExpandedRepresentation.qml`) becomes an overlay
anchored to the bottom-left instead of its own right-hand column, with a
dark gradient scrim (`compactModeScrim`) behind it for legibility over
busy video/art.

Standard KConfigXT setup, same pattern as most Plasma widgets (verified
against [Kurve](https://github.com/luisbocanegra/kurve)'s config system
before building this):
- `contents/config/main.xml` - schema, one `compactMode` Bool entry
- `contents/config/config.qml` - registers the config page
- `contents/ui/configGeneral.qml` - the actual checkbox UI, using the
  `cfg_<name>` property-alias convention Plasma auto-binds to the schema

Deliberately scoped to just the album-art/details-column area for now -
the seek bar and playback controls stay in Plasma's own footer chrome
below, not overlaid on the video. Moving those on top too would mean
pulling them out of `PlasmaExtras.PlasmoidHeading`'s footer entirely,
which is a bigger structural change worth doing carefully/incrementally
rather than in the same pass as introducing the config system itself.

## Troubleshooting

**Widget shows "Type X unavailable" errors, or QML syntax errors, after
pulling a fix.** `kpackagetool6 -t Plasma/Applet -u` doesn't always
reliably sync every file - if you've pulled a fix and it doesn't seem to
have taken effect, verify what's actually installed matches what's in
the repo before assuming the fix didn't work:

```sh
diff plasmoid/contents/ui/AlbumArtStackView.qml \
     ~/.local/share/plasma/plasmoids/io.github.KenzieOSS.kanvasplayer/contents/ui/AlbumArtStackView.qml
```

Any output means the installed copy is stale. Force a clean reinstall
rather than trusting `-u`:

```sh
kpackagetool6 -t Plasma/Applet -r io.github.KenzieOSS.kanvasplayer
kpackagetool6 -t Plasma/Applet -i plasmoid
rm -rf ~/.cache/org.kde.plasmashell/qmlcache ~/.cache/QtProject
kquitapp6 plasmashell && kstart plasmashell
```

The qmlcache clear matters too - Qt caches compiled QML bytecode keyed
by file path, and it doesn't always reliably invalidate just because the
underlying KPackage was reinstalled.

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
- Typed function-return/parameter annotations (e.g. `function foo(): void`)
  were stripped from every shipped QML file (both upstream KDE code and
  our own additions) - some Qt6 QML engine versions/contexts reject this
  syntax outright with "Type annotations are not permitted for the
  return value of JavaScript functions", which is a hard parse error
  that cascades upward and breaks the whole widget. Purely a
  compile-time hint either way, functionally identical without it.
