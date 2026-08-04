// SPDX-FileCopyrightText: 2026 KenzieOSS
// SPDX-License-Identifier: GPL-3.0-only
import QtQuick
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("Appearance")
        icon: "preferences-desktop-theme-symbolic"
        source: "configGeneral.qml"
    }
}
