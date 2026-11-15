import AppKit

DevCommands.runIfRequested()   // dev CLI (--snapshot, --benchmark, ...) exits before the app starts

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
