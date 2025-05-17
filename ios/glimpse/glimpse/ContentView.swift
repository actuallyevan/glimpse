import SwiftUI

struct ContentView: View {
    @StateObject private var ble = BLEManager()

    @State private var statusMessage: String = "Press the button to convert text."
    @State private var mp3Data: Data? = nil // To store the MP3 data if you want to use it
    

    // The text you want to convert
    let textToSpeak = "Hello from SwiftUI. This will become an MP3."
    
    var body: some View {
        VStack {
            Text("BLE State: \(ble.bleStatusString)")
                .font(.headline)
                .padding(20)
            if ble.bleState == .connected {
                Text("Connected")
            } else if (ble.bleState == .scanning) {
                Text("Scanning for devices...")
            } else {
                Button("Connect") {
                    // ble.initialConnection()
                }
            }
            Button("Send Message") {
                ble.sendData()
            }
            .padding(20)
            Text("Received Message: \(ble.receivedMessage)")
                .font(.headline)
                .padding(20)
            if let img = ble.receivedImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}


