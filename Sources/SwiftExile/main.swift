import AppKit

let application = NSApplication.shared
let delegate = AppDelegate(options: LaunchOptions.parse())
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
