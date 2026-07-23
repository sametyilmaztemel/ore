import Foundation
import CoreGraphics
import CoreImage
import AppKit
import IOKit

/// OreHelper - Privileged helper tool for Oretty
/// Installed via SMJobBless, runs as root.
/// Communicates via command-line arguments + stdout.
///
/// Usage:
///   OreHelper capture     → Captures display to stdout (JPEG raw bytes)
///   OreHelper unlock <pw> → Sends password to login window  
///   OreHelper check       → Returns JSON: {"locked":true/false, "login_pid":N}
///   OreHelper lock        → Locks the screen immediately
///   OreHelper install-check → Returns JSON with uid/euid
///   OreHelper mouse_move <x> <y> → Move mouse to absolute coordinates
///   OreHelper mouse_click <button> <0|1> <x> <y> → Click mouse button (0=left,1=right,2=center)
///   OreHelper mouse_scroll <deltaX> <deltaY> → Scroll mouse wheel
///   OreHelper key_event <keyCode> <0|1> [modifiers] → Send keyboard event (modifiers: cmd,shift,option,ctrl,fn)

private let kVersion = "1.0.0"

// MARK: - Lock Screen Detection

func isScreenLocked() -> Bool {
    guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    
    for info in windowList {
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let name = info[kCGWindowOwnerName as String] as? String ?? ""
        if layer == 0 && name == "loginwindow" {
            return true
        }
    }
    return false
}

func getLoginWindowPID() -> pid_t {
    // Try NSWorkspace first
    for app in NSWorkspace.shared.runningApplications {
        if app.bundleIdentifier == "com.apple.loginwindow" {
            return app.processIdentifier
        }
    }
    return -1
}

// MARK: - Screen Capture

func captureDisplay() -> Data? {
    // Use CGDisplayCreateImage via dynamic dispatch to avoid Swift deprecation check
    typealias CGDisplayCreateImageFunc = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
    let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    guard let handle = handle,
          let sym = dlsym(handle, "CGDisplayCreateImage") else {
        return nil
    }
    let fn = unsafeBitCast(sym, to: CGDisplayCreateImageFunc.self)
    guard let image = fn(CGMainDisplayID())?.takeRetainedValue() else {
        dlclose(handle)
        return nil
    }
    dlclose(handle)
    
    let bitmap = NSBitmapImageRep(cgImage: image)
    let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    return jpegData
}

// MARK: - Key Code Mapping

struct KeyEntry {
    let char: Character
    let code: UInt16
    let shift: Bool
}

let keyMap: [Character: (code: UInt16, shift: Bool)] = {
    var map: [Character: (UInt16, Bool)] = [:]
    let entries: [KeyEntry] = [
        KeyEntry(char: "a", code: 0x00, shift: false), KeyEntry(char: "b", code: 0x0B, shift: false),
        KeyEntry(char: "c", code: 0x08, shift: false), KeyEntry(char: "d", code: 0x02, shift: false),
        KeyEntry(char: "e", code: 0x0E, shift: false), KeyEntry(char: "f", code: 0x03, shift: false),
        KeyEntry(char: "g", code: 0x05, shift: false), KeyEntry(char: "h", code: 0x04, shift: false),
        KeyEntry(char: "i", code: 0x22, shift: false), KeyEntry(char: "j", code: 0x26, shift: false),
        KeyEntry(char: "k", code: 0x28, shift: false), KeyEntry(char: "l", code: 0x25, shift: false),
        KeyEntry(char: "m", code: 0x2E, shift: false), KeyEntry(char: "n", code: 0x2D, shift: false),
        KeyEntry(char: "o", code: 0x1F, shift: false), KeyEntry(char: "p", code: 0x23, shift: false),
        KeyEntry(char: "q", code: 0x0C, shift: false), KeyEntry(char: "r", code: 0x0F, shift: false),
        KeyEntry(char: "s", code: 0x01, shift: false), KeyEntry(char: "t", code: 0x11, shift: false),
        KeyEntry(char: "u", code: 0x20, shift: false), KeyEntry(char: "v", code: 0x09, shift: false),
        KeyEntry(char: "w", code: 0x0D, shift: false), KeyEntry(char: "x", code: 0x07, shift: false),
        KeyEntry(char: "y", code: 0x10, shift: false), KeyEntry(char: "z", code: 0x06, shift: false),
        KeyEntry(char: "0", code: 0x1D, shift: false), KeyEntry(char: "1", code: 0x12, shift: false),
        KeyEntry(char: "2", code: 0x13, shift: false), KeyEntry(char: "3", code: 0x14, shift: false),
        KeyEntry(char: "4", code: 0x15, shift: false), KeyEntry(char: "5", code: 0x17, shift: false),
        KeyEntry(char: "6", code: 0x16, shift: false), KeyEntry(char: "7", code: 0x1A, shift: false),
        KeyEntry(char: "8", code: 0x1C, shift: false), KeyEntry(char: "9", code: 0x19, shift: false),
        KeyEntry(char: "-", code: 0x1B, shift: false), KeyEntry(char: "=", code: 0x18, shift: false),
        KeyEntry(char: "[", code: 0x21, shift: false), KeyEntry(char: "]", code: 0x1E, shift: false),
        KeyEntry(char: ";", code: 0x29, shift: false), KeyEntry(char: "'", code: 0x27, shift: false),
        KeyEntry(char: ",", code: 0x2B, shift: false), KeyEntry(char: ".", code: 0x2F, shift: false),
        KeyEntry(char: "/", code: 0x2C, shift: false), KeyEntry(char: "`", code: 0x32, shift: false),
        KeyEntry(char: "\\", code: 0x2A, shift: false), KeyEntry(char: " ", code: 0x31, shift: false),
        // Uppercase (with shift)
        KeyEntry(char: "A", code: 0x00, shift: true), KeyEntry(char: "B", code: 0x0B, shift: true),
        KeyEntry(char: "C", code: 0x08, shift: true), KeyEntry(char: "D", code: 0x02, shift: true),
        KeyEntry(char: "E", code: 0x0E, shift: true), KeyEntry(char: "F", code: 0x03, shift: true),
        KeyEntry(char: "G", code: 0x05, shift: true), KeyEntry(char: "H", code: 0x04, shift: true),
        KeyEntry(char: "I", code: 0x22, shift: true), KeyEntry(char: "J", code: 0x26, shift: true),
        KeyEntry(char: "K", code: 0x28, shift: true), KeyEntry(char: "L", code: 0x25, shift: true),
        KeyEntry(char: "M", code: 0x2E, shift: true), KeyEntry(char: "N", code: 0x2D, shift: true),
        KeyEntry(char: "O", code: 0x1F, shift: true), KeyEntry(char: "P", code: 0x23, shift: true),
        KeyEntry(char: "Q", code: 0x0C, shift: true), KeyEntry(char: "R", code: 0x0F, shift: true),
        KeyEntry(char: "S", code: 0x01, shift: true), KeyEntry(char: "T", code: 0x11, shift: true),
        KeyEntry(char: "U", code: 0x20, shift: true), KeyEntry(char: "V", code: 0x09, shift: true),
        KeyEntry(char: "W", code: 0x0D, shift: true), KeyEntry(char: "X", code: 0x07, shift: true),
        KeyEntry(char: "Y", code: 0x10, shift: true), KeyEntry(char: "Z", code: 0x06, shift: true),
        KeyEntry(char: "!", code: 0x12, shift: true), KeyEntry(char: "@", code: 0x13, shift: true),
        KeyEntry(char: "#", code: 0x14, shift: true), KeyEntry(char: "$", code: 0x15, shift: true),
        KeyEntry(char: "%", code: 0x17, shift: true), KeyEntry(char: "^", code: 0x16, shift: true),
        KeyEntry(char: "&", code: 0x1A, shift: true), KeyEntry(char: "*", code: 0x1C, shift: true),
        KeyEntry(char: "(", code: 0x19, shift: true), KeyEntry(char: ")", code: 0x1D, shift: true),
        KeyEntry(char: "_", code: 0x1B, shift: true), KeyEntry(char: "+", code: 0x18, shift: true),
        KeyEntry(char: "{", code: 0x21, shift: true), KeyEntry(char: "}", code: 0x1E, shift: true),
        KeyEntry(char: ":", code: 0x29, shift: true), KeyEntry(char: "\"", code: 0x27, shift: true),
        KeyEntry(char: "<", code: 0x2B, shift: true), KeyEntry(char: ">", code: 0x2F, shift: true),
        KeyEntry(char: "?", code: 0x2C, shift: true), KeyEntry(char: "~", code: 0x32, shift: true),
        KeyEntry(char: "|", code: 0x2A, shift: true),
    ]
    for e in entries {
        map[e.char] = (e.code, e.shift)
    }
    return map
}()

func typeString(_ str: String) {
    for ch in str {
        guard let entry = keyMap[ch] else { continue }
        
        var flags: CGEventFlags = []
        if entry.shift {
            flags.insert(.maskShift)
        }
        
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: entry.code, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cghidEventTap)
        }
        
        usleep(15000) // 15ms between keypresses
        
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: entry.code, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
    }
}

func pressReturn() {
    if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true) {
        keyDown.post(tap: .cghidEventTap)
    }
    usleep(50000)
    if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false) {
        keyUp.post(tap: .cghidEventTap)
    }
}

func unlockScreen(password: String) -> Bool {
    guard !password.isEmpty else { return false }
    typeString(password)
    usleep(100000)
    pressReturn()
    return true
}

func lockScreenNow() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
        IOServiceMatching("IODisplayWrangler"))
    guard service != 0 else { return false }
    
    let ret = IORegistryEntrySetCFProperty(service, "IORequestIdle" as CFString, kCFBooleanTrue)
    IOObjectRelease(service)
    return ret == KERN_SUCCESS
}

// MARK: - Mouse Event Functions

// FIX: Move mouse cursor to absolute coordinates
func moveMouse(x: Int32, y: Int32) {
    if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: CGFloat(x), y: CGFloat(y)), mouseButton: .left) {
        event.post(tap: .cghidEventTap)
    }
}

// FIX: Click mouse button (button: 0=left, 1=right, 2=center)
func clickMouse(button: Int32, down: Bool, x: Int32, y: Int32) {
    let btn: CGMouseButton
    let downType: CGEventType
    let upType: CGEventType
    switch button {
    case 0:
        btn = .left
        downType = .leftMouseDown
        upType = .leftMouseUp
    case 1:
        btn = .right
        downType = .rightMouseDown
        upType = .rightMouseUp
    case 2:
        btn = .center
        downType = .otherMouseDown
        upType = .otherMouseUp
    default:
        return
    }
    let type = down ? downType : upType
    if let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: CGFloat(x), y: CGFloat(y)), mouseButton: btn) {
        event.post(tap: .cghidEventTap)
    }
}

// FIX: Scroll wheel event
func scrollMouse(deltaX: Int32, deltaY: Int32) {
    if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
        event.post(tap: .cghidEventTap)
    }
}

// FIX: Send key event with modifier flags support
func sendKeyWithModifiers(keyCode: UInt16, down: Bool, flags: CGEventFlags) {
    if let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) {
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}

// FIX: Parse modifier flags from comma-separated string (e.g. "cmd,shift,option")
func parseModifierFlags(_ str: String) -> CGEventFlags {
    var flags: CGEventFlags = []
    let parts = str.split(separator: ",")
    for part in parts {
        switch part.trimmingCharacters(in: .whitespaces).lowercased() {
        case "cmd", "command":    flags.insert(.maskCommand)
        case "opt", "option", "alt": flags.insert(.maskAlternate)
        case "ctrl", "control":   flags.insert(.maskControl)
        case "shift":             flags.insert(.maskShift)
        case "fn", "function":    flags.insert(.maskSecondaryFn)
        default: break
        }
    }
    return flags
}

// FIX: Special key code constants for use with key_event command
struct KeyCodes {
    // Function keys
    static let f1: UInt16 = 0x7A
    static let f2: UInt16 = 0x78
    static let f3: UInt16 = 0x63
    static let f4: UInt16 = 0x76
    static let f5: UInt16 = 0x60
    static let f6: UInt16 = 0x61
    static let f7: UInt16 = 0x62
    static let f8: UInt16 = 0x64
    static let f9: UInt16 = 0x65
    static let f10: UInt16 = 0x6D
    static let f11: UInt16 = 0x67
    static let f12: UInt16 = 0x6F
    // Arrow keys
    static let upArrow: UInt16 = 0x7E
    static let downArrow: UInt16 = 0x7D
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    // Special keys
    static let escape: UInt16 = 0x35
    static let tab: UInt16 = 0x30
    static let delete: UInt16 = 0x33
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let pageUp: UInt16 = 0x74
    static let pageDown: UInt16 = 0x79
    static let `return`: UInt16 = 0x24
    static let space: UInt16 = 0x31
    // Additional keys
    static let fn: UInt16 = 0x3F
    static let backspace: UInt16 = 0x33 // Alias for delete
    static let capsLock: UInt16 = 0x39
}

// MARK: - Main

func main() -> Int32 {
    let args = CommandLine.arguments
    
    if args.count < 2 {
        print("{\"error\":\"no command\", \"version\":\"\(kVersion)\"}")
        return 1
    }
    
    let command = args[1]
    
    switch command {
    case "check":
        let loginPID = getLoginWindowPID()
        let locked = isScreenLocked()
        print("{\"locked\":\(locked),\"login_pid\":\(loginPID)}")
        return 0
        
    case "capture":
        guard let jpegData = captureDisplay() else {
            fputs("{\"error\":\"capture failed\"}\n", stderr)
            return 1
        }
        FileHandle.standardOutput.write(jpegData)
        return 0
        
    case "unlock":
        guard args.count >= 3 else {
            fputs("{\"error\":\"password required\"}\n", stderr)
            return 1
        }
        let success = unlockScreen(password: args[2])
        print("{\"success\":\(success)}")
        return success ? 0 : 1
        
    case "lock":
        let success = lockScreenNow()
        print("{\"success\":\(success)}")
        return success ? 0 : 1
        
    case "install-check":
        print("{\"uid\":\(getuid()),\"euid\":\(geteuid()),\"is_root\":\(geteuid() == 0),\"version\":\"\(kVersion)\"}")
        return 0

    // FIX: Mouse move command
    case "mouse_move":
        guard args.count >= 4,
              let x = Int32(args[2]),
              let y = Int32(args[3]) else {
            fputs("{\"error\":\"usage: mouse_move <x> <y>\"}\n", stderr)
            return 1
        }
        moveMouse(x: x, y: y)
        print("{\"success\":true}")
        return 0

    // FIX: Mouse click command
    case "mouse_click":
        guard args.count >= 6,
              let btn = Int32(args[2]),
              let x = Int32(args[4]),
              let y = Int32(args[5]) else {
            fputs("{\"error\":\"usage: mouse_click <button> <0|1> <x> <y>\"}\n", stderr)
            return 1
        }
        let down = args[3] == "1"
        clickMouse(button: btn, down: down, x: x, y: y)
        print("{\"success\":true}")
        return 0

    // FIX: Mouse scroll command
    case "mouse_scroll":
        guard args.count >= 4,
              let dx = Int32(args[2]),
              let dy = Int32(args[3]) else {
            fputs("{\"error\":\"usage: mouse_scroll <deltaX> <deltaY>\"}\n", stderr)
            return 1
        }
        scrollMouse(deltaX: dx, deltaY: dy)
        print("{\"success\":true}")
        return 0

    // FIX: Key event command with optional modifier flags
    case "key_event":
        guard args.count >= 4,
              let keyCode = UInt16(args[2]) else {
            fputs("{\"error\":\"usage: key_event <keyCode> <0|1> [modifiers...]\"}\n", stderr)
            return 1
        }
        let down = args[3] == "1"
        let flags: CGEventFlags = args.count > 4 ? parseModifierFlags(args[4]) : []
        sendKeyWithModifiers(keyCode: keyCode, down: down, flags: flags)
        print("{\"success\":true}")
        return 0

    default:
        fputs("{\"error\":\"unknown command: \(command)\"}\n", stderr)
        return 1
    }
}

exit(main())
