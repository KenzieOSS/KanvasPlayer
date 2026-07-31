#!/usr/bin/env python3
"""
kanvasd - canvas daemon for the KanvasPlayer Plasma widget (a modified
Plasma MediaPlayer).

Watches MPRIS (org.mpris.MediaPlayer2.spotify) for track changes. On each
new track, spawns the TypeScript canvas fetcher with a cached Bearer token.
If the fetcher exits with code 2 (auth failure), forces a token refresh via
CDP and retries once. Writes the resulting mp4 to a fixed, predictable path
so the QML widget can just watch that file (e.g. with a FileWatcher / by
re-reading it on trackChanged).

Only the MAX_CACHED_CANVASES most recently used canvases are kept on disk;
older ones are evicted LRU-style after each new download.

Waits for org.mpris.MediaPlayer2.spotify to appear on the session bus
before doing anything else, so it's safe to autostart (e.g. via a
systemd --user service) before Spotify itself is running.

DEPENDENCIES
    pip install dbus-next requests websocket-client

USAGE
    python3 kanvasd.py
"""

import asyncio
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from dbus_next.aio import MessageBus
from dbus_next import BusType

# --- import the token extractor from the earlier script -------------------
# Put spotify_token_extractor.py next to this file (or on PYTHONPATH).
from spotify_token_extractor import extract_bearer_token, DEBUG_PORT

CACHE_DIR = Path.home() / ".cache" / "kanvasd"
TOKEN_FILE = CACHE_DIR / "token.json"
CANVAS_DIR = CACHE_DIR / "canvases"
CURRENT_CANVAS = CACHE_DIR / "current.mp4"   # fixed path QML watches

def resolve_bun_path() -> str:
    """
    Find the bun executable without trusting ambient PATH - a systemd
    --user service gets its own minimal environment and never sources
    .bashrc/.bash_profile, so "just add it to PATH in your shell config"
    (what the official Bun installer does) doesn't reach it. Checked, in
    order: $PATH, then the official installer's default location.
    """
    from_path = shutil.which("bun")
    if from_path:
        return from_path

    default_install = Path.home() / ".bun" / "bin" / "bun"
    if default_install.exists():
        return str(default_install)

    raise RuntimeError(
        "Could not find the 'bun' executable (checked $PATH and "
        f"{default_install}). Install it from https://bun.sh, or if it's "
        "installed somewhere else, make sure it's on PATH for whatever "
        "context runs kanvasd.py (a systemd --user service does NOT "
        "inherit your shell's PATH from .bashrc/.bash_profile)."
    )


FETCHER_CMD = [resolve_bun_path(), "run", str(Path(__file__).parent / "mrn4txt.ts")]

# Spotify access tokens are typically valid ~1hr; refresh a bit early.
TOKEN_MAX_AGE = 45 * 60

# Max number of canvas mp4s to keep on disk (LRU eviction).
MAX_CACHED_CANVASES = 5


class TokenManager:
    def __init__(self):
        self._token = None
        self._fetched_at = 0
        self._lock = asyncio.Lock()
        self._load_cache()

    def _load_cache(self):
        if TOKEN_FILE.exists():
            try:
                data = json.loads(TOKEN_FILE.read_text())
                self._token = data["token"]
                self._fetched_at = data["fetched_at"]
            except Exception:
                pass

    def _save_cache(self):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        TOKEN_FILE.write_text(json.dumps({
            "token": self._token,
            "fetched_at": self._fetched_at,
        }))

    def _is_stale(self) -> bool:
        return self._token is None or (time.time() - self._fetched_at) > TOKEN_MAX_AGE

    async def get(self, force_refresh: bool = False) -> str:
        async with self._lock:
            if force_refresh or self._is_stale():
                print("[token] refreshing via CDP...")
                loop = asyncio.get_event_loop()
                token = await loop.run_in_executor(
                    None, lambda: extract_bearer_token(DEBUG_PORT, 30)
                )
                if not token:
                    raise RuntimeError(
                        "Could not extract a fresh token. Is Spotify running "
                        "with --remote-debugging-port and --remote-allow-origins=*?"
                    )
                self._token = token
                self._fetched_at = time.time()
                self._save_cache()
            return self._token


token_mgr = TokenManager()


def _touch(path: Path):
    """Bump mtime so LRU eviction treats this as recently used."""
    now = time.time()
    os.utime(path, (now, now))


def _evict_lru():
    """Keep only the MAX_CACHED_CANVASES most recently used mp4s."""
    files = sorted(
        CANVAS_DIR.glob("*.mp4"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,  # newest first
    )
    for stale in files[MAX_CACHED_CANVASES:]:
        try:
            stale.unlink()
            print(f"[cache] evicted {stale.name}")
        except OSError:
            pass


async def fetch_canvas(track_id: str) -> Path | None:
    """Run the TS fetcher for track_id, retrying once on a 401."""
    CANVAS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = CANVAS_DIR / f"{track_id}.mp4"

    if out_path.exists():
        _touch(out_path)  # mark as recently used so it isn't evicted next
        return out_path  # already cached

    for attempt, force in enumerate([False, True]):
        token = await token_mgr.get(force_refresh=force)
        env = {**os.environ, "SP_ACCESS_TOKEN": token}

        proc = await asyncio.create_subprocess_exec(
            *FETCHER_CMD, track_id, "-o", str(out_path),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()

        if proc.returncode == 0:
            _evict_lru()
            return out_path

        if proc.returncode == 2:
            print(f"[fetcher] token rejected (attempt {attempt + 1}), "
                  f"{'retrying with fresh token' if attempt == 0 else 'giving up'}")
            if attempt == 0:
                continue
            return None

        # Non-auth failure (e.g. no canvas for this track) - don't retry.
        print(f"[fetcher] failed (exit {proc.returncode}): "
              f"{stderr.decode(errors='replace').strip()}")
        return None

    return None


async def on_track_changed(track_id: str):
    print(f"[track] {track_id}")
    result = await fetch_canvas(track_id)
    if result is None:
        print("[canvas] none available for this track")
        # Clear any previous track's canvas so the widget falls back to
        # album art instead of showing a stale video.
        if CURRENT_CANVAS.exists() or CURRENT_CANVAS.is_symlink():
            CURRENT_CANVAS.unlink()
        return

    # Delete-then-recreate rather than an atomic rename over the existing
    # name. QML's FolderListModel (what the widget watches) only notices a
    # row being added or removed - an in-place rename onto an existing
    # filename doesn't change its row count, so it was never told to
    # reload when going straight from one canvas to another. This trades
    # a few-millisecond gap (file briefly absent) for a reliable 0->1
    # transition the watcher can actually see.
    if CURRENT_CANVAS.exists() or CURRENT_CANVAS.is_symlink():
        CURRENT_CANVAS.unlink()
    CURRENT_CANVAS.symlink_to(result)
    print(f"[canvas] ready -> {CURRENT_CANVAS}")


def extract_track_id_from_mpris(metadata: dict) -> str | None:
    trackid = metadata.get("mpris:trackid")
    if trackid:
        val = trackid.value if hasattr(trackid, "value") else trackid
        # e.g. "/com/spotify/track/3n3Ppam7vgaVa1iaRUc9Lp"
        if "/track/" in val:
            return val.rsplit("/track/", 1)[-1]
    url = metadata.get("xesam:url")
    if url:
        val = url.value if hasattr(url, "value") else url
        if "/track/" in val:
            return val.rstrip("/").rsplit("/track/", 1)[-1].split("?")[0]
    return None


SPOTIFY_BUS_NAME = "org.mpris.MediaPlayer2.spotify"


async def wait_for_spotify(bus: MessageBus) -> None:
    """
    Block until org.mpris.MediaPlayer2.spotify appears on the session bus.
    Returns immediately if it's already there. Lets kanvasd start cleanly
    under systemd before Spotify has even been launched, instead of
    throwing on introspect().
    """
    dbus_introspection = await bus.introspect(
        "org.freedesktop.DBus", "/org/freedesktop/DBus"
    )
    dbus_proxy = bus.get_proxy_object(
        "org.freedesktop.DBus", "/org/freedesktop/DBus", dbus_introspection
    )
    dbus_iface = dbus_proxy.get_interface("org.freedesktop.DBus")

    if await dbus_iface.call_name_has_owner(SPOTIFY_BUS_NAME):
        return

    appeared = asyncio.Event()

    def on_name_owner_changed(name: str, old_owner: str, new_owner: str):
        if name == SPOTIFY_BUS_NAME and new_owner:
            appeared.set()

    dbus_iface.on_name_owner_changed(on_name_owner_changed)

    print("Spotify not running yet - waiting for it to appear on D-Bus...")
    await appeared.wait()

    dbus_iface.off_name_owner_changed(on_name_owner_changed)


async def main():
    bus = await MessageBus(bus_type=BusType.SESSION).connect()

    await wait_for_spotify(bus)

    introspection = await bus.introspect(
        SPOTIFY_BUS_NAME, "/org/mpris/MediaPlayer2"
    )
    proxy = bus.get_proxy_object(
        SPOTIFY_BUS_NAME, "/org/mpris/MediaPlayer2", introspection
    )
    props = proxy.get_interface("org.freedesktop.DBus.Properties")

    last_track_id = None

    def on_properties_changed(interface_name, changed_props, invalidated_props):
        nonlocal last_track_id
        if "Metadata" not in changed_props:
            return
        metadata = changed_props["Metadata"].value
        track_id = extract_track_id_from_mpris(metadata)
        if track_id and track_id != last_track_id:
            last_track_id = track_id
            asyncio.create_task(on_track_changed(track_id))

    props.on_properties_changed(on_properties_changed)

    print("kanvasd running. Watching Spotify MPRIS for track changes...")
    await asyncio.Event().wait()  # run forever


if __name__ == "__main__":
    asyncio.run(main())
