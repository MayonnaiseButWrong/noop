import SwiftUI
import CoreBluetooth
import WhoopKit   // product name from WhoopKitExperimental's Package.swift

// Deliberately minimal: this exists to prove the whole pipeline (Windows
// edit -> git push -> Mac build/sign -> TestFlight -> iPhone) works
// end-to-end with something real -- live heart rate off your actual
// strap -- before building any actual UI for recovery/strain/sleep.
// WhoopBLEManagerDelegate is the protocol WhoopKitExperimental/BLEManager.swift
// already defines; nothing new is invented here, just wired up.

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

    // MARK: - WhoopBLEManagerDelegate

    func whoopManager(_ manager: WhoopBLEManager, didUpdateState newState: WhoopBLEManager.ConnectionState) {
        DispatchQueue.main.async { self.state = String(describing: newState) }
    }

    func whoopManager(_ manager: WhoopBLEManager, didReceiveHeartRate hr: HeartRateMeasurement) {
        DispatchQueue.main.async { self.lastHR = hr.bpm }
    }

    func whoopManager(_ manager: WhoopBLEManager, didDecode message: DecodedPuffin, fromChannel uuid: CBUUID) {
        // Real decoded WHOOP5 records will show up here as messages.swift
        // grows to cover more record types. Nothing to show yet.
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
