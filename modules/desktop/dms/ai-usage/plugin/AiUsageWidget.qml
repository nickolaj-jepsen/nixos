// Bar pill: provider icon + concentric pace rings (short window outside, long inside).
// Popout: every window with its projection. Data and pace come from `ai-usage --json`;
// pluginData.command is its store path.
import QtQuick
import QtQuick.Effects
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    property var popoutService: null

    readonly property string command: pluginData.command || "ai-usage"
    readonly property var hiddenProviders: pluginData.hiddenProviders || []
    readonly property var barProviders: providers.filter(p => hiddenProviders.indexOf(p.id) < 0)
    readonly property real textSize: Theme.barTextSize(barThickness, barConfig?.fontScale, barConfig?.maximizeWidgetText)
    readonly property string iconDir: Qt.resolvedUrl("icons/")
    readonly property var tabular: ({
            "tnum": 1
        })

    property var providers: []
    property string generatedAt: ""
    property string fetchError: ""
    property real nowMs: Date.now()
    property bool refreshing: false

    function refresh(force) {
        root.refreshing = true;
        Proc.runCommand("aiUsage.fetch", [root.command, "--json"].concat(force ? ["--refresh"] : []), (stdout, exitCode) => {
            root.refreshing = false;
            root.nowMs = Date.now();
            if (exitCode !== 0) {
                root.fetchError = "ai-usage exited with " + exitCode;
                return;
            }
            try {
                const result = JSON.parse(stdout);
                root.providers = result.providers;
                root.generatedAt = result.generatedAt;
                root.fetchError = "";
            } catch (e) {
                root.fetchError = "ai-usage printed invalid JSON";
            }
        }, 0, 30000);
    }

    function ringWindow(p, ring) {
        return p.windows.find(w => w.ring === ring) || null;
    }

    // Neutral while on pace, like the other bar monitors; color only flags trouble.
    function paceColor(w) {
        if (!w)
            return Theme.surfaceVariantText;
        return w.pace === "exhausted" ? Theme.error : w.pace === "over" ? Theme.warning : Theme.widgetIconColor;
    }

    function dimmed(p) {
        return p.stale || (!!p.error && !p.windows.length);
    }

    function clock(ms) {
        return new Date(ms).toLocaleTimeString(Qt.locale(), "HH:mm");
    }

    // Countdown within a day, weekday + time within a week, else the date.
    function when(iso) {
        const ms = Date.parse(iso);
        const s = Math.max(0, (ms - root.nowMs) / 1000);
        if (s < 86400) {
            const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60);
            return "in " + (h > 0 ? h + "h " + m + "m" : m + "m");
        }
        const d = new Date(ms);
        return s < 7 * 86400 ? d.toLocaleString(Qt.locale(), "ddd HH:mm") : d.toLocaleDateString(Qt.locale(), "d MMM");
    }

    function age(iso) {
        if (!iso)
            return "never fetched";
        const m = Math.floor((root.nowMs - Date.parse(iso)) / 60000);
        return m < 1 ? "just now" : m < 60 ? m + "m ago" : Math.floor(m / 60) + "h ago";
    }

    // Shown under a window's row: when it runs out at this pace, and any provider detail.
    function windowNote(w) {
        return [w.runsOutAt ? "runs out " + root.when(w.runsOutAt) + " at this pace" : "", w.detail || ""].filter(t => t).join(" · ");
    }

    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.nowMs = Date.now();
            root.refresh();
        }
    }

    // Inline components don't see the file's ids, so `root` comes in as `widget`.
    component ProviderIcon: Item {
        id: providerIcon

        required property var provider
        required property var widget
        property real size: widget.iconSize * 0.8

        implicitWidth: size
        implicitHeight: size

        Image {
            id: logo
            anchors.fill: parent
            visible: false
            source: providerIcon.provider.icon ? providerIcon.widget.iconDir + providerIcon.provider.icon + ".svg" : ""
            sourceSize: Qt.size(providerIcon.size * 2, providerIcon.size * 2)
            smooth: true
            mipmap: true
        }

        MultiEffect {
            anchors.fill: parent
            visible: logo.status === Image.Ready
            source: logo
            colorization: 1
            colorizationColor: Theme.surfaceVariantText
        }

        StyledText {
            anchors.centerIn: parent
            visible: logo.status !== Image.Ready
            text: providerIcon.provider.short
            font.pixelSize: providerIcon.widget.textSize * 0.8
            color: Theme.surfaceVariantText
        }

        // Tells apart accounts that share an icon (Claude vs Claude work).
        StyledText {
            visible: !!providerIcon.provider.badge
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: -width / 2
            anchors.bottomMargin: -height / 4
            text: providerIcon.provider.badge || ""
            font.pixelSize: providerIcon.size * 0.5
            font.weight: Font.Bold
            color: Theme.surfaceText
        }
    }

    component ProviderRings: UsageRings {
        required property var provider
        required property var widget

        outer: widget.ringWindow(provider, "outer")
        inner: widget.ringWindow(provider, "inner")
        outerColor: widget.paceColor(outer)
        innerColor: widget.paceColor(inner)
        diameter: widget.iconSize + 2
        opacity: widget.dimmed(provider) ? 0.45 : 1
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingM

            StyledText {
                visible: root.barProviders.length === 0
                anchors.verticalCenter: parent.verticalCenter
                text: "AI --"
                font.pixelSize: root.textSize
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.barProviders

                Row {
                    required property var modelData
                    spacing: Theme.spacingXS + 2
                    anchors.verticalCenter: parent.verticalCenter

                    ProviderIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        provider: parent.modelData
                        widget: root
                    }

                    ProviderRings {
                        anchors.verticalCenter: parent.verticalCenter
                        provider: parent.modelData
                        widget: root
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingM

            Repeater {
                model: root.barProviders

                Column {
                    required property var modelData
                    spacing: Theme.spacingXS
                    anchors.horizontalCenter: parent.horizontalCenter

                    ProviderIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        provider: parent.modelData
                        widget: root
                    }

                    ProviderRings {
                        anchors.horizontalCenter: parent.horizontalCenter
                        provider: parent.modelData
                        widget: root
                    }
                }
            }
        }
    }

    popoutWidth: 500

    // Label, used %, projection and reset columns; the bar takes the rest.
    readonly property var columns: ({
            "label": 44,
            "used": 36,
            "projection": 48,
            "reset": 104
        })

    component Chip: Rectangle {
        property alias text: chipText.text
        property color tone: Theme.surfaceVariantText

        implicitWidth: chipText.implicitWidth + Theme.spacingS * 2
        implicitHeight: chipText.implicitHeight + 4
        radius: height / 2
        color: Theme.withAlpha(tone, 0.15)

        StyledText {
            id: chipText
            anchors.centerIn: parent
            width: parent.width - Theme.spacingS * 2
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeSmall
            color: parent.tone
        }
    }

    popoutContent: Component {
        PopoutComponent {
            headerText: "AI usage"
            detailsText: root.fetchError

            headerActions: Component {
                Row {
                    spacing: Theme.spacingS

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!root.generatedAt
                        text: "updated " + root.clock(Date.parse(root.generatedAt))
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Rectangle {
                        width: Theme.iconSize + Theme.spacingXS * 2
                        height: width
                        radius: width / 2
                        color: refreshArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.1) : "transparent"

                        DankIcon {
                            id: refreshIcon
                            anchors.centerIn: parent
                            name: "refresh"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceText

                            RotationAnimation on rotation {
                                running: root.refreshing
                                from: 0
                                to: 360
                                duration: 900
                                loops: Animation.Infinite
                                onStopped: refreshIcon.rotation = 0
                            }
                        }

                        MouseArea {
                            id: refreshArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.refresh(true)
                        }
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: root.providers

                    Rectangle {
                        id: card
                        required property var modelData
                        width: parent.width
                        height: cardColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.55)

                        Column {
                            id: cardColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Item {
                                width: parent.width
                                height: Math.max(nameRow.implicitHeight, statusChip.implicitHeight)

                                Row {
                                    id: nameRow
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    ProviderIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        provider: card.modelData
                                        widget: root
                                        size: Theme.fontSizeLarge
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: card.modelData.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }
                                }

                                // An error outranks overage: it says the numbers may be wrong.
                                Chip {
                                    id: statusChip
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width - nameRow.implicitWidth - Theme.spacingM)
                                    visible: !!card.modelData.error || !!card.modelData.overage
                                    text: card.modelData.error ? (card.modelData.stale ? "stale " + root.age(card.modelData.fetchedAt) + ": " : "") + card.modelData.error : card.modelData.overage?.text ?? ""
                                    tone: card.modelData.error ? (card.modelData.stale ? Theme.warning : Theme.error) : card.modelData.overage?.active ? Theme.warning : Theme.surfaceVariantText
                                }
                            }

                            Repeater {
                                model: card.modelData.windows

                                Column {
                                    id: windowItem
                                    required property var modelData
                                    readonly property color tone: root.paceColor(modelData)
                                    readonly property string note: root.windowNote(modelData)
                                    width: parent.width
                                    spacing: 2

                                    Row {
                                        width: parent.width
                                        spacing: Theme.spacingS

                                        StyledText {
                                            width: root.columns.label
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: windowItem.modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                        }

                                        // Fill = used, tinted once it is trouble; tick = elapsed share of a window (a meter has none).
                                        Item {
                                            width: parent.width - root.columns.label - root.columns.used - root.columns.projection - root.columns.reset - parent.spacing * 4
                                            height: 8
                                            anchors.verticalCenter: parent.verticalCenter

                                            readonly property real usedX: width * Math.min(1, windowItem.modelData.usedPct / 100)
                                            readonly property real elapsedX: width * windowItem.modelData.elapsedPct / 100
                                            // A window tints only past the tick; a meter, having no tick, tints whole.
                                            readonly property color fill: windowItem.modelData.pace === "exhausted" ? Theme.error
                                                : windowItem.modelData.meter && windowItem.modelData.pace === "over" ? Theme.warning
                                                : Theme.withAlpha(Theme.surfaceText, 0.75)

                                            Rectangle {
                                                anchors.fill: parent
                                                radius: height / 2
                                                color: Theme.withAlpha(Theme.surfaceText, 0.12)
                                            }

                                            Rectangle {
                                                width: parent.usedX
                                                height: parent.height
                                                radius: height / 2
                                                color: parent.fill
                                            }

                                            // Only a window has a share of it elapsed; a meter has no tick.
                                            Rectangle {
                                                visible: !windowItem.modelData.meter && windowItem.modelData.pace === "over" && parent.usedX > parent.elapsedX
                                                x: parent.elapsedX
                                                width: parent.usedX - parent.elapsedX
                                                height: parent.height
                                                radius: height / 2
                                                color: Theme.warning
                                            }

                                            Rectangle {
                                                visible: !windowItem.modelData.meter
                                                x: parent.elapsedX - width / 2
                                                y: -2
                                                width: 2
                                                height: parent.height + 4
                                                color: Theme.surfaceText
                                                opacity: 0.6
                                            }
                                        }

                                        StyledText {
                                            width: root.columns.used
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignRight
                                            text: Math.round(windowItem.modelData.usedPct) + "%"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.features: root.tabular
                                            color: Theme.surfaceText
                                        }

                                        // Linear projection to reset; absent early in a window.
                                        StyledText {
                                            width: root.columns.projection
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: windowItem.modelData.projectedPct == null ? "" : "→" + windowItem.modelData.projectedPct + "%"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.features: root.tabular
                                            color: windowItem.modelData.pace === "under" ? Theme.surfaceVariantText : windowItem.tone
                                        }

                                        Row {
                                            width: root.columns.reset
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 3

                                            DankIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "autorenew"
                                                size: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                            }

                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: root.when(windowItem.modelData.resetsAt)
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.features: root.tabular
                                                color: Theme.surfaceVariantText
                                            }
                                        }
                                    }

                                    StyledText {
                                        visible: windowItem.note !== ""
                                        leftPadding: root.columns.label + Theme.spacingS
                                        text: windowItem.note
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: windowItem.modelData.runsOutAt ? windowItem.tone : Theme.surfaceVariantText
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
