import Foundation

enum AppleScriptRunner {
    static func run(_ source: String) -> Result<String, Error> {
        guard let script = NSAppleScript(source: source) else {
            return .failure(AppleScriptError.failedToCreate)
        }
        return run(script)
    }

    static func run(_ script: NSAppleScript) -> Result<String, Error> {
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            return .failure(AppleScriptError.executionFailed(message))
        }
        return .success(result.stringValue ?? "")
    }
}

enum AppleScriptError: LocalizedError {
    case failedToCreate
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreate:
            return "Failed to create AppleScript."
        case .executionFailed(let message):
            return message
        }
    }
}
