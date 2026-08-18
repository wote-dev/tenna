import Foundation
import os

enum Log {
    private static let logger = Logger(subsystem: "com.tennanova.mac", category: "app")

    static func info(_ msg: String) {
        logger.info("\(msg, privacy: .public)")
        emit("[info] \(msg)")
    }

    static func warn(_ msg: String) {
        logger.warning("\(msg, privacy: .public)")
        emit("[warn] \(msg)")
    }

    static func error(_ msg: String) {
        logger.error("\(msg, privacy: .public)")
        emit("[error] \(msg)")
    }

    /// stdout is block-buffered when it isn't a terminal, which hides logs when the
    /// app is launched from a script or by Launch Services. Flush every line.
    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }
}
