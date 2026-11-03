//
//  TrackpadGestures.swift
//  BitChord for macOS
//
//  Two-finger trackpad gestures: a horizontal swipe from the left edge goes
//  back, and a downward swipe at the top of the window dismisses the player —
//  the desktop equivalent of the phone's back gesture and its sheet drag.
//
//  They listen to `scrollWheel` because that is what a two-finger swipe
//  produces. The back gesture is restricted to the window's left edge so it
//  can't steal the horizontal shelf rows; the dismiss gesture to the top
//  portion so the lyrics can still be scrolled with two fingers.
//

import AppKit

@MainActor
final class TrackpadGestures: ObservableObject {
    static let shared = TrackpadGestures()

    /// How far the gesture has travelled, 0…1, published while the fingers move
    /// so the UI can follow them instead of jumping at the end.
    @Published private(set) var backProgress: CGFloat = 0
    @Published private(set) var dismissProgress: CGFloat = 0

    var onBack: (() -> Void)?
    var onDismissPlayer: (() -> Void)?
    var isPlayerOpen = false

    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var startPoint: NSPoint = .zero
    private var handled = false

    private let backThreshold: CGFloat = 110
    private let dismissThreshold: CGFloat = 130
    private let edgeWidth: CGFloat = 70

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas, let window = event.window else { return event }

        if event.phase == .began {
            accumulatedX = 0
            accumulatedY = 0
            handled = false
            backProgress = 0
            dismissProgress = 0
            // Window coordinates: origin bottom-left, so a large y is the top.
            startPoint = event.locationInWindow
        }

        accumulatedX += event.scrollingDeltaX
        accumulatedY += event.scrollingDeltaY

        let height = window.frame.height
        let width = window.frame.width
        let startedAtLeftEdge = startPoint.x < edgeWidth
        let startedNearTop = startPoint.y > height * 0.55

        // Follow the fingers: the progress the shell animates with.
        if !handled {
            let horizontal = startedAtLeftEdge
                && abs(accumulatedX) > abs(accumulatedY) * 1.5
            let vertical = abs(accumulatedY) > abs(accumulatedX) * 1.5
            backProgress = horizontal ? min(1, abs(accumulatedX) / backThreshold) : 0
            dismissProgress = (isPlayerOpen && vertical)
                ? min(1, abs(accumulatedY) / dismissThreshold) : 0
        }

        // The gesture belongs to the page only when it starts at the left edge:
        // elsewhere a horizontal two-finger swipe is scrolling a shelf, and
        // treating it as "back" dragged the whole page sideways.
        if !handled, abs(accumulatedX) > backThreshold,
           abs(accumulatedX) > abs(accumulatedY) * 1.5,
           startedAtLeftEdge {
            handled = true
            onBack?()
            return nil
        }

        // With the player open, a two-finger vertical swipe closes it — from
        // anywhere in the window, the way it behaved before the cleanup.
        if !handled, isPlayerOpen, abs(accumulatedY) > dismissThreshold,
           abs(accumulatedY) > abs(accumulatedX) * 1.5 {
            handled = true
            dismissProgress = 0
            onDismissPlayer?()
            return nil
        }

        // Fingers lifted short of the threshold: springs back.
        if event.phase == .ended || event.phase == .cancelled {
            backProgress = 0
            dismissProgress = 0
        }

        return event
    }
}
