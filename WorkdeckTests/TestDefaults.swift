import Foundation

/// A fresh, empty `UserDefaults` for one test. Its suite is a path in a temporary folder, so CFPreferences keeps the
/// plist there instead of in `~/Library/Preferences`, where every named test suite used to leave a file for good.
func makeTestDefaults() -> UserDefaults {
    UserDefaults(suiteName: makeTemporaryDirectory().appending(path: "defaults").path)!
}
