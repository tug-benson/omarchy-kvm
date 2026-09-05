pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.Ui

BarWidget {
    id: root
    moduleName: "io.github.tug-benson.omarchy-kvm"

    readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
        ? (bar.shell.serviceFor("io.github.tug-benson.omarchy-kvm") || bar.shell.serviceFor("omarchy-kvm")) : null
    readonly property bool isBusy: service ? service.busy : false
    readonly property int runCount: service ? service.runningCount : 0
    readonly property int totalCount: service ? service.totalCount : 0
    readonly property bool libvirtdOk: service ? service.libvirtdActive : true

    function injectPanel() {
        var t = panelLoader.item
        if (!t) return
        if ("hostWidget" in t) t.hostWidget = root
        if ("anchorItem" in t) t.anchorItem = button
        if ("bar" in t) t.bar = root.bar
    }

    function togglePanel() {
        if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
    }

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    function open() { if (panelLoader.item && panelLoader.item.open) panelLoader.item.open() }
    function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
    function closeForPopoutSwitch() { if (panelLoader.item && panelLoader.item.closeForPopoutSwitch) panelLoader.item.closeForPopoutSwitch() }

    implicitWidth: button.implicitWidth
    implicitHeight: barSize
    onBarChanged: injectPanel()

    // Datacenter  (U+E91A) not in stable font — fallback to 󰢻, detect via probe
    Text {
        id: datacenterProbe
        visible: false
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Style.space(32)
        text: ""
    }
    readonly property bool hasDatacenter: datacenterProbe.implicitWidth > Style.space(8) && datacenterProbe.implicitWidth < Style.space(36)
    readonly property string kvmGlyph: hasDatacenter ? "" : "󰢻"

    // Nerd Font: kvmGlyph/󰢻 KVM/server, 󰅺 error, 󰐥 play
    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: !root.libvirtdOk ? "󰅺" : root.kvmGlyph
        // badge via tooltip + optional suffix; keep icon simple for bar
        tooltipText: !root.libvirtdOk ? "KVM: libvirtd not reachable — check systemctl"
                   : root.totalCount === 0 ? "KVM: no VMs"
                   : root.runCount + "/" + root.totalCount + " running — click to manage"
        active: root.runCount > 0
        // subtle opacity when no libvirtd
        opacity: root.libvirtdOk ? 1.0 : 0.6
        onPressed: function(b) {
            if (b === Qt.LeftButton) root.togglePanel()
        }
    }

    // Small badge overlay when >0 (optional, uses second label if bar supports)
    // For simplicity badge is in tooltip only; panel shows counts.

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }
}
