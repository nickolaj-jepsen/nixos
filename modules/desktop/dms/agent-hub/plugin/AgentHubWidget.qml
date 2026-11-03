// Bar pill: a dot per session that wants you, in the hub's order, then a ring per working
// one. Something new bursts, an ask also peeks its name, and it breathes until you look.
// Popout: every session on the left, by what it is, and on the right everything about the
// selected one, which is whatever you last hovered or moved to. Nothing moves under the
// pointer. Keys act on the selection: Enter opens it (or resumes an ended one in a new
// terminal), x dismisses, w logs its verdict as wrong, u undoes the last dismissal, a and d
// answer its prompt, j/k move, g/G jump to the ends.
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
    readonly property int maxRecent: 5
    readonly property var endedRows: (hub?.recent ?? []).slice(0, maxRecent).map(r => ({
                "id": r.id,
                "agent": r.agent,
                "name": r.label,
                "cwd": r.cwd,
                "reason": r.summary,
                "state": "ended",
                "host": r.host,
                "since": r.endedAt,
                "history": r.history
            }))
    readonly property var foldRow: endedRows.length ? [
        {
            "id": "fold:ended",
            "fold": true,
            "state": "fold",
            "members": endedRows
        }
    ] : []
    // The list: the hub's order, then what ended behind its heading.
    readonly property var rows: active.concat(idleRows, foldRow, endedOpen ? endedRows : [])
    readonly property int maxDots: 6
    // A session left waiting on you this long has its age turn red.
    readonly property int staleSeconds: 900
    // A working session silent this long has its last activity turn amber: a hint, not a verdict.
    readonly property int quietSeconds: 300
    readonly property var pillGroups: [["asking", "needs-reply"], ["failed"], ["done"], ["working"]]

    property string selectedId: ""
    // The row `w` flagged last, until the popout next opens: the only sign the key worked.
    property string flaggedId: ""
    property bool endedOpen: false
    property real nowMs: Date.now()

    readonly property int selectedIndex: {
        const at = rows.findIndex(s => s.id === selectedId);
        return at >= 0 ? at : rows.findIndex(s => !s.fold);
    }
    readonly property var selected: rows[selectedIndex] ?? null
    readonly property var permission: selected?.permission ?? null

    // What the pane shows: a new one keeps Allow and Deny off long enough to read what they'd answer.
    readonly property string paneKey: (selected?.id ?? "") + ":" + (permission?.id ?? "")
    property bool armed: true
    onPaneKeyChanged: {
        disarm();
        paneFade.restart();
    }

    function disarm() {
        armed = false;
        armTimer.restart();
    }

    // The pane changes what it says in place, so a soft fade is all the motion it needs.
    property real paneOpacity: 1

    NumberAnimation {
        id: paneFade
        target: root
        property: "paneOpacity"
        from: 0.55
        to: 1
        duration: 130
        easing.type: Easing.OutCubic
    }

    // One height whatever it holds, known before it first opens: the popout never resizes.
    readonly property real contentHeightFixed: Math.min((parentScreen?.height ?? 1080) * 0.6, 620)
    popoutHeight: contentHeightFixed + PopoutMetrics.contentPadding * 2

    Timer {
        id: armTimer
        interval: 500
        onTriggered: root.armed = true
    }

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

    // What was just dismissed, offered back for a moment; and what a menu just copied.
    property string undoName: ""
    property string noteText: ""

    function note(text) {
        noteText = text;
        noteTimer.restart();
    }

    Timer {
        id: undoTimer
        interval: 8000
        onTriggered: root.undoName = ""
    }

    Timer {
        id: noteTimer
        interval: 3000
        onTriggered: root.noteText = ""
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

    // Bursts what started pulsing since the last state, and peeks the first new ask.
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
            peekText = displayName(ask) + (ask.state === "asking" ? " wants permission" : " asks");
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
        return session.state === "asking" || session.state === "needs-reply";
    }

    function wantsYou(session) {
        return waits(session) || session.state === "failed" || session.state === "done";
    }

    function finished(session) {
        return ["needs-reply", "failed", "done"].includes(session.state);
    }

    // The heading a row goes under; what ended sits under its own fold.
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
            "needs-reply": Theme.warning,
            "failed": Theme.error,
            "done": Theme.success
        }[session.state] ?? Theme.surfaceVariantText;
    }

    function ago(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "now" : m < 60 ? m + "m" : m < 2880 ? Math.floor(m / 60) + "h" : Math.floor(m / 1440) + "d";
    }

    // The pane's heading words: what it is doing, and for how long.
    function stateWords(session) {
        const word = {
            "asking": "waiting",
            "needs-reply": "waiting",
            "failed": "failed",
            "done": "finished",
            "working": "working",
            "idle": "idle",
            "ended": "ended"
        }[session.state] ?? "";
        const age = ago(session.since);
        return age === "now" ? word + " just now" : word + " " + age;
    }

    function displayName(session) {
        return session.name || folderName(session) || session.agent || "";
    }

    function folderName(session) {
        return Paths.shortenHome(session.cwd || "").split("/").pop() || "";
    }

    // How long something has been running; "now" would read as if it had just begun.
    function elapsed(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "under 1m" : m < 60 ? m + "m" : Math.floor(m / 60) + "h " + (m % 60) + "m";
    }

    function nowLine(session) {
        if (!session.now)
            return "";
        const line = session.now + " · " + elapsed(session.nowAt);
        const guess = estimateWords(session);
        return guess ? line + " · " + guess : line;
    }

    // A model's guess at a long command, always worded as one, counted down from when it was made.
    function estimateWords(session) {
        const estimate = session.estimate;
        if (!estimate)
            return "";
        const parts = [];
        if (estimate.left !== null) {
            const left = Math.ceil(estimate.left - (nowMs - estimate.at) / 60000);
            parts.push(left > 0 ? "est. " + left + "m left" : "past its estimate");
        }
        if (estimate.note)
            parts.push(estimate.note);
        return parts.join(", ");
    }

    // This turn's tally, leaving out what hasn't happened.
    function countsLine(session) {
        const counts = session.counts;
        if (!counts)
            return "";
        const part = (n, word) => n ? n + " " + word + (n === 1 ? "" : "s") : "";
        const parts = [part(counts.edits, "edit"), part(counts.commands, "command"), counts.failed ? counts.failed + " failed" : ""];
        return parts.filter(text => text).join(", ");
    }

    // A running turn's narration, oldest first, as a pane's lines read.
    function trailLines(session) {
        if (session?.state !== "working")
            return [];
        return (session.trail ?? []).slice(-6).map(step => ({
                    "did": step.text,
                    "at": step.at,
                    "state": "working"
                }));
    }

    // A row's second line: what is running, its ask or step, or else its folder when the name doesn't already say it.
    function rowLine(session) {
        if (session.state === "working" && session.now)
            return nowLine(session);
        const said = session.reason || "";
        if (said)
            return said;
        const folder = folderName(session);
        return displayName(session).includes(folder) ? "" : folder;
    }

    // j/k and the ends. Landing on the fold goes through it, which opens it on the way down.
    function select(index) {
        if (!rows.length)
            return;
        const at = Math.max(0, Math.min(rows.length - 1, index));
        const row = rows[at];
        if (row.fold) {
            if (at > selectedIndex) {
                endedOpen = true;
                selectedId = row.members[0].id;
            } else if (at > 0) {
                selectedId = rows[at - 1].id;
            }
        } else {
            selectedId = row.id;
        }
        hoverTimer.stop();
    }

    function dismiss(session) {
        if (!session || !wantsYou(session))
            return;
        // It leaves its section, so the selection goes to what took its place.
        if (session.id === selected?.id) {
            const next = rows[selectedIndex + 1] ?? rows[selectedIndex - 1];
            selectedId = next && !next.fold ? next.id : "";
        }
        hub.dismiss(session.id, session.turn);
        undoName = displayName(session);
        undoTimer.restart();
    }

    function undo() {
        hub?.undo();
        undoName = "";
    }

    // A row on another host that Enter can't reach, and why it says so.
    function unreachable(session) {
        return !!session.host && session.state !== "ended" && !session.tmux && !session.bridge;
    }

    function flagWrong(session) {
        if (session && finished(session)) {
            hub.wrong(session.id);
            flaggedId = session.id;
        }
    }

    function focusSession(session) {
        if (!session || session.fold)
            return;
        if (session.state === "ended")
            hub.resume(session.id);
        else
            hub.focusSession(session.id);
        closePopout();
    }

    // Only while the pane has shown this prompt long enough to be read, and only all of it.
    function answer(allow) {
        if (!permission || !armed || (allow && !permission.complete))
            return;
        hub.answer(selected.id, permission.id, allow);
        // It moves down to Working, so the highlight stays put on whatever waits next.
        const next = rows[selectedIndex + 1];
        if (next && waits(next))
            selectedId = next.id;
    }

    // What it opens with. Set before it shows, so nothing changes on screen as it does.
    function prepareToOpen() {
        nowMs = Date.now();
        hub?.closeMenu();
        selectedId = "";
        flaggedId = "";
        endedOpen = false;
        undoName = "";
        noteText = "";
        legendShown = !pillHovered;
        pointerHeard = false;
        hoverTimer.stop();
        disarm();
    }

    function runMenuRow(row) {
        const action = row.run;
        if (!action)
            return;
        hub.run(selected.id, action);
        hub.closeMenu();
        if (action.kind === "copy")
            note("Copied");
        else
            closePopout();
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
                    width: Math.min(implicitWidth, 204)
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

    // Someone else's words: never read as markup, which could hide what a command says.
    component PaneText: StyledText {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        font.pixelSize: Theme.fontSizeSmall + 1
        color: Theme.surfaceText
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
            readonly property bool quiet: mark.session.state === "idle" || mark.session.state === "ended"
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

    component PaneButton: Rectangle {
        id: button

        required property string label
        property string kind: "plain"

        signal clicked

        width: buttonLabel.implicitWidth + Theme.spacingM * 2
        height: 34
        radius: Theme.cornerRadius
        color: kind === "open" ? Theme.primaryContainer : kind === "allow" ? Theme.withAlpha(Theme.success, 0.32) : "transparent"
        border.width: kind === "plain" ? 1 : 0
        border.color: Theme.outline
        opacity: enabled ? 1 : 0.4

        Behavior on opacity {
            NumberAnimation {
                duration: 120
            }
        }

        StyledText {
            id: buttonLabel
            anchors.centerIn: parent
            text: button.label
            font.pixelSize: Theme.fontSizeSmall + 1
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StateLayer {
            onClicked: button.clicked()
        }
    }

    // An icon and a word in the pane's quiet bottom row, which says the rest when hovered.
    component MetaChip: Rectangle {
        id: chip

        required property string icon
        required property string label
        required property string tip
        property bool clickable: false
        property color tint: Theme.surfaceVariantText
        property real maxLabel: 160

        signal clicked

        width: chipRow.implicitWidth + 8
        height: 22
        radius: 5
        color: "transparent"

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 4

            DIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: chip.icon
                size: 13
                color: chip.tint
            }

            OneLine {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, chip.maxLabel)
                visible: chip.label !== ""
                text: chip.label
                color: chip.tint
            }
        }

        StateLayer {
            tooltipText: chip.tip
            tooltipSide: "top"
            cursorShape: chip.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
            enableRipple: chip.clickable
            stateColor: chip.clickable ? Theme.surfaceText : "transparent"
            onClicked: chip.clicked()
        }
    }

    component KeyHint: Row {
        required property string key
        required property string label

        spacing: 5

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: keyLabel.implicitWidth + 10
            height: keyLabel.implicitHeight + 2
            radius: 4
            color: Theme.withAlpha(Theme.surfaceText, 0.12)

            StyledText {
                id: keyLabel
                anchors.centerIn: parent
                text: parent.parent.key
                font.family: Theme.monoFontFamily
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.label
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
        readonly property bool slim: session.state === "idle" || session.state === "ended"
        readonly property string section: root.sectionOf(index)
        readonly property bool headed: section !== "" && (index === 0 || root.sectionOf(index - 1) !== section)
        readonly property string line: slim ? "" : root.rowLine(session)
        readonly property bool working: session.state === "working"

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
            // A working row keeps room for its tally, so the first edit moves nothing under the pointer.
            height: row.slim ? 32 : row.working ? 68 : 52
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

                Row {
                    width: parent.width
                    spacing: 6

                    OneLine {
                        id: nameText
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width - agentMark.width - hostChip.width - kindChip.width - 18)
                        text: root.displayName(row.session)
                        font.pixelSize: row.slim ? Theme.fontSizeSmall + 1 : Theme.fontSizeMedium
                        font.weight: root.waits(row.session) ? Font.DemiBold : row.slim ? Font.Normal : Font.Medium
                        color: row.slim ? Theme.surfaceVariantText : Theme.surfaceText
                    }

                    AgentIcon {
                        id: agentMark
                        anchors.verticalCenter: parent.verticalCenter
                        agent: row.session.agent ?? ""
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

                    // What it wants of you, for a row that needs a reply.
                    Rectangle {
                        id: kindChip
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.session.state === "needs-reply" && !!row.session.askKind
                        width: visible ? kindLabel.implicitWidth + 10 : 0
                        height: kindLabel.implicitHeight + 2
                        radius: 4
                        color: Theme.withAlpha(Theme.warning, 0.15)

                        OneLine {
                            id: kindLabel
                            anchors.centerIn: parent
                            text: row.session.askKind ?? ""
                            color: Theme.warning
                            font.pixelSize: Theme.fontSizeSmall - 1
                        }
                    }
                }

                OneLine {
                    width: parent.width
                    visible: row.line !== ""
                    text: row.line
                }

                OneLine {
                    width: parent.width
                    visible: row.working && text !== ""
                    text: row.working ? root.countsLine(row.session) : ""
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                    font.pixelSize: Theme.fontSizeSmall - 1
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

                    readonly property int visibleCount: (flagButton.visible ? 1 : 0) + (dismissButton.visible ? 1 : 0)

                    anchors.right: parent.right
                    visible: rowHover.hovered
                    spacing: 2

                    IconButton {
                        id: flagButton
                        visible: root.finished(row.session)
                        icon: "flag"
                        tip: "Flag as a wrong call"
                        onClicked: root.flagWrong(row.session)
                    }

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

    // What ended: its heading, which a click opens, as it stays until the popout closes.
    component FoldRow: Rectangle {
        id: foldRow

        required property var members

        width: parent.width
        height: 32
        radius: Theme.cornerRadius
        color: "transparent"

        DIcon {
            id: chevron
            x: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            name: root.endedOpen ? "expand_more" : "chevron_right"
            size: 16
            color: Theme.surfaceVariantText
        }

        SectionLabel {
            anchors.left: chevron.right
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            text: "Ended · " + foldRow.members.length
        }

        StateLayer {
            onClicked: root.endedOpen = !root.endedOpen
        }
    }

    // The agent's request in full: a command as it would run, an edit as the lines it changes.
    component RequestBlock: Rectangle {
        id: request

        required property var ask

        width: parent.width
        height: requestBody.implicitHeight + Theme.spacingM * 2 - 4
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceText, 0.05)

        Column {
            id: requestBody

            x: Theme.spacingM
            y: Theme.spacingS
            width: parent.width - Theme.spacingM * 2
            spacing: 0

            Repeater {
                model: request.ask?.kind === "diff" ? request.ask.body.split("\n") : [request.ask?.body ?? ""]

                PaneText {
                    required property var modelData

                    text: modelData
                    wrapMode: Text.WrapAnywhere
                    font.family: Theme.monoFontFamily
                    font.pixelSize: Theme.fontSizeSmall
                    color: request.ask?.kind !== "diff" ? Theme.surfaceText : modelData.startsWith("- ") ? Theme.error : modelData.startsWith("+ ") ? Theme.success : Theme.surfaceText
                }
            }
        }
    }

    // A past turn, its mark and when.
    component TurnLine: Item {
        id: turn

        required property var modelData

        width: parent.width
        height: did.implicitHeight

        Rectangle {
            x: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 5
            height: 5
            radius: 2.5
            color: root.tone(turn.modelData)
        }

        OneLine {
            id: did
            x: 18
            width: parent.width - x - turnAge.width - Theme.spacingS
            text: turn.modelData.did
        }

        OneLine {
            id: turnAge
            anchors.right: parent.right
            text: root.ago(turn.modelData.at)
            color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
        }
    }

    // A line with a quiet icon where a label would be.
    component IconLine: Item {
        id: iconLine

        required property string icon
        required property string text
        property string tip: ""

        width: parent.width
        height: iconLineText.implicitHeight

        DIcon {
            id: iconMark
            y: 1
            name: iconLine.icon
            size: 15
            color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
        }

        PaneText {
            id: iconLineText
            x: 22
            width: parent.width - x
            text: iconLine.text
            color: Theme.surfaceVariantText
        }

        StateLayer {
            anchors.fill: iconMark
            tooltipText: iconLine.tip
            cursorShape: Qt.ArrowCursor
            enableRipple: false
            stateColor: "transparent"
        }
    }

    popoutWidth: 800

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

            Connections {
                target: root
                function onPaneKeyChanged() {
                    root.hub?.closeMenu();
                    paneScroll.contentY = 0;
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
                if (event.key === Qt.Key_Escape && root.hub?.menu) {
                    root.hub.closeMenu();
                    event.accepted = true;
                    return;
                }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                    root.focusSession(root.selected);
                else if (event.key === Qt.Key_X)
                    root.dismiss(root.selected);
                else if (event.key === Qt.Key_W)
                    root.flagWrong(root.selected);
                else if (event.key === Qt.Key_U)
                    root.undo();
                else if (event.key === Qt.Key_A)
                    root.answer(true);
                else if (event.key === Qt.Key_D)
                    root.answer(false);
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
                anchors.bottom: legend.top
                visible: root.rows.length > 0

                Column {
                    id: leftColumn

                    width: 310
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

                        // A session changing state slides to its new place.
                        displaced: Transition {
                            NumberAnimation {
                                properties: "y"
                                duration: 160
                                easing.type: Easing.OutCubic
                            }
                        }

                        move: Transition {
                            NumberAnimation {
                                properties: "y"
                                duration: 160
                                easing.type: Easing.OutCubic
                            }
                        }

                        delegate: Column {
                            id: rowSlot

                            required property var modelData
                            required property int index

                            width: ListView.view.width - Theme.spacingS

                            FoldRow {
                                visible: !!rowSlot.modelData.fold
                                members: rowSlot.modelData.members ?? []
                            }

                            SessionRow {
                                visible: !rowSlot.modelData.fold
                                modelData: rowSlot.modelData
                                index: rowSlot.index
                            }
                        }
                    }
                }

                Rectangle {
                    id: divider
                    x: leftColumn.width + Theme.spacingS
                    width: 1
                    height: parent.height
                    color: Theme.surfaceContainerHigh
                }

                Item {
                    id: pane

                    readonly property var session: root.selected && !root.selected.fold ? root.selected : null

                    anchors.left: divider.right
                    anchors.leftMargin: Theme.spacingL
                    anchors.right: parent.right
                    height: parent.height

                    // Passive, so it hears the pointer over the buttons too: a hover on its way
                    // here must not change what they would answer.
                    HoverHandler {
                        onHoveredChanged: {
                            if (hovered)
                                hoverTimer.stop();
                        }
                    }

                    Row {
                        id: paneHead

                        width: parent.width
                        height: 26
                        visible: pane.session !== null
                        opacity: root.paneOpacity
                        spacing: Theme.spacingS

                        OneLine {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, parent.width - paneIcon.width - paneAge.width - Theme.spacingS * 3)
                            text: pane.session ? root.displayName(pane.session) : ""
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                        }

                        AgentIcon {
                            id: paneIcon
                            anchors.verticalCenter: parent.verticalCenter
                            size: 13
                            agent: pane.session?.agent ?? ""
                        }

                        Item {
                            width: parent.width - x - paneAge.width - Theme.spacingS
                            height: 1
                        }

                        OneLine {
                            id: paneAge
                            anchors.verticalCenter: parent.verticalCenter
                            text: pane.session ? root.stateWords(pane.session) : ""
                            font.weight: Font.Medium
                            color: pane.session && root.stale(pane.session) ? Theme.error : Theme.surfaceVariantText
                        }
                    }

                    DFlickable {
                        id: paneScroll

                        anchors.top: paneHead.bottom
                        anchors.topMargin: Theme.spacingM
                        anchors.bottom: paneNotes.visible ? paneNotes.top : paneMeta.top
                        anchors.bottomMargin: Theme.spacingS
                        width: parent.width
                        clip: true
                        contentWidth: width
                        contentHeight: paneBody.implicitHeight
                        visible: pane.session !== null
                        opacity: root.paneOpacity

                        Column {
                            id: paneBody

                            width: paneScroll.width
                            spacing: Theme.spacingM

                            IconLine {
                                visible: !!pane.session?.prompt
                                icon: "person"
                                text: pane.session?.prompt ?? ""
                                tip: "What you last asked"
                            }

                            // What it wants permission for, in full when its hook is holding the prompt.
                            Column {
                                width: parent.width
                                visible: pane.session?.state === "asking"
                                spacing: Theme.spacingS

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingS
                                    visible: root.permission !== null

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: toolName.implicitWidth + 12
                                        height: toolName.implicitHeight + 2
                                        radius: 4
                                        color: Theme.withAlpha(Theme.surfaceText, 0.1)

                                        OneLine {
                                            id: toolName
                                            anchors.centerIn: parent
                                            text: root.permission?.tool ?? ""
                                            font.family: Theme.monoFontFamily
                                            color: Theme.surfaceText
                                        }
                                    }

                                    OneLine {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - x
                                        text: root.permission?.about ?? ""
                                    }
                                }

                                Loader {
                                    width: parent.width
                                    active: root.permission !== null
                                    visible: active
                                    sourceComponent: RequestBlock {
                                        ask: root.permission
                                    }
                                }

                                PaneText {
                                    visible: root.permission !== null && !root.permission.complete
                                    text: "Too long to show in full, so it can only be allowed in the session."
                                    color: Theme.warning
                                }

                                // pi's own prompts, and anything no hook is holding, come as one line.
                                Rectangle {
                                    width: parent.width
                                    visible: root.permission === null
                                    height: plainAsk.implicitHeight + Theme.spacingM * 2 - 4
                                    radius: Theme.cornerRadius
                                    color: Theme.withAlpha(Theme.surfaceText, 0.05)

                                    PaneText {
                                        id: plainAsk
                                        x: Theme.spacingM
                                        y: Theme.spacingS
                                        width: parent.width - Theme.spacingM * 2
                                        text: pane.session?.reason ?? ""
                                        wrapMode: Text.WrapAnywhere
                                        font.family: Theme.monoFontFamily
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            // The agent's own closing words, and what you'd most likely say back.
                            PaneText {
                                visible: pane.session?.state === "needs-reply"
                                text: pane.session?.said || pane.session?.reason || ""
                                font.pixelSize: Theme.fontSizeMedium
                            }

                            IconLine {
                                visible: pane.session?.state === "needs-reply" && !!pane.session?.reply
                                icon: "auto_awesome"
                                text: pane.session?.reply ?? ""
                                tip: "What you would probably say"
                            }

                            // A working session's trail has this line as its last.
                            PaneText {
                                visible: !!pane.session && !root.waits(pane.session) && text !== "" && root.trailLines(pane.session).length === 0
                                text: pane.session?.reason ?? ""
                                font.pixelSize: Theme.fontSizeMedium
                            }

                            // What it has said so far, then what is running now and the turn's tally.
                            Column {
                                width: parent.width
                                visible: root.trailLines(pane.session).length > 0
                                spacing: 5

                                Repeater {
                                    model: root.trailLines(pane.session)

                                    TurnLine {}
                                }
                            }

                            Item {
                                width: parent.width
                                height: nowText.implicitHeight
                                visible: pane.session?.state === "working" && !!pane.session?.now

                                DSpinner {
                                    anchors.verticalCenter: parent.verticalCenter
                                    size: 11
                                    strokeWidth: 2
                                    color: Theme.surfaceVariantText
                                }

                                OneLine {
                                    id: nowText
                                    x: 18
                                    width: parent.width - x
                                    text: pane.session ? root.nowLine(pane.session) : ""
                                    color: Theme.surfaceText
                                }
                            }

                            OneLine {
                                width: parent.width
                                visible: pane.session?.state === "working" && text !== ""
                                text: pane.session ? root.countsLine(pane.session) : ""
                                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                            }

                            Column {
                                width: parent.width
                                visible: (pane.session?.jobs ?? []).length > 0
                                spacing: 4

                                Repeater {
                                    model: pane.session?.jobs ?? []

                                    Item {
                                        required property var modelData

                                        width: parent.width
                                        height: jobText.implicitHeight

                                        DSpinner {
                                            anchors.verticalCenter: parent.verticalCenter
                                            size: 11
                                            strokeWidth: 2
                                            color: Theme.surfaceVariantText
                                        }

                                        OneLine {
                                            id: jobText
                                            x: 18
                                            width: parent.width - x
                                            text: parent.modelData
                                        }
                                    }
                                }
                            }

                            Column {
                                width: parent.width
                                visible: (pane.session?.history ?? []).length > 0
                                spacing: 5

                                Repeater {
                                    model: (pane.session?.history ?? []).slice(-3).reverse()

                                    TurnLine {}
                                }
                            }
                        }
                    }

                    // What only words can say, and what can be taken back.
                    Rectangle {
                        id: paneNotes

                        anchors.bottom: paneMeta.top
                        anchors.bottomMargin: Theme.spacingS
                        width: parent.width
                        height: 34
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh
                        visible: root.undoName !== "" || noteLine.text !== ""

                        OneLine {
                            id: noteLine
                            x: Theme.spacingM
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - x - Theme.spacingM * 2 - undoButton.width
                            text: {
                                if (root.undoName)
                                    return "Dismissed " + root.undoName;
                                if (root.noteText)
                                    return root.noteText;
                                if (pane.session && root.flaggedId === pane.session.id)
                                    return "Logged as a wrong call";
                                if (pane.session && root.unreachable(pane.session))
                                    return "No way to open it from here";
                                return "";
                            }
                            color: Theme.surfaceText
                        }

                        Rectangle {
                            id: undoButton
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.undoName !== ""
                            width: visible ? undoLabel.implicitWidth + 16 : 0
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

                    // Where it is: quiet, one line, and only what applies.
                    Row {
                        id: paneMeta

                        anchors.bottom: paneButtons.top
                        anchors.bottomMargin: Theme.spacingS
                        width: parent.width
                        visible: pane.session !== null
                        opacity: root.paneOpacity
                        spacing: 4

                        MetaChip {
                            id: folderChip
                            icon: "folder"
                            label: pane.session ? Paths.shortenHome(pane.session.cwd || "") : ""
                            tip: "Open this folder in another app"
                            clickable: true
                            maxLabel: 170
                            onClicked: {
                                menuBox.x = x;
                                root.hub?.openMenu(pane.session.id, "folder");
                            }
                        }

                        MetaChip {
                            id: branchChip
                            visible: !!pane.session?.branch
                            icon: "commit"
                            label: pane.session?.branch ?? ""
                            tip: "This branch on the web"
                            clickable: true
                            maxLabel: 120
                            onClicked: {
                                menuBox.x = x;
                                root.hub?.openMenu(pane.session.id, "git");
                            }
                        }

                        MetaChip {
                            visible: (pane.session?.changed ?? 0) > 0
                            icon: "edit"
                            label: String(pane.session?.changed ?? "")
                            tip: (pane.session?.changed ?? 0) + " files with uncommitted changes"
                        }

                        MetaChip {
                            visible: (pane.session?.peers ?? []).length > 0
                            icon: "group"
                            label: String((pane.session?.peers ?? []).length)
                            tip: "Also in this folder: " + (pane.session?.peers ?? []).join(", ")
                        }

                        MetaChip {
                            readonly property bool quiet: !!pane.session?.activity && (root.nowMs - pane.session.activity) / 1000 >= root.quietSeconds
                            visible: !!pane.session?.activity
                            icon: "timeline"
                            label: pane.session?.activity ? root.ago(pane.session.activity) : ""
                            tip: "Last activity"
                            tint: quiet ? Theme.warning : Theme.surfaceVariantText
                        }
                    }

                    Item {
                        id: paneButtons

                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 2
                        width: parent.width
                        height: 34
                        visible: pane.session !== null

                        Row {
                            spacing: Theme.spacingS

                            PaneButton {
                                visible: !!pane.session && root.wantsYou(pane.session)
                                label: "Dismiss"
                                onClicked: root.dismiss(pane.session)
                            }

                            PaneButton {
                                visible: !!pane.session && root.finished(pane.session)
                                label: "Wrong call"
                                kind: "quiet"
                                onClicked: root.flagWrong(pane.session)
                            }
                        }

                        Row {
                            anchors.right: parent.right
                            spacing: Theme.spacingS

                            PaneButton {
                                visible: root.permission !== null
                                enabled: root.armed
                                label: "Deny"
                                onClicked: root.answer(false)
                            }

                            PaneButton {
                                visible: root.permission !== null
                                enabled: root.armed && (root.permission?.complete ?? false)
                                label: "Allow"
                                kind: "allow"
                                onClicked: root.answer(true)
                            }

                            PaneButton {
                                enabled: !!pane.session && !root.unreachable(pane.session)
                                label: pane.session?.state === "ended" ? "Resume" : "Open"
                                kind: "open"
                                onClicked: root.focusSession(pane.session)
                            }
                        }
                    }

                    // A click anywhere else in the pane puts the menu away.
                    MouseArea {
                        anchors.fill: parent
                        visible: !!root.hub?.menu
                        onClicked: root.hub.closeMenu()
                    }

                    Rectangle {
                        id: menuBox

                        anchors.bottom: paneMeta.top
                        anchors.bottomMargin: 4
                        visible: !!root.hub?.menu
                        width: 250
                        height: menuColumn.implicitHeight + Theme.spacingS
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHighest
                        border.width: 1
                        border.color: Theme.outlineVariant

                        Column {
                            id: menuColumn

                            x: 4
                            y: 4
                            width: parent.width - 8

                            Item {
                                width: parent.width
                                height: 26

                                SectionLabel {
                                    x: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.hub?.menu?.title ?? ""
                                }

                                OneLine {
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, 150)
                                    text: root.hub?.menu?.context ?? ""
                                }
                            }

                            Repeater {
                                model: root.hub?.menu?.rows ?? []

                                Rectangle {
                                    id: menuRow

                                    required property var modelData
                                    readonly property bool canRun: !!modelData.run

                                    width: parent.width
                                    height: 30
                                    radius: 6
                                    color: modelData.id === root.hub?.menu?.preferred ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent"

                                    OneLine {
                                        x: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, parent.width - x - menuHint.width - Theme.spacingM)
                                        text: menuRow.modelData.label
                                        color: menuRow.canRun ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceVariantText, 0.7)
                                    }

                                    OneLine {
                                        id: menuHint
                                        anchors.right: parent.right
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: Math.min(implicitWidth, 120)
                                        text: menuRow.modelData.unavailable || menuRow.modelData.description || ""
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                                    }

                                    StateLayer {
                                        disabled: !menuRow.canRun
                                        onClicked: root.runMenuRow(menuRow.modelData)
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        anchors.centerIn: parent
                        visible: pane.session === null
                        text: "Nothing selected"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
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
                    key: "↵"
                    label: "open"
                }

                KeyHint {
                    key: "a"
                    label: "allow"
                }

                KeyHint {
                    key: "d"
                    label: "deny"
                }

                KeyHint {
                    key: "x"
                    label: "dismiss"
                }

                KeyHint {
                    key: "u"
                    label: "undo"
                }

                KeyHint {
                    key: "w"
                    label: "wrong call"
                }

                KeyHint {
                    key: "j k"
                    label: "move"
                }
            }
        }
    }
}
