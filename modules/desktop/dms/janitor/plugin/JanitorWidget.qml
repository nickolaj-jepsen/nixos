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
import qs.DCommon.Widgets
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

    readonly property var categoryOrder: ["build", "tmp", "jobs", "transcripts", "worktree", "branch", "scratch"]
    readonly property var categoryTitles: ({
            "build": "Build dirs",
            "tmp": "Agent temp",
            "jobs": "Finished jobs",
            "transcripts": "Transcripts",
            "worktree": "Worktrees",
            "branch": "Branches",
            "scratch": "Stale scratch"
        })
    readonly property var categoryIcons: ({
            "build": "folder",
            "tmp": "hourglass_empty",
            "jobs": "work_history",
            "transcripts": "description",
            "worktree": "account_tree",
            "branch": "alt_route",
            "scratch": "inventory_2"
        })

    property var snapshot: null
    property var items: []
    // Top-level entries of ~ outside the home layout: shown, never applied.
    property var strays: []
    property var rows: []
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
    readonly property int selectedCount: root.items.filter(item => root.checked[item.id]).length
    readonly property real selectedBytes: root.items.reduce((sum, item) => root.checked[item.id] ? sum + item.bytes : sum, 0)
    // Every row's bar is drawn against the biggest item, so the shape of the list
    // says where the space is without a second column of numbers.
    readonly property real maxBytes: Math.max(1, ...root.items.map(item => item.bytes))

    function gib(bytes) {
        if (!bytes)
            return "0K";
        if (bytes >= 1073741824)
            return (bytes / 1073741824).toFixed(1) + "G";
        if (bytes >= 1048576)
            return Math.round(bytes / 1048576) + "M";
        return Math.ceil(bytes / 1024) + "K";
    }

    function groupRows(list) {
        const built = [];
        root.categoryOrder.forEach(category => {
            const group = list.filter(item => item.category === category).sort((a, b) => b.bytes - a.bytes);
            if (group.length === 0)
                return;
            built.push({
                header: true,
                category: category,
                label: root.categoryTitles[category] ?? category,
                icon: root.categoryIcons[category] ?? "folder",
                bytes: group.reduce((sum, item) => sum + item.bytes, 0),
                count: group.length
            });
            group.forEach(item => built.push(Object.assign({
                header: false
            }, item)));
        });
        return built;
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
                root.strays = plan.strays ?? [];
                root.rows = root.groupRows(plan.items);
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

    // A category header is the bulk control: all of it, or none of it.
    function groupSelected(category) {
        const group = root.items.filter(item => item.category === category);
        return group.length > 0 && group.every(item => root.checked[item.id]);
    }

    function toggleGroup(category) {
        const next = Object.assign({}, root.checked);
        const wanted = !root.groupSelected(category);
        root.items.forEach(item => {
            if (item.category === category)
                next[item.id] = wanted;
        });
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

            DIcon {
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

            DIcon {
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

    popoutWidth: 640

    popoutContent: Component {
        PopoutComponent {
            headerText: "Janitor"
            detailsText: root.error

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
                        color: scanArea.containsMouse ? Theme.surfaceHover : "transparent"

                        DIcon {
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

            // Disk first, because that is what the widget it replaced showed.
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

                    Item {
                        width: parent.width
                        height: summaryLeft.implicitHeight

                        StyledText {
                            id: summaryLeft
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.gib(root.totalBytes - root.availBytes) + " of " + root.gib(root.totalBytes) + " used"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            anchors.left: summaryLeft.right
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: "· " + root.gib(root.availBytes) + " free"
                            font.pixelSize: Theme.fontSizeMedium
                            color: root.usedPct > 90 ? Theme.tempDanger : Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.gib(root.reclaimBytes) + " reclaimable"
                            font.pixelSize: Theme.fontSizeMedium
                            color: Theme.primary
                        }
                    }

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
                        text: "agent temp " + root.gib(root.tmpBytes) + " of " + root.gib(root.tmpBudget)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }

            // The checklist: one line per row, sized and aligned in columns, with a
            // bar behind each row drawn against the biggest item.
            ListView {
                id: checklist
                width: parent.width
                height: Math.min(contentHeight, 360)
                clip: true
                model: root.rows
                boundsBehavior: Flickable.StopAtBounds

                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool isHeader: modelData.header === true
                    readonly property bool ticked: !row.isHeader && !!root.checked[modelData.id]

                    width: ListView.view.width
                    height: row.isHeader ? 32 : 30

                    // Category header: icon, name, what the group holds, and a
                    // click that toggles the whole group.
                    Item {
                        visible: row.isHeader
                        anchors.fill: parent

                        Rectangle {
                            anchors.top: parent.top
                            width: parent.width - Theme.spacingS * 2
                            x: Theme.spacingS
                            height: 1
                            color: Theme.withAlpha(Theme.surfaceText, 0.1)
                            visible: index > 0
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingS

                            DIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: row.isHeader ? modelData.icon : ""
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.isHeader ? modelData.label : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.isHeader ? root.gib(modelData.bytes) + " · " + modelData.count : ""
                                font.pixelSize: Theme.fontSizeSmall
                                font.features: root.tabular
                                color: Theme.surfaceVariantText
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleGroup(modelData.category)
                        }
                    }

                    // The row's own bar, behind everything else.
                    Rectangle {
                        visible: !row.isHeader
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        width: Math.max(2, (parent.width - Theme.spacingS * 2) * modelData.bytes / root.maxBytes)
                        height: parent.height - 2
                        y: 1
                        radius: 4
                        color: Theme.withAlpha(root.selectedCount > 0 && row.ticked ? Theme.primary : Theme.surfaceText, row.ticked ? 0.16 : 0.06)
                    }

                    Rectangle {
                        visible: !row.isHeader && rowArea.containsMouse
                        anchors.fill: parent
                        color: Theme.surfaceHover
                        opacity: 0.5
                    }

                    Row {
                        visible: !row.isHeader
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                        DIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: row.ticked ? "check_box" : "check_box_outline_blank"
                            size: Theme.iconSize
                            color: row.ticked ? Theme.primary : Theme.surfaceVariantText
                        }

                        // Size, right-aligned in a fixed column so the numbers line up.
                        Item {
                            width: 56
                            height: parent.height

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.gib(modelData.bytes)
                                font.pixelSize: Theme.fontSizeSmall
                                font.features: root.tabular
                                color: Theme.surfaceVariantText
                            }
                        }

                        // The short label, elided in the middle so both the repo and
                        // the directory name survive a narrow row.
                        StyledText {
                            width: parent.width - 20 - 56 - 76 - Theme.spacingS * 3
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label ?? modelData.title
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            elide: Text.ElideMiddle
                        }

                        // Age, right-aligned, the reason the row is offered at all.
                        Item {
                            width: 76
                            height: parent.height

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.detail ?? ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.features: root.tabular
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        enabled: !row.isHeader
                        hoverEnabled: !row.isHeader
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggle(modelData.id)
                    }
                }
            }

            // Strays get no checkbox: moving one somewhere is the user's call.
            Column {
                width: parent.width
                visible: root.strays.length > 0
                spacing: 2

                Row {
                    leftPadding: Theme.spacingS
                    spacing: Theme.spacingS

                    DIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "drive_file_move"
                        size: Theme.iconSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Strays in ~ · " + root.strays.length
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }
                }

                Repeater {
                    model: root.strays

                    StyledText {
                        required property var modelData
                        width: parent.width
                        leftPadding: Theme.spacingS
                        rightPadding: Theme.spacingS
                        text: root.gib(modelData.bytes) + "  " + modelData.label + (modelData.suggestLabel ? "  →  " + modelData.suggestLabel : "")
                        font.pixelSize: Theme.fontSizeSmall
                        font.features: root.tabular
                        color: Theme.surfaceVariantText
                        elide: Text.ElideMiddle
                    }
                }
            }

            StyledText {
                width: parent.width
                leftPadding: Theme.spacingS
                rightPadding: Theme.spacingS
                topPadding: Theme.spacingXS
                visible: root.items.length === 0 && !root.scanning
                text: "Nothing to reclaim."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
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
                        text: root.result.length > 0 ? root.result : root.selectedCount + " of " + root.items.length + " selected"
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.result.length > 0 ? Theme.success : Theme.surfaceVariantText
                    }

                    Rectangle {
                        width: applyLabel.implicitWidth + Theme.spacingL * 2
                        height: applyLabel.implicitHeight + Theme.spacingS * 2
                        radius: height / 2
                        color: root.selectedCount === 0 || root.applying ? Theme.surfaceContainerHigh : Theme.primary

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
        }
    }
}
