import AppKit
import SwiftUI

@MainActor
enum SSHConnectSheetPresenter {
    /// Opens the SSH Connect form as a sheet attached to `parentWindow`.
    /// If `parentWindow` is nil, falls back to the key or main window.
    static func present(on parentWindow: NSWindow?) {
        let host = parentWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let host else { return }

        let savedHosts = SSHConfigParser.loadUserConfig()
        let model = SSHConnectFormModel(savedHosts: savedHosts)
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.title = String(
            localized: "sshConnect.windowTitle",
            defaultValue: "New SSH Connection"
        )

        model.onCancel = { [weak host, weak sheetWindow] in
            guard let host, let sheetWindow else { return }
            host.endSheet(sheetWindow)
        }
        model.onConnect = { [weak host, weak sheetWindow] request in
            guard let host, let sheetWindow else { return }
            host.endSheet(sheetWindow)
            _ = CmuxSSHURLProcessLauncher.shared.start(
                request: request,
                preferredWindow: host
            )
        }

        let hosting = NSHostingController(rootView: SSHConnectFormView(model: model))
        sheetWindow.contentViewController = hosting
        host.beginSheet(sheetWindow, completionHandler: nil)
    }
}

@MainActor
final class SSHConnectFormModel: ObservableObject {
    @Published var selectedAlias: String = ""
    @Published var hostInput: String = ""
    @Published var userInput: String = ""
    @Published var portInput: String = ""
    @Published var identityFileInput: String = ""
    @Published var workspaceNameInput: String = ""
    @Published var selectedColorName: String? = nil
    @Published var errorMessage: String?

    let savedHosts: [SSHConfigHost]
    let colorPalette: [WorkspaceTabColorEntry]
    var onCancel: (() -> Void)?
    var onConnect: ((CmuxSSHURLRequest) -> Void)?

    init(
        savedHosts: [SSHConfigHost],
        colorPalette: [WorkspaceTabColorEntry] = WorkspaceTabColorSettings.palette()
    ) {
        self.savedHosts = savedHosts
        self.colorPalette = colorPalette
    }

    var canConnect: Bool {
        !hostInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func applySavedHost(alias: String) {
        selectedAlias = alias
        guard let entry = savedHosts.first(where: { $0.alias == alias }) else { return }
        hostInput = entry.resolvedHostName
        if hostInput.isEmpty { hostInput = entry.alias }
        userInput = entry.user ?? userInput
        portInput = entry.port.map(String.init) ?? portInput
        identityFileInput = entry.identityFile ?? identityFileInput
        if workspaceNameInput.isEmpty { workspaceNameInput = entry.alias }
    }

    func cancel() {
        onCancel?()
    }

    func submit() {
        let host = hostInput.trimmingCharacters(in: .whitespaces)
        let user = userInput.trimmingCharacters(in: .whitespaces)
        let portText = portInput.trimmingCharacters(in: .whitespaces)
        let identity = identityFileInput.trimmingCharacters(in: .whitespaces)
        let workspace = workspaceNameInput.trimmingCharacters(in: .whitespaces)

        guard !host.isEmpty else {
            errorMessage = String(
                localized: "sshConnect.error.hostRequired",
                defaultValue: "Enter a host to connect to."
            )
            return
        }

        var port: Int?
        if !portText.isEmpty {
            guard let parsed = Int(portText), parsed > 0, parsed <= 65535 else {
                errorMessage = String(
                    localized: "sshConnect.error.invalidPort",
                    defaultValue: "Port must be a number between 1 and 65535."
                )
                return
            }
            port = parsed
        }

        var components = URLComponents()
        components.scheme = AuthEnvironment.callbackScheme
        components.host = "ssh"
        var query: [URLQueryItem] = [URLQueryItem(name: "host", value: host)]
        if !user.isEmpty { query.append(URLQueryItem(name: "user", value: user)) }
        if let port { query.append(URLQueryItem(name: "port", value: String(port))) }
        if !workspace.isEmpty { query.append(URLQueryItem(name: "name", value: workspace)) }
        components.queryItems = query

        guard let url = components.url else {
            errorMessage = String(
                localized: "sshConnect.error.invalidInput",
                defaultValue: "Couldn't build an SSH request from those values."
            )
            return
        }

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let parsed)):
            var sshOptions = parsed.sshOptions
            if !identity.isEmpty {
                guard isValidIdentityPath(identity) else {
                    errorMessage = String(
                        localized: "sshConnect.error.invalidIdentity",
                        defaultValue: "Identity file path contains unsupported characters."
                    )
                    return
                }
                sshOptions.append("IdentityFile=\(expandTilde(identity))")
            }
            let request = CmuxSSHURLRequest(
                originalURL: parsed.originalURL,
                destination: parsed.destination,
                port: parsed.port,
                title: parsed.title,
                sshOptions: sshOptions,
                noFocus: false,
                color: selectedColorName
            )
            errorMessage = nil
            onConnect?(request)
        case .success(.none):
            errorMessage = String(
                localized: "sshConnect.error.invalidInput",
                defaultValue: "Couldn't build an SSH request from those values."
            )
        case .failure(let error):
            errorMessage = SSHConnectFormModel.describe(error)
        }
    }

    private func isValidIdentityPath(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static func describe(_ error: CmuxSSHURLParseError) -> String {
        switch error {
        case .missingDestination:
            return String(
                localized: "sshConnect.error.hostRequired",
                defaultValue: "Enter a host to connect to."
            )
        case .destinationTooLong(let max):
            return String(
                format: String(
                    localized: "sshConnect.error.hostTooLong",
                    defaultValue: "Host is too long (max %lld characters)."
                ),
                Int64(max)
            )
        case .destinationContainsUnsafeCharacters, .destinationStartsWithDash:
            return String(
                localized: "sshConnect.error.invalidHost",
                defaultValue: "Host or user contains characters that aren't allowed."
            )
        case .titleTooLong(let max):
            return String(
                format: String(
                    localized: "sshConnect.error.workspaceNameTooLong",
                    defaultValue: "Workspace name is too long (max %lld characters)."
                ),
                Int64(max)
            )
        case .titleContainsUnsafeCharacters:
            return String(
                localized: "sshConnect.error.invalidWorkspaceName",
                defaultValue: "Workspace name contains characters that aren't allowed."
            )
        case .invalidPort:
            return String(
                localized: "sshConnect.error.invalidPort",
                defaultValue: "Port must be a number between 1 and 65535."
            )
        case .invalidIntegerParameter, .invalidHostKeyPolicy,
             .invalidBooleanParameter, .conflictingDestinationParameters,
             .conflictingTitleParameters, .duplicateParameter,
             .unsupportedParameter, .multipleLinks:
            return String(
                localized: "sshConnect.error.invalidInput",
                defaultValue: "Couldn't build an SSH request from those values."
            )
        }
    }
}

struct SSHConnectFormView: View {
    @ObservedObject var model: SSHConnectFormModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
    }

    private static let manualEntryToken = "__manual__"
    private let labelWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.savedHosts.isEmpty {
                labeledField(
                    String(
                        localized: "sshConnect.field.savedHosts",
                        defaultValue: "From ~/.ssh/config"
                    )
                ) {
                    Picker(
                        "",
                        selection: Binding(
                            get: { model.selectedAlias.isEmpty ? Self.manualEntryToken : model.selectedAlias },
                            set: { newValue in
                                if newValue == Self.manualEntryToken {
                                    model.selectedAlias = ""
                                } else {
                                    model.applySavedHost(alias: newValue)
                                }
                            }
                        )
                    ) {
                        Text(String(
                            localized: "sshConnect.savedHosts.manual",
                            defaultValue: "Enter manually…"
                        )).tag(Self.manualEntryToken)
                        ForEach(model.savedHosts, id: \.alias) { entry in
                            Text(entry.alias).tag(entry.alias)
                        }
                    }
                    .labelsHidden()
                }
            }

            labeledField(
                String(localized: "sshConnect.field.host", defaultValue: "Host")
            ) {
                TextField("example.com", text: $model.hostInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .host)
                    .onSubmit { model.submit() }
            }

            labeledField(
                String(localized: "sshConnect.field.user", defaultValue: "User")
            ) {
                TextField(
                    String(localized: "sshConnect.field.userPlaceholder", defaultValue: "username"),
                    text: $model.userInput
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submit() }
            }

            labeledField(
                String(localized: "sshConnect.field.port", defaultValue: "Port")
            ) {
                TextField("22", text: $model.portInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                    .onSubmit { model.submit() }
                Spacer(minLength: 0)
            }

            labeledField(
                String(localized: "sshConnect.field.identity", defaultValue: "Identity file")
            ) {
                TextField("~/.ssh/id_ed25519", text: $model.identityFileInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submit() }
            }

            labeledField(
                String(localized: "sshConnect.field.workspaceName", defaultValue: "Workspace name")
            ) {
                TextField(
                    String(
                        localized: "sshConnect.field.workspaceNamePlaceholder",
                        defaultValue: "Optional"
                    ),
                    text: $model.workspaceNameInput
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submit() }
            }

            labeledField(
                String(localized: "sshConnect.field.color", defaultValue: "Color")
            ) {
                colorPicker
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(
                    String(localized: "common.cancel", defaultValue: "Cancel"),
                    action: { model.cancel() }
                )
                .keyboardShortcut(.cancelAction)
                Button(
                    String(localized: "sshConnect.connect", defaultValue: "Connect"),
                    action: { model.submit() }
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConnect)
            }
        }
        .padding(20)
        .frame(width: 480, height: 560, alignment: .topLeading)
        .onAppear {
            // Sheets briefly fight us for first-responder during the present
            // animation, so hop a tick before claiming focus. Without this
            // SwiftUI's initial focus assignment is sometimes overridden by
            // AppKit's window-becomes-key handler.
            DispatchQueue.main.async {
                focusedField = .host
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private var colorPicker: some View {
        HStack(spacing: 6) {
            colorSwatch(name: nil, hex: nil)
            ForEach(model.colorPalette, id: \.name) { entry in
                colorSwatch(name: entry.name, hex: entry.hex)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func colorSwatch(name: String?, hex: String?) -> some View {
        let isSelected = model.selectedColorName == name
        Button {
            model.selectedColorName = name
        } label: {
            ZStack {
                if let hex, let nsColor = NSColor(hex: hex) {
                    Circle().fill(Color(nsColor: nsColor))
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1)
                        .background(Circle().fill(Color.clear))
                }
                if isSelected {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-2)
                }
            }
            .frame(width: 18, height: 18)
            .help(name ?? String(
                localized: "sshConnect.color.none",
                defaultValue: "No color"
            ))
        }
        .buttonStyle(.plain)
    }
}
