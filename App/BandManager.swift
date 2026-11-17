import Foundation
import CoreBluetooth
#if canImport(RecoveryCore)
import RecoveryCore
#endif

struct FoundBand: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// Holds the Bluetooth connection to the band and feeds every heart-rate notification to the store.
/// Uses the standard Heart Rate service, the "bluetooth-central" background mode and state
/// restoration, so iOS keeps delivering data while the app is in the background and relaunches
/// the app if it was removed from memory.
final class BandManager: NSObject, ObservableObject {
    static let shared = BandManager()

    private static let heartRateService = CBUUID(string: "180D")
    private static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let savedIdKey = "bandIdentifier"

    @Published var status = "Starting Bluetooth…"
    @Published var connected = false
    @Published var hasBand = UserDefaults.standard.string(forKey: "bandIdentifier") != nil
    @Published var bpm: Int?
    @Published var hrv: Int?
    @Published var battery: Int?
    @Published var deviceName: String?
    @Published var found: [FoundBand] = []
    @Published var minutesToday = 0
    @Published var lastBeat: Date?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var discovered: [UUID: CBPeripheral] = [:]
    private let store = MinuteStore.shared
    private var lastUiUpdate = Date.distantPast

    private override init() {
        super.init()
        minutesToday = store.minutesToday()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "recoverylab.central",
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    // MARK: - Choosing a band

    private func start() {
        if let p = peripheral {
            attach(p)
            return
        }
        if let text = UserDefaults.standard.string(forKey: BandManager.savedIdKey),
           let id = UUID(uuidString: text),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(p)
            return
        }
        scan()
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        found = []
        discovered = [:]
        status = "Looking for bands nearby…"
        // A band another app already connected doesn't advertise, so list those too.
        for p in central.retrieveConnectedPeripherals(withServices: [BandManager.heartRateService]) {
            remember(p, rssi: 0, advertisedName: nil)
        }
        central.scanForPeripherals(withServices: [BandManager.heartRateService], options: nil)
    }

    func choose(_ id: UUID) {
        guard let p = discovered[id] else { return }
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: BandManager.savedIdKey)
        hasBand = true
        attach(p)
    }

    func forget() {
        let old = peripheral
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: BandManager.savedIdKey)
        hasBand = false
        connected = false
        bpm = nil
        hrv = nil
        deviceName = nil
        if let old { central.cancelPeripheralConnection(old) }
        scan()
    }

    private func remember(_ p: CBPeripheral, rssi: Int, advertisedName: String?) {
        discovered[p.identifier] = p
        let entry = FoundBand(id: p.identifier, name: p.name ?? advertisedName ?? "Unnamed heart-rate device", rssi: rssi)
        if let index = found.firstIndex(where: { $0.id == entry.id }) {
            found[index] = entry
        } else {
            found.append(entry)
        }
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        let name = p.name ?? "your band"
        if let real = p.name {
            deviceName = real
            store.deviceName = real
        }
        if p.state == .connected {
            connected = true
            status = "Connected to \(name)."
            p.discoverServices([BandManager.heartRateService, BandManager.batteryService])
        } else {
            status = "Waiting for \(name) to come into range…"
            // A connect request never times out: iOS completes it whenever the band shows up.
            central.connect(p, options: nil)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restored.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            start()
        case .poweredOff:
            connected = false
            status = "Bluetooth is off. Turn it on to record."
        case .unauthorized:
            status = "Bluetooth permission is off. Allow it in Settings, under Recovery Lab."
        case .unsupported:
            status = "This device can't use Bluetooth LE."
        default:
            status = "Starting Bluetooth…"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        remember(peripheral, rssi: RSSI.intValue,
                 advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connected = true
        if let real = peripheral.name {
            deviceName = real
            store.deviceName = real
        }
        status = "Connected to \(peripheral.name ?? "band")."
        peripheral.discoverServices([BandManager.heartRateService, BandManager.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        status = "Couldn't connect. Trying again…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, peripheral === self.peripheral else { return }
            self.central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        store.flush()
        Uploader.shared.uploadIfDue()
        guard peripheral === self.peripheral else { return }
        connected = false
        bpm = nil
        status = "Band out of range. It reconnects by itself when it's close again."
        central.connect(peripheral, options: nil)
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == BandManager.heartRateService }) else {
            status = "Connected, but this band isn't sharing heart rate. Turn on HR Broadcast for it, then try again."
            return
        }
        for service in services {
            if service.uuid == BandManager.heartRateService {
                peripheral.discoverCharacteristics([BandManager.heartRateMeasurement], for: service)
            } else if service.uuid == BandManager.batteryService {
                peripheral.discoverCharacteristics([BandManager.batteryLevel], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BandManager.heartRateMeasurement {
                peripheral.setNotifyValue(true, for: characteristic)
                status = "Recording from \(peripheral.name ?? "band")."
            } else if characteristic.uuid == BandManager.batteryLevel {
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        if characteristic.uuid == BandManager.batteryLevel {
            if let level = data.first {
                battery = Int(level)
                store.battery = Int(level)
            }
            return
        }
        guard characteristic.uuid == BandManager.heartRateMeasurement,
              let sample = HeartRateParser.parse(data) else { return }
        let startedNewMinute = store.add(sample)
        let now = Date()
        if now.timeIntervalSince(lastUiUpdate) >= 1 {
            lastUiUpdate = now
            bpm = sample.bpm
            hrv = store.liveHrv
            minutesToday = store.minutesToday()
            lastBeat = now
        }
        if startedNewMinute { Uploader.shared.uploadIfDue() }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        peripheral.discoverServices([BandManager.heartRateService, BandManager.batteryService])
    }
}
