import AppKit

/// The `deepfield` command. It's the app's own executable: `deepfield install` links it onto
/// the PATH, and running it under that name (or with a command as the first argument) runs the
/// command and exits instead of starting the app. Commands that read or change the wallpaper go
/// to the running app over a local message port, so they show at once; when the app isn't
/// running they work on the saved settings instead.
enum CLI {
    struct Command {
        let name: String
        let summary: String
        let usage: String
        /// Runs in the app when it's running (CLIService); otherwise right here.
        let service: Bool
    }

    static let commands: [Command] = [
        Command(name: "status", summary: "What's showing, and whether Deep Field is running", usage: """
            deepfield status [--json]
            """, service: true),
        Command(name: "scene", summary: "Show the current scene, or switch to one", usage: """
            deepfield scene [NAME|random] [KEY=VALUE...] [--preset NAME] [--fade SECONDS] [--style STYLE]

            Switches the wallpaper to a scene with the settings it had last, plus any changes given.
            NAME is an id or title from `deepfield scenes` ("ringedPlanet", "ringed planet").
              deepfield scene galaxy galaxyType=barred darkMatter=false
              deepfield scene random --fade 4 --style warp
            """, service: true),
        Command(name: "scenes", summary: "List the scenes (* marks the current one)", usage: """
            deepfield scenes [--names|--json]
            """, service: true),
        Command(name: "get", summary: "Print settings", usage: """
            deepfield get [KEY...] [--json]

            With no keys, prints every setting as JSON. One key prints just its value (colors as hex),
            so it works in scripts: bloom=$(deepfield get bloom)
            """, service: true),
        Command(name: "set", summary: "Change settings of the current wallpaper", usage: """
            deepfield set KEY=VALUE... [--preset NAME] [--fade SECONDS] [--style STYLE]

            Keys are the saved settings' names; `deepfield keys` lists the current scene's and
            `deepfield keys --all` every one. Numbers, true/false (or on/off), hex colors and choices:
              deepfield set bloom=0.6 pixelSize=4 dither=blueNoise
              deepfield set palette.core=#ffd27a diskSpeed=1.5
            tilt is the current scene's own; with scene=NAME in the same command, before or after it, the
            new scene's.
            """, service: true),
        Command(name: "keys", summary: "List settings with their values and types", usage: """
            deepfield keys [--scene NAME] [--all] [--names] [--json]

            Without --all: the scene's own settings plus the image settings.
            """, service: true),
        Command(name: "reset", summary: "Put settings back to their defaults", usage: """
            deepfield reset [KEY...] [--scene NAME] [--all] [--fade SECONDS]

            No arguments resets the current scene's own settings (like Customize's Reset); KEYs reset
            just those; --all resets everything but frame rate and lock screen settings.
            """, service: true),
        Command(name: "presets", summary: "List saved, scene color and palette presets", usage: """
            deepfield presets [--scene NAME] [--names|--json]
            """, service: true),
        Command(name: "preset", summary: "Apply, save, delete, rename, export or import presets", usage: """
            deepfield preset apply NAME|FILE.deepfield [KEY=VALUE...] [--fade SECONDS] [--style STYLE]
            deepfield preset save NAME [--with-place]
            deepfield preset delete NAME
            deepfield preset rename OLD NEW
            deepfield preset export [NAME] FILE.deepfield [--with-place]    (the current settings without NAME)
            deepfield preset import FILE.deepfield...

            apply also takes a palette preset ("Synthwave") or one of the scene's color presets.
            --with-place includes Live Earth's latitude and longitude, left out otherwise.
            """, service: true),
        Command(name: "events", summary: "List events you can trigger", usage: """
            deepfield events [--all] [--names|--json]
            """, service: true),
        Command(name: "event", summary: "Trigger an event now", usage: """
            deepfield event NAME|ID
              deepfield event supernova
            """, service: true),
        Command(name: "on", summary: "Show the scene on the desktop", usage: "deepfield on", service: true),
        Command(name: "off", summary: "Hide it, leaving your own desktop picture", usage: "deepfield off", service: true),
        Command(name: "toggle", summary: "Switch between on and off", usage: "deepfield toggle", service: true),
        Command(name: "pause", summary: "Pause the animation", usage: "deepfield pause", service: true),
        Command(name: "resume", summary: "Resume the animation", usage: "deepfield resume", service: true),
        Command(name: "schedule", summary: "Schedule status, on, off, or skip to the next entry", usage: """
            deepfield schedule [status|on|off|next] [--json]
            """, service: true),
        Command(name: "login", summary: "Launch at login: status, on or off", usage: """
            deepfield login [status|on|off]
            """, service: true),
        Command(name: "customize", summary: "Open the Customize window", usage: """
            deepfield customize [--section scene|sky|image|system|phone|schedule]
            """, service: true),
        Command(name: "render", summary: "Render an image, video, time-lapse, GIF or frames", usage: RenderCommand.usage, service: false),
        Command(name: "launch", summary: "Start Deep Field", usage: "deepfield launch [--customize]", service: false),
        Command(name: "quit", summary: "Quit Deep Field", usage: "deepfield quit", service: true),
        Command(name: "install", summary: "Link `deepfield` into a folder on your PATH", usage: """
            deepfield install [--dir FOLDER] [--force]

            Links /usr/local/bin/deepfield (or /opt/homebrew/bin, or ~/.local/bin, the first one you
            can write to) to this copy of the app. Run it again if you move the app.
            """, service: false),
        Command(name: "completion", summary: "Print a shell completion script", usage: """
            deepfield completion zsh|bash|fish

              zsh:  deepfield completion zsh > ~/.zfunc/_deepfield   (with ~/.zfunc on fpath)
              bash: deepfield completion bash > ~/.local/share/bash-completion/completions/deepfield
              fish: deepfield completion fish > ~/.config/fish/completions/deepfield.fish
            """, service: false),
        Command(name: "version", summary: "Print the version", usage: "deepfield version", service: false),
        Command(name: "help", summary: "Help for a command", usage: "deepfield help [COMMAND]", service: false),
    ]

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Runs a command and exits when the executable was started as `deepfield` or its first
    /// argument is a command; otherwise returns, and the app (or a dev command) starts.
    static func runIfRequested() {
        let argv = CommandLine.arguments
        let invokedAs = URL(fileURLWithPath: argv.first ?? "").lastPathComponent
        let args = Array(argv.dropFirst())
        let named = invokedAs == "deepfield"
        guard named || args.first.map({ a in commands.contains { $0.name == a } }) == true else { return }
        // Started through the `deepfield` link, Foundation takes the link's folder for the bundle,
        // so settings would go to the wrong defaults domain. Run the real path instead, keeping
        // the name.
        if Bundle.main.bundleIdentifier == nil, let exe = Bundle.main.executableURL,
           case let real = exe.resolvingSymlinksInPath(), real != exe,
           real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app" {
            var cargs = argv.map { strdup($0) } + [nil]
            execv(real.path, &cargs)
        }
        exit(run(args))
    }

    static func run(_ args: [String]) -> Int32 {
        guard let name = args.first, !["-h", "--help"].contains(name) else {
            print(overview)
            return 0
        }
        if name == "--version" || name == "-v" { print(version); return 0 }
        guard let command = commands.first(where: { $0.name == name }) else {
            let near = commands.map(\.name).filter { $0.hasPrefix(String(name.prefix(2))) }
            stderr("deepfield: unknown command \u{201C}\(name)\u{201D}" + (near.isEmpty ? "" : " (did you mean \(near.joined(separator: ", "))?)"))
            stderr("Run `deepfield help` for the list.")
            return 2
        }
        if args.contains("--help") || args.contains("-h") {
            print("\(command.summary).\n\n\(command.usage)")
            return 0
        }
        let cwd = FileManager.default.currentDirectoryPath
        if command.service {
            let out = CLIClient.send(args, cwd: cwd) ?? {
                if name == "customize" { return launch(["--customize"]) }
                let o = CLIService.run(args, cwd: cwd, inApp: false)
                UserDefaults.standard.synchronize()
                return o
            }()
            FileHandle.standardOutput.write(Data(out.out.utf8))
            FileHandle.standardError.write(Data(out.err.utf8))
            return out.code
        }
        do {
            switch name {
            case "render": return try RenderCommand.run(Array(args.dropFirst()), cwd: cwd)
            case "launch": return emit(launch(Array(args.dropFirst())))
            case "install": return try install(Array(args.dropFirst()))
            case "completion": return try completion(Array(args.dropFirst()))
            case "version": print(version); return 0
            case "help":
                if let topic = args.dropFirst().first {
                    guard let c = commands.first(where: { $0.name == topic }) else { throw CLIError("no command \(topic)") }
                    print("\(c.summary).\n\n\(c.usage)")
                } else if args.contains("--commands") {
                    commands.forEach { print("\($0.name):\($0.summary)") }
                } else {
                    print(overview)
                }
                return 0
            default: return 2
            }
        } catch let e as CLIError {
            stderr("deepfield: \(e.message)")
            return 1
        } catch {
            stderr("deepfield: \(error.localizedDescription)")
            return 1
        }
    }

    static var overview: String {
        let w = commands.map(\.name.count).max() ?? 0
        let list = commands.map { "  \($0.name.padding(toLength: w + 2, withPad: " ", startingAt: 0))\($0.summary)" }
        return """
            Deep Field \(version): animated space wallpapers from the command line.

            Usage: deepfield COMMAND [ARGS]

            \(list.joined(separator: "\n"))

            `deepfield help COMMAND` (or COMMAND --help) explains one. Changes go to the running app and
            show at once; when it isn't running they're saved for its next launch.
            """
    }

    static func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private static func emit(_ o: CLIOutput) -> Int32 {
        FileHandle.standardOutput.write(Data(o.out.utf8))
        FileHandle.standardError.write(Data(o.err.utf8))
        return o.code
    }

    // MARK: launch

    /// The app bundle this executable is in, or the installed one.
    static var appURL: URL? {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let bundle = exe?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let bundle, bundle.pathExtension == "app" { return bundle }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.narrowstacks.DeepField")
    }

    private static func launch(_ args: [String]) -> CLIOutput {
        let o = CLIOutput()
        if CLIClient.isRunning {
            if args.contains("--customize") { return CLIClient.send(["customize"], cwd: "/") ?? o }
            o.print("Deep Field is already running")
            return o
        }
        guard let url = appURL else { o.fail("can't find Deep Field.app"); return o }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args.contains("--customize") ? ["--customize"] : []
        config.activates = args.contains("--customize")
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure { o.fail("couldn't start Deep Field: \(failure.localizedDescription)"); return o }
        // wait for its port, so a command right after this one reaches it
        let deadline = Date().addingTimeInterval(20)
        while !CLIClient.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if !CLIClient.isRunning { o.warn("Deep Field started but isn't answering yet") }
        return o
    }

    // MARK: install

    private static func install(_ args: [String]) throws -> Int32 {
        let a = try ParsedArgs(args, values: ["--dir"], flags: ["--force"])
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath(),
              exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().pathExtension == "app" else {
            throw CLIError("run install from the app: \"/Applications/Deep Field.app/Contents/MacOS/DeepField\" install")
        }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dir: String
        if let d = a.value("--dir") {
            dir = (d as NSString).expandingTildeInPath
        } else {
            let candidates = ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin"]
            dir = candidates.first { fm.isWritableFile(atPath: $0) } ?? "\(home)/.local/bin"
        }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let link = (dir as NSString).appendingPathComponent("deepfield")
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
            if URL(fileURLWithPath: existing).resolvingSymlinksInPath() != exe && !a.has("--force") {
                print("Replacing the link to \(existing)")
            }
            try fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            guard a.has("--force") else { throw CLIError("\(link) exists and isn't a link; pass --force to replace it") }
            try fm.removeItem(atPath: link)
        }
        try fm.createSymbolicLink(atPath: link, withDestinationPath: exe.path)
        print("Linked \(link) -> \(exe.path)")
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if !path.contains(dir) {
            print("\(dir) isn't on your PATH; add it in your shell profile:\n  export PATH=\"\(dir):$PATH\"")
        }
        print("Shell completion: `deepfield completion --help`")
        return 0
    }

    // MARK: completion

    private static func completion(_ args: [String]) throws -> Int32 {
        guard let shell = args.first else { throw CLIError("usage: deepfield completion zsh|bash|fish") }
        switch shell {
        case "zsh": print(Completions.zsh)
        case "bash": print(Completions.bash)
        case "fish": print(Completions.fish)
        default: throw CLIError("no completion for \(shell) (zsh, bash, fish)")
        }
        return 0
    }
}

/// Options for one command: `--name value` (or `--name=value`) for those in `values`, bare
/// flags for those in `flags`, and everything else positional.
struct ParsedArgs {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ args: [String], values: Set<String> = [], flags allowed: Set<String> = []) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                positional += args[(i + 1)...]
                break
            }
            if a.hasPrefix("--") {
                var name = a
                var inline: String?
                if let eq = a.firstIndex(of: "=") {
                    name = String(a[..<eq])
                    inline = String(a[a.index(after: eq)...])
                }
                if values.contains(name) {
                    if let inline {
                        options[name] = inline
                    } else {
                        guard i + 1 < args.count else { throw CLIError("\(name) needs a value") }
                        options[name] = args[i + 1]
                        i += 1
                    }
                } else if allowed.contains(name) {
                    // a flag can carry an optional value as --flag=value (render's --loop=2)
                    flags.insert(name)
                    if let inline { options[name] = inline }
                } else {
                    let known = (values.union(allowed)).sorted()
                    throw CLIError("unknown option \(name)" + (known.isEmpty ? "" : " (this command takes \(known.joined(separator: ", ")))"))
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
    func value(_ option: String) -> String? { options[option] }

    func double(_ option: String) throws -> Double? {
        guard let s = options[option] else { return nil }
        guard let x = Double(s), x.isFinite else { throw CLIError("\(option) takes a number, got \u{201C}\(s)\u{201D}") }
        return x
    }

    func int(_ option: String) throws -> Int? {
        guard let s = options[option] else { return nil }
        guard let x = Int(s) else { throw CLIError("\(option) takes a whole number, got \u{201C}\(s)\u{201D}") }
        return x
    }
}

// MARK: message port

private let portName = "com.narrowstacks.DeepField.cli" as CFString

private struct CLIRequest: Codable {
    let args: [String]
    let cwd: String
}

/// The app's end: answers commands from `deepfield` on the main thread.
enum CLIServer {
    private static var port: CFMessagePort?

    static func start() {
        guard port == nil else { return }
        let callback: CFMessagePortCallBack = { _, _, data, _ in
            let reply: CLIOutput
            if let data = data as Data?, let req = try? JSONDecoder().decode(CLIRequest.self, from: data) {
                reply = CLIService.run(req.args, cwd: req.cwd, inApp: true)
            } else {
                reply = CLIOutput()
                reply.fail("bad request")
            }
            let out = (try? JSONEncoder().encode(reply)) ?? Data()
            return Unmanaged.passRetained(out as CFData)
        }
        var shouldFree: DarwinBoolean = false
        guard let p = CFMessagePortCreateLocal(nil, portName, callback, nil, &shouldFree) else {
            NSLog("DeepField: command line port is taken (another copy running?)")
            return
        }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, p, 0), .commonModes)
    }
}

/// The command's end.
enum CLIClient {
    static var isRunning: Bool { CFMessagePortCreateRemote(nil, portName) != nil }

    /// The app's reply, or nil when it isn't running.
    static func send(_ args: [String], cwd: String) -> CLIOutput? {
        guard let remote = CFMessagePortCreateRemote(nil, portName),
              let body = try? JSONEncoder().encode(CLIRequest(args: args, cwd: cwd)) else { return nil }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 0, body as CFData, 5, 60, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess, let data = reply?.takeRetainedValue() as Data?,
              let out = try? JSONDecoder().decode(CLIOutput.self, from: data) else {
            let o = CLIOutput()
            o.fail("Deep Field didn't answer (status \(status))")
            return o
        }
        return out
    }
}
