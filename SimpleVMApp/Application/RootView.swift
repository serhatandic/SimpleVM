import SimpleVMCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarSelection?
    @State private var presentsNewMachine = false

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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentsNewMachine = true
                } label: {
                    Label("New Machine", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $presentsNewMachine) {
            NewMachineView(model: model) { machineID in
                selection = .machine(machineID)
                presentsNewMachine = false
            }
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
                    MachineDetailView(model: model, machine: machine)
                } else {
                    MachineEmptyView {
                        presentsNewMachine = true
                    }
                }
            case .library:
                LibraryView(model: model)
            case nil:
                MachineEmptyView {
                    presentsNewMachine = true
                }
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
