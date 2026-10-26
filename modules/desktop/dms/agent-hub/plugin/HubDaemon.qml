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
    readonly property bool linkUp: socket.linkUp

    function focusSession(sessionId) {
        socket.send({
            "op": "focus",
            "session": sessionId
        });
    }

    function dismiss(sessionId) {
        socket.send({
            "op": "dismiss",
            "session": sessionId
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
        if (message.type === "state")
            root.sessions = message.sessions;
    }

    DCommon.DSocket {
        id: socket
        path: Quickshell.env("XDG_RUNTIME_DIR") + "/agent-hub/hub.sock"
        connected: true
        onConnectionStateChanged: {
            if (linkUp)
                send({
                    "op": "subscribe"
                });
            else
                root.sessions = [];
        }
        parser: SplitParser {
            onRead: line => root.handle(line)
        }
    }
}
