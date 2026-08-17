import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePicker {
    static func chooseFile(
        allowedContentTypes: [UTType]
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        return present(panel)
    }

    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return present(panel)
    }

    static func chooseSaveFile(
        suggestedName: String,
        allowedContentType: UTType? = nil
    ) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let allowedContentType {
            panel.allowedContentTypes = [allowedContentType]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func present(_ panel: NSOpenPanel) -> URL? {
        panel.runModal() == .OK ? panel.url : nil
    }
}
