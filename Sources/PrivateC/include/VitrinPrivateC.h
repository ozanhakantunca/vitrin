// Vitrin — free & open-source window switcher for macOS (GPL-3.0-only)
//
// Declarations for the private WindowServer (SkyLight / CGS) and HIServices APIs Vitrin uses.
//
// Nothing here is linked: every function is declared as a *function-pointer type* only, and the Swift
// layer (`VitrinPrivate`) resolves the symbols at runtime with dlsym. A symbol that disappears on a future
// macOS therefore degrades one feature instead of preventing the app from launching.
//
// Signatures were cross-checked against AltTab (github.com/lwouis/alt-tab-macos, GPL-3.0), yabai and
// NUIKit/CGSInternal, and verified by calling them on macOS 26.
#ifndef VITRIN_PRIVATE_C_H
#define VITRIN_PRIVATE_C_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h> // AXUIElementRef, AXError, ProcessSerialNumber

CF_ASSUME_NONNULL_BEGIN

// MARK: - Types

/// A connection to the WindowServer. Every app has one "main" connection.
typedef int32_t CGSConnectionID;
/// A Mission Control Space.
typedef uint64_t CGSSpaceID;
/// Which Spaces `CopySpacesForWindows` reports (see `VPSpaceMask*`).
typedef int32_t CGSSpaceMask;
/// Identifier of a system ("symbolic") hotkey, e.g. ⌘⇥ = 1.
typedef int32_t CGSSymbolicHotKey;
/// `CGSSpaceGetType` result.
typedef int32_t CGSSpaceType;

enum {
    VPSpaceMaskIncludesCurrent = 1 << 0,
    VPSpaceMaskIncludesOthers  = 1 << 1,
    VPSpaceMaskIncludesUser    = 1 << 2,
    VPSpaceMaskCurrent = VPSpaceMaskIncludesUser | VPSpaceMaskIncludesCurrent,   // 5
    VPSpaceMaskOthers  = VPSpaceMaskIncludesOthers | VPSpaceMaskIncludesCurrent, // 6
    VPSpaceMaskAll     = VPSpaceMaskIncludesUser | VPSpaceMaskIncludesOthers | VPSpaceMaskIncludesCurrent, // 7
};

enum {
    VPSpaceTypeUser       = 0,
    VPSpaceTypeSystem     = 2,
    VPSpaceTypeFullscreen = 4,
};

/// `_SLPSSetFrontProcessWithOptions` modes (yabai's `kCPS*`).
enum {
    VPFrontProcessAllWindows    = 0x100, // bring all of the app's windows forward
    VPFrontProcessUserGenerated = 0x200, // mark the switch as user-initiated (avoids focus-stealing suppression)
    VPFrontProcessNoWindows     = 0x400, // front the process without raising any window
};

// MARK: - SkyLight / CGS (resolved from SkyLight.framework; CGS* aliases are re-exported by CoreGraphics)

/// SLSMainConnectionID / CGSMainConnectionID
typedef CGSConnectionID (*VPMainConnectionIDFn)(void);

/// SLSCopySpacesForWindows — returns (+1) the *union* of Spaces of `windowIDs` (CFArray of CFNumber CGWindowID)
/// as a CFArray of CFNumber CGSSpaceID.
typedef CFArrayRef _Nullable (*VPCopySpacesForWindowsFn)(CGSConnectionID cid, CGSSpaceMask mask, CFArrayRef windowIDs);

/// SLSCopyManagedDisplaySpaces — returns (+1) a CFArray of CFDictionary, one per display:
///   "Display Identifier": CFString (display UUID, or "Main" when displays don't have separate Spaces)
///   "Current Space":      CFDictionary { "id64": CFNumber, "ManagedSpaceID": CFNumber, "type": CFNumber, "uuid": CFString }
///   "Spaces":             CFArray of the same Space dictionaries, in Mission Control order
typedef CFArrayRef _Nullable (*VPCopyManagedDisplaySpacesFn)(CGSConnectionID cid);

/// SLSManagedDisplayGetCurrentSpace — the visible Space on the display with UUID `displayUUID`.
typedef CGSSpaceID (*VPManagedDisplayGetCurrentSpaceFn)(CGSConnectionID cid, CFStringRef displayUUID);

/// SLSGetActiveSpace — the Space of the display that has keyboard focus.
typedef CGSSpaceID (*VPGetActiveSpaceFn)(CGSConnectionID cid);

/// SLSCopyActiveMenuBarDisplayIdentifier — (+1) UUID of the display whose menu bar is active.
typedef CFStringRef _Nullable (*VPCopyActiveMenuBarDisplayIdentifierFn)(CGSConnectionID cid);

/// SLSCopyManagedDisplayForSpace — (+1) UUID of the display that owns `space`.
typedef CFStringRef _Nullable (*VPCopyManagedDisplayForSpaceFn)(CGSConnectionID cid, CGSSpaceID space);

/// SLSSpaceGetType — `VPSpaceType*`.
typedef CGSSpaceType (*VPSpaceGetTypeFn)(CGSConnectionID cid, CGSSpaceID space);

/// CGSSetSymbolicHotKeyEnabled. NOTE: the change persists after the calling app quits.
typedef CGError (*VPSetSymbolicHotKeyEnabledFn)(CGSSymbolicHotKey hotKey, bool enabled);

/// CGSIsSymbolicHotKeyEnabled
typedef bool (*VPIsSymbolicHotKeyEnabledFn)(CGSSymbolicHotKey hotKey);

/// CGSGetSymbolicHotKeyValue. `outModifiers` receives CGEventFlags-style bits. It is declared 64-bit here
/// (CGSInternal says `unsigned long`); callers pass a zeroed buffer so a 32-bit write is also safe.
typedef CGError (*VPGetSymbolicHotKeyValueFn)(CGSSymbolicHotKey hotKey,
                                              uint16_t *outKeyEquivalent,
                                              uint16_t *outVirtualKeyCode,
                                              uint64_t *outModifiers);

/// _SLPSSetFrontProcessWithOptions — make `psn` the front process, focusing window `wid` (0 = any).
typedef CGError (*VPSetFrontProcessWithOptionsFn)(ProcessSerialNumber *psn, CGWindowID wid, uint32_t mode);

/// SLSSpaceSetFrontPSN — sets the front process of ONE Space, without making it the global front process or
/// touching other Spaces' front-window memory. Used after a cross-Space focus to restore the origin Space's
/// front app (AltTab #4507; yabai uses it in `window_manager_send_window_to_space`). PSN is passed by value.
typedef CGError (*VPSpaceSetFrontPSNFn)(CGSConnectionID cid, CGSSpaceID sid, ProcessSerialNumber psn);

/// SLPSPostEventRecordTo — post a raw CGSEventRecord (`bytes`, see `VPFocusEventRecord*`) to `psn`.
/// The callee may read past the declared 0xf8 bytes on macOS 14.7.4+; pass a zeroed 0x100-byte buffer.
typedef CGError (*VPPostEventRecordToFn)(ProcessSerialNumber *psn, uint8_t *bytes);

/// Layout of the synthetic "make key window" event record (Hammerspoon#370, AltTab WindowFocusEvent).
enum {
    VPFocusEventRecordBufferSize   = 0x100, // allocation (zero-filled)
    VPFocusEventRecordDeclaredSize = 0xf8,  // value stored at offset 0x04
    VPFocusEventOffsetLength       = 0x04,  // uint8: declared length
    VPFocusEventOffsetType         = 0x08,  // uint8: 1 = left mouse down, 2 = left mouse up
    VPFocusEventOffsetGlobalPoint  = 0x10,  // CGPoint: global location (kept off-content)
    VPFocusEventOffsetWindowPoint  = 0x20,  // CGPoint: window-relative location (kept off-content)
    VPFocusEventOffsetFlags        = 0x3a,  // uint8: must be 0x10
    VPFocusEventOffsetWindowID     = 0x3c,  // uint32: CGWindowID
};

// MARK: - HIServices (resolved from ApplicationServices.framework)

/// _AXUIElementGetWindow — the CGWindowID backing an AX window element.
typedef AXError (*VPAXUIElementGetWindowFn)(AXUIElementRef element, CGWindowID *outWindowID);

/// _AXUIElementCreateWithRemoteToken — (+1) recreates an AX element from a 20-byte token:
///
///   offset  size  field
///   0x00    4     pid_t     owning process id
///   0x04    4     int32     0
///   0x08    4     uint32    0x636f636f ('coco')
///   0x0c    8     uint64    AXUIElementID (per-process element counter)
///
/// Brute-forcing element ids for a pid yields window elements on *other Spaces*, which the public
/// `kAXWindowsAttribute` omits.
typedef AXUIElementRef _Nullable (*VPAXUIElementCreateWithRemoteTokenFn)(CFDataRef token);

enum {
    VPAXRemoteTokenSize  = 20,
    VPAXRemoteTokenMagic = 0x636f636f,
};

/// GetProcessForPID (deprecated public API, still required to get a PSN for the SLPS* calls).
typedef OSStatus (*VPGetProcessForPIDFn)(pid_t pid, ProcessSerialNumber *outPSN);

// MARK: - MultitouchSupport (resolved from MultitouchSupport.framework)
//
// Raw trackpad contact frames, used for the three-finger swipe gesture. The approach (register a
// contact-frame callback on every device from `MTDeviceCreateList`, then `MTDeviceStart`) is the one
// AltTab ships (github.com/lwouis/alt-tab-macos, GPL-3.0, `TrackpadEvents`); the struct layout below is
// the long-standing community reverse-engineering of `MultitouchSupport.h` (calftrail "Finger" struct,
// M5MultitouchSupport, OpenMultitouchSupport), unchanged on 64-bit macOS 10.6 → 26.
//
// Callbacks arrive on a private MultitouchSupport thread, roughly once per frame (~90–120 Hz) while any
// contact is present, plus one frame with zero touches after the last lift.

/// An MTDevice (a CFType owned by the array returned from `MTDeviceCreateList`).
typedef void *VPMTDeviceRef;

typedef struct {
    float x;
    float y;
} VPMTPoint;

typedef struct {
    VPMTPoint position;
    VPMTPoint velocity;
} VPMTVector;

/// `MTTouch.state` values. A finger is "on the pad" in MakeTouch / Touching.
enum {
    VPMTTouchStateNotTracking   = 0,
    VPMTTouchStateStartInRange  = 1,
    VPMTTouchStateHoverInRange  = 2,
    VPMTTouchStateMakeTouch     = 3,
    VPMTTouchStateTouching      = 4,
    VPMTTouchStateBreakTouch    = 5,
    VPMTTouchStateLingerInRange = 6,
    VPMTTouchStateOutOfRange    = 7,
};

/// One contact in a frame. 96 bytes, 8-byte aligned:
///
///   offset  size  field
///   0x00    4     int32    frame           frame counter
///   0x04    4     -        (padding)
///   0x08    8     double   timestamp       seconds (host uptime)
///   0x10    4     int32    identifier      stable per contact while it stays on the pad
///   0x14    4     int32    state           VPMTTouchState*
///   0x18    4     int32    fingerID        (unreliable finger classification)
///   0x1c    4     int32    handID
///   0x20    16    VPMTVector normalized    position 0…1 (x: left→right, y: bottom→top) + velocity
///   0x30    4     float    size            contact area
///   0x34    4     int32    (zero)
///   0x38    4     float    angle
///   0x3c    4     float    majorAxis
///   0x40    4     float    minorAxis
///   0x44    16    VPMTVector absolute      millimetres
///   0x54    8     int32[2] (zero)
///   0x5c    4     float    density
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    VPMTVector normalized;
    float size;
    int32_t reserved1;
    float angle;
    float majorAxis;
    float minorAxis;
    VPMTVector absolute;
    int32_t reserved2[2];
    float density;
} VPMTTouch;

_Static_assert(sizeof(VPMTTouch) == 96, "MTTouch must be 96 bytes");
_Static_assert(__builtin_offsetof(VPMTTouch, timestamp) == 0x08, "MTTouch.timestamp offset");
_Static_assert(__builtin_offsetof(VPMTTouch, identifier) == 0x10, "MTTouch.identifier offset");
_Static_assert(__builtin_offsetof(VPMTTouch, state) == 0x14, "MTTouch.state offset");
_Static_assert(__builtin_offsetof(VPMTTouch, normalized) == 0x20, "MTTouch.normalized offset");
_Static_assert(__builtin_offsetof(VPMTTouch, size) == 0x30, "MTTouch.size offset");
_Static_assert(__builtin_offsetof(VPMTTouch, absolute) == 0x44, "MTTouch.absolute offset");
_Static_assert(__builtin_offsetof(VPMTTouch, density) == 0x5c, "MTTouch.density offset");

/// Contact-frame callback: `touches` points at `count` contiguous `VPMTTouch`es (valid only during the call).
/// The return value is ignored by the framework.
typedef int (*VPMTContactFrameCallback)(VPMTDeviceRef _Nullable device,
                                        VPMTTouch *_Nullable touches,
                                        int32_t count,
                                        double timestamp,
                                        int32_t frame);

/// MTDeviceCreateList — (+1) CFMutableArray of every multitouch device (built-in and external trackpads,
/// Magic Mouse). Releasing the array releases the devices.
typedef CFMutableArrayRef _Nullable (*VPMTDeviceCreateListFn)(void);
/// MTRegisterContactFrameCallback / MTUnregisterContactFrameCallback
typedef void (*VPMTRegisterContactFrameCallbackFn)(VPMTDeviceRef device, VPMTContactFrameCallback callback);
typedef void (*VPMTUnregisterContactFrameCallbackFn)(VPMTDeviceRef device, VPMTContactFrameCallback callback);
/// MTDeviceStart(device, runMode = 0) / MTDeviceStop(device) — OSStatus-style result, 0 on success.
typedef int32_t (*VPMTDeviceStartFn)(VPMTDeviceRef device, int32_t runMode);
typedef int32_t (*VPMTDeviceStopFn)(VPMTDeviceRef device);
/// MTDeviceIsRunning / MTDeviceIsBuiltIn
typedef bool (*VPMTDeviceIsRunningFn)(VPMTDeviceRef device);
typedef bool (*VPMTDeviceIsBuiltInFn)(VPMTDeviceRef device);
/// MTDeviceGetDeviceID — stable 64-bit id of the device (0 on success).
typedef int32_t (*VPMTDeviceGetDeviceIDFn)(VPMTDeviceRef device, uint64_t *outDeviceID);

CF_ASSUME_NONNULL_END

#endif // VITRIN_PRIVATE_C_H
