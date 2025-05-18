import CoreBluetooth
import Foundation
import OSLog
import SwiftUI

enum BLEState: CustomStringConvertible, Equatable {
    case idle
    case scanning
    case connecting
    case connected
    case disconnected

    var description: String {
        switch self {
        case .idle: return "Idle"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }
}

class BLEHandler: NSObject, ObservableObject, CBCentralManagerDelegate,
    CBPeripheralDelegate
{

    @Published var bleState: BLEState = .disconnected {
        didSet {
            if oldValue != bleState {
                Logger.logger?.log(
                    "BLE state changed from \(oldValue.description) to \(self.bleState.description)"
                )
            }
        }
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    var l2capChannel: CBL2CAPChannel?
    private let psm: CBL2CAPPSM = 150
    let mtu = 1251  // this is our MTU, so we use as chunk size for sending and receiving data

    var inputStream: InputStream?
    var outputStream: OutputStream?
    var canWriteToOutputStream = false

    private var restoredPeripheral: CBPeripheral?
    private var wasRestored = false

    private var manualDisconnect = false

    private let targetServiceUUID = CBUUID(
        string: "dcbc7255-1e9e-49a0-a360-b0430b6c6905"
    )
    private let keepAliveUUID = CBUUID(
        string: "371a55c8-f251-4ad2-90b3-c7c195b049be"
    )

    private let autoReconnectOptions: [String: Any] = [
        CBConnectPeripheralOptionEnableAutoReconnect: true,
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
    ]

    var expectedLength: Int?
    var imageBuffer = Data()

    var audioSendCompletionHandler: ((Bool) -> Void)?

    var bgID: UIBackgroundTaskIdentifier = .invalid

    var api = APIHandler()
    var imageProcessor = JPEGHandler()

    @Published var rawImage: UIImage?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey:
                    "com.glimpseApp.central"
            ]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bleState = .idle
            Logger.logger?.log("Bluetooth is powered on")

            if wasRestored {
                reconnectOnRestore()  // not sure if this will be used
            } else {
                reconnectToSavedPeripheral()
            }

        case .poweredOff:
            bleState = .disconnected
            self.peripheral = nil
            self.restoredPeripheral = nil
            wasRestored = false
            Logger.logger?.log("Bluetooth is powered off")

        default:
            bleState = .disconnected
            self.peripheral = nil
            self.restoredPeripheral = nil
            wasRestored = false
            Logger.logger?.log("Bluetooth unknown state")
        }
    }

    private func reconnectToSavedPeripheral() {

        guard
            let uuidString = UserDefaults.standard.string(
                forKey: "lastPeripheralUUID"
            ),
            let savedPeripheralUUID = UUID(uuidString: uuidString)
        else {
            Logger.logger?.log("No saved peripheral UUID found")
            bleState = .disconnected
            return
        }

        // If we are already connected to the saved peripheral, do nothing
        let connectedPeripheralsWithService =
            central.retrieveConnectedPeripherals(withServices: [
                targetServiceUUID
            ])
        if let alreadyConnectedSavedPeripheral =
            connectedPeripheralsWithService.first(where: {
                $0.identifier == savedPeripheralUUID
            })
        {
            Logger.logger?.log("Already connected to saved peripheral")

            // Assign the already connected peripheral as our peripheral (as a safe measure))
            if self.peripheral?.identifier
                != alreadyConnectedSavedPeripheral.identifier
            {
                self.peripheral = alreadyConnectedSavedPeripheral
                self.peripheral?.delegate = self
            }
            return
        }

        // Ensure we are trying to connect to a disconnected (but saved) peripheral
        guard
            let peripheralToConnect = central.retrievePeripherals(
                withIdentifiers: [savedPeripheralUUID]).first
        else {
            return
        }

        self.peripheral = peripheralToConnect
        peripheralToConnect.delegate = self

        Logger.logger?.log("Attempting to connect to saved peripheral")
        bleState = .connecting
        central.connect(peripheralToConnect, options: autoReconnectOptions)
    }

    // this is linked to the callback that I don't know when is called
    private func reconnectOnRestore() {
        Logger.logger?.log("Attempting to reconnect on restore")

        if let restoredP = self.restoredPeripheral {
            self.peripheral = self.restoredPeripheral
            if restoredP.state == .connected {
                Logger.logger?.log("Restored peripheral is already connected")
                bleState = .connected
                self.centralManager(central, didConnect: restoredP)
            } else if restoredP.state == .connecting {
                Logger.logger?.log("Restored peripheral is already connecting")
                bleState = .connecting
            } else {
                Logger.logger?.log("Restored peripheral is not connected")
                bleState = .connecting
                self.central.connect(restoredP, options: autoReconnectOptions)
            }
        } else {
            Logger.logger?.log("No restored peripheral found")
            bleState = .disconnected
            reconnectToSavedPeripheral()  // fallback to saved peripheral
        }
        wasRestored = false
        self.restoredPeripheral = nil
    }

    // Manual connection attempt, only possible if disconnected
    func manuallyConnect() {

        guard central.state == .poweredOn, bleState == .disconnected else {
            return
        }

        guard !central.isScanning else {
            Logger.logger?.log("Already scanning for peripherals")
            return
        }

        if let p = self.peripheral,
            p.state == .connected || p.state == .connecting
        {
            Logger.logger?.log("Already connected/connecting to peripheral")
            return
        }

        bleState = .scanning
        Logger.logger?.log("Scanning for peripherals")

        central.scanForPeripherals(
            withServices: [targetServiceUUID],
            options: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            if bleState == .scanning {
                self.central.stopScan()
                bleState = .disconnected
                Logger.logger?.log("Scanning timed out")
            }
        }
    }

    func manuallyDisconnect() {
        UserDefaults.standard.removeObject(forKey: "lastPeripheralUUID")
        UserDefaults.standard.synchronize()

        guard let p = self.peripheral else {
            Logger.logger?.log("No peripheral to disconnect from")
            bleState = .disconnected
            return
        }

        if p.state == .connected || p.state == .connecting
            || p.state == .disconnecting
        {
            manualDisconnect = true
            Logger.logger?.log(
                "Disconnecting from peripheral: \(p.name ?? "unknown")"
            )
            central.cancelPeripheralConnection(p)
        } else if p.state == .disconnected {
            Logger.logger?.log("Peripheral is already disconnected")
            bleState = .disconnected
        }
        // rest will be handled in .didDisconnectPeripheral
    }

    // ONLY called after .scanForPeripherals
    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Logger.logger?.log(
            "Discovered peripheral: \(peripheral.name ?? "unknown")"
        )

        central.stopScan()

        self.peripheral = peripheral
        peripheral.delegate = self

        Logger.logger?.log(
            "Connecting to peripheral: \(peripheral.name ?? "unknown")"
        )
        bleState = .connecting
        central.connect(peripheral, options: autoReconnectOptions)
    }

    // open l2cap when connected
    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {

        // we enter the connected state after the L2CAP streams are fully opened (.openCompleted), not here

        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: "lastPeripheralUUID"
        )
        peripheral.discoverServices([targetServiceUUID])
        peripheral.openL2CAPChannel(psm)  // calls .didOpen
        Logger.logger?.log(
            "Connected to peripheral: \(peripheral.name ?? "unknown")"
        )
    }

    // open streams on L2CAP channel connection
    func peripheral(
        _ peripheral: CBPeripheral,
        didOpen channel: CBL2CAPChannel?,
        error: Error?
    ) {
        l2capChannel = channel
        setupStreams(for: channel!)
        Logger.logger?.log("Setting up L2CAP streams")
    }

    // called after .didConnect
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {

        if let error = error {
            Logger.logger?.error(
                "Error discovering services: \(error.localizedDescription)"
            )
            return
        }

        guard let services = peripheral.services else {
            Logger.logger?.log("No services found on peripheral.")
            return
        }

        Logger.logger?.log("Discovered services: \(services.map { $0.uuid })")

        for service in services {
            if service.uuid == targetServiceUUID {
                Logger.logger?.log(
                    "Found target service: \(service.uuid), discovering characteristics"
                )
                peripheral.discoverCharacteristics(
                    [keepAliveUUID],
                    for: service
                )
                return
            }
        }
        Logger.logger?.log(
            "Target service (\(self.targetServiceUUID.uuidString)) not found among discovered services"
        )
    }

    // called after .discoverCharacteristics
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {

        if let error = error {
            Logger.logger?.error(
                "Error discovering characteristics for service \(service.uuid): \(error.localizedDescription)"
            )
            return
        }

        guard let characteristics = service.characteristics else {
            Logger.logger?.log(
                "No characteristics found for service \(service.uuid)."
            )
            return
        }

        Logger.logger?.log(
            "Discovered characteristics for service \(service.uuid): \(characteristics.map { $0.uuid })"
        )

        for characteristic in characteristics {
            Logger.logger?.log(
                "Checking characteristic: \(characteristic.uuid)"
            )
            if characteristic.uuid == keepAliveUUID {
                Logger.logger?.log(
                    "Found keepAlive characteristic: \(characteristic.uuid)"
                )
                if characteristic.properties.contains(.notify) {
                    Logger.logger?.log(
                        "Characteristic supports notify, subscribing"
                    )
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            Logger.logger?.error(
                "Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)"
            )
            return
        }

        if characteristic.isNotifying {
            Logger.logger?.log(
                "Successfully subscribed to notifications for characteristic: \(characteristic.uuid)"
            )
        } else {
            Logger.logger?.log(
                "Successfully unsubscribed from notifications for characteristic: \(characteristic.uuid) (or subscription failed)"
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            Logger.logger?.error(
                "Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)"
            )
            return
        }
    }

    // not even sure when this is called or if its needed, but theoretically it should work
    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        Logger.logger?.log("Restoring state (willRestoreState)")
        wasRestored = true

        if let restoredPeripherals = dict[
            CBCentralManagerRestoredStatePeripheralsKey
        ] as? [CBPeripheral],
            let uuidString = UserDefaults.standard.string(
                forKey: "lastPeripheralUUID"
            ),
            let savedPeripheralUUID = UUID(uuidString: uuidString)
        {

            if let restoredP = restoredPeripherals.first(where: {
                $0.identifier == savedPeripheralUUID
            }) {
                Logger.logger?.log(
                    "Found our saved peripheral in restored list: \(restoredP.name ?? uuidString)"
                )
                restoredP.delegate = self
                self.restoredPeripheral = restoredP
                // we then thereotically go to .didUpdateState
            } else {
                Logger.logger?.log(
                    "Saved peripheral (UUID: \(uuidString)) not found among restored peripherals"
                )
            }
        } else {
            Logger.logger?.log(
                "No peripherals to restore from dictionary, or no saved UUID to match"
            )
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        if isReconnecting && !manualDisconnect {
            bleState = .connecting
            Logger.logger?.log(
                "Reconnecting to disconnected peripheral: \(peripheral.name ?? "unknown")"
            )
        } else {
            Logger.logger?.log(
                "Disconnected from peripheral: \(peripheral.name ?? "unknown")"
            )
            manualDisconnect = false
            bleState = .disconnected
            cleanupStreams()
            self.peripheral = nil
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Logger.logger?.error(
            "Failed to connect to peripheral: \(peripheral.name ?? "unknown"), error: \(error?.localizedDescription ?? "Unknown error")"
        )
        bleState = .disconnected
        cleanupStreams()
        self.peripheral = nil
    }
}
