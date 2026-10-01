import SwiftUI

@MainActor
struct AIDevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var aiHelper = AIHelper.shared
    
    @AppStorage("tailscale_host") private var tailscaleHost: String = ""
    @AppStorage("tailscale_model_general") private var tailscaleModelGeneral: String = ""
    @AppStorage("vision_tailscale_host") private var visionTailscaleHost: String = ""
    @AppStorage("vision_tailscale_model") private var visionTailscaleModel: String = ""
    @AppStorage("ai_provider") private var aiProvider: String = "tailscale"
    @AppStorage("vision_provider") private var visionProvider: String = "tailscale"
    
    @State private var selectedHostURL: String = ""
    @State private var selectedGeneralModel: String = ""
    @State private var selectedVisionModel: String = ""
    @State private var customHostInput: String = ""
    @State private var isCustomHostTesting: Bool = false
    @State private var customHostError: String? = nil
    @State private var customDiscoveredHost: DiscoveredAIHost? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            contentScrollView
            Divider()
            footerView
        }
        .frame(width: 580, height: 600)
        .onAppear {
            if !tailscaleHost.isEmpty {
                selectedHostURL = tailscaleHost
                selectedGeneralModel = tailscaleModelGeneral
                selectedVisionModel = visionTailscaleModel
            }
            Task {
                _ = await aiHelper.scanTailscaleNetwork()
                if selectedHostURL.isEmpty, let first = aiHelper.discoveredHosts.first {
                    selectHost(first)
                }
            }
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "network")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Select AI Compute Device")
                    .font(.title3.bold())
                Text("Choose a Tailscale peer or local machine running Ollama for background processing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                Task {
                    _ = await aiHelper.scanTailscaleNetwork()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text(aiHelper.isScanningTailscale ? "Scanning..." : "Scan Network")
                }
                .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .disabled(aiHelper.isScanningTailscale)
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var contentScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Discovered Ollama Nodes")
                            .font(.headline)
                        Spacer()
                        if aiHelper.isScanningTailscale {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }
                    
                    if aiHelper.discoveredHosts.isEmpty && !aiHelper.isScanningTailscale {
                        emptyNodesView
                    } else {
                        ForEach(aiHelper.discoveredHosts) { host in
                            HostCardItemView(
                                host: host,
                                isSelected: selectedHostURL == host.hostURL,
                                selectedGeneralModel: $selectedGeneralModel,
                                selectedVisionModel: $selectedVisionModel,
                                onSelect: { selectHost(host) }
                            )
                        }
                    }
                }
                
                Divider()
                
                customHostSection
            }
            .padding(20)
        }
    }
    
    private var emptyNodesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No active Ollama servers detected on Tailscale.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Ensure Ollama is running (`ollama serve`) and reachable on port 11434.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
    
    private var customHostSection: some View {
        DisclosureGroup("Manual Host Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Enter the Tailscale IP, MagicDNS hostname, or local IP address of your AI server:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 10) {
                    TextField("http://hostname-or-ip:11434", text: $customHostInput)
                        .textFieldStyle(.roundedBorder)
                    
                    Button(action: testCustomHost) {
                        if isCustomHostTesting {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Text("Test & Probe")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(customHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCustomHostTesting)
                }
                
                if let err = customHostError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                if let customHost = customDiscoveredHost {
                    HostCardItemView(
                        host: customHost,
                        isSelected: selectedHostURL == customHost.hostURL,
                        selectedGeneralModel: $selectedGeneralModel,
                        selectedVisionModel: $selectedVisionModel,
                        onSelect: { selectHost(customHost) }
                    )
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
    }
    
    private var footerView: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            Button(action: saveAndApply) {
                Text("Connect & Save Selection")
                    .font(.headline)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedHostURL.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func selectHost(_ host: DiscoveredAIHost) {
        selectedHostURL = host.hostURL
        if selectedGeneralModel.isEmpty || !host.models.contains(selectedGeneralModel) {
            selectedGeneralModel = host.generalModels.first ?? host.models.first ?? ""
        }
        if selectedVisionModel.isEmpty || !host.models.contains(selectedVisionModel) {
            selectedVisionModel = host.visionModels.first ?? host.models.first ?? ""
        }
    }
    
    private func testCustomHost() {
        guard let url = AIHelper.normalizedOllamaURL(from: customHostInput) else {
            customHostError = "Invalid URL format."
            return
        }
        
        isCustomHostTesting = true
        customHostError = nil
        
        Task {
            let hostStr = url.host ?? customHostInput
            let port = url.port ?? 11434
            if let host = await aiHelper.probeHost(name: hostStr, ipOrHost: hostStr, port: port) {
                await MainActor.run {
                    self.customDiscoveredHost = host
                    self.selectHost(host)
                    self.isCustomHostTesting = false
                }
            } else {
                await MainActor.run {
                    self.customHostError = "Could not connect to Ollama at \(url.absoluteString). Verify port 11434 is open."
                    self.isCustomHostTesting = false
                }
            }
        }
    }
    
    private func saveAndApply() {
        guard !selectedHostURL.isEmpty else { return }
        
        tailscaleHost = selectedHostURL
        visionTailscaleHost = selectedHostURL
        aiProvider = "tailscale"
        visionProvider = "tailscale"
        
        if !selectedGeneralModel.isEmpty {
            tailscaleModelGeneral = selectedGeneralModel
        }
        if !selectedVisionModel.isEmpty {
            visionTailscaleModel = selectedVisionModel
        }
        
        aiHelper.touchAIAccess()
        aiHelper.retryConnectionAndQueue()
        dismiss()
    }
}

private struct HostCardItemView: View {
    let host: DiscoveredAIHost
    let isSelected: Bool
    @Binding var selectedGeneralModel: String
    @Binding var selectedVisionModel: String
    let onSelect: () -> Void
    
    private var isLocalDevice: Bool {
        host.ip.contains("127.0.0.1") || host.ip == "localhost"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            
            if !host.models.isEmpty {
                modelsRow
            }
            
            if isSelected {
                Divider()
                configurationRow
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
        )
    }
    
    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: isLocalDevice ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 22))
                .foregroundColor(isSelected ? .accentColor : .primary)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(host.name)
                        .font(.headline)
                    
                    if host.isOnline {
                        Text("Online (\(host.responseTimeMs)ms)")
                            .font(.caption2.bold())
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                
                Text(host.hostURL)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isSelected {
                Button(action: onSelect) {
                    Text("Selected")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: onSelect) {
                    Text("Select")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    private var modelsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Installed Models (\(host.models.count)):")
                .font(.caption.bold())
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(host.models, id: \.self) { model in
                        let isVision = host.visionModels.contains(model)
                        HStack(spacing: 4) {
                            Image(systemName: isVision ? "eye" : "text.bubble")
                                .font(.system(size: 9))
                            Text(model)
                                .font(.caption2.monospaced())
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(isVision ? Color.purple.opacity(0.15) : Color.blue.opacity(0.12))
                        .foregroundColor(isVision ? .purple : .blue)
                        .cornerRadius(4)
                    }
                }
            }
        }
    }
    
    private var configurationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configure Preferred Models for this Device:")
                .font(.caption.bold())
            
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("General AI:")
                        .font(.caption.bold())
                        .gridCellAnchor(.trailing)
                    Picker("", selection: $selectedGeneralModel) {
                        ForEach(host.generalModels.isEmpty ? host.models : host.generalModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }
                
                GridRow {
                    Text("Vision AI:")
                        .font(.caption.bold())
                        .gridCellAnchor(.trailing)
                    Picker("", selection: $selectedVisionModel) {
                        ForEach(host.visionModels.isEmpty ? host.models : host.visionModels, id: \.self) { m in
                            Text(m).tag(m)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
        .cornerRadius(8)
    }
}
