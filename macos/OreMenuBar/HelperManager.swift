import Foundation
import ServiceManagement

// MARK: - Helper Manager

/// Manages the privileged helper tool (OreHelper) lifecycle.
/// Handles installation via direct copy + launchctl, and execution of privileged operations.
@MainActor
public class HelperManager: ObservableObject {
    @Published public var isHelperInstalled = false
    @Published public var isHelperRunning = false
    @Published public var lastError: String?

    // These are nonisolated constants — safe to access from any context.
    nonisolated public static let helperBundleID = "com.sametyilmaztemel.ore.helper"
    nonisolated public static let helperMachService = "com.sametyilmaztemel.ore.helper.xpc"
    nonisolated public static let helperPath = "/Library/PrivilegedHelperTools/com.sametyilmaztemel.ore.helper"
    nonisolated public static let plistPath = "/Library/LaunchDaemons/com.sametyilmaztemel.ore.helper.plist"

    public init() {
        checkInstallation()
    }

    // MARK: - Installation

    public func installHelper() async -> Bool {
        // Strategy: Try SMAppService first, fall back to direct copy + launchctl
        do {
            try SMAppService.daemon(plistName: "com.sametyilmaztemel.ore.helper.plist").register()
            isHelperInstalled = true
            lastError = nil
            return true
        } catch {
            // Fallback: direct copy via AppleScript with admin privileges
            lastError = nil
            return await installHelperManually()
        }
    }

    private func installHelperManually() async -> Bool {
        // Resolve helper path: check bundle Resources first, then fall back to bundlePath
        let helperPath: String
        if let path = Bundle.main.path(forResource: "OreHelper", ofType: "") {
            helperPath = path
        } else {
            helperPath = Bundle.main.bundlePath + "/Contents/Resources/OreHelper"
        }

        guard FileManager.default.fileExists(atPath: helperPath) else {
            // Try compiling the helper from source as a last resort
            if await compileOreHelper() {
                // Re-resolve after compilation
                let retryPath: String
                if let path = Bundle.main.path(forResource: "OreHelper", ofType: "") {
                    retryPath = path
                } else {
                    retryPath = Bundle.main.bundlePath + "/Contents/Resources/OreHelper"
                }
                guard FileManager.default.fileExists(atPath: retryPath) else {
                    lastError = "Helper binary not found even after compilation"
                    return false
                }
                return await performManualInstall(from: retryPath)
            }
            lastError = "Helper binary not found in app bundle and compilation failed"
            return false
        }

        return await performManualInstall(from: helperPath)
    }

    /// Perform the actual privileged installation (copy + launchctl load).
    private func performManualInstall(from helperPath: String) async -> Bool {
        let escapedHelperPath = helperPath.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedDestPath = Self.helperPath.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPlistPath = Self.plistPath.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        do shell script "
            mkdir -p /Library/PrivilegedHelperTools
            cp -f '\(escapedHelperPath)' '\(escapedDestPath)'
            chown root:wheel '\(escapedDestPath)'
            chmod 755 '\(escapedDestPath)'

            cat > '\(escapedPlistPath)' << PLISTEOF
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>Label</key>
            <string>com.sametyilmaztemel.ore.helper</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(escapedDestPath)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
            <key>UserName</key>
            <string>root</string>
        </dict>
        </plist>
        PLISTEOF
            chown root:wheel '\(escapedPlistPath)'
            chmod 644 '\(escapedPlistPath)'
            launchctl load '\(escapedPlistPath)'
        " with administrator privileges
        """

        let success = await runAppleScript(script)
        if success {
            isHelperInstalled = true
        }
        return success
    }

    /// Compile the OreHelper binary from source code bundled in the app.
    /// Returns true if compilation succeeded and the binary exists at the expected location.
    public func compileOreHelper() async -> Bool {
        // Look for main.swift in the app bundle's Resources
        guard let sourcePath = Bundle.main.path(forResource: "main", ofType: "swift", inDirectory: "Resources") ?? Bundle.main.path(forResource: "main", ofType: "swift") else {
            // Fallback: look next to the app bundle (development layout)
            let devPath = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/OreHelper/main.swift"
            if FileManager.default.fileExists(atPath: devPath) {
                return await compileHelper(from: devPath)
            }
            lastError = "OreHelper source (main.swift) not found in app bundle or development path"
            return false
        }
        return await compileHelper(from: sourcePath)
    }

    /// Internal: run swiftc to compile the helper binary.
    private func compileHelper(from sourcePath: String) async -> Bool {
        let outputPath = Bundle.main.bundlePath + "/Contents/Resources/OreHelper"
        let outputDir = (outputPath as NSString).deletingLastPathComponent

        do {
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create Resources directory: \(error.localizedDescription)"
            return false
        }

        let result: (status: Int32, output: String) = await Task.detached { () -> (Int32, String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            process.arguments = [
                "-o", outputPath,
                "-framework", "CoreGraphics",
                "-framework", "CoreImage",
                "-framework", "AppKit",
                "-framework", "IOKit",
                sourcePath
            ]

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let outputStr = String(data: outputData, encoding: .utf8) ?? ""
                return (process.terminationStatus, outputStr)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value

        if result.status == 0 {
            return FileManager.default.fileExists(atPath: outputPath)
        } else {
            lastError = "Helper compilation failed (code \(result.status)): \(result.output)"
            return false
        }
    }

    public func checkInstallation() {
        isHelperInstalled = FileManager.default.fileExists(atPath: Self.helperPath)
        if isHelperInstalled {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "system/com.sametyilmaztemel.ore.helper"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                isHelperRunning = process.terminationStatus == 0
            } catch {
                isHelperRunning = false
            }
        } else {
            isHelperRunning = false
        }
    }

    public func removeHelper() async -> Bool {
        let script = """
        do shell script "
            launchctl unload \(Self.plistPath) 2>/dev/null || true
            rm -f \(Self.plistPath)
            rm -f \(Self.helperPath)
        " with administrator privileges
        """

        let result = await runAppleScript(script)
        isHelperInstalled = false
        isHelperRunning = false
        return result
    }

    // MARK: - Privileged Operations

    public func unlock(password: String) async -> Bool {
        return await executeHelper(args: ["unlock", password])
    }

    public func isScreenLocked() async -> Bool {
        guard let output = await executeHelperWithOutput(args: ["check"]) else { return false }
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locked = json["locked"] as? Bool else {
            return false
        }
        return locked
    }

    public func captureDisplay() async -> Data? {
        return await executeHelperWithData(args: ["capture"])
    }

    public func lockScreen() async -> Bool {
        return await executeHelper(args: ["lock"])
    }

    public func moveMouse(x: Int32, y: Int32) async -> Bool {
        return await executeHelper(args: ["mouse_move", String(x), String(y)])
    }

    public func clickMouse(button: Int32, down: Bool, x: Int32, y: Int32) async -> Bool {
        return await executeHelper(args: ["mouse_click", String(button), down ? "1" : "0", String(x), String(y)])
    }

    public func scrollMouse(deltaX: Int32, deltaY: Int32) async -> Bool {
        return await executeHelper(args: ["mouse_scroll", String(deltaX), String(deltaY)])
    }

    public func sendKey(keyCode: UInt16, down: Bool, flags: String = "") async -> Bool {
        if flags.isEmpty {
            return await executeHelper(args: ["key_event", String(keyCode), down ? "1" : "0"])
        }
        return await executeHelper(args: ["key_event", String(keyCode), down ? "1" : "0", flags])
    }

    // MARK: - Helper Execution (async wrappers that move blocking work off the main actor)

    private func executeHelper(args: [String]) async -> Bool {
        guard isHelperInstalled else { return false }

        let status = await runProcessDetached(args: args)
        if status < 0 {
            lastError = "Helper execution failed"
            return false
        }
        return status == 0
    }

    private func executeHelperWithOutput(args: [String]) async -> String? {
        guard isHelperInstalled else { return nil }

        let result = await runProcessWithOutputDetached(args: args)
        return result
    }

    private func executeHelperWithData(args: [String]) async -> Data? {
        guard isHelperInstalled else { return nil }

        let result = await runProcessWithDataDetached(args: args)
        return result
    }

    // MARK: - Detached Process Runners

    /// Run a Process on a background task, return termination status (-1 on error).
    private nonisolated func runProcessDetached(args: [String]) async -> Int32 {
        return await Task.detached { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }.value
    }

    /// Run a Process on a background task, return stdout as String (nil on error).
    private nonisolated func runProcessWithOutputDetached(args: [String]) async -> String? {
        return await Task.detached { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = args

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: outputData, encoding: .utf8)
            } catch {
                return nil
            }
        }.value
    }

    /// Run a Process on a background task, return stdout as Data (nil on error).
    private nonisolated func runProcessWithDataDetached(args: [String]) async -> Data? {
        return await Task.detached { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.helperPath)
            process.arguments = args

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                return outputPipe.fileHandleForReading.readDataToEndOfFile()
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - AppleScript Helper

    /// Run AppleScript with admin prompt. NSAppleScript blocks the calling thread
    /// (it shows a modal authorization dialog), so we run it via Task.detached.
    private func runAppleScript(_ source: String) async -> Bool {
        let result: (success: Bool, errorMsg: String?) = await Task.detached { () -> (Bool, String?) in
            guard let appleScript = NSAppleScript(source: source) else {
                return (false, "Failed to create AppleScript")
            }

            var errorDict: NSDictionary?
            appleScript.executeAndReturnError(&errorDict)

            if let errorDict = errorDict {
                let number = errorDict[NSAppleScript.errorNumber] as? Int ?? -1
                let message = errorDict[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                return (false, "AppleScript error #\(number): \(message)")
            }
            return (true, nil)
        }.value

        if let errorMsg = result.errorMsg {
            self.lastError = errorMsg
            return false
        }
        return result.success
    }
}

// MARK: - XPC Service Protocol (for future use with SMJobBless)

public protocol OreHelperXPCProtocol {
    func unlockScreen(password: String, reply: @escaping (Bool, String?) -> Void)
    func isScreenLocked(reply: @escaping (Bool) -> Void)
    func captureDisplay(reply: @escaping (Data?, String?) -> Void)
    func lockScreen(reply: @escaping (Bool, String?) -> Void)
}
