import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    var body: some View {
        VStack {
            Text("BLE State: \(ble.BLEstate)")
                .font(.headline)
                .padding(20)
            if ble.BLEstate == "connected" {
                Text("Connected")
            } else if (ble.BLEstate == "scanning") {
                Text("Scanning for devices...")
            } else {
                Button("Connect") {
                    ble.initialConnection()
                }
            }
            Button("Send Message") {
                ble.sendData()
            }
            .padding(20)
            Text("Received Message: \(ble.receivedMessage)")
                .font(.headline)
                .padding(20)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
