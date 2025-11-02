//
//  LogView.swift
//  VouchForMe
//
//  Created by Josh Mcdermott Sonoma on 11/2/25.
//


//  LogView.swift

import SwiftUI

struct LogView: View {
    @ObservedObject var model: LogModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Live Log").font(.title3).padding(.bottom, 6)

            List(model.entries) { entry in
                switch entry.kind {
                case .chunk(let text):
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.ts.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text("Chunk")
                            .font(.caption2).padding(4)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(4)
                        Text(text).lineLimit(3).truncationMode(.tail)
                    }
                case .secure(let on):
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.ts.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text("Secure Input")
                            .font(.caption2).padding(4)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(4)
                        Text(on ? "Enabled" : "Disabled")
                    }
                case .window(let snap):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.ts.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text("Window")
                                .font(.caption2).padding(4)
                                .background(Color.purple.opacity(0.15))
                                .cornerRadius(4)
                            Text(snap.appName)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Title: \(snap.windowTitle.isEmpty ? "—" : snap.windowTitle)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("Bundle: \(snap.bundleID ?? "—")   PID: \(snap.processID)   WindowID: \(snap.windowID)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Size: \(Int(snap.frame.width))×\(Int(snap.frame.height))  @\(String(format: "%.0f", NSScreen.main?.backingScaleFactor ?? 2))x")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Image(nsImage: snap.image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 320)
                            .cornerRadius(6)
                            .shadow(radius: 1)
                    }
                case .payload(let p):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.ts.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 72, alignment: .leading)
                            Text("Payload")
                                .font(.caption2).padding(4)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(4)
                            Text("\(p.appName) — \(p.windowTitle.isEmpty ? "No Window Title" : p.windowTitle)")
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Text(p.text).lineLimit(3).truncationMode(.tail)
                        if let img = p.image {
                            Image(nsImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 320)
                                .cornerRadius(6)
                                .shadow(radius: 1)
                        }
                    }
                case .queueInfo(let message):
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.ts.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text("Queue")
                            .font(.caption2).padding(4)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(4)
                        Text(message).lineLimit(2).truncationMode(.tail)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 360)
    }
}
