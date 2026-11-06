import SwiftUI

@MainActor
struct SettingsView: View {
    @State private var selectedTab = "AI Settings"
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AISettingsView()
                .tabItem {
                    Label("AI Settings", systemImage: "cpu")
                }
                .tag("AI Settings")
            
            AnkiSyncSettingsView()
                .tabItem {
                    Label("Anki Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag("Anki Sync")
            
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag("General")
        }
        .frame(width: 620, height: 500)
        .padding()
    }
}

// MARK: - AI Settings Tab
@MainActor
struct AISettingsView: View {
    // Compute topology preset
    @AppStorage("ai_compute_preset") private var aiComputePreset: String = "hybrid_twotier"
    
    // Model thinking toggles (--think) for text and visual models
    @AppStorage("ai_thinking_enabled") private var aiThinkingEnabled: Bool = false
    @AppStorage("ai_text_thinking_enabled") private var aiTextThinkingEnabled: Bool = false
    @AppStorage("ai_vision_thinking_enabled") private var aiVisionThinkingEnabled: Bool = false
    
    // Independent thinking toggles for Local and Remote
    @AppStorage("local_text_thinking_enabled") private var localTextThinkingEnabled: Bool = false
    @AppStorage("local_vision_thinking_enabled") private var localVisionThinkingEnabled: Bool = false
    @AppStorage("remote_text_thinking_enabled") private var remoteTextThinkingEnabled: Bool = false
    @AppStorage("remote_vision_thinking_enabled") private var remoteVisionThinkingEnabled: Bool = false
    
    // Sub-module selector for Hybrid preset ("local" vs "remote")
    @State private var selectedHybridModule: String = "local"
    
    // Task-specific granular routes ("local", "tailscale", or "cloud")
    @AppStorage("route_vision") private var routeVision: String = "local"
    @AppStorage("route_stitching") private var routeStitching: String = "tailscale"
    @AppStorage("route_math") private var routeMath: String = "tailscale"
    @AppStorage("route_steps") private var routeSteps: String = "tailscale"
    @AppStorage("route_matching") private var routeMatching: String = "tailscale"
    @AppStorage("route_classification") private var routeClassification: String = "tailscale"
    @AppStorage("route_translation") private var routeTranslation: String = "local"
    @AppStorage("route_feynman") private var routeFeynman: String = "local"
    
    // Power & background settings (always enabled per requirements)
    @AppStorage("background_ai_enabled") private var backgroundAIEnabled: Bool = true
    @AppStorage("auto_power_saver_enabled") private var autoPowerSaverEnabled: Bool = true
    
    // Local module settings
    @AppStorage("local_host") private var localHost: String = "http://localhost:11434"
    @AppStorage("local_model_general") private var localModelGeneral: String = ""
    @AppStorage("local_model_vision") private var localModelVision: String = ""
    
    // Remote module settings
    @AppStorage("remote_provider") private var remoteProvider: String = "tailscale"
    @AppStorage("ai_provider") private var aiProvider: String = "tailscale"
    @AppStorage("vision_provider") private var visionProvider: String = "local"
    
    // Remote node settings
    @AppStorage("tailscale_host") private var tailscaleHost: String = ""
    @AppStorage("tailscale_model_general") private var tailscaleModelGeneral: String = ""
    @AppStorage("vision_tailscale_host") private var visionTailscaleHost: String = ""
    @AppStorage("vision_tailscale_model") private var visionTailscaleModel: String = ""
    
    // Cloud API settings
    @AppStorage("cloud_api_key") private var cloudApiKey: String = ""
    @AppStorage("cloud_model_name") private var cloudModelName: String = ""
    @AppStorage("cloud_api_base_url") private var cloudApiBaseUrl: String = ""
    @AppStorage("vision_api_key") private var visionApiKey: String = ""
    @AppStorage("vision_model_name") private var visionModelName: String = ""
    @AppStorage("vision_api_base_url") private var visionApiBaseUrl: String = ""
    
    // Sheet & models cache state
    @State private var showDevicePickerSheet = false
    @State private var localModels: [String] = []
    @State private var localVisionModels: [String] = []
    @State private var tailscaleModels: [String] = []
    @State private var tailscaleVisionModels: [String] = []
    @State private var hermesModels: [String] = []
    @State private var visionHermesModels: [String] = []
    @State private var isLoadingModels = false
    @State private var isTailscaleOnline = false
    @State private var isLocalOnline = false
    @State private var tailscaleLatencyMs: Int = 0
    @State private var manualEntryKeys: Set<String> = []
    
    // Known vision keywords
    private let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream", "gpt-4o", "gpt-4-turbo", "claude-3", "gemini", "pixtral", "gemma3"]
    
    private func isVisionCapable(_ name: String) -> Bool {
        let lower = name.lowercased()
        return visionKeywords.contains { lower.contains($0) }
    }
    
    private var remoteProviderDisplayName: String {
        switch remoteProvider {
        case "tailscale": return "Tailscale Node"
        case "hermes": return "Hermes (GLM 5.2)"
        case "groq": return "Groq"
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "gemini": return "Gemini"
        default: return remoteProvider.capitalized
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 1. TOP: Compute Topology Presets Selector
            VStack(alignment: .leading, spacing: 6) {
                Label("Compute Topology Preset", systemImage: "square.grid.2x2")
                    .font(.headline)
                
                Picker("", selection: $aiComputePreset) {
                    Text("Two-Tier Hybrid").tag("hybrid_twotier")
                    Text("Remote GPU Only").tag("remote_only")
                    Text("100% On-Device").tag("local_only")
                    Text("Frontier Cloud").tag("cloud_frontier")
                }
                .pickerStyle(.segmented)
                
                Text(presetDescription(for: aiComputePreset))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 1)
            }
            
            Divider()
                .padding(.vertical, 2)
            
            // 2. SUB-SELECTOR: Local vs Remote (Shown when Two-Tier Hybrid is selected)
            if aiComputePreset == "hybrid_twotier" {
                Picker("", selection: $selectedHybridModule) {
                    Text("Local Module (Apple Silicon)").tag("local")
                    Text("Remote Module (\(remoteProviderDisplayName))").tag("remote")
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 2)
            }
            
            // 3. MODULE CONFIGURATION CARD
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if aiComputePreset == "local_only" || (aiComputePreset == "hybrid_twotier" && selectedHybridModule == "local") {
                        localModuleCard
                    } else {
                        remoteModuleCard
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
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .sheet(isPresented: $showDevicePickerSheet) {
            AIDevicePickerView()
        }
        .onAppear {
            autoPowerSaverEnabled = true
            backgroundAIEnabled = true
            if UserDefaults.standard.object(forKey: "local_text_thinking_enabled") == nil {
                localTextThinkingEnabled = aiTextThinkingEnabled
            }
            if UserDefaults.standard.object(forKey: "remote_text_thinking_enabled") == nil {
                remoteTextThinkingEnabled = aiTextThinkingEnabled
            }
            applyPreset(aiComputePreset)
            refreshModels()
        }
        .onChange(of: aiComputePreset) { _, newValue in
            applyPreset(newValue)
            refreshModels()
        }
        .onChange(of: remoteProvider) { _, newRemote in
            if ["hermes", "groq", "openai", "anthropic", "gemini"].contains(newRemote) {
                prefillTextDefaults(for: newRemote)
                prefillVisionDefaults(for: newRemote)
            }
            applyPreset(aiComputePreset)
            refreshModels()
        }
        .onChange(of: localHost) { _, _ in refreshModels() }
        .onChange(of: tailscaleHost) { _, newHost in
            if visionTailscaleHost.isEmpty {
                visionTailscaleHost = newHost
            }
            refreshModels()
        }
        .onChange(of: visionTailscaleHost) { _, _ in refreshModels() }
        .onChange(of: cloudApiBaseUrl) { _, _ in
            if remoteProvider == "hermes" { refreshModels() }
        }
        .onChange(of: visionApiBaseUrl) { _, _ in
            if remoteProvider == "hermes" { refreshModels() }
        }
    }
    
    // MARK: - Local Module Card
    private var localModuleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Local Engine (Apple Silicon)", systemImage: "laptopcomputer")
                    .font(.headline)
                
                Spacer()
                
                HStack(spacing: 5) {
                    Circle()
                        .fill(isLocalOnline ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(isLocalOnline ? "Ollama Ready (\(localModels.count) models)" : "Ollama Offline")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(isLocalOnline ? .green : .orange)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((isLocalOnline ? Color.green : Color.orange).opacity(0.12))
                .cornerRadius(6)
                
                Button(action: { refreshModels() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh local models")
            }
            
            Text("Runs on-device Metal acceleration for fast Vision OCR, LaTeX conversions, and Feynman dialogues.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Local Host:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 95, alignment: .trailing)
                    TextField("http://localhost:11434", text: $localHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 270)
                }
                
                HStack(spacing: 12) {
                    Text("Text Model:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 95, alignment: .trailing)
                    modelPicker(key: "local_text", models: localModels, selection: $localModelGeneral, placeholder: "Select text model")
                    let canThink = AIHelper.shared.isModelThinkingCapable(localModelGeneral)
                    Toggle("--think", isOn: $localTextThinkingEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(!canThink)
                        .opacity(canThink ? 1.0 : 0.4)
                        .help(canThink ? "Enable thinking tokens (--think) for local text model" : "Selected model does not support thinking mode")
                }
                
                HStack(spacing: 12) {
                    Text("Visual Model:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 95, alignment: .trailing)
                    modelPicker(key: "local_vision", models: localVisionModels, selection: $localModelVision, placeholder: "Select visual model")
                    let canThinkVision = AIHelper.shared.isModelThinkingCapable(localModelVision)
                    Toggle("--think", isOn: $localVisionThinkingEnabled)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .disabled(!canThinkVision)
                        .opacity(canThinkVision ? 1.0 : 0.4)
                        .help(canThinkVision ? "Enable thinking tokens (--think) for local visual model" : "Selected visual model does not support thinking mode")
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)
        }
    }
    
    // MARK: - Remote Module Card
    private var remoteModuleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Remote Engine (\(remoteProviderDisplayName))", systemImage: "server.rack")
                    .font(.headline)
                
                Spacer()
                
                if remoteProvider == "tailscale" {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isTailscaleOnline ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(isTailscaleOnline ? "Online (\(tailscaleModels.count) models, \(tailscaleLatencyMs)ms)" : "Offline / Unreachable")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(isTailscaleOnline ? .green : .orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((isTailscaleOnline ? Color.green : Color.orange).opacity(0.12))
                    .cornerRadius(6)
                    
                    Button(action: { showDevicePickerSheet = true }) {
                        Label("Scan Nodes", systemImage: "network")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Button(action: { refreshModels() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh remote models")
            }
            
            Text("Executes heavy reasoning, math derivations, step-by-step breakdowns, and question-solution matching.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("Remote Type:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 95, alignment: .trailing)
                    Picker("", selection: $remoteProvider) {
                        Text("Tailscale Node").tag("tailscale")
                        Text("Hermes (GLM 5.2)").tag("hermes")
                        Text("Groq").tag("groq")
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                        Text("Gemini").tag("gemini")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 270)
                }
                
                if remoteProvider == "tailscale" {
                    HStack(spacing: 12) {
                        Text("Tailscale Host:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        HStack(spacing: 8) {
                            TextField("e.g. http://100.x.y.z:11434", text: $tailscaleHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            if !tailscaleHost.isEmpty {
                                Button("Clear") {
                                    tailscaleHost = ""
                                    visionTailscaleHost = ""
                                    refreshModels()
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 10))
                            }
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Text("Text Model:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        modelPicker(key: "remote_text", models: tailscaleModels, selection: $tailscaleModelGeneral, placeholder: "Select text model")
                        let canThink = AIHelper.shared.isModelThinkingCapable(tailscaleModelGeneral)
                        Toggle("--think", isOn: $remoteTextThinkingEnabled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .disabled(!canThink)
                            .opacity(canThink ? 1.0 : 0.4)
                            .help(canThink ? "Enable thinking tokens (--think) for remote text model" : "Selected model does not support thinking mode")
                    }
                    
                    HStack(spacing: 12) {
                        Text("Visual Model:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        modelPicker(key: "remote_vision", models: tailscaleVisionModels, selection: $visionTailscaleModel, placeholder: "Select visual model")
                        let canThinkVision = AIHelper.shared.isModelThinkingCapable(visionTailscaleModel)
                        Toggle("--think", isOn: $remoteVisionThinkingEnabled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .disabled(!canThinkVision)
                            .opacity(canThinkVision ? 1.0 : 0.4)
                            .help(canThinkVision ? "Enable thinking tokens (--think) for remote visual model" : "Selected visual model does not support thinking mode")
                    }
                } else {
                    HStack(spacing: 12) {
                        Text("API Key:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        SecureField(remoteProvider == "hermes" ? "Optional" : "API Key", text: $cloudApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 270)
                    }
                    
                    HStack(spacing: 12) {
                        Text("API Base URL:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        TextField("Base URL", text: $cloudApiBaseUrl)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 270)
                    }
                    
                    HStack(spacing: 12) {
                        Text("Text Model:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        if remoteProvider == "hermes" && !hermesModels.isEmpty {
                            Picker("", selection: $cloudModelName) {
                                ForEach(hermesModels, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 270)
                        } else {
                            TextField("e.g. claude-3-5-sonnet-latest", text: $cloudModelName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 270)
                        }
                        let canThink = AIHelper.shared.isModelThinkingCapable(cloudModelName)
                        Toggle("--think", isOn: $remoteTextThinkingEnabled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .disabled(!canThink)
                            .opacity(canThink ? 1.0 : 0.4)
                            .help(canThink ? "Enable thinking tokens (--think)" : "Selected model does not support thinking mode")
                    }
                    
                    HStack(spacing: 12) {
                        Text("Visual Model:")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 95, alignment: .trailing)
                        if remoteProvider == "hermes" && !visionHermesModels.isEmpty {
                            Picker("", selection: $visionModelName) {
                                ForEach(visionHermesModels, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 270)
                        } else {
                            TextField("e.g. gpt-4o", text: $visionModelName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 270)
                        }
                        let canThinkVision = AIHelper.shared.isModelThinkingCapable(visionModelName)
                        Toggle("--think", isOn: $remoteVisionThinkingEnabled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                            .disabled(!canThinkVision)
                            .opacity(canThinkVision ? 1.0 : 0.4)
                            .help(canThinkVision ? "Enable thinking tokens (--think)" : "Selected visual model does not support thinking mode")
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)
        }
    }
    
    // MARK: - Model Picker Component
    private func effectiveModels(from models: [String], current: String) -> [String] {
        var list = models
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !list.contains(trimmed) {
            list.insert(trimmed, at: 0)
        }
        return list
    }
    
    @ViewBuilder
    private func modelPicker(key: String, models: [String], selection: Binding<String>, placeholder: String) -> some View {
        let isManual = manualEntryKeys.contains(key)
        let displayModels = effectiveModels(from: models, current: selection.wrappedValue)
        
        HStack(spacing: 6) {
            if isManual || models.isEmpty {
                TextField(placeholder, text: selection)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 270)
            } else {
                Picker("", selection: selection) {
                    ForEach(displayModels, id: \.self) { item in
                        Text(item).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 270)
            }
            
            Button(action: {
                if manualEntryKeys.contains(key) {
                    manualEntryKeys.remove(key)
                } else {
                    manualEntryKeys.insert(key)
                }
            }) {
                Image(systemName: isManual ? "list.bullet" : "pencil")
                    .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(isManual ? "Switch to model menu" : "Type custom model tag manually")
        }
    }
    
    // MARK: - Presets & Defaults
    private func presetDescription(for preset: String) -> String {
        switch preset {
        case "hybrid_twotier":
            return "Two-Tier Hybrid: Local Apple Silicon runs Vision OCR; Remote GPU runs 14B Math & Coding (Zero VRAM thrashing)."
        case "remote_only":
            return "Remote GPU Only: Offload 100% of text reasoning and vision OCR to remote server."
        case "local_only":
            return "100% On-Device: Execute all text and vision tasks locally on Apple Silicon (Metal)."
        case "cloud_frontier":
            return "Frontier Cloud: Route reasoning and OCR to Claude 3.5 Sonnet, Gemini 2.5 Pro, or GPT-4o."
        default:
            return ""
        }
    }
    
    private func applyPreset(_ preset: String) {
        aiComputePreset = preset
        let remoteTarget = remoteProvider == "local" ? "tailscale" : remoteProvider
        
        switch preset {
        case "hybrid_twotier":
            aiProvider = remoteTarget
            visionProvider = "local"
            routeVision = "local"
            routeTranslation = "local"
            routeFeynman = "local"
            routeMath = remoteTarget
            routeSteps = remoteTarget
            routeMatching = remoteTarget
            routeClassification = remoteTarget
            routeStitching = remoteTarget
        case "remote_only":
            aiProvider = remoteTarget
            visionProvider = remoteTarget
            routeVision = remoteTarget
            routeMath = remoteTarget
            routeSteps = remoteTarget
            routeMatching = remoteTarget
            routeClassification = remoteTarget
            routeTranslation = remoteTarget
            routeFeynman = remoteTarget
            routeStitching = remoteTarget
        case "local_only":
            aiProvider = "local"
            visionProvider = "local"
            routeVision = "local"
            routeMath = "local"
            routeSteps = "local"
            routeMatching = "local"
            routeClassification = "local"
            routeTranslation = "local"
            routeFeynman = "local"
            routeStitching = "local"
        case "cloud_frontier":
            let cloudProv = ["anthropic", "gemini", "openai", "groq", "hermes"].contains(remoteProvider) ? remoteProvider : "anthropic"
            remoteProvider = cloudProv
            aiProvider = cloudProv
            visionProvider = cloudProv
            routeVision = "cloud"
            routeMath = "cloud"
            routeSteps = "cloud"
            routeMatching = "cloud"
            routeClassification = "cloud"
            routeTranslation = "cloud"
            routeFeynman = "cloud"
            routeStitching = "cloud"
        default:
            break
        }
    }
    
    private func prefillTextDefaults(for provider: String) {
        switch provider {
        case "hermes":
            cloudApiBaseUrl = ""
            cloudModelName = ""
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
            cloudModelName = "gemini-flash-latest"
        default:
            break
        }
    }
    
    private func prefillVisionDefaults(for provider: String) {
        switch provider {
        case "hermes":
            visionApiBaseUrl = ""
            visionModelName = ""
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
            visionModelName = "gemini-flash-latest"
        default:
            break
        }
    }
    
    // MARK: - Querying Models
    private func refreshModels() {
        Task {
            await MainActor.run { isLoadingModels = true }
            
            await fetchAllOllamaModels()
            
            if remoteProvider == "hermes" {
                await fetchHermesModels(baseURL: cloudApiBaseUrl, key: cloudApiKey)
                await fetchVisionHermesModels(baseURL: visionApiBaseUrl, key: visionApiKey)
            }
            
            await MainActor.run { isLoadingModels = false }
        }
    }
    
    private func fetchAllOllamaModels() async {
        async let localTask: () = fetchLocalModels()
        async let tailscaleTask: () = fetchTailscaleModels()
        _ = await (localTask, tailscaleTask)
    }
    
    private func fetchLocalModels() async {
        let rawHost = localHost.isEmpty ? "http://localhost:11434" : localHost
        guard let baseURL = AIHelper.normalizedOllamaURL(from: rawHost, defaultHost: "http://localhost:11434") else { return }
        let url = baseURL.appendingPathComponent("api/tags")
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        
        struct Resp: Codable { struct M: Codable { let name: String }; let models: [M] }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run { self.isLocalOnline = false }
                return
            }
            let res = try JSONDecoder().decode(Resp.self, from: data)
            let names = res.models.map { $0.name }.sorted()
            let visionNames = names.filter { self.isVisionCapable($0) }
            
            await MainActor.run {
                self.localModels = names
                self.localVisionModels = visionNames.isEmpty ? names : visionNames
                self.isLocalOnline = true
                
                if !names.isEmpty {
                    if self.localModelGeneral.isEmpty || !names.contains(self.localModelGeneral) {
                        self.localModelGeneral = names.first(where: { !self.isVisionCapable($0) }) ?? names[0]
                    }
                }
                if !self.localVisionModels.isEmpty {
                    if self.localModelVision.isEmpty || !self.localVisionModels.contains(self.localModelVision) {
                        self.localModelVision = self.localVisionModels[0]
                    }
                }
            }
            for name in names {
                Task {
                    await AIHelper.shared.probeModelThinkingCapability(model: name, host: rawHost)
                }
            }
        } catch {
            await MainActor.run {
                self.isLocalOnline = false
            }
        }
    }
    
    private func fetchTailscaleModels() async {
        var rawHost = tailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawHost.isEmpty {
            rawHost = visionTailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !rawHost.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: rawHost, defaultHost: "") else {
            await MainActor.run {
                self.isTailscaleOnline = false
                self.tailscaleModels = []
                self.tailscaleVisionModels = []
            }
            return
        }
        let url = baseURL.appendingPathComponent("api/tags")
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        
        struct Resp: Codable { struct M: Codable { let name: String }; let models: [M] }
        
        let startTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run {
                    self.isTailscaleOnline = false
                }
                return
            }
            let res = try JSONDecoder().decode(Resp.self, from: data)
            let names = res.models.map { $0.name }.sorted()
            let visionNames = names.filter { self.isVisionCapable($0) }
            
            await MainActor.run {
                self.tailscaleModels = names
                self.tailscaleVisionModels = visionNames.isEmpty ? names : visionNames
                self.isTailscaleOnline = true
                self.tailscaleLatencyMs = durationMs
                
                if !names.isEmpty {
                    if self.tailscaleModelGeneral.isEmpty || !names.contains(self.tailscaleModelGeneral) {
                        self.tailscaleModelGeneral = names.first(where: { !self.isVisionCapable($0) }) ?? names[0]
                    }
                }
                if !self.tailscaleVisionModels.isEmpty {
                    if self.visionTailscaleModel.isEmpty || !self.tailscaleVisionModels.contains(self.visionTailscaleModel) {
                        self.visionTailscaleModel = self.tailscaleVisionModels[0]
                    }
                }
            }
            for name in names {
                Task {
                    await AIHelper.shared.probeModelThinkingCapability(model: name, host: rawHost)
                }
            }
        } catch {
            await MainActor.run {
                self.isTailscaleOnline = false
            }
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

// MARK: - Anki Sync Settings Tab
@MainActor
struct AnkiSyncSettingsView: View {
    @ObservedObject private var ankiEngine = AnkiSyncEngine.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("AnkiConnect & AnkiWeb Cloud Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .bold()
                Spacer()
            }
            
            Text("Bi-directional synchronization between Project Nobel and your AnkiWeb account. All flashcards are automatically organized into Year 1-4 decks.")
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.caption)
                        .foregroundColor(ankiEngine.isSyncing ? .orange : .green)
                    Text(ankiEngine.isSyncing ? "Syncing in progress..." : "AnkiConnect Bridge Ready (http://127.0.0.1:8765)")
                        .bold()
                }
                
                if let lastDate = ankiEngine.lastSyncDate {
                    Text("Last successful sync: \(lastDate.formatted(date: .numeric, time: .standard))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !ankiEngine.lastSyncStatus.isEmpty {
                    Text(ankiEngine.lastSyncStatus)
                        .font(.caption)
                        .foregroundColor(ankiEngine.lastSyncStatus.contains("missing") || ankiEngine.lastSyncStatus.contains("not running") ? .red : .primary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            
            HStack {
                Button(action: {
                    ankiEngine.syncWithAnki()
                }) {
                    HStack(spacing: 6) {
                        if ankiEngine.isSyncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(ankiEngine.isSyncing ? "Syncing..." : "Sync with Anki Now")
                    }
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(ankiEngine.isSyncing)
            }
            .padding(.top, 5)
            
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - General Settings Tab
@MainActor
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
