import Foundation
import os

/// The app's log, for what goes wrong quietly: a retry, a fallback, a
/// problem the menu shows in one line. Read it with
/// `log show --predicate 'subsystem == "ru.mac.HAOS"'`.
///
/// `Logger` rather than `NSLog`: `NSLog` lines from this process don't
/// reliably reach the unified log store (verified on macOS 27), which makes
/// them useless for the one thing they're for — reading back what happened
/// after the fact. Messages are marked public: they carry no user data,
/// only errors and interface names, and a redacted log line answers nothing.
let log = Logger(subsystem: "ru.mac.HAOS", category: "app")
