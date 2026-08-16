import SwiftUI

struct MachineEmptyView: View {
    let onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Virtual Machines", systemImage: "desktopcomputer")
        } description: {
            Text("Create a machine from catalog media or a local installer ISO.")
        } actions: {
            Button("New Machine…", action: onCreate)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier("machines.empty")
    }
}
