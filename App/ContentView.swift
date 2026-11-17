import SwiftUI

struct ContentView: View {
    @ObservedObject private var band = BandManager.shared
    @ObservedObject private var uploader = Uploader.shared
    @State private var token = ""
    @State private var repo = Uploader.shared.repo
    @State private var savedNote = ""

    private let dashboard = URL(string: "https://claude.ai/artifact/Gu79bL78dSqooGp3dyPy6w")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top) {
                        readout("Heart rate", band.bpm.map { "\($0)" } ?? "—", "bpm")
                        Spacer()
                        readout("HRV now", band.hrv.map { "\($0)" } ?? "—", "ms")
                        Spacer()
                        readout("Battery", band.battery.map { "\($0)" } ?? "—", "%")
                    }
                    .padding(.vertical, 6)
                    Label(band.status, systemImage: band.connected ? "dot.radiowaves.left.and.right" : "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(band.connected ? Color.green : Color.orange)
                    LabeledContent("Recorded today", value: duration(band.minutesToday))
                } header: {
                    Text(band.deviceName ?? "Band")
                }

                if !band.hasBand {
                    Section {
                        if band.found.isEmpty {
                            Text("No bands found yet. Wear your band and close the WHOOP app.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(band.found) { item in
                            Button {
                                band.choose(item.id)
                            } label: {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Search again") { band.scan() }
                    } header: {
                        Text("Pick your band")
                    }
                }

                Section {
                    if let last = uploader.lastUpload {
                        LabeledContent("Last upload") { Text(last, style: .relative) + Text(" ago") }
                    } else {
                        LabeledContent("Last upload", value: uploader.hasToken ? "Not yet" : "Needs a token")
                    }
                    if let problem = uploader.lastError {
                        Text(problem).font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Upload now") { uploader.uploadIfDue(force: true) }
                        .disabled(!uploader.hasToken)
                    Link("Open my dashboard in Claude", destination: dashboard)
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Recordings upload to your private GitHub repository every 10 minutes. Claude reads them from there and updates your dashboard.")
                }

                Section {
                    TextField("owner/repository", text: $repo)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(uploader.hasToken ? "Token saved. Paste a new one to replace it" : "GitHub token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        uploader.repo = repo
                        if !token.isEmpty {
                            uploader.saveToken(token)
                            token = ""
                        }
                        savedNote = "Saved."
                        uploader.uploadIfDue(force: true)
                    }
                    if !savedNote.isEmpty {
                        Text(savedNote).font(.footnote).foregroundStyle(.secondary)
                    }
                    if band.hasBand {
                        Button("Use a different band", role: .destructive) { band.forget() }
                    }
                } header: {
                    Text("Settings")
                } footer: {
                    Text("Keep this app running in the background. Don't swipe it away in the app switcher: iOS stops Bluetooth for apps you close that way. After a phone restart, open the app once.")
                }
            }
            .navigationTitle("Recovery Lab")
        }
    }

    private func readout(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func duration(_ minutes: Int) -> String {
        "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
    }
}
