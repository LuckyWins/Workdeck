import Foundation

let power = PowerSettings(runner: ProcessCommandRunner())

// Launchd starts the helper at boot and after a crash; no client can be holding sleep disabled then.
try? power.setSleepDisabled(false)

let delegate = HelperListenerDelegate(power: power)
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(HelperConstants.clientRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
