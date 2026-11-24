import Foundation
import AppKit
import PDFKit
import CryptoKit

struct OllamaOptions: Codable {
    let temperature: Double?
    let num_predict: Int?
    let top_p: Double?
    
    init(temperature: Double? = nil, num_predict: Int? = nil, top_p: Double? = nil) {
        self.temperature = temperature
        self.num_predict = num_predict
        self.top_p = top_p
    }
}

struct GenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
    let images: [String]?
    let keep_alive: String?
    let options: OllamaOptions?
    let think: Bool?
    
    init(model: String, prompt: String, stream: Bool = false, images: [String]? = nil, keep_alive: String? = "60m", options: OllamaOptions? = nil, think: Bool? = nil) {
        self.model = model
        self.prompt = prompt
        self.stream = stream
        self.images = images
        self.keep_alive = keep_alive
        self.options = options
        self.think = think
    }
}

struct GenerateResponse: Codable {
    let response: String?
    let thinking: String?
    let done: Bool?
    let error: String?
}

struct PullRequest: Codable {
    let model: String
    let stream: Bool
}

struct TagsResponse: Codable {
    struct ModelInfo: Codable {
        let name: String
    }
    let models: [ModelInfo]
}

struct DiscoveredAIHost: Identifiable, Hashable {
    var id: String { hostURL }
    let name: String
    let ip: String
    let port: Int
    let hostURL: String
    let models: [String]
    let generalModels: [String]
    let visionModels: [String]
    let isOnline: Bool
    let responseTimeMs: Int
}
struct PendingExtractionItem: Identifiable, Equatable {
    let id: UUID
    enum ItemType {
        case pdf
        case image
    }
    let type: ItemType
    let pathOrName: String
    let imageBase64: String?
    let isAnswerSource: Bool
    let originalPdfPath: String?
    
    var displayName: String {
        URL(fileURLWithPath: pathOrName).lastPathComponent
    }
    
    init(type: ItemType, pathOrName: String, imageBase64: String? = nil, isAnswerSource: Bool = false, originalPdfPath: String? = nil) {
        self.id = UUID()
        self.type = type
        self.pathOrName = pathOrName
        self.imageBase64 = imageBase64
        self.isAnswerSource = isAnswerSource
        self.originalPdfPath = originalPdfPath
    }
    
    static func == (lhs: PendingExtractionItem, rhs: PendingExtractionItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct ExtractionGroup: Identifiable, Equatable {
    let id: UUID
    let questionItem: PendingExtractionItem
    let answerItems: [PendingExtractionItem]
    
    init(questionItem: PendingExtractionItem, answerItems: [PendingExtractionItem] = []) {
        self.id = UUID()
        self.questionItem = questionItem
        self.answerItems = answerItems
    }
    
    static func == (lhs: ExtractionGroup, rhs: ExtractionGroup) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor class AIHelper: ObservableObject {
    static let shared = AIHelper()
    
    var isBackgroundAIEnabled: Bool {
        if UserDefaults.standard.object(forKey: "background_ai_enabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "background_ai_enabled")
    }
    
    var isAutoPowerSaverEnabled: Bool {
        if UserDefaults.standard.object(forKey: "auto_power_saver_enabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "auto_power_saver_enabled")
    }
    
    @Published var isPowerSavingMode: Bool = false
    @Published var aiCuratedCardsVersion: Int = 0
    private(set) var lastAIAccessTimestamp: Date = Date()
    
    func touchAIAccess() {
        self.lastAIAccessTimestamp = Date()
        if self.isPowerSavingMode {
            self.isPowerSavingMode = false
            print("[AI Helper] User activity detected — exiting Power Saving Mode.")
            PhysicsStudyApp.startOllamaServer()
        }
    }
    
    let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300.0
        config.timeoutIntervalForResource = 600.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    
    let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 4.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    
    nonisolated static func normalizedOllamaURL(from rawHost: String?, defaultHost: String = "http://localhost:11434") -> URL? {
        let input = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var host = input.isEmpty ? defaultHost : input
        guard !host.isEmpty else { return nil }
        if !host.lowercased().hasPrefix("http://") && !host.lowercased().hasPrefix("https://") {
            host = "http://" + host
        }
        while host.hasSuffix("/") {
            host.removeLast()
        }
        if let url = URL(string: host), url.port == nil && !host.contains(":") {
            host = "\(host):11434"
        }
        return URL(string: host)
    }
    
    var baseURL: URL {
        let host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        return AIHelper.normalizedOllamaURL(from: host, defaultHost: "http://localhost:11434") ?? URL(string: "http://127.0.0.1:11434") ?? URL(fileURLWithPath: "/")
    }
    
    // Global AI Activity Indicator State
    nonisolated static func optimizeImageForOCR(_ image: NSImage, maxDimension: CGFloat = 800) -> String? {
        let origSize = image.size
        guard origSize.width > 0 && origSize.height > 0 else { return nil }
        
        let scale = min(1.0, min(maxDimension / origSize.width, maxDimension / origSize.height))
        let targetSize = NSSize(width: max(1, origSize.width * scale), height: max(1, origSize.height * scale))
        
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmapRep = rep else { return nil }
        
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = context
        
        let rect = NSRect(origin: .zero, size: targetSize)
        NSColor.white.setFill()
        rect.fill()
        
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        
        if let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            return jpegData.base64EncodedString()
        }
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            return pngData.base64EncodedString()
        }
        return nil
    }
    
    @Published var isAIBusy: Bool = false
    @Published var currentAITaskDescription: String = ""
    @Published var isCurrentAILocal: Bool = true
    @Published var currentAIProviderName: String = "Local AI"
    @Published var activeProgressCurrent: Int = 0
    @Published var activeProgressTotal: Int = 0
    @Published var activeProcessingNoteIds: Set<Int> = []
    
    // Disconnection & Error State
    let maxAutoReconnectAttempts: Int = 3
    @Published var isAIDisconnected: Bool = false
    @Published var disconnectionMessage: String = ""
    @Published var isRetryingConnection: Bool = false
    @Published var isAutoReconnecting: Bool = false
    @Published var autoReconnectAttempts: Int = 0
    @Published var autoReconnectExhausted: Bool = false
    @Published var isWaitingForRemoteConnection: Bool = false
    @Published var waitingTaskDescription: String = ""
    var pendingLocalFallbackOverride: Bool = false
    var cancelWaitingRemoteFlag: Bool = false
    var isRunningReconnectLoop: Bool = false
    var lastTailscaleTimeoutTime: Date? = nil
    let tailscaleCooldownSeconds: TimeInterval = 180.0
    
    var shouldFallbackToLocalWhenRemoteOffline: Bool {
        let policy = UserDefaults.standard.string(forKey: "hybrid_offline_policy") ?? "wait"
        return policy == "fallback"
    }
    
    func triggerFallbackToLocalForWaitingTasks() {
        self.pendingLocalFallbackOverride = true
        self.logToFile("[AI Helper LOG] User selected local fallback for paused remote task.")
    }
    
    func cancelWaitingTasks() {
        self.cancelWaitingRemoteFlag = true
        self.isWaitingForRemoteConnection = false
        self.waitingTaskDescription = ""
        self.logToFile("[AI Helper LOG] User cancelled paused remote task wait.")
    }
    
    // Tailscale Network Discovery State
    @Published var discoveredHosts: [DiscoveredAIHost] = []
    @Published var isScanningTailscale: Bool = false
    @Published var showTailscaleSetupModal: Bool = false
    
    // Hardware Engine & Machine Pipeline Status
    @Published var isRemoteOnline: Bool = false
    @Published var remoteStatusMessage: String = "Not Connected"
    var isPCOnline: Bool { isRemoteOnline }
    var pcStatusMessage: String { remoteStatusMessage }
    @Published var isLocalActive: Bool = false
    @Published var isRemoteActive: Bool = false
    
    @Published var localPagesTotal: Int = 0
    @Published var localPagesCompleted: Int = 0
    @Published var localTaskStatus: String = "Idle"
    
    @Published var remoteProblemsTotal: Int = 0
    @Published var remoteProblemsCompleted: Int = 0
    @Published var remoteTaskStatus: String = "Idle"
    
    @Published var pipelineCurrentPhase: String = "Idle"
    
    // Batch Importer Live Telemetry & Events
    @Published var batchTokensGenerated: Int = 0
    @Published var lastStreamingActivityDate: Date? = nil
    @Published var batchLiveEvents: [String] = []
    @Published var batchActiveSubtask: String = ""
    @Published var batchStartTime: Date? = nil
    @Published var isBatchImportActive: Bool = false
    @Published var cachedThinkingSupport: [String: Bool] = [:]
    
    var currentExtractionTask: Task<Void, Never>? = nil
    
    var isTailscaleInCooldown: Bool {
        guard let timeoutTime = lastTailscaleTimeoutTime else { return false }
        return Date().timeIntervalSince(timeoutTime) < tailscaleCooldownSeconds
    }
    
    var tailscaleCooldownRemainingSeconds: Int {
        guard let timeoutTime = lastTailscaleTimeoutTime else { return 0 }
        let remaining = Int(tailscaleCooldownSeconds - Date().timeIntervalSince(timeoutTime))
        return max(0, remaining)
    }
    
    func addBatchLiveEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        let entry = "[\(timeStr)] \(message)"
        DispatchQueue.main.async {
            self.batchLiveEvents.append(entry)
            if self.batchLiveEvents.count > 40 {
                self.batchLiveEvents.removeFirst(self.batchLiveEvents.count - 40)
            }
        }
    }
    
    @MainActor
    func cancelExtractionQueue() {
        self.extractionQueue.removeAll()
        self.currentExtractionTask?.cancel()
        self.currentExtractionTask = nil
        self.cancelWaitingRemoteFlag = true
        self.isWaitingForRemoteConnection = false
        self.waitingTaskDescription = ""
        self.isProcessingExtractionQueue = false
        self.isClassifyingProblems = false
        self.isBatchImportActive = false
        self.pipelineCurrentPhase = "Cancelled"
        self.localTaskStatus = "Cancelled"
        self.remoteTaskStatus = "Cancelled"
        self.isLocalActive = false
        self.isRemoteActive = false
        self.addBatchLiveEvent("Batch extraction cancelled by user.")
    }
    
    func isModelThinkingCapable(_ modelName: String) -> Bool {
        let lower = modelName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return false }
        
        // Vision models generally do not support thinking flags in Ollama
        if lower.contains("-vl") || lower.contains("vision") || lower.contains("llava") || lower.contains("bakllava") || lower.contains("minicpm-v") {
            return false
        }
        
        // Check dynamic cache if probed via /api/show
        if let cached = cachedThinkingSupport[lower] {
            return cached
        }
        
        // Known thinking / reasoning model families (DeepSeek-R1, QwQ, Qwen3 text)
        if lower.contains("r1") || lower.contains("qwq") || lower.contains("qwen3") || lower.contains("think") || lower.contains("reason") {
            return true
        }
        
        return false
    }
    
    func probeModelThinkingCapability(model: String, host: String) async {
        let lower = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return }
        if lower.contains("-vl") || lower.contains("vision") {
            await MainActor.run { self.cachedThinkingSupport[lower] = false }
            return
        }
        guard let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "http://localhost:11434") else { return }
        let url = baseURL.appendingPathComponent("api/show")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 3.0
        struct ShowReq: Codable { let name: String }
        struct ShowResp: Codable { let template: String?; let parameters: String? }
        do {
            req.httpBody = try JSONEncoder().encode(ShowReq(name: model))
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                let showObj = try JSONDecoder().decode(ShowResp.self, from: data)
                let tmpl = showObj.template ?? ""
                let params = showObj.parameters ?? ""
                let supports = tmpl.contains("<think>") || tmpl.contains(".Thinking") || tmpl.contains("thinking") || params.contains("think")
                await MainActor.run {
                    self.cachedThinkingSupport[lower] = supports || lower.contains("r1") || lower.contains("qwq") || lower.contains("qwen3")
                }
            }
        } catch {
            // Keep default heuristic
        }
    }
    
    var localPagesRemaining: Int {
        max(0, localPagesTotal - localPagesCompleted)
    }
    
    var remoteProblemsRemaining: Int {
        max(0, remoteProblemsTotal - remoteProblemsCompleted)
    }
    
    var isPipelineActive: Bool {
        isLocalActive || isRemoteActive || (localPagesTotal > 0 && localPagesRemaining > 0) || (remoteProblemsTotal > 0 && remoteProblemsRemaining > 0)
    }
    
    func isProcessingNote(id: Int) -> Bool {
        return activeProcessingNoteIds.contains(id)
    }
    
    func retryConnectionAndQueue() {
        guard !isRetryingConnection && !isRunningReconnectLoop else { return }
        self.isRetryingConnection = true
        self.autoReconnectExhausted = false
        self.autoReconnectAttempts = 0
        self.lastTailscaleTimeoutTime = nil
        
        Task {
            let reconnected = await self.attemptAutoReconnect(manualRetry: true)
            await MainActor.run {
                self.isRetryingConnection = false
                if reconnected || self.isLocalOnlyMode {
                    self.isAIDisconnected = false
                    self.disconnectionMessage = ""
                    self.autoReconnectExhausted = false
                    self.autoReconnectAttempts = 0
                    if !self.isWaitingForRemoteConnection {
                        self.finishAITask(force: true)
                    }
                } else {
                    self.isAIDisconnected = true
                    self.autoReconnectExhausted = true
                    self.disconnectionMessage = "\(self.remoteEngineName) Disconnected"
                    if !self.isWaitingForRemoteConnection {
                        self.isAIBusy = false
                        self.isProcessing = false
                        self.activeProcessingNoteIds.removeAll()
                    }
                }
            }
        }
    }
    
    var activeAIModel: String {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        if provider == "local" {
            return UserDefaults.standard.string(forKey: "local_model_general") ?? ""
        } else if provider == "tailscale" {
            return UserDefaults.standard.string(forKey: "tailscale_model_general") ?? ""
        } else {
            return UserDefaults.standard.string(forKey: "cloud_model_name") ?? ""
        }
    }
    
    func providerInfo(for providerKey: String, isVision: Bool = false) -> (isLocal: Bool, name: String) {
        let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
        if preset == "local_only" {
            return (true, "Local AI")
        }
        switch providerKey {
        case "local":
            let host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let url = URL(string: cleanHost)
            let hostName = url?.host?.lowercased() ?? "localhost"
            let isLocalHost = hostName == "localhost" || hostName == "127.0.0.1" || hostName == "::1" || hostName == "0.0.0.0"
            return (isLocalHost, isLocalHost ? "Local AI" : "Remote AI")
        case "tailscale":
            let hostKey = isVision ? "vision_tailscale_host" : "tailscale_host"
            var host = UserDefaults.standard.string(forKey: hostKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if host.isEmpty {
                host = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if let url = URL(string: host), let h = url.host?.lowercased(), (h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "0.0.0.0") {
                return (true, "Local AI")
            }
            return (false, "Tailscale AI")
        case "hermes":
            return (false, "Hermes (Custom Endpoint)")
        case "groq":
            return (false, "Groq AI")
        case "openai":
            return (false, "OpenAI")
        case "anthropic":
            return (false, "Anthropic")
        case "gemini":
            return (false, "Gemini")
        case "cloud":
            return (false, "Cloud AI")
        default:
            return (false, providerKey.capitalized + " AI")
        }
    }
    
    var remoteEngineName: String {
        let remoteProv = UserDefaults.standard.string(forKey: "remote_provider") ?? "tailscale"
        if remoteProv == "local" || remoteProv == "tailscale" {
            return "Tailscale AI"
        }
        return providerInfo(for: remoteProv).name
    }
    
    var isLocalOnlyMode: Bool {
        let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
        if preset == "local_only" { return true }
        let aiProv = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let visProv = UserDefaults.standard.string(forKey: "vision_provider") ?? aiProv
        return aiProv == "local" && visProv == "local"
    }
    
    var activeAIProvider: (isLocal: Bool, name: String) {
        if isLocalOnlyMode {
            return (true, "Local AI")
        }
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        if provider == "tailscale" {
            let tailHost = (UserDefaults.standard.string(forKey: "tailscale_host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if tailHost.isEmpty || (!isRemoteOnline && isTailscaleInCooldown && shouldFallbackToLocalWhenRemoteOffline) {
                return (true, "Local AI")
            }
        }
        return providerInfo(for: provider, isVision: false)
    }
    
    var activeVisionProvider: (isLocal: Bool, name: String) {
        let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
        if preset == "local_only" || preset == "hybrid_twotier" {
            return (true, "Local AI")
        }
        let provider = UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        return providerInfo(for: provider, isVision: true)
    }
    
    func updateActiveTaskProvider(provider: String? = nil, isVision: Bool = false, forceLocal: Bool = false, description: String? = nil) {
        let info: (isLocal: Bool, name: String)
        if forceLocal || isLocalOnlyMode {
            info = (true, "Local AI")
        } else if let prov = provider, !prov.isEmpty {
            info = providerInfo(for: prov, isVision: isVision)
        } else if isVision {
            info = self.activeVisionProvider
        } else {
            info = self.activeAIProvider
        }
        
        if let desc = description, !desc.isEmpty {
            self.currentAITaskDescription = desc
        }
        let taskDesc = self.currentAITaskDescription.isEmpty ? (description ?? "Processing AI Request...") : self.currentAITaskDescription
        
        self.isCurrentAILocal = info.isLocal
        self.currentAIProviderName = info.name
        
        if info.isLocal {
            self.isLocalActive = true
            if !self.isProcessingExtractionQueue {
                self.isRemoteActive = false
                self.pipelineCurrentPhase = "Local AI Active"
            }
            self.localTaskStatus = taskDesc
        } else {
            self.isRemoteActive = true
            if !self.isProcessingExtractionQueue {
                self.isLocalActive = false
                self.pipelineCurrentPhase = "\(info.name) Active"
            }
            self.remoteTaskStatus = taskDesc
        }
    }
    
    func startAITask(description: String, isVision: Bool = false, forceLocal: Bool = false, provider: String? = nil, current: Int = 0, total: Int = 0) {
        self.isAIBusy = true
        self.activeProgressTotal = total > 0 ? max(self.activeProgressTotal, total) : 0
        self.activeProgressCurrent = current > 0 ? current : 0
        updateActiveTaskProvider(provider: provider, isVision: isVision, forceLocal: forceLocal, description: description)
    }
    
    func finishAITask(force: Bool = false) {
        if force || self.activeProcessingNoteIds.isEmpty {
            self.isAIBusy = false
            self.currentAITaskDescription = ""
            self.activeProgressCurrent = 0
            self.activeProgressTotal = 0
            if !self.isProcessingExtractionQueue {
                self.isLocalActive = false
                self.isRemoteActive = false
                if self.pipelineCurrentPhase.contains("AI Active") {
                    self.pipelineCurrentPhase = "Idle"
                }
            }
        }
    }
    
    // Track processing thread states
    @Published var activeJobDescription: String = "Idle"
    @Published var isProcessing: Bool = false
    var awakeActivityToken: NSObjectProtocol? = nil
    var failedNoteTimes = [Int: Date]()
    
    // User request prioritization
    @Published var activeUserRequestsCount: Int = 0
    var currentBackgroundTask: Task<Void, Never>? = nil
    
    static var isStartingLocalOllama = false
    var isBackgroundProcessorStarted: Bool = false

    struct QueueItem {
        let content: String
        let solutionHint: String
        let moduleId: Int
        var solution: String
        var steps: [String]
    }
    
    var classificationQueue: [QueueItem] = []
    var isProcessingQueue: Bool = false
    
    @Published var classificationQueueCount: Int = 0
    @Published var classificationCompletedCount: Int = 0
    @Published var isClassifyingProblems: Bool = false
    @Published var queueStatusText: String = "Assigning Problems"
    
    // Unified extraction queue
    struct ExtractionQueueItem {
        enum ItemType {
            case pdf
            case image
        }
        let type: ItemType
        let pathOrName: String
        let imageBase64: String?
        let isAnswerSource: Bool
        let originalPdfPath: String?
    }
    struct ExtractionQueueGroupItem {
        let questionItem: ExtractionQueueItem
        let answerItems: [ExtractionQueueItem]
    }
    var extractionQueue: [ExtractionQueueGroupItem] = []
    @Published var isProcessingExtractionQueue: Bool = false
    
    @Published var sessionExtractedProblems: [ExtractedProblem] = []
    @Published var sessionExtractedAnswers: [ExtractedAnswer] = []

    nonisolated private static let logQueue = DispatchQueue(label: "com.projectnobel.ai.logfile", qos: .utility)
    nonisolated private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    nonisolated func logToFile(_ message: String) {
        print(message)
        let now = Date()
        Self.logQueue.async {
            let timestamp = Self.logDateFormatter.string(from: now)
            let logLine = "[\(timestamp)] \(message)\n"
            let appDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".physics_study_app")
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
            let logURL = appDir.appendingPathComponent("batch_importer_run.log")
            let logPath = logURL.path
            guard let data = logLine.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logPath) {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
                   let fileSize = attrs[.size] as? UInt64,
                   fileSize > 5_000_000 {
                    try? data.write(to: logURL)
                } else if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func sanitizeSavedProviderSettings() {
        let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
        let aiProv = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let visProv = UserDefaults.standard.string(forKey: "vision_provider") ?? "local"
        let remoteProv = UserDefaults.standard.string(forKey: "remote_provider") ?? "tailscale"
        let cloudKey = KeychainHelper.get(account: "cloud_api_key").trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudProviders = ["anthropic", "gemini", "openai", "groq", "cloud"]
        
        if preset == "local_only" || (aiProv == "local" && visProv == "local") {
            UserDefaults.standard.set("local", forKey: "ai_provider")
            UserDefaults.standard.set("local", forKey: "vision_provider")
            for k in ["route_vision", "route_stitching", "route_math", "route_steps", "route_matching", "route_classification", "route_translation", "route_feynman"] {
                UserDefaults.standard.set("local", forKey: k)
            }
        } else if preset == "hybrid_twotier" {
            UserDefaults.standard.set("local", forKey: "vision_provider")
            UserDefaults.standard.set("local", forKey: "route_vision")
            UserDefaults.standard.set("local", forKey: "route_translation")
            UserDefaults.standard.set("local", forKey: "route_feynman")
            if cloudProviders.contains(remoteProv) && cloudKey.isEmpty {
                UserDefaults.standard.set("tailscale", forKey: "remote_provider")
            }
            if cloudProviders.contains(aiProv) && cloudKey.isEmpty {
                let tailHost = (UserDefaults.standard.string(forKey: "tailscale_host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackTarget = tailHost.isEmpty ? "local" : "tailscale"
                UserDefaults.standard.set(fallbackTarget, forKey: "ai_provider")
                for k in ["route_stitching", "route_math", "route_steps", "route_matching", "route_classification"] {
                    UserDefaults.standard.set(fallbackTarget, forKey: k)
                }
            }
        } else if preset == "remote_only" && cloudProviders.contains(aiProv) && cloudKey.isEmpty {
            UserDefaults.standard.set("tailscale", forKey: "remote_provider")
            UserDefaults.standard.set("tailscale", forKey: "ai_provider")
            UserDefaults.standard.set("tailscale", forKey: "vision_provider")
        }
    }

    private init() {
        PhysicsStudyApp.migrateLegacyPreferencesIfNeeded()
        sanitizeSavedProviderSettings()
        startAutoReconnectMonitor()
        startEngineStatusMonitor()
    }
    
    func withUserPriority<T>(_ block: () async -> T) async -> T {
        await MainActor.run {
            self.touchAIAccess()
            self.activeUserRequestsCount += 1
            if let task = self.currentBackgroundTask {
                task.cancel()
                self.currentBackgroundTask = nil
                print("[AI Helper] Cancelled background task to prioritize user request.")
            }
        }
        defer {
            Task { @MainActor in
                self.activeUserRequestsCount = max(0, self.activeUserRequestsCount - 1)
            }
        }
        return await block()
    }
    
    func isNoteFailed(noteId: Int) -> Bool {
        if let failDate = failedNoteTimes[noteId] {
            return Date().timeIntervalSince(failDate) < 300 // Retry after 5 minutes
        }
        return false
    }
    
}
