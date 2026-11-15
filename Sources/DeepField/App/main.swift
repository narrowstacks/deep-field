import AppKit

LockScreenStillTest.runIfRequested()   // dev: --lockscreen-still-test
PickerCheck.runIfRequested()   // dev: --check-picker
DevCommands.runIfRequested()   // dev CLI (--snapshot, --benchmark, ...) exits before the app starts

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
