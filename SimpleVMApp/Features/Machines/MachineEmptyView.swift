import SwiftUI

struct MachineEmptyView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Virtual Machines", systemImage: "desktopcomputer")
        } description: {
            Text("Create a machine from catalog media or a local installer ISO.")
        }
        .accessibilityIdentifier("machines.empty")
    }
}

