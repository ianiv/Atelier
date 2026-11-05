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
        LabeledContent("Tailscale App") {
          Text(tailscaleText)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      } header: {
        Text("This Device as a Server")
      }
      RemoteTailscaleSection(tailnet: create.tailnet)
      Section {
        ForEach(server.devices) { device in
          LabeledContent {
            Button("Remove") { server.remove(device.id) }
              .rowButton()
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
          .rowButton()
          .disabled(!server.isEnabled || !server.isListening)
        }
      } header: {
        Text("Paired Devices")
      }
      Section {
        ForEach(create.remoteServers.servers) { record in
          LabeledContent {
            Button("Remove") { create.remoteServers.remove(record.id) }
              .rowButton()
          } label: {
            Text(record.name)
            Text(serverDetail(record))
          }
        }
        if create.remoteServers.servers.isEmpty {
          Text("No servers added yet.").foregroundStyle(.secondary)
        }
        HStack {
          Spacer()
          Button("Add Server…") { showingAddServer = true }
            .rowButton()
        }
      } header: {
        Text("Servers This Device Can Use")
      }
    }
    .formStyle(.grouped)
    #if os(macOS)
      // Tall enough to show the three sections without scrolling while the lists are short.
      .frame(minHeight: 640)
    #endif
      .onAppear {
        portText = String(server.port)
        server.loadIfNeeded()
        create.remoteServers.loadIfNeeded()
        if !create.remoteServers.servers.isEmpty { create.remoteServers.startBrowsing() }
      }
      .task { await server.refreshNetworkInfo() }
      .task { await create.remoteServers.checkStatus() }
    #if DEBUG
      // For layout checks: -AtelierShowPairing YES.
      .onChange(of: server.isListening, initial: true) {
        if server.isListening, UserDefaults.standard.bool(forKey: "AtelierShowPairing"), !showingPairing {
          server.startPairing()
          showingPairing = true
        }
      }
    #endif
      .sheet(isPresented: $showingPairing, onDismiss: { server.closePairing() }) {
        PairDeviceSheet()
      }
      .debugPresents("addServer", $showingAddServer)
      .sheet(isPresented: $showingAddServer) {
        AddServerSheet()
      }
  }

  private var tailscaleText: String {
    guard let address = server.tailscaleAddress else { return "Not found on this device" }
    return server.tailscaleName.map { "\($0) (\(address))" } ?? address
  }

  private func serverDetail(_ record: RemoteServerRecord) -> String {
    let address = record.addresses.first?.description ?? ""
    switch create.remoteServers.status(of: record.id) {
    case .online: return "Online · \(address)"
    case .offline: return "Offline · \(address)"
    case .unknown: return address
    }
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

/// Atelier's own Tailscale sign-in, which needs no Tailscale app.
private struct RemoteTailscaleSection: View {
  @Bindable var tailnet: RemoteTailnet
  @Environment(\.openURL) private var openURL
  @State private var hostnameText = ""

  private var isAvailable: Bool { tailnet.state != .unavailable }

  var body: some View {
    Section {
      LabeledContent {
        switch tailnet.state {
        case .unavailable:
          EmptyView()
        case .signedOut, .failed:
          Button("Sign In…") { tailnet.signIn() }
            .rowButton()
        case .starting:
          ProgressView().controlSize(.small)
        case .needsLogin(let url):
          Button("Open Sign-In Page") { openURL(url) }
            .rowButton()
        case .running:
          Button("Sign Out…") { Task { await tailnet.signOut() } }
            .rowButton()
        }
      } label: {
        Text(title)
        Text(detail)
      }
      Toggle(isOn: $tailnet.serves) {
        Text("Serve over Tailscale")
        Text("Paired devices can reach this one over your tailnet.")
      }
      .disabled(!isAvailable)
      Toggle(isOn: $tailnet.limitsToAccount) {
        Text("Limit access to your Tailscale account")
        Text(tailnet.status.login.map { "Only devices signed in as \($0) can connect, on top of being paired." } ?? "Only devices signed in as you can connect, on top of being paired.")
      }
      .disabled(!isAvailable)
      TextField("Control Server", text: $tailnet.controlURL, prompt: Text("Tailscale"))
        .help("Leave empty for Tailscale's own. For Headscale, its address.")
        .disabled(!isAvailable || tailnet.isSignedIn)
      LabeledContent {
        TextField("Preferred Hostname", text: $hostnameText)
          .labelsHidden()
          .onSubmit { applyHostname() }
      } label: {
        Text("Preferred Hostname")
        Text("Used to generate the Tailscale address.")
      }
      .disabled(!isAvailable)
    } header: {
      Text("Tailscale")
    }
    .onAppear { hostnameText = tailnet.hostname }
    .onChange(of: tailnet.state) { _, state in
      // The page to sign in on opens by itself the first time it's there.
      if case .needsLogin(let url) = state { openURL(url) }
    }
  }

  private var title: String {
    switch tailnet.state {
    case .unavailable: "Not in This Build"
    case .signedOut: "Not Signed In to Tailscale"
    case .starting: "Connecting to Tailscale…"
    case .needsLogin: "Waiting for Sign-In"
    case .running: "Signed In to Tailscale"
    case .failed: "Couldn't Connect to Tailscale"
    }
  }

  private var detail: String {
    switch tailnet.state {
    case .unavailable: "Run Scripts/build-tailscale.sh and build again. A Tailscale app still works."
    case .signedOut: "Atelier joins your tailnet by itself, with no Tailscale app needed."
    case .starting: "This takes a few seconds."
    case .needsLogin: "Finish signing in in your browser."
    case .running:
      ["Signed in as \(tailnet.status.login ?? "you")", tailnet.status.dnsName].compactMap(\.self).joined(separator: " · ")
    case .failed(let message): message
    }
  }

  private func applyHostname() {
    let name = hostnameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != tailnet.hostname else {
      hostnameText = tailnet.hostname
      return
    }
    tailnet.hostname = name
    Task { await tailnet.restart() }
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
      Text("On an iPad, scan this with the Camera app. Or on the other device, open Settings ▸ Compute ▸ Add Server… and paste the link or type the code. The code works once.")
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
  @Environment(RemoteServer.self) private var server
  @Environment(\.dismiss) private var dismiss
  /// A link opened from outside (a scanned QR code), to confirm.
  var opened: RemotePairingLink?
  @State private var link = ""
  @State private var host = ""
  @State private var code = ""
  @State private var error: String?
  @State private var isPairing = false

  private var parsedLink: RemotePairingLink? { RemotePairingLink(link) }
  private var canAdd: Bool {
    !isPairing && (parsedLink != nil || (RemoteAddress(host) != nil && RemotePairing.normalizedCode(code) != nil))
  }

  /// This device's own server isn't one to add.
  private var nearby: [RemoteNearby] {
    create.remoteServers.unpairedNearby.filter { $0.id != server.serverID }
  }

  private func use(_ found: RemoteNearby) {
    link = ""
    host = found.address.description
  }

  var body: some View {
    content
      .onAppear {
        if let opened { link = opened.text }
        create.remoteServers.startBrowsing()
      }
  }

  #if os(macOS)
    private var content: some View {
      VStack(alignment: .leading, spacing: 16) {
        Text("Add Server").font(.headline)
        Form {
          LabeledContent("Nearby") {
            if nearby.isEmpty {
              Text("None found").foregroundStyle(.secondary)
            } else {
              VStack(alignment: .trailing) {
                ForEach(nearby) { found in
                  Button("\(found.name): Pair…") { use(found) }
                    .rowButton()
                    .help("Fills in its address. It needs the code shown on \(found.name), under Pair a Device….")
                }
              }
            }
          }
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
  #else
    private var content: some View {
      NavigationStack {
        Form {
          Section {
            if nearby.isEmpty {
              Text("None found").foregroundStyle(.secondary)
            }
            ForEach(nearby) { found in
              LabeledContent(found.name) {
                Button("Pair…") { use(found) }
                  .rowButton()
              }
            }
          } header: {
            Text("Nearby")
          } footer: {
            Text("Pair… fills in its address. You'll need the code shown under Pair a Device… on that device.")
          }
          Section {
            HStack {
              TextField("atelier-pair://…", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
              PasteButton(payloadType: String.self) { strings in
                if let text = strings.first { link = text.trimmingCharacters(in: .whitespacesAndNewlines) }
              }
              .labelStyle(.iconOnly)
              .buttonBorderShape(.capsule)
            }
          } header: {
            Text("Pairing Link")
          } footer: {
            Text("Copy Link on the server gives you this. Scanning its QR code with the Camera app opens here with it filled in.")
          }
          Section {
            LabeledContent("Host") {
              TextField("vimes.tail1234.ts.net", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .multilineTextAlignment(.trailing)
            }
            LabeledContent("Code") {
              TextField("ABCDE-12345", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
            }
          } header: {
            Text("Or Enter Its Address")
          } footer: {
            if let error {
              Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if isPairing {
              Label { Text("Pairing…") } icon: { ProgressView().controlSize(.small) }
            }
          }
          .disabled(!link.isEmpty)
        }
        .formStyle(.grouped)
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Add") { add() }
              .disabled(!canAdd)
          }
        }
      }
      .presentationSizing(.form)
    }
  #endif

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

extension View {
  /// A button in a Form row. On iPad a plain one makes the whole row its tap target, so a tap
  /// anywhere on a server's row would remove it; a style of its own keeps it to the button.
  func rowButton() -> some View { buttonStyle(.bordered) }

  /// Opens `atelier-pair://` links, as a scanned QR code does, asking first: a link can come from
  /// anywhere, and the server it names would receive the jobs you send it.
  func remotePairingLinks() -> some View { modifier(RemotePairingLinks()) }
}

private struct RemotePairingLinks: ViewModifier {
  @Environment(CreateModel.self) private var create
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif

  func body(content: Content) -> some View {
    @Bindable var servers = create.remoteServers
    content
      .onOpenURL { url in
        guard url.scheme == RemotePairingLink.scheme else { return }
        if let link = RemotePairingLink(url.absoluteString) {
          servers.openedLink = link
        } else {
          create.errorMessage = RemoteError.invalidPairingLink.errorDescription
        }
      }
      // A link goes to the window already open, instead of making another.
      .handlesExternalEvents(preferring: [RemotePairingLink.scheme], allowing: ["*"])
      .sheet(item: $servers.openedLink) { link in
        AddServerSheet(opened: link)
      }
    #if os(macOS)
      .onAppear { Automation.openSettingsWindow = { openSettings() } }
    #endif
  }
}
