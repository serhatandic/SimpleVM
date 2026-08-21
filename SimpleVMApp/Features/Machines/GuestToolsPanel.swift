import AppKit
import SimpleVMCore
import SwiftUI

extension Machine {
    var hasConfiguredSharedDirectory: Bool {
        spec.sharedDirectoryPath != nil
    }
}

struct GuestToolsPanel: View {
    let machine: Machine
    let runtimeState: MachineRuntimeState
    let state: GuestToolsConnectionState
    let notice: String?
    let deliveredMessage: String?
    let retry: () -> Void
    let exportBundle: () -> Void
    let copyToShare: () -> Void
    let chooseShare: () -> Void
    let removeShare: () -> Void
    let reboot: () -> Void

    private var status: GuestAgentStatus? {
        state.status
    }

    private var installCommand: String {
        machine.hasConfiguredSharedDirectory
            ? GuestToolsBundleExporter.sharedInstallCommand(
                backend: machine.backend
            )
            : GuestToolsBundleExporter.manualInstallCommand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SimpleVM Guest Tools")
                        .font(.headline)
                        .accessibilityIdentifier("guestTools.panel")
                    Text(statusTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if runtimeState == .running,
                   status == nil {
                    Button("Retry Connection", action: retry)
                        .accessibilityIdentifier("guestTools.retry")
                }
            }

            if let status {
                connectedDetails(status)
            } else if let message = stateMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(
                        isErrorState ? Color.orange : Color.secondary
                    )
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("guestTools.notice")
            }

            Divider()
            Text("Setup and updates")
                .font(.subheadline.weight(.semibold))
            Text(
                "SimpleVM can deliver the bundle, but you run the command in the guest. It never supplies a password or modifies the guest disk."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                if machine.hasConfiguredSharedDirectory {
                    Button("Copy to Shared Folder", action: copyToShare)
                        .accessibilityIdentifier("guestTools.copyToShare")
                }
                Button("Export Tools Bundle...", action: exportBundle)
                    .accessibilityIdentifier("guestTools.export")
            }
            HStack {
                Button(
                    machine.hasConfiguredSharedDirectory
                        ? "Change Shared Folder..."
                        : "Choose Shared Folder...",
                    action: chooseShare
                )
                .accessibilityIdentifier("guestTools.chooseShare")
                if machine.hasConfiguredSharedDirectory {
                    Button(
                        "Remove Shared Folder",
                        role: .destructive,
                        action: removeShare
                    )
                    .accessibilityIdentifier("guestTools.removeShare")
                }
            }
            if let path = machine.spec.sharedDirectoryPath {
                LabeledContent(
                    "Host folder",
                    value: URL(filePath: path).lastPathComponent
                )
                .font(.caption)
            }
            if let deliveredMessage {
                Label(deliveredMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("guestTools.deliveryStatus")
            }

            Text(
                machine.hasConfiguredSharedDirectory
                    ? "After restarting the VM if the share was just configured, run:"
                    : "After moving the archive into the guest, run:"
            )
            .font(.caption.weight(.medium))
            HStack(alignment: .top) {
                Text(installCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("guestTools.installCommand")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        installCommand,
                        forType: .string
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy guest command")
                .accessibilityLabel("Copy guest command")
                .accessibilityIdentifier("guestTools.copyCommand")
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(width: 440)
    }

    @ViewBuilder
    private func connectedDetails(_ status: GuestAgentStatus) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            detailRow("Agent", status.agentVersion)
            detailRow(
                "System",
                "\(status.distroID) \(status.distroVersion)"
            )
            detailRow(
                "Session",
                "\(status.desktopEnvironment.rawValue) / \(status.sessionType.rawValue)"
            )
            detailRow(
                "Shared folder",
                status.sharedMountStatus.state.rawValue
            )
        }
        Text("Capabilities")
            .font(.subheadline.weight(.semibold))
        ForEach(GuestAgentCapability.allCases, id: \.self) { capability in
            let enabled = status.capabilities.contains(capability)
            Label(
                capability.displayName.capitalized,
                systemImage: enabled ? "checkmark.circle.fill" : "minus.circle"
            )
            .font(.caption)
            .foregroundStyle(enabled ? .primary : .secondary)
            .accessibilityIdentifier(
                "guestTools.capability.\(capability.rawValue)"
            )
        }
        if status.capabilities.contains(.gracefulReboot) {
            Button("Restart Guest", action: reboot)
                .accessibilityIdentifier("guestTools.reboot")
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private var statusTitle: String {
        switch state {
        case .stopped:
            "VM stopped"
        case .checking:
            "Checking for Guest Tools..."
        case .notConnected:
            "Not connected"
        case .connected:
            "Connected"
        case .incompatible:
            "Incompatible version"
        case .failed:
            "Connection error"
        }
    }

    private var stateMessage: String? {
        switch state {
        case .stopped:
            "Start the VM to check whether Guest Tools are installed."
        case .checking:
            "Waiting for the guest agent. The VM remains usable without it."
        case .notConnected(let message):
            if let message {
                "Guest Tools are not installed or its service is not running. Install the bundle, then retry. Technical detail: \(message)"
            } else {
                "Guest Tools are not installed or its service is not running. Install the bundle, then retry."
            }
        case .incompatible(let message), .failed(let message):
            message
        case .connected:
            nil
        }
    }

    private var isErrorState: Bool {
        switch state {
        case .incompatible, .failed:
            true
        case .stopped, .checking, .notConnected, .connected:
            false
        }
    }

    private var statusSymbol: String {
        switch state {
        case .connected:
            "checkmark.circle.fill"
        case .checking:
            "arrow.triangle.2.circlepath"
        case .incompatible, .failed:
            "exclamationmark.triangle.fill"
        case .stopped, .notConnected:
            "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected:
            .green
        case .incompatible, .failed:
            .orange
        case .stopped, .checking, .notConnected:
            .secondary
        }
    }
}
