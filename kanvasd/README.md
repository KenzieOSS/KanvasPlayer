# kanvasd

Background daemon that watches Spotify (via MPRIS) and fetches the
Canvas video for whatever track is currently playing, for the
[KanvasPlayer](../plasmoid) Plasma widget to display.

## Components

- **`kanvasd.py`** - the daemon. Listens for MPRIS track changes,
  manages a cached Spotify Bearer token, and shells out to the fetcher
  below for each new track. Writes the result to
  `~/.cache/kanvasd/current.mp4` (or removes it, if the track has no
  Canvas) for the widget to pick up.
- **`spotify_token_extractor.py`** - pulls a fresh Bearer token out of
  Spotify's own desktop client via the Chrome DevTools Protocol. Spotify's
  Linux client is CEF/Electron-based, so it supports the same
  `--remote-debugging-port` flag as Chrome.
- **`mrn4txt.ts`** (by [yaaaarn](https://github.com/yaaaarn)) - given a
  track ID and a token, resolves and downloads the actual Canvas video
  (handles both direct-URL and segmented-stream delivery). Runs under
  [Bun](https://bun.sh).
- **`kanvasd.service`** - a `systemd --user` unit for autostart.

## Setup

The fast way is [`../install.sh`](../install.sh) from the repo root - it
does everything below automatically (venv, deps, Bun, the systemd
service, and offers to patch Spotify's launcher for you). What follows
is the manual version, if you'd rather do it by hand or just want to see
what the installer is actually doing.

**1. Launch Spotify with remote debugging enabled**

Fully quit Spotify first, then:

```sh
spotify --remote-debugging-port=9222 --remote-allow-origins=*
```

(Flatpak: `flatpak run com.spotify.Client -- --remote-debugging-port=9222 --remote-allow-origins=*`)

**2. Install dependencies**

```sh
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

`mrn4txt.ts` has no external npm dependencies - just [Bun](https://bun.sh)
itself needs to be installed and on `PATH`.

**3. Run the daemon**

```sh
source .venv/bin/activate
python kanvasd.py
```

## Autostart (systemd)

`kanvasd` waits for `org.mpris.MediaPlayer2.spotify` to appear on the
session D-Bus before doing anything else, so it's safe to start before
Spotify itself is running - no crash loop, no polling, it just sits idle
until Spotify shows up. Quitting and relaunching Spotify while `kanvasd`
is already running also works fine with no special handling - the MPRIS
subscription picks back up on its own. This makes it safe to run as a
`systemd --user` service that starts at login:

```sh
mkdir -p ~/.local/bin/kanvasd
cp kanvasd.py spotify_token_extractor.py mrn4txt.ts ~/.local/bin/kanvasd/
cd ~/.local/bin/kanvasd
python -m venv .venv && .venv/bin/pip install -r requirements.txt

mkdir -p ~/.config/systemd/user
cp kanvasd.service ~/.config/systemd/user/
systemctl --user enable --now kanvasd
```

Check on it with `systemctl --user status kanvasd` /
`journalctl --user -u kanvasd -f`.

One thing this doesn't handle on its own: actually launching Spotify
with `--remote-debugging-port=9222 --remote-allow-origins=*`.
`install.sh` can patch a user-local copy of Spotify's `.desktop`
launcher to add these automatically (it asks first, defaults to no) - if
you're doing this by hand instead, add the flags however you normally
launch Spotify (a `.desktop` file, a shell alias, etc.).

## How it fits together

```
MPRIS (Spotify) --track change--> kanvasd.py
                                       |
                                       |-- cached token? use it
                                       |-- stale/missing? refresh via
                                       |   spotify_token_extractor.py (CDP)
                                       |
                                       v
                              mrn4txt.ts (subprocess, SP_ACCESS_TOKEN env)
                                       |
                                       v
                     ~/.cache/kanvasd/canvases/<track_id>.mp4
                                       |
                          symlinked as current.mp4  <-- KanvasPlayer watches this
```

- Up to 5 canvases are cached on disk (LRU eviction); replaying a recent
  track skips the network entirely.
- If the fetcher reports a 401 (exit code 2), the daemon forces a token
  refresh and retries once before giving up.
- If a track genuinely has no Canvas, `current.mp4` is removed so the
  widget falls back to album art rather than showing a stale video.
