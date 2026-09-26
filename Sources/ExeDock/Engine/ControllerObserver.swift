import Foundation
import GameController

enum ControllerDirection {
    case up, down, left, right
}

/// Tracks whether a game controller is currently connected, using Apple's own `GameController`
/// framework - a real, first-party API, not something rebuilt from scratch. Also the single owner
/// of every button/D-pad handler on the controller - LB/RB step between top-level sections (see
/// `ContentView`'s `stepSection(by:)`), LT/RT step between games in whichever layout has a single
/// featured/focused game to step through (Carousel, Shelves, Spotlight); D-pad/A/B are published as
/// generic signals any view can subscribe to and react to *only while it's the active input layer*
/// (its own `isActiveLayer`-style check on its own state), rather than each view fighting over the
/// same raw `GCExtendedGamepad` handler properties directly. That "single owner, many self-filtering
/// subscribers" split is what lets the grid, the Game Detail view, and the dedicated Controller Mode
/// carousel all support real D-pad/A/B navigation without colliding - whichever one is actually on
/// top just ignores signals when it isn't. Everything here is purely event-driven
/// (`GCControllerDidConnect`/`DidDisconnect` notifications, `pressedChangedHandler`), so this costs
/// nothing while idle.
@MainActor
final class ControllerObserver: ObservableObject {
    static let shared = ControllerObserver()

    @Published private(set) var isConnected: Bool
    /// Cleared automatically whenever a controller (re)connects, so dismissing the banner for one
    /// session doesn't silently suppress it forever.
    @Published var bannerDismissed = false
    /// Bumped exactly once on every real (re)connect - `nil` at launch if a controller happened to
    /// already be attached before this ever became visible. Purely a UI trigger (the brief green
    /// "controller connected" glow next to the tab switcher) - `isConnected` is still the source of
    /// truth for whether one is attached right now.
    @Published private(set) var connectedPulse: UUID?
    /// Bumped whenever LB/RB is pressed - direction is -1/+1, `token` changes every time so a
    /// repeated press in the same direction still triggers `.onChange` in `ContentView`. Kept as a
    /// plain signal rather than a direct reference to `AppModel`, so this observer doesn't need to
    /// know anything about the app's specific section type.
    @Published private(set) var sectionStepRequest: (direction: Int, token: UUID)?
    /// Bumped whenever LT/RT is pressed - "step to the previous/next game" for whichever layout
    /// currently has one game singled out (Carousel's focused tile, Shelves/Spotlight's featured
    /// hero). Kept separate from `directionPress` since D-pad left/right already means something
    /// different in some of those same layouts (Carousel's own row navigation).
    @Published private(set) var gameStepRequest: (direction: Int, token: UUID)?
    /// Bumped on every D-pad press (button-edge, not continuous) - `token` changes every time so a
    /// repeated press in the same direction still triggers `.onChange` for whichever view is
    /// currently treating itself as the active input layer.
    @Published private(set) var directionPress: (direction: ControllerDirection, token: UUID)?
    /// Bumped on every A-button press - "confirm/select whatever's focused."
    @Published private(set) var primaryPress: UUID?
    /// Bumped on every B-button press - "back/close/cancel."
    @Published private(set) var secondaryPress: UUID?

    /// The real, currently-attached controller's own SF Symbol names for each button this app
    /// actually uses (Apple hands these back per-element, matched to whatever is really plugged in -
    /// an Xbox pad reports its own glyphs, a DualSense reports PlayStation's, an MFi pad its own
    /// generic ones) - so the on-screen control legend shows the real glyph for the real hardware
    /// instead of one guessed icon painted over every controller alike. Falls back to a plain,
    /// reasonable SF Symbol when nothing's connected (the legend only ever renders while
    /// `isConnected` anyway, but every accessor stays safe to call regardless). Reads
    /// `physicalInputProfile` - see `attachGlobalHandlers`'s own doc comment for why that's the
    /// right one to read instead of `extendedGamepad`.
    var dpadSymbol: String { activeProfile?.dpads[GCInputDirectionPad]?.sfSymbolsName ?? "dpad" }
    var buttonASymbol: String { activeProfile?.buttons[GCInputButtonA]?.sfSymbolsName ?? "a.circle" }
    var buttonBSymbol: String { activeProfile?.buttons[GCInputButtonB]?.sfSymbolsName ?? "b.circle" }
    var leftShoulderSymbol: String { activeProfile?.buttons[GCInputLeftShoulder]?.sfSymbolsName ?? "l.rectangle.roundedbottom" }
    var rightShoulderSymbol: String { activeProfile?.buttons[GCInputRightShoulder]?.sfSymbolsName ?? "r.rectangle.roundedbottom" }
    var leftTriggerSymbol: String { activeProfile?.buttons[GCInputLeftTrigger]?.sfSymbolsName ?? "l2.rectangle.roundedbottom" }
    var rightTriggerSymbol: String { activeProfile?.buttons[GCInputRightTrigger]?.sfSymbolsName ?? "r2.rectangle.roundedbottom" }
    private var activeProfile: GCPhysicalInputProfile? { GCController.controllers().first?.physicalInputProfile }

    private init() {
        let atLaunch = GCController.controllers()
        isConnected = !atLaunch.isEmpty
        // Real diagnostics for a real, previously-unresolved report - "controller mode doesn't
        // work, I don't see highlights, can't control anything," with the connect banner/glow
        // never appearing either, meaning this app's GameController detection itself never fires,
        // not just something downstream of it. Nothing here was reproducible without real
        // hardware, so this is the actual, checkable evidence trail for next time instead of a
        // second guess - Settings -> Open Logs Folder -> diagnostics.log.
        DiagnosticsLog.log("ControllerObserver: \(atLaunch.count) controller(s) present at launch" + (atLaunch.isEmpty ? "" : ": " + atLaunch.map { Self.describe($0) }.joined(separator: ", ")))
        // Every controller present, not just the first - a real defensive fix, not just the
        // obvious case: some real hardware (a DualSense reconnecting, in particular) has been seen
        // to briefly enumerate as more than one GCController entry before settling down to one.
        for controller in atLaunch { attachGlobalHandlers(to: controller) }
        // Two real, documented gaps a controller that's paired at the OS level but not yet
        // surfaced to this app can fall into - neither was ever set anywhere in this codebase.
        // `shouldMonitorBackgroundEvents` governs whether GCController keeps delivering events
        // once this app isn't the frontmost/key one (the default is *off*); actively kicking off
        // discovery is Apple's own recommended way to make sure an already-paired Bluetooth
        // controller gets handed to this app promptly rather than only whenever the system
        // happens to get around to it.
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery {
            DiagnosticsLog.log("ControllerObserver: startWirelessControllerDiscovery finished - \(GCController.controllers().count) controller(s) now visible")
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in self?.handleConnect(notification) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] notification in
            let controller = notification.object as? GCController
            Task { @MainActor in
                let name = controller.map { Self.describe($0) } ?? "unknown"
                DiagnosticsLog.log("ControllerObserver: disconnected - \(name)")
                self?.refresh()
            }
        }
    }

    private static func describe(_ controller: GCController) -> String {
        "\(controller.vendorName ?? "unnamed") (extendedGamepad: \(controller.extendedGamepad != nil), physicalInputProfile: \(type(of: controller.physicalInputProfile)))"
    }

    private func handleConnect(_ notification: Notification) {
        let controller = notification.object as? GCController
        DiagnosticsLog.log("ControllerObserver: GCControllerDidConnect fired - " + (controller.map { Self.describe($0) } ?? "notification.object was not a GCController"))
        refresh(justConnected: true)
        if let controller {
            attachGlobalHandlers(to: controller)
        }
    }

    private func refresh(justConnected: Bool = false) {
        isConnected = !GCController.controllers().isEmpty
        if justConnected, isConnected {
            bannerDismissed = false
            connectedPulse = UUID()
        }
    }

    /// Reads `controller.physicalInputProfile` - Apple's newer, unified profile every real
    /// controller populates - rather than `controller.extendedGamepad`, which can come back `nil`
    /// for real, currently-shipping hardware whose exact layout doesn't map perfectly onto Apple's
    /// fixed "extended gamepad" template (confirmed live: a DualSense over Bluetooth reported fine
    /// in macOS's own System Settings but this app never saw it - `extendedGamepad` silently
    /// bailing out here, with no logging at all before this, is the single most likely reason why).
    /// `physicalInputProfile.buttons`/`.dpads` are looked up individually by Apple's own standard
    /// element-name constants (`GCInputButtonA` etc.) and each one is optional on its own, so a
    /// controller genuinely missing one input (say, no shoulder buttons) still gets everything else
    /// wired instead of this bailing out entirely the way the old single `guard let` did.
    private func attachGlobalHandlers(to controller: GCController) {
        let profile = controller.physicalInputProfile
        DiagnosticsLog.log("ControllerObserver: attaching handlers to \(Self.describe(controller)) - buttons: \(profile.buttons.keys.sorted().joined(separator: ",")) dpads: \(profile.dpads.keys.sorted().joined(separator: ","))")

        // Real, per-press diagnostics - "not working, continue checking," after detection itself
        // was already confirmed working (the connect banner/legend genuinely show live). This is
        // the next real question: does a physical press actually reach this handler at all. Every
        // handler below logs on the real button-edge event, before touching any @Published state,
        // so the log alone answers it - if a press is logged, the app saw it; if a screen still
        // didn't react to a logged press, the bug is downstream (a specific view's own `.onChange`
        // filter), not detection or wiring.
        func log(_ input: String) { DiagnosticsLog.log("ControllerObserver: \(input) pressed") }

        profile.buttons[GCInputLeftShoulder]?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("LB")
            Task { @MainActor in self?.sectionStepRequest = (-1, UUID()) }
        }
        profile.buttons[GCInputRightShoulder]?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("RB")
            Task { @MainActor in self?.sectionStepRequest = (1, UUID()) }
        }
        profile.buttons[GCInputLeftTrigger]?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("LT")
            Task { @MainActor in self?.gameStepRequest = (-1, UUID()) }
        }
        profile.buttons[GCInputRightTrigger]?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("RT")
            Task { @MainActor in self?.gameStepRequest = (1, UUID()) }
        }

        // `pressedChangedHandler` (button-edge semantics: fires once per press/release), not
        // `valueChangedHandler` (fires continuously while held) - the latter would fire dozens of
        // times a second while a direction is held, jumping through focus far too fast.
        if let dpad = profile.dpads[GCInputDirectionPad] {
            wireDirectionPad(dpad, label: "D-pad", log: log)
        } else {
            DiagnosticsLog.log("ControllerObserver: no dpad found under key '\(GCInputDirectionPad)' - real dpad presses will never be seen")
        }
        // "add joystick (wobbly thing) support for eslecting things," per live feedback - both
        // thumbsticks are the exact same real type as the physical D-pad in Apple's own API
        // (`GCControllerDirectionPad`, confirmed via the framework's own type system, not an
        // assumption), so pushing a stick far enough crosses the same real per-element threshold
        // Apple already computes internally and fires the identical discrete up/down/left/right
        // event the D-pad does - `wireDirectionPad` is the exact same code either one runs
        // through, so every existing `directionPress` consumer picks up stick navigation for
        // free, with no separate deadzone/debounce logic needed.
        if let leftStick = profile.dpads[GCInputLeftThumbstick] {
            wireDirectionPad(leftStick, label: "left stick", log: log)
        }
        if let rightStick = profile.dpads[GCInputRightThumbstick] {
            wireDirectionPad(rightStick, label: "right stick", log: log)
        }
        profile.buttons[GCInputButtonA]?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("A")
            Task { @MainActor in self?.primaryPress = UUID() }
        }
        profile.buttons[GCInputButtonB]?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("B")
            Task { @MainActor in self?.secondaryPress = UUID() }
        }
    }

    /// Wires one `GCControllerDirectionPad`'s four sub-buttons to `directionPress` - pulled out of
    /// `attachGlobalHandlers` as a pure extraction (identical behavior, D-pad only, for now) so a
    /// later change can reuse it for the analog thumbsticks without duplicating this block.
    private func wireDirectionPad(_ dpad: GCControllerDirectionPad, label: String, log: @escaping (String) -> Void) {
        dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("\(label) up")
            Task { @MainActor in self?.directionPress = (.up, UUID()) }
        }
        dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("\(label) down")
            Task { @MainActor in self?.directionPress = (.down, UUID()) }
        }
        dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("\(label) left")
            Task { @MainActor in self?.directionPress = (.left, UUID()) }
        }
        dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            log("\(label) right")
            Task { @MainActor in self?.directionPress = (.right, UUID()) }
        }
    }
}
