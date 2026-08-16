import SimpleVMCore
import SwiftUI

struct MachineDetailView: View {
    let machine: Machine

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 44, weight: .light))
            Text(machine.name)
                .font(.title2.weight(.semibold))
            Text(machine.runtimeState == .running ? "Running" : "Stopped")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

