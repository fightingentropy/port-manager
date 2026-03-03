import Foundation

let delegate = PrivilegedHelperDelegate()
let listener = NSXPCListener(machServiceName: "com.erlinhoxha.portmanager.helper")
listener.delegate = delegate
listener.resume()

RunLoop.main.run()
