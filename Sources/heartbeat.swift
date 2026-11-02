// heartbeat — streams the MacBook's built-in accelerometer to a local web page.
//
// Apple Silicon MacBooks expose the IMU as a vendor HID device ("accel",
// usage page 0xFF00, usage 3) behind AppleSPUHIDDriver. Each input report is
// 22 bytes; X/Y/Z are little-endian Int32 at offsets 6/10/14 in units of 1/65536 g.
//
// Experimental ballistocardiography toy. Not a medical device.

import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import Network

// MARK: - Config

let port: UInt16 = {
    if let i = CommandLine.arguments.firstIndex(of: "--port"), i + 1 < CommandLine.arguments.count,
       let p = UInt16(CommandLine.arguments[i + 1]) { return p }
    return 8787
}()

let webRoot: URL = {
    if let i = CommandLine.arguments.firstIndex(of: "--web"), i + 1 < CommandLine.arguments.count {
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web")
}()

/// Sensor reports arrive at ~800 Hz; average blocks of this many to get ~200 Hz.
let decimation = 4

// MARK: - Streaming hub

final class Hub {
    private let queue = DispatchQueue(label: "hub")
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var pending: [[Double]] = []
    private var sensorStatus = "starting"

    func add(_ c: NWConnection) {
        queue.async {
            self.clients[ObjectIdentifier(c)] = c
            self.send("event: status\ndata: \"\(self.sensorStatus)\"\n\n", to: c)
        }
    }

    func remove(_ c: NWConnection) {
        queue.async { self.clients.removeValue(forKey: ObjectIdentifier(c)) }
    }

    func push(_ sample: [Double]) {
        queue.async { self.pending.append(sample) }
    }

    func setStatus(_ s: String) {
        queue.async {
            self.sensorStatus = s
            for c in self.clients.values { self.send("event: status\ndata: \"\(s)\"\n\n", to: c) }
        }
    }

    func flush() {
        queue.async {
            guard !self.pending.isEmpty else { return }
            let rows = self.pending.map { r in
                "[" + r.map { String(format: "%.7f", $0) }.joined(separator: ",") + "]"
            }
            self.pending.removeAll(keepingCapacity: true)
            let msg = "data: [" + rows.joined(separator: ",") + "]\n\n"
            for c in self.clients.values { self.send(msg, to: c) }
        }
    }

    private func send(_ s: String, to c: NWConnection) {
        c.send(content: s.data(using: .utf8), completion: .contentProcessed { [weak self] err in
            if err != nil { self?.remove(c); c.cancel() }
        })
    }
}

let hub = Hub()

// MARK: - Sensor

final class Accelerometer {
    private var manager: IOHIDManager?
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private let t0 = CFAbsoluteTimeGetCurrent()
    private var acc = (x: 0.0, y: 0.0, z: 0.0, n: 0)
    private var lastSeq: [Int: UInt16] = [:]

    func start() -> Bool {
        wakeSensors()

        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        guard IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>, !devices.isEmpty
        else { return false }
        manager = m

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for d in devices {
            guard IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { continue }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            buffers.append(buf)
            IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { ctx, _, sender, _, _, report, len in
                guard let ctx, len >= 18 else { return }
                let me = Unmanaged<Accelerometer>.fromOpaque(ctx).takeUnretainedValue()
                me.handle(report, sender: sender)
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        return !buffers.isEmpty
    }

    /// The sensor coprocessor keeps the IMU idle until a client asks for reports.
    private func wakeSensors() {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &it) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            IORegistryEntrySetCFProperty(s, "SensorPropertyReportingState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(s, "SensorPropertyPowerState" as CFString, 1 as CFNumber)
            IORegistryEntrySetCFProperty(s, "ReportInterval" as CFString, 1000 as CFNumber) // µs
            IOObjectRelease(s)
        }
    }

    private func handle(_ r: UnsafeMutablePointer<UInt8>, sender: UnsafeMutableRawPointer?) {
        // Two HID interfaces can deliver the same report; drop duplicates by sequence number.
        let seq = UInt16(r[0]) | UInt16(r[1]) << 8
        let key = Int(bitPattern: sender)
        for (k, s) in lastSeq where k != key && s == seq { return }
        lastSeq[key] = seq

        func i32(_ o: Int) -> Double {
            Double(Int32(bitPattern: UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24)) / 65536
        }
        acc.x += i32(6); acc.y += i32(10); acc.z += i32(14); acc.n += 1
        if acc.n == decimation {
            let n = Double(acc.n)
            hub.push([CFAbsoluteTimeGetCurrent() - t0, acc.x / n, acc.y / n, acc.z / n])
            acc = (0, 0, 0, 0)
        }
    }
}

// MARK: - HTTP

func serve(_ c: NWConnection) {
    c.start(queue: .global())
    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
        guard let data, let req = String(data: data, encoding: .utf8),
              let line = req.split(separator: "\r\n").first else { c.cancel(); return }
        let parts = line.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "/") : "/"

        // The hosted page (any origin) may read the stream from this machine.
        let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\n"
        if parts.first == "OPTIONS" {
            let head = "HTTP/1.1 204 No Content\r\n\(cors)Access-Control-Allow-Methods: GET\r\nAccess-Control-Allow-Headers: *\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            c.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
            return
        }

        if path == "/stream" {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\(cors)Connection: keep-alive\r\n\r\n"
            c.send(content: head.data(using: .utf8), completion: .contentProcessed { _ in hub.add(c) })
            return
        }

        let name = path == "/" ? "index.html" : String(path.dropFirst())
        let file = webRoot.appendingPathComponent(name).standardizedFileURL
        guard file.path.hasPrefix(webRoot.standardizedFileURL.path), let body = try? Data(contentsOf: file) else {
            c.send(content: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".data(using: .utf8),
                   completion: .contentProcessed { _ in c.cancel() })
            return
        }
        let type = [ "html": "text/html; charset=utf-8", "js": "text/javascript", "css": "text/css",
                     "svg": "image/svg+xml", "png": "image/png",
                     "jpg": "image/jpeg", "mp4": "video/mp4" ][file.pathExtension] ?? "application/octet-stream"
        var out = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

// MARK: - Main

let params = NWParameters.tcp
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
let listener = try NWListener(using: params)
listener.newConnectionHandler = serve
listener.start(queue: .global())

let sensor = Accelerometer()
if sensor.start() {
    hub.setStatus("live")
} else {
    hub.setStatus("no-sensor")
    FileHandle.standardError.write("No accelerometer found. This needs an Apple Silicon MacBook (M2 or newer).\n".data(using: .utf8)!)
}

Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in hub.flush() }

print("""

  ♥  heartbeat is running → http://localhost:\(port)

     Rest both wrists on the palm rest, stay still, breathe slowly.
     Experimental ballistocardiography — not a medical device.
     Ctrl-C to stop.

""")
if !CommandLine.arguments.contains("--no-open") {
    Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["http://localhost:\(port)"])
}
CFRunLoopRun()
