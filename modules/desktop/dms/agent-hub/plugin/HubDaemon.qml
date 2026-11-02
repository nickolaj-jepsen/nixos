// The one subscription to the agent-hub daemon, shared by every bar's widget.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.DCommon.Common as DCommon

Item {
    id: root

    property string pluginId
    property var pluginService

    property var sessions: []
    // Sessions that ended, newest first, each with the command that resumes it.
    property var recent: []
    // Other hosts piped in, each `up` or saying why it isn't.
    property var links: []
    readonly property bool linkUp: socket.linkUp
    // Set when the hub speaks another protocol version; the socket then stays closed.
    property string refused: ""
    // The menu last asked for, null until it answers; it may answer again with more.
    property var menu: null
    property int menuRequest: 0

    function focusSession(sessionId) {
        socket.send({
            "op": "focus",
            "session": sessionId
        });
    }

    function resume(sessionId) {
        socket.send({
            "op": "resume",
            "session": sessionId
        });
    }

    function dismiss(sessionId, turn) {
        socket.send({
            "op": "dismiss",
            "session": sessionId,
            "turn": turn
        });
    }

    function undo() {
        socket.send({
            "op": "undo"
        });
    }

    function wrong(sessionId) {
        socket.send({
            "op": "wrong",
            "session": sessionId
        });
    }

    function seen() {
        socket.send({
            "op": "seen"
        });
    }

    function answer(sessionId, ask, allow) {
        socket.send({
            "op": "answer",
            "session": sessionId,
            "ask": ask,
            "allow": allow
        });
    }

    function openMenu(sessionId, which) {
        root.menu = null;
        root.menuRequest += 1;
        socket.send({
            "op": "menu",
            "request": root.menuRequest,
            "session": sessionId,
            "which": which
        });
    }

    function closeMenu() {
        root.menu = null;
        root.menuRequest += 1;
    }

    function run(sessionId, action) {
        socket.send({
            "op": "run",
            "session": sessionId,
            "kind": action.kind,
            "value": action.value
        });
    }

    function handle(line) {
        let message;
        try {
            message = JSON.parse(line);
        } catch (e) {
            console.warn("agentHub: unreadable line from the hub");
            return;
        }
        if (message.type === "state") {
            root.sessions = message.sessions;
            root.recent = message.recent ?? [];
            root.links = message.links ?? [];
        } else if (message.type === "menu") {
            if (message.request === root.menuRequest)
                root.menu = message.menu;
        } else if (message.type === "refused") {
            console.warn("agentHub: " + message.text);
            root.refused = message.text;
            // Not from inside the parser's own callback: this destroys the socket.
            Qt.callLater(() => socket.connected = false);
        }
    }

    DCommon.DSocket {
        id: socket
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/agent-hub/hub.sock"
        connected: true
        onConnectionStateChanged: {
            if (linkUp)
                send({
                    "op": "subscribe",
                    "version": 3
                });
            else {
                root.sessions = [];
                root.recent = [];
                root.links = [];
            }
        }
        parser: SplitParser {
            onRead: line => root.handle(line)
        }
    }
}
