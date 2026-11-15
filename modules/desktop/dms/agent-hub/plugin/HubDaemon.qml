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
    // Other hosts piped in, each `up` or saying why it isn't.
    property var links: []
    readonly property bool linkUp: socket.linkUp
    // Set when the hub speaks another protocol version; the socket then stays closed.
    property string refused: ""

    function focusSession(sessionId) {
        socket.send({
            "op": "focus",
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

    function seen() {
        socket.send({
            "op": "seen"
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
            root.links = message.links ?? [];
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
                    "version": 6
                });
            else {
                root.sessions = [];
                root.links = [];
            }
        }
        parser: SplitParser {
            onRead: line => root.handle(line)
        }
    }
}
