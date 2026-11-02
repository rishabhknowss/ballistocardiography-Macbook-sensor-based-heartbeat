// sax — blow into your MacBook and it plays like a saxophone.
//
// Blowing on a microphone mostly produces low-frequency wind rumble, which the
// laptop's small speakers can barely reproduce. So breath is measured as energy
// below ~120 Hz: it hears you, but not the synth coming out of the speakers.
// Breath drives volume, brightness and growl; the keyboard is the fingering.

import AppKit
import AVFoundation

// MARK: - Tuning

/// Wind-band cutoff for breath detection (Hz).
let breathBandHz: Float = 120
/// How far above the room noise floor (dB) breath starts to count.
let breathThresholdDb: Float = 8
/// dB above the threshold that counts as full breath. Lower = more sensitive.
var breathRangeDb: Float = 26

// MARK: - Shared state (written by UI/mic, read by audio; races are benign)

final class Shared {
    var breath: Float = 0       // 0...1
    var micDb: Float = -100
    var floorDb: Float = -60
    var note: Int = -1          // MIDI note currently fingered, -1 = none
    var spaceBreath = false
    var micStatus = "starting mic…"
}

let shared = Shared()

// MARK: - Breath detector

final class BreathDetector {
    private var lp1: Float = 0, lp2: Float = 0
    private var power: Float = 0
    private var calibrating = 60    // callbacks spent learning the noise floor
    private var calSum: Float = 0, calN: Float = 0

    func process(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) {
        let k = min(1, 2 * Float.pi * breathBandHz / sampleRate)
        var sum: Float = 0
        for i in 0..<count {
            lp1 += (samples[i] - lp1) * k
            lp2 += (lp1 - lp2) * k
            sum += lp2 * lp2
        }
        let p = sum / Float(max(count, 1))
        power += (p - power) * (p > power ? 0.6 : 0.12)   // fast attack, slower release
        let db = 10 * log10f(power + 1e-12)
        shared.micDb = db

        if calibrating > 0 {
            calibrating -= 1
            calSum += db; calN += 1
            shared.floorDb = calSum / calN
            shared.breath = 0
            return
        }

        // Follow the room floor: down quickly, up very slowly so long notes don't raise it.
        if db < shared.floorDb { shared.floorDb += (db - shared.floorDb) * 0.05 }
        else if db < shared.floorDb + breathThresholdDb { shared.floorDb += 0.002 }

        let b = (db - shared.floorDb - breathThresholdDb) / breathRangeDb
        shared.breath = max(0, min(1, b))
    }
}

// MARK: - Sax synth (monophonic, subtractive with formants)

final class SaxSynth {
    let engine = AVAudioEngine()
    let detector = BreathDetector()
    private var sr: Float = 48000

    private var freq: Float = 261.6
    private var phase: Float = 0
    private var amp: Float = 0
    private var bright: Float = 0
    private var noteAge: Float = 0
    private var lastNote = -1
    private var vibPhase: Float = 0
    private var lp1: Float = 0, lp2: Float = 0
    private var f1 = SVF(), f2 = SVF(), fn = SVF()
    private var seed: UInt32 = 12345

    struct SVF {
        var low: Float = 0, band: Float = 0
        mutating func run(_ x: Float, f: Float, q: Float) -> Float {
            low += f * band
            let high = x - low - q * band
            band += f * high
            return band
        }
    }

    func start() throws {
        let out = engine.outputNode.outputFormat(forBus: 0)
        sr = Float(out.sampleRate)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: out.sampleRate, channels: 2)!
        let src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl in
            self.render(frames: Int(frames), abl: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: fmt)

        let input = engine.inputNode
        let inFmt = input.inputFormat(forBus: 0)
        if inFmt.channelCount > 0 && inFmt.sampleRate > 0 {
            let inRate = Float(inFmt.sampleRate)
            let sink = AVAudioSinkNode { [unowned self] _, frames, abl in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
                if let data = list.first?.mData {
                    self.detector.process(data.assumingMemoryBound(to: Float.self), count: Int(frames), sampleRate: inRate)
                }
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: sink, format: nil)
            shared.micStatus = "listening"
        } else {
            shared.micStatus = "no microphone input"
        }
        try engine.start()
    }

    @inline(__always) private func polyBLEP(_ t: Float, _ dt: Float) -> Float {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    @inline(__always) private func noise() -> Float {
        seed = seed &* 1664525 &+ 1013904223
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }

    private func render(frames: Int, abl: UnsafeMutableAudioBufferListPointer) {
        let left = abl[0].mData!.assumingMemoryBound(to: Float.self)
        let right = abl[1].mData!.assumingMemoryBound(to: Float.self)
        let breathIn = shared.spaceBreath ? max(shared.breath, 0.7) : shared.breath
        let note = shared.note
        if note != lastNote {
            if note >= 0 && lastNote < 0 { freq = 440 * powf(2, Float(note - 69) / 12) }  // no glide from silence
            noteAge = 0
            lastNote = note
        }
        let target = note >= 0 ? 440 * powf(2, Float(note - 69) / 12) : freq
        let glide = 1 / (0.025 * sr)
        let ampRate = 1 / (0.012 * sr)
        let dtSec = 1 / sr

        for i in 0..<frames {
            freq += (target - freq) * glide
            noteAge += dtSec

            // Breath shapes everything. With no key held you only hear air.
            let want = note >= 0 ? powf(breathIn, 1.3) : 0
            amp += (want - amp) * ampRate
            bright += (breathIn - bright) * ampRate

            // Delayed vibrato, like a player settling into a long note.
            let vibDepth = min(1, max(0, (noteAge - 0.35) / 0.6)) * 0.006
            vibPhase += 5.3 * dtSec
            if vibPhase >= 1 { vibPhase -= 1 }
            let f = freq * (1 + vibDepth * sinf(2 * .pi * vibPhase))

            let inc = f / sr
            phase += inc
            if phase >= 1 { phase -= 1 }
            var s = 2 * phase - 1 - polyBLEP(phase, inc)

            // Reed brightness: harder breath opens the filter and adds edge.
            let cutoff = min(9000, f * (2 + 14 * bright))
            let k = min(1, 2 * Float.pi * cutoff / sr)
            lp1 += (s - lp1) * k
            lp2 += (lp1 - lp2) * k
            s = lp2

            // Body formants give the hollow "honk".
            let a = f1.run(s, f: 2 * sinf(.pi * 600 / sr), q: 0.35)
            let b = f2.run(s, f: 2 * sinf(.pi * 1700 / sr), q: 0.45)
            var voice = s * 0.6 + a * 0.55 + b * 0.35

            // Growl at high breath: drive into saturation.
            let drive = 1 + 3 * bright * bright
            voice = tanhf(voice * drive) / drive * (1 + bright)

            // Breath noise through the mouthpiece.
            let air = fn.run(noise(), f: 2 * sinf(.pi * 2600 / sr), q: 0.9)
            let hiss = air * breathIn * (note >= 0 ? 0.05 : 0.08)

            let out = tanhf((voice * amp * 0.55 + hiss) * 1.2)
            left[i] = out
            right[i] = out
        }
    }
}

// MARK: - Fingering (piano-style home row; Shift is the octave key)

struct KeyDef { let char: Character; let semitone: Int; let black: Bool }

let keyDefs: [KeyDef] = [
    .init(char: "a", semitone: 0, black: false), .init(char: "w", semitone: 1, black: true),
    .init(char: "s", semitone: 2, black: false), .init(char: "e", semitone: 3, black: true),
    .init(char: "d", semitone: 4, black: false), .init(char: "f", semitone: 5, black: false),
    .init(char: "t", semitone: 6, black: true), .init(char: "g", semitone: 7, black: false),
    .init(char: "y", semitone: 8, black: true), .init(char: "h", semitone: 9, black: false),
    .init(char: "u", semitone: 10, black: true), .init(char: "j", semitone: 11, black: false),
    .init(char: "k", semitone: 12, black: false), .init(char: "o", semitone: 13, black: true),
    .init(char: "l", semitone: 14, black: false), .init(char: "p", semitone: 15, black: true),
    .init(char: ";", semitone: 16, black: false),
]

let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

// MARK: - UI

final class SaxView: NSView {
    var root = 60                       // MIDI note for the A key
    var held: [Character] = []          // most recent last (last-note priority)
    var octaveKey = false
    private var shownBreath: CGFloat = 0
    private var trail: [CGFloat] = Array(repeating: 0, count: 180)

    override init(frame: NSRect) {
        super.init(frame: frame)
        Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.trail.removeFirst()
            self.trail.append(CGFloat(shared.spaceBreath ? max(shared.breath, 0.7) : shared.breath))
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func refreshNote() {
        guard let c = held.last, let k = keyDefs.first(where: { $0.char == c }) else { shared.note = -1; return }
        shared.note = root + k.semitone + (octaveKey ? 12 : 0)
    }

    func releaseAll() {
        held.removeAll(); octaveKey = false; shared.spaceBreath = false
        refreshNote()
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        switch event.keyCode {
        case 123: root = max(36, root - 1); refreshNote(); return   // left
        case 124: root = min(84, root + 1); refreshNote(); return   // right
        case 49: shared.spaceBreath = true; return                   // space
        default: break
        }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
        switch c {
        case "z": root = max(36, root - 12)
        case "x": root = min(84, root + 12)
        case "-": breathRangeDb = min(45, breathRangeDb + 3)
        case "=": breathRangeDb = max(8, breathRangeDb - 3)
        default:
            guard keyDefs.contains(where: { $0.char == c }) else { return }
            held.removeAll { $0 == c }
            held.append(c)
        }
        refreshNote()
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { shared.spaceBreath = false; return }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
        held.removeAll { $0 == c }
        refreshNote()
    }

    override func flagsChanged(with event: NSEvent) {
        octaveKey = event.modifierFlags.contains(.shift)
        refreshNote()
    }

    // MARK: Drawing

    private let bg = NSColor(red: 0.07, green: 0.06, blue: 0.08, alpha: 1)
    private let brass = NSColor(red: 0.95, green: 0.74, blue: 0.30, alpha: 1)
    private let brassDim = NSColor(red: 0.95, green: 0.74, blue: 0.30, alpha: 0.18)
    private let cream = NSColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1)
    private let ink = NSColor(red: 0.12, green: 0.10, blue: 0.10, alpha: 1)

    private func text(_ s: String, _ p: NSPoint, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, center: Bool = false, mono: Bool = false) {
        let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        var pt = p
        if center { pt.x -= str.size().width / 2 }
        str.draw(at: pt)
    }

    override func draw(_ dirtyRect: NSRect) {
        bg.setFill(); bounds.fill()
        let w = bounds.width

        text("Blow Sax", NSPoint(x: 40, y: 28), size: 30, color: brass, weight: .bold)
        text("Hold a key and blow at your MacBook's mic. Blow harder for a louder, rougher sound.",
             NSPoint(x: 40, y: 68), size: 14, color: cream.withAlphaComponent(0.7))

        drawBreath(in: NSRect(x: 40, y: 110, width: w - 80, height: 170))
        drawKeys(in: NSRect(x: 40, y: 310, width: w - 80, height: 190))

        let status = "A key = \(noteNames[root % 12])\(root / 12 - 1)   ·   octave key \(octaveKey ? "ON" : "off")   ·   mic: \(shared.micStatus)"
        text(status, NSPoint(x: 40, y: 520), size: 14, color: brass, weight: .medium)
        text("Shift = octave key   ←/→ transpose   Z/X octave   −/= sensitivity   space = breathe without blowing",
             NSPoint(x: 40, y: 546), size: 12, color: cream.withAlphaComponent(0.45))
    }

    private func drawBreath(in r: NSRect) {
        let breath = CGFloat(shared.spaceBreath ? max(shared.breath, 0.7) : shared.breath)
        shownBreath += (breath - shownBreath) * 0.35

        // Breath history as a filled wave.
        let graph = NSRect(x: r.minX, y: r.minY, width: r.width * 0.58, height: r.height)
        brassDim.setFill()
        NSBezierPath(roundedRect: graph, xRadius: 10, yRadius: 10).fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: graph.minX, y: graph.maxY))
        for (i, v) in trail.enumerated() {
            let x = graph.minX + graph.width * CGFloat(i) / CGFloat(trail.count - 1)
            path.line(to: NSPoint(x: x, y: graph.maxY - 8 - (graph.height - 16) * v))
        }
        path.line(to: NSPoint(x: graph.maxX, y: graph.maxY))
        path.close()
        brass.withAlphaComponent(0.85).setFill()
        path.fill()
        text("BREATH", NSPoint(x: graph.minX + 12, y: graph.minY + 10), size: 11, color: cream.withAlphaComponent(0.6), weight: .semibold)

        // Current note, big.
        let rx = graph.maxX + 40
        text("NOTE", NSPoint(x: rx, y: r.minY), size: 11, color: cream.withAlphaComponent(0.5), weight: .semibold)
        let n = shared.note
        let name = n >= 0 ? "\(noteNames[n % 12])\(n / 12 - 1)" : "—"
        let sounding = n >= 0 && shownBreath > 0.03
        text(name, NSPoint(x: rx, y: r.minY + 12), size: 64, color: sounding ? brass : cream.withAlphaComponent(0.5), weight: .heavy)

        text("MIC", NSPoint(x: rx, y: r.minY + 108), size: 11, color: cream.withAlphaComponent(0.5), weight: .semibold)
        text(String(format: "%.0f dB  (room %.0f dB)", shared.micDb, shared.floorDb),
             NSPoint(x: rx, y: r.minY + 124), size: 14, color: cream.withAlphaComponent(0.75), mono: true)
        if n >= 0 && shownBreath < 0.03 {
            text("now blow!", NSPoint(x: rx, y: r.minY + 146), size: 13, color: brass, weight: .semibold)
        }
    }

    private func drawKeys(in r: NSRect) {
        let whites = keyDefs.filter { !$0.black }
        let kw = r.width / CGFloat(whites.count)
        var whiteX: [Int: CGFloat] = [:]
        let current = held.last

        func label(_ k: KeyDef) -> String {
            let n = root + k.semitone + (octaveKey ? 12 : 0)
            return noteNames[n % 12]
        }

        for (i, k) in whites.enumerated() {
            let x = r.minX + CGFloat(i) * kw
            whiteX[k.semitone] = x
            let rect = NSRect(x: x + 2, y: r.minY, width: kw - 4, height: r.height)
            (k.char == current ? brass : cream).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text(label(k), NSPoint(x: x + kw / 2, y: r.maxY - 52), size: 16, color: ink, weight: .bold, center: true)
            text(String(k.char).uppercased(), NSPoint(x: x + kw / 2, y: r.maxY - 28), size: 12, color: ink.withAlphaComponent(0.5), weight: .medium, center: true)
        }
        for k in keyDefs where k.black {
            guard let leftX = whiteX[k.semitone - 1] else { continue }
            let bw = kw * 0.62
            let x = leftX + kw - bw / 2
            let on = k.char == current
            let rect = NSRect(x: x, y: r.minY, width: bw, height: r.height * 0.58)
            (on ? brass : ink).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            text(label(k), NSPoint(x: x + bw / 2, y: r.minY + r.height * 0.58 - 44), size: 12, color: on ? ink : cream, weight: .semibold, center: true)
            text(String(k.char).uppercased(), NSPoint(x: x + bw / 2, y: r.minY + r.height * 0.58 - 24), size: 11, color: (on ? ink : cream).withAlphaComponent(0.5), center: true)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let synth = SaxSynth()
    var view: SaxView!

    func applicationDidFinishLaunching(_ note: Notification) {
        view = SaxView(frame: .zero)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 590),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Blow Sax"
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if !granted { shared.micStatus = "mic access denied (System Settings → Privacy → Microphone)" }
                do { try self.synth.start() } catch {
                    shared.micStatus = "audio failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) { view.releaseAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
