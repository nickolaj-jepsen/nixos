// Bar pill: a dot per session that wants you, in the hub's order, then a ring per working
// one. Something new bursts, an ask also peeks its name, and it breathes until you look.
// Popout: the first session waiting on you as a card, then the rest by what they are, with
// Idle and Ended folded to a line that unfolds when selected. Keys act on the selection:
// Enter focuses it (or resumes an ended one in a new terminal), x dismisses, w logs its
// verdict as wrong, u undoes the last dismissal, j/k move, g/G jump to the ends.
import QtQuick
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
    // The folded group the selection is in, which is therefore unfolded.
    readonly property string unfolded: idleRows.some(s => s.id === selectedId) ? "Idle" : endedRows.some(s => s.id === selectedId) ? "Ended" : ""
    // The popout's rows: what isn't idle in the hub's order, then the two groups.
    readonly property var rows: active.concat(group("Idle", idleRows), group("Ended", endedRows))
    readonly property int maxDots: 6
    // A session left waiting on you this long has its age turn red.
    readonly property int staleSeconds: 900
    readonly property var pillGroups: [["asking", "needs-reply"], ["failed"], ["done"], ["working"]]

    property string selectedId: ""
    // The row `w` flagged last, until the popout next opens: the only sign the key worked.
    property string flaggedId: ""
    property real nowMs: Date.now()

    readonly property int selectedIndex: Math.max(0, rows.findIndex(s => s.id === selectedId))
    readonly property var selected: rows[selectedIndex] ?? null

    // Which rows pulsed at the last state, null until one has come in on this connection.
    property var announced: null
    // The animations live here: a state from the hub rebuilds the pill's dots.
    property var burstIds: ({})
    property real burstProgress: 0
    property real breath: 1
    property bool peekOpen: false
    property string peekText: ""
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

    function group(title, members) {
        if (!members.length)
            return [];
        return unfolded === title ? members : [
            {
                "id": "fold:" + title,
                "fold": title,
                "state": "fold",
                "members": members
            }
        ];
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

    function isCard(index) {
        return index === 0 && rows.length > 0 && waits(rows[0]);
    }

    // The heading a row goes under; the card and a folded line have none.
    function sectionOf(index) {
        const row = rows[index];
        if (!row || row.fold || isCard(index))
            return "";
        if (waits(row))
            return "Also waiting";
        return {
            "failed": "Finished",
            "done": "Finished",
            "working": "Working",
            "idle": "Idle",
            "ended": "Ended"
        }[row.state] ?? "";
    }

    function sectionCount(title) {
        return rows.filter((row, index) => sectionOf(index) === title).length;
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

    // A row's or a past turn's glyph; working and idle draw a spinner and a dot instead.
    function icon(item) {
        return {
            "asking": "lock",
            "needs-reply": "chat_bubble",
            "failed": "cancel",
            "done": "check_circle",
            "ended": "history"
        }[item.state] ?? "";
    }

    function stateWords(session) {
        const at = Qt.formatTime(new Date(session.since), "HH:mm");
        return {
            "asking": "asking since ",
            "needs-reply": "waiting on you since ",
            "failed": "failed at ",
            "done": "finished at ",
            "working": "working since ",
            "idle": "idle since ",
            "ended": "ended at "
        }[session.state] + at;
    }

    function ago(ms) {
        const m = Math.floor((nowMs - ms) / 60000);
        return m < 1 ? "now" : m < 60 ? m + "m" : m < 2880 ? Math.floor(m / 60) + "h" : Math.floor(m / 1440) + "d";
    }

    function displayName(session) {
        return session.name || Paths.shortenHome(session.cwd || "").split("/").pop() || session.agent || "";
    }

    // A folded group's names, a name more than one session has saying how many.
    function foldNames(members) {
        const counts = {};
        members.forEach(s => {
            const name = displayName(s);
            counts[name] = (counts[name] ?? 0) + 1;
        });
        return Object.keys(counts).map(name => counts[name] > 1 ? name + " (" + counts[name] + ")" : name).join(", ");
    }

    // Landing on a folded group goes into it, at the end you came from.
    function select(index) {
        if (!rows.length)
            return;
        const at = Math.max(0, Math.min(rows.length - 1, index));
        const row = rows[at];
        if (row.fold)
            selectedId = (at >= selectedIndex ? row.members[0] : row.members[row.members.length - 1]).id;
        else
            selectedId = row.id;
    }

    function dismiss(session) {
        if (!session || !wantsYou(session))
            return;
        // It leaves the list, so the selection goes to what took its place.
        if (session.id === selected?.id) {
            const next = rows[selectedIndex + 1] ?? rows[selectedIndex - 1];
            selectedId = next ? next.id : "";
        }
        hub.dismiss(session.id, session.turn);
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
        if (!session)
            return;
        if (session.fold) {
            select(rows.indexOf(session));
            return;
        }
        if (session.state === "ended")
            hub.resume(session.id);
        else
            hub.focusSession(session.id);
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
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    color: Theme.surfaceText
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

    component KeyCap: Rectangle {
        property alias text: capLabel.text

        anchors.verticalCenter: parent.verticalCenter
        width: capLabel.implicitWidth + 10
        height: capLabel.implicitHeight + 2
        radius: 4
        color: Theme.withAlpha(Theme.surfaceText, 0.12)

        StyledText {
            id: capLabel
            anchors.centerIn: parent
            font.family: Theme.monoFontFamily
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceText
        }
    }

    component CardButton: Rectangle {
        id: button

        required property string label
        required property string key
        // The keys act on the selection, so a card not selected doesn't offer them.
        property bool showKey: true
        property bool primary: false

        signal clicked

        width: buttonRow.implicitWidth + Theme.spacingM * 2
        height: 34
        radius: Theme.cornerRadius
        color: primary ? Theme.primaryContainer : "transparent"
        border.width: primary ? 0 : 1
        border.color: Theme.outline
        opacity: enabled ? 1 : 0.45

        Row {
            id: buttonRow
            anchors.centerIn: parent
            spacing: 6

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: button.label
                font.pixelSize: Theme.fontSizeSmall + 1
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            KeyCap {
                visible: button.showKey
                text: button.key
            }
        }

        StateLayer {
            onClicked: button.clicked()
        }
    }

    // The tone's glyph, a spinner while working, a dim dot when idle.
    component StateIcon: Item {
        id: stateIcon

        required property var session
        property real size: 18

        width: size + 2
        height: size + 2

        Dot {
            anchors.centerIn: parent
            visible: stateIcon.session.state === "idle"
            size: 6
            tone: Theme.withAlpha(Theme.surfaceVariantText, 0.6)
        }

        DSpinner {
            anchors.centerIn: parent
            visible: stateIcon.session.state === "working"
            size: stateIcon.size - 3
            strokeWidth: 2
            color: root.tone(stateIcon.session)
        }

        DIcon {
            anchors.centerIn: parent
            visible: stateIcon.session.state !== "idle" && stateIcon.session.state !== "working"
            name: root.icon(stateIcon.session)
            size: stateIcon.size
            color: root.tone(stateIcon.session)
        }
    }

    component SessionRow: Column {
        id: row

        required property var modelData
        required property int index
        readonly property var session: modelData
        readonly property bool card: root.isCard(index)
        readonly property bool fold: !!session.fold
        readonly property bool isSelected: index === root.selectedIndex
        readonly property string section: root.sectionOf(index)
        readonly property bool headed: section !== "" && (index === 0 || root.sectionOf(index - 1) !== section)
        readonly property string reason: session.reason || session.summary || ""
        readonly property string cwd: Paths.shortenHome(session.cwd || "")
        readonly property color tone: root.tone(session)
        // The last finished turns, newest last, as the hub sends them.
        readonly property var history: (session.history ?? []).slice(-3)
        readonly property string agentName: session.agent === "pi" ? "pi" : "Claude"
        // What can only be said in words: no way to open it, and that `w` was heard.
        readonly property var notes: [root.unreachable(session) ? "no way to open it from here" : "", root.flaggedId === session.id ? "logged as wrong" : ""]

        width: ListView.view.width

        Item {
            width: parent.width
            visible: row.headed
            height: headingText.implicitHeight + Theme.spacingM + Theme.spacingXS

            StyledText {
                id: headingText
                x: Theme.spacingM
                y: Theme.spacingM
                text: row.section
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
            }

            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                y: Theme.spacingM
                text: root.sectionCount(row.section)
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
            }
        }

        // The first session waiting on you, read without moving.
        Rectangle {
            id: cardBox

            width: parent.width
            visible: row.card
            height: visible ? cardBody.implicitHeight + Theme.spacingM * 2 : 0
            radius: Theme.cornerRadius + 2
            color: Theme.surfaceContainerHigh

            Rectangle {
                visible: row.isSelected
                y: Theme.spacingM
                width: 3
                height: parent.height - Theme.spacingM * 2
                radius: 1.5
                color: row.tone
            }

            Column {
                id: cardBody

                x: Theme.spacingM
                y: Theme.spacingM
                width: parent.width - Theme.spacingM * 2
                spacing: Theme.spacingS + 2

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    StateIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        session: row.session
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - cardAge.width - Theme.spacingS
                        text: root.displayName(row.session)
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontSizeMedium + 1
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        id: cardAge
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.ago(row.session.since) === "now" ? "just now" : "waiting " + root.ago(row.session.since)
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: root.stale(row.session) ? Theme.error : Theme.primary
                    }
                }

                StyledText {
                    width: parent.width
                    visible: text !== ""
                    text: row.reason
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 8
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeMedium + 1
                    color: Theme.surfaceText
                }

                Item {
                    width: parent.width
                    height: 34

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - cardButtons.width - Theme.spacingS
                        text: [row.agentName, row.session.host, row.cwd].concat(row.notes).filter(t => t).join(" · ")
                        wrapMode: Text.NoWrap
                        elide: Text.ElideMiddle
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Row {
                        id: cardButtons
                        anchors.right: parent.right
                        spacing: Theme.spacingS

                        CardButton {
                            label: "Dismiss"
                            key: "x"
                            showKey: row.isSelected
                            onClicked: root.dismiss(row.session)
                        }

                        CardButton {
                            label: "Open"
                            key: "↵"
                            primary: true
                            showKey: row.isSelected
                            enabled: !root.unreachable(row.session)
                            onClicked: root.focusSession(row.session)
                        }
                    }
                }
            }
        }

        // One line, or its full reason and last turns while selected.
        Rectangle {
            width: parent.width
            visible: !row.card && !row.fold
            height: visible ? compactBody.implicitHeight + Theme.spacingS * 2 : 0
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

            StateIcon {
                x: Theme.spacingM - 2
                y: Theme.spacingS
                session: row.session
                size: 16
            }

            Column {
                id: compactBody

                x: Theme.spacingM + 18 + Theme.spacingS
                y: Theme.spacingS
                width: parent.width - x - Theme.spacingM
                spacing: 2

                Item {
                    width: parent.width
                    height: nameText.implicitHeight

                    StyledText {
                        id: nameText
                        width: Math.min(implicitWidth, parent.width * 0.5)
                        text: root.displayName(row.session)
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontSizeSmall + 1
                        font.weight: Font.Medium
                        color: row.session.state === "idle" || row.session.state === "ended" ? Theme.surfaceVariantText : Theme.surfaceText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        x: nameText.width + Theme.spacingS
                        width: parent.width - x - rowMeta.width - Theme.spacingS
                        visible: !row.isSelected
                        text: row.reason || row.cwd
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Row {
                        id: rowMeta
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        StyledText {
                            visible: !!row.session.host
                            text: row.session.host ?? ""
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            visible: row.session.state !== "idle"
                            text: root.ago(row.session.since)
                            font.pixelSize: Theme.fontSizeSmall
                            color: root.stale(row.session) ? Theme.error : Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: row.isSelected && text !== ""
                    text: row.reason
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }

                Repeater {
                    model: row.isSelected ? row.history : []

                    Item {
                        id: turn

                        required property var modelData

                        width: compactBody.width
                        height: did.implicitHeight

                        DIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.icon(turn.modelData) || "circle"
                            size: Theme.fontSizeSmall
                            color: root.tone(turn.modelData)
                        }

                        StyledText {
                            id: did
                            x: Theme.fontSizeSmall + Theme.spacingXS
                            width: parent.width - x - turnAge.width - Theme.spacingS
                            text: turn.modelData.did
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            id: turnAge
                            anchors.right: parent.right
                            text: root.ago(turn.modelData.at)
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: row.isSelected
                    text: [row.agentName, row.cwd, root.stateWords(row.session)].concat(row.notes).filter(t => t).join(" · ")
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                }
            }
        }

        // A folded group: selecting it unfolds it.
        Rectangle {
            width: parent.width
            visible: row.fold
            height: visible ? foldText.implicitHeight + Theme.spacingS * 2 : 0
            radius: Theme.cornerRadius
            color: row.isSelected ? Theme.surfaceContainerHigh : "transparent"
            clip: true

            StateLayer {
                onClicked: root.focusSession(row.session)
            }

            StyledText {
                id: foldHeading
                x: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                text: row.session.fold ?? ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
            }

            StyledText {
                id: foldText
                x: Theme.spacingM + 18 + Theme.spacingS + Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - x - Theme.spacingM
                text: row.fold ? root.foldNames(row.session.members) : ""
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }

    component Legend: StyledText {
        anchors.verticalCenter: parent.verticalCenter
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
    }

    popoutWidth: 440

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

            // PluginPopout focuses its own container whenever it shows; take the keys back.
            onActiveFocusChanged: {
                if (!activeFocus && parentPopout?.shouldBeVisible)
                    grab();
            }

            Connections {
                target: pop.parentPopout
                function onOpened() {
                    root.nowMs = Date.now();
                    root.hub?.seen();
                    root.selectedId = "";
                    root.flaggedId = "";
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
                else if (event.key === Qt.Key_W)
                    root.flagWrong(root.selected);
                else if (event.key === Qt.Key_U)
                    root.hub?.undo();
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
                event.accepted = true;
            }

            Column {
                id: content

                width: parent.width
                spacing: 0

                StyledText {
                    width: parent.width
                    visible: !root.rows.length
                    topPadding: Theme.spacingM
                    bottomPadding: Theme.spacingM
                    horizontalAlignment: Text.AlignHCenter
                    text: root.linkUp ? "No agent sessions." : root.hub?.refused || "The agent-hub service is not running."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }

                DListView {
                    id: list
                    width: parent.width
                    height: Math.min(contentHeight, Screen.height * 0.6)
                    visible: root.rows.length > 0
                    interactive: contentHeight > height
                    spacing: 2
                    model: root.rows
                    delegate: SessionRow {}
                }

                StyledText {
                    width: parent.width
                    visible: text !== ""
                    topPadding: Theme.spacingS
                    horizontalAlignment: Text.AlignHCenter
                    text: (root.hub?.links ?? []).filter(l => l.status !== "up").map(l => l.host + ": " + l.status).join(" · ")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Item {
                    width: parent.width
                    height: Theme.spacingS
                    visible: root.rows.length > 0
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    visible: root.rows.length > 0
                    color: Theme.surfaceContainerHigh
                }

                Row {
                    x: Theme.spacingM
                    topPadding: Theme.spacingS
                    visible: root.rows.length > 0
                    spacing: Theme.spacingM

                    Row {
                        spacing: 5

                        KeyCap {
                            text: "u"
                        }

                        Legend {
                            text: "undo dismiss"
                        }
                    }

                    Row {
                        spacing: 5

                        KeyCap {
                            text: "w"
                        }

                        Legend {
                            text: "wrong call"
                        }
                    }

                    Row {
                        spacing: 5

                        KeyCap {
                            text: "j"
                        }

                        KeyCap {
                            text: "k"
                        }

                        Legend {
                            text: "move"
                        }
                    }
                }
            }
        }
    }
}
