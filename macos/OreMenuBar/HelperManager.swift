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