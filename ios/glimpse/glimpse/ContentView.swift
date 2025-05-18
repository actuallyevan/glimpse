import SwiftUI

struct ImageView: View {

    let image: UIImage?

    var body: some View {
        VStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            } else {
                Text("No image available")
            }
        }
    }
}

struct ContentView: View {

    @StateObject private var ble = BLEHandler()

    @State private var showingImage: Bool = false

    private var statusButtonText: String {
        switch ble.bleState {
        case .connected: return "Disconnect"
        case .connecting: return "Connecting... (Tap to disconnect)"
        case .disconnected: return "Connect"
        case .idle: return "Waiting..."
        case .scanning: return "Scanning..."
        }
    }

    private var statusButtonAction: () -> Void {
        switch ble.bleState {
        case .connected: return ble.manuallyDisconnect
        case .connecting: return ble.manuallyDisconnect
        case .disconnected: return ble.manuallyConnect
        case .idle: return {}
        case .scanning: return {}
        }
    }

    var body: some View {
        VStack {

            Spacer()

            Button(action: statusButtonAction) {
                Text(statusButtonText)
                    .font(.system(size: 40, weight: .bold))
                    .padding(.vertical, 20)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.teal)
            }

            Spacer()
        }

        VStack {

            Button {
                showingImage = true
            } label: {
                Text("Show Raw Image")
                    .font(.system(size: 15))
                    .padding(10)
                    .foregroundColor(.teal)
            }
            .padding(.bottom, 30)
        }

        .sheet(isPresented: $showingImage) {
            ImageView(image: ble.rawImage)
        }
    }
}

#Preview {
    ContentView()
}
