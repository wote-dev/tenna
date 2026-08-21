import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Files pane: what is moving now, then what has moved.
///
/// The drop target is here *and* on the whole window. Dropping onto a pane you are already
/// looking at is the obvious gesture; dropping onto whichever pane happens to be open is
/// the one people actually make.
struct TransfersView: View {
    @Environment(AppState.self) private var state
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if state.transfers.items.isEmpty {
                    empty
                } else {
                    ForEach(state.transfers.running) { transfer in
                        TransferCard(transfer: transfer)
                    }

                    if !state.transfers.finished.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Finished").font(.headline)
                                Spacer()
                                Button("Clear") { state.clearFinishedTransfers() }
                                    .buttonStyle(.plain)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(spacing: 0) {
                                ForEach(state.transfers.finished) { transfer in
                                    TransferRow(transfer: transfer)
                                    if transfer.id != state.transfers.finished.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .glassPanel(cornerRadius: 16)
                        }
                    }
                }

                Caption("Files you send land in the phone's Downloads folder, and files "
                        + "the phone sends land in yours. Everything is checked against a "
                        + "SHA-256 the sender computed before it started, and a transfer "
                        + "interrupted by a dropped connection carries on from where it "
                        + "stopped rather than starting again.")
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Files")
        .task { state.transfers.markSeen() }
        // A transfer finishing while this pane is open is being read as it lands, so the
        // sidebar badge must not start climbing behind the reader's back.
        .onChange(of: state.transfers.items.first?.id) { _, _ in
            state.transfers.markSeen()
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { state.sendFiles(urls) }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button("Send Files…") { picking = true }
                .disabled(!state.supportsFileTransfer)
            Spacer()
        }
    }

    /// Nothing has moved yet. Which of the three reasons it is decides what is worth saying.
    @ViewBuilder
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !state.status.isConnected {
                StatusRow("Waiting for your phone — files go over the same connection.",
                          symbol: "iphone.slash", font: .callout)
            } else if !state.supportsFileTransfer {
                StatusRow("This phone's build cannot transfer files yet. Update the app "
                          + "on the phone.",
                          symbol: "exclamationmark.triangle", font: .callout)
            } else {
                StatusRow("Drop files anywhere on this window to send them to the phone.",
                          symbol: "arrow.down.doc", font: .callout)
                StatusRow("On the phone, share anything to Tennanova to send it here.",
                          symbol: "square.and.arrow.up", font: .callout)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20)
    }
}

/// A transfer still going: name, status, a bar, and a way to stop it.
private struct TransferCard: View {
    @Environment(AppState.self) private var state
    let transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DirectionGlyph(transfer: transfer)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(TransferFormat.status(transfer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Stop") { state.cancelTransfer(transfer.id) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: transfer.fraction)
                .progressViewStyle(.linear)
                .tint(Tenna.accent)

            HStack {
                Text(TransferFormat.counts(transfer))
                Spacer()
                Text("\(Int(transfer.fraction * 100))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 20)
    }
}

/// A transfer that is over, in one line.
private struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 10) {
            DirectionGlyph(transfer: transfer)
            VStack(alignment: .leading, spacing: 1) {
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(TransferFormat.status(transfer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if transfer.state == .completed, let path = transfer.path {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Tenna.accent)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct DirectionGlyph: View {
    let transfer: Transfer

    var body: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(tint)
    }

    private var symbol: String {
        switch transfer.state {
        case .failed, .cancelled: return "exclamationmark.circle.fill"
        case .completed:
            return transfer.direction == .toPhone
                ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
        default:
            return transfer.direction == .toPhone
                ? "arrow.up.circle" : "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .failed, .cancelled: return .red
        case .completed:          return Tenna.accent
        default:                  return .secondary
        }
    }
}

/// The words and numbers on a row. Free functions rather than view code so the phrasing
/// can be read in one place and compared against the Android side's `transferStatusLine`.
enum TransferFormat {

    static func status(_ transfer: Transfer) -> String {
        switch transfer.state {
        case .queued:      return "Waiting its turn"
        case .preparing:   return "Preparing…"
        case .offered:     return "Waiting for the phone"
        case .active:      return counts(transfer)
        case .paused(let why):
            return why.isEmpty ? "Paused — it will continue when the phone reconnects" : why
        case .verifying:   return "Checking it arrived intact…"
        case .completed:
            return transfer.direction == .toPhone
                ? "Sent · \(bytes(transfer.bytes))"
                : "Saved to Downloads · \(bytes(transfer.bytes))"
        case .cancelled:   return "Cancelled"
        case .failed(let why): return why.isEmpty ? "Failed" : why
        }
    }

    static func counts(_ transfer: Transfer) -> String {
        "\(bytes(transfer.transferred)) / \(bytes(transfer.bytes))"
    }

    /// Sizes as a person would say them, and never more precision than the number
    /// deserves. Decimal units, matching Finder.
    static func bytes(_ value: Int) -> String {
        let count = Double(value)
        switch value {
        case 1_000_000_000...: return String(format: "%.1f GB", count / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1f MB", count / 1_000_000)
        case 1_000...:         return String(format: "%.1f KB", count / 1_000)
        default:               return "\(value) B"
        }
    }
}
