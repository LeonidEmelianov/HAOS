import Foundation

/// An error whose message is written for the user: it ends up in the menu's
/// status line or a start-failure alert, so it says what went wrong in plain
/// words instead of carrying a code to look up.
struct HAOSError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
