import Foundation
import CoreBluetooth


class BLEManager : NSObject, ObservableObject, CBCentralManagerDelegate {
    
    @Published public var BLEstate = "disconnected"
    @Published public var receivedMessage = ""
    
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var l2capChannel: CBL2CAPChannel?
    
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var canWrite = false
    
    private let targetService = CBUUID(string: "dcbc7255-1e9e-49a0-a360-b0430b6c6905")
    private let psm: CBL2CAPPSM = 150
    
    private let autoReconnectOptions: [String: Any] = [
        CBConnectPeripheralOptionEnableAutoReconnect: true,
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
    ]
    
    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.glimpseApp.central"]
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
        central.connect(peripheral, options: autoReconnectOptions) // should be auto reconnect
    }
    
    // open l2cap when connected
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "unknown device")")
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")
        peripheral.openL2CAPChannel(psm)
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
    
    // setup l2cap streams
    private func setupStreams(for channel: CBL2CAPChannel) {
        guard let inSt = channel.inputStream, let outSt = channel.outputStream else { return }
        
        inputStream = inSt
        outputStream = outSt
        
        inputStream?.delegate = self
        outputStream?.delegate = self
        
        inputStream?.schedule(in: .main, forMode: .default)
        outputStream?.schedule(in: .main, forMode: .default)
        
        inputStream?.open()
        outputStream?.open()
    }
    
    // cleanup l2cap streams
    func cleanupStreams() {
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
            if let inputStream = aStream as? InputStream {
                var buffer = [UInt8](repeating: 0, count: 1024)
                let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    handleIncomingData(data)
                }
            }
            
        case .hasSpaceAvailable:
            if outputStream == aStream as? OutputStream {
                canWrite = true
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
    
    func handleIncomingData(_ d: Data) {
        // get the current date and time
        let currentDateTime = Date()

        // initialize the date formatter and set the style
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none

        // get the date time String from the date object
        formatter.string(from: currentDateTime) // October 8, 2016 at 10:48:53 PM
        
        if let received = String(data: d, encoding: .utf8) {
            receivedMessage = received + formatter.string(from: currentDateTime)
            if received == "Hi iPhone (init esp)" {
                sendData("Hi ESP32 (init esp)")
            }
        }
    }
}
