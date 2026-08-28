//
//  BLEManager.swift
//  WhoopKit
//
//  CoreBluetooth central for a WHOOP 5.0 / MG strap, for use in a real
//  iPhone app (this needs the CoreBluetooth "always/when in use" background
//  mode + Info.plist NSBluetoothAlwaysUsageDescription to run reliably).
//
//  Two hardware realities from NOOP's own field notes, both real BLE/iOS
//  constraints, not something code can route around:
//
//  1. The strap holds an encrypted bond with only ONE central at a time.
//     If it's still bonded to the official WHOOP app, this will get
//     "Encryption is insufficient" / bond refused. Put the strap in
//     pairing mode (repeated taps until LEDs flash blue) after fully
//     quitting / disconnecting the official app first.
//
//  2. CoreBluetooth has no explicit "bond now" API. Per Apple's own BLE
//     pairing model, a bond is triggered automatically the first time you
//     touch a characteristic that requires encryption -- so this manager
//     deliberately reads a protected characteristic right after service
//     discovery to kick off the system pairing dialog before it tries to
//     write commands. This matches Apple's documented CoreBluetooth
//     pairing model, not a workaround of it.
//

import Foundation
import CoreBluetooth

public struct WhoopBLEIdentifiers {
    public static let heartRateMeasurement = CBUUID(string: "2A37")
    public static let whoopService = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
    public static let commandChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    public static let dataChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
}

public protocol WhoopBLEManagerDelegate: AnyObject {
    func whoopManager(_ manager: WhoopBLEManager, didUpdateState state: WhoopBLEManager.ConnectionState)
    func whoopManager(_ manager: WhoopBLEManager, didReceiveHeartRate hr: HeartRateMeasurement)
    func whoopManager(_ manager: WhoopBLEManager, didDecode message: DecodedPuffin, fromChannel uuid: CBUUID)
    func whoopManager(_ manager: WhoopBLEManager, didFailWithError error: Error)
}

public final class WhoopBLEManager: NSObject {
    public enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting
        case discoveringServices
        case bonding
        case ready       // bonded, subscribed, command channel writable
        case liveHROnly   // connected but not bonded -- HR works, commands won't
        case disconnected(Error?)

        public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning), (.connecting, .connecting),
                 (.discoveringServices, .discoveringServices), (.bonding, .bonding),
                 (.ready, .ready), (.liveHROnly, .liveHROnly):
                return true
            case (.disconnected, .disconnected):
                return true
            default:
                return false
            }
        }
    }

    public weak var delegate: WhoopBLEManagerDelegate?
    public private(set) var state: ConnectionState = .idle {
        didSet { delegate?.whoopManager(self, didUpdateState: state) }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var reassemblers: [CBUUID: FrameReassembler] = [:]
    private var seqCounter: UInt8 = 0
    private var pendingScanNamed: Bool = true

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    public func startScan() {
        guard central.state == .poweredOn else {
            state = .disconnected(nil)
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: [WhoopBLEIdentifiers.whoopService], options: nil)
    }

    /// Fallback: some firmware revisions don't advertise the custom service
    /// UUID in the scan response, only the name. Scan for everything and
    /// filter by name if the service-filtered scan finds nothing in a few
    /// seconds.
    public func startScanByName() {
        guard central.state == .poweredOn else {
            state = .disconnected(nil)
            return
        }
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    public func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.stopScan()
        central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true])
    }

    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    /// Write a command frame to fd4b0002. Requires the bond to be
    /// established (see class doc) -- if it's not, the strap silently
    /// drops write-without-response and returns "Encryption is
    /// insufficient" for write-with-response, which is why NOOP always
    /// writes commands WITH response.
    @discardableResult
    public func sendCommand(cmd: UInt8, b3: UInt8, payload: Data = Data()) -> Bool {
        guard let char = commandCharacteristic, let p = peripheral else { return false }
        seqCounter = seqCounter &+ 1
        let frame = buildCommandFrame(msgType: puffinEnvelopeType, seq: seqCounter,
                                       cmd: cmd, b3: b3, payload: payload)
        p.writeValue(frame, for: char, type: .withResponse)
        return true
    }

    /// Sends one SET_FF_VALUE (cmd 0x78) feature-flag write, ~80ms is the
    /// spacing NOOP uses between the 15 flags in the enable sequence --
    /// call this in a loop from your own verified flag list, don't fire
    /// all 15 back-to-back.
    @discardableResult
    public func sendFeatureFlag(name: String, valueChar: Character) -> Bool {
        var body = Data(repeating: 0, count: 40)
        let nameBytes = Array(name.utf8.prefix(32))
        body.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        if let v = valueChar.asciiValue {
            body[32] = v
        }
        return sendCommand(cmd: Command.setFFValue, b3: 0x01, payload: body)
    }
}

// MARK: - CBCentralManagerDelegate

extension WhoopBLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && state == .idle {
            // caller decides when to kick off startScan()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        if name.lowercased().contains("whoop") {
            connect(to: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discoveringServices
        peripheral.discoverServices([WhoopBLEIdentifiers.whoopService])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                error: Error?) {
        state = .disconnected(error)
        if let e = error { delegate?.whoopManager(self, didFailWithError: e) }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                error: Error?) {
        state = .disconnected(error)
    }
}

// MARK: - CBPeripheralDelegate

extension WhoopBLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            delegate?.whoopManager(self, didFailWithError: error)
            return
        }
        // Also look for the standard HR service (0x180D), which many
        // firmware revisions expose alongside the custom WHOOP service.
        peripheral.discoverServices(nil)
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                            error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == WhoopBLEIdentifiers.heartRateMeasurement && c.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: c)
            }
            if c.uuid == WhoopBLEIdentifiers.commandChar {
                commandCharacteristic = c
                state = .bonding
                // Triggers the OS pairing dialog per Apple's documented
                // model: touching a protected characteristic initiates
                // the bond. See class-level doc comment.
                peripheral.readValue(for: c)
            }
            if WhoopBLEIdentifiers.dataChars.contains(c.uuid) && c.properties.contains(.notify) {
                reassemblers[c.uuid] = FrameReassembler()
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                            error: Error?) {
        if let error = error {
            // CBATTError.insufficientEncryption (15) here means the bond
            // didn't complete -- almost always because the strap is still
            // bonded to the official app. Surface it distinctly so the UI
            // can tell the person to unpair the official app / strap.
            delegate?.whoopManager(self, didFailWithError: error)
            if state == .bonding { state = .liveHROnly }
            return
        }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == WhoopBLEIdentifiers.heartRateMeasurement {
            if let hr = HeartRateMeasurement.decode(data) {
                delegate?.whoopManager(self, didReceiveHeartRate: hr)
            }
            return
        }

        if characteristic.uuid == WhoopBLEIdentifiers.commandChar {
            // Successful read of the protected characteristic = bond established.
            if state == .bonding { state = .ready }
            return
        }

        if let reassembler = reassemblers[characteristic.uuid] {
            for frame in reassembler.feed(data) {
                let decoded = decodePuffinPayload(frame.inner)
                delegate?.whoopManager(self, didDecode: decoded, fromChannel: characteristic.uuid)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                            error: Error?) {
        if let error = error {
            delegate?.whoopManager(self, didFailWithError: error)
        }
    }
}
