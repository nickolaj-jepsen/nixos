// Bar pill: a dot per session that wants you, in the hub's order, then a ring per working
// one. Something new bursts, a prompt also peeks its name, and it breathes until you look.
// Popout: one list of every session, by what it is. Keys act on the selection: Enter opens
// it, x dismisses, u undoes the last dismissal, j/k move, g/G jump to the ends.
import QtQuick
import QtQuick.Effects
import Quickshell
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
    readonly property var idleRows: sessions.filter(s => s.state === "idle")
    // The list: the hub's order.
    readonly property var rows: active.concat(idleRows)
    readonly property int maxDots: 6
    // A session left waiting on you this long has its age turn red.
    readonly property int staleSeconds: 900
    readonly property var pillGroups: [["asking"], ["failed"], ["done"], ["working"]]

    property string selectedId: ""
    property real nowMs: Date.now()

    readonly property int selectedIndex: {
        const at = rows.findIndex(s => s.id === selectedId);
        return at >= 0 ? at : 0;
    }
    readonly property var selected: rows[selectedIndex] ?? null

    // One height whatever it holds, known before it first opens: the popout never resizes.
    readonly property real contentHeightFixed: Math.min((parentScreen?.height ?? 1080) * 0.6, 620)
    popoutHeight: contentHeightFixed + PopoutMetrics.contentPadding * 2

    // The row the pointer is settling on, and where it last was: a hover counts only when the
    // pointer itself moved, never when a row moved under it.
    property string hoverTarget: ""
    property real pointerX: -1
    property real pointerY: -1
    // Whether the pointer has been heard since the popout opened: the popout can open under a
    // resting pointer, and hearing where that rests isn't the pointer moving.
    property bool pointerHeard: false

    function hoverRow(id, point) {
        const moved = pointerHeard && (point.x !== pointerX || point.y !== pointerY);
        pointerHeard = true;
        pointerX = point.x;
        pointerY = point.y;
        if (!moved)
            return;
        hoverTarget = id;
        hoverTimer.restart();
    }

    Timer {
        id: hoverTimer
        interval: 120
        onTriggered: root.selectedId = root.hoverTarget
    }

    // What was just dismissed, offered back for a moment.
    property string undoName: ""

    Timer {
        id: undoTimer
        interval: 8000
        onTriggered: root.undoName = ""
    }

    // The key legend, for whoever came by keyboard.
    property bool legendShown: false
    property bool pillHovered: false

    // Which rows pulsed at the last state, null until one has come in on this connection.
    property var announced: null
    // The animations live here: a state from the hub rebuilds the pill's dots.
    property var burstIds: ({})
    property real burstProgress: 0
    property real breath: 1
    property bool peekOpen: false
    property string peekText: ""
    property string peekId: ""
    readonly property bool anyPulse: sessions.some(s => s.pulse === true)

    _visibilityOverride: true
    _visibilityOverrideValue: active.length > 0 || !linkUp

    onSessionsChanged: announce()
    Component.onCompleted: announce()

    // Bursts what started pulsing since the last state, and peeks the first new prompt.
    function announce() {
        if (!(hub?.linkUp ?? false)) {
            announced = null;
            return;
        }
        const pulsing = {};
        sessions.filter(s => s.pulse === true).forEach(s => pulsing[s.id] = true);
        const fresh = announced === null ? [] : sessions.filter(s => pulsing[s.id] && !announced[s.id]);
        announced = pulsing;
        if (!fresh.length)
            return;
        const ids = {};
        fresh.forEach(s => ids[s.id] = true);
        burstIds = ids;
        burst.restart();
        const ask = fresh.find(waits);
        if (ask) {
            peekText = [repoBeside(ask), shortName(ask)].filter(part => part).join(" · ") + " wants permission";
            peekId = ask.id;
            peekOpen = true;
            peekTimer.restart();
        }
    }

    NumberAnimation {
        id: burst
        target: root
        property: "burstProgress"
        from: 0
        to: 1
        duration: 700
        loops: 2
        easing.type: Easing.OutQuad
        onFinished: root.burstIds = ({})
    }

    SequentialAnimation on breath {
        running: root.anyPulse
        loops: Animation.Infinite
        alwaysRunToEnd: true

        NumberAnimation {
            to: 0.3
            duration: 1200
            easing.type: Easing.InOutSine
        }

        NumberAnimation {
            to: 1
            duration: 1200
            easing.type: Easing.InOutSine
        }
    }

    Timer {
        id: peekTimer
        interval: 4000
        onTriggered: root.peekOpen = false
    }

    Timer {
        interval: 15000
        running: root.active.length > 0
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    function waits(session) {
        return session.state === "asking";
    }

    function wantsYou(session) {
        return waits(session) || session.state === "failed" || session.state === "done";
    }

    // The heading a row goes under; 
    function sectionOf(index) {
        const row = rows[index];
        if (!row)
            return "";
        if (waits(row))
            return "Waiting on you";
        return {
            "failed": "Finished",
            "done": "Finished",
            "working": "Working",
            "idle": "Idle"
        }[row.state] ?? "";
    }

    function stale(session) {
        return waits(session) && (nowMs - session.since) / 1000 >= staleSeconds;
    }

    function tone(session) {
        return {
            "asking": Theme.warning,
            "failed": Theme.error,
            "done": Theme.success
        }[session.state] ?? Theme.surfaceVariantText;
    }

    function ago(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "now" : m < 60 ? m + "m" : m < 2880 ? Math.floor(m / 60) + "h" : Math.floor(m / 1440) + "d";
    }

    function displayName(session) {
        return session.name || folderName(session) || session.agent || "";
    }

    function folderName(session) {
        return Paths.shortenHome(session.cwd || "").split("/").pop() || "";
    }

    function repoName(session) {
        return session.project || folderName(session);
    }

    // The name, without what the repo beside it already says: `nixos-a0` reads `a0`.
    function shortName(session) {
        const name = displayName(session);
        const repo = repoName(session);
        return name.startsWith(repo + "-") ? name.slice(repo.length + 1) : name;
    }

    // The repo to show beside a name, unless that name is the repo.
    function repoBeside(session) {
        const repo = repoName(session);
        return shortName(session) === repo ? "" : repo;
    }

    // j/k and the ends.
    // How long something has been running; "now" would read as if it had just begun.
    function elapsed(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "under 1m" : m < 60 ? m + "m" : Math.floor(m / 60) + "h " + (m % 60) + "m";
    }

    // A row's second line: what it waits on, how its turn failed or ended, or that it is working, and for how long.
    function rowLine(session) {
        if (session.state === "working")
            return (session.doing || "working") + " · " + elapsed(session.since);
        return session.reason || "";
    }

    function select(index) {
        if (!rows.length)
            return;
        selectedId = rows[Math.max(0, Math.min(rows.length - 1, index))].id;
        hoverTimer.stop();
    }

    function dismiss(session) {
        if (!session || !wantsYou(session))
            return;
        // It leaves its section, so the selection goes to what took its place.
        if (session.id === selected?.id) {
            const next = rows[selectedIndex + 1] ?? rows[selectedIndex - 1];
            selectedId = next ? next.id : "";
        }
        hub.dismiss(session.id, session.turn);
        undoName = displayName(session);
        undoTimer.restart();
    }

    function undo() {
        hub?.undo();
        undoName = "";
    }

    function focusSession(session) {
        if (!session)
            return;
        hub.focusSession(session.id);
        closePopout();
    }

    // What it opens with. Set before it shows, so nothing changes on screen as it does.
    function prepareToOpen() {
        nowMs = Date.now();
        selectedId = "";
        undoName = "";
        legendShown = !pillHovered;
        pointerHeard = false;
        hoverTimer.stop();
    }

    // A filled dot, or a hollow ring. Its burst and breath are the same for every dot.
    component Dot: Item {
        id: dot

        required property color tone
        property real size: 8
        property bool ring: false
        property bool pulse: false
        property bool bursting: false
        readonly property real progress: bursting ? root.burstProgress : 0

        width: size
        height: size

        Rectangle {
            anchors.centerIn: parent
            visible: dot.bursting
            width: dot.size + 16 * dot.progress
            height: width
            radius: width / 2
            color: dot.tone
            opacity: 0.75 * (1 - dot.progress)
        }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: dot.ring ? "transparent" : dot.tone
            border.width: dot.ring ? 1.5 : 0
            border.color: dot.tone
            opacity: dot.pulse && !dot.bursting ? root.breath : 1
            scale: 1 + 0.35 * (dot.progress < 0.35 ? dot.progress / 0.35 : (1 - dot.progress) / 0.65)
        }
    }

    // Past maxDots the pill shows a count per group instead of one dot per session.
    readonly property var pillItems: {
        if (active.length <= maxDots)
            return active.map(s => ({
                        "tone": tone(s),
                        "count": 0,
                        "ring": s.state === "working",
                        "pulse": s.pulse === true,
                        "ids": [s.id]
                    }));
        return pillGroups.map(states => {
            const members = active.filter(s => states.includes(s.state));
            return {
                "tone": members.length ? tone(members[0]) : "transparent",
                "count": members.length,
                "ring": states[0] === "working",
                "pulse": members.some(s => s.pulse === true),
                "ids": members.map(s => s.id)
            };
        }).filter(item => item.count > 0);
    }
    readonly property var dotItems: pillItems.filter(item => !item.ring)
    readonly property var ringItems: pillItems.filter(item => item.ring)

    component PillItem: Row {
        required property var modelData
        required property var widget
        spacing: 3

        Dot {
            anchors.verticalCenter: parent.verticalCenter
            tone: parent.modelData.tone
            ring: parent.modelData.ring
            pulse: parent.modelData.pulse
            bursting: parent.modelData.ids.some(id => root.burstIds[id])
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

            // A popout opened while the pointer is off the pill came from the keyboard.
            HoverHandler {
                margin: 10
                onHoveredChanged: root.pillHovered = hovered
            }

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.linkUp
                name: "link_off"
                size: root.iconSize
                color: Theme.surfaceVariantText
            }

            Rectangle {
                id: peek

                anchors.verticalCenter: parent.verticalCenter
                visible: width > 0
                width: root.peekOpen ? peekLabel.width + 16 : 0
                height: peekLabel.implicitHeight + 4
                radius: 6
                clip: true
                opacity: root.peekOpen ? 1 : 0
                color: Theme.withAlpha(Theme.warning, 0.24)

                Behavior on width {
                    NumberAnimation {
                        duration: 400
                        easing.type: Easing.OutCubic
                    }
                }

                Behavior on opacity {
                    NumberAnimation {
                        duration: 250
                    }
                }

                StyledText {
                    id: peekLabel
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, 260)
                    text: root.peekText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }

                // It names one session, so a click goes straight to it.
                MouseArea {
                    anchors.fill: parent
                    enabled: root.peekOpen
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.peekOpen = false;
                        root.hub?.focusSession(root.peekId);
                    }
                }
            }

            Repeater {
                model: root.dotItems

                PillItem {
                    anchors.verticalCenter: parent.verticalCenter
                    widget: root
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.dotItems.length > 0 && root.ringItems.length > 0
                width: 1
                height: 12
                color: Theme.outlineVariant
            }

            Repeater {
                model: root.ringItems

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

            HoverHandler {
                margin: 10
                onHoveredChanged: root.pillHovered = hovered
            }

            DIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !root.linkUp
                name: "link_off"
                size: root.iconSize
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: root.dotItems

                PillItem {
                    anchors.horizontalCenter: parent.horizontalCenter
                    widget: root
                }
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.dotItems.length > 0 && root.ringItems.length > 0
                width: 12
                height: 1
                color: Theme.outlineVariant
            }

            Repeater {
                model: root.ringItems

                PillItem {
                    anchors.horizontalCenter: parent.horizontalCenter
                    widget: root
                }
            }
        }
    }

    // pi's or Claude's mark, quiet beside a name.
    component AgentIcon: Item {
        id: agentIcon

        required property string agent
        property real size: 11

        width: size
        height: size

        Image {
            id: logo
            anchors.fill: parent
            visible: false
            source: Qt.resolvedUrl("icons/" + (agentIcon.agent === "pi" ? "pi" : "claude") + ".svg")
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
    }

    component OneLine: StyledText {
        textFormat: Text.PlainText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    component SectionLabel: StyledText {
        textFormat: Text.PlainText
        font.pixelSize: Theme.fontSizeSmall
        font.weight: Font.Medium
        color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
    }

    // The dot or spinner a row leads with.
    component RowMark: Item {
        id: mark

        required property var session

        width: 14
        height: 14

        DSpinner {
            anchors.centerIn: parent
            visible: mark.session.state === "working"
            size: 13
            strokeWidth: 2
            color: Theme.surfaceVariantText
        }

        Rectangle {
            anchors.centerIn: parent
            visible: mark.session.state !== "working"
            readonly property bool quiet: mark.session.state === "idle"
            width: quiet ? 6 : 9
            height: width
            radius: width / 2
            color: quiet ? Theme.withAlpha(Theme.surfaceVariantText, 0.5) : root.tone(mark.session)
        }
    }

    component IconButton: Rectangle {
        id: iconButton

        required property string icon
        required property string tip

        signal clicked

        width: 26
        height: 26
        radius: 6
        color: "transparent"

        DIcon {
            anchors.centerIn: parent
            name: iconButton.icon
            size: 15
            color: Theme.surfaceVariantText
        }

        StateLayer {
            tooltipText: iconButton.tip
            onClicked: iconButton.clicked()
        }
    }

    component KeyCap: Rectangle {
        id: cap

        required property string key

        width: capLabel.implicitWidth + 10
        height: capLabel.implicitHeight + 2
        radius: 4
        color: Theme.withAlpha(Theme.surfaceText, 0.12)

        StyledText {
            id: capLabel
            anchors.centerIn: parent
            text: cap.key
            font.family: Theme.monoFontFamily
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceText
        }
    }

    component KeyHint: Row {
        id: hint

        required property string key
        required property string label

        spacing: 5

        KeyCap {
            anchors.verticalCenter: parent.verticalCenter
            key: hint.key
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: hint.label
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
        }
    }

    // A session in the list: two lines, or one when it is resting.
    component SessionRow: Column {
        id: row

        required property var modelData
        required property int index
        readonly property var session: modelData
        readonly property bool isSelected: index === root.selectedIndex
        readonly property bool slim: session.state === "idle"
        readonly property string section: root.sectionOf(index)
        readonly property bool headed: section !== "" && (index === 0 || root.sectionOf(index - 1) !== section)
        readonly property string line: slim ? "" : root.rowLine(session)

        width: parent.width

        SectionLabel {
            visible: row.headed
            x: Theme.spacingS
            topPadding: row.index === 0 ? Theme.spacingXS : Theme.spacingM
            bottomPadding: Theme.spacingXS
            text: row.section
            color: row.section === "Waiting on you" ? Theme.warning : Theme.withAlpha(Theme.surfaceVariantText, 0.8)
        }

        Rectangle {
            width: parent.width
            height: row.slim ? 32 : 52
            radius: Theme.cornerRadius
            color: row.isSelected ? Theme.surfaceContainerHigh : "transparent"

            Behavior on color {
                ColorAnimation {
                    duration: 90
                }
            }

            HoverHandler {
                id: rowHover
            }

            StateLayer {
                onPositionChanged: mouse => root.hoverRow(row.session.id, mapToGlobal(mouse.x, mouse.y))
                onClicked: root.focusSession(row.session)
            }

            RowMark {
                x: Theme.spacingS + 2
                anchors.verticalCenter: parent.verticalCenter
                session: row.session
            }

            Column {
                x: Theme.spacingS + 2 + 14 + Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                width: rightSide.x - x - Theme.spacingS
                spacing: 2

                Item {
                    width: parent.width
                    height: firstLine.implicitHeight

                    Row {
                        id: firstLine

                        width: parent.width - repoText.width - 8
                        spacing: 6

                        OneLine {
                            id: nameText
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, parent.width - hostChip.width - 6)
                            text: root.shortName(row.session)
                            font.pixelSize: row.slim ? Theme.fontSizeSmall + 1 : Theme.fontSizeMedium
                            font.weight: root.waits(row.session) ? Font.DemiBold : row.slim ? Font.Normal : Font.Medium
                            color: row.slim ? Theme.surfaceVariantText : Theme.surfaceText
                        }

                        Rectangle {
                            id: hostChip
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !!row.session.host
                            width: visible ? hostLabel.implicitWidth + 10 : 0
                            height: hostLabel.implicitHeight + 2
                            radius: 4
                            color: Theme.withAlpha(Theme.surfaceText, 0.1)

                            OneLine {
                                id: hostLabel
                                anchors.centerIn: parent
                                text: row.session.host ?? ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                            }
                        }
                    }

                    // Against the right edge, so names and repos each line up whatever their lengths.
                    OneLine {
                        id: repoText
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width * 0.4)
                        text: root.repoBeside(row.session)
                        font.pixelSize: nameText.font.pixelSize
                        font.weight: row.slim ? Font.Normal : Font.Medium
                        color: row.slim ? Theme.withAlpha(Theme.surfaceVariantText, 0.8) : Theme.surfaceVariantText
                    }
                }

                OneLine {
                    width: parent.width
                    visible: row.line !== ""
                    text: row.line
                    color: root.waits(row.session) ? Theme.surfaceText : Theme.surfaceVariantText
                }
            }

            // Wide enough for its buttons at all times, so the text beside it never reflows on hover.
            Item {
                id: rightSide

                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                width: 54
                height: 26

                AgentIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: rowAge.visible
                    opacity: 0.7
                    agent: row.session.agent ?? ""
                }

                StyledText {
                    id: rowAge
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !(rowHover.hovered && rowActions.visibleCount > 0)
                    text: root.ago(row.session.since)
                    font.pixelSize: Theme.fontSizeSmall
                    color: root.stale(row.session) ? Theme.error : Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                }

                Row {
                    id: rowActions

                    readonly property int visibleCount: dismissButton.visible ? 1 : 0

                    anchors.right: parent.right
                    visible: rowHover.hovered
                    spacing: 2

                    IconButton {
                        id: dismissButton
                        visible: root.wantsYou(row.session)
                        icon: "close"
                        tip: "Dismiss"
                        onClicked: root.dismiss(row.session)
                    }
                }
            }
        }
    }

    popoutWidth: 420

    popoutContent: Component {
        FocusScope {
            id: pop

            property var parentPopout: null
            property var closePopout: null

            implicitHeight: root.contentHeightFixed
            focus: true

            function grab() {
                Qt.callLater(() => pop.forceActiveFocus());
            }

            Component.onCompleted: {
                root.prepareToOpen();
                grab();
            }

            // PluginPopout focuses its own container whenever it shows; take the keys back.
            onActiveFocusChanged: {
                if (!activeFocus && parentPopout?.shouldBeVisible)
                    grab();
            }

            Connections {
                target: pop.parentPopout
                function onShouldBeVisibleChanged() {
                    if (pop.parentPopout.shouldBeVisible) {
                        root.prepareToOpen();
                        list.positionViewAtBeginning();
                    }
                }
                function onOpened() {
                    root.hub?.seen();
                    pop.grab();
                }
            }

            // Only the keyboard scrolls the list: a row you are pointing at is already in view.
            function reveal() {
                if (root.selectedIndex >= 0)
                    list.revealIndex(root.selectedIndex);
            }

            Keys.onPressed: event => {
                if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                    return;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    root.focusSession(root.selected);
                else if (event.key === Qt.Key_X)
                    root.dismiss(root.selected);
                else if (event.key === Qt.Key_U)
                    root.undo();
                else if (event.key === Qt.Key_J || event.key === Qt.Key_Down)
                    root.select(root.selectedIndex + 1);
                else if (event.key === Qt.Key_K || event.key === Qt.Key_Up)
                    root.select(root.selectedIndex - 1);
                else if (event.key === Qt.Key_Home || event.text === "g")
                    root.select(0);
                else if (event.key === Qt.Key_End || event.text === "G")
                    root.select(root.rows.length - 1);
                else
                    return;
                root.legendShown = true;
                Qt.callLater(pop.reveal);
                event.accepted = true;
            }

            StyledText {
                anchors.centerIn: parent
                visible: !root.rows.length
                text: root.linkUp ? "No agent sessions." : root.hub?.refused || "The agent-hub service is not running."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }

            Item {
                id: panes

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                // The legend's room is kept whether it shows or not, so the buttons never shift.
                anchors.bottom: undoNote.visible ? undoNote.top : legend.top
                visible: root.rows.length > 0

                Column {
                    id: leftColumn

                    width: parent.width
                    height: parent.height

                    OneLine {
                        id: linkLine
                        width: parent.width
                        visible: text !== ""
                        bottomPadding: Theme.spacingXS
                        text: (root.hub?.links ?? []).filter(l => l.status !== "up").map(l => l.host + ": " + l.status).join(" · ")
                    }

                    DListView {
                        id: list

                        width: parent.width
                        height: parent.height - (linkLine.visible ? linkLine.height : 0)
                        clip: true
                        spacing: 2
                        // Keyed, so a new state from the hub updates rows in place instead of
                        // rebuilding them, which lost the hover and the scroll position.
                        model: ScriptModel {
                            objectProp: "id"
                            values: root.rows
                        }

                        // No displaced or move transition: a view transition parks the positions the
                        // view writes while it runs, so order changes faster than it lasts stack rows.

                        delegate: Column {
                            id: rowSlot

                            required property var modelData
                            required property int index

                            width: ListView.view.width - Theme.spacingS

                            SessionRow {
                                                modelData: rowSlot.modelData
                                index: rowSlot.index
                            }
                        }
                    }
                }
            }

            // What was just dismissed, offered back for a moment.
            Rectangle {
                id: undoNote

                anchors.bottom: legend.top
                width: parent.width
                height: 34
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh
                visible: root.undoName !== ""

                OneLine {
                    x: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - x - Theme.spacingM * 2 - undoButton.width
                    text: "Dismissed " + root.undoName
                    color: Theme.surfaceText
                }

                Rectangle {
                    id: undoButton
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: undoLabel.implicitWidth + 16
                    height: 26
                    radius: 6
                    color: Theme.withAlpha(Theme.surfaceText, 0.1)

                    StyledText {
                        id: undoLabel
                        anchors.centerIn: parent
                        text: "Undo"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StateLayer {
                        onClicked: root.undo()
                    }
                }
            }

            Row {
                id: legend

                anchors.bottom: parent.bottom
                x: Theme.spacingS
                topPadding: Theme.spacingS
                visible: root.rows.length > 0
                opacity: root.legendShown ? 1 : 0
                spacing: Theme.spacingL

                Behavior on opacity {
                    NumberAnimation {
                        duration: 150
                    }
                }

                KeyHint {
                    key: "u"
                    label: "undo"
                }

                KeyHint {
                    key: "j k"
                    label: "move"
                }
            }
        }
    }
}
