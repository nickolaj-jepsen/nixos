// The note reader: a session's notes at the screen's edge. A slideout and not the popout, since
// that closes on a click outside it, and a plan is read while typing about it in the terminal.
// The hub lists the notes and renders each one; this polls while it shows, so a note being
// rewritten updates under you and keeps your place.
import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets

DSlideout {
    id: reader

    required property var hub

    property string session: ""
    property string path: ""
    property var notes: []
    property bool listed: false
    // The note showing: `html`, `at`, `size`, `cut`, or `gone`. Null while it is asked for.
    property var note: null
    property bool moreOpen: false
    property bool listFailed: false
    property real nowMs: Date.now()

    readonly property var row: (hub.sessions ?? []).find(s => s.id === session) ?? (hub.recent ?? []).find(s => s.id === session) ?? null
    // What the session touched comes first; the rest of its project waits behind `More`.
    readonly property var tabs: {
        const own = notes.filter(n => n.group !== "project");
        if (path && !own.some(n => n.path === path)) {
            const parts = path.split("/");
            own.push(notes.find(n => n.path === path) ?? {
                "path": path,
                "name": parts.slice(-2).join("/"),
                "group": "opened",
                "at": 0
            });
        }
        return own;
    }
    readonly property var more: notes.filter(n => n.group === "project" && !tabs.some(t => t.path === n.path))

    // Qt's rich text reads these; the hub's HTML carries no colours or fonts of its own.
    readonly property string css: "<style>" + "a { color: " + Theme.primary + "; text-decoration: none; }" + "h1, h2, h3, h4 { color: " + Theme.surfaceText + "; }" + "code, pre { font-family: '" + Theme.monoFontFamily + "'; }" + "code { background-color: " + Theme.surfaceContainerHigh + "; }" + "pre { white-space: pre-wrap; }" + "table.fence { background-color: " + Theme.surfaceContainerHigh + "; }" + "table.data { border-color: " + Theme.outlineVariant + "; border-style: solid; }" + "th { color: " + Theme.surfaceVariantText + "; }" + "</style>"

    layerNamespace: "dms:plugins:agentHub:reader"
    // Text over whatever is behind it can't be read, whatever the shell's transparency is set to.
    customTransparency: 1
    slideoutWidth: Math.min((modelData?.width ?? 1600) * 0.5, 820)

    function ago(at) {
        const seconds = Math.max(0, Math.floor((nowMs - at) / 1000));
        if (seconds < 60)
            return seconds < 5 ? "now" : seconds + "s ago";
        const minutes = Math.floor(seconds / 60);
        if (minutes < 60)
            return minutes + "m ago";
        const hours = Math.floor(minutes / 60);
        return hours < 48 ? hours + "h ago" : Math.floor(hours / 24) + "d ago";
    }

    function size(bytes) {
        return bytes < 1024 ? bytes + " B" : (bytes / 1024).toFixed(1) + " KB";
    }

    function open(sessionId, notePath, toggle) {
        if (toggle && isVisible) {
            hide();
            return;
        }
        // Named nothing, it comes back to what it last showed, and with nothing to come back to it stays away.
        if (!sessionId && !notePath && !session && !path)
            return;
        const id = sessionId ?? (notePath ? "" : session);
        if (id !== session) {
            session = id;
            notes = [];
            listed = false;
            path = "";
            note = null;
        }
        moreOpen = false;
        if (notePath)
            pick(notePath);
        if (!isVisible)
            modelData = CompositorService.getFocusedScreen() ?? Quickshell.screens[0];
        hub.askNotes(session, notePath ?? "");
        show();
    }

    function pick(notePath) {
        moreOpen = false;
        if (notePath === path && !note?.gone)
            return;
        path = notePath;
        note = null;
        hub.askNote(session, path, -1);
    }

    function step(by) {
        const at = tabs.findIndex(n => n.path === path);
        const next = tabs[at + by];
        if (next)
            pick(next.path);
    }

    function listAnswered(list) {
        // No list at all means nobody answered, which an empty one doesn't.
        listFailed = !list;
        notes = list ?? notes;
        listed = true;
        if (!path && notes.length)
            pick(notes[0].path);
    }

    function noteAnswered(found) {
        if (!found)
            note = {
                "gone": true
            };
        else if (!found.unchanged)
            note = found;
    }

    function follow(link) {
        if (link.startsWith("note:"))
            pick(link.slice(5));
        else
            hub.run(session, {
                "kind": "url",
                "value": link
            });
    }

    function edit() {
        if (path)
            hub.run(session, {
                "kind": "note",
                "value": path
            });
    }

    function copyPath() {
        if (path)
            hub.run(session, {
                "kind": "copy",
                "value": path
            });
    }

    Timer {
        interval: 1500
        repeat: true
        running: reader.isVisible && reader.path !== ""
        onTriggered: {
            reader.nowMs = Date.now();
            if (reader.note)
                reader.hub.askNote(reader.session, reader.path, reader.note.at);
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: reader.isVisible
        onTriggered: reader.hub.askNotes(reader.session, reader.session ? "" : reader.path)
    }

    component ReaderButton: Rectangle {
        id: button

        required property string label

        signal clicked

        width: buttonLabel.implicitWidth + Theme.spacingM * 2
        height: 30
        radius: Theme.cornerRadius
        color: "transparent"
        border.width: 1
        border.color: Theme.outline

        StyledText {
            id: buttonLabel
            anchors.centerIn: parent
            text: button.label
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StateLayer {
            onClicked: button.clicked()
        }
    }

    component NoteTab: Rectangle {
        id: tab

        required property string label
        required property string detail
        property bool current: false
        property bool quiet: false

        signal clicked

        width: Math.min(tabRow.implicitWidth + Theme.spacingM * 2, 300)
        height: 30
        radius: Theme.cornerRadius
        color: current ? Theme.surfaceContainerHighest : "transparent"

        Row {
            id: tabRow
            anchors.centerIn: parent
            spacing: Theme.spacingS

            StyledText {
                width: Math.min(implicitWidth, 240)
                text: tab.label
                textFormat: Text.PlainText
                wrapMode: Text.NoWrap
                elide: Text.ElideLeft
                font.pixelSize: Theme.fontSizeSmall
                font.weight: tab.current ? Font.Medium : Font.Normal
                color: tab.quiet && !tab.current ? Theme.surfaceVariantText : Theme.surfaceText
            }

            StyledText {
                visible: tab.detail !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: tab.detail
                font.pixelSize: Theme.fontSizeSmall - 2
                color: Theme.surfaceVariantText
            }
        }

        StateLayer {
            onClicked: tab.clicked()
        }
    }

    content: Component {
        FocusScope {
            id: scope

            focus: true

            function scrollTo(y) {
                scroll.contentY = Math.max(0, Math.min(y, Math.max(0, scroll.contentHeight - scroll.height)));
            }

            function keyed(event) {
                if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
                    return;
                const page = scroll.height * 0.9;
                if (event.key === Qt.Key_J || event.key === Qt.Key_Down)
                    scrollTo(scroll.contentY + 60);
                else if (event.key === Qt.Key_K || event.key === Qt.Key_Up)
                    scrollTo(scroll.contentY - 60);
                else if (event.key === Qt.Key_Space || event.key === Qt.Key_PageDown)
                    scrollTo(scroll.contentY + page);
                else if (event.key === Qt.Key_PageUp)
                    scrollTo(scroll.contentY - page);
                else if (event.key === Qt.Key_Home || event.text === "g")
                    scrollTo(0);
                else if (event.key === Qt.Key_End || event.text === "G")
                    scrollTo(scroll.contentHeight);
                else if (event.text === "]" || event.key === Qt.Key_L)
                    reader.step(1);
                else if (event.text === "[" || event.key === Qt.Key_H)
                    reader.step(-1);
                else if (event.key === Qt.Key_E)
                    reader.edit();
                else if (event.key === Qt.Key_Y)
                    reader.copyPath();
                else if (event.key === Qt.Key_S && reader.session)
                    reader.hub.focusSession(reader.session);
                else if (event.key === Qt.Key_Escape && reader.moreOpen)
                    reader.moreOpen = false;
                else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q)
                    reader.hide();
                else
                    return;
                event.accepted = true;
            }

            Keys.onPressed: event => keyed(event)

            Connections {
                target: reader
                function onPathChanged() {
                    scroll.contentY = 0;
                }
            }

            Item {
                id: head

                width: parent.width
                height: 32

                StyledText {
                    id: headName
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - closeButton.width - headState.width - Theme.spacingM * 2)
                    text: reader.row?.label || reader.row?.name || "Notes"
                    textFormat: Text.PlainText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Theme.fontWeightMedium
                    color: Theme.surfaceText
                }

                StyledText {
                    id: headState
                    anchors.left: headName.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    text: [reader.row?.host, (reader.row?.state ?? "").replace("-", " ")].filter(Boolean).join(" · ")
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                DActionButton {
                    id: closeButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "close"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    onClicked: reader.hide()
                }
            }

            Item {
                id: tabBar

                anchors.top: head.bottom
                anchors.topMargin: Theme.spacingS
                width: parent.width
                height: 30

                ListView {
                    anchors.left: parent.left
                    anchors.right: moreButton.visible ? moreButton.left : parent.right
                    anchors.rightMargin: moreButton.visible ? Theme.spacingS : 0
                    height: parent.height
                    orientation: ListView.Horizontal
                    spacing: 2
                    clip: true
                    model: reader.tabs

                    delegate: NoteTab {
                        required property var modelData

                        label: modelData.name
                        detail: modelData.at ? reader.ago(modelData.at) : ""
                        current: modelData.path === reader.path
                        quiet: modelData.group !== "written"
                        onClicked: reader.pick(modelData.path)
                    }
                }

                NoteTab {
                    id: moreButton
                    anchors.right: parent.right
                    visible: reader.more.length > 0
                    label: "More"
                    detail: String(reader.more.length)
                    current: reader.moreOpen
                    onClicked: reader.moreOpen = !reader.moreOpen
                }
            }

            Rectangle {
                id: rule

                anchors.top: tabBar.bottom
                anchors.topMargin: Theme.spacingS
                width: parent.width
                height: 1
                color: Theme.outlineVariant
            }

            DFlickable {
                id: scroll

                anchors.top: rule.bottom
                anchors.topMargin: Theme.spacingS
                anchors.bottom: foot.top
                anchors.bottomMargin: Theme.spacingS
                width: parent.width
                clip: true
                contentWidth: width
                contentHeight: body.implicitHeight

                TextEdit {
                    id: body

                    width: scroll.width - Theme.spacingM
                    readOnly: true
                    selectByMouse: true
                    textFormat: TextEdit.RichText
                    wrapMode: TextEdit.Wrap
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    selectionColor: Theme.primaryContainer
                    selectedTextColor: Theme.surfaceText
                    text: reader.note?.html ? reader.css + reader.note.html : ""
                    Keys.onPressed: event => scope.keyed(event)
                    onLinkActivated: link => reader.follow(link)

                    HoverHandler {
                        cursorShape: body.hoveredLink ? Qt.PointingHandCursor : Qt.IBeamCursor
                    }
                }
            }

            StyledText {
                anchors.centerIn: scroll
                width: scroll.width - Theme.spacingXL
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                visible: !reader.note?.html
                text: {
                    if (reader.note?.gone)
                        return "This note can't be read: it is gone, or its host is out of reach.";
                    if (reader.path)
                        return "";
                    if (!reader.listed)
                        return reader.session.includes(":") ? "Asking the other host…" : "Looking for notes…";
                    if (reader.listFailed)
                        return "Couldn't list this session's notes: its host didn't answer.";
                    return "No notes yet: this session hasn't written or read any, and its project's folder is empty.";
                }
                textFormat: Text.PlainText
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }

            Item {
                id: foot

                anchors.bottom: parent.bottom
                width: parent.width
                height: 30

                Row {
                    spacing: Theme.spacingS

                    ReaderButton {
                        visible: reader.path !== ""
                        label: "Edit in VS Code"
                        onClicked: reader.edit()
                    }

                    ReaderButton {
                        visible: reader.path !== ""
                        label: "Copy path"
                        onClicked: reader.copyPath()
                    }

                    ReaderButton {
                        visible: (reader.hub.sessions ?? []).some(s => s.id === reader.session)
                        label: "Go to session"
                        onClicked: reader.hub.focusSession(reader.session)
                    }
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!reader.note?.at
                    text: [scope.activeFocus || body.activeFocus ? "j k scroll · [ ] note" : "", reader.note?.cut ? "cut short" : "", reader.note?.size ? reader.size(reader.note.size) : "", reader.note?.at ? reader.ago(reader.note.at) : ""].filter(Boolean).join(" · ")
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }

            // A click anywhere else puts the list away.
            MouseArea {
                anchors.fill: parent
                visible: reader.moreOpen
                onClicked: reader.moreOpen = false
            }

            Rectangle {
                id: moreList

                anchors.top: tabBar.bottom
                anchors.topMargin: 4
                anchors.right: parent.right
                width: Math.min(parent.width, 460)
                height: Math.min(moreRows.contentHeight + 8, parent.height * 0.6)
                visible: reader.moreOpen
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHighest
                border.width: 1
                border.color: Theme.outlineVariant

                ListView {
                    id: moreRows

                    anchors.fill: parent
                    anchors.margins: 4
                    clip: true
                    model: reader.more

                    delegate: Item {
                        id: moreRow

                        required property var modelData

                        width: moreRows.width
                        height: 28

                        StyledText {
                            x: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - moreAge.width - Theme.spacingM * 2
                            text: moreRow.modelData.name
                            textFormat: Text.PlainText
                            wrapMode: Text.NoWrap
                            elide: Text.ElideLeft
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }

                        StyledText {
                            id: moreAge
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: reader.ago(moreRow.modelData.at)
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.surfaceVariantText
                        }

                        StateLayer {
                            onClicked: reader.pick(moreRow.modelData.path)
                        }
                    }
                }
            }

            // Clicking the reader is what gives it the keys; until then they stay in your terminal.
            TapHandler {
                onTapped: scope.forceActiveFocus()
            }
        }
    }
}
