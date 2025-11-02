import SwiftUI

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                ForEach(model.items) { item in
                    ChunkCard(item: item)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 380, maxWidth: 460)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "app.fill")
                .imageScale(.medium)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.windowTitle.isEmpty ? "Active Window" : model.windowTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.appName.isEmpty ? "—" : model.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(6)
                }
                .buttonStyle(.plain)
                .background(.black.opacity(0.08), in: Circle())
                .contentShape(Circle())
                .help("Hide overlay")
            }
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for text…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

// MARK: - Card

private struct ChunkCard: View {
    let item: OverlayModel.Item

    var badge: some View {
        switch item.verdict {
        case .checking:
            return Label("Checking", systemImage: "ellipsis")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.gray.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        case .verified:
            return Label("Verified", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(LinearGradient(colors: [.green.opacity(0.3), .green.opacity(0.15)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                .foregroundStyle(.green)
        case .corrected:
            return Label("Correction", systemImage: "pencil.and.scribble")
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(LinearGradient(colors: [.pink.opacity(0.35), .pink.opacity(0.15)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                .foregroundStyle(.pink)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // First row: indicator + time
            HStack(spacing: 8) {
                badge
                Spacer()
                Text(item.ts, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Original text
            VStack(alignment: .leading, spacing: 6) {
                Text(item.chunk)
                    .font(.callout)
                    .lineLimit(3)
                    .foregroundStyle(item.hasCorrection ? .secondary : .primary)
                    .overlay(alignment: .topLeading) {
                        if item.isNewest {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                                .offset(y: -18)
                        }
                    }

                if let replacement = item.replacement {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Suggested")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(replacement)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
