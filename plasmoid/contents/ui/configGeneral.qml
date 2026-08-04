// SPDX-FileCopyrightText: 2026 KenzieOSS
// SPDX-License-Identifier: GPL-3.0-only
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: root

    property alias cfg_compactMode: compactModeCheckbox.checked

    Kirigami.FormLayout {
        Layout.fillWidth: true

        RowLayout {
            Kirigami.FormData.label: i18n("Compact mode:")
            CheckBox {
                id: compactModeCheckbox
            }
            Kirigami.ContextualHelpButton {
                toolTipText: i18n("Shows the canvas video as a full-bleed background with the track title, artist, and album overlaid on top, instead of a separate box next to the details column.")
            }
        }
    }
}
