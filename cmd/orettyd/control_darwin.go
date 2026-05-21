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