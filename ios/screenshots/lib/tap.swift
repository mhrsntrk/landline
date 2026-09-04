// A tap, posted at a point on the Simulator's device window.
//
// `xcrun simctl` cannot touch the screen, and the App Preview has to show a
// finger doing the things the app is for: choosing a machine, arming the
// leader, changing window. So the run posts real mouse events at the window,
// which the simulator delivers to the app as real touches.
//
// Usage: tap <x> <y> [<hold-seconds>]  in screen points, top-left origin.
// Needs Accessibility permission for whatever runs it, the same permission the
// menu automation in simctl.sh already uses.

import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: tap <x> <y> [hold]\n".utf8))
    exit(2)
}
let hold = args.count > 3 ? (Double(args[3]) ?? 0.06) : 0.06
let point = CGPoint(x: x, y: y)

// Move first: a down event at a point the cursor was never at is delivered, but
// the simulator's hover state lags it and the first frame of the recording
// catches a highlight in the wrong place.
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(40_000)
CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(useconds_t(hold * 1_000_000))
CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
