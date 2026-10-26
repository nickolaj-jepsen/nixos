// Bar pill: a dot per session that wants attention or is working. Popout: a switcher
// over every live agent session in the hub's order, the selected row expanded to its
// full reason. Keys: Enter focuses the selection, x dismisses a finished one, j/k move,
// g/G jump to the ends; the selection starts on the first row, so Mod+B then Enter goes
// to the longest-waiting one.
import QtQuick
import QtQuick.Effects
import QtQuick.Window
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
    readonly property int maxDots: 6
    // A session left asking or waiting on a reply this long has its age turn red.
    readonly property int staleSeconds: 900
    readonly property var pillStates: ["asking", "needs-reply", "failed", "done", "working"]
    readonly property string iconDir: Qt.resolvedUrl("icons/")

    property string selectedId: ""
    property real nowMs: Date.now()

    readonly property int selectedIndex: Math.max(0, sessions.findIndex(s => s.id === selectedId))
    readonly property var selected: sessions[selectedIndex] ?? null

    _visibilityOverride: true
    _visibilityOverrideValue: active.length > 0 || !linkUp

    function wantsYou(session) {
        return ["asking", "needs-reply", "failed", "done"].includes(session.state);
    }

    function finished(session) {
        return ["needs-reply", "failed", "done"].includes(session.state);
    }

    function stale(session) {
        return (session.state === "asking" || session.state === "needs-reply") && (nowMs - session.since) / 1000 >= staleSeconds;
    }

    function tone(session) {
        return {
            "asking": Theme.error,
            "needs-reply": Theme.warning,
            "failed": Theme.error,
            "done": Theme.primary
        }[session.state] ?? Theme.surfaceVariantText;
    }

    function reason(session) {
        return {
            "asking": session.waitingFor,
            "needs-reply": session.ask,
            "failed": session.summary,
            "done": session.summary,
            "working": session.doing
        }[session.state] || "";
    }

    function stateWords(session) {
        const at = Qt.formatTime(new Date(session.since), "HH:mm");
        return {
            "asking": "asking since ",
            "needs-reply": "waiting on you since ",
            "failed": "failed at ",
            "done": "finished at ",
            "working": "working since ",
            "idle": "idle since "
        }[session.state] + at;
    }

    function ago(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "now" : m < 60 ? m + "m" : Math.floor(m / 60) + "h";
    }

    function select(index) {
        if (sessions.length)
            selectedId = sessions[Math.max(0, Math.min(sessions.length - 1, index))].id;
    }

    function dismiss(session) {
        if (session && finished(session))
            hub.dismiss(session.id);
    }

    function focusSession(session) {
        if (!session)
            return;
        hub.focusSession(session.id);
        closePopout();
    }

    Timer {
        interval: 15000
        running: root.active.length > 0
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
        return pillStates.map(state => {
            const rows = active.filter(s => s.state === state);
            return {
                "tone": rows.length ? tone(rows[0]) : "transparent",
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

    // The agent's logo from icons/, tinted; its name as text if the SVG is missing.
    component AgentIcon: Item {
        id: agentIcon

        required property string agent
        property real size: Theme.fontSizeSmall + 1

        implicitWidth: size
        implicitHeight: size

        Image {
            id: logo
            anchors.fill: parent
            visible: false
            source: root.iconDir + agentIcon.agent + ".svg"
            sourceSize: Qt.size(agentIcon.size * 2, agentIcon.size * 2)
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
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: logo.status === Image.Error
            text: agentIcon.agent
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    component SessionRow: Item {
        id: row

        required property var modelData
        required property int index
        readonly property var session: modelData
        readonly property bool isSelected: index === root.selectedIndex
        readonly property bool idle: session.state === "idle"
        readonly property string reason: root.reason(session)
        readonly property string cwd: Paths.shortenHome(session.cwd)
        readonly property color tone: root.tone(session)
        // A rule between the sessions that want you and the rest.
        readonly property bool divided: index > 0 && !root.wantsYou(session) && root.wantsYou(root.sessions[index - 1])
        readonly property real gap: divided ? Theme.spacingM : 0
        readonly property real iconBox: 20

        width: ListView.view.width
        height: gap + card.height

        Rectangle {
            visible: row.divided
            x: Theme.spacingS
            y: row.gap / 2
            width: parent.width - Theme.spacingS * 2
            height: 1
            color: Theme.outlineVariant
        }

        Rectangle {
            id: card

            y: row.gap
            width: parent.width
            height: body.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: row.isSelected ? Theme.surfaceContainerHigh : "transparent"
            clip: true

            Behavior on height {
                NumberAnimation {
                    duration: Theme.shortDuration
                    easing.type: Easing.OutCubic
                }
            }

            Rectangle {
                visible: row.isSelected
                x: 0
                y: Theme.spacingS
                width: 3
                height: parent.height - Theme.spacingS * 2
                radius: 1.5
                color: row.tone
            }

            // Hover only tints; the keyboard selection stays where it is.
            StateLayer {
                onClicked: root.focusSession(row.session)
            }

            Item {
                x: Theme.spacingM
                y: Theme.spacingS
                width: row.iconBox
                height: nameText.implicitHeight

                Dot {
                    anchors.centerIn: parent
                    visible: row.idle
                    size: 6
                    tone: Theme.withAlpha(Theme.surfaceVariantText, 0.6)
                }

                DSpinner {
                    anchors.centerIn: parent
                    visible: row.session.state === "working"
                    size: 15
                    strokeWidth: 2
                    color: row.tone
                }

                DIcon {
                    anchors.centerIn: parent
                    visible: !row.idle && row.session.state !== "working"
                    name: ({
                            "asking": "front_hand",
                            "needs-reply": "chat_bubble",
                            "failed": "error",
                            "done": "check_circle"
                        })[row.session.state] ?? ""
                    // Outlined, failed reads quieter than asking in the same red.
                    filled: row.session.state !== "failed"
                    size: 18
                    color: row.tone
                }
            }

            Column {
                id: body

                x: Theme.spacingM + row.iconBox + Theme.spacingS
                y: Theme.spacingS
                width: parent.width - x - Theme.spacingM
                spacing: 2

                Item {
                    width: parent.width
                    height: nameText.implicitHeight

                    StyledText {
                        id: nameText
                        width: parent.width - meta.width - Theme.spacingS
                        text: row.session.name || row.cwd.split("/").pop() || row.session.agent
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: row.idle ? Theme.surfaceVariantText : Theme.surfaceText
                    }

                    Row {
                        id: meta
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXS

                        AgentIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            agent: row.session.agent
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !row.idle
                            text: root.ago(row.session.since)
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.stale(row.session) ? Theme.error : Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: text !== ""
                    text: row.isSelected ? row.reason : row.reason || row.cwd
                    wrapMode: row.isSelected ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
                    maximumLineCount: row.isSelected ? 4 : 1
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeSmall
                    color: row.session.state === "asking" || row.session.state === "needs-reply" ? Theme.surfaceText : Theme.surfaceVariantText
                }

                StyledText {
                    width: parent.width
                    visible: row.isSelected
                    text: [row.cwd, root.stateWords(row.session)].filter(t => t).join(" · ")
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
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

            implicitHeight: root.sessions.length ? list.height : empty.implicitHeight
            focus: true

            function grab() {
                Qt.callLater(() => pop.forceActiveFocus());
            }

            Component.onCompleted: grab()

            // PluginPopout focuses its own container whenever it shows; take the keys back.
            onActiveFocusChanged: {
                if (!activeFocus && parentPopout?.shouldBeVisible)
                    grab();
            }

            Connections {
                target: pop.parentPopout
                function onOpened() {
                    root.nowMs = Date.now();
                    root.selectedId = "";
                    list.positionViewAtBeginning();
                    pop.grab();
                }
            }

            Connections {
                target: root
                function onSelectedIndexChanged() {
                    Qt.callLater(() => list.revealIndex(root.selectedIndex));
                }
            }

            Keys.onPressed: event => {
                if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                    return;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    root.focusSession(root.selected);
                else if (event.key === Qt.Key_X)
                    root.dismiss(root.selected);
                else if (event.key === Qt.Key_J || event.key === Qt.Key_Down)
                    root.select(root.selectedIndex + 1);
                else if (event.key === Qt.Key_K || event.key === Qt.Key_Up)
                    root.select(root.selectedIndex - 1);
                else if (event.key === Qt.Key_Home || event.text === "g")
                    root.select(0);
                else if (event.key === Qt.Key_End || event.text === "G")
                    root.select(root.sessions.length - 1);
                else
                    return;
                event.accepted = true;
            }

            StyledText {
                id: empty
                width: parent.width
                visible: !root.sessions.length
                topPadding: Theme.spacingM
                bottomPadding: Theme.spacingM
                horizontalAlignment: Text.AlignHCenter
                text: root.linkUp ? "No agent sessions." : "The agent-hub service is not running."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }

            DListView {
                id: list
                width: parent.width
                height: Math.min(contentHeight, Screen.height * 0.6)
                visible: root.sessions.length > 0
                interactive: contentHeight > height
                spacing: 2
                model: root.sessions
                delegate: SessionRow {}
            }
        }
    }
}
