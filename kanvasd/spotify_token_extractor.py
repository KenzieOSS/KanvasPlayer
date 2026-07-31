#!/usr/bin/env python3
"""
Extract the Spotify desktop app's Bearer token via the Chrome DevTools
Protocol (CDP). Spotify's Linux client is CEF/Electron-based, so it
supports the same --remote-debugging-port flag as Chrome.
"""
import json
import time
import sys

import requests
import websocket

DEBUG_PORT = 9222
TIMEOUT_SECONDS = 30


def get_target(debug_port: int):
    resp = requests.get(f"http://localhost:{debug_port}/json", timeout=5)
    resp.raise_for_status()
    targets = resp.json()

    # Prefer the main xpui page if we can identify it.
    for t in targets:
        if t.get("type") == "page" and "spotify.com" in t.get("url", ""):
            return t

    # Fallback: any page target.
    for t in targets:
        if t.get("type") == "page":
            return t

    raise RuntimeError(
        "No debuggable page target found. Is Spotify running with "
        f"--remote-debugging-port={debug_port}?"
    )


def extract_bearer_token(debug_port: int = DEBUG_PORT, timeout: int = TIMEOUT_SECONDS):
    target = get_target(debug_port)
    ws_url = target.get("webSocketDebuggerUrl")
    if not ws_url:
        raise RuntimeError("Target has no webSocketDebuggerUrl.")

    ws = websocket.create_connection(ws_url)
    ws.send(json.dumps({"id": 1, "method": "Network.enable"}))

    print("Connected to Spotify's DevTools. Waiting for an authenticated "
          "request (browse a playlist, search, etc.)...")

    start = time.time()
    ws.settimeout(2)
    while time.time() - start < timeout:
        try:
            message = ws.recv()
        except websocket.WebSocketTimeoutException:
            continue

        if not message:
            continue

        data = json.loads(message)
        if data.get("method") != "Network.requestWillBeSent":
            continue

        headers = data["params"]["request"].get("headers", {})
        auth = headers.get("Authorization") or headers.get("authorization")
        if auth and auth.startswith("Bearer "):
            token = auth.split(" ", 1)[1]
            print("\nBearer token found:\n")
            print(token)
            ws.close()
            return token

    ws.close()
    print("Timed out without seeing an Authorization header. Try "
          "interacting with the app more, or increase `timeout`.")
    return None


if __name__ == "__main__":
    try:
        extract_bearer_token()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
