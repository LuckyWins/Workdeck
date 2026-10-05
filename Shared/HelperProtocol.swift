import Foundation

/// XPC interface exported by the privileged helper. Keep it minimal: every method runs as root.
@objc nonisolated protocol HelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (NSError?) -> Void)
    func isSleepDisabled(reply: @escaping @Sendable (Bool, NSError?) -> Void)
    func version(reply: @escaping @Sendable (String) -> Void)
}
