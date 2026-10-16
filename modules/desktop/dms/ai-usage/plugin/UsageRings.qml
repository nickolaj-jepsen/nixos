// Two concentric progress rings: `outer` (the short window) and `inner` (the long one).
// Without `inner`, only the outer ring is drawn.
import QtQuick
import qs.Common

Item {
    id: root

    property var outer: null
    property var inner: null
    property color outerColor: Theme.primary
    property color innerColor: Theme.primary
    property real diameter: 18
    property real thickness: Math.max(2.5, diameter / 6.5)

    implicitWidth: diameter
    implicitHeight: diameter

    onOuterChanged: canvas.requestPaint()
    onInnerChanged: canvas.requestPaint()
    onOuterColorChanged: canvas.requestPaint()
    onInnerColorChanged: canvas.requestPaint()

    Canvas {
        id: canvas
        anchors.fill: parent

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const c = width / 2;
            const track = Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.18);
            const ring = (radius, lineWidth, w, color) => {
                ctx.lineWidth = lineWidth;
                ctx.strokeStyle = track;
                ctx.beginPath();
                ctx.arc(c, c, radius, 0, 2 * Math.PI);
                ctx.stroke();
                const frac = w ? Math.max(0, Math.min(1, w.usedPct / 100)) : 0;
                if (frac > 0) {
                    ctx.strokeStyle = color;
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.arc(c, c, radius, -Math.PI / 2, -Math.PI / 2 + frac * 2 * Math.PI);
                    ctx.stroke();
                }
            };
            const edge = Math.min(width, height) / 2;
            const t = root.thickness;
            ring(edge - t / 2, t, root.outer, root.outerColor);
            if (root.inner)
                ring(edge - t * 2, t, root.inner, root.innerColor);
        }
    }
}
