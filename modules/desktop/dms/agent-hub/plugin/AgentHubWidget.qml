// Bar pill: a dot per session that wants attention or is working. Popout: every
// live agent session by state, in the hub's order. Keys: Enter focuses the
// selected session, j/k move; the selection starts on the longest-waiting one.
import QtQuick
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property var hub: PluginService.pluginDaemonInstances[pluginId] ?? null
    readonly property bool linkUp: hub?.linkUp ?? false
    readonly property var sessions: hub?.sessions ?? []
    readonly property var active: sessions.filter(s => s.state !== "idle")
    readonly property int idleCount: sessions.length - active.length
    readonly property int maxDots: 6
    // A session left waiting this long turns from warning to error.
    readonly property int errorSeconds: 900
    readonly property var sections: [
        {
            "state": "needs-you",
            "title": "Needs you"
        },
        {
            "state": "your-turn",
            "title": "Your turn"
        },
        {
            "state": "working",
            "title": "Working"
        }
    ]

    property bool showIdle: false
    property string selectedId: ""
    property real nowMs: Date.now()

    // The rows j/k walks, in the order the popout lists them.
    readonly property var listed: showIdle ? sessions : active
    readonly property var selected: listed.find(s => s.id === selectedId) ?? listed[0] ?? null

    _visibilityOverride: true
    _visibilityOverrideValue: active.length > 0 || !linkUp

    function tone(session) {
        if (session.state === "needs-you")
            return (nowMs - session.since) / 1000 >= errorSeconds ? Theme.error : Theme.warning;
        if (session.state === "your-turn")
            return Theme.primary;
        return Theme.surfaceVariantText;
    }

    function ago(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "now" : m < 60 ? m + "m" : Math.floor(m / 60) + "h";
    }

    function move(step) {
        if (!listed.length)
            return;
        const at = listed.findIndex(s => s.id === selected?.id);
        selectedId = listed[Math.max(0, Math.min(listed.length - 1, at + step))].id;
    }

    function focusSession(session) {
        if (!session)
            return;
        hub.focusSession(session.id);
        closePopout();
    }

    Timer {
        interval: 15000
        running: root.active.some(s => s.state === "needs-you")
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    component Dot: Rectangle {
        required property color tone
        property real size: 8

        width: size
        height: size
        radius: size / 2
        color: tone
    }

    // Past maxDots the pill shows a count per state instead of one dot per session.
    readonly property var pillItems: {
        if (active.length <= maxDots)
            return active.map(s => ({
                        "tone": tone(s),
                        "count": 0
                    }));
        return sections.map(section => {
            const rows = active.filter(s => s.state === section.state);
            return {
                "tone": rows.length ? rows.map(tone).find(t => t === Theme.error) ?? tone(rows[0]) : "transparent",
                "count": rows.length
            };
        }).filter(item => item.count > 0);
    }

    component PillItem: Row {
        required property var modelData
        required property var widget
        spacing: 3

        Dot {
            anchors.verticalCenter: parent.verticalCenter
            tone: parent.modelData.tone
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            visible: parent.modelData.count > 0
            text: parent.modelData.count
            font.pixelSize: parent.widget.textSize
            color: Theme.widgetTextColor
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS + 2

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.linkUp
                name: "link_off"
                size: root.iconSize
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.pillItems

                PillItem {
                    anchors.verticalCenter: parent.verticalCenter
                    widget: root
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS + 2

            DIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.linkUp
                name: "link_off"
                size: root.iconSize
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.pillItems

                PillItem {
                    anchors.horizontalCenter: parent.horizontalCenter
                    widget: root
                }
            }
        }
    }

    component SessionRow: Rectangle {
        id: row

        required property var session
        required property var widget
        readonly property bool isSelected: widget.selected?.id === session.id

        width: parent.width
        height: rowContent.implicitHeight + Theme.spacingS * 2
        radius: Theme.cornerRadius
        color: isSelected ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"

        StateLayer {
            anchors.fill: parent
            onClicked: row.widget.focusSession(row.session)
        }

        Row {
            id: rowContent
            x: Theme.spacingS
            y: Theme.spacingS
            width: parent.width - Theme.spacingS * 2
            spacing: Theme.spacingS

            Dot {
                anchors.verticalCenter: parent.verticalCenter
                tone: row.widget.tone(row.session)
            }

            Column {
                width: parent.width - 8 - parent.spacing
                spacing: 2

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        id: nameText
                        width: Math.min(implicitWidth, parent.width - ageText.implicitWidth - agentText.implicitWidth - Theme.spacingS * 2)
                        text: row.session.name || Paths.shortenHome(row.session.cwd)
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        id: agentText
                        anchors.baseline: nameText.baseline
                        text: row.session.agent
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        id: ageText
                        anchors.baseline: nameText.baseline
                        visible: row.session.state !== "idle"
                        text: row.widget.ago(row.session.since)
                        font.pixelSize: Theme.fontSizeSmall
                        color: row.session.state === "needs-you" ? row.widget.tone(row.session) : Theme.surfaceVariantText
                    }
                }

                StyledText {
                    width: parent.width
                    text: [row.session.waitingFor || row.session.doing || row.session.summary, Paths.shortenHome(row.session.cwd)].filter(t => t).join(" · ")
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeSmall
                    color: row.session.state === "needs-you" ? Theme.surfaceText : Theme.surfaceVariantText
                }
            }
        }
    }

    popoutWidth: 520

    popoutContent: Component {
        FocusScope {
            id: pop

            property var parentPopout: null
            property var closePopout: null

            implicitHeight: content.implicitHeight
            focus: true

            function grab() {
                Qt.callLater(() => pop.forceActiveFocus());
            }

            Component.onCompleted: grab()

            Connections {
                target: pop.parentPopout
                function onOpened() {
                    root.nowMs = Date.now();
                    root.selectedId = "";
                    pop.grab();
                }
            }

            Keys.onPressed: event => {
                if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                    return;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    root.focusSession(root.selected);
                else if (event.key === Qt.Key_J || event.key === Qt.Key_Down)
                    root.move(1);
                else if (event.key === Qt.Key_K || event.key === Qt.Key_Up)
                    root.move(-1);
                else
                    return;
                event.accepted = true;
            }

            Column {
                id: content
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    width: parent.width
                    visible: !root.linkUp || !root.sessions.length
                    text: root.linkUp ? "No agent sessions." : "The agent-hub service is not running."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: root.sections

                    Column {
                        id: section
                        required property var modelData
                        readonly property var rows: root.active.filter(s => s.state === modelData.state)

                        width: parent.width
                        spacing: 2
                        visible: rows.length > 0

                        StyledText {
                            text: section.modelData.title
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: section.rows

                            SessionRow {
                                required property var modelData
                                session: modelData
                                widget: root
                            }
                        }
                    }
                }

                StyledText {
                    visible: root.idleCount > 0
                    text: (root.showIdle ? "▾ " : "▸ ") + root.idleCount + " idle"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceVariantText

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showIdle = !root.showIdle
                    }
                }

                Repeater {
                    model: root.showIdle ? root.sessions.filter(s => s.state === "idle") : []

                    SessionRow {
                        required property var modelData
                        session: modelData
                        widget: root
                    }
                }
            }
        }
    }
}
