import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code for `text`, sharp at any size when drawn with `.interpolation(.none)`.
nonisolated enum RemoteQRCode {
  static func image(for text: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}

/// Settings ▸ Compute: let paired devices run jobs on this one, and the servers this one can use.
struct RemoteSettingsView: View {
  @Environment(RemoteServer.self) private var server
  @Environment(CreateModel.self) private var create
  @State private var portText = ""
  @State private var showingPairing = false
  @State private var showingAddServer = false

  var body: some View {
    @Bindable var server = server
    Form {
      Section {
        Toggle(isOn: $server.isEnabled) {
          Text("Let paired devices run jobs here")
          Text("Their jobs join this device's queue, one at a time. They can't see your projects, history or files.")
        }
        Picker("Accept connections from", selection: $server.filter) {
          ForEach(RemoteAddressFilter.allCases) { Text($0.title).tag($0) }
        }
        .disabled(!server.isEnabled)
        LabeledContent("Port") {
          TextField("Port", text: $portText)
            .labelsHidden()
            .frame(width: 80)
            .onSubmit { applyPort() }
        }
        .disabled(!server.isEnabled)
        LabeledContent("Status") {
          if !server.isEnabled {
            Text("Off").foregroundStyle(.secondary)
          } else if let error = server.listenError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
          } else if server.isListening {
            Text("Listening on port \(String(server.boundPort))").foregroundStyle(.secondary)
          } else {
            Text("Starting…").foregroundStyle(.secondary)
          }
        }
        LabeledContent("Tailscale") {
          Text(tailscaleText)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      } header: {
        Text("This Device as a Server")
      }
      Section {
        ForEach(server.devices) { device in
          LabeledContent {
            Button("Remove") { server.remove(device.id) }
          } label: {
            Text(device.name)
            Text(lastSeen(device))
          }
        }
        if server.devices.isEmpty {
          Text("No devices paired yet.").foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Pair a Device…") {
            server.startPairing()
            showingPairing = true
          }
          .disabled(!server.isEnabled || !server.isListening)
        }
      } header: {
        Text("Paired Devices")
      }
      Section {
        ForEach(create.remoteServers.servers) { record in
          LabeledContent {
            Button("Remove") { create.remoteServers.remove(record.id) }
          } label: {
            Text(record.name)
            Text(record.addresses.first?.description ?? "")
          }
        }
        if create.remoteServers.servers.isEmpty {
          Text("No servers added yet.").foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Add Server…") { showingAddServer = true }
        }
      } header: {
        Text("Servers This Device Can Use")
      }
    }
    .formStyle(.grouped)
    .onAppear {
      portText = String(server.port)
      server.loadIfNeeded()
      create.remoteServers.loadIfNeeded()
    }
    .task { await server.refreshNetworkInfo() }
    .sheet(isPresented: $showingPairing, onDismiss: { server.closePairing() }) {
      PairDeviceSheet()
    }
    .sheet(isPresented: $showingAddServer) {
      AddServerSheet()
    }
  }

  private var tailscaleText: String {
    guard let address = server.tailscaleAddress else { return "Not found on this device" }
    return server.tailscaleName.map { "\($0) (\(address))" } ?? address
  }

  private func lastSeen(_ device: RemotePairedDevice) -> String {
    guard let date = device.lastSeen else { return "Not seen yet" }
    return "Last seen \(date.formatted(.relative(presentation: .named)))"
  }

  private func applyPort() {
    if let port = UInt16(portText), port > 0 {
      server.port = port
    }
    portText = String(server.port)
  }
}

/// Shows the code and QR for one device to pair with, until it does or the code runs out.
private struct PairDeviceSheet: View {
  @Environment(RemoteServer.self) private var server
  @Environment(\.dismiss) private var dismiss
  /// The device list when the code was made: one more means it worked.
  @State private var deviceCount: Int?

  var body: some View {
    VStack(spacing: 16) {
      Text("Pair a Device").font(.headline)
      Group {
        if let pairing = server.pairing, let image = RemoteQRCode.image(for: pairing.link.text) {
          Image(decorative: image, scale: 1)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .accessibilityLabel("Pairing QR code")
        } else {
          ContentUnavailableView("Code Expired", systemImage: "clock", description: Text("Make a new one to pair a device."))
        }
      }
      .frame(width: 240, height: 240)
      Text(server.pairing?.displayCode ?? "-----·-----")
        .font(.system(.title2, design: .monospaced))
        .textSelection(.enabled)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(remaining(at: context.date)).foregroundStyle(.secondary)
      }
      Text("On the other device, open Settings ▸ Compute ▸ Add Server… and paste the link or type the code. The code works once.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      HStack {
        Button("Copy Link") {
          if let link = server.pairing?.link.text { Clipboard.copy(link) }
        }
        .disabled(server.pairing == nil)
        Button("New Code") { server.startPairing() }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 400)
    .onAppear { deviceCount = server.devices.count }
    .onChange(of: server.devices.count) { _, count in
      if let deviceCount, count > deviceCount { dismiss() }
    }
  }

  private func remaining(at date: Date) -> String {
    guard let pairing = server.pairing else { return "Not pairing" }
    let seconds = max(Int(pairing.expiresAt.timeIntervalSince(date).rounded(.up)), 0)
    return "Expires in \(seconds / 60):\(String(format: "%02d", seconds % 60))"
  }
}

/// Adds a server from its pairing link, or a host and the code it shows.
private struct AddServerSheet: View {
  @Environment(CreateModel.self) private var create
  @Environment(\.dismiss) private var dismiss
  @State private var link = ""
  @State private var host = ""
  @State private var code = ""
  @State private var error: String?
  @State private var isPairing = false

  private var parsedLink: RemotePairingLink? { RemotePairingLink(link) }
  private var canAdd: Bool {
    !isPairing && (parsedLink != nil || (RemoteAddress(host) != nil && RemotePairing.normalizedCode(code) != nil))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Server").font(.headline)
      Form {
        TextField("Pairing link", text: $link, prompt: Text("atelier-pair://…"))
        TextField("Or host", text: $host, prompt: Text("vimes.tail1234.ts.net"))
          .disabled(!link.isEmpty)
        TextField("Code", text: $code, prompt: Text("ABCDE-12345"))
          .disabled(!link.isEmpty)
      }
      .disableAutocorrection(true)
      Text(error ?? " ")
        .foregroundStyle(.red)
        .font(.callout)
      HStack {
        if isPairing { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") { add() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdd)
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private func add() {
    isPairing = true
    error = nil
    Task {
      defer { isPairing = false }
      do {
        if let parsedLink {
          try await create.remoteServers.pair(link: parsedLink)
        } else {
          try await create.remoteServers.pair(host: host, code: code)
        }
        dismiss()
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}
