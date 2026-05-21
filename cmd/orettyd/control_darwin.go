// Package main provides macOS-specific input control functions.
//
// These use CoreGraphics CGEvent API to simulate mouse and keyboard input.
// Note: These do NOT work on the macOS Lock Screen for security reasons.

//go:build darwin

package main

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework CoreGraphics -framework Foundation

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

// Move the mouse cursor to the given coordinates (in screen space).
void moveMouseTo(double x, double y) {
    CGEventRef moveEvent = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved,
        CGPointMake(x, y), kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, moveEvent);
    CFRelease(moveEvent);
}

// Click the mouse at the given coordinates.
void clickAt(double x, double y, int button, int down) {
    CGEventType eventType;
    CGMouseButton btn = kCGMouseButtonLeft;
    
    if (button == 1) btn = kCGMouseButtonRight;
    else if (button == 2) btn = kCGMouseButtonCenter;
    
    if (down) {
        if (button == 0) eventType = kCGEventLeftMouseDown;
        else if (button == 1) eventType = kCGEventRightMouseDown;
        else eventType = kCGEventOtherMouseDown;
    } else {
        if (button == 0) eventType = kCGEventLeftMouseUp;
        else if (button == 1) eventType = kCGEventRightMouseUp;
        else eventType = kCGEventOtherMouseUp;
    }
    
    CGEventRef clickEvent = CGEventCreateMouseEvent(NULL, eventType,
        CGPointMake(x, y), btn);
    CGEventPost(kCGHIDEventTap, clickEvent);
    CFRelease(clickEvent);
}

// Scroll the mouse wheel.
void scrollWheel(double deltaX, double deltaY) {
    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(NULL,
        kCGScrollEventUnitPixel, 2, (int32_t)-deltaY, (int32_t)-deltaX);
    CGEventPost(kCGHIDEventTap, scrollEvent);
    CFRelease(scrollEvent);
}

// Send a keyboard key event.
void sendKeyEvent(unsigned short keyCode, int down) {
    CGEventRef keyEvent = CGEventCreateKeyboardEvent(NULL, keyCode, down != 0);
    CGEventPost(kCGHIDEventTap, keyEvent);
    CFRelease(keyEvent);
}

// Send a keyboard event with modifier flags.
void sendKeyWithModifiers(unsigned short keyCode, int down, CGEventFlags modifiers) {
    CGEventRef keyEvent = CGEventCreateKeyboardEvent(NULL, keyCode, down != 0);
    CGEventSetFlags(keyEvent, modifiers);
    CGEventPost(kCGHIDEventTap, keyEvent);
    CFRelease(keyEvent);
}

// Get CGEventFlags from modifier string array.
CGEventFlags getModifierFlags(const char **modifiers, int count) {
    CGEventFlags flags = 0;
    for (int i = 0; i < count; i++) {
        if (strcmp(modifiers[i], "cmd") == 0 || strcmp(modifiers[i], "command") == 0)
            flags |= kCGEventFlagMaskCommand;
        else if (strcmp(modifiers[i], "alt") == 0 || strcmp(modifiers[i], "option") == 0)
            flags |= kCGEventFlagMaskAlternate;
        else if (strcmp(modifiers[i], "ctrl") == 0 || strcmp(modifiers[i], "control") == 0)
            flags |= kCGEventFlagMaskControl;
        else if (strcmp(modifiers[i], "shift") == 0)
            flags |= kCGEventFlagMaskShift;
        else if (strcmp(modifiers[i], "meta") == 0 || strcmp(modifiers[i], "win") == 0)
            flags |= kCGEventFlagMaskCommand;
    }
    return flags;
}
*/
import "C"
import (
	"log"
	"strings"
	"unicode"
	"unsafe"
)

// Convert modifier string to CGEventFlags
func cgModifiers(modifiers []string) C.CGEventFlags {
	flags := C.CGEventFlags(0)
	for _, m := range modifiers {
		switch strings.ToLower(m) {
		case "cmd", "command":
			flags |= C.kCGEventFlagMaskCommand
		case "alt", "option":
			flags |= C.kCGEventFlagMaskAlternate
		case "ctrl", "control":
			flags |= C.kCGEventFlagMaskControl
		case "shift":
			flags |= C.kCGEventFlagMaskShift
		}
	}
	return flags
}

// Key code mapping for common keys.
var keyCodeMap = map[string]C.ushort{
	"a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
	"z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
	"w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
	"2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
	"9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
	"o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
	"l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
	"\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
	".": 0x2F, "	": 0x30, " ": 0x31, "`": 0x32, "\b": 0x33,
	"backspace": 0x33,
	"\n": 0x24, // return
	"esc": 0x35, "escape": 0x35,
	"cmd": 0x37, "command": 0x37,
	"shift": 0x38, "caps": 0x39,
	"alt": 0x3A, "option": 0x3A,
	"ctrl": 0x3B, "control": 0x3B,
	"right_shift": 0x3C, "right_alt": 0x3D, "right_ctrl": 0x3E,
	"fn": 0x3F, "f17": 0x40, "kp.": 0x41, "kp*": 0x43,
	"kp+": 0x45, "kp-": 0x4E, "kp/": 0x4B, "kp=": 0x51,
	"up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
	"f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
	"f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
	"f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
	"home": 0x73, "end": 0x77, "pgup": 0x74, "pgdn": 0x79,
	"delete": 0x75, "insert": 0x72,
	// FIX: Shifted symbol keys (same key code as base key, shift modifier auto-added by sendKey)
	"~": 0x32, "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15,
	"%": 0x17, "^": 0x16, "&": 0x1A, "*": 0x1C, "(": 0x19,
	")": 0x1D, "_": 0x1B, "+": 0x18, "{": 0x21, "}": 0x1E,
	"|": 0x2A, ":": 0x29, "\"": 0x27, "<": 0x2B, ">": 0x2F,
	"?": 0x2C,
}

// FIX: Shifted symbols that require the shift modifier on a US keyboard
var shiftedSymbols = map[string]bool{
	"~": true, "!": true, "@": true, "#": true, "$": true, "%": true,
	"^": true, "&": true, "*": true, "(": true, ")": true,
	"_": true, "+": true, "{": true, "}": true, "|": true,
	":": true, "\"": true, "<": true, ">": true, "?": true,
}

func moveMouse(x, y float64) {
	C.moveMouseTo(C.double(x), C.double(y))
}

func clickMouse(button int, down bool, x, y float64) {
	downInt := 0
	if down {
		downInt = 1
	}
	C.clickAt(C.double(x), C.double(y), C.int(button), C.int(downInt))
}

func scrollMouse(deltaX, deltaY float64) {
	// FIX: Clamp delta values to prevent int32 overflow in C cast
	if deltaX > 100 {
		deltaX = 100
	}
	if deltaX < -100 {
		deltaX = -100
	}
	if deltaY > 100 {
		deltaY = 100
	}
	if deltaY < -100 {
		deltaY = -100
	}
	C.scrollWheel(C.double(deltaX), C.double(deltaY))
}

func sendKey(key, code string, modifiers []string, down bool) {
	downInt := 0
	if down {
		downInt = 1
	}

	keyCode, ok := keyCodeMap[strings.ToLower(key)]
	if !ok {
		// Try the code parameter
		keyCode, ok = keyCodeMap[strings.ToLower(code)]
		if !ok {
			// FIX: Log warning for unknown keys instead of silent return
			log.Printf("[WARN] sendKey: unknown key '%s' (code='%s')", key, code)
			return
		}
	}

	// FIX: Auto-detect shift requirement for uppercase letters and shifted symbols
	shiftInModifiers := false
	for _, m := range modifiers {
		if strings.ToLower(m) == "shift" {
			shiftInModifiers = true
			break
		}
	}

	keyNeedsShift := false
	if !shiftInModifiers {
		for _, ch := range key {
			if unicode.IsUpper(ch) {
				keyNeedsShift = true
				break
			}
		}
		if !keyNeedsShift {
			if _, isShifted := shiftedSymbols[key]; isShifted {
				keyNeedsShift = true
			}
		}
	}

	var finalModifiers []string
	if keyNeedsShift {
		finalModifiers = make([]string, len(modifiers), len(modifiers)+1)
		copy(finalModifiers, modifiers)
		finalModifiers = append(finalModifiers, "shift")
	} else {
		finalModifiers = modifiers
	}

	if len(finalModifiers) > 0 {
		flags := cgModifiers(finalModifiers)
		C.sendKeyWithModifiers(keyCode, C.int(downInt), flags)
	} else {
		C.sendKeyEvent(keyCode, C.int(downInt))
	}
}

func unlockMac(password string) {
	// Lock screen unlock: Send password followed by Enter
	// Note: On macOS 15+, CGEventPost to login window is blocked by SIP
	// This only works if the session is active (not at login window)

	// FIX: Log SIP warning
	log.Printf("[WARN] unlockMac: unlock may fail on macOS 15+ due to SIP restrictions on Lock Screen")

	if password == "" {
		return
	}

	// Type the password character by character
	for _, ch := range password {
		keyCode, ok := keyCodeMap[strings.ToLower(string(ch))]
		if !ok {
			// FIX: Log warning for unknown characters
			log.Printf("[WARN] unlockMac: unknown character '%c' in password, skipping", ch)
			continue
		}

		// FIX: Auto-add shift for uppercase letters and shifted symbols
		needsShift := false
		if unicode.IsUpper(ch) {
			needsShift = true
		}
		if !needsShift {
			if _, isShifted := shiftedSymbols[string(ch)]; isShifted {
				needsShift = true
			}
		}

		if needsShift {
			C.sendKeyWithModifiers(keyCode, 1, C.kCGEventFlagMaskShift) // down
			C.sendKeyWithModifiers(keyCode, 0, C.kCGEventFlagMaskShift) // up
		} else {
			C.sendKeyEvent(keyCode, 1) // down
			C.sendKeyEvent(keyCode, 0) // up
		}
	}

	// Send Enter
	C.sendKeyEvent(0x24, 1)
	C.sendKeyEvent(0x24, 0)
}

// CGDisplayStream-related helper types
// These are C-function wrappers for cursor visibility
var _ = unsafe.Pointer(nil)
