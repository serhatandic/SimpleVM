import SimpleVMCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarSelection?
    @State private var presentsNewMachine = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var immersion = ImmersionController()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
            if immersion.activeMachineID == nil {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentsNewMachine = true
                    } label: {
                        Label("New Machine", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        .toolbar(
            immersion.activeMachineID == nil ? .visible : .hidden,
            for: .windowToolbar
        )
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
        .onChange(of: immersion.activeMachineID) { _, machineID in
            columnVisibility = machineID == nil ? .all : .detailOnly
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
                    MachineDetailView(
                        model: model,
                        machine: machine,
                        immersion: immersion
                    )
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
