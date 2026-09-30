import Foundation
import os

/// Logs to the unified log (`log stream --predicate 'subsystem == "app.macslap.MacSlapApp"'`),
/// to stderr when run from a terminal, and to a small file people can attach to bug reports.
enum AppLog {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(AppInfo.name)/\(AppInfo.name).log")

    /// Rotated at launch past this size; one previous file is kept.
    private static let maxFileSize = 1_000_000

    fileprivate static let logger = Logger(subsystem: AppInfo.bundleIdentifier, category: "app")
    fileprivate static let queue = DispatchQueue(label: "app.macslap.log", qos: .utility)
    fileprivate static let isTerminal = isatty(STDERR_FILENO) != 0

    fileprivate static let fileHandle: FileHandle? = {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxFileSize {
                let previous = fileURL.deletingPathExtension().appendingPathExtension("previous.log")
                try? fm.removeItem(at: previous)
                try fm.moveItem(at: fileURL, to: previous)
            }
        } catch {
            fputs("[\(AppInfo.name)] log rotation failed: \(error)\n", stderr)
        }
        // O_APPEND so writes land at the real end even if something truncates the file.
        let fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            fputs("[\(AppInfo.name)] log file unavailable: \(String(cString: strerror(errno)))\n", stderr)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }()

    fileprivate static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()
}

func log(_ message: String) {
    AppLog.logger.notice("\(message, privacy: .public)")
    if AppLog.isTerminal {
        fputs("[\(AppInfo.name)] \(message)\n", stderr)
    }
    let now = Date()
    AppLog.queue.async {
        let line = "\(AppLog.timestampFormatter.string(from: now)) \(message)\n"
        AppLog.fileHandle?.write(Data(line.utf8))
    }
}
