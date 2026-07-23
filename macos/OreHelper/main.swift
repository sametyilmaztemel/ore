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