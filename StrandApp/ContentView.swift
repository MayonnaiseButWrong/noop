import SwiftUI
import Combine
import CoreBluetooth
import WhoopKit

final class ContentViewModel: NSObject, ObservableObject, WhoopBLEManagerDelegate {
    @Published var state: String = "idle"
    @Published var lastHR: Int?
    @Published var lastError: String?

    private let manager = WhoopBLEManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func startScan() {
        lastError = nil
        manager.startScan()
    }

    func whoopManager(_ manager: WhoopBLEManager, didUpdateState newState: WhoopBLEManager.ConnectionState) {
        DispatchQueue.main.async { self.state = String(describing: newState) }
    }

    func whoopManager(_ manager: WhoopBLEManager, didReceiveHeartRate hr: HeartRateMeasurement) {
        DispatchQueue.main.async { self.lastHR = hr.bpm }
    }

    func whoopManager(_ manager: WhoopBLEManager, didDecode message: DecodedPuffin, fromChannel uuid: CBUUID) {
    }

    func whoopManager(_ manager: WhoopBLEManager, didFailWithError error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}

struct ContentView: View {
    @StateObject private var vm = ContentViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Strand").font(.largeTitle.bold())

            Text("Status: \(vm.state)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let hr = vm.lastHR {
                Text("\(hr)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                Text("bpm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No heart rate yet").foregroundStyle(.secondary)
            }

            if let err = vm.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Scan for WHOOP strap") { vm.startScan() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
