import SwiftUI

/// Voice browser window — flat alphabetical list with a search box.
/// Single click plays a sample; double-click sets the voice as preferred
/// (stored in UserDefaults under `"preferredVoice"`, displayed in the popover).
struct VoiceListView: View {
    @EnvironmentObject var healthMonitor: HealthMonitor
    @EnvironmentObject var samplePlayer: SamplePlayer
    @AppStorage("preferredVoice") private var preferredVoice = ""

    @State private var searchQuery = ""
    @State private var selectedVoice: String?

    private var voices: [String] {
        guard case .running(let info) = healthMonitor.state else { return [] }
        return info.voices.sorted()
    }

    private var filteredVoices: [String] {
        guard !searchQuery.isEmpty else { return voices }
        let needle = searchQuery.lowercased()
        return voices.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    private var header: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search voices", text: $searchQuery)
                .textFieldStyle(.plain)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var list: some View {
        if voices.isEmpty {
            VStack(spacing: 8) {
                Text("Voice list available only when the server is running.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(healthMonitor.state.displayName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredVoices.isEmpty {
            Text("No voices match \u{201C}\(searchQuery)\u{201D}")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredVoices, id: \.self, selection: $selectedVoice) { voice in
                row(for: voice)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        preferredVoice = voice
                        samplePlayer.playSample(voice: voice)
                    }
                    .onTapGesture(count: 1) {
                        selectedVoice = voice
                        samplePlayer.playSample(voice: voice)
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(for voice: String) -> some View {
        HStack {
            Text(voice)
                .font(.body.monospaced())
            if voice == preferredVoice {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.secondary, lineWidth: 0.5)
                    )
            }
            Spacer()
            if samplePlayer.playingVoice == voice {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(filteredVoices.count) voice\(filteredVoices.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !preferredVoice.isEmpty {
                    Text("Default: ")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    + Text(preferredVoice)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                }
            }
            Text("Click to play a sample. Double-click to set as default.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let err = samplePlayer.lastError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
    }
}
