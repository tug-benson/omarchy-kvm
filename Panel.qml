pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
    id: root
    moduleName: "io.github.tug-benson.omarchy-kvm"
    manageIpc: false

    property var hostWidget: null
    property var anchorItem: null
    readonly property var barIdentity: hostWidget || root

    function switchPanel(direction) {
        if (bar && typeof bar.switchPanelFrom === "function")
            return bar.switchPanelFrom(barIdentity, direction)
        return false
    }

    readonly property var service: hostWidget && hostWidget.service ? hostWidget.service
        : (bar && bar.shell && typeof bar.shell.serviceFor === "function"
            ? (bar.shell.serviceFor("io.github.tug-benson.omarchy-kvm") || bar.shell.serviceFor("omarchy-kvm")) : null)

    property string expandedVm: ""
    property string newSnapName: ""
    // wizard state
    property bool showWizard: false
    property int wizardStep: 0
    property string wizName: ""
    property string wizOs: "generic"
    property int wizMem: 2048
    property int wizVcpu: 2
    property int wizDisk: 20
    property string wizPool: "default"
    property string wizIso: ""
    property string wizNet: "default"
    property string wizFirmware: "bios"
    property string cloneSrc: ""
    property string cloneDst: ""
    // hardware edit per expanded vm (use wiz fields reused)
    property int editVcpu: 2
    property int editMem: 2048
    property bool editLive: false
    // confirm dialogs
    property string confirmVm: ""
    property string confirmAction: ""
    property bool poolsCollapsed: true
    property bool vmsCollapsed: false
    property bool settingsCollapsed: true
    property string newPoolPath: ""
    property string newPoolName: ""
    property string newDiskPath: ""
    property string diskPickerVm: ""
    // Import OVA/VMDK
    property bool showImport: false
    property string importFile: ""
    property string importVmName: ""
    property int importMem: 2048
    property int importVcpus: 2
    property string importPoolPath: ""
    property string importOsVariant: "generic"
    property bool importNoCreate: false

    // zenity pickers (avoid native FileDialog crash in layer-shell)
    Process {
        id: isoPicker
        command: ["zenity", "--file-selection", "--title=Select ISO image", "--file-filter=ISO images | *.iso", "--file-filter=All files | *"]
        stdout: StdioCollector { id: isoOut; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            if (code === 0) {
                var p = isoOut.text.trim()
                if (p) root.wizIso = p
            }
        }
    }
    Process {
        id: poolDirPicker
        command: ["zenity", "--file-selection", "--directory", "--title=Select VM image directory"]
        stdout: StdioCollector { id: poolDirOut; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            if (code === 0) {
                var p = poolDirOut.text.trim()
                if (p) root.newPoolPath = p
            }
        }
    }
    Process {
        id: diskPicker
        command: ["zenity", "--file-selection", "--title=Select disk image", "--file-filter=Disk images | *.qcow2 *.img *.raw", "--file-filter=All files | *"]
        stdout: StdioCollector { id: diskPickerOut; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            if (code === 0) {
                var p = diskPickerOut.text.trim()
                if (p) root.newDiskPath = p
            }
        }
    }
    Process {
        id: importFilePicker
        command: ["zenity", "--file-selection", "--title=Select OVA/VMDK", "--file-filter=OVA/VMDK | *.ova *.vmdk *.vmdk.gz", "--file-filter=All files | *"]
        stdout: StdioCollector { id: importFileOut; waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            if (code === 0) {
                var p = importFileOut.text.trim()
                if (p) {
                    root.importFile = p
                    if (!root.importVmName) {
                        var base = p.split("/").pop().split(".")[0].replace(/[^a-zA-Z0-9._-]/g, "")
                        if (base) root.importVmName = base
                    }
                    if (!root.importPoolPath && service) root.importPoolPath = service.defaultPoolPath
                }
            }
        }
    }
    Process {
        id: copyLogProc
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            if (code === 0) { if (service) service.lastInfo = "Copied to clipboard" }
            else { if (service) service.lastError = "Copy failed — install wl-clipboard (wl-copy) or xclip" }
        }
    }
    function copyToClipboard(text) {
        if (!text) return
        if (text.length > 65536) text = text.substring(0, 65536)
        copyLogProc.environment = {"TEXT": text}
        copyLogProc.command = ["bash", "-lc", "printf '%s' \"$TEXT\" | wl-copy 2>/dev/null || printf '%s' \"$TEXT\" | xclip -selection clipboard 2>/dev/null || (echo \"no clipboard tool\" >&2; exit 1)"]
        copyLogProc.running = true
    }

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: Style.space(420)
        contentHeight: panel.fittedContentHeight(flick.contentHeight + Style.space(16))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(dir) { root.switchPanel(dir) }

            Flickable {
                id: flick
                anchors.fill: parent
                contentWidth: width
                contentHeight: col.implicitHeight + Style.space(12)
                clip: true

                ColumnLayout {
                    id: col
                    width: flick.width - Style.space(16)
                    x: Style.space(8)
                    y: Style.space(8)
                    spacing: Style.space(8)

                    // ── Header ──
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Label {
                            textFormat: Text.PlainText
                            text: ""
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: Style.space(32)
                            color: Color.accent
                            Layout.alignment: Qt.AlignVCenter
                            Layout.preferredWidth: Style.space(36)
                            Layout.preferredHeight: Style.space(36)
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignHCenter
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Label {
                                textFormat: Text.PlainText
                                text: "KVM Manager"
                                font.family: Style.font.family
                                font.pixelSize: Style.font.title + 1
                                font.bold: true
                                color: Color.foreground
                            }
                            Label {
                                textFormat: Text.PlainText
                                text: service ? (service.runningCount + "/" + service.totalCount + " running  •  " + (service.defaultNetActive ? "virbr0 up" : "virbr0 down") + (service.libvirtdActive ? "" : "  •  libvirtd down")) : "--"
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                color: Color.muted
                            }
                        }
                        Button {
                            iconText: ""
                            fontFamily: "JetBrainsMono Nerd Font"
                            fontSize: Style.font.caption
                            tooltipText: "Refresh"
                            Layout.preferredWidth: Style.space(26)
                            onClicked: { if (service) { service.refresh(); service.refreshPools() } }
                        }
                    }

                    // libvirtd warning
                    Rectangle {
                        Layout.fillWidth: true
                        visible: service && !service.libvirtdActive
                        radius: Style.space(6)
                        color: Util.alpha(Color.urgent, 0.12)
                        border.color: Util.alpha(Color.urgent, 0.35)
                        border.width: 1
                        implicitHeight: warnCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: warnCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(4)
                            Label { textFormat: Text.PlainText; text: "libvirtd not reachable"; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; color: Color.urgent }
                            Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: "Run: sudo systemctl enable --now libvirtd  +  sudo virsh net-start default"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.caption - 1; color: Color.muted; wrapMode: Text.Wrap }
                        }
                    }

                    // tool warnings (P1)
                    Rectangle {
                        Layout.fillWidth: true
                        visible: service && service.toolStatus && (service.toolStatus.virtInstall === false || service.toolStatus.virtViewer === false)
                        radius: Style.space(6)
                        color: Util.alpha(Color.muted, 0.08)
                        border.color: Util.alpha(Color.muted, 0.2)
                        border.width: 1
                        implicitHeight: toolCol.implicitHeight + Style.space(10)
                        ColumnLayout {
                            id: toolCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: 2
                            Label { visible: service && service.toolStatus.virtInstall===false; textFormat: Text.PlainText; text: "⚠ virt-install missing — creation disabled (install virtinst)"; font.family: Style.font.family; font.pixelSize: Style.font.caption -1; color: Color.urgent; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { visible: service && service.toolStatus.virtViewer===false; textFormat: Text.PlainText; text: "⚠ virt-viewer missing — console disabled (install virt-viewer)"; font.family: Style.font.family; font.pixelSize: Style.font.caption -1; color: Color.urgent; wrapMode: Text.Wrap; Layout.fillWidth: true }
                            Label { visible: service && service.toolStatus.osinfo===false; textFormat: Text.PlainText; text: "ℹ osinfo-query missing — OS list limited (install libosinfo)"; font.family: Style.font.family; font.pixelSize: Style.font.caption -1; color: Color.muted; wrapMode: Text.Wrap; Layout.fillWidth: true }
                        }
                    }

                    // ── Filters + virt-manager row ──
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(6)
                        TextField {
                            Layout.fillWidth: true
                            placeholderText: "  Filter name, title..."
                            font.family: Style.font.family
                            font.pixelSize: Style.font.body
                            text: service ? service.searchText : ""
                            onTextChanged: if (service) service.searchText = text
                        }
                        Button {
                            iconText: "󰍉"
                            fontFamily: "JetBrainsMono Nerd Font"
                            fontSize: Style.font.body
                            tooltipText: "Open virt-manager"
                            Layout.preferredWidth: Style.space(30)
                            onClicked: if (service) service.launchVirtManager()
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(4)
                        Repeater {
                            model: ["all", "running", "off", "paused"]
                            delegate: Button {
                                required property string modelData
                                text: modelData === "all" ? "All" : modelData === "off" ? "Off" : modelData.charAt(0).toUpperCase() + modelData.slice(1)
                                fontSize: Style.font.caption
                                Layout.fillWidth: true
                                opacity: service && service.filterState === modelData ? 1.0 : 0.7
                                onClicked: if (service) service.filterState = modelData
                            }
                        }
                    }

                    // error / info
                    Label {
                        Layout.fillWidth: true
                        visible: service && service.lastError
                        textFormat: Text.PlainText
                        text: service ? service.lastError : ""
                        font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.urgent; wrapMode: Text.Wrap
                    }
                    Label {
                        Layout.fillWidth: true
                        visible: service && service.lastInfo
                        textFormat: Text.PlainText
                        text: service ? service.lastInfo : ""
                        font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.accent; wrapMode: Text.Wrap
                    }

                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.rgba(1,1,1,0.08) }

                    // ── New VM button + Wizard ──
                    Button {
                        Layout.fillWidth: true
                        text: root.showWizard ? "▾  Close Wizard" : "＋  New VM (wizard)"
                        fontSize: Style.font.caption
                        onClicked: root.showWizard = !root.showWizard
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.showWizard
                        radius: Style.space(6)
                        color: Util.alpha(Color.background, 0.4)
                        border.color: Util.alpha(Color.accent, 0.25)
                        border.width: 1
                        implicitHeight: wizCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: wizCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(6)
                            // step indicator
                            Label { textFormat: Text.PlainText; text: "Step " + (root.wizardStep+1) + "/5 — " + ["General","Resources","Storage","Network","Summary"][root.wizardStep]; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; color: Color.accent }
                            // step 0: General
                            ColumnLayout { visible: root.wizardStep===0; spacing: Style.space(4); Layout.fillWidth: true
                                Label { textFormat: Text.PlainText; text: "Name *"; font.pixelSize: Style.font.caption; color: Color.muted }
                                TextField { Layout.fillWidth: true; text: root.wizName; placeholderText: "vm-test-01"; font.pixelSize: Style.font.caption; onTextChanged: root.wizName=text }
                                Label { textFormat: Text.PlainText; text: "OS variant"; font.pixelSize: Style.font.caption; color: Color.muted }
                                SearchableDropdown {
                                    Layout.fillWidth: true
                                    value: root.wizOs
                                    options: service ? (service.osVariants.length? service.osVariants : ["generic","generic-virtio","debian12","ubuntu24.04","fedora40","archlinux"]) : ["generic"]
                                    placeholderText: "Search OS variant…"
                                    onChanged: function(v){ root.wizOs = v }
                                }
                            }
                            // step 1: Resources
                            ColumnLayout { visible: root.wizardStep===1; spacing: Style.space(4); Layout.fillWidth: true
                                RowLayout { Layout.fillWidth: true; spacing: Style.space(6)
                                    Label { textFormat: Text.PlainText; text: "vCPU"; font.pixelSize: Style.font.caption; color: Color.muted }
                                    SpinBox { from: 1; to: 32; value: root.wizVcpu; onValueChanged: root.wizVcpu = value }
                                    Label { textFormat: Text.PlainText; text: "RAM MB"; font.pixelSize: Style.font.caption; color: Color.muted }
                                    SpinBox { from: 256; to: 65536; stepSize: 256; value: root.wizMem; onValueChanged: root.wizMem = value }
                                }
                                Label { textFormat: Text.PlainText; text: "Firmware"; font.pixelSize: Style.font.caption; color: Color.muted }
                                Dropdown {
                                    Layout.fillWidth: true
                                    value: root.wizFirmware
                                    options: ["bios","uefi"]
                                    showLabel: false
                                    onChanged: function(v){ root.wizFirmware = v }
                                }
                            }
                            // step 2: Storage
                            ColumnLayout { visible: root.wizardStep===2; spacing: Style.space(4); Layout.fillWidth: true
                                RowLayout { Label { textFormat: Text.PlainText; text: "Disk GB"; font.pixelSize: Style.font.caption; color: Color.muted } SpinBox { from: 1; to: 2000; value: root.wizDisk; onValueChanged: root.wizDisk = value } }
                                RowLayout { Label { textFormat: Text.PlainText; text: "Pool"; font.pixelSize: Style.font.caption; color: Color.muted } TextField { Layout.fillWidth: true; text: root.wizPool; font.pixelSize: Style.font.caption; onTextChanged: root.wizPool=text } }
                                RowLayout {
                                    Label { textFormat: Text.PlainText; text: "ISO"; font.pixelSize: Style.font.caption; color: Color.muted }
                                    TextField { Layout.fillWidth: true; text: root.wizIso; placeholderText: "/path/to.iso (optional)"; font.pixelSize: Style.font.caption; onTextChanged: root.wizIso=text }
                                    Button {
                                        iconText: "󰉋"
                                        fontFamily: "JetBrainsMono Nerd Font"
                                        fontSize: Style.font.caption
                                        tooltipText: "Browse ISO…"
                                        Layout.preferredWidth: Style.space(28)
                                        onClicked: isoPicker.running = true
                                    }
                                }
                            }
                            // step 3: Network
                            ColumnLayout { visible: root.wizardStep===3; spacing: Style.space(4); Layout.fillWidth: true
                                RowLayout { Label { textFormat: Text.PlainText; text: "Network"; font.pixelSize: Style.font.caption; color: Color.muted } TextField { Layout.fillWidth: true; text: root.wizNet; font.pixelSize: Style.font.caption; onTextChanged: root.wizNet=text } }
                                Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: "Pool/Network will be auto-created if missing (default)."; font.pixelSize: Style.font.caption-1; color: Color.muted; wrapMode: Text.Wrap }
                            }
                            // step 4: Summary
                            ColumnLayout { visible: root.wizardStep===4; spacing: Style.space(4); Layout.fillWidth: true
                                Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.wizName + " — " + root.wizOs + " — " + root.wizVcpu + " vCPU / " + root.wizMem + " MB — " + root.wizDisk + " GB ("+root.wizPool+") — " + root.wizNet + " — " + root.wizFirmware + (root.wizIso? " — ISO "+root.wizIso:""); font.pixelSize: Style.font.caption; color: Color.foreground; wrapMode: Text.Wrap }
                                Rectangle { Layout.fillWidth: true; implicitHeight: logView.implicitHeight + 8; color: Util.alpha(Color.foreground,0.04); radius: 4; visible: service && service.wizardLog
                                    Label { id: logView; anchors.fill: parent; anchors.margins: 6; textFormat: Text.PlainText; text: service ? service.wizardLog : ""; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.caption-1; color: Color.muted; wrapMode: Text.Wrap }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: service && service.wizardLog
                                    spacing: Style.space(6)
                                    Button { text: "⎘ Copy log"; fontSize: Style.font.caption; Layout.fillWidth: true; onClicked: root.copyToClipboard(service.wizardLog) }
                                    Button { text: "⎘ Copy summary"; fontSize: Style.font.caption; Layout.fillWidth: true; onClicked: root.copyToClipboard(root.wizName + " — " + root.wizOs + " — " + root.wizVcpu + " vCPU / " + root.wizMem + " MB — " + root.wizDisk + " GB ("+root.wizPool+") — " + root.wizNet + " — " + root.wizFirmware + (root.wizIso? " — ISO "+root.wizIso:"")) }
                                }
                                Label { visible: service && service.wizardRunning; textFormat: Text.PlainText; text: "⏳ Creating… please wait"; font.pixelSize: Style.font.caption; color: Color.accent }
                            }
                            // nav
                            RowLayout {
                                Layout.fillWidth: true
                                Button { text: "‹ Back"; fontSize: Style.font.caption; enabled: root.wizardStep>0; Layout.fillWidth: true; onClicked: root.wizardStep-- }
                                Button { text: root.wizardStep<4? "Next ›" : "Create"; fontSize: Style.font.caption; Layout.fillWidth: true; enabled: root.wizName.length>0 && (service ? !service.wizardRunning : true);
                                    onClicked: {
                                        if (root.wizardStep<4) root.wizardStep++
                                        else if (service) service.createVm({name: root.wizName, osVariant: root.wizOs, memoryMb: root.wizMem, vcpus: root.wizVcpu, diskSizeGb: root.wizDisk, poolName: root.wizPool, isoPath: root.wizIso, networkName: root.wizNet, bootFirmware: root.wizFirmware, graphicsType: "spice"})
                                    }
                                }
                            }
                            Button { Layout.fillWidth: true; text: "Cancel"; fontSize: Style.font.caption; onClicked: root.showWizard=false }
                        }
                    }

                    // ── Import OVA/VMDK (local) ──
                    Button {
                        Layout.fillWidth: true
                        text: root.showImport ? "▾  Close Import" : "⬆ Import OVA/VMDK"
                        fontSize: Style.font.caption
                        onClicked: root.showImport = !root.showImport
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.showImport
                        radius: Style.space(6)
                        color: Util.alpha(Color.background, 0.4)
                        border.color: Util.alpha(Color.accent, 0.25)
                        border.width: 1
                        implicitHeight: importCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: importCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(6)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: "File *"; font.pixelSize: Style.font.caption; color: Color.muted }
                                TextField { Layout.fillWidth: true; text: root.importFile; placeholderText: "/path/to/file.ova"; font.pixelSize: Style.font.caption; onTextChanged: root.importFile = text }
                                Button { iconText: "󰉋"; fontFamily: "JetBrainsMono Nerd Font"; fontSize: Style.font.caption; tooltipText: "Browse OVA/VMDK…"; Layout.preferredWidth: Style.space(28); onClicked: importFilePicker.running = true }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: "Target"; font.pixelSize: Style.font.caption; color: Color.muted }
                                Label { textFormat: Text.PlainText; text: "KVM local (qemu:///system)"; font.pixelSize: Style.font.caption; color: Color.accent; font.bold: true; Layout.fillWidth: true }
                                Label { textFormat: Text.PlainText; text: "Proxmox excluded"; font.pixelSize: Style.font.caption -1; color: Color.muted; opacity: 0.6 }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: "VM Name *"; font.pixelSize: Style.font.caption; color: Color.muted }
                                TextField { Layout.fillWidth: true; text: root.importVmName; placeholderText: "my-vm"; font.pixelSize: Style.font.caption; onTextChanged: root.importVmName = text }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: "RAM MB"; font.pixelSize: Style.font.caption; color: Color.muted }
                                SpinBox { from: 256; to: 65536; stepSize: 256; value: root.importMem; onValueChanged: root.importMem = value; Layout.preferredWidth: Style.space(90) }
                                Label { textFormat: Text.PlainText; text: "vCPUs"; font.pixelSize: Style.font.caption; color: Color.muted }
                                SpinBox { from: 1; to: 32; value: root.importVcpus; onValueChanged: root.importVcpus = value; Layout.preferredWidth: Style.space(70) }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: "Pool Path *"; font.pixelSize: Style.font.caption; color: Color.muted }
                                TextField { Layout.fillWidth: true; text: root.importPoolPath; placeholderText: service ? service.defaultPoolPath : "/var/lib/libvirt/images"; font.pixelSize: Style.font.caption; onTextChanged: root.importPoolPath = text }
                                Button { iconText: "󰉋"; fontFamily: "JetBrainsMono Nerd Font"; fontSize: Style.font.caption; tooltipText: "Browse directory…"; Layout.preferredWidth: Style.space(28); onClicked: poolDirPicker.running = true }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: "OS Variant"; font.pixelSize: Style.font.caption; color: Color.muted }
                                SearchableDropdown {
                                    Layout.fillWidth: true
                                    value: root.importOsVariant
                                    options: service ? (service.osVariants.length? service.osVariants : ["generic","debian12","ubuntu24.04"]) : ["generic"]
                                    placeholderText: "Search OS…"
                                    onChanged: function(value){ root.importOsVariant = value }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                CheckBox { id: importNoCreateChk; text: "Only convert (no VM creation)"; checked: root.importNoCreate; onCheckedChanged: root.importNoCreate = checked; font.pixelSize: Style.font.caption }
                            }
                            Button {
                                Layout.fillWidth: true
                                text: service && service.importBusy ? "⏳ Importing…" : "⬆ Import"
                                fontSize: Style.font.caption
                                enabled: service && !service.importBusy && root.importFile.length>0 && root.importVmName.length>0 && root.importPoolPath.length>0
                                onClicked: {
                                    if (service) service.importDisk({filePath: root.importFile, vmName: root.importVmName, memoryMb: root.importMem, vcpus: root.importVcpus, poolPath: root.importPoolPath, osVariant: root.importOsVariant, noCreate: root.importNoCreate})
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                visible: service && (service.importLog || service.importError)
                                radius: 4
                                color: Util.alpha(Color.foreground,0.04)
                                implicitHeight: Math.min(importLogFlick.contentHeight + 12, Style.space(150))
                                clip: true
                                Flickable {
                                    id: importLogFlick
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    contentWidth: width
                                    contentHeight: importLogLbl.implicitHeight
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    Label {
                                        id: importLogLbl
                                        width: parent.width
                                        textFormat: Text.PlainText
                                        text: service ? (service.importLog + (service.importError ? "\n" + service.importError : "")) : ""
                                        font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: Style.font.caption -1
                                        color: service && service.importError ? Color.urgent : Color.muted
                                        wrapMode: Text.Wrap
                                    }
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                visible: service && service.importLog
                                spacing: Style.space(4)
                                Button { text: "⎘ Copy log"; fontSize: Style.font.caption -1; Layout.fillWidth: true; onClicked: root.copyToClipboard(service.importLog) }
                                Button { text: "Clear"; fontSize: Style.font.caption -1; Layout.fillWidth: true; onClicked: { service.importLog=""; service.importError="" } }
                            }
                        }
                    }

                    // ── VM list ── collapsable + scrollable
                    Rectangle {
                        Layout.fillWidth: true
                        radius: Style.space(6)
                        color: Util.alpha(Color.foreground, 0.02)
                        border.color: Util.alpha(Color.foreground, 0.06)
                        border.width: 1
                        implicitHeight: vmsCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: vmsCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(6)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label {
                                    textFormat: Text.PlainText
                                    text: root.vmsCollapsed ? "" : ""
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: Style.font.caption
                                    color: Color.accent
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.vmsCollapsed = !root.vmsCollapsed }
                                }
                                Label {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: "Virtual Machines (" + (service ? service.filteredVms.length : 0) + "/" + (service ? service.totalCount : 0) + ")"
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    color: Color.foreground
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.vmsCollapsed = !root.vmsCollapsed }
                                }
                                Label {
                                    visible: !root.vmsCollapsed && service && service.filteredVms.length > 0
                                    textFormat: Text.PlainText
                                    text: service ? service.runningCount + " running" : ""
                                    font.pixelSize: Style.font.caption - 1
                                    color: Color.muted
                                    opacity: 0.7
                                }
                            }
                            Label {
                                visible: !root.vmsCollapsed && service && service.filteredVms.length === 0 && service.vms.length === 0
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: "No VMs — use wizard above or virt-manager"
                                font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.muted
                                horizontalAlignment: Text.AlignHCenter
                                topPadding: Style.space(4)
                            }
                            Label {
                                visible: !root.vmsCollapsed && service && service.filteredVms.length === 0 && service.vms.length > 0
                                Layout.fillWidth: true
                                textFormat: Text.PlainText
                                text: "No match for filter"
                                font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.muted
                                horizontalAlignment: Text.AlignHCenter
                            }
                            Flickable {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.min(vmsRepeater.implicitHeight + Style.space(6), Style.space(340))
                                visible: !root.vmsCollapsed
                                contentWidth: width
                                contentHeight: vmsRepeater.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                ColumnLayout {
                                    id: vmsRepeater
                                    width: parent.width
                                    spacing: Style.space(6)
                                    Repeater {
                                        model: service ? service.filteredVms : []
                                        delegate: Rectangle {
                                id: row
                                required property var modelData
                                required property int index
                                readonly property string vmName: modelData.name
                                readonly property string vmState: modelData.state
                                readonly property bool isRunning: vmState === "running"
                                readonly property bool isPaused: vmState === "paused"
                                readonly property bool isOff: !isRunning && !isPaused
                                readonly property bool expanded: root.expandedVm === vmName
                                Layout.fillWidth: true
                                radius: Style.space(6)
                                color: isRunning ? Util.alpha(Color.accent, 0.10) : isPaused ? Util.alpha(Color.muted, 0.08) : Util.alpha(Color.foreground, 0.04)
                                border.color: isRunning ? Util.alpha(Color.accent, 0.28) : Util.alpha(Color.foreground, 0.08)
                                border.width: 1
                                implicitHeight: innerCol.implicitHeight + Style.space(10)

                                ColumnLayout {
                                    id: innerCol
                                    anchors.fill: parent
                                    anchors.margins: Style.space(8)
                                    spacing: Style.space(6)

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Style.space(6)
                                        Label {
                                            textFormat: Text.PlainText
                                            text: row.isRunning ? "󰐥" : row.isPaused ? "󰏤" : "󰓛"
                                            font.family: "JetBrainsMono Nerd Font"
                                            font.pixelSize: Style.font.body + 2
                                            color: row.isRunning ? Color.accent : row.isPaused ? Color.muted : Qt.rgba(1,1,1,0.5)
                                        }
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 0
                                            Label {
                                                Layout.fillWidth: true
                                                textFormat: Text.PlainText
                                                text: row.vmName
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.body
                                                font.bold: true
                                                color: Color.foreground
                                                elide: Text.ElideRight
                                            }
                                            Label {
                                                Layout.fillWidth: true
                                                textFormat: Text.PlainText
                                                text: (modelData.title ? modelData.title + " · " : "") + row.vmState + " · " + modelData.vcpu + " vCPU · " + Math.round(modelData.ramKiB/1024) + " MB" + (modelData.autostart ? " · autostart" : "") + (modelData.snapshots ? " · " + modelData.snapshots + " snaps" : "")
                                                font.family: Style.font.family
                                                font.pixelSize: Style.font.caption
                                                color: Color.muted
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Button {
                                            iconText: row.expanded ? "" : ""
                                            fontFamily: "JetBrainsMono Nerd Font"
                                            fontSize: Style.font.caption
                                            tooltipText: "Details"
                                            Layout.preferredWidth: Style.space(22)
                                            onClicked: {
                                                var willExpand = !row.expanded
                                                root.expandedVm = willExpand ? row.vmName : ""
                                                if (willExpand && service) {
                                                    service.fetchStats(row.vmName)
                                                    service.fetchVmNet(row.vmName)
                                                    service.refreshHostNetworks()
                                                    service.fetchDiskPath(row.vmName)
                                                }
                                            }
                                        }
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Style.space(4)
                                        Button {
                                            iconText: "⏻"
                                            fontFamily: "JetBrainsMono Nerd Font"
                                            text: row.isRunning ? "Shutdown" : "Start"
                                            foreground: row.isRunning ? Color.urgent : Color.accent
                                            fontSize: Style.font.caption
                                            Layout.fillWidth: true
                                            enabled: service && !service.busy
                                            onClicked: row.isRunning ? service.shutdownVm(row.vmName) : service.startVm(row.vmName)
                                        }
                                        Button {
                                            iconText: "󰜉"
                                            fontFamily: "JetBrainsMono Nerd Font"
                                            fontSize: Style.font.caption
                                            tooltipText: "Reboot"
                                            Layout.preferredWidth: Style.space(30)
                                            enabled: row.isRunning && service && !service.busy
                                            onClicked: if (service) service.rebootVm(row.vmName)
                                        }
                                        Button {
                                            iconText: row.isPaused ? "󰐥" : "󰏤"
                                            fontFamily: "JetBrainsMono Nerd Font"
                                            fontSize: Style.font.caption
                                            tooltipText: row.isPaused ? "Resume" : "Suspend"
                                            Layout.preferredWidth: Style.space(30)
                                            enabled: (row.isRunning || row.isPaused) && service && !service.busy
                                            onClicked: row.isPaused ? service.resumeVm(row.vmName) : service.suspendVm(row.vmName)
                                        }
                                        Button {
                                            iconText: ""
                                            fontFamily: "JetBrainsMono Nerd Font"
                                            fontSize: Style.font.caption
                                            tooltipText: "Console (virt-viewer)"
                                            Layout.preferredWidth: Style.space(30)
                                            enabled: service && !service.busy
                                            onClicked: if (service) service.openConsole(row.vmName)
                                        }
                                        Button {
                                            iconText: ""
                                            fontFamily: "JetBrainsMono Nerd Font"
                                            fontSize: Style.font.caption
                                            tooltipText: "Force off (destroy)"
                                            Layout.preferredWidth: Style.space(30)
                                            enabled: row.isRunning && service && !service.busy
                                            onClicked: { root.confirmVm=row.vmName; root.confirmAction="destroy" }
                                        }
                                    }

                                    // expanded detail — lifecycle, hardware, snapshots, clone, delete
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        visible: row.expanded
                                        spacing: Style.space(6)
                                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.rgba(1,1,1,0.06) }

                                        // autostart + hardware
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(4)
                                            Label { textFormat: Text.PlainText; text: "Autostart"; font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.muted; Layout.fillWidth: true }
                                            ToggleSwitch {
                                                checked: modelData.autostart === true
                                                onToggled: function(checked) { if (checked) service.autostartOn(row.vmName); else service.autostartOff(row.vmName) }
                                            }
                                        }
                                        // hardware edit (P2 — à froid si running sans live)
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(4)
                                            Label { textFormat: Text.PlainText; text: "vCPU"; font.pixelSize: Style.font.caption - 1; color: Color.muted }
                                            SpinBox { from: 1; to: 32; value: modelData.vcpu || 2; onValueChanged: root.editVcpu = value; Layout.preferredWidth: Style.space(70) }
                                            Label { textFormat: Text.PlainText; text: "RAM"; font.pixelSize: Style.font.caption - 1; color: Color.muted }
                                            SpinBox { from: 256; to: 65536; stepSize: 256; value: Math.round(modelData.ramKiB/1024) || 2048; onValueChanged: root.editMem = value; Layout.preferredWidth: Style.space(90) }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(6)
                                            CheckBox { id: liveChk; text: "Live"; checked: root.editLive; onCheckedChanged: root.editLive=checked }
                                            Button { text: "Apply HW"; fontSize: Style.font.caption; Layout.fillWidth: true; onClicked: { service.setVcpus(row.vmName, root.editVcpu, liveChk.checked); service.setMemory(row.vmName, root.editMem, liveChk.checked) } }
                                        }
                                        Label { visible: row.isRunning && !liveChk.checked; Layout.fillWidth: true; textFormat: Text.PlainText; text: "VM running — coche Live ou arrête la VM pour appliquer à froid."; font.pixelSize: Style.font.caption-1; color: Color.urgent; wrapMode: Text.Wrap }

                                        // disk relink (after pool move)
                                        Rectangle {
                                            Layout.fillWidth: true
                                            visible: true
                                            radius: 4
                                            color: Util.alpha(Color.foreground,0.04)
                                            border.color: Util.alpha(Color.foreground,0.08)
                                            border.width: 1
                                            implicitHeight: diskRelinkCol.implicitHeight + 8
                                            ColumnLayout {
                                                id: diskRelinkCol
                                                anchors.fill: parent
                                                anchors.margins: 6
                                                spacing: 4
                                                Label {
                                                    textFormat: Text.PlainText
                                                    text: "Disk"
                                                    font.pixelSize: Style.font.caption
                                                    font.bold: true
                                                    color: Color.foreground
                                                }
                                                Label {
                                                    Layout.fillWidth: true
                                                    textFormat: Text.PlainText
                                                    text: service ? (service.lastDiskPath ? service.lastDiskPath : "—") : "—"
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: Style.font.caption - 1
                                                    color: Color.muted
                                                    wrapMode: Text.Wrap
                                                    elide: Text.ElideMiddle
                                                    MouseArea {
                                                        anchors.fill: parent
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: if (service) service.fetchDiskPath(row.vmName)
                                                    }
                                                }
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: Style.space(4)
                                                    TextField {
                                                        Layout.fillWidth: true
                                                        placeholderText: "/home/user/VMs/disk.qcow2"
                                                        text: root.newDiskPath
                                                        font.pixelSize: Style.font.caption
                                                        onTextChanged: root.newDiskPath = text
                                                    }
                                                    Button {
                                                        iconText: "󰉋"
                                                        fontFamily: "JetBrainsMono Nerd Font"
                                                        fontSize: Style.font.caption
                                                        tooltipText: "Browse disk…"
                                                        Layout.preferredWidth: Style.space(28)
                                                        onClicked: { root.diskPickerVm = row.vmName; diskPicker.running = true }
                                                    }
                                                    Button {
                                                        text: "Relink"
                                                        fontSize: Style.font.caption
                                                        Layout.preferredWidth: Style.space(50)
                                                        enabled: root.newDiskPath.length > 0 && service && !service.busy
                                                        onClicked: { service.relinkDisk(row.vmName, root.newDiskPath); root.newDiskPath = "" }
                                                    }
                                                }
                                                Label {
                                                    visible: service && service.lastDiskPath && service.lastDiskPath.indexOf("/var/lib/libvirt/images") !== -1 && service.defaultPoolPath && service.defaultPoolPath.indexOf("/home") !== -1
                                                    Layout.fillWidth: true
                                                    textFormat: Text.PlainText
                                                    text: "⚠ Disk still at old location (/var) but pool now at " + (service ? service.defaultPoolPath : "") + " — relink to new path."
                                                    font.pixelSize: Style.font.caption - 1
                                                    color: Color.urgent
                                                    wrapMode: Text.Wrap
                                                }
                                            }
                                        }

                                        // network interface (NAT vs Bridge) — per blog.stephane-robert.info
                                        Rectangle {
                                            Layout.fillWidth: true
                                            radius: 4
                                            color: Util.alpha(Color.foreground,0.04)
                                            border.color: Util.alpha(Color.foreground,0.08)
                                            border.width: 1
                                            implicitHeight: netChoiceCol.implicitHeight + 8
                                            ColumnLayout {
                                                id: netChoiceCol
                                                anchors.fill: parent
                                                anchors.margins: 6
                                                spacing: 4
                                                Label {
                                                    textFormat: Text.PlainText
                                                    text: "Network"
                                                    font.pixelSize: Style.font.caption
                                                    font.bold: true
                                                    color: Color.foreground
                                                }
                                                Label {
                                                    Layout.fillWidth: true
                                                    textFormat: Text.PlainText
                                                    text: service ? (service.vmNetType + ":" + service.vmNetSource + " (" + (service.vmNetType === "bridge" ? "Bridge, LAN IP" : "NAT, virbr0 192.168.122.0/24") + ")") : "—"
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: Style.font.caption - 1
                                                    color: Color.muted
                                                    wrapMode: Text.Wrap
                                                    elide: Text.ElideMiddle
                                                }
                                                Label {
                                                    Layout.fillWidth: true
                                                    textFormat: Text.PlainText
                                                    text: "NAT = private (192.168.122.x), Internet via host. Bridge = LAN IP, needs br0 (see blog.stephane-robert.info)"
                                                    font.pixelSize: Style.font.caption - 1
                                                    color: Color.muted
                                                    wrapMode: Text.Wrap
                                                    opacity: 0.6
                                                }
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: Style.space(4)
                                                    Label { textFormat: Text.PlainText; text: "Type"; font.pixelSize: Style.font.caption; color: Color.muted }
                                                    Dropdown {
                                                        id: netTypeDropdown
                                                        Layout.preferredWidth: Style.space(90)
                                                        value: service ? service.vmNetType : "network"
                                                        options: ["network", "bridge"]
                                                        showLabel: false
                                                        onChanged: function(value){ if (service) service.vmNetType = value }
                                                    }
                                                    Label { textFormat: Text.PlainText; text: "Source"; font.pixelSize: Style.font.caption; color: Color.muted }
                                                    SearchableDropdown {
                                                        Layout.fillWidth: true
                                                        value: service ? service.vmNetSource : "default"
                                                        options: netTypeDropdown.value === "bridge" ? (service ? (service.hostBridges.length ? service.hostBridges : ["br0", "virbr0", "enp5s0"]) : ["br0"]) : (service ? (service.libvirtNetworks.length ? service.libvirtNetworks : ["default"]) : ["default"])
                                                        placeholderText: "Source…"
                                                        onChanged: function(value){ if (service) service.vmNetSource = value }
                                                    }
                                                }
                                                RowLayout {
                                                    Layout.fillWidth: true
                                                    spacing: Style.space(4)
                                                    CheckBox { id: netLiveChk2; text: "Live"; checked: false; font.pixelSize: Style.font.caption }
                                                    Button {
                                                        text: "Apply Network"
                                                        fontSize: Style.font.caption
                                                        Layout.fillWidth: true
                                                        enabled: service && !service.busy && service.vmNetSource
                                                        onClicked: service.setVmNetwork(row.vmName, netTypeDropdown.value, service.vmNetSource, netLiveChk2.checked)
                                                    }
                                                    Button {
                                                        iconText: ""
                                                        fontFamily: "JetBrainsMono Nerd Font"
                                                        fontSize: Style.font.caption
                                                        tooltipText: "Refresh networks"
                                                        Layout.preferredWidth: Style.space(28)
                                                        onClicked: { service.fetchVmNet(row.vmName); service.refreshHostNetworks() }
                                                    }
                                                }
                                                Label {
                                                    visible: netTypeDropdown.value === "bridge" && service && service.hostBridges.indexOf(service.vmNetSource) === -1
                                                    Layout.fillWidth: true
                                                    textFormat: Text.PlainText
                                                    text: "Bridge '" + (service ? service.vmNetSource : "") + "' not found. Create it first: nmcli connection add type bridge ifname " + (service ? service.vmNetSource : "br0") + " con-name " + (service ? service.vmNetSource : "br0") + " && nmcli connection up " + (service ? service.vmNetSource : "br0")
                                                    font.pixelSize: Style.font.caption - 1
                                                    color: Color.urgent
                                                    wrapMode: Text.Wrap
                                                }
                                                // Result of network change (persistent)
                                                Rectangle {
                                                    Layout.fillWidth: true
                                                    visible: service && (service.vmNetLastResult || service.vmNetLastError)
                                                    radius: 4
                                                    color: service && service.vmNetLastError ? Util.alpha(Color.urgent, 0.12) : Util.alpha(Color.accent, 0.08)
                                                    border.color: service && service.vmNetLastError ? Util.alpha(Color.urgent, 0.3) : Util.alpha(Color.accent, 0.2)
                                                    border.width: 1
                                                    implicitHeight: netResultCol.implicitHeight + 8
                                                    ColumnLayout {
                                                        id: netResultCol
                                                        anchors.fill: parent
                                                        anchors.margins: 6
                                                        spacing: 4
                                                        Label {
                                                            Layout.fillWidth: true
                                                            textFormat: Text.PlainText
                                                            text: service ? (service.vmNetLastError ? service.vmNetLastError : service.vmNetLastResult) : ""
                                                            font.family: "JetBrainsMono Nerd Font"
                                                            font.pixelSize: Style.font.caption - 1
                                                            color: service && service.vmNetLastError ? Color.urgent : Color.accent
                                                            wrapMode: Text.Wrap
                                                        }
                                                        RowLayout {
                                                            Layout.fillWidth: true
                                                            visible: service && service.vmNetLastResult
                                                            spacing: Style.space(4)
                                                            Button { text: "⎘ Copy"; fontSize: Style.font.caption -1; Layout.fillWidth: true; onClicked: root.copyToClipboard(service.vmNetLastResult) }
                                                            Button { text: "Dismiss"; fontSize: Style.font.caption -1; Layout.fillWidth: true; onClicked: { service.vmNetLastResult=""; service.vmNetLastError="" } }
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // clone + delete row
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(6)
                                            TextField { Layout.fillWidth: true; placeholderText: "clone new name"; text: root.cloneDst; font.pixelSize: Style.font.caption; onTextChanged: root.cloneDst=text }
                                            Button { text: "Clone"; fontSize: Style.font.caption; enabled: root.cloneDst.length>0; onClicked: { service.cloneVm(row.vmName, root.cloneDst); root.cloneDst="" } }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(4)
                                            Label {
                                                textFormat: Text.PlainText
                                                text: "󰋽"
                                                font.family: "JetBrainsMono Nerd Font"
                                                font.pixelSize: Style.font.caption
                                                color: Color.muted
                                            }
                                            Label {
                                                Layout.fillWidth: true
                                                textFormat: Text.PlainText
                                                text: "To delete the VM, use Undefine (keeps disk) or Undefine + storage (deletes disk). Destroy is force-off for running VMs."
                                                font.pixelSize: Style.font.caption - 1
                                                color: Color.muted
                                                opacity: 0.7
                                                wrapMode: Text.Wrap
                                            }
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(6)
                                            Button { text: "Undefine"; fontSize: Style.font.caption; Layout.fillWidth: true; onClicked: { root.confirmVm=row.vmName; root.confirmAction="undefine" } }
                                            Button { text: "Undefine + storage"; fontSize: Style.font.caption; Layout.fillWidth: true; onClicked: { root.confirmVm=row.vmName; root.confirmAction="undefine-storage" } }
                                        }

                                        // snapshots
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Style.space(4)
                                            TextField {
                                                Layout.fillWidth: true
                                                placeholderText: "new snapshot name"
                                                text: root.newSnapName
                                                font.pixelSize: Style.font.caption
                                                onTextChanged: root.newSnapName = text
                                            }
                                            Button {
                                                text: "Snap"
                                                fontSize: Style.font.caption
                                                Layout.preferredWidth: Style.space(50)
                                                enabled: root.newSnapName.length > 0
                                                onClicked: { if (service) service.snapCreate(row.vmName, root.newSnapName); root.newSnapName="" }
                                            }
                                        }
                                        // stats (P3) — compact + scrollable
                                        Rectangle {
                                            Layout.fillWidth: true
                                            visible: service && service.statsText
                                            radius: 4
                                            color: Util.alpha(Color.foreground,0.04)
                                            implicitHeight: Math.min(statsFlick.contentHeight + 12, Style.space(90))
                                            clip: true
                                            Flickable {
                                                id: statsFlick
                                                anchors.fill: parent
                                                anchors.margins: 6
                                                contentWidth: width
                                                contentHeight: statsLbl.implicitHeight
                                                clip: true
                                                boundsBehavior: Flickable.StopAtBounds
                                                Label {
                                                    id: statsLbl
                                                    width: parent.width
                                                    textFormat: Text.PlainText
                                                    text: service ? service.statsText : ""
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: Style.font.caption - 2
                                                    color: Color.muted
                                                    wrapMode: Text.Wrap
                                                }
                                            }
                                        }
                                        Label {
                                            Layout.fillWidth: true
                                            textFormat: Text.PlainText
                                            text: "OS: " + (modelData.osType || "--") + "  •  " + (modelData.persistent ? "persistent" : "transient") + "  •  " + (modelData.firmware || "bios")
                                            font.family: Style.font.family; font.pixelSize: Style.font.caption - 1; color: Color.muted; wrapMode: Text.Wrap
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.rgba(1,1,1,0.08) }

                    // ── Network ──
                    Rectangle {
                        Layout.fillWidth: true
                        radius: Style.space(6)
                        color: Util.alpha(Color.foreground, 0.04)
                        border.color: Util.alpha(Color.foreground, 0.08)
                        border.width: 1
                        implicitHeight: netCol.implicitHeight + Style.space(10)
                        ColumnLayout {
                            id: netCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(4)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { textFormat: Text.PlainText; text: service && service.defaultNetActive ? "󰈀" : "󰅛"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.body; color: service && service.defaultNetActive ? Color.accent : Color.urgent }
                                Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: "default NAT (virbr0)"; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; color: Color.foreground }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: (service && service.defaultNetActive ? "active" : "inactive") + " • autostart " + (service && service.defaultNetAutostart ? "yes" : "no"); font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.foreground; wrapMode: Text.Wrap }
                                Button {
                                    iconText: service && service.defaultNetActive ? "󰙧" : ""
                                    fontFamily: "JetBrainsMono Nerd Font"
                                    text: service && service.defaultNetActive ? "Stop" : "Start"
                                    foreground: service && service.defaultNetActive ? Color.urgent : Color.accent
                                    fontSize: Style.font.caption
                                    Layout.preferredWidth: Style.space(60)
                                    enabled: service && !service.busy
                                    onClicked: if (service) service.defaultNetActive ? service.netStop() : service.netStart()
                                }
                                Button {
                                    iconText: service && service.defaultNetAutostart ? "" : ""
                                    fontFamily: "JetBrainsMono Nerd Font"
                                    fontSize: Style.font.caption
                                    foreground: service && service.defaultNetAutostart ? Color.accent : Color.muted
                                tooltipText: service && service.defaultNetAutostart ? "Autostart ON — click to disable" : "Autostart OFF — click to enable"
                                Layout.preferredWidth: Style.space(26)
                                enabled: service && !service.busy
                                onClicked: if (service) service.netAutostart(!service.defaultNetAutostart)
                            }
                        }
                    }
                    }

                    // ── Image Storage (pool path) ── collapsable (xmodulo)
                    Rectangle {
                        Layout.fillWidth: true
                        radius: Style.space(6)
                        color: Util.alpha(Color.foreground,0.03)
                        border.color: Util.alpha(Color.foreground,0.06)
                        border.width: 1
                        implicitHeight: storageCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: storageCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(4)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label {
                                    textFormat: Text.PlainText
                                    text: root.settingsCollapsed ? "" : ""
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: Style.font.caption
                                    color: Color.accent
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsCollapsed = !root.settingsCollapsed }
                                }
                                Label {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: "⚙ Image Storage"
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    color: Color.foreground
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.settingsCollapsed = !root.settingsCollapsed }
                                }
                                Label {
                                    textFormat: Text.PlainText
                                    text: service ? service.defaultPoolPath : "/var/lib/libvirt/images"
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: Style.font.caption - 1
                                    color: Color.muted
                                    elide: Text.ElideLeft
                                    Layout.maximumWidth: Style.space(140)
                                }
                                Button { iconText: ""; fontFamily: "JetBrainsMono Nerd Font"; fontSize: Style.font.caption; Layout.preferredWidth: Style.space(22); onClicked: if (service) service.refreshPoolPath() }
                            }
                            ColumnLayout {
                                visible: !root.settingsCollapsed
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: "Current: " + (service ? service.defaultPoolPath : "--")
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: Style.font.caption - 1
                                    color: Color.muted
                                    wrapMode: Text.Wrap
                                    elide: Text.ElideMiddle
                                }
                                Label {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: "Change where new VM images are stored. For /home paths, parent dirs need o+x — the helper sets 755/711 automatically (xmodulo method: pool-dumpxml → edit <path> → pool-destroy → pool-define → pool-start)."
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption - 1
                                    color: Color.muted
                                    wrapMode: Text.Wrap
                                    opacity: 0.8
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.space(6)
                                    Label { textFormat: Text.PlainText; text: "Path"; font.pixelSize: Style.font.caption; color: Color.muted }
                                    TextField { Layout.fillWidth: true; text: root.newPoolPath; placeholderText: "/home/user/VMs  or  /mnt/data/libvirt"; font.pixelSize: Style.font.caption; onTextChanged: root.newPoolPath = text }
                                    Button {
                                        iconText: "󰉋"
                                        fontFamily: "JetBrainsMono Nerd Font"
                                        fontSize: Style.font.caption
                                        tooltipText: "Browse directory…"
                                        Layout.preferredWidth: Style.space(28)
                                        onClicked: poolDirPicker.running = true
                                    }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.space(6)
                                    Label { textFormat: Text.PlainText; text: "Pool"; font.pixelSize: Style.font.caption; color: Color.muted }
                                    TextField { Layout.fillWidth: true; text: root.newPoolName; placeholderText: "default (move) or my-pool (new)"; font.pixelSize: Style.font.caption; onTextChanged: root.newPoolName = text }
                                    Label { textFormat: Text.PlainText; text: "→"; font.pixelSize: Style.font.caption; color: Color.muted }
                                    Label { textFormat: Text.PlainText; text: root.newPoolName ? root.newPoolName : "default"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.caption; color: Color.accent }
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Style.space(6)
                                    Button {
                                        text: "Move default pool"
                                        fontSize: Style.font.caption
                                        Layout.fillWidth: true
                                        enabled: root.newPoolPath.length > 0 && service && !service.busy
                                        onClicked: service.setDefaultPoolPath(root.newPoolPath, "redefine")
                                    }
                                    Button {
                                        text: "Create new pool"
                                        fontSize: Style.font.caption
                                        Layout.fillWidth: true
                                        enabled: root.newPoolPath.length > 0 && root.newPoolName.length > 0 && service && !service.busy
                                        onClicked: service.createPoolAt(root.newPoolName, root.newPoolPath)
                                    }
                                }
                                // Result of last pool operation (persistent, with copy/dismiss)
                                Rectangle {
                                    Layout.fillWidth: true
                                    visible: service && (service.poolLastResult || service.poolLastError)
                                    radius: 4
                                    color: service && service.poolLastError ? Util.alpha(Color.urgent, 0.12) : Util.alpha(Color.accent, 0.08)
                                    border.color: service && service.poolLastError ? Util.alpha(Color.urgent, 0.3) : Util.alpha(Color.accent, 0.2)
                                    border.width: 1
                                    implicitHeight: poolResultCol.implicitHeight + 8
                                    ColumnLayout {
                                        id: poolResultCol
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        spacing: 4
                                        Label {
                                            Layout.fillWidth: true
                                            textFormat: Text.PlainText
                                            text: service ? (service.poolLastError ? service.poolLastError : service.poolLastResult) : ""
                                            font.family: "JetBrainsMono Nerd Font"
                                            font.pixelSize: Style.font.caption - 1
                                            color: service && service.poolLastError ? Color.urgent : Color.accent
                                            wrapMode: Text.Wrap
                                        }
                                        RowLayout {
                                            Layout.fillWidth: true
                                            visible: service && service.poolLastResult
                                            spacing: Style.space(4)
                                            Button { text: "⎘ Copy"; fontSize: Style.font.caption -1; Layout.fillWidth: true; onClicked: root.copyToClipboard(service.poolLastResult) }
                                            Button { text: "Dismiss"; fontSize: Style.font.caption -1; Layout.fillWidth: true; onClicked: { service.poolLastResult=""; service.poolLastError="" } }
                                        }
                                    }
                                }
                                Label {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: "Note: existing VM images stay at old location (/var/lib/libvirt/images). Move them manually with `sudo mv /var/lib/libvirt/images/*.qcow2 <new-path>/` + `virsh pool-refresh default` if needed."
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption - 1
                                    color: Color.muted
                                    wrapMode: Text.Wrap
                                    opacity: 0.7
                                }
                                Label {
                                    visible: service && service.poolDetailText
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: service ? service.poolDetailText : ""
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: Style.font.caption - 2
                                    color: Color.muted
                                    wrapMode: Text.Wrap
                                    opacity: 0.6
                                }
                            }
                        }
                    }

                    // ── Pools & Networks (P2) ── collapsable
                    Rectangle {
                        Layout.fillWidth: true
                        radius: Style.space(6)
                        color: Util.alpha(Color.foreground,0.03)
                        border.color: Util.alpha(Color.foreground,0.06)
                        border.width: 1
                        implicitHeight: poolsCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: poolsCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(4)
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Style.space(6)
                                Label {
                                    textFormat: Text.PlainText
                                    text: root.poolsCollapsed ? "" : ""
                                    font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: Style.font.caption
                                    color: Color.accent
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.poolsCollapsed = !root.poolsCollapsed }
                                }
                                Label {
                                    Layout.fillWidth: true
                                    textFormat: Text.PlainText
                                    text: "Pools & Networks"
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    color: Color.foreground
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.poolsCollapsed = !root.poolsCollapsed }
                                }
                                Button { iconText: ""; fontFamily: "JetBrainsMono Nerd Font"; fontSize: Style.font.caption; Layout.preferredWidth: Style.space(22); onClicked: if (service) { service.refreshPools(); service.refresh() } }
                            }
                            ColumnLayout {
                                visible: !root.poolsCollapsed
                                Layout.fillWidth: true
                                spacing: Style.space(4)
                                Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: service ? service.poolInfo : ""; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.caption-1; color: Color.muted; wrapMode: Text.Wrap }
                                Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: service ? service.netInfo : ""; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.caption-1; color: Color.muted; wrapMode: Text.Wrap }
                                RowLayout {
                                    Layout.fillWidth: true
                                    TextField { id: poolNameField; Layout.fillWidth: true; placeholderText: "pool name"; font.pixelSize: Style.font.caption }
                                    TextField { id: poolPathField; Layout.fillWidth: true; placeholderText: "/path"; font.pixelSize: Style.font.caption }
                                    Button { text: "Create pool"; fontSize: Style.font.caption; onClicked: if (service) service.poolCreate(poolNameField.text, poolPathField.text) }
                                }
                            }
                        }
                    }

                    // ── Confirm dialog ──
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.confirmVm !== ""
                        radius: Style.space(6)
                        color: Util.alpha(Color.urgent,0.12)
                        border.color: Util.alpha(Color.urgent,0.35)
                        border.width: 1
                        implicitHeight: confirmCol.implicitHeight + Style.space(12)
                        ColumnLayout {
                            id: confirmCol
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(6)
                            Label { Layout.fillWidth: true; textFormat: Text.PlainText; text: root.confirmAction==="destroy" ? "Force off " + root.confirmVm + " ? Données non enregistrées perdues." : root.confirmAction.indexOf("undefine")!==-1 ? "Supprimer " + root.confirmVm + (root.confirmAction==="undefine-storage" ? " + disques ?" : " ?") : ""; font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.urgent; wrapMode: Text.Wrap }
                            RowLayout {
                                Layout.fillWidth: true
                                Button { text: "Cancel"; fontSize: Style.font.caption; Layout.fillWidth: true; onClicked: root.confirmVm="" }
                                Button { text: "Confirm"; fontSize: Style.font.caption; Layout.fillWidth: true;
                                    onClicked: {
                                        if (root.confirmAction==="destroy") service.destroyVm(root.confirmVm)
                                        else if (root.confirmAction==="undefine") service.undefineVm(root.confirmVm, false)
                                        else if (root.confirmAction==="undefine-storage") service.undefineVm(root.confirmVm, true)
                                        root.confirmVm=""; root.confirmAction=""
                                    }
                                }
                            }
                        }
                    }



                    Label {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: "Tip: Hardware changes need VM shutdown for cold apply, or use Live toggle for hot apply. Cloning via virt-clone."
                        font.family: Style.font.family; font.pixelSize: Style.font.caption - 1; color: Color.muted; opacity: 0.7; wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
}
