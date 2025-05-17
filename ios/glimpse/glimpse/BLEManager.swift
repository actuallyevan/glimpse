import Foundation
import CoreBluetooth
import SwiftUI
import OSLog

private var logEnabled = true

extension Logger {
    
    private static let _logger: Logger = .init(subsystem: Bundle.main.bundleIdentifier!, category: "glimpse")
    static var logger: Logger? {
        guard logEnabled else { return nil }
        return _logger
    }
}

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
    

class BLEManager : NSObject, ObservableObject, CBCentralManagerDelegate {
    
    @Published var bleState: BLEState = .disconnected {
        didSet {
            if oldValue != bleState {
                Logger.logger?.log("BLE state changed from \(oldValue.description) to: \(self.bleState.description)")
                self.bleStatusString = self.bleState.description
            }
        }
    }
    
    @Published var bleStatusString: String = BLEState.disconnected.description
    
    // @Published public var BLEstate = "disconnected"
    @Published public var receivedMessage = ""
    
    @Published public var receivedImage: UIImage?
    
    private var api = APIHandler()
    
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var l2capChannel: CBL2CAPChannel?
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var canWrite = false
    
    private let targetServiceUUID = CBUUID(string: "dcbc7255-1e9e-49a0-a360-b0430b6c6905")
    private let psm: CBL2CAPPSM = 150
    
    private let keepAliveUUID = CBUUID(string: "371a55c8-f251-4ad2-90b3-c7c195b049be")
    
    private let autoReconnectOptions: [String: Any] = [
        CBConnectPeripheralOptionEnableAutoReconnect: true,
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
    ]
    
    var expectedLength: Int?
    var buffer = Data()
    
    private var dataToSend: Data?
    private var sendOffset: Int = 0
    
    var bgID: UIBackgroundTaskIdentifier = .invalid
    
    private var audioSendCompletionHandler: ((Bool) -> Void)?
    
    private var restoredPeripheral: CBPeripheral?
    private var wasRestored = false
    
    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.glimpseApp.central", CBConnectPeripheralOptionNotifyOnConnectionKey: true]
        )
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            self.bleState = .idle
            Logger.logger?.log("Bluetooth is powered on")
            
            if wasRestored {
                reconnectOnRestore()    // not sure if this will be used
            } else {
                reconnectToSavedPeripheral()
            }
            
        case .poweredOff:
            self.bleState = .disconnected
            self.peripheral = nil
            self.restoredPeripheral = nil
            wasRestored = false
            Logger.logger?.log("Bluetooth is powered off")
        default:
            self.bleState = .disconnected
            self.peripheral = nil
            self.restoredPeripheral = nil
            wasRestored = false
            Logger.logger?.log("Bluetooth unknown state")
        }
    }
    
    private func reconnectToSavedPeripheral() {
        
        guard let uuidString = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
              let savedPeripheralUUID = UUID(uuidString: uuidString) else {
            Logger.logger?.log("No saved peripheral UUID found")
            return
        }
        
        // If we are already connected to the saved peripheral, do nothing
        let connectedPeripheralsWithService = central.retrieveConnectedPeripherals(withServices: [targetServiceUUID])
        if let alreadyConnectedSavedPeripheral = connectedPeripheralsWithService.first(where: { $0.identifier == savedPeripheralUUID }) {
            Logger.logger?.log("Already connected to saved peripheral")
            
            // Assign the already connected peripheral as our peripheral (as a safe measure))
            if self.peripheral?.identifier != alreadyConnectedSavedPeripheral.identifier {
                self.peripheral = alreadyConnectedSavedPeripheral
                self.peripheral?.delegate = self
            }
            return
        }
        
        // Ensure we are trying to connect to a disconnected (but saved) peripheral
        guard let peripheralToConnect = central.retrievePeripherals(withIdentifiers: [savedPeripheralUUID]).first else {
            return
        }
        
        self.peripheral = peripheralToConnect
        peripheralToConnect.delegate = self
        
        Logger.logger?.log("Attempting to connect to saved peripheral")
        central.connect(peripheralToConnect, options: autoReconnectOptions)
    }
    
    // this is linked to the callback that I don't know when is called
    private func reconnectOnRestore() {
        Logger.logger?.log("Attempting to reconnect on restore")
        
        if let restoredP = self.restoredPeripheral {
            self.peripheral = self.restoredPeripheral
            if restoredP.state == .connected  {
                Logger.logger?.log("Restored peripheral is already connected")
                self.bleState = .connected
                self.centralManager(central, didConnect: restoredP)
            } else if restoredP.state == .connecting {
                Logger.logger?.log("Restored peripheral is already connecting")
                self.bleState = .connecting
            } else {
                Logger.logger?.log("Restored peripheral is not connected")
                self.bleState = .connecting
                self.central.connect(restoredP, options: autoReconnectOptions)
            }
        } else {
            Logger.logger?.log("No restored peripheral found")
            self.bleState = .disconnected
            reconnectToSavedPeripheral() // fallback to saved peripheral
        }
        self.wasRestored = false
        self.restoredPeripheral = nil
    }
    
    // Manual connection attempt, only possible if disconnected
    func manuallyConnect() {
        
        guard central.state == .poweredOn, self.bleState == .disconnected else { return }
        
        guard !central.isScanning else {
            Logger.logger?.log("Already scanning for peripherals")
            return
        }
        
        if let p = self.peripheral, (p.state == .connected || p.state == .connecting) {
            Logger.logger?.log("Already connected/connecting to peripheral")
            return
        }
        
        self.bleState = .scanning
        Logger.logger?.log("Scanning for peripherals")
            
        central.scanForPeripherals(withServices: [targetServiceUUID], options: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            self.bleState = .disconnected
            Logger.logger?.log("Scanning timed out")
        }
    }
    
    // ONLY called after .scanForPeripherals
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Logger.logger?.log("Discovered peripheral: \(peripheral.name ?? "unknown")")
        
        central.stopScan()
        
        self.peripheral = peripheral
        peripheral.delegate = self
        
        Logger.logger?.log("Connecting to peripheral: \(peripheral.name ?? "unknown")")
        self.bleState = .connecting
        central.connect(peripheral, options: autoReconnectOptions)
    }
    
    // open l2cap when connected
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        
        // we update state after open the L2CAP streams, not here
        
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")
        peripheral.discoverServices([targetServiceUUID])
        peripheral.openL2CAPChannel(psm)
        Logger.logger?.log("Connected to peripheral: \(peripheral.name ?? "unknown")")
    }
    
    // called after .didConnect
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        
        if let error = error {
            Logger.logger?.error("Error discovering services: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else {
            Logger.logger?.log("No services found on peripheral.")
            return
        }

        Logger.logger?.log("Discovered services: \(services.map { $0.uuid })")

        for service in services {
            if service.uuid == targetServiceUUID {
                Logger.logger?.log("Found target service: \(service.uuid), discovering characteristics")
                peripheral.discoverCharacteristics([keepAliveUUID], for: service)
                return
            }
        }
        Logger.logger?.log("Target service (\(self.targetServiceUUID.uuidString)) not found among discovered services")
    }
    
    // called after .discoverCharacteristics
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {

        if let error = error {
            Logger.logger?.error("Error discovering characteristics for service \(service.uuid): \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            Logger.logger?.log("No characteristics found for service \(service.uuid).")
            return
        }

        Logger.logger?.log("Discovered characteristics for service \(service.uuid): \(characteristics.map { $0.uuid })")

        for characteristic in characteristics {
            Logger.logger?.log("Checking characteristic: \(characteristic.uuid)")
            if characteristic.uuid == self.keepAliveUUID {
                Logger.logger?.log("Found keepAlive characteristic: \(characteristic.uuid)")
                if characteristic.properties.contains(.notify) {
                    Logger.logger?.log("Doorbell characteristic supports notify, subscribing")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            Logger.logger?.error("Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            Logger.logger?.log("Successfully subscribed to notifications for characteristic: \(characteristic.uuid)")
        } else {
            Logger.logger?.log("Successfully unsubscribed from notifications for characteristic: \(characteristic.uuid) (or subscription failed)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            Logger.logger?.error("Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
    }
    
    // not even sure when this is called or if its needed, but theoretically it should work
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        Logger.logger?.log("Restoring state (willRestoreState)")
        wasRestored = true

        if let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let uuidString = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
           let savedPeripheralUUID = UUID(uuidString: uuidString) {

            if let restoredP = restoredPeripherals.first(where: { $0.identifier == savedPeripheralUUID }) {
                Logger.logger?.log("Found our saved peripheral in restored list: \(restoredP.name ?? uuidString)")
                restoredP.delegate = self
                self.restoredPeripheral = restoredP
                // we then thereotically go to .didUpdateState
            } else {
                 Logger.logger?.log("Saved peripheral (UUID: \(uuidString)) not found among restored peripherals.")
            }
        } else {
            Logger.logger?.log("No peripherals to restore from dictionary, or no saved UUID to match.")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        
        if isReconnecting {
            print("Disconnected, reconnecting")
        } else {
            Logger.logger?.log("Disconnected from peripheral: \(peripheral.name ?? "unknown")")
            self.bleState = .disconnected
            self.cleanupStreams()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Logger.logger?.error("Failed to connect to peripheral: \(peripheral.name ?? "unknown"), error: \(error?.localizedDescription ?? "Unknown error")")
        self.bleState = .disconnected
        self.peripheral = nil
        self.cleanupStreams()
    }
}

extension BLEManager : CBPeripheralDelegate, StreamDelegate {
    
    // open l2cap streams on channel connection
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        self.l2capChannel = channel
        setupStreams(for: channel!)
        self.bleState = .connected
    }
            
    
    // setup l2cap streams
    private func setupStreams(for channel: CBL2CAPChannel) {
        guard let inSt = channel.inputStream, let outSt = channel.outputStream else { return }
        
        inputStream = inSt
        outputStream = outSt
        
        Logger.logger?.log("streams created")
        
        inputStream?.setProperty(StreamNetworkServiceTypeValue.voice, forKey: .networkServiceType)
        outputStream?.setProperty(StreamNetworkServiceTypeValue.voice, forKey: .networkServiceType)
        
        inputStream?.delegate = self
        outputStream?.delegate = self
        
        inputStream?.schedule(in: .main, forMode: .default)
        outputStream?.schedule(in: .main, forMode: .default)
        
        inputStream?.open()
        outputStream?.open()
    }
    
    // cleanup l2cap streams
    func cleanupStreams() {
        
        Logger.logger?.log("streams closed")
        
        inputStream?.close()
        inputStream?.remove(from: .main, forMode: .default)
        inputStream?.delegate = nil
        
        outputStream?.close()
        outputStream?.remove(from: .main, forMode: .default)
        outputStream?.delegate = nil
        
        l2capChannel = nil
    }

    // handle streams
    func stream(_ aStream: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted:
            // self.BLEstate = "connected"
            if inputStream == aStream as? InputStream {
                print("Input stream opened")
            } else {
                print("Output stream opened")
            }
        
        case .hasBytesAvailable:
            
            // Logger.logger?.log("bytes read")
            
            
            if let inputStream = aStream as? InputStream {
                if expectedLength == nil {
                    var lenBytes = [UInt8](repeating: 0, count: 4)
                    let n = inputStream.read(&lenBytes, maxLength: 4)
                    guard n == 4 else { return }
                    expectedLength = Int(lenBytes[0])
                        | Int(lenBytes[1]) << 8
                        | Int(lenBytes[2]) << 16
                        | Int(lenBytes[3]) << 24
                    buffer.removeAll(keepingCapacity: true)
                    print("Expected length: \(expectedLength!) bytes")
                }
                var chunk = [UInt8](repeating: 0, count: 1024)
                let read = inputStream.read(&chunk, maxLength: chunk.count)
                if read > 0 {
                    Logger.logger?.log("chunk read")
                    buffer.append(chunk, count: read)
                    print("Received \(buffer.count) / \(expectedLength!) bytes")
                    
                    if let expected = expectedLength, buffer.count >= expected {
                        Logger.logger?.log("expected bytes received")
                        self.bgID = UIApplication.shared.beginBackgroundTask(withName: "apiCall") { [weak self] in
                            guard let self = self else { return }
                            UIApplication.shared.endBackgroundTask(self.bgID)
                        }
                        
                        // UIApplication.shared.endBackgroundTask(bgID)
                        
                        // Logger.logger?.log("Background time remaining: \(UIApplication.shared.backgroundTimeRemaining) seconds")
                        
                        // defer { UIApplication.shared.endBackgroundTask(self.bgID) }
                        
                        if let img = UIImage(data: buffer.prefix(expected)) {
                            DispatchQueue.main.async {
                                self.receivedImage = img.rotate(radians: -Float.pi / 2)
                                // print image width and height in pixels
                                print("Image size: \(img.size.width) x \(img.size.height)")
                                guard let imgBase64 = self.receivedImage?.convertToBase64() else { return }
                                Logger.logger?.log("base64 generated")
                                self.api.base64ImageString = imgBase64
                                Logger.logger?.log("Background time remaining: \(UIApplication.shared.backgroundTimeRemaining) seconds")
                                self.api.generateAudioDescription { [weak self] (receivedAudioData) in
                                    guard let self = self else { return }
                                    
                                    let taskID = self.bgID // Capture task ID in case self is deallocated

                                    if let audioData = receivedAudioData { // Or your test Data(count: 750000)
                                        print("Received audio data of length: \(audioData.count)")
                                        self.sendAudioData(audioData: audioData) { success in // Use your test data
                                            Logger.logger?.log("Audio send completed. Success: \(success). Ending background task.")
                                            UIApplication.shared.endBackgroundTask(taskID) // Use captured taskID
                                            if taskID == self.bgID { // defensive check if bgID was reassigned
                                               self.bgID = .invalid
                                            }
                                        }
                                    } else {
                                        print("Failed to receive audio data")
                                        UIApplication.shared.endBackgroundTask(taskID)
                                        if taskID == self.bgID {
                                           self.bgID = .invalid
                                        }
                                    }
                                }
                                 
                                    
                                print("api called")
                            }
                        }
                        expectedLength = nil
                    }
                }
                 
            }
             
        
            
        case .hasSpaceAvailable:
            if outputStream == aStream as? OutputStream {
                canWrite = true
                self.sendPendingData()
            }
            
        case .errorOccurred:
            print("Stream error:", aStream.streamError ?? "Unknown")
            // self.BLEstate = "disconnected"
            
        case .endEncountered:
            // self.BLEstate = "disconnected"
            cleanupStreams()
            
        default:
            break
        }
    }
    
    func sendData(_ message: String = "Hi ESP32 (init ios)") {
        
        guard let outSt = outputStream, canWrite, let data = message.data(using: .utf8) else { return }
        
        data.withUnsafeBytes { rawBuf in
            let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress!
            outSt.write(ptr, maxLength: data.count)
        }
    }
    
    func sendAudioData(audioData: Data, completion: @escaping (Bool) -> Void) {
        guard self.outputStream != nil else {
            Logger.logger?.error("Output stream is not available to send audio data.")
            completion(false) // Signal failure
            return
        }


        if self.dataToSend != nil && self.sendOffset < (self.dataToSend?.count ?? 0) {
            print("Previous send operation still in progress. New audio data not sent.")
            return
        }
        
        var length = UInt32(audioData.count).littleEndian
        let lengthData = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        
        self.dataToSend = lengthData + audioData
        self.sendOffset = 0
        
        print("Prepared audio data for sending: \(self.dataToSend!.count) bytes (including header)")
        
        self.audioSendCompletionHandler = completion
        
        if self.canWrite {
            self.sendPendingData()
        } else if self.dataToSend != nil && !self.dataToSend!.isEmpty {
            // If canWrite is false but we have data, we're waiting for .hasSpaceAvailable.
            // The completion will be called from sendPendingData when it's done or errors.
            Logger.logger?.log("sendAudioData: canWrite is false, data is queued. Waiting for .hasSpaceAvailable.")
        } else {
            // Should not happen if dataToSend was just set, but good for safety
            Logger.logger?.error("sendAudioData: No data to send or canWrite is false unexpectedly.")
            completion(false)
        }
    }

    private func sendPendingData() {
        guard let outSt = self.outputStream, let currentData = self.dataToSend else {
            // If no data, and we have a completion handler, maybe it was an empty send?
            // Or an error occurred before getting here.
            self.audioSendCompletionHandler?(true) // Or false depending on logic
            self.audioSendCompletionHandler = nil
            return
        }
        
        while self.canWrite && self.sendOffset < currentData.count {
            let bytesRemaining = currentData.count - self.sendOffset
            let amountToWrite = min(1024, bytesRemaining)
            
            let written = currentData.withUnsafeBytes { (rawBufferPointer: UnsafeRawBufferPointer) -> Int in
                let unsafeBufferPointer = rawBufferPointer.bindMemory(to: UInt8.self)
                guard let basePtr = unsafeBufferPointer.baseAddress else {
                    return -1
                }
                let pointerForChunk = basePtr.advanced(by: self.sendOffset)
                return outSt.write(pointerForChunk, maxLength: amountToWrite)
            }
            
            if written > 0 {
                self.sendOffset += written
                print("Sent \(written) bytes of audio packet. Total sent: \(self.sendOffset)/\(currentData.count)")
                if self.sendOffset == currentData.count {
                    print("Audio data packet sent successfully.")
                    self.dataToSend = nil
                    self.sendOffset = 0
                    self.audioSendCompletionHandler?(true)
                    self.audioSendCompletionHandler = nil
                    break
                }
                if written < amountToWrite {
                    self.canWrite = false
                }
            } else if written < 0 {
                print("Stream write error for audio data: \(outSt.streamError?.localizedDescription ?? "Unknown error")")
                self.dataToSend = nil
                self.sendOffset = 0
                self.canWrite = false
                self.audioSendCompletionHandler?(false) // <<<< SIGNAL FAILURE
                self.audioSendCompletionHandler = nil
                break
            } else {
                print("Wrote 0 bytes for audio data, stream buffer likely full.")
                self.canWrite = false
                break
            }
        }
        if self.sendOffset < currentData.count && self.dataToSend != nil {
             Logger.logger?.log("sendPendingData: Exited loop, canWrite likely false. \(currentData.count - self.sendOffset) bytes remaining.")
        } else if self.dataToSend == nil && self.audioSendCompletionHandler != nil {
            // This case implies all data was sent and completion was already called.
            // Or dataToSend became nil due to an error and completion was called.
        }
    }
}
