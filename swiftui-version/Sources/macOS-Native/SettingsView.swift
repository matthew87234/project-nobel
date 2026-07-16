import SwiftUI

struct SettingsView: View {
    @State private var selectedTab = "AI Settings"
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AISettingsView()
                .tabItem {
                    Label("AI Settings", systemImage: "cpu")
                }
                .tag("AI Settings")
            
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("General")
        }
        .frame(width: 580, height: 480)
        .padding()
    }
}

// MARK: - AI Settings Tab
struct AISettingsView: View {
    @State private var activeSection: String = "text"
    
    // Local routing overrides
    @AppStorage("latex_always_local") private var latexAlwaysLocal: Bool = true
    @AppStorage("feynman_always_local") private var feynmanAlwaysLocal: Bool = true
    
    // Text model settings
    @AppStorage("ai_provider") private var aiProvider: String = "local"
    @AppStorage("local_model_general") private var localModelGeneral: String = "qwen2.5-coder:7b"
    @AppStorage("tailscale_host") private var tailscaleHost: String = "http://100.100.100.100:11434"
    @AppStorage("tailscale_model_general") private var tailscaleModelGeneral: String = "qwen2.5-coder:7b"
    @AppStorage("cloud_api_key") private var cloudApiKey: String = ""
    @AppStorage("cloud_model_name") private var cloudModelName: String = ""
    @AppStorage("cloud_api_base_url") private var cloudApiBaseUrl: String = ""
    
    // Vision model settings (independent)
    @AppStorage("vision_provider") private var visionProvider: String = "local"
    @AppStorage("local_host") private var localHost: String = "http://localhost:11434"
    @AppStorage("local_model_vision") private var localModelVision: String = "qwen2.5vl:7b"
    @AppStorage("vision_tailscale_host") private var visionTailscaleHost: String = "http://100.100.100.100:11434"
    @AppStorage("vision_tailscale_model") private var visionTailscaleModel: String = "qwen2.5vl:7b"
    @AppStorage("vision_api_key") private var visionApiKey: String = ""
    @AppStorage("vision_model_name") private var visionModelName: String = ""
    @AppStorage("vision_api_base_url") private var visionApiBaseUrl: String = ""
    
    // Models cache
    @State private var ollamaModels: [String] = []
    @State private var ollamaVisionModels: [String] = []
    @State private var hermesModels: [String] = []
    @State private var visionHermesModels: [String] = []
    @State private var isLoadingModels = false
    
    // Known vision-capable model name patterns
    private let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream", "gpt-4o", "gpt-4-turbo", "claude-3", "gemini", "qwen2.5vl", "qwen2-vl", "llama3.2-vision", "pixtral"]
    
    private func isVisionCapable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return visionKeywords.contains { lower.contains($0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top-level slider: Text Model ↔ Vision Model
            Picker("", selection: $activeSection) {
                Text("Text Model").tag("text")
                Text("Vision Model").tag("vision")
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .padding(.bottom, 4)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if activeSection == "text" {
                        // ── TEXT MODEL ──
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Text Model", systemImage: "textformat")
                                .font(.headline)
                            Text("Used for summaries, step generation, problem extraction, and Feynman dialogue.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("Provider:")
                                    .bold()
                                    .gridCellAnchor(.trailing)
                                HStack(spacing: 8) {
                                    Picker("", selection: $aiProvider) {
                                        Text("Local Ollama").tag("local")
                                        Text("Tailscale").tag("tailscale")
                                        Text("Hermes (GLM 5.2)").tag("hermes")
                                        Text("Groq").tag("groq")
                                        Text("OpenAI").tag("openai")
                                        Text("Anthropic").tag("anthropic")
                                        Text("Gemini").tag("gemini")
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 180)
                                    
                                    Button(action: { refreshModels() }) {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Refresh model lists")
                                }
                            }
                            
                            if aiProvider == "local" {
                                GridRow {
                                    Text("Model:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    modelPicker(models: ollamaModels, selection: $localModelGeneral, placeholder: "e.g. qwen2.5-coder:7b")
                                }
                            } else if aiProvider == "tailscale" {
                                GridRow {
                                    Text("Tailscale Host:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    TextField("http://100.100.100.100:11434", text: $tailscaleHost)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                                GridRow {
                                    Text("Model:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    modelPicker(models: ollamaModels, selection: $tailscaleModelGeneral, placeholder: "e.g. qwen2.5-coder:7b")
                                }
                            } else {
                                GridRow {
                                    Text("API Key:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    SecureField(aiProvider == "hermes" ? "Optional" : "API Key", text: $cloudApiKey)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                                GridRow {
                                    Text("Model:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    if aiProvider == "hermes" && !hermesModels.isEmpty {
                                        Picker("", selection: $cloudModelName) {
                                            ForEach(hermesModels, id: \.self) { Text($0).tag($0) }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(width: 320)
                                    } else {
                                        TextField("e.g. glm-5.2:cloud", text: $cloudModelName)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 320)
                                    }
                                }
                                GridRow {
                                    Text("API Base:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    TextField("e.g. https://api.groq.com/openai/v1", text: $cloudApiBaseUrl)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                            }
                        }
                    } else {
                        // ── VISION MODEL ── (same format as text model)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Vision Model", systemImage: "eye")
                                .font(.headline)
                            Text("Used for image-to-LaTeX, image problem extraction, and scanned PDF answers.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            GridRow {
                                Text("Provider:")
                                    .bold()
                                    .gridCellAnchor(.trailing)
                                HStack(spacing: 8) {
                                    Picker("", selection: $visionProvider) {
                                        Text("Local Ollama").tag("local")
                                        Text("Tailscale").tag("tailscale")
                                        Text("Hermes (GLM 5.2)").tag("hermes")
                                        Text("Groq").tag("groq")
                                        Text("OpenAI").tag("openai")
                                        Text("Anthropic").tag("anthropic")
                                        Text("Gemini").tag("gemini")
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 180)
                                    
                                    Button(action: { refreshModels() }) {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Refresh model lists")
                                }
                            }
                            
                            if visionProvider == "local" {
                                GridRow {
                                    Text("Host:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    TextField("http://localhost:11434", text: $localHost)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                                GridRow {
                                    Text("Model:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    modelPicker(models: ollamaVisionModels, selection: $localModelVision, placeholder: "e.g. qwen2.5vl:7b")
                                }
                            } else if visionProvider == "tailscale" {
                                GridRow {
                                    Text("Tailscale Host:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    TextField("http://100.100.100.100:11434", text: $visionTailscaleHost)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                                GridRow {
                                    Text("Model:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    modelPicker(models: ollamaVisionModels, selection: $visionTailscaleModel, placeholder: "e.g. qwen2.5vl:7b")
                                }
                            } else {
                                GridRow {
                                    Text("API Key:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    SecureField(visionProvider == "hermes" ? "Optional" : "API Key", text: $visionApiKey)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                                GridRow {
                                    Text("Model:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    if visionProvider == "hermes" && !visionHermesModels.isEmpty {
                                        Picker("", selection: $visionModelName) {
                                            ForEach(visionHermesModels, id: \.self) { Text($0).tag($0) }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(width: 320)
                                    } else {
                                        TextField("e.g. gpt-4o", text: $visionModelName)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 320)
                                    }
                                }
                                GridRow {
                                    Text("API Base:")
                                        .bold()
                                        .gridCellAnchor(.trailing)
                                    TextField("e.g. https://api.openai.com/v1", text: $visionApiBaseUrl)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 320)
                                }
                            }
                        }
                    }
                    
                    if isLoadingModels {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Querying models...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Local Laptop Routing Overrides", systemImage: "macbook")
                            .font(.headline)
                        
                        Text("Enforce local laptop model execution regardless of active network or provider settings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Toggle("Always Run LaTeX Translator Locally", isOn: $latexAlwaysLocal)
                            .toggleStyle(.switch)
                        
                        Toggle("Always Run Feynman Dialogue Locally", isOn: $feynmanAlwaysLocal)
                            .toggleStyle(.switch)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .onAppear { refreshModels() }
        .onChange(of: aiProvider) { _, newValue in
            prefillTextDefaults(for: newValue)
            refreshModels()
        }
        .onChange(of: visionProvider) { _, newValue in
            prefillVisionDefaults(for: newValue)
            refreshModels()
        }
        .onChange(of: localHost) { _, _ in refreshModels() }
        .onChange(of: tailscaleHost) { _, _ in refreshModels() }
        .onChange(of: visionTailscaleHost) { _, _ in refreshModels() }
        .onChange(of: cloudApiBaseUrl) { _, _ in
            if aiProvider == "hermes" { refreshModels() }
        }
        .onChange(of: visionApiBaseUrl) { _, _ in
            if visionProvider == "hermes" { refreshModels() }
        }
    }
    
    @ViewBuilder
    private func modelPicker(models: [String], selection: Binding<String>, placeholder: String) -> some View {
        if models.isEmpty {
            TextField(placeholder, text: selection)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
        } else {
            Picker("", selection: selection) {
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 320)
        }
    }
    
    private func prefillTextDefaults(for provider: String) {
        switch provider {
        case "hermes":
            cloudApiBaseUrl = "http://ollama1:11434/v1"
            cloudModelName = "glm-5.2:cloud"
            cloudApiKey = ""
        case "groq":
            cloudApiBaseUrl = "https://api.groq.com/openai/v1"
            cloudModelName = "llama-3.3-70b-versatile"
        case "openai":
            cloudApiBaseUrl = "https://api.openai.com/v1"
            cloudModelName = "gpt-4o"
        case "anthropic":
            cloudApiBaseUrl = "https://api.anthropic.com/v1"
            cloudModelName = "claude-3-5-sonnet-latest"
        case "gemini":
            cloudApiBaseUrl = "https://generativelanguage.googleapis.com/v1beta"
            cloudModelName = "gemini-1.5-pro"
        default:
            break
        }
    }
    
    private func prefillVisionDefaults(for provider: String) {
        switch provider {
        case "hermes":
            visionApiBaseUrl = "http://ollama1:11434/v1"
            visionModelName = "glm-5.2:cloud"
            visionApiKey = ""
        case "groq":
            visionApiBaseUrl = "https://api.groq.com/openai/v1"
            visionModelName = "llama-3.3-70b-versatile"
        case "openai":
            visionApiBaseUrl = "https://api.openai.com/v1"
            visionModelName = "gpt-4o"
        case "anthropic":
            visionApiBaseUrl = "https://api.anthropic.com/v1"
            visionModelName = "claude-3-5-sonnet-latest"
        case "gemini":
            visionApiBaseUrl = "https://generativelanguage.googleapis.com/v1beta"
            visionModelName = "gemini-1.5-pro"
        default:
            break
        }
    }
    
    private func refreshModels() {
        Task {
            await MainActor.run { isLoadingModels = true }
            
            await fetchOllamaModels()
            
            if aiProvider == "hermes" { await fetchHermesModels(baseURL: cloudApiBaseUrl, key: cloudApiKey) }
            if visionProvider == "hermes" { await fetchVisionHermesModels(baseURL: visionApiBaseUrl, key: visionApiKey) }
            
            await MainActor.run { isLoadingModels = false }
        }
    }
    
    private func fetchOllamaModels() async {
        let generalHost = aiProvider == "tailscale" ? tailscaleHost : localHost
        let visionHost = visionProvider == "tailscale" ? visionTailscaleHost : localHost
        
        // Fetch general models
        let cleanGenHost = generalHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if let generalURL = URL(string: "\(cleanGenHost)/api/tags") {
            do {
                let (data, _) = try await URLSession.shared.data(from: generalURL)
                struct Resp: Codable { struct M: Codable { let name: String }; let models: [M] }
                let res = try JSONDecoder().decode(Resp.self, from: data)
                let names = res.models.map { $0.name }.sorted()
                await MainActor.run {
                    self.ollamaModels = names
                    if !names.isEmpty {
                        if aiProvider == "tailscale" {
                            if tailscaleModelGeneral.isEmpty || !names.contains(tailscaleModelGeneral) {
                                tailscaleModelGeneral = names.first(where: { $0.contains("coder") }) ?? names[0]
                            }
                        } else {
                            if localModelGeneral.isEmpty || !names.contains(localModelGeneral) {
                                localModelGeneral = names.first(where: { $0.contains("coder") }) ?? names[0]
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.ollamaModels = [] }
            }
        } else {
            await MainActor.run { self.ollamaModels = [] }
        }
        
        // Fetch vision models
        let cleanVisHost = visionHost.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if let visionURL = URL(string: "\(cleanVisHost)/api/tags") {
            do {
                let (data, _) = try await URLSession.shared.data(from: visionURL)
                struct Resp: Codable { struct M: Codable { let name: String }; let models: [M] }
                let res = try JSONDecoder().decode(Resp.self, from: data)
                let names = res.models.map { $0.name }.sorted()
                await MainActor.run {
                    self.ollamaVisionModels = names.filter { self.isVisionCapable($0) }
                    if self.ollamaVisionModels.isEmpty { self.ollamaVisionModels = names }
                    
                    if !names.isEmpty {
                        if visionProvider == "tailscale" {
                            if visionTailscaleModel.isEmpty || !names.contains(visionTailscaleModel) {
                                visionTailscaleModel = names.first(where: { self.isVisionCapable($0) }) ?? names[0]
                            }
                        } else {
                            if localModelVision.isEmpty || !names.contains(localModelVision) {
                                localModelVision = names.first(where: { self.isVisionCapable($0) }) ?? names[0]
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.ollamaVisionModels = [] }
            }
        } else {
            await MainActor.run { self.ollamaVisionModels = [] }
        }
    }
    
    private func fetchHermesModels(baseURL: String, key: String) async {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(clean)/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Resp: Codable { struct M: Codable { let id: String }; let data: [M] }
            let res = try JSONDecoder().decode(Resp.self, from: data)
            let names = res.data.map { $0.id }.sorted()
            await MainActor.run {
                self.hermesModels = names
                if !names.isEmpty && (cloudModelName.isEmpty || !names.contains(cloudModelName)) {
                    cloudModelName = names[0]
                }
            }
        } catch {
            await MainActor.run { self.hermesModels = [] }
        }
    }
    
    private func fetchVisionHermesModels(baseURL: String, key: String) async {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(clean)/models") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Resp: Codable { struct M: Codable { let id: String }; let data: [M] }
            let res = try JSONDecoder().decode(Resp.self, from: data)
            let allNames = res.data.map { $0.id }.sorted()
            let visionNames = allNames.filter { self.isVisionCapable($0) }
            await MainActor.run {
                self.visionHermesModels = visionNames.isEmpty ? allNames : visionNames
                if !self.visionHermesModels.isEmpty && (visionModelName.isEmpty || !self.visionHermesModels.contains(visionModelName)) {
                    visionModelName = self.visionHermesModels[0]
                }
            }
        } catch {
            await MainActor.run { self.visionHermesModels = [] }
        }
    }
}

// MARK: - General Settings Tab
struct GeneralSettingsView: View {
    var body: some View {
        VStack(spacing: 25) {
            Image(systemName: "gearshape")
                .resizable()
                .frame(width: 48, height: 48)
                .foregroundColor(.secondary)
                .padding(.top, 40)
            
            Text("General Settings")
                .font(.title2)
                .bold()
            
            Text("Placeholder for future app configurations. Tabs to adjust parameters such as Database Paths, export styles, dark/light theme choices, and notifications preferences will be integrated here.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 45)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}