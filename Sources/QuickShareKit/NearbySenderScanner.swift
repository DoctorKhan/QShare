import CoreBluetooth
import Foundation

/// Listens for the Bluetooth LE beacon Android phones broadcast while their Quick Share
/// sheet is open. Purely an optimisation: without Bluetooth permission the receiver still
/// works, it just can't react the moment a phone starts looking.
final class NearbySenderScanner: NSObject, CBCentralManagerDelegate {
    private static let serviceUUID = CBUUID(string: "FE2C")
    private static let beaconPrefix: [UInt8] = [0xFC, 0x12, 0x8E]

    private let queue = DispatchQueue(label: "qshare.bluetooth")
    private let onSenderNearby: () -> Void
    private var central: CBCentralManager?
    private var lastReport = Date.distantPast

    init(onSenderNearby: @escaping () -> Void) {
        self.onSenderNearby = onSenderNearby
    }

    func start() {
        queue.async {
            guard self.central == nil else { return }
            self.central = CBCentralManager(
                delegate: self, queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        queue.async {
            if self.central?.state == .poweredOn { self.central?.stopScan() }
            self.central?.delegate = nil
            self.central = nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let data = serviceData[Self.serviceUUID],
              data.starts(with: Self.beaconPrefix)
        else { return }
        guard Date().timeIntervalSince(lastReport) > 3 else { return }
        lastReport = Date()
        onSenderNearby()
    }
}
