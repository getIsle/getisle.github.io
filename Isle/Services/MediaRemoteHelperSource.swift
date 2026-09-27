//
//  MediaRemoteHelperSource.swift
//  Isle
//
//  System-wide Now Playing on macOS 15.4+, where MediaRemote only answers
//  Apple-signed processes.
//
//  The trick: Isle itself is not allowed to ask, but Apple's own Swift interpreter
//  is (see the README — `swift probe.swift` works where the compiled binary gets
//  nil). So Isle writes a tiny script to its Caches folder and runs it with the
//  toolchain's `swift`. The script subscribes to MediaRemote's change notifications
//  and streams one JSON line per update on stdout; Isle writes transport commands
//  back on stdin. When Isle quits, stdin closes and the helper exits with it.
//
//  What this buys over Apple Events: EVERY app that publishes Now Playing (Music,
//  Spotify, Safari, Chrome, Arc, Firefox, Podcasts, VLC, IINA, YouTube in any
//  browser…), event-driven instead of 2 s polling, with real artwork, and no
//  Automation or "Allow JavaScript from Apple Events" prompts at all.
//
//  Requirements / costs:
//   • Xcode or the Command Line Tools must be installed (that is where `swift`
//     lives). If not, `isAvailable` is false and MediaService uses Apple Events.
//   • ~1–2 s JIT compile when the helper starts, and one extra process (~40 MB).
//   • It rides on a private framework and on the interpreter's code signature, so a
//     future macOS can close it. MediaService treats it as optional and keeps
//     Apple Events as the safety net.
//

import AppKit
import Foundation
import os

final class MediaRemoteHelperSource: NowPlayingSource {

    let name = "MediaRemote (helper)"

    var onUpdate: ((NowPlayingInfo?) -> Void)?
    private(set) var hasProducedData = false
    let isAvailable: Bool

    private let log = Logger(subsystem: "com.isle.Isle", category: "MediaHelper")
    private let swiftPath: String?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var wantsRunning = false
    private var restartCount = 0

    /// stdout arrives in arbitrary chunks; lines are split and decoded here, off the
    /// main thread, because a line can carry a few hundred KB of base64 artwork.
    private let parseQueue = DispatchQueue(label: "com.isle.Isle.media-helper")
    private var buffer = Data()
    private var artworkCache: (key: String, image: NSImage)?

    init() {
        swiftPath = Self.locateSwift()
        isAvailable = swiftPath != nil
        if !isAvailable {
            log.notice("No Swift toolchain found — the MediaRemote helper is unavailable")
        }
    }

    deinit { terminate() }

    // MARK: Toolchain discovery

    /// `/usr/bin/swift` is only a shim: without a toolchain it pops the "install
    /// Command Line Tools?" dialog, which we must never trigger from a menu bar
    /// app. So ask `xcode-select` where the developer dir is and use that `swift`.
    static func locateSwift() -> String? {
        let selector = Process()
        selector.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        selector.arguments = ["-p"]
        let output = Pipe()
        selector.standardOutput = output
        selector.standardError = Pipe()
        do { try selector.run() } catch { return nil }
        selector.waitUntilExit()
        guard selector.terminationStatus == 0 else { return nil }

        let developerDir = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = [
            developerDir + "/usr/bin/swift",
            developerDir + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Lifecycle

    func start() {
        guard isAvailable, !wantsRunning else { return }
        wantsRunning = true
        restartCount = 0
        launch()
    }

    func stop() {
        wantsRunning = false
        terminate()
    }

    func refresh() {
        write("refresh")
    }

    @discardableResult
    func send(_ command: MediaCommand) -> Bool {
        // MediaRemote's command numbers.
        let code: Int
        switch command {
        case .play: code = 0
        case .pause: code = 1
        case .togglePlayPause: code = 2
        case .nextTrack: code = 4
        case .previousTrack: code = 5
        }
        return write(String(code))
    }

    private func launch() {
        guard wantsRunning, process == nil, let swiftPath, let script = Self.installScript() else {
            return
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: swiftPath)
        helper.arguments = ["-swift-version", "5", script.path]

        let stdout = Pipe()
        let stdin = Pipe()
        let stderr = Pipe()
        helper.standardOutput = stdout
        helper.standardInput = stdin
        helper.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.parseQueue.async { self?.consume(data) }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // Compile errors in the script land here — worth seeing in Console.
            let text = String(decoding: data, as: UTF8.self)
            self?.log.error("helper stderr: \(text, privacy: .public)")
        }

        helper.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { self?.helperExited(status: status) }
        }

        do {
            try helper.run()
        } catch {
            log.error("Could not start helper: \(error.localizedDescription, privacy: .public)")
            return
        }

        process = helper
        stdinPipe = stdin
        log.info("MediaRemote helper started (pid \(helper.processIdentifier, privacy: .public))")
    }

    private func terminate() {
        try? stdinPipe?.fileHandleForWriting.close()   // helper exits on EOF
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdinPipe = nil
    }

    private func helperExited(status: Int32) {
        process = nil
        stdinPipe = nil
        guard wantsRunning else { return }

        log.notice("MediaRemote helper exited with status \(status, privacy: .public)")
        guard restartCount < 3 else {
            log.error("MediaRemote helper keeps exiting — giving up until next launch")
            return
        }
        restartCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.launch() }
    }

    @discardableResult
    private func write(_ line: String) -> Bool {
        guard let handle = stdinPipe?.fileHandleForWriting,
              let data = (line + "\n").data(using: .utf8) else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    // MARK: Parsing (parseQueue)

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return }

        switch type {
        case "ready":
            log.info("MediaRemote helper ready")
        case "error":
            log.error("MediaRemote helper: \(object["message"] as? String ?? "?", privacy: .public)")
        case "info":
            let media = makeInfo(from: object)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsRunning else { return }
                if media != nil { self.hasProducedData = true }
                self.onUpdate?(media)
            }
        default:
            break
        }
    }

    private func makeInfo(from object: [String: Any]) -> NowPlayingInfo? {
        let title = object["title"] as? String ?? ""
        let artist = object["artist"] as? String ?? ""
        guard !(title.isEmpty && artist.isEmpty) else { return nil }

        let rate = object["rate"] as? Double ?? 0
        let timestamp = (object["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()

        var media = NowPlayingInfo(
            title: title,
            artist: artist,
            album: object["album"] as? String ?? "",
            isPlaying: rate > 0,
            duration: object["duration"] as? Double ?? 0,
            elapsed: object["elapsed"] as? Double ?? 0,
            playbackRate: rate,
            timestamp: timestamp,
            artwork: artwork(from: object),
            sourceBundleIdentifier: nil,
            sourceName: nil
        )

        if let pid = object["pid"] as? Int, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
            media.sourceBundleIdentifier = app.bundleIdentifier
            media.sourceName = app.localizedName
        }
        return media
    }

    /// The helper sends the (large) artwork payload only when the cover changes and
    /// otherwise just its key, so decode once per cover.
    private func artwork(from object: [String: Any]) -> NSImage? {
        guard let key = object["artworkKey"] as? String else { return nil }

        if let encoded = object["artwork"] as? String,
           let data = Data(base64Encoded: encoded),
           let image = NSImage(data: data) {
            artworkCache = (key, image)
            return image
        }
        if let cached = artworkCache, cached.key == key {
            return cached.image
        }
        // We missed the frame that carried this cover — ask for it again.
        DispatchQueue.main.async { [weak self] in self?.write("resend") }
        return nil
    }

    // MARK: The helper script

    private static func installScript() -> URL? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent("com.isle.Isle", isDirectory: true)
        let file = directory.appendingPathComponent("NowPlayingHelper.swift")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = try? String(contentsOf: file, encoding: .utf8)
            if existing != helperScript {
                try helperScript.write(to: file, atomically: true, encoding: .utf8)
            }
            return file
        } catch {
            return nil
        }
    }

    /// Runs under Apple's `swift` interpreter. Foundation only, so it JITs quickly.
    /// Protocol: stdout = one JSON object per line; stdin = "refresh", "resend", or
    /// a MediaRemote command number. EOF on stdin means Isle is gone → exit.
    private static let helperScript = ##"""
    import Foundation

    setvbuf(stdout, nil, _IOLBF, 0)

    typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    typealias GetPIDFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void
    typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    typealias SendFn = @convention(c) (Int32, CFDictionary?) -> Bool

    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    guard let lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
        write(["type": "error", "message": "dlopen MediaRemote failed"])
        exit(2)
    }

    func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(lib, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    guard let getInfo = sym("MRMediaRemoteGetNowPlayingInfo", GetInfoFn.self),
          let register = sym("MRMediaRemoteRegisterForNowPlayingNotifications", RegisterFn.self) else {
        write(["type": "error", "message": "MediaRemote symbols missing"])
        exit(2)
    }
    let getPID = sym("MRMediaRemoteGetNowPlayingApplicationPID", GetPIDFn.self)
    let sendCommand = sym("MRMediaRemoteSendCommand", SendFn.self)

    let prefix = "kMRMediaRemoteNowPlayingInfo"
    var lastArtworkKey = ""

    func emit() {
        getInfo(DispatchQueue.main) { dictionary in
            var out: [String: Any] = ["type": "info"]
            if let info = dictionary as? [String: Any], !info.isEmpty {
                out["title"] = info[prefix + "Title"] as? String ?? ""
                out["artist"] = info[prefix + "Artist"] as? String ?? ""
                out["album"] = info[prefix + "Album"] as? String ?? ""
                out["duration"] = (info[prefix + "Duration"] as? NSNumber)?.doubleValue ?? 0
                out["elapsed"] = (info[prefix + "ElapsedTime"] as? NSNumber)?.doubleValue ?? 0
                out["rate"] = (info[prefix + "PlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                if let stamp = info[prefix + "Timestamp"] as? Date {
                    out["timestamp"] = stamp.timeIntervalSince1970
                }
                if let art = info[prefix + "ArtworkData"] as? Data, !art.isEmpty {
                    let key = (info[prefix + "ArtworkIdentifier"] as? String)
                        ?? "\(art.count)-\(art.prefix(512).base64EncodedString().hashValue)"
                    out["artworkKey"] = key
                    if key != lastArtworkKey {
                        out["artwork"] = art.base64EncodedString()
                        lastArtworkKey = key
                    }
                }
            } else {
                lastArtworkKey = ""
            }

            if let getPID {
                getPID(DispatchQueue.main) { pid in
                    out["pid"] = Int(pid)
                    write(out)
                }
            } else {
                write(out)
            }
        }
    }

    FileHandle.standardInput.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { exit(0) }          // Isle quit — go with it.
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for raw in lines {
            let command = raw.trimmingCharacters(in: .whitespaces)
            DispatchQueue.main.async {
                switch command {
                case "refresh":
                    emit()
                case "resend":
                    lastArtworkKey = ""
                    emit()
                default:
                    if let code = Int32(command) {
                        _ = sendCommand?(code, nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { emit() }
                    }
                }
            }
        }
    }

    register(DispatchQueue.main)
    let names = [
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
    ]
    for name in names {
        NotificationCenter.default.addObserver(
            forName: Notification.Name(name), object: nil, queue: .main
        ) { _ in emit() }
    }

    // Browsers move the playhead without posting a notification; resync regularly.
    let resync = Timer(timeInterval: 2, repeats: true) { _ in emit() }
    RunLoop.main.add(resync, forMode: .common)

    write(["type": "ready"])
    emit()
    RunLoop.main.run()
    """##
}
