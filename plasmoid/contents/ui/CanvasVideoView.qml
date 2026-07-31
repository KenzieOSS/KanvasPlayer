/*
    SPDX-FileCopyrightText: 2026 KenzieOSS

    SPDX-License-Identifier: GPL-2.0-or-later

    Displays the Spotify Canvas video fetched by kanvasd for the currently
    playing track. Not every track has a Canvas, so `hasVideo` reports
    whether a playable video is currently loaded - the caller is expected
    to fall back to album art (AlbumArtStackView) when it's false.

    kanvasd replaces ~/.cache/kanvasd/current.mp4 (delete, then recreate)
    whenever a new canvas is ready, and removes it outright when the
    current track has no canvas.

    We deliberately DON'T rely on FolderListModel's onCountChanged to tell
    us when to reload: a delete-then-recreate under the same filename may
    not reliably surface as a row add/remove depending on how the model
    diffs directory rescans internally, which was causing silent misses
    when skipping straight from one canvas-having track to another. So we
    poll FolderListModel's own exposed data (existence + fileModified)
    ourselves on a short timer instead of trusting its change signals.
*/
pragma ComponentBehavior: Bound

import QtQuick
import QtMultimedia
import Qt.labs.platform as Labs
import Qt.labs.folderlistmodel

Item {
    id: canvasView

    readonly property url cacheDir: Qt.resolvedUrl(
        Labs.StandardPaths.writableLocation(Labs.StandardPaths.HomeLocation) + "/.cache/kanvasd")
    readonly property url canvasFile: cacheDir + "/current.mp4"

    // True once a video is actually decodable and ready to show.
    readonly property bool hasVideo: player.hasVideo
        && (player.status === MediaPlayer.Buffered || player.status === MediaPlayer.Loaded)

    // Tracks what we last loaded, so the poll below only reloads on an
    // actual change instead of every tick.
    property bool _lastPresent: false
    property var _lastModified: undefined

    /**
     * Force the player to pick up current.mp4 again, even if the source
     * string hasn't changed - kanvasd may have replaced the file in place
     * (same path, new bytes) when a new track's canvas became ready.
     */
    function reload(): void {
        player.stop();
        player.source = "";
        if (watcher.count > 0) {
            player.source = canvasView.canvasFile;
            if (root.isPlaying) {
                player.play();
            }
        }
    }

    Component.onCompleted: reload()

    Connections {
        target: root
        function onIsPlayingChanged(): void {
            if (!canvasView.hasVideo) {
                return;
            }
            if (root.isPlaying) {
                player.play();
            } else {
                player.pause();
            }
        }
    }

    // Pure data source - just lists current.mp4 if it exists, so we can
    // read its existence/fileModified. Its own change signals are NOT
    // used as the reload trigger (see file header comment).
    FolderListModel {
        id: watcher
        folder: canvasView.cacheDir
        nameFilters: ["current.mp4"]
        showDirs: false
        showDotAndDotDot: false
    }

    // Actively polls the watcher's data every second and reloads on any
    // actual change (present/absent flips, or a newer fileModified while
    // still present). Deterministic regardless of how FolderListModel
    // internally diffs a same-name replace.
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            const present = watcher.count > 0;
            const modified = present ? watcher.get(0, "fileModified") : undefined;

            const changed = present !== canvasView._lastPresent
                || (present && (canvasView._lastModified === undefined
                    || modified.getTime() !== canvasView._lastModified.getTime()));

            if (changed) {
                canvasView._lastPresent = present;
                canvasView._lastModified = modified;
                canvasView.reload();
            }
        }
    }

    MediaPlayer {
        id: player
        loops: MediaPlayer.Infinite
        videoOutput: videoOutput
        // Canvas videos have no audio track; nothing to route.
        audioOutput: null
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: canvasView.hasVideo
    }
}
