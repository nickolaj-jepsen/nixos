// The pill the storage widget used to be: the same storage icon and the same
// percentage, colored at the same 75%/90% thresholds, with what the janitor
// could reclaim beside it. The popout is the checklist — `janitor plan` for the
// rows, `janitor apply` for the ones ticked, branches bundled by the CLI first.
//
// The pill reads cached numbers only (`janitor state`, written by the timers), so
// a bar render never walks the disk. Opening the popout is what triggers a real
// scan, at most once an hour.
import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    readonly property string command: pluginData.command || "janitor"
    readonly property real textSize: Theme.barTextSize(barThickness, barConfig?.fontScale, barConfig?.maximizeWidgetText)
    readonly property real iconSize: Theme.barIconSize(barThickness, undefined, barConfig?.maximizeWidgetIcons, barConfig?.iconScale)
    readonly property var tabular: ({
            "tnum": 1
        })
    readonly property int scanIntervalMs: 3600000

    property var snapshot: null
    property var items: []
    property var checked: ({})
    property bool scanning: false
    property bool applying: false
    property string error: ""
    property string scannedAt: ""
    property string result: ""
    property real lastScanMs: 0

    readonly property real usedPct: snapshot?.disk?.usedPct ?? 0
    readonly property real availBytes: snapshot?.disk?.avail ?? 0
    readonly property real totalBytes: snapshot?.disk?.total ?? 0
    readonly property real reclaimBytes: snapshot?.reclaim?.bytes ?? 0
    readonly property real tmpBytes: snapshot?.tmp?.used ?? 0
    readonly property real tmpBudget: snapshot?.tmp?.budget ?? 0
    readonly property color levelColor: root.usedPct > 90 ? Theme.tempDanger : root.usedPct > 75 ? Theme.tempWarning : Theme.widgetIconColor
    readonly property int selectedCount: Object.keys(root.checked).filter(key => root.checked[key]).length
    readonly property real selectedBytes: root.items.reduce((sum, item) => root.checked[item.id] ? sum + item.bytes : sum, 0)

    function gib(bytes) {
        if (!bytes)
            return "0K";
        if (bytes >= 1073741824)
            return (bytes / 1073741824).toFixed(1) + "G";
        if (bytes >= 1048576)
            return Math.round(bytes / 1048576) + "M";
        return Math.ceil(bytes / 1024) + "K";
    }

    function refreshState() {
        Proc.runCommand("janitor.state", [root.command, "state", "print"], (stdout, exitCode) => {
            if (exitCode !== 0) {
                root.error = "janitor state exited with " + exitCode;
                return;
            }
            try {
                root.snapshot = JSON.parse(stdout);
                root.error = "";
            } catch (e) {
                root.error = "janitor state printed invalid JSON";
            }
        }, 0, 15000);
    }

    function scan() {
        if (root.scanning)
            return;
        root.scanning = true;
        root.lastScanMs = Date.now();
        Proc.runCommand("janitor.plan", [root.command, "plan"], (stdout, exitCode) => {
            root.scanning = false;
            if (exitCode !== 0) {
                root.error = "janitor plan exited with " + exitCode;
                return;
            }
            try {
                const plan = JSON.parse(stdout);
                const preset = {};
                plan.items.forEach(item => {
                    if (item.preset)
                        preset[item.id] = true;
                });
                root.items = plan.items;
                root.checked = preset;
                root.snapshot = Object.assign({}, root.snapshot, {
                    disk: plan.disk,
                    tmp: plan.tmp,
                    reclaim: plan.reclaim
                });
                root.scannedAt = new Date(plan.generated * 1000).toLocaleTimeString(Qt.locale(), "HH:mm");
                root.error = "";
            } catch (e) {
                root.error = "janitor plan printed invalid JSON";
            }
        }, 0, 180000);
    }

    function scanIfStale() {
        if (Date.now() - root.lastScanMs > root.scanIntervalMs)
            root.scan();
    }

    function toggle(id) {
        const next = Object.assign({}, root.checked);
        next[id] = !next[id];
        root.checked = next;
    }

    function applySelected() {
        const ids = root.items.filter(item => root.checked[item.id]).map(item => item.id);
        if (ids.length === 0 || root.applying)
            return;
        root.applying = true;
        root.result = "";
        Proc.runCommand("janitor.apply", [root.command, "apply", "--ids"].concat(ids), (stdout, exitCode) => {
            root.applying = false;
            const lines = stdout.trim().split("\n").filter(line => line.length > 0);
            root.result = lines.length > 0 ? lines[lines.length - 1] : "";
            if (exitCode !== 0) {
                root.error = "janitor apply exited with " + exitCode;
                return;
            }
            root.error = "";
            root.scan();
            root.refreshState();
        }, 0, 900000);
    }

    // Cached numbers, refreshed by the timers; the pill itself never scans.
    Timer {
        interval: 300000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshState()
    }

    // Opening the popout is the one moment a full walk is worth its seconds.
    onInteractionActiveChanged: {
        if (root.interactionActive)
            root.scanIfStale();
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS + 2

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "storage"
                size: root.iconSize
                color: root.levelColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.usedPct.toFixed(0) + "%"
                font.pixelSize: root.textSize
                font.features: root.tabular
                color: root.levelColor
            }

            StyledText {
                visible: root.reclaimBytes > 0
                anchors.verticalCenter: parent.verticalCenter
                text: "· " + root.gib(root.reclaimBytes)
                font.pixelSize: root.textSize
                font.features: root.tabular
                color: Theme.surfaceVariantText
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "storage"
                size: root.iconSize
                color: root.levelColor
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.usedPct.toFixed(0) + "%"
                font.pixelSize: root.textSize
                font.features: root.tabular
                color: root.levelColor
            }
        }
    }

    popoutWidth: 520

    popoutContent: Component {
        PopoutComponent {
            headerText: "Janitor"
            detailsText: root.error.length > 0 ? root.error : root.result

            headerActions: Component {
                Row {
                    spacing: Theme.spacingS

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.scannedAt.length > 0
                        text: "scanned " + root.scannedAt
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Rectangle {
                        width: Theme.iconSize + Theme.spacingXS * 2
                        height: width
                        radius: width / 2
                        color: scanArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.1) : "transparent"

                        DankIcon {
                            id: scanIcon
                            anchors.centerIn: parent
                            name: "refresh"
                            size: Theme.iconSizeSmall
                            color: Theme.surfaceText

                            RotationAnimation on rotation {
                                running: root.scanning || root.applying
                                from: 0
                                to: 360
                                duration: 900
                                loops: Animation.Infinite
                                onStopped: scanIcon.rotation = 0
                            }
                        }

                        MouseArea {
                            id: scanArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.scan()
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: diskColumn.implicitHeight + Theme.spacingM

                Column {
                    id: diskColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    StyledText {
                        width: parent.width
                        text: "root   " + root.gib(root.totalBytes - root.availBytes) + " of " + root.gib(root.totalBytes) + "   ·   " + root.gib(root.availBytes) + " free"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }

                    // The storage widget's fill, as a bar rather than a ring.
                    Rectangle {
                        width: parent.width
                        height: 6
                        radius: 3
                        color: Theme.withAlpha(Theme.surfaceText, 0.12)

                        Rectangle {
                            width: Math.max(0, Math.min(parent.width, parent.width * root.usedPct / 100))
                            height: parent.height
                            radius: parent.radius
                            color: root.levelColor
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: root.gib(root.reclaimBytes) + " reclaimable   ·   agent temp " + root.gib(root.tmpBytes) + " of " + root.gib(root.tmpBudget)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }

            ListView {
                width: parent.width
                height: Math.min(contentHeight, 320)
                clip: true
                model: root.items
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    required property var modelData
                    readonly property bool ticked: !!root.checked[modelData.id]

                    width: ListView.view.width
                    height: rowContent.implicitHeight + Theme.spacingS
                    color: rowArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent"

                    Row {
                        id: rowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: parent.parent.ticked ? "check_box" : "check_box_outline_blank"
                            size: Theme.iconSizeSmall
                            color: parent.parent.ticked ? Theme.primary : Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.gib(modelData.bytes)
                            font.pixelSize: Theme.fontSizeSmall
                            font.features: root.tabular
                            color: Theme.surfaceVariantText
                        }

                        Column {
                            width: parent.width - Theme.iconSize - 310
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            StyledText {
                                width: parent.width
                                text: modelData.title
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideMiddle
                            }

                            StyledText {
                                width: parent.width
                                text: modelData.detail
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggle(modelData.id)
                    }
                }
            }

            Item {
                width: parent.width
                height: applyRow.implicitHeight + Theme.spacingM

                Row {
                    id: applyRow
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingM

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.selectedCount + " selected"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Rectangle {
                        width: applyLabel.implicitWidth + Theme.spacingL * 2
                        height: applyLabel.implicitHeight + Theme.spacingS * 2
                        radius: height / 2
                        color: root.selectedCount === 0 || root.applying ? Theme.withAlpha(Theme.surfaceText, 0.08) : Theme.primary

                        StyledText {
                            id: applyLabel
                            anchors.centerIn: parent
                            text: root.applying ? "applying…" : "Apply " + root.gib(root.selectedBytes)
                            font.pixelSize: Theme.fontSizeMedium
                            color: root.selectedCount === 0 || root.applying ? Theme.surfaceVariantText : Theme.primaryText
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: root.selectedCount > 0 && !root.applying
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.applySelected()
                        }
                    }
                }
            }

            StyledText {
                width: parent.width
                leftPadding: Theme.spacingS
                rightPadding: Theme.spacingS
                bottomPadding: Theme.spacingS
                visible: root.items.length === 0 && !root.scanning
                text: "Nothing to reclaim."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }
    }
}
