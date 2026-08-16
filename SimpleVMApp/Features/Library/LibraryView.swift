import SimpleVMCore
import SwiftUI

struct LibraryView: View {
    let images: [MachineImage]

    var body: some View {
        if images.isEmpty {
            ContentUnavailableView {
                Label("No Images", systemImage: "opticaldiscdrive")
            } description: {
                Text("Managed installer media and machine images appear here.")
            }
        } else {
            Table(images) {
                TableColumn("Name", value: \.name)
                TableColumn("Architecture") { image in
                    Text(image.architecture.displayName)
                }
                TableColumn("Kind") { image in
                    Text(image.artifactKind.displayName)
                }
                TableColumn("Size") { image in
                    if let size = image.sizeBytes {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: size,
                                countStyle: .file
                            )
                        )
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Images")
        }
    }
}

