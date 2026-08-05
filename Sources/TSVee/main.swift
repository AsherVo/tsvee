import AppKit

let app = NSApplication.shared
// The first NSDocumentController instantiated becomes the shared one; ours
// adds open-a-folder-as-tabs support.
let documentController = TSVDocumentController()
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.mainMenu = MainMenu.build()
app.run()
