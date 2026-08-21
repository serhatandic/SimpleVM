import AppKit
import SwiftUI

struct VMKeystrokePanel: View {
    let isRunning: Bool
    let sendChord: (GuestChord) -> Void

    @State private var text = ""
    @State private var clearsAfterSending = true
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Send Keystrokes")
                    .font(.headline)
                Spacer()
                specialKeyButton(":", chord: GuestChord(
                    keyCode: 41,
                    modifiers: [.shift]
                ))
                specialKeyButton("Esc", chord: GuestChord(
                    keyCode: 53,
                    modifiers: []
                ))
                specialKeyButton("Tab", chord: GuestChord(
                    keyCode: 48,
                    modifiers: []
                ))
                specialKeyButton("F10", chord: GuestChord(
                    keyCode: 109,
                    modifiers: []
                ))
                specialKeyButton("Ctrl+C", chord: GuestChord(
                    keyCode: 8,
                    modifiers: [.control]
                ))
                specialKeyButton("Ctrl+Alt+Del", chord: GuestChord(
                    keyCode: 117,
                    modifiers: [.control, .option]
                ))
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }
                .disabled(!isRunning || isSending)
                .accessibilityLabel("Keystroke staging area")
                .accessibilityIdentifier("vmInput.text")

            HStack {
                Text(
                    isRunning
                        ? "Characters are typed as a virtual US keyboard. This does not execute a remote command."
                        : "Start the machine before sending keystrokes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Toggle(
                    "Clear text after sending",
                    isOn: $clearsAfterSending
                )
                .toggleStyle(.checkbox)
                .disabled(!isRunning || isSending)
                Button("Type Text") {
                    send(appendingReturn: false)
                }
                .disabled(!canSend)
                Button("Type + Return") {
                    send(appendingReturn: true)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("vmInput.error")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .opacity(isRunning ? 1 : 0.6)
        .accessibilityIdentifier("vmInput.panel")
    }

    private var canSend: Bool {
        isRunning && !isSending && !text.isEmpty
    }

    private func specialKeyButton(
        _ title: String,
        chord: GuestChord
    ) -> some View {
        Button(title) {
            sendChord(chord)
        }
        .disabled(!isRunning || isSending)
        .accessibilityLabel("Send \(title) keystroke")
    }

    private func send(appendingReturn: Bool) {
        isSending = true
        errorMessage = nil
        Task {
            do {
                let targetWindow = NSApp.keyWindow
                var chords = try GuestTextEncoder.chords(for: text)
                if appendingReturn {
                    chords.append(GuestChord(keyCode: 36, modifiers: []))
                }
                for chord in chords {
                    guard NSApp.isActive,
                          NSApp.keyWindow === targetWindow else {
                        throw VMKeystrokePanelError.focusChanged
                    }
                    sendChord(chord)
                    try await Task.sleep(for: .milliseconds(8))
                }
                if clearsAfterSending {
                    text = ""
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }

    private enum VMKeystrokePanelError: LocalizedError {
        case focusChanged

        var errorDescription: String? {
            "Typing stopped because focus moved to another window."
        }
    }
}
