import SimpleVMCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarSelection?

    var body: some View {
        NavigationSplitView {
            SidebarView(
                machines: model.machines,
                selection: $selection
            )
        } detail: {
            detail
        }
        .task {
            await model.initialize()
        }
        .alert("SimpleVM", isPresented: errorBinding) {
            Button("OK") {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.isLoading {
            ProgressView("Opening SimpleVM…")
        } else {
            switch selection {
            case .machine(let id):
                if let machine = model.machines.first(where: { $0.id == id }) {
                    MachineDetailView(machine: machine)
                } else {
                    MachineEmptyView()
                }
            case .library:
                LibraryView(model: model)
            case nil:
                MachineEmptyView()
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.dismissError()
                }
            }
        )
    }
}

enum SidebarSelection: Hashable {
    case machine(UUID)
    case library
}
