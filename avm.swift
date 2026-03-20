import Cocoa
import Virtualization

// MARK: - Helpers

func log(_ msg: String) { fputs("\(msg)\n", stderr) }

func die(_ msg: String) -> Never { log("Error: \(msg)"); exit(1) }

let GB: UInt64 = 1_073_741_824

/// Block on an async callback-based API, keeping the run loop alive.
func waitFor<T>(_ work: (@escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    work { r in result = r; sem.signal() }
    while sem.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
    }
    return try result.get()
}

// MARK: - VM Bundle (directory layout)

struct VMBundle {
    let url: URL

    var disk: URL            { url.appending(path: "Disk.img") }
    var auxStorage: URL      { url.appending(path: "AuxiliaryStorage") }
    var hardwareModel: URL   { url.appending(path: "HardwareModel") }
    var machineId: URL       { url.appending(path: "MachineIdentifier") }
    var configJSON: URL      { url.appending(path: "config.json") }
    var legacyPlist: URL     { url.appending(path: ".vbdata/Config.plist") }
    var name: String         { url.deletingPathExtension().lastPathComponent }

    func loadHardwareModel() throws -> VZMacHardwareModel {
        let data = try Data(contentsOf: hardwareModel)
        guard let m = VZMacHardwareModel(dataRepresentation: data), m.isSupported else {
            die("unsupported or invalid HardwareModel")
        }
        return m
    }

    func loadMachineId() throws -> VZMacMachineIdentifier {
        let data = try Data(contentsOf: machineId)
        guard let m = VZMacMachineIdentifier(dataRepresentation: data) else {
            die("invalid MachineIdentifier")
        }
        return m
    }

    func loadAuxStorage() -> VZMacAuxiliaryStorage {
        VZMacAuxiliaryStorage(contentsOf: auxStorage)
    }
}

// MARK: - VM Config (JSON-serializable settings)

struct VMConfig {
    var cpus       = 4
    var memoryGB   = 4
    var diskGB     = 64
    var width      = 1920
    var height     = 1200
    var ppi        = 144
    var mac        = ""
    var noAudio    = false
    var noAccel    = false

    var memorySize: UInt64 { UInt64(memoryGB) * GB }

    // Load: config.json -> legacy plist -> defaults
    static func load(from bundle: VMBundle) -> VMConfig {
        if let c = try? loadJSON(bundle.configJSON) { return c }
        if let c = try? loadPlist(bundle.legacyPlist) { return c }
        return VMConfig()
    }

    private static func loadJSON(_ url: URL) throws -> VMConfig {
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        var c = VMConfig()
        if let v = j["cpuCount"]      as? Int    { c.cpus     = v }
        if let v = j["memoryGB"]      as? Int    { c.memoryGB = v }
        if let v = j["diskSizeGB"]    as? Int    { c.diskGB   = v }
        if let v = j["displayWidth"]  as? Int    { c.width    = v }
        if let v = j["displayHeight"] as? Int    { c.height   = v }
        if let v = j["pixelsPerInch"] as? Int    { c.ppi      = v }
        if let v = j["macAddress"]    as? String { c.mac      = v }
        if let v = j["noAudio"]       as? Bool   { c.noAudio  = v }
        if let v = j["noAccel"]       as? Bool   { c.noAccel  = v }
        return c
    }

    private static func loadPlist(_ url: URL) throws -> VMConfig {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        guard let hw = (plist as? [String: Any])?["hardware"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var c = VMConfig()
        c.cpus = hw["cpuCount"] as? Int ?? c.cpus
        if let b = hw["memorySize"]    as? UInt64          { c.memoryGB = Int(b / GB) }
        if let d = (hw["displayDevices"]  as? [[String: Any]])?.first {
            c.width  = d["width"]         as? Int ?? c.width
            c.height = d["height"]        as? Int ?? c.height
            c.ppi    = d["pixelsPerInch"] as? Int ?? c.ppi
        }
        if let n = (hw["networkDevices"]  as? [[String: Any]])?.first { c.mac = n["macAddress"] as? String ?? "" }
        if let s =  hw["soundDevices"]    as? [[String: Any]]         { c.noAudio = s.isEmpty }
        return c
    }

    func save(to url: URL) throws {
        var d: [String: Any] = [
            "cpuCount": cpus, "memoryGB": memoryGB, "diskSizeGB": diskGB,
            "displayWidth": width, "displayHeight": height, "pixelsPerInch": ppi,
        ]
        if !mac.isEmpty { d["macAddress"] = mac }
        if noAudio { d["noAudio"] = true }
        if noAccel { d["noAccel"] = true }
        try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

// MARK: - Build VZVirtualMachineConfiguration

func buildVMConfig(bundle: VMBundle, config: VMConfig) throws -> VZVirtualMachineConfiguration {
    let vz = VZVirtualMachineConfiguration()

    // Platform
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel    = try bundle.loadHardwareModel()
    platform.machineIdentifier = try bundle.loadMachineId()
    platform.auxiliaryStorage  = bundle.loadAuxStorage()
    vz.platform   = platform
    vz.bootLoader = VZMacOSBootLoader()
    vz.cpuCount   = config.cpus
    vz.memorySize = config.memorySize

    // Display (always attached -- macOS needs a framebuffer even in headless mode)
    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(
        widthInPixels: config.width, heightInPixels: config.height, pixelsPerInch: config.ppi
    )]
    vz.graphicsDevices = [gfx]

    // Disk
    vz.storageDevices = [VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: bundle.disk, readOnly: false)
    )]

    // Network (NAT)
    let net = VZVirtioNetworkDeviceConfiguration()
    net.macAddress = VZMACAddress(string: config.mac) ?? .randomLocallyAdministered()
    net.attachment = VZNATNetworkDeviceAttachment()
    vz.networkDevices = [net]

    // Input
    vz.keyboards      = [VZUSBKeyboardConfiguration()]
    vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    // Audio
    if !config.noAudio {
        let audio = VZVirtioSoundDeviceConfiguration()
        let input  = VZVirtioSoundDeviceInputStreamConfiguration();  input.source  = VZHostAudioInputStreamSource()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration(); output.sink = VZHostAudioOutputStreamSink()
        audio.streams = [input, output]
        vz.audioDevices = [audio]
    }

    vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    // Private API: VideoToolbox + M2Scaler paravirtualization
    if !config.noAccel {
        let classes = ["_VZMacVideoToolboxDeviceConfiguration", "_VZMacScalerAcceleratorDeviceConfiguration"]
        let accels = classes.compactMap { NSClassFromString($0) as? NSObject.Type }.map { $0.init() }
        if !accels.isEmpty {
            vz.setValue(accels, forKey: "_acceleratorDevices")
            log("  Accelerators: VideoToolbox, M2Scaler")
        }
    }

    try vz.validate()
    return vz
}

// Variant for install: takes raw hardware model + aux storage instead of loading from bundle files
func buildInstallVMConfig(hardwareModel: VZMacHardwareModel, machineId: VZMacMachineIdentifier,
                          auxStorage: VZMacAuxiliaryStorage, diskURL: URL, config: VMConfig) throws -> VZVirtualMachineConfiguration {
    let vz = VZVirtualMachineConfiguration()

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel     = hardwareModel
    platform.machineIdentifier = machineId
    platform.auxiliaryStorage  = auxStorage
    vz.platform   = platform
    vz.bootLoader = VZMacOSBootLoader()
    vz.cpuCount   = config.cpus
    vz.memorySize = config.memorySize

    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(
        widthInPixels: config.width, heightInPixels: config.height, pixelsPerInch: config.ppi
    )]
    vz.graphicsDevices = [gfx]

    vz.storageDevices = [VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
    )]

    let net = VZVirtioNetworkDeviceConfiguration()
    net.macAddress = VZMACAddress(string: config.mac) ?? .randomLocallyAdministered()
    net.attachment = VZNATNetworkDeviceAttachment()
    vz.networkDevices = [net]

    vz.keyboards       = [VZUSBKeyboardConfiguration()]
    vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    vz.entropyDevices  = [VZVirtioEntropyDeviceConfiguration()]

    if !config.noAudio {
        let audio  = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration(); output.sink = VZHostAudioOutputStreamSink()
        audio.streams = [output]
        vz.audioDevices = [audio]
    }

    try vz.validate()
    return vz
}

// MARK: - Install

func resolveIPSW(_ path: String, near bundlePath: String) -> URL {
    if path != "latest" {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { die("IPSW not found at '\(path)'") }
        return url
    }

    log("Fetching latest supported IPSW info...")
    let image: VZMacOSRestoreImage = try! waitFor { cb in VZMacOSRestoreImage.fetchLatestSupported { cb($0) } }
    let dest  = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().appendingPathComponent(image.url.lastPathComponent)

    if FileManager.default.fileExists(atPath: dest.path) {
        log("IPSW already downloaded: \(dest.path)")
        return dest
    }

    log("Downloading: \(image.url)")
    let task = URLSession.shared.downloadTask(with: image.url) { tmp, _, err in
        if let err { die("Download failed: \(err.localizedDescription)") }
        try! FileManager.default.moveItem(at: tmp!, to: dest)
    }
    task.resume()
    var lastPct = -1
    while task.state == URLSessionTask.State.running {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1.0))
        let recv = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive
        if total > 0 {
            let pct = Int(recv * 100 / total)
            if pct != lastPct {
                fputs("\r  \(pct)%  \(String(format: "%.1f/%.1f GB", Double(recv) / 1e9, Double(total) / 1e9))   ", stderr)
                lastPct = pct
            }
        }
    }
    fputs("\n", stderr)
    log("Download complete.")
    return dest
}

func install(ipswPath: String, bundlePath: String, config: VMConfig) {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: bundlePath) else {
        die("'\(bundlePath)' already exists. Remove it first or choose a different path.")
    }

    // Resolve IPSW (download if "latest")
    let ipswURL = resolveIPSW(ipswPath, near: bundlePath)

    // Load restore image metadata
    log("Loading IPSW: \(ipswURL.lastPathComponent)")
    let image: VZMacOSRestoreImage = try! waitFor { cb in VZMacOSRestoreImage.load(from: ipswURL) { cb($0) } }
    guard let reqs = image.mostFeaturefulSupportedConfiguration else { die("IPSW not supported on this host") }

    let hwModel = reqs.hardwareModel
    log("  Build: \(image.buildVersion)")
    log("  Min CPUs: \(reqs.minimumSupportedCPUCount), Min RAM: \(reqs.minimumSupportedMemorySize / GB) GB")

    // Clamp config to IPSW minimums
    var cfg = config
    if cfg.cpus     < reqs.minimumSupportedCPUCount { cfg.cpus     = reqs.minimumSupportedCPUCount }
    if cfg.memoryGB < Int(reqs.minimumSupportedMemorySize / GB) { cfg.memoryGB = Int(reqs.minimumSupportedMemorySize / GB) }
    if cfg.mac.isEmpty { cfg.mac = VZMACAddress.randomLocallyAdministered().string }

    // Create bundle directory and contents
    let bundle = VMBundle(url: URL(fileURLWithPath: bundlePath))
    try! fm.createDirectory(at: bundle.url, withIntermediateDirectories: true)
    try! hwModel.dataRepresentation.write(to: bundle.hardwareModel)
    let mid = VZMacMachineIdentifier()
    try! mid.dataRepresentation.write(to: bundle.machineId)
    let aux = try! VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxStorage, hardwareModel: hwModel, options: [.allowOverwrite])
    fm.createFile(atPath: bundle.disk.path, contents: nil)
    try! FileHandle(forWritingTo: bundle.disk).apply { try $0.truncate(atOffset: UInt64(cfg.diskGB) * GB); try $0.close() }
    try! cfg.save(to: bundle.configJSON)

    log("  Created bundle: \(bundlePath)")
    log("  CPUs: \(cfg.cpus), RAM: \(cfg.memoryGB) GB, Disk: \(cfg.diskGB) GB")

    // Build VM config and install
    let vmConfig = try! buildInstallVMConfig(hardwareModel: hwModel, machineId: mid, auxStorage: aux, diskURL: bundle.disk, config: cfg)
    let vm = VZVirtualMachine(configuration: vmConfig)

    log("Installing macOS (this will take a while)...")
    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
    let obs = installer.progress.observe(\.fractionCompleted, options: []) { (p: Progress, _) in
        fputs("\r  Install progress: \(Int(p.fractionCompleted * 100))%    ", stderr)
    }

    let sem = DispatchSemaphore(value: 0)
    var installErr: Error?
    installer.install { result in
        if case .failure(let e) = result { installErr = e }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5)) }
    _ = obs; fputs("\n", stderr)

    if let e = installErr {
        let ns = e as NSError
        log("  Domain: \(ns.domain), Code: \(ns.code)")
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            log("  Underlying: \(underlying.domain) \(underlying.code) - \(underlying.localizedDescription)")
        }
        die("Install failed: \(e.localizedDescription)")
    }
    log("macOS installed successfully!")
    log("Run with:  avm \(bundlePath)")
    exit(0)
}

// MARK: - Run

class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: Error) { log("VM stopped: \(error.localizedDescription)"); exit(1) }
    func guestDidStop(_ vm: VZVirtualMachine) { log("Guest shut down."); exit(0) }
}

class VMWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let view: VZVirtualMachineView

    init(vm: VZVirtualMachine, title: String, width: Int, height: Int) {
        view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width) / 2, height: CGFloat(height) / 2),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.contentMinSize = NSSize(width: 640, height: 480)
        super.init()
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { exit(0) }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let bundle: VMBundle, config: VMConfig, headless: Bool, recovery: Bool
    var delegate: VMDelegate?
    var window: VMWindow?

    init(bundle: VMBundle, config: VMConfig, headless: Bool, recovery: Bool) {
        self.bundle = bundle; self.config = config; self.headless = headless; self.recovery = recovery
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        do {
            log("VM: \(bundle.name)")
            log("  CPUs: \(config.cpus), RAM: \(config.memoryGB) GB")
            log("  Display: \(config.width)x\(config.height) @ \(config.ppi) PPI")
            log("  Mode: \(headless ? "headless" : "GUI")\(recovery ? " (recovery)" : "")")

            let vmConfig = try buildVMConfig(bundle: bundle, config: config)
            let vm = VZVirtualMachine(configuration: vmConfig)
            delegate = VMDelegate(); vm.delegate = delegate

            if headless {
                // Attach a VZVirtualMachineView even in headless mode -- without it,
                // Virtualization.framework doesn't create the NAT bridge (bridge100)
                let view = VZVirtualMachineView()
                view.virtualMachine = vm
                objc_setAssociatedObject(vm, "headlessView", view, .OBJC_ASSOCIATION_RETAIN)
            } else {
                window = VMWindow(vm: vm, title: bundle.name, width: config.width, height: config.height)
            }

            log("Starting...")
            if recovery {
                let opts = VZMacOSVirtualMachineStartOptions(); opts.startUpFromMacOSRecovery = true
                vm.start(options: opts) { if let e = $0 { die("Failed to start: \(e.localizedDescription)") }; log("VM running (recovery).") }
            } else {
                vm.start { r in if case .failure(let e) = r { die("Failed to start: \(e.localizedDescription)") }; log("VM running.") }
            }
        } catch { die(error.localizedDescription) }
    }
}

// MARK: - CLI

let usage = """
avm - macOS VM manager using Virtualization.framework

USAGE:
  avm <path.vbvm>                          Run an existing VM
  avm install <ipsw|latest> <path.vbvm>    Create and install a new VM

OPTIONS:
  --headless       Run without GUI window      --recovery       Boot into macOS Recovery
  --cpus <n>       CPU count (default: 4)      --memory <n>     RAM in GB (default: 4)
  --disk <n>       Disk size in GB (default: 64, install only)
  --display <WxH>  Resolution (default: 1920x1200)
  --no-accel       Disable VideoToolbox/M2Scaler paravirtualization
  --no-audio       Disable audio

EXAMPLES:
  avm install latest ~/VMs/dev.vbvm --cpus 6 --memory 8 --disk 128
  avm ~/VMs/dev.vbvm
  avm --headless --recovery ~/VMs/dev.vbvm
"""

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { fputs(usage + "\n", stderr); exit(0) }

let isInstall = args.first == "install"
if isInstall { args.removeFirst() }

var headless = false, recovery = false
var config = VMConfig()
var positional: [String] = []

var i = 0
while i < args.count {
    switch args[i] {
    case "--headless":  headless = true
    case "--recovery":  recovery = true
    case "--no-accel":  config.noAccel = true
    case "--no-audio":  config.noAudio = true
    case "--cpus":      i += 1; guard i < args.count, let v = Int(args[i]), v > 0 else { die("--cpus needs positive int") }; config.cpus = v
    case "--memory":    i += 1; guard i < args.count, let v = Int(args[i]), v > 0 else { die("--memory needs positive int") }; config.memoryGB = v
    case "--disk":      i += 1; guard i < args.count, let v = Int(args[i]), v > 0 else { die("--disk needs positive int") }; config.diskGB = v
    case "--display":
        i += 1; guard i < args.count else { die("--display needs WxH") }
        let p = args[i].lowercased().split(separator: "x")
        guard p.count == 2, let w = Int(p[0]), let h = Int(p[1]), w > 0, h > 0 else { die("--display format: WxH") }
        config.width = w; config.height = h
    default:
        if args[i].hasPrefix("-") { die("unknown option '\(args[i])'") }
        positional.append(args[i])
    }
    i += 1
}

if isInstall {
    guard positional.count == 2 else { die("install needs <ipsw|latest> <bundle-path>") }
    install(ipswPath: positional[0], bundlePath: positional[1], config: config)
    dispatchMain()
} else {
    guard positional.count == 1 else { die("expected one VM bundle path") }
    let path = positional[0]
    guard FileManager.default.fileExists(atPath: path) else { die("'\(path)' does not exist") }

    let bundle = VMBundle(url: URL(fileURLWithPath: path))
    var cfg = VMConfig.load(from: bundle)

    // CLI overrides
    if args.contains("--cpus")    { cfg.cpus   = config.cpus }
    if args.contains("--memory")  { cfg.memoryGB = config.memoryGB }
    if args.contains("--display") { cfg.width  = config.width; cfg.height = config.height }
    if args.contains("--no-audio") { cfg.noAudio = true }
    if args.contains("--no-accel") { cfg.noAccel = true }

    let app = NSApplication.shared
    let appDelegate = AppDelegate(bundle: bundle, config: cfg, headless: headless, recovery: recovery)
    app.delegate = appDelegate
    // .prohibited prevents Virtualization.framework from creating the NAT bridge;
    // .accessory keeps AppKit alive without showing a Dock icon or menu bar
    app.setActivationPolicy(headless ? .accessory : .regular)
    if !headless { app.activate(ignoringOtherApps: true) }
    app.run()
}

// MARK: - Extensions

extension FileHandle {
    @discardableResult func apply(_ body: (FileHandle) throws -> Void) rethrows -> FileHandle { try body(self); return self }
}
