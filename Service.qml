pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string omarchyPath: ""
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null

    // ── State ──
    property var vms: []
    property var filteredVms: []
    property string searchText: ""
    property string filterState: "all" // all | running | off | paused
    property int totalCount: 0
    property int runningCount: 0
    property int offCount: 0
    property int pausedCount: 0
    property bool busy: false
    property string lastError: ""
    property string lastInfo: ""
    property bool libvirtdActive: false
    property bool defaultNetActive: false
    property bool defaultNetAutostart: false
    property double lastRefresh: 0

    // Pools / networks / stats
    property var pools: []
    property var networks: []
    property string poolInfo: ""
    property string netInfo: ""
    property string statsText: ""
    property var osVariants: []
    property string defaultPoolPath: "/var/lib/libvirt/images"
    property string poolDetailText: ""
    property string poolLastResult: ""
    property string poolLastError: ""

    // Wizard / tool checks
    property bool wizardRunning: false
    property string wizardLog: ""
    property string lastCreatedVm: ""
    property var toolStatus: ({}) // {virtInstall: bool, virtViewer: bool, osinfo: bool}

    readonly property int maxVms: 500
    readonly property int maxOutputBytes: 262144

    function scriptPath(name) {
        return Qt.resolvedUrl("bin/" + name).toString().replace(/^file:\/\//, "")
    }

    Component.onCompleted: {
        refresh()
        pollTimer.start()
        checkTools()
        refreshPools()
        refreshPoolPath()
        loadOsVariants()
    }

    // ── Filtering ──
    function applyFilter() {
        var q = (root.searchText || "").toLowerCase().trim()
        var fs = root.filterState
        var out = []
        for (var i = 0; i < root.vms.length; i++) {
            var v = root.vms[i]
            var state = (v.state || "").toLowerCase()
            if (fs === "running" && state !== "running") continue
            if (fs === "off" && !(state.indexOf("shut off") !== -1 || state === "shut off" || state === "shutoff")) continue
            if (fs === "paused" && state !== "paused") continue
            if (q) {
                var hay = ((v.name || "") + " " + (v.title || "") + " " + (v.state || "")).toLowerCase()
                if (hay.indexOf(q) === -1) continue
            }
            out.push(v)
        }
        root.filteredVms = out
    }
    onSearchTextChanged: applyFilter()
    onFilterStateChanged: applyFilter()
    onVmsChanged: applyFilter()

    function recalcStats() {
        var total = root.vms.length
        var run = 0, off = 0, paused = 0
        for (var i = 0; i < root.vms.length; i++) {
            var s = (root.vms[i].state || "").toLowerCase()
            if (s === "running") run++
            else if (s === "paused") paused++
            else if (s.indexOf("shut") !== -1) off++
            else off++
        }
        root.totalCount = total
        root.runningCount = run
        root.pausedCount = paused
        root.offCount = off
    }

    // ── Polling ──
    Timer {
        id: pollTimer
        interval: 3000
        repeat: true
        onTriggered: root.refresh()
    }

    function refresh() {
        if (listProc.running) return
        listProc.running = true
        netProc.running = true
    }

    Process {
        id: listProc
        command: ["python3", root.scriptPath("omarchy-kvm-list")]
        stdout: StdioCollector { id: listOut; waitForEnd: true }
        stderr: StdioCollector { id: listErr; waitForEnd: true }
        property bool timedOut: false
        onRunningChanged: {
            if (running) { timedOut = false; listDeadline.restart() } else listDeadline.stop()
        }
        onExited: function(code) {
            listDeadline.stop()
            if (timedOut) { root.lastError = "list timeout (8s)"; return }
            if (listOut.text.length > root.maxOutputBytes) { root.lastError = "list output too large"; return }
            if (code !== 0 && listOut.text.trim() === "") {
                var err = listErr.text.trim() || listOut.text.trim()
                if (err) root.lastError = err.substring(0, 400)
                root.libvirtdActive = err.indexOf("Failed to connect") === -1
                return
            }
            try {
                var txt = listOut.text.trim()
                if (!txt) { root.vms = []; root.libvirtdActive = true; root.recalcStats(); return }
                var parsed = JSON.parse(txt)
                if (parsed && parsed.error) {
                    root.lastError = String(parsed.error).substring(0, 400)
                    root.libvirtdActive = String(parsed.error).indexOf("Failed to connect") === -1
                    return
                }
                if (!Array.isArray(parsed)) parsed = []
                if (parsed.length > root.maxVms) parsed = parsed.slice(0, root.maxVms)
                root.vms = parsed
                root.recalcStats()
                root.libvirtdActive = true
                root.lastError = ""
                root.lastRefresh = Date.now()
            } catch (e) {
                root.lastError = "list parse failed: " + e
            }
        }
    }
    Timer { id: listDeadline; interval: 8000; onTriggered: { listProc.timedOut = true; listProc.running = false } }

    Process {
        id: netProc
        command: ["python3", root.scriptPath("omarchy-kvm-network"), "list"]
        stdout: StdioCollector { id: netOut; waitForEnd: true }
        stderr: StdioCollector { id: netErr; waitForEnd: true }
        onExited: function(code) {
            var txt = netOut.text
            root.netInfo = txt.substring(0, 2000)
            var lines = txt.split("\n")
            var nets = []
            var start = false
            var defActive = false
            var defAutostart = false
            for (var i = 0; i < lines.length; i++) {
                var l = lines[i].trim()
                if (!start) { if (l.indexOf("---") === 0) start = true; continue }
                if (!l) continue
                var parts = l.split(/\s+/)
                if (parts.length >= 2) {
                    var entry = {name: parts[0], state: parts[1], autostart: parts[2] || "", persistent: parts[3] || ""}
                    nets.push(entry)
                    if (entry.name === "default") {
                        defActive = (entry.state === "active")
                        defAutostart = (entry.autostart === "yes")
                    }
                }
            }
            root.networks = nets
            root.defaultNetActive = defActive
            root.defaultNetAutostart = defAutostart
        }
    }

    // ── Generic action (lifecycle) ──
    Process {
        id: actionProc
        stdout: StdioCollector { id: actionOut; waitForEnd: true }
        stderr: StdioCollector { id: actionErr; waitForEnd: true }
        property bool timedOut: false
        onRunningChanged: {
            if (running) { timedOut = false; actionDeadline.restart(); root.busy = true } else { actionDeadline.stop(); root.busy = false }
        }
        onExited: function(code) {
            actionDeadline.stop()
            root.busy = false
            if (timedOut) { root.lastError = "action timeout (15s)"; return }
            if (code === 0) {
                root.lastError = ""
                root.lastInfo = actionOut.text.trim().substring(0,300)
                refreshDelay.restart()
            } else {
                var msg = actionErr.text.trim() || actionOut.text.trim()
                root.lastError = msg ? msg.substring(0, 500) : "action failed"
            }
        }
    }
    Timer { id: actionDeadline; interval: 15000; onTriggered: { actionProc.timedOut = true; actionProc.running = false } }
    Timer { id: refreshDelay; interval: 800; onTriggered: root.refresh() }

    function actionVm(act, vmName) {
        if (!vmName || vmName.length > 100) { root.lastError = "invalid vm name"; return }
        var re = /^[a-zA-Z0-9._-]+$/
        if (!re.test(vmName)) { root.lastError = "invalid vm name chars"; return }
        root.lastError = ""
        actionProc.command = ["python3", root.scriptPath("omarchy-kvm-action"), act, vmName]
        actionProc.running = true
    }
    function startVm(n) { actionVm("start", n) }
    function shutdownVm(n) { actionVm("shutdown", n) }
    function destroyVm(n) { actionVm("destroy", n) }
    function rebootVm(n) { actionVm("reboot", n) }
    function suspendVm(n) { actionVm("suspend", n) }
    function resumeVm(n) { actionVm("resume", n) }
    function autostartOn(n) { actionVm("autostart-on", n) }
    function autostartOff(n) { actionVm("autostart-off", n) }

    // ── Console ──
    Process {
        id: consoleProc
        stdout: StdioCollector { waitForEnd: true }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code) {
            if (code !== 0) root.lastError = "console launch failed — install virt-viewer"
        }
    }
    function openConsole(vmName) {
        if (!vmName) return
        consoleProc.command = ["python3", root.scriptPath("omarchy-kvm-console"), vmName]
        consoleProc.running = true
    }

    // ── Snapshots ──
    Process {
        id: snapProc
        stdout: StdioCollector { id: snapOut; waitForEnd: true }
        stderr: StdioCollector { id: snapErr; waitForEnd: true }
        onExited: function(code) {
            if (code === 0) { root.lastError = ""; root.lastInfo = snapOut.text.trim().substring(0,300); refreshDelay.restart() }
            else root.lastError = (snapErr.text.trim() || snapOut.text.trim()).substring(0,500)
        }
    }
    function snapList(vm) { snapProc.command = ["python3", root.scriptPath("omarchy-kvm-snapshot"), "list", vm]; snapProc.running = true }
    function snapCreate(vm, snapName) { snapProc.command = ["python3", root.scriptPath("omarchy-kvm-snapshot"), "create", vm, snapName]; snapProc.running = true }
    function snapRevert(vm, snapName) { snapProc.command = ["python3", root.scriptPath("omarchy-kvm-snapshot"), "revert", vm, snapName]; snapProc.running = true }
    function snapDelete(vm, snapName) { snapProc.command = ["python3", root.scriptPath("omarchy-kvm-snapshot"), "delete", vm, snapName]; snapProc.running = true }

    // ── Network ──
    Process {
        id: netActionProc
        stdout: StdioCollector { id: netActionOut; waitForEnd: true }
        stderr: StdioCollector { id: netActionErr; waitForEnd: true }
        onExited: function(code) {
            if (code === 0) { root.lastError = ""; root.lastInfo = netActionOut.text.trim().substring(0,300) || "Network action ok"; netProc.running = true }
            else root.lastError = (netActionErr.text.trim() || netActionOut.text.trim()).substring(0,400)
        }
    }
    function netStart() { netActionProc.command = ["python3", root.scriptPath("omarchy-kvm-network"), "start", "default"]; netActionProc.running = true }
    function netStop() { netActionProc.command = ["python3", root.scriptPath("omarchy-kvm-network"), "stop", "default"]; netActionProc.running = true }
    function netAutostart(enable) { netActionProc.command = ["python3", root.scriptPath("omarchy-kvm-network"), "autostart", "default", enable ? "yes" : "no"]; netActionProc.running = true }
    function netCreate(name, bridgeOrXml) {
        // simple via virsh net-define? For now use pool helper as placeholder
        netActionProc.command = ["python3", root.scriptPath("omarchy-kvm-network"), "list"]
        netActionProc.running = true
    }

    // ── Undefine (with storage) ──
    Process {
        id: undefineProc
        stdout: StdioCollector { id: undefineOut; waitForEnd: true }
        stderr: StdioCollector { id: undefineErr; waitForEnd: true }
        property bool timedOut: false
        onRunningChanged: { if (running) { timedOut=false; undefineDeadline.restart(); root.busy=true } else { undefineDeadline.stop(); root.busy=false } }
        onExited: function(code) {
            undefineDeadline.stop(); root.busy=false
            if (timedOut) { root.lastError="undefine timeout"; return }
            if (code===0) { root.lastError=""; root.lastInfo=undefineOut.text.trim().substring(0,300); refreshDelay.restart() }
            else root.lastError=(undefineErr.text.trim()||undefineOut.text.trim()).substring(0,500)
        }
    }
    Timer { id: undefineDeadline; interval: 20000; onTriggered: { undefineProc.timedOut=true; undefineProc.running=false } }
    function undefineVm(name, removeStorage) {
        if (!name) return
        var cmd = ["python3", root.scriptPath("omarchy-kvm-undefine"), name]
        if (removeStorage) cmd.push("--remove-storage")
        undefineProc.command = cmd
        undefineProc.running = true
    }

    // ── Hardware (vcpus/memory) ──
    Process {
        id: hwProc
        stdout: StdioCollector { id: hwOut; waitForEnd: true }
        stderr: StdioCollector { id: hwErr; waitForEnd: true }
        onExited: function(code) {
            if (code===0) { root.lastError=""; root.lastInfo=hwOut.text.trim().substring(0,300); refreshDelay.restart() }
            else root.lastError=(hwErr.text.trim()||hwOut.text.trim()).substring(0,500)
        }
    }
    function setVcpus(vm, cnt, live) {
        var cmd=["python3", root.scriptPath("omarchy-kvm-hardware"), "set-vcpus", vm, String(cnt)]
        if (live) cmd.push("--live")
        hwProc.command=cmd; hwProc.running=true
    }
    function setMemory(vm, mb, live) {
        var cmd=["python3", root.scriptPath("omarchy-kvm-hardware"), "set-memory", vm, String(mb)]
        if (live) cmd.push("--live")
        hwProc.command=cmd; hwProc.running=true
    }

    // ── Clone ──
    Process {
        id: cloneProc
        stdout: StdioCollector { id: cloneOut; waitForEnd: true }
        stderr: StdioCollector { id: cloneErr; waitForEnd: true }
        property bool timedOut: false
        onRunningChanged: { if (running) { timedOut=false; cloneDeadline.restart(); root.busy=true } else { cloneDeadline.stop(); root.busy=false } }
        onExited: function(code) {
            cloneDeadline.stop(); root.busy=false
            if (timedOut) { root.lastError="clone timeout"; return }
            if (code===0) { root.lastError=""; root.lastInfo=cloneOut.text.trim().substring(0,300); refreshDelay.restart() }
            else root.lastError=(cloneErr.text.trim()||cloneOut.text.trim()).substring(0,500)
        }
    }
    Timer { id: cloneDeadline; interval: 60000; onTriggered: { cloneProc.timedOut=true; cloneProc.running=false } }
    function cloneVm(src, dst) {
        cloneProc.command=["python3", root.scriptPath("omarchy-kvm-clone"), src, dst]
        cloneProc.running=true
    }

    // ── Pools ──
    Process {
        id: poolProc
        stdout: StdioCollector { id: poolOut; waitForEnd: true }
        stderr: StdioCollector { id: poolErr; waitForEnd: true }
        onExited: function(code) {
            if (code===0) { root.poolInfo=poolOut.text.substring(0,2000); root.lastError="" }
            else root.lastError=(poolErr.text.trim()||poolOut.text.trim()).substring(0,400)
            // parse pools
            var txt=poolOut.text
            var lines=txt.split("\n")
            var pools=[]
            var start=false
            for (var i=0;i<lines.length;i++) {
                var l=lines[i].trim()
                if (!start) { if (l.indexOf("---")===0) start=true; continue }
                if (!l) continue
                var parts=l.split(/\s+/)
                if (parts.length>=2) pools.push({name: parts[0], state: parts[1], autostart: parts[2]||""})
            }
            root.pools=pools
        }
    }
    function refreshPools() { poolProc.command=["python3", root.scriptPath("omarchy-kvm-pool"), "list"]; poolProc.running=true }
    function poolCreate(name, path) { poolProc.command=["python3", root.scriptPath("omarchy-kvm-pool"), "create", name, path]; poolProc.running=true }
    function poolStart(name) { poolProc.command=["python3", root.scriptPath("omarchy-kvm-pool"), "start", name]; poolProc.running=true }
    function volList(pool) { poolProc.command=["python3", root.scriptPath("omarchy-kvm-pool"), "vol-list", pool]; poolProc.running=true }

    // ── Pool path (default images location) ──
    Process {
        id: poolPathProc
        stdout: StdioCollector { id: poolPathOut; waitForEnd: true }
        stderr: StdioCollector { id: poolPathErr; waitForEnd: true }
        onExited: function(code) {
            if (code === 0) {
                var txt = poolPathOut.text
                var m = txt.match(/<path>(.*?)<\/path>/)
                if (m && m[1]) root.defaultPoolPath = m[1].trim()
                root.poolDetailText = txt.substring(0, 3000)
            } else {
                root.poolDetailText = poolPathErr.text.trim().substring(0, 1000)
            }
        }
    }
    function refreshPoolPath() { poolPathProc.command = ["virsh", "--connect", "qemu:///system", "pool-dumpxml", "default"]; poolPathProc.running = true }

    Process {
        id: poolSetProc
        stdout: StdioCollector { id: poolSetOut; waitForEnd: true }
        stderr: StdioCollector { id: poolSetErr; waitForEnd: true }
        property bool timedOut: false
        onRunningChanged: { if (running) { timedOut=false; poolSetDeadline.restart(); root.busy=true } else { poolSetDeadline.stop(); root.busy=false } }
        onExited: function(code) {
            poolSetDeadline.stop(); root.busy=false
            if (timedOut) { root.lastError="pool set timeout (30s)"; root.poolLastError="timeout"; return }
            var out = poolSetOut.text.trim()
            var err = poolSetErr.text.trim()
            if (code === 0) {
                root.lastError=""; root.lastInfo=out.substring(0,500) || "Pool location updated"
                root.poolLastResult=out.substring(0,800) || "Pool updated"
                root.poolLastError=""
                root.wizardLog+=out+"\n"; refreshPools(); refreshPoolPath()
            } else {
                root.lastError=(err||out).substring(0,600)
                root.poolLastError=(err||out).substring(0,600)
                root.poolLastResult=""
            }
        }
    }
    Timer { id: poolSetDeadline; interval: 30000; onTriggered: { poolSetProc.timedOut=true; poolSetProc.running=false } }
    function setDefaultPoolPath(newPath, mode) {
        if (!newPath || newPath.length > 512) { root.lastError="invalid path"; return }
        var m = mode || "redefine"
        poolSetProc.command=["python3", root.scriptPath("omarchy-kvm-pool-set-default"), newPath, "--pool", "default", "--mode", m]
        poolSetProc.running=true
    }
    function createPoolAt(name, path) {
        if (!name || !path) { root.lastError="name and path required"; return }
        if (name.length > 64 || path.length > 512) { root.lastError="name/path too long"; return }
        var re=/^[a-zA-Z0-9._-]+$/
        if (!re.test(name)) { root.lastError="invalid pool name"; return }
        poolSetProc.command=["python3", root.scriptPath("omarchy-kvm-pool-set-default"), path, "--pool", name, "--mode", "create"]
        poolSetProc.running=true
    }

    // ── Create VM (virt-install) ──
    Process {
        id: createProc
        stdout: StdioCollector { id: createOut; waitForEnd: true }
        stderr: StdioCollector { id: createErr; waitForEnd: true }
        property bool timedOut: false
        onRunningChanged: {
            if (running) { timedOut=false; createDeadline.restart(); root.wizardRunning=true; root.busy=true }
            else { createDeadline.stop(); root.wizardRunning=false; root.busy=false }
        }
        onExited: function(code) {
            createDeadline.stop(); root.wizardRunning=false; root.busy=false
            if (timedOut) { root.lastError="create timeout (120s)"; return }
            var out=createOut.text.trim()
            var err=createErr.text.trim()
            if (code===0) {
                root.lastError=""; root.lastInfo="VM created — opening console…"; root.wizardLog+=out+"\n✔ done\n";
                refreshDelay.restart()
                if (root.lastCreatedVm) consoleDelay.restart()
            } else { root.lastError=(err||out).substring(0,600); root.wizardLog+=out+"\n✘ failed\n"+err }
        }
    }
    Timer { id: createDeadline; interval: 120000; onTriggered: { createProc.timedOut=true; createProc.running=false } }
    Timer { id: consoleDelay; interval: 1500; onTriggered: { if (root.lastCreatedVm) root.openConsole(root.lastCreatedVm) } }
    function createVm(jsonParams) {
        root.lastCreatedVm = jsonParams.name || ""
        // write temp file via python helper
        var jsonStr = JSON.stringify(jsonParams)
        if (jsonStr.length > 8192) { root.lastError="create params too large"; return }
        // use bash -lc to write temp and call helper
        var sPath=root.scriptPath("omarchy-kvm-create")
        createProc.command=["bash","-lc", "tmp=$(mktemp /tmp/kvm-create.XXXXXX.json); printf '%s' \"$JSON\" > \"$tmp\"; python3 \""+sPath+"\" \"$tmp\"; rc=$?; cat \"$tmp\"; rm -f \"$tmp\"; exit $rc"]
        createProc.environment={"JSON": jsonStr}
        createProc.running=true
        root.wizardLog=""
    }

    // ── Stats ──
    Process {
        id: statsProc
        stdout: StdioCollector { id: statsOut; waitForEnd: true }
        onExited: function(code) { if (code===0) root.statsText=statsOut.text.substring(0,3000) }
    }
    function fetchStats(vm) {
        if (vm) statsProc.command=["python3", root.scriptPath("omarchy-kvm-stats"), vm]
        else statsProc.command=["python3", root.scriptPath("omarchy-kvm-stats")]
        statsProc.running=true
    }

    // ── Tool checks ──
    Process {
        id: toolCheckProc
        stdout: StdioCollector { id: toolOut; waitForEnd: true }
        onExited: function(code) {
            try { root.toolStatus=JSON.parse(toolOut.text.trim()) } catch(e) { root.toolStatus={} }
        }
    }
    function checkTools() {
        var sPath=root.scriptPath("omarchy-kvm-list")
        toolCheckProc.command=["bash","-lc", "printf '{\"virtInstall\":%s,\"virtViewer\":%s,\"osinfo\":%s}' \"$(command -v virt-install >/dev/null && echo true || echo false)\" \"$(command -v virt-viewer >/dev/null && echo true || echo false)\" \"$(command -v osinfo-query >/dev/null && echo true || echo false)\""]
        toolCheckProc.running=true
    }
    Process {
        id: osProc
        stdout: StdioCollector { id: osOut; waitForEnd: true }
        onExited: function(code) {
            var txt=osOut.text.trim()
            var lines=txt.split("\n")
            var vars=[]
            for (var i=0;i<lines.length;i++) {
                var l=lines[i].trim()
                if (l && l!=="short-id" && !l.startsWith("-")) vars.push(l)
            }
            root.osVariants=vars
        }
    }
    function loadOsVariants() {
        osProc.command=["bash","-lc","osinfo-query os --fields=short-id 2>/dev/null | head -n 100"]
        osProc.running=true
    }

    // ── Helpers for BarWidget ──
    function launchVirtManager() {
        virtMgrProc.running = true
    }
    Process {
        id: virtMgrProc
        command: ["bash", "-lc", "virt-manager & disown"]
        stdout: StdioCollector { waitForEnd: true }
    }
}
