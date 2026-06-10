import SwiftUI

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
        .onDisappear {
            samplePlayer.stopPlayback()
        }
        .onChange(of: voices) { newVoices in
            if let selected = selectedVoice, !newVoices.contains(selected) {
                selectedVoice = nil
            }
        }
    }

    // MARK: — Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
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

    // MARK: — List

    @ViewBuilder
    private var list: some View {
        if voices.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Voice list available when the server is running.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(healthMonitor.state.displayName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredVoices.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 24))
                    .foregroundStyle(.tertiary)
                Text("No voices match \u{201C}\(searchQuery)\u{201D}")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredVoices, id: \.self, selection: $selectedVoice) { voice in
                row(for: voice)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 10))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        preferredVoice = voice == preferredVoice ? "" : voice
                    }
                    .onTapGesture(count: 1) {
                        selectedVoice = voice
                        samplePlayer.playSample(voice: voice)
                    }
                    .contextMenu {
                        Button("Play Sample") {
                            samplePlayer.playSample(voice: voice)
                        }
                        Divider()
                        Button(voice == preferredVoice ? "Clear Default" : "Set as Default") {
                            preferredVoice = voice == preferredVoice ? "" : voice
                        }
                    }
            }
            .listStyle(.inset)
        }
    }

    private func row(for voice: String) -> some View {
        let isDefault = voice == preferredVoice
        let isPlaying = samplePlayer.playingVoice == voice

        return HStack(spacing: 8) {
            Text(voice)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(isDefault ? Color.accentColor : Color.primary)

            Spacer()

            if isPlaying {
                EqualizerView(active: true, color: .accentColor, barCount: 5, maxHeight: 12)
                    .padding(.trailing, 2)
            }

            Button {
                preferredVoice = isDefault ? "" : voice
            } label: {
                Image(systemName: isDefault ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(isDefault ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle().size(CGSize(width: 28, height: 28)))
        }
        .frame(height: 34)
    }

    // MARK: — Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(filteredVoices.count) voice\(filteredVoices.count == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                if let playing = samplePlayer.playingVoice {
                    EqualizerView(active: true, color: .accentColor, barCount: 5, maxHeight: 10)
                    Text("playing \(playing)")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                if !preferredVoice.isEmpty {
                    Text("default: ")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                    + Text(preferredVoice)
                        .font(.caption.monospaced())
                        .foregroundColor(.primary)
                }
            }
            Text("Click to play a sample. Star to set as default.")
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
