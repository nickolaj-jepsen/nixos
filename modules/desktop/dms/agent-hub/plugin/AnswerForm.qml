// A session's answer form in the popout's pane. It holds no form logic: `form` is the hub's view
// (`forms.view`), and every button is one step back to the hub, which every surface shares.
import QtQuick
import qs.Common
import qs.DCommon.Widgets

Column {
    id: root

    // The row's `answer`.
    required property var form
    // Off for a moment after the pane changes, so a click can't land on what just appeared.
    property bool armed: true

    // One step of the draft, as `form-step` takes it.
    signal step(var action)
    // Leaves the reply for the session's TUI: in its prompt, or sent.
    signal deliver(bool submit)

    // What the field is typing into: the shown item's write-in, or a note.
    property string editing: ""
    readonly property var item: form?.item ?? null

    // Keys the popout hands over: true when the form used it.
    function handleKey(event) {
        if (editing)
            return false;
        const digit = event.key - Qt.Key_1;
        if (digit >= 0 && digit <= 8) {
            if (item)
                pick(digit);
            else if (digit < form.count)
                go({
                    "do": "go",
                    "step": digit
                });
            return true;
        }
        const words = item ? {
            "b": "back",
            "f": "forward",
            "s": "skip",
            "r": "review"
        } : {
            "b": "back"
        };
        if (words[event.text]) {
            go({
                "do": words[event.text]
            });
            return true;
        }
        if (!item && event.text === "n") {
            edit("note");
            return true;
        }
        if (!item && armed && form.reply && (event.text === "y" || event.text === "i")) {
            root.deliver(event.text === "y");
            return true;
        }
        return false;
    }

    function go(action) {
        editing = "";
        root.step(action);
    }

    // A pick is kept and its note field opens; a write-in opens its own.
    function pick(index) {
        const entry = item?.entries[index];
        if (!entry)
            return;
        if (entry.kind === "write") {
            edit("write");
            return;
        }
        root.step({
            "do": "pick",
            "entry": index
        });
        edit("note");
    }

    function edit(what) {
        editing = what;
        field.text = what === "write" ? (item?.written ?? "") : item ? item.note : form.note;
        field.forceActiveFocus();
    }

    function commit() {
        const what = editing;
        editing = "";
        root.step({
            "do": what,
            "text": field.text
        });
    }

    width: parent?.width ?? 0
    spacing: Theme.spacingS

    onFormChanged: {
        // Another surface moved it, or another round replaced it: the field no longer applies.
        if (editing && lastStep !== `${form?.id}:${form?.step}`)
            editing = "";
        lastStep = `${form?.id}:${form?.step}`;
    }
    property string lastStep: ""

    StyledText {
        text: root.item ? `${root.item.label} · ${root.form.step + 1} of ${root.form.count}` : "Review"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    StyledText {
        width: parent.width
        visible: !!root.item
        text: root.item?.title ?? ""
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.Medium
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        visible: !!root.item?.body
        text: root.item?.body ?? ""
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    // The item's entries, or on the review what each one came to.
    Repeater {
        model: root.item ? root.item.entries : root.form?.review ?? []

        Rectangle {
            id: entryRow

            required property var modelData
            required property int index

            readonly property bool isEntry: !!root.item
            readonly property bool isOn: isEntry && modelData.isChosen

            width: root.width
            height: entryColumn.implicitHeight + Theme.spacingXS * 2
            radius: Theme.cornerRadius
            color: isOn ? Theme.withAlpha(Theme.success, 0.18) : Theme.withAlpha(Theme.surfaceText, 0.05)

            Column {
                id: entryColumn

                x: Theme.spacingS
                y: Theme.spacingXS
                width: parent.width - Theme.spacingS * 2

                StyledText {
                    width: parent.width
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall + 1
                    color: Theme.surfaceText
                    text: {
                        const key = entryRow.index < 9 ? `${entryRow.index + 1}  ` : "";
                        if (!entryRow.isEntry) {
                            const note = entryRow.modelData.note ? ` — ${entryRow.modelData.note}` : "";
                            return `${key}${entryRow.modelData.label}  ${entryRow.modelData.shown}${note}`;
                        }
                        const rec = entryRow.modelData.isRecommended ? "  (recommended)" : "";
                        return `${key}${entryRow.modelData.text}${rec}${entryRow.isOn ? "  ✓" : ""}`;
                    }
                }

                StyledText {
                    width: parent.width
                    visible: entryRow.isEntry && !!entryRow.modelData.detail
                    leftPadding: Theme.spacingM
                    wrapMode: Text.Wrap
                    textFormat: Text.PlainText
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: entryRow.isEntry ? entryRow.modelData.detail : ""
                }
            }

            StateLayer {
                onClicked: {
                    if (entryRow.isEntry)
                        root.pick(entryRow.index);
                    else
                        root.go({
                            "do": "go",
                            "step": entryRow.index
                        });
                }
            }
        }
    }

    StyledText {
        width: parent.width
        visible: !!root.item?.written && root.editing !== "write"
        text: `Your answer: ${root.item?.written ?? ""}`
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        readonly property string note: root.item ? root.item.note : root.form?.note ?? ""
        visible: !!note && root.editing !== "note"
        text: `Note: ${note}`
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    Rectangle {
        width: parent.width
        height: 34
        visible: root.editing !== ""
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceText, 0.05)
        border.width: 1
        border.color: field.activeFocus ? Theme.primary : Theme.outline

        TextInput {
            id: field

            anchors.fill: parent
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            color: Theme.surfaceText
            selectionColor: Theme.primary
            font.pixelSize: Theme.fontSizeSmall + 1
            // Not onAccepted: a TextInput lets Return carry on up, where the popout opens the window.
            Keys.onReturnPressed: event => {
                root.commit();
                event.accepted = true;
            }
            Keys.onEnterPressed: event => {
                root.commit();
                event.accepted = true;
            }
            Keys.onEscapePressed: event => {
                root.editing = "";
                event.accepted = true;
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            x: Theme.spacingS
            visible: !field.text
            text: root.editing === "write" ? "Your answer, Enter to save" : root.item ? "A note, or Enter to go on" : "A note on the whole round, Enter to keep"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // The field gave its keys back.
    signal fieldLeft
    onEditingChanged: {
        if (editing)
            return;
        // Or the popout's FocusScope, asked for focus, hands it straight back to the hidden field.
        field.focus = false;
        fieldLeft();
    }

    Column {
        width: parent.width
        visible: !root.item
        spacing: 2

        StyledText {
            text: "The reply"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            text: root.form?.reply || "(nothing answered yet)"
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            font.family: Theme.monoFontFamily
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceText
        }
    }

    StyledText {
        width: parent.width
        visible: root.form?.pending ?? false
        text: "Waiting for the session to take the reply."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.warning
    }

    Row {
        spacing: Theme.spacingS

        Repeater {
            model: root.item ? [
                {
                    "label": "b back",
                    "do": "back"
                },
                {
                    "label": "f forward",
                    "do": "forward"
                },
                {
                    "label": "s skip",
                    "do": "skip"
                },
                {
                    "label": "r review",
                    "do": "review"
                }
            ] : [
                {
                    "label": "b back",
                    "do": "back"
                },
                {
                    "label": "n note",
                    "do": "note"
                },
                {
                    "label": "i to its prompt",
                    "do": "fill"
                },
                {
                    "label": "y send",
                    "do": "send"
                }
            ]

            Rectangle {
                id: navButton

                required property var modelData

                readonly property bool delivers: modelData.do === "fill" || modelData.do === "send"

                width: navLabel.implicitWidth + Theme.spacingM
                height: 26
                radius: Theme.cornerRadius
                enabled: !delivers || (root.armed && !!root.form?.reply)
                opacity: enabled ? 1 : 0.4
                color: modelData.do === "send" ? Theme.primaryContainer : "transparent"
                border.width: modelData.do === "send" ? 0 : 1
                border.color: Theme.outline

                StyledText {
                    id: navLabel
                    anchors.centerIn: parent
                    text: navButton.modelData.label
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }

                StateLayer {
                    onClicked: {
                        const what = navButton.modelData.do;
                        if (what === "note")
                            root.edit("note");
                        else if (navButton.delivers)
                            root.deliver(what === "send");
                        else
                            root.go({
                                "do": what
                            });
                    }
                }
            }
        }
    }
}
