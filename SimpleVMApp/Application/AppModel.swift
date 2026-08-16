import Foundation
import Observation
import SimpleVMCore

@MainActor
@Observable
final class AppModel {
    private(set) var machines: [Machine] = []
    private(set) var images: [MachineImage] = []
    private(set) var storageURL: URL?
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    @ObservationIgnored
    private var store: LibraryStore?

    func initialize() async {
        guard store == nil else {
            return
        }

        do {
            let layout = try StorageLayout.live()
            let store = LibraryStore(layout: layout)
            let snapshot = try await store.load()
            self.store = store
            storageURL = layout.rootURL
            machines = snapshot.machines
            images = snapshot.images
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
