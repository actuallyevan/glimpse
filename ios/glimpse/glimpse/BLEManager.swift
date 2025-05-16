import Foundation
import CoreBluetooth
import SwiftUI
import AVFoundation
import OSLog

// Helper extension for Data (if you don't have one)
extension Data {
    func hexEncodedString() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}

class AtomicBool {
    private var val: Bool
    private let queue = DispatchQueue(label: "com.yourapp.atomicBoolQueue")
    init(_ initialValue: Bool) { self.val = initialValue }
    func load() -> Bool { queue.sync { self.val } }
    func store(_ newValue: Bool) { queue.async(flags: .barrier) { self.val = newValue } }
}

class BLEManager : NSObject, ObservableObject, CBCentralManagerDelegate {
    
    @Published public var BLEstate = "disconnected"
    @Published public var receivedMessage = ""
    
    @Published public var receivedImage: UIImage?
    
    private var api = APIHandler()
    private var audioPlayer: AVAudioPlayer?
    
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var l2capChannel: CBL2CAPChannel?
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var canWrite = false
    
    private let targetService = CBUUID(string: "dcbc7255-1e9e-49a0-a360-b0430b6c6905")
    private let psm: CBL2CAPPSM = 150
    
    private let doorBellUUID = CBUUID(string: "371a55c8-f251-4ad2-90b3-c7c195b049be")
    
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
    
    let logger = Logger(subsystem: "com.glimpseApp", category: "BLE")
    
    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.glimpseApp.central", CBConnectPeripheralOptionNotifyOnConnectionKey: true]
        )
    }
    
    // automatically reconnect to saved peripheral on startup
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        BLEstate = (central.state == .poweredOn) ? "ready" : "disconnected"
        
        guard central.state == .poweredOn else { return }
        
        // only connect if we are disconnected
        guard central.retrieveConnectedPeripherals(withServices: [targetService]).isEmpty else { return }
        
        // check if we have a saved peripheral and connect
        if let uuidString = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
        let uuid = UUID(uuidString: uuidString) {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            if let saved = known.first {
                
                self.peripheral = saved
                saved.delegate = self
                
                central.connect(saved, options: autoReconnectOptions)
                print("Reconnecting to saved peripheral")
                return
            }
        }
    }
    
    // initial connection (only when no peripheral is saved/connected)
    func initialConnection() {
        
        guard central.state == .poweredOn else { return }
        
        self.BLEstate = "scanning"
        central.scanForPeripherals(withServices: [targetService], options: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.central.isScanning else { return }
            
            self.central.stopScan()
            self.BLEstate = "disconnected"
            print("Scan timed out")
        }
    }
    
    // connect to discovered peripherals
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        self.BLEstate = "connecting"
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: autoReconnectOptions)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logger.error("Error discovering services: \(error.localizedDescription)")
            // Handle error, e.g., disconnect or retry
            return
        }

        guard let services = peripheral.services else {
            logger.log("No services found on peripheral.")
            return
        }

        logger.log("Discovered services: \(services.map { $0.uuid })")

        for service in services {
            if service.uuid == targetService {
                logger.log("Found target service: \(service.uuid). Discovering characteristics for it...")
                // Discover only the specific characteristic (doorBellUUID) for this service
                peripheral.discoverCharacteristics([doorBellUUID], for: service)
                return // Exit after finding and processing the target service
            }
        }
        logger.log("Target service (\(self.targetService.uuidString)) not found among discovered services.")
    }
    
    // open l2cap when connected
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "unknown device")")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")
        peripheral.discoverServices([targetService])
        peripheral.openL2CAPChannel(psm)
        logger.log("connected")
    }
    
    // reconnect on restart
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        
        guard central.state == .poweredOn else { return }
        
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            peripherals.forEach { peripheral in
                central.connect(peripheral, options: autoReconnectOptions)
            }
        }
    }
    
    // handle disconnect
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        
        if isReconnecting {
            print("Disconnected, reconnecting")
        } else {
            print("Disconnected")
            cleanupStreams()
            BLEstate = "disconnected"
        }
    }
}

extension BLEManager : CBPeripheralDelegate, StreamDelegate {
    
    // open l2cap streams on channel connection
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        self.l2capChannel = channel
        setupStreams(for: channel!)
        BLEstate = "connected"
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        logger.log("Peripheral:didDiscoverCharacteristicsFor service: \(service.uuid) called.") // Add this line

        if let error = error {
            logger.error("Error discovering characteristics for service \(service.uuid): \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            logger.log("No characteristics found for service \(service.uuid).")
            return
        }

        logger.log("Discovered characteristics for service \(service.uuid): \(characteristics.map { $0.uuid })")

        for characteristic in characteristics {
            logger.log("Checking characteristic: \(characteristic.uuid)")
            if characteristic.uuid == self.doorBellUUID {
                logger.log("Found Doorbell characteristic: \(characteristic.uuid)")
                if characteristic.properties.contains(.notify) {
                    logger.log("Doorbell characteristic supports notify. Subscribing...")
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    logger.log("Doorbell characteristic does NOT support notify property.")
                }
                // If you intend to read its initial value (which is L2CAP_CHANNEL in your ESP32 code)
                if characteristic.properties.contains(.read) {
                    // logger.log("Doorbell characteristic supports read. Reading initial value...")
                    // peripheral.readValue(for: characteristic)
                }
                // No need to continue loop if specific characteristic found
                // break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }

        if characteristic.isNotifying {
            logger.log("Successfully subscribed to notifications for characteristic: \(characteristic.uuid)")
        } else {
            logger.log("Successfully unsubscribed from notifications for characteristic: \(characteristic.uuid) (or subscription failed)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value else {
            logger.log("Characteristic \(characteristic.uuid) value is nil.")
            return
        }

        if characteristic.uuid == doorBellUUID {
            logger.log("Received notification from Doorbell characteristic (UUID: \(characteristic.uuid)): \(data.hexEncodedString())")
            // Process the doorbell notification data here.
            // The ESP32 sends a single byte token.
        } else {
            logger.log("Received data from unexpected characteristic \(characteristic.uuid): \(data.hexEncodedString())")
        }
    }
            
    
    // setup l2cap streams
    private func setupStreams(for channel: CBL2CAPChannel) {
        guard let inSt = channel.inputStream, let outSt = channel.outputStream else { return }
        
        inputStream = inSt
        outputStream = outSt
        
        logger.log("streams created")
        
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
        
        logger.log("streams closed")
        
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
            self.BLEstate = "connected"
            if inputStream == aStream as? InputStream {
                print("Input stream opened")
            } else {
                print("Output stream opened")
            }
        
        case .hasBytesAvailable:
            
            // logger.log("bytes read")
            
            
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
                    logger.log("chunk read")
                    buffer.append(chunk, count: read)
                    print("Received \(buffer.count) / \(expectedLength!) bytes")
                    
                    if let expected = expectedLength, buffer.count >= expected {
                        logger.log("expected bytes received")
                        self.bgID = UIApplication.shared.beginBackgroundTask(withName: "apiCall") { [weak self] in
                            guard let self = self else { return }
                            UIApplication.shared.endBackgroundTask(self.bgID)
                        }
                        
                        // UIApplication.shared.endBackgroundTask(bgID)
                        
                        // logger.log("Background time remaining: \(UIApplication.shared.backgroundTimeRemaining) seconds")
                        
                        // defer { UIApplication.shared.endBackgroundTask(self.bgID) }
                        
                        if let img = UIImage(data: buffer.prefix(expected)) {
                            DispatchQueue.main.async {
                                self.receivedImage = img.rotate(radians: -Float.pi / 2)
                                // print image width and height in pixels
                                print("Image size: \(img.size.width) x \(img.size.height)")
                                guard let imgBase64 = self.receivedImage?.convertToBase64() else { return }
                                self.logger.log("base64 generated")
                                self.api.base64ImageString = imgBase64
                                self.logger.log("Background time remaining: \(UIApplication.shared.backgroundTimeRemaining) seconds")
                                self.api.generateAudioDescription { [weak self] (receivedAudioData) in
                                    guard let self = self else { return }
                                    
                                    let taskID = self.bgID // Capture task ID in case self is deallocated

                                    if let audioData = receivedAudioData { // Or your test Data(count: 750000)
                                        print("Received audio data of length: \(audioData.count)")
                                        // self.playAudio(data: audioData)
                                        self.sendAudioData(audioData: Data(count: 750000)) { success in // Use your test data
                                            self.logger.log("Audio send completed. Success: \(success). Ending background task.")
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
            self.BLEstate = "disconnected"
            
        case .endEncountered:
            self.BLEstate = "disconnected"
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
    
    func playAudio(data: Data) {
        do {
            // Configure the audio session for playback
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            // Initialize the audio player with the MP3 data
            // The fileTypeHint helps AVAudioPlayer correctly interpret the data.
            // For MP3, AVFileType.mp3.rawValue is appropriate.
            self.audioPlayer = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)

            // Optional: self.audioPlayer?.delegate = self (if you need to handle playback finishing, etc.)
            // Optional: self.audioPlayer?.prepareToPlay() // Prepares the audio player for playback, reducing latency.

            self.audioPlayer?.play()
            print("Audio playback started.")

        } catch {
            print("Error initializing or playing audio: \(error.localizedDescription)")
        }
    }
    
    
    
    func sendAudioData(audioData: Data, completion: @escaping (Bool) -> Void) {
        guard self.outputStream != nil else {
            logger.error("Output stream is not available to send audio data.")
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
            logger.log("sendAudioData: canWrite is false, data is queued. Waiting for .hasSpaceAvailable.")
        } else {
            // Should not happen if dataToSend was just set, but good for safety
            logger.error("sendAudioData: No data to send or canWrite is false unexpectedly.")
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
             logger.log("sendPendingData: Exited loop, canWrite likely false. \(currentData.count - self.sendOffset) bytes remaining.")
        } else if self.dataToSend == nil && self.audioSendCompletionHandler != nil {
            // This case implies all data was sent and completion was already called.
            // Or dataToSend became nil due to an error and completion was called.
        }
    }
}
