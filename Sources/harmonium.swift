// harmonium — play your MacBook like a harmonium. The lid hinge is the bellows.
//
// Rocking the lid back and forth pumps air into a reservoir; held keys drain it.
// Volume and brightness follow the air pressure, so if you stop pumping the reeds
// fade out like the real thing.
//
// The lid angle comes from the SPU's "las" HID device (usage page 0x20, usage 0x8A).
// Feature report 1 is 3 bytes: [reportID, angleLo, angleHi], in whole degrees.

import AppKit
import AVFoundation
import IOKit
import IOKit.hid

// MARK: - Tuning

/// Air added per degree of lid travel.
let pumpPerDegree: Float = 0.006
/// Lid speeds below this (deg/s) are treated as sensor jitter.
let pumpDeadZone: Float = 4
/// Air lost per second even with nothing playing.
let baseLeak: Float = 0.10
/// Extra air lost per second for each sounding note.
let leakPerNote: Float = 0.06
/// Lid speed (deg/s) simulated while holding space, for testing without the hinge.
let spacePumpSpeed: Float = 110

// MARK: - Shared state (written by UI/sensor, read by audio; races are benign)

final class Shared {
    /// Per-MIDI-note gate, 0 or 1.
    let gate = UnsafeMutablePointer<Float>.allocate(capacity: 128)
    var air: Float = 0          // reservoir 0...1
    var pumpSpeed: Float = 0    // smoothed lid speed, deg/s
    var lidAngle: Int = -1      // -1 = no sensor
    init() { gate.initialize(repeating: 0, count: 128) }

    var soundingCount: Int {
        var n = 0
        for i in 0..<128 where gate[i] > 0 { n += 1 }
        return n
    }
}

let shared = Shared()

// MARK: - Lid sensor + bellows physics

final class Bellows {
    private var manager: IOHIDManager?  // must outlive the device, or the device closes
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private var history: [(t: Double, angle: Int)] = []
    private var lastTick = CFAbsoluteTimeGetCurrent()
    var manualPump = false

    func start() {
        openSensor()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "bellows", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func openSensor() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: 0x5AC, kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>,
              let d = devices.first,
              IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else {
            print("No lid angle sensor found. Hold space to pump instead.")
            return
        }
        manager = m
        device = d
    }

    private func readAngle() -> Int? {
        guard let d = device else { return nil }
        var buf = [UInt8](repeating: 0, count: 8)
        var len = CFIndex(buf.count)
        guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess,
              len >= 3 else { return nil }
        return Int(UInt16(buf[1]) | UInt16(buf[2]) << 8)
    }

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(min(now - lastTick, 0.05))
        lastTick = now

        // Lid speed over a ~100 ms window; the sensor only reports whole degrees.
        var speed: Float = 0
        if let a = readAngle() {
            shared.lidAngle = a
            history.append((now, a))
            history.removeAll { now - $0.t > 0.15 }
            if let old = history.first(where: { now - $0.t <= 0.1 }), now - old.t > 0.02 {
                speed = abs(Float(a - old.angle)) / Float(now - old.t)
            }
        }
        if manualPump { speed = max(speed, spacePumpSpeed) }
        shared.pumpSpeed += (speed - shared.pumpSpeed) * 0.15

        var air = shared.air
        if shared.pumpSpeed > pumpDeadZone { air += pumpPerDegree * shared.pumpSpeed * dt }
        air -= (baseLeak + leakPerNote * Float(shared.soundingCount)) * dt
        shared.air = min(1, max(0, air))
    }
}

// MARK: - Reed synth

final class ReedSynth {
    let engine = AVAudioEngine()
    private var sampleRate: Float = 48000
    private var env = [Float](repeating: 0, count: 128)
    private var ph1 = [Float](repeating: 0, count: 128)
    private var ph2 = [Float](repeating: 0, count: 128)
    private var ph3 = [Float](repeating: 0, count: 128)
    private var pressure: Float = 0
    private var lp1: Float = 0, lp2: Float = 0
    private var noiseSeed: UInt32 = 22222
    private var noiseLP: Float = 0

    func start() throws {
        let out = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = Float(out.sampleRate)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate, channels: 2)!
        let node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl in
            self.render(frames: Int(frames), abl: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 0.9
        try engine.start()
    }

    @inline(__always) private func polyBLEP(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    @inline(__always) private func saw(_ p: inout Float, _ inc: Float) -> Float {
        p += inc
        if p >= 1 { p -= 1 }
        return 2 * p - 1 - polyBLEP(p, inc)
    }

    private func render(frames: Int, abl: UnsafeMutableAudioBufferListPointer) {
        let sr = sampleRate
        let attack = 1 / (0.025 * sr), release = 1 / (0.09 * sr)
        let pSmooth: Float = 1 / (0.02 * sr)

        var active: [Int] = []
        for n in 0..<128 where shared.gate[n] > 0 || env[n] > 0.0001 { active.append(n) }

        let targetAir = shared.air
        let pumpNoise = min(shared.pumpSpeed / 300, 1)
        let left = abl[0].mData!.assumingMemoryBound(to: Float.self)
        let right = abl[1].mData!.assumingMemoryBound(to: Float.self)

        for i in 0..<frames {
            pressure += (targetAir - pressure) * pSmooth
            // Reeds need some pressure before they speak, then get louder and brighter.
            let speak = max(0, min(1, (pressure - 0.03) / 0.5))
            let loud = speak * speak * (3 - 2 * speak)

            var s: Float = 0
            for n in active {
                let target = shared.gate[n]
                env[n] += (target - env[n]) * (target > env[n] ? attack * 4 : release * 4)
                let f = 440 * powf(2, Float(n - 69) / 12)
                let inc = f / sr
                let a = saw(&ph1[n], inc)
                let b = saw(&ph2[n], inc * 1.0023)      // second reed, ~4 cents sharp: the harmonium "beat"
                let c = saw(&ph3[n], inc * 0.5)         // bass reed one octave down
                s += (a * 0.45 + b * 0.35 + c * 0.25) * env[n]
            }

            // Brightness follows pressure, like reeds driven harder.
            let cutoff = 700 + 3800 * loud
            let k = min(1, 2 * Float.pi * cutoff / sr)
            lp1 += (s - lp1) * k
            lp2 += (lp1 - lp2) * k
            var out = lp2 * loud * 0.22

            // A little air hiss while the bellows move.
            noiseSeed = noiseSeed &* 1664525 &+ 1013904223
            let white = Float(Int32(bitPattern: noiseSeed)) / Float(Int32.max)
            noiseLP += (white - noiseLP) * 0.08
            out += noiseLP * pumpNoise * 0.04

            out = tanhf(out * 1.4)
            left[i] = out
            right[i] = out
        }
    }
}

// MARK: - Keyboard mapping (sargam, piano-style layout on the home row)

struct KeyDef { let char: Character; let semitone: Int; let sargam: String; let black: Bool }

let keyDefs: [KeyDef] = [
    .init(char: "a", semitone: 0, sargam: "Sa", black: false),
    .init(char: "w", semitone: 1, sargam: "re", black: true),
    .init(char: "s", semitone: 2, sargam: "Re", black: false),
    .init(char: "e", semitone: 3, sargam: "ga", black: true),
    .init(char: "d", semitone: 4, sargam: "Ga", black: false),
    .init(char: "f", semitone: 5, sargam: "Ma", black: false),
    .init(char: "t", semitone: 6, sargam: "Ma'", black: true),
    .init(char: "g", semitone: 7, sargam: "Pa", black: false),
    .init(char: "y", semitone: 8, sargam: "dha", black: true),
    .init(char: "h", semitone: 9, sargam: "Dha", black: false),
    .init(char: "u", semitone: 10, sargam: "ni", black: true),
    .init(char: "j", semitone: 11, sargam: "Ni", black: false),
    .init(char: "k", semitone: 12, sargam: "Sa", black: false),
    .init(char: "o", semitone: 13, sargam: "re", black: true),
    .init(char: "l", semitone: 14, sargam: "Re", black: false),
    .init(char: "p", semitone: 15, sargam: "ga", black: true),
    .init(char: ";", semitone: 16, sargam: "Ga", black: false),
]

let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

// MARK: - UI

final class HarmoniumView: NSView {
    let bellows: Bellows
    var root = 60                    // MIDI note for Sa (C4)
    var held: [Character: Int] = [:] // key -> MIDI note it started
    var droneSa = false, dronePa = false
    private var displayAir: CGFloat = 0

    init(bellows: Bellows) {
        self.bellows = bellows
        super.init(frame: .zero)
        Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Gates

    private func refreshGates() {
        var g = [Float](repeating: 0, count: 128)
        for n in held.values where (0..<128).contains(n) { g[n] = 1 }
        if droneSa { g[root - 12] = 1 }
        if dronePa { g[root - 5] = 1 }
        for i in 0..<128 { shared.gate[i] = g[i] }
    }

    func releaseAll() {
        held.removeAll()
        bellows.manualPump = false
        refreshGates()
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        switch event.keyCode {
        case 123: root = max(48, root - 1); refreshGates(); return  // left
        case 124: root = min(72, root + 1); refreshGates(); return  // right
        case 49: bellows.manualPump = true; return                    // space
        default: break
        }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
        switch c {
        case "z": root = max(36, root - 12); refreshGates()
        case "x": root = min(84, root + 12); refreshGates()
        case "1": droneSa.toggle(); refreshGates()
        case "2": dronePa.toggle(); refreshGates()
        default:
            if let k = keyDefs.first(where: { $0.char == c }) {
                held[c] = root + k.semitone
                refreshGates()
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { bellows.manualPump = false; return }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
        if held.removeValue(forKey: c) != nil { refreshGates() }
    }

    // MARK: Drawing

    private let bg = NSColor(red: 0.11, green: 0.07, blue: 0.05, alpha: 1)
    private let wood = NSColor(red: 0.42, green: 0.22, blue: 0.10, alpha: 1)
    private let woodDark = NSColor(red: 0.28, green: 0.14, blue: 0.06, alpha: 1)
    private let brass = NSColor(red: 0.91, green: 0.72, blue: 0.36, alpha: 1)
    private let ivory = NSColor(red: 0.97, green: 0.94, blue: 0.86, alpha: 1)
    private let ebony = NSColor(red: 0.10, green: 0.08, blue: 0.07, alpha: 1)
    private let saffron = NSColor(red: 1.0, green: 0.55, blue: 0.15, alpha: 1)

    private func text(_ s: String, _ p: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, center: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let str = NSAttributedString(string: s, attributes: attrs)
        var pt = p
        if center { pt.x -= str.size().width / 2 }
        str.draw(at: pt)
    }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill(); bounds.fill()
        let w = bounds.width

        text("Lid Harmonium", NSPoint(x: 40, y: 28), size: 30, color: brass, weight: .bold)
        text("Rock the lid to pump the bellows. Play the home row.", NSPoint(x: 40, y: 68), size: 14, color: ivory.withAlphaComponent(0.7))

        drawBellows(in: NSRect(x: 40, y: 110, width: w - 80, height: 170))
        drawKeys(in: NSRect(x: 40, y: 310, width: w - 80, height: 190))

        let drones = [droneSa ? "Sa" : nil, dronePa ? "Pa" : nil].compactMap { $0 }
        let status = "Sa = \(noteNames[root % 12])\(root / 12 - 1)   ·   drones: \(drones.isEmpty ? "off" : drones.joined(separator: " + "))"
        text(status, NSPoint(x: 40, y: 520), size: 14, color: brass, weight: .medium)
        text("←/→ change key   Z/X octave   1 Sa drone   2 Pa drone   space = pump without lid",
             NSPoint(x: 40, y: 546), size: 12, color: ivory.withAlphaComponent(0.45))
    }

    private func drawBellows(in r: NSRect) {
        displayAir += (CGFloat(shared.air) - displayAir) * 0.25
        let air = displayAir

        // Back board (fixed) and front flap (moves out with air), with pleats between.
        let boardW: CGFloat = 18
        let maxSpan = r.width * 0.55
        let span = 30 + (maxSpan - 30) * air
        let backX = r.minX
        let frontX = backX + boardW + span

        wood.setFill()
        NSBezierPath(roundedRect: NSRect(x: backX, y: r.minY, width: boardW, height: r.height), xRadius: 4, yRadius: 4).fill()
        NSBezierPath(roundedRect: NSRect(x: frontX, y: r.minY, width: boardW, height: r.height), xRadius: 4, yRadius: 4).fill()

        let pleats = 9
        let pleatW = span / CGFloat(pleats)
        let inset: CGFloat = 14
        let cloth = NSBezierPath()
        cloth.move(to: NSPoint(x: backX + boardW, y: r.minY + 4))
        for i in 0...pleats {
            let x = backX + boardW + CGFloat(i) * pleatW
            let y = i % 2 == 0 ? r.minY + 4 : r.minY + inset
            cloth.line(to: NSPoint(x: x, y: y))
        }
        for i in stride(from: pleats, through: 0, by: -1) {
            let x = backX + boardW + CGFloat(i) * pleatW
            let y = i % 2 == 0 ? r.maxY - 4 : r.maxY - inset
            cloth.line(to: NSPoint(x: x, y: y))
        }
        cloth.close()
        NSColor(red: 0.55, green: 0.10, blue: 0.12, alpha: 1).setFill()
        cloth.fill()
        NSColor(red: 0.85, green: 0.65, blue: 0.30, alpha: 0.8).setStroke()
        for i in 0...pleats {
            let x = backX + boardW + CGFloat(i) * pleatW
            let fold = NSBezierPath()
            fold.move(to: NSPoint(x: x, y: i % 2 == 0 ? r.minY + 4 : r.minY + inset))
            fold.line(to: NSPoint(x: x, y: i % 2 == 0 ? r.maxY - 4 : r.maxY - inset))
            fold.lineWidth = 1.2
            fold.stroke()
        }

        // Readouts on the right.
        let rx = r.minX + maxSpan + 90
        let angle = shared.lidAngle >= 0 ? "\(shared.lidAngle)°" : "—"
        text("LID", NSPoint(x: rx, y: r.minY), size: 11, color: ivory.withAlphaComponent(0.5), weight: .semibold)
        text(angle, NSPoint(x: rx, y: r.minY + 14), size: 34, color: ivory, weight: .bold)
        text("PUMP", NSPoint(x: rx + 170, y: r.minY), size: 11, color: ivory.withAlphaComponent(0.5), weight: .semibold)
        text(String(format: "%.0f°/s", shared.pumpSpeed), NSPoint(x: rx + 170, y: r.minY + 14), size: 34, color: ivory, weight: .bold)

        text("AIR", NSPoint(x: rx, y: r.minY + 80), size: 11, color: ivory.withAlphaComponent(0.5), weight: .semibold)
        let meter = NSRect(x: rx, y: r.minY + 98, width: r.maxX - rx, height: 22)
        woodDark.setFill()
        NSBezierPath(roundedRect: meter, xRadius: 11, yRadius: 11).fill()
        let fill = NSRect(x: meter.minX, y: meter.minY, width: max(22, meter.width * air), height: meter.height)
        (air > 0.05 ? saffron : saffron.withAlphaComponent(0.3)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 11, yRadius: 11).fill()
        if air < 0.05 && !held.isEmpty {
            text("pump the lid!", NSPoint(x: rx, y: r.minY + 130), size: 13, color: saffron, weight: .semibold)
        }
    }

    private func drawKeys(in r: NSRect) {
        let whites = keyDefs.filter { !$0.black }
        let kw = r.width / CGFloat(whites.count)
        var whiteX: [Int: CGFloat] = [:]

        for (i, k) in whites.enumerated() {
            let x = r.minX + CGFloat(i) * kw
            whiteX[k.semitone] = x
            let down = held[k.char] != nil
            let rect = NSRect(x: x + 2, y: r.minY, width: kw - 4, height: r.height)
            (down ? saffron : ivory).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text(k.sargam, NSPoint(x: x + kw / 2, y: r.maxY - 52), size: 16, color: ebony, weight: .bold, center: true)
            text(String(k.char).uppercased(), NSPoint(x: x + kw / 2, y: r.maxY - 28), size: 12, color: ebony.withAlphaComponent(0.5), weight: .medium, center: true)
        }
        for k in keyDefs where k.black {
            guard let leftX = whiteX[k.semitone - 1] else { continue }
            let bw = kw * 0.62
            let x = leftX + kw - bw / 2
            let down = held[k.char] != nil
            let rect = NSRect(x: x, y: r.minY, width: bw, height: r.height * 0.58)
            (down ? saffron : ebony).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            text(k.sargam, NSPoint(x: x + bw / 2, y: r.minY + r.height * 0.58 - 44), size: 12, color: down ? ebony : ivory, weight: .semibold, center: true)
            text(String(k.char).uppercased(), NSPoint(x: x + bw / 2, y: r.minY + r.height * 0.58 - 24), size: 11, color: (down ? ebony : ivory).withAlphaComponent(0.5), center: true)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let bellows = Bellows()
    let synth = ReedSynth()
    var view: HarmoniumView!

    func applicationDidFinishLaunching(_ note: Notification) {
        bellows.start()
        do { try synth.start() } catch { print("Audio failed to start: \(error)") }

        view = HarmoniumView(bellows: bellows)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 590),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Lid Harmonium"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResignKey(_ notification: Notification) { view.releaseAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
