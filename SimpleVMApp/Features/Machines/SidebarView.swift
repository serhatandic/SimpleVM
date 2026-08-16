import SimpleVMCore
import SwiftUI

struct SidebarView: View {
    let machines: [Machine]
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Virtual Machines") {
                ForEach(machines) { machine in
                    MachineRow(machine: machine)
                        .tag(SidebarSelection.machine(machine.id))
                }
            }

            Section("Library") {
                Label("Images", systemImage: "opticaldiscdrive")
                    .tag(SidebarSelection.library)
            }
        }
        .navigationTitle("SimpleVM")
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
    }
}

private struct MachineRow: View {
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(machine.name)
                .lineLimit(1)
            Text(machine.runtimeState.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private extension MachineRuntimeState {
    var displayName: String {
        switch self {
        case .stopped:
            "Stopped"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopping:
            "Stopping"
        case .failed:
            "Error"
        }
    }
}

