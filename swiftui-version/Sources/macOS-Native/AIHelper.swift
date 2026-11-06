import Foundation
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
    
    var latexAlwaysLocal: Bool {
        if UserDefaults.standard.object(forKey: "latex_always_local") == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: "latex_always_local")
    }
    
    var feynmanAlwaysLocal: Bool {
        if UserDefaults.standard.object(forKey: "feynman_always_local") == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: "feynman_always_local")
    }
    
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
    
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300.0
        config.timeoutIntervalForResource = 600.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.2
        config.timeoutIntervalForResource = 1.2
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
    
    private var baseURL: URL {
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
    @Published var isAIDisconnected: Bool = false
    @Published var disconnectionMessage: String = ""
    @Published var isRetryingConnection: Bool = false
    @Published var isAutoReconnecting: Bool = false
    @Published var autoReconnectAttempts: Int = 0
    private var lastTailscaleTimeoutTime: Date? = nil
    private let tailscaleCooldownSeconds: TimeInterval = 180.0
    
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
    
    private var currentExtractionTask: Task<Void, Never>? = nil
    
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
        guard !isRetryingConnection else { return }
        Task { @MainActor in
            self.isRetryingConnection = true
        }
        Task {
            let reconnected = await self.attemptAutoReconnect()
            await MainActor.run {
                self.isRetryingConnection = false
                let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
                if reconnected || !self.isAIDisconnected {
                    self.isAIDisconnected = false
                    self.disconnectionMessage = ""
                    self.finishAITask(force: true)
                } else {
                    self.isAIDisconnected = true
                    if provider == "tailscale" {
                        self.disconnectionMessage = "Tailscale Disconnected"
                    } else if provider == "local" {
                        self.disconnectionMessage = "Ollama Server Offline"
                    } else {
                        let name = self.providerInfo(for: provider).name
                        self.disconnectionMessage = "\(name) Disconnected"
                    }
                    self.isAIBusy = false
                    self.isProcessing = false
                    self.activeProcessingNoteIds.removeAll()
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
        switch providerKey {
        case "local":
            let hostKey = (isVision && !(UserDefaults.standard.string(forKey: "vision_local_host") ?? "").isEmpty) ? "vision_local_host" : "local_host"
            let host = UserDefaults.standard.string(forKey: hostKey) ?? "http://localhost:11434"
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let url = URL(string: cleanHost)
            let hostName = url?.host?.lowercased() ?? "localhost"
            let isLocalHost = hostName == "localhost" || hostName == "127.0.0.1" || hostName == "::1" || hostName == "0.0.0.0"
            return (isLocalHost, isLocalHost ? "Local AI" : "Remote AI")
        case "tailscale":
            return (false, "Tailscale AI")
        case "hermes":
            return (false, "Hermes (GLM 5.2)")
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
    
    var activeAIProvider: (isLocal: Bool, name: String) {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        return providerInfo(for: provider, isVision: false)
    }
    
    var activeVisionProvider: (isLocal: Bool, name: String) {
        let provider = UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        return providerInfo(for: provider, isVision: true)
    }
    
    func startAITask(description: String, isVision: Bool = false, forceLocal: Bool = false, provider: String? = nil, current: Int = 0, total: Int = 0) {
        let info: (isLocal: Bool, name: String)
        if let prov = provider, !prov.isEmpty {
            info = providerInfo(for: prov, isVision: isVision)
        } else if forceLocal {
            info = (true, "Local AI")
        } else if isVision {
            info = self.activeVisionProvider
        } else {
            info = self.activeAIProvider
        }
        self.isAIBusy = true
        self.currentAITaskDescription = description
        self.isCurrentAILocal = info.isLocal
        self.currentAIProviderName = info.name
        self.activeProgressTotal = total > 0 ? max(self.activeProgressTotal, total) : 0
        self.activeProgressCurrent = current > 0 ? current : 0
        
        if info.isLocal {
            self.isLocalActive = true
            self.localTaskStatus = description
            if self.pipelineCurrentPhase == "Idle" || self.pipelineCurrentPhase.isEmpty {
                self.pipelineCurrentPhase = "Local AI Active"
            }
        } else {
            self.isRemoteActive = true
            self.remoteTaskStatus = description
            if self.pipelineCurrentPhase == "Idle" || self.pipelineCurrentPhase.isEmpty {
                self.pipelineCurrentPhase = "Tailscale AI Active"
            }
        }
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
    private var awakeActivityToken: NSObjectProtocol? = nil
    private var failedNoteTimes = [Int: Date]()
    
    // User request prioritization
    @Published var activeUserRequestsCount: Int = 0
    private var currentBackgroundTask: Task<Void, Never>? = nil
    
    // Queue implementation for sequential problem classification
    struct QueueItem {
        let content: String
        let solutionHint: String
        let moduleId: Int
        var solution: String
        var steps: [String]
    }
    
    private var classificationQueue: [QueueItem] = []
    private var isProcessingQueue: Bool = false
    
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
    private var extractionQueue: [ExtractionQueueGroupItem] = []
    @Published var isProcessingExtractionQueue: Bool = false
    
    @Published var sessionExtractedProblems: [ExtractedProblem] = []
    @Published var sessionExtractedAnswers: [ExtractedAnswer] = []
    
    func queueProblemForClassification(content: String, solutionHint: String, moduleId: Int, solution: String = "", steps: [String] = []) {
        let item = QueueItem(content: content, solutionHint: solutionHint, moduleId: moduleId, solution: solution, steps: steps)
        
        let info = self.activeAIProvider
        self.isCurrentAILocal = info.isLocal
        self.currentAIProviderName = info.name
        
        if !self.isClassifyingProblems {
            self.isClassifyingProblems = true
            self.classificationQueueCount = 0
            self.classificationCompletedCount = 0
        }
        self.queueStatusText = "Assigning Problems"
        self.classificationQueueCount += 1
        self.classificationQueue.append(item)
        
        self.processNextQueueItem()
    }
    
    private func processNextQueueItem() {
        guard !isProcessingQueue else { return }
        guard !classificationQueue.isEmpty else {
            // Queue is empty, reset state after a short delay so the progress bar is visible briefly
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.classificationQueue.isEmpty {
                    self.isClassifyingProblems = false
                    self.classificationQueueCount = 0
                    self.classificationCompletedCount = 0
                }
            }
            return
        }
        
        isProcessingQueue = true
        let item = classificationQueue.removeFirst()
        
        Task {
            // Fetch topics for context
            let topics = DatabaseManager.shared.getTopics(forModuleId: item.moduleId)
            
            // Call the AI model
            let suggestedWeek = await classifyProblemTopic(problemContent: item.content, moduleId: item.moduleId)
            
            var targetTopicId: Int? = nil
            if let week = suggestedWeek, week > 0 {
                if let existingTopic = topics.first(where: { $0.week == week }) {
                    targetTopicId = existingTopic.id
                } else {
                    targetTopicId = DatabaseManager.shared.getOrCreateTopic(
                        moduleId: item.moduleId,
                        week: week,
                        name: "Week \(week) Lecture"
                    )
                }
            }
            
            // Fallbacks
            if targetTopicId == nil {
                if let firstTopic = topics.first {
                    targetTopicId = firstTopic.id
                } else {
                    targetTopicId = DatabaseManager.shared.getOrCreateTopic(
                        moduleId: item.moduleId,
                        week: 1,
                        name: "General"
                    )
                }
            }
            
            // Generate solution with AI if empty
            var sol = item.solution
            if sol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sol = await generateProblemSolution(content: item.content)
            }
            
            // Generate steps with AI if empty
            var steps = item.steps
            if steps.isEmpty {
                steps = await generateProblemSteps(content: item.content, solution: sol)
            }
            
            let stepsStr: String
            if let data = try? JSONEncoder().encode(steps) {
                stepsStr = String(data: data, encoding: .utf8) ?? "[]"
            } else {
                stepsStr = "[]"
            }
            
            if let topicId = targetTopicId {
                _ = DatabaseManager.shared.addProblem(
                    topicId: topicId,
                    content: item.content,
                    hint: item.solutionHint,
                    solution: sol,
                    steps: stepsStr
                )
            }
            
            // Done with this item
            self.classificationCompletedCount += 1
            self.isProcessingQueue = false
            // Trigger next item
            self.processNextQueueItem()
        }
    }
    
    func normalizeFilename(_ filename: String) -> String {
        var name = filename.lowercased()
        let url = URL(fileURLWithPath: name)
        name = url.deletingPathExtension().lastPathComponent
        
        // Remove page indicator (e.g. "page 1 of ", "1 of ")
        if name.hasPrefix("page ") {
            name = name.replacingOccurrences(of: "page ", with: "")
        }
        let pageRegex = try? NSRegularExpression(pattern: "^\\d+\\s*(of|\\s)\\s*", options: [])
        if let regex = pageRegex {
            name = regex.stringByReplacingMatches(in: name, options: [], range: NSRange(location: 0, length: name.utf16.count), withTemplate: "")
        }
        
        let stopwords = ["questions", "question", "answers", "answer", "solutions", "solution", "sols", "sol", "pdf", "image", "pasted", "page"]
        for word in stopwords {
            name = name.replacingOccurrences(of: word, with: "")
        }
        
        // Remove course code (e.g. "5ccp9200" or similar 7-9 character course codes containing digits)
        let courseCodeRegex = try? NSRegularExpression(pattern: "\\b[a-z0-9]{4,9}\\b", options: [])
        if let regex = courseCodeRegex {
            let nsRange = NSRange(location: 0, length: name.utf16.count)
            let matches = regex.matches(in: name, options: [], range: nsRange)
            for match in matches.reversed() {
                if let range = Range(match.range, in: name) {
                    let token = String(name[range])
                    if token.contains(where: { $0.isLetter }) && token.contains(where: { $0.isNumber }) {
                        name.removeSubrange(range)
                    }
                }
            }
        }
        
        let allowedChars = CharacterSet.alphanumerics
        name = String(name.unicodeScalars.filter { allowedChars.contains($0) })
        return name
    }
    
    private func extractSheetNumber(_ filename: String) -> Int? {
        let lower = filename.lowercased()
        let pattern = "sheet[\\s_#-]*(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsRange = NSRange(location: 0, length: lower.utf16.count)
            if let match = regex.firstMatch(in: lower, options: [], range: nsRange),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: lower),
               let num = Int(lower[range]) {
                return num
            }
        }
        let normalized = normalizeFilename(filename)
        let digits = normalized.filter { $0.isNumber }
        if let lastDigit = digits.last, let num = Int(String(lastDigit)) {
            return num
        }
        return nil
    }

    func isAnswerFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        let keywords = ["sol", "solution", "solutions", "sols", "answer", "answers", "ans", "marking", "scheme", "key"]
        let url = URL(fileURLWithPath: lower)
        let base = url.deletingPathExtension().lastPathComponent
        let tokens = base.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return tokens.contains(where: { keywords.contains($0) }) || keywords.contains(where: { base.contains("_\($0)") || base.contains("-\($0)") || base.hasSuffix("\($0)") || base.hasPrefix("\($0)") })
    }

    func pairQuestionsAndAnswers(questions: [PendingExtractionItem], answers: [PendingExtractionItem]) -> [ExtractionGroup] {
        var allQuestions = [PendingExtractionItem]()
        var allAnswers = answers
        
        for q in questions {
            if isAnswerFilename(q.pathOrName) {
                if !allAnswers.contains(where: { $0.pathOrName == q.pathOrName }) {
                    allAnswers.append(q)
                }
            } else {
                allQuestions.append(q)
            }
        }
        
        // If all items were answer-named or all were regular, fallback so we don't end up with 0 questions
        if allQuestions.isEmpty {
            allQuestions = questions
        }
        
        var groups = [ExtractionGroup]()
        
        for q in allQuestions {
            var matchedAnswers = [PendingExtractionItem]()
            
            if allAnswers.isEmpty {
                // Self-referential: scan the same document for both questions and answers!
                matchedAnswers.append(q)
            } else {
                let qSheetNum = extractSheetNumber(q.pathOrName)
                for a in allAnswers {
                    let aSheetNum = extractSheetNumber(a.pathOrName)
                    if let qNum = qSheetNum, let aNum = aSheetNum {
                        if qNum == aNum {
                            matchedAnswers.append(a)
                        }
                    } else {
                        let qNorm = normalizeFilename(q.pathOrName)
                        let aNorm = normalizeFilename(a.pathOrName)
                        if aNorm == qNorm || aNorm.contains(qNorm) || qNorm.contains(aNorm) {
                            matchedAnswers.append(a)
                        }
                    }
                }
                if matchedAnswers.isEmpty {
                    // Fallback: also scan the question document itself for embedded answers!
                    matchedAnswers.append(q)
                }
            }
            groups.append(ExtractionGroup(questionItem: q, answerItems: matchedAnswers))
        }
        return groups
    }
    
    func queueGroupsForExtraction(groups: [ExtractionGroup]) {
        self.sessionExtractedProblems = []
        self.sessionExtractedAnswers = []
        
        let hasImages = groups.contains { g in
            g.questionItem.type == .image || g.answerItems.contains(where: { $0.type == .image })
        }
        let info = hasImages ? self.activeVisionProvider : self.activeAIProvider
        self.isCurrentAILocal = info.isLocal
        self.currentAIProviderName = info.name
        
        if !self.isClassifyingProblems {
            self.isClassifyingProblems = true
            self.classificationQueueCount = 0
            self.classificationCompletedCount = 0
        }
        
        self.queueStatusText = "Extracting Problems..."
        
        // Count exact unique document items to display accurate 1 of N progress!
        var uniqueItems = 0
        for g in groups {
            uniqueItems += 1
            for a in g.answerItems {
                if a.pathOrName != g.questionItem.pathOrName {
                    uniqueItems += 1
                }
            }
        }
        self.classificationQueueCount += uniqueItems
        
        // Calculate total pages for local OCR processing
        var totalPages = 0
        for g in groups {
            if g.questionItem.type == .pdf {
                if let pdf = PDFDocument(url: URL(fileURLWithPath: g.questionItem.pathOrName)) {
                    totalPages += pdf.pageCount
                } else {
                    totalPages += 1
                }
            } else {
                totalPages += 1
            }
            for a in g.answerItems {
                if a.pathOrName != g.questionItem.pathOrName {
                    if a.type == .pdf {
                        if let pdf = PDFDocument(url: URL(fileURLWithPath: a.pathOrName)) {
                            totalPages += pdf.pageCount
                        } else {
                            totalPages += 1
                        }
                    } else {
                        totalPages += 1
                    }
                }
            }
        }
        self.localPagesTotal = max(1, totalPages)
        self.localPagesCompleted = 0
        self.localTaskStatus = "Starting OCR (\(self.localPagesTotal) pages)..."
        self.remoteProblemsTotal = 0
        self.remoteProblemsCompleted = 0
        self.remoteTaskStatus = "Queued (waiting for OCR)"
        self.pipelineCurrentPhase = "Phase 1/2: Local OCR"
        self.isLocalActive = true
        self.isRemoteActive = false
        self.batchTokensGenerated = 0
        self.batchStartTime = Date()
        self.isBatchImportActive = true
        self.addBatchLiveEvent("Batch import started: \(groups.count) document groups queued (\(self.localPagesTotal) pages).")
        
        self.logToFile("[AI Batch Importer LOG] Queued \(groups.count) extraction groups (\(self.localPagesTotal) total pages). Clear session state completed.")
        for g in groups {
            let qType: ExtractionQueueItem.ItemType = (g.questionItem.type == .pdf) ? .pdf : .image
            let qItem = ExtractionQueueItem(type: qType, pathOrName: g.questionItem.pathOrName, imageBase64: g.questionItem.imageBase64, isAnswerSource: false, originalPdfPath: g.questionItem.originalPdfPath)
            
            var aItems = [ExtractionQueueItem]()
            for ans in g.answerItems {
                // Only queue separate answer files (skip duplicate pass on the question document itself)
                if ans.pathOrName != g.questionItem.pathOrName {
                    let aType: ExtractionQueueItem.ItemType = (ans.type == .pdf) ? .pdf : .image
                    let aItem = ExtractionQueueItem(type: aType, pathOrName: ans.pathOrName, imageBase64: ans.imageBase64, isAnswerSource: true, originalPdfPath: ans.originalPdfPath)
                    aItems.append(aItem)
                }
            }
            
            let groupItem = ExtractionQueueGroupItem(questionItem: qItem, answerItems: aItems)
            self.extractionQueue.append(groupItem)
        }
        
        self.processNextExtractionQueueItem()
    }
    
    private func processNextExtractionQueueItem() {
        guard !isProcessingExtractionQueue else { return }
        guard !extractionQueue.isEmpty else {
            if classificationCompletedCount >= classificationQueueCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.extractionQueue.isEmpty && self.classificationQueue.isEmpty {
                        self.isClassifyingProblems = false
                        self.isBatchImportActive = false
                        self.classificationQueueCount = 0
                        self.classificationCompletedCount = 0
                        self.queueStatusText = "Assigning Problems"
                        self.localPagesTotal = 0
                        self.localPagesCompleted = 0
                        self.remoteProblemsTotal = 0
                        self.remoteProblemsCompleted = 0
                        self.localTaskStatus = "Idle"
                        self.remoteTaskStatus = "Idle"
                        self.pipelineCurrentPhase = "Idle"
                        self.isLocalActive = false
                        self.isRemoteActive = false
                    }
                }
            }
            return
        }
        
        isProcessingExtractionQueue = true
        let group = extractionQueue.removeFirst()
        
        self.currentExtractionTask = Task {
            let startGroupTime = Date()
            var extractedQuestions = [ExtractedProblem]()
            var extractedAnswers = [ExtractedAnswer]()
            
            // 1. Extract Questions via local visual transcription
            let qItem = group.questionItem
            self.addBatchLiveEvent("Starting extraction for question document: \(qItem.pathOrName.components(separatedBy: "/").last ?? qItem.pathOrName)")
            self.logToFile("[AI Batch Importer LOG] --------------------------------------------------")
            self.logToFile("[AI Batch Importer LOG] Starting extraction for group question item: \(qItem.pathOrName)")
            
            let startQExtract = Date()
            extractedQuestions = await self.extractProblemsUnified(item: qItem)
            let endQExtract = Date().timeIntervalSince(startQExtract)
            self.logToFile("[AI Batch Importer LOG] Parsed \(extractedQuestions.count) individual questions from group question item. (Took \(String(format: "%.2f", endQExtract))s)")
            
            self.classificationCompletedCount += 1 // Increment for question task
            
            // 2. Extract Answers (if any) via local visual transcription
            var endAExtract: TimeInterval = 0.0
            var endMatch: TimeInterval = 0.0
            
            if !group.answerItems.isEmpty {
                let startAExtract = Date()
                self.logToFile("[AI Batch Importer LOG] Starting answer extraction for \(group.answerItems.count) answer items.")
                
                for aItem in group.answerItems {
                    self.logToFile("[AI Batch Importer LOG] Starting answer extraction for group answer item: \(aItem.pathOrName)")
                    let fileAnswers = await self.extractAnswersUnified(item: aItem)
                    extractedAnswers.append(contentsOf: fileAnswers)
                    self.sessionExtractedAnswers.append(contentsOf: fileAnswers)
                    self.classificationCompletedCount += 1
                }
                extractedAnswers = self.deduplicateExtractedAnswers(extractedAnswers)
                self.sessionExtractedAnswers = self.deduplicateExtractedAnswers(self.sessionExtractedAnswers)
                
                endAExtract = Date().timeIntervalSince(startAExtract)
                self.logToFile("[AI Batch Importer LOG] Answer extraction completed. Parsed \(extractedAnswers.count) deduplicated answers. (Took \(String(format: "%.2f", endAExtract))s)")
            }
            
            // Phase 1 (Local Visual OCR) is now 100% complete for all documents in this group
            await MainActor.run {
                self.localPagesCompleted = self.localPagesTotal
                self.localTaskStatus = "Done (\(self.localPagesTotal) pages OCR'd)"
                self.isLocalActive = false
                self.remoteProblemsTotal = max(self.remoteProblemsTotal, extractedQuestions.count)
                self.remoteProblemsCompleted = 0
                self.remoteTaskStatus = "Queued (\(extractedQuestions.count) problems)"
                self.pipelineCurrentPhase = "Phase 2/2: Tailscale Derivations"
                self.isRemoteActive = true
            }
            
            // 3. Fast match answers to questions and attach steps on Remote Engine BEFORE displaying on screen
            let startMatch = Date()
            if !extractedAnswers.isEmpty && !extractedQuestions.isEmpty {
                var solvedCount = 0
                // Match by sequential monotonic partitioning heuristic (preserving order and subpart hierarchy)
                var assignedAnswers: [Int: [ExtractedAnswer]] = [:]
                var currentProblemNum = 1
                var seenSubparts: [String] = []

                let p1Pattern = #"^\s*(?:Problem|Question|Exercise|Task|Part)?\s*(?:\(?1\)?|\(?a\)?|1a)(?:\b|[:.\)\-]|$)"#
                let lateSubpartPattern = #"(?:\(?[cd]\)?|\b[34]\b|Problem\s+d)"#

                func expectedMaxSubpart(for questionContent: String) -> String? {
                    let subs = self.extractQuestionSubparts(questionContent)
                    if let last = subs.last?.subpart {
                        return last.trimmingCharacters(in: CharacterSet(charactersIn: "() \t")).lowercased()
                    }
                    return nil
                }

                func extractSubpartFromLabel(_ label: String) -> String? {
                    let p = #"(?:^|\s|\(|\d+)([a-j])(?:\)|\.|\s|$)"#
                    guard let reg = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return nil }
                    let ns = label as NSString
                    if let m = reg.firstMatch(in: label, options: [], range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                        return ns.substring(with: m.range(at: 1)).lowercased()
                    }
                    return nil
                }

                let maxSubparts = extractedQuestions.map { expectedMaxSubpart(for: $0.content) }

                for (ansIdx, ans) in extractedAnswers.enumerated() {
                    var rawNum = self.extractProblemNumberFromLabel(ans.label)
                    
                    // Don't let a generic "Problem 1" header pull us back if we have already progressed past Problem 1
                    if rawNum == 1 && currentProblemNum > 1 {
                        rawNum = nil
                    }
                    
                    // Guard against handwritten '(c)' misread as 'Problem 3' right before the actual 'Problem 3 (a)'
                    if let num = rawNum, num == currentProblemNum + 1, extractSubpartFromLabel(ans.label) == nil, ansIdx + 1 < extractedAnswers.count {
                        let nextAns = extractedAnswers[ansIdx + 1]
                        if self.extractProblemNumberFromLabel(nextAns.label) == num && extractSubpartFromLabel(nextAns.label) == "a" {
                            rawNum = nil
                        }
                    }

                    if let num = rawNum, num > currentProblemNum && num <= extractedQuestions.count {
                        currentProblemNum = num
                        seenSubparts = [ans.label]
                    } else {
                        let maxExpected = (currentProblemNum <= maxSubparts.count) ? maxSubparts[currentProblemNum - 1] : nil
                        var hasSeenMax = false
                        if let maxExp = maxExpected {
                            for s in seenSubparts {
                                if let sp = extractSubpartFromLabel(s), sp >= maxExp {
                                    hasSeenMax = true
                                    break
                                }
                            }
                        }

                        if hasSeenMax && (rawNum == nil || rawNum != currentProblemNum) && (currentProblemNum + 1) <= extractedQuestions.count {
                            // Before advancing on an unnumbered continuation block after maxExpected, check if it still belongs to the final subpart of currentProblemNum
                            var staysWithCurrent = false
                            if rawNum == nil && extractSubpartFromLabel(ans.label) == nil {
                                let curOverlap = self.answerOverlapScore(ans, withQuestion: extractedQuestions[currentProblemNum - 1].content)
                                let nextOverlap = self.answerOverlapScore(ans, withQuestion: extractedQuestions[currentProblemNum].content)
                                if curOverlap > nextOverlap && curOverlap >= 2 {
                                    staysWithCurrent = true
                                }
                            }
                            if staysWithCurrent {
                                seenSubparts.append(ans.label)
                            } else {
                                currentProblemNum += 1
                                seenSubparts = [ans.label]
                            }
                        } else {
                            let isPart1 = ans.label.range(of: p1Pattern, options: [.regularExpression, .caseInsensitive]) != nil
                            let hasLateSubpart = seenSubparts.contains { prev in
                                prev.range(of: lateSubpartPattern, options: [.regularExpression, .caseInsensitive]) != nil
                            }
                            
                            if isPart1 && hasLateSubpart && (currentProblemNum + 1) <= extractedQuestions.count {
                                currentProblemNum += 1
                                seenSubparts = [ans.label]
                            } else {
                                seenSubparts.append(ans.label)
                            }
                        }
                    }
                    
                    let targetQ = min(max(currentProblemNum, 1), extractedQuestions.count)
                    assignedAnswers[targetQ, default: []].append(ans)
                }

                for i in 0..<extractedQuestions.count {
                    if extractedQuestions[i].solution.isEmpty {
                        let qTargetNum = i + 1
                        let matchingAnswers = self.deduplicateExtractedAnswers(assignedAnswers[qTargetNum] ?? [])
                        
                        if !matchingAnswers.isEmpty {
                            await MainActor.run {
                                self.isRemoteActive = true
                                self.remoteTaskStatus = "Deriving Question \(i + 1) of \(extractedQuestions.count)"
                                self.pipelineCurrentPhase = "Phase 2/2: Deriving Solutions"
                            }
                            let combinedSolution = matchingAnswers.map { ans in
                                if matchingAnswers.count > 1 {
                                    return "### \(ans.label)\n\(ans.content)"
                                } else {
                                    return ans.content
                                }
                            }.joined(separator: "\n\n")
                            
                            extractedQuestions[i].solution = sanitizeLaTeX(combinedSolution)
                            self.logToFile("[AI Batch Importer LOG] Generating pedagogical multi-step solution for Question \(i + 1) [matched \(matchingAnswers.count) segments for Problem \(qTargetNum)]...")
                            let aiSteps = await self.generateStepsFromAnswer(question: extractedQuestions[i].content, answer: combinedSolution, problemNumber: qTargetNum)
                            if !aiSteps.isEmpty {
                                extractedQuestions[i].steps = aiSteps
                            } else {
                                let fallbackSteps = self.splitSolutionIntoSteps(combinedSolution)
                                extractedQuestions[i].steps = !fallbackSteps.isEmpty ? fallbackSteps : [combinedSolution]
                            }
                            solvedCount += 1
                            await MainActor.run {
                                self.remoteProblemsCompleted = solvedCount
                            }
                            self.logToFile("[AI Batch Importer LOG] Attached answer for Question \(i + 1) (\(extractedQuestions[i].steps.count) steps)")
                        }
                    }
                }
                
                // Fallback to semantic matching for any remaining unassigned questions
                let stillUnassigned = extractedQuestions.enumerated().filter { $0.element.solution.isEmpty }
                if !stillUnassigned.isEmpty {
                    await MainActor.run {
                        self.isRemoteActive = true
                        self.remoteTaskStatus = "Matching \(stillUnassigned.count) questions..."
                        self.pipelineCurrentPhase = "Phase 2/2: Semantic Matching"
                    }
                    let unassignedQs = stillUnassigned.map { $0.element }
                    let matched = await self.matchQuestionsAndAnswers(questions: unassignedQs, answers: extractedAnswers)
                    for matchedQ in matched {
                        if let idx = extractedQuestions.firstIndex(where: { $0.id == matchedQ.id || $0.content == matchedQ.content }) {
                            if !matchedQ.solution.isEmpty {
                                await MainActor.run {
                                    self.isRemoteActive = true
                                    self.remoteTaskStatus = "Deriving Question \(idx + 1) of \(extractedQuestions.count)"
                                }
                                extractedQuestions[idx].solution = matchedQ.solution
                                let aiSteps = await self.generateStepsFromAnswer(question: extractedQuestions[idx].content, answer: matchedQ.solution, problemNumber: idx + 1)
                                if !aiSteps.isEmpty {
                                    extractedQuestions[idx].steps = aiSteps
                                } else {
                                    extractedQuestions[idx].steps = !matchedQ.steps.isEmpty ? matchedQ.steps : [matchedQ.solution]
                                }
                                solvedCount += 1
                                await MainActor.run {
                                    self.remoteProblemsCompleted = solvedCount
                                }
                            }
                        }
                    }
                }
                
                // For any questions that still have NO matching solution in the answer key:
                // Derive complete pedagogical solution and steps directly from first principles!
                for i in 0..<extractedQuestions.count {
                    if extractedQuestions[i].solution.isEmpty {
                        await MainActor.run {
                            self.isRemoteActive = true
                            self.remoteTaskStatus = "Deriving Question \(i + 1) from first principles..."
                            self.pipelineCurrentPhase = "Phase 2/2: Deriving Solutions"
                        }
                        self.logToFile("[AI Batch Importer LOG] Question \(i + 1) has no answer key in solution document. Deriving complete solution and steps from first principles...")
                        let (derivedSol, derivedSteps) = await self.deriveSolutionAndSteps(question: extractedQuestions[i].content)
                        if !derivedSol.isEmpty {
                            extractedQuestions[i].solution = derivedSol
                            extractedQuestions[i].steps = derivedSteps
                            solvedCount += 1
                            await MainActor.run {
                                self.remoteProblemsCompleted = solvedCount
                            }
                            self.logToFile("[AI Batch Importer LOG] Successfully derived first-principles solution for Question \(i + 1) (\(derivedSteps.count) steps).")
                        }
                    }
                }
                
                endMatch = Date().timeIntervalSince(startMatch)
            }
            
            // 4. Output questions to screen (with their steps already populated if solutions exist)
            for i in 0..<extractedQuestions.count {
                extractedQuestions[i].content = sanitizeLaTeX(extractedQuestions[i].content)
                extractedQuestions[i].solutionHint = sanitizeLaTeX(extractedQuestions[i].solutionHint)
                extractedQuestions[i].solution = sanitizeLaTeX(extractedQuestions[i].solution)
                extractedQuestions[i].steps = extractedQuestions[i].steps.map { s in
                    var cleaned = s.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
                    cleaned = cleaned.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
                    return sanitizeLaTeX(cleaned)
                }
            }
            self.sessionExtractedProblems.append(contentsOf: extractedQuestions)
            self.sanitizeSessionExtractedProblems()
            self.logToFile("[AI Batch Importer LOG] Appended \(extractedQuestions.count) questions (with steps if available) to session list.")
            self.addBatchLiveEvent("Successfully processed \(extractedQuestions.count) practice problems with step-by-step breakdowns.")
            
            await MainActor.run {
                self.isRemoteActive = false
                self.remoteProblemsCompleted = extractedQuestions.count
                self.remoteTaskStatus = "Done (\(extractedQuestions.count) problems)"
                self.pipelineCurrentPhase = "All Problems Ready"
                if self.extractionQueue.isEmpty {
                    self.isBatchImportActive = false
                }
            }
            
            let totalGroupTime = Date().timeIntervalSince(startGroupTime)
            self.logToFile("[AI Batch Importer LOG] ==================================================")
            self.logToFile("[AI Batch Importer LOG] GROUP RUN TIMING REPORT SUMMARY:")
            self.logToFile("[AI Batch Importer LOG] Question Extraction:  \(String(format: "%.2f", endQExtract))s")
            self.logToFile("[AI Batch Importer LOG] Answer Extraction:    \(String(format: "%.2f", endAExtract))s")
            self.logToFile("[AI Batch Importer LOG] Matching:             \(String(format: "%.2f", endMatch))s")
            self.logToFile("[AI Batch Importer LOG] Total Processing Time: \(String(format: "%.2f", totalGroupTime))s")
            self.logToFile("[AI Batch Importer LOG] ==================================================")
            
            self.isProcessingExtractionQueue = false
            self.processNextExtractionQueueItem()
        }
    }
    
    // MARK: - Answer extraction and matching helpers
    
    struct ExtractedAnswer: Codable {
        let label: String
        let content: String
    }
    
    nonisolated func normalizeLaTeXDelimiters(_ text: String) -> String {
        var result = convertTabularToArray(text)
        result = result.replacingOccurrences(of: "\\[", with: "$$")
        result = result.replacingOccurrences(of: "\\]", with: "$$")
        result = result.replacingOccurrences(of: "\\(", with: "$")
        result = result.replacingOccurrences(of: "\\)", with: "$")
        return result
    }

    func sanitizeSessionExtractedProblems() {
        for i in 0..<sessionExtractedProblems.count {
            sessionExtractedProblems[i].content = sanitizeLaTeX(sessionExtractedProblems[i].content)
            sessionExtractedProblems[i].solutionHint = sanitizeLaTeX(sessionExtractedProblems[i].solutionHint)
            sessionExtractedProblems[i].solution = sanitizeLaTeX(sessionExtractedProblems[i].solution)
            sessionExtractedProblems[i].steps = sessionExtractedProblems[i].steps.map { s in
                var cleaned = s.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
                cleaned = cleaned.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
                return sanitizeLaTeX(cleaned)
            }
        }
    }

    func taskProvider(for key: String, isVision: Bool = false, defaultProvider: String? = nil) -> String {
        let globalActive = isVision ?
            (UserDefaults.standard.string(forKey: "vision_provider") ?? UserDefaults.standard.string(forKey: "ai_provider") ?? "local") :
            (UserDefaults.standard.string(forKey: "ai_provider") ?? "tailscale")
        
        let isCloud = ["openai", "anthropic", "gemini", "groq", "hermes", "cloud"].contains(globalActive)

        if let val = UserDefaults.standard.string(forKey: key), !val.isEmpty {
            if val == "cloud" {
                return globalActive
            }
            if isCloud && val == "tailscale" {
                return globalActive
            }
            return val
        }
        
        if isCloud {
            return globalActive
        }
        
        if let def = defaultProvider {
            return def
        }
        return globalActive
    }

    func isTaskLocal(_ key: String, defaultLocal: Bool = false) -> Bool {
        let prov = taskProvider(for: key, defaultProvider: defaultLocal ? "local" : "tailscale")
        return prov == "local"
    }

    func extractAnswers(fromText text: String) async -> String? {
        await withUserPriority {
            let provider = taskProvider(for: "route_math", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            let prompt = """
            You are a physics teaching assistant. Analyze the following text containing worked physics solutions or an answer key:
            ---
            \(text)
            ---
            Extract each distinct solution or answer found on this page.
            
            Rules:
            1. Keep the complete mathematical derivation, working steps, and final equations intact.
            2. Wrap all math formulas, variables, and math symbols in standard single dollar signs ($...$) for inline math, and double dollar signs ($$...$$) on separate lines for block equations.
            3. Label each answer clearly with its question number/letter if visible (e.g. 'Problem 1', 'Question 1 (i)', 'Problem 2').
            
            Format strictly as follows:
            [ANSWER]
            Label: <Question number or identifier, e.g. 'Problem 1'>
            Content: <full solution text, derivations, and final equations with math in dollar signs>
            [ANSWER]
            
            Output ONLY the [ANSWER] blocks with no introductory text or conversational filler.
            """
            return await callOllama(prompt: prompt, model: model, timeout: 120.0, overrideProvider: provider)
        }
    }
    
    func extractAnswersFromImage(base64Image: String) async -> String? {
        await withUserPriority {
            let provider = taskProvider(for: "route_vision", isVision: true, defaultProvider: "local")
            guard let visionModel = await getOllamaVisionModel(forceLocal: provider == "local") else { return "MODEL_NOT_FOUND" }
            let prompt = """
            You are a physics teaching assistant. Analyze this image containing solutions, answers, or an answer key.
            Extract and list all individual answers or solutions from the image.
            For each answer/solution:
            1. Keep the full mathematical derivations, calculations, intermediate steps, and final formulas intact.
            2. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            3. CRITICAL: If the top of the page starts with a continuation of an earlier problem or an unlabelled subpart (e.g. '(c)', 'c)', '(d)', or a formula continuing from a previous page before a new problem header begins), you MUST extract it as its own separate [ANSWER] block. Label it with the subpart or continuation (e.g. 'Part (c)' or 'Problem Continuation'). Never ignore or drop calculations at the top of a page.
            
            Format the output strictly as follows:
            [ANSWER]
            Label: <e.g. 'Problem 1', 'Question 2 (i)', 'Part (c)', or briefly summarize what the answer is about if no label exists>
            Content: <the full answer text, steps, or final answer code, with equations wrapped in dollar signs>
            [ANSWER]
            
            Do NOT include any introduction, explanations, or conversational filler. Output only the structured list.
            """
            return await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 180.0, overrideProvider: provider)
        }
    }
    
    nonisolated func deduplicateExtractedAnswers(_ answers: [ExtractedAnswer]) -> [ExtractedAnswer] {
        var uniqueAnswers = [ExtractedAnswer]()
        var seenFingerprints = Set<String>()
        
        for ans in answers {
            let norm = ans.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if norm.isEmpty { continue }
            
            // Build invariant fingerprint by stripping whitespace and non-alphanumeric math
            let fingerprint = norm.components(separatedBy: CharacterSet.whitespacesAndNewlines).joined()
            if seenFingerprints.contains(fingerprint) {
                continue
            }
            
            // Check for near-identical duplicate against the last added answer (e.g. repeated OCR loops)
            if let last = uniqueAnswers.last {
                let lastNorm = last.content.components(separatedBy: CharacterSet.whitespacesAndNewlines).joined()
                if lastNorm == fingerprint || (fingerprint.count > 40 && lastNorm.contains(fingerprint.prefix(80))) {
                    continue
                }
            }
            
            seenFingerprints.insert(fingerprint)
            uniqueAnswers.append(ans)
        }
        return uniqueAnswers
    }
    
    nonisolated func answerOverlapScore(_ answer: ExtractedAnswer, withQuestion question: String) -> Int {
        let qTokens = Set(question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
        let aTokens = answer.content.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
        var score = 0
        for token in aTokens {
            if qTokens.contains(token) {
                score += 1
            }
        }
        return score
    }

    nonisolated func parseExtractedAnswers(_ text: String) -> [ExtractedAnswer] {
        var answers: [ExtractedAnswer] = []
        var strippedText = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        strippedText = strippedText.replacingOccurrences(of: #"(?i)\[/ANSWER\]"#, with: "[ANSWER]", options: .regularExpression)
        let normalizedText = normalizeLaTeXDelimiters(strippedText)
        let blocks = normalizedText.components(separatedBy: "[ANSWER]")
        
        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var labelText = ""
            var contentText = ""
            var isReadingContent = false
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                let lower = trimmed.lowercased()
                
                if lower.starts(with: "label:") || (lower.contains("label:") && !isReadingContent) {
                    isReadingContent = false
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        labelText = val
                    }
                } else if lower.starts(with: "content:") || (lower.contains("content:") && !isReadingContent) {
                    isReadingContent = true
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        contentText = val
                    }
                } else {
                    if isReadingContent {
                        if !contentText.isEmpty { contentText += "\n" }
                        contentText += line
                    } else {
                        if !labelText.isEmpty { labelText += " " }
                        labelText += trimmed
                    }
                }
            }
            
            let finalLabel = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalContent = contentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalContent.isEmpty {
                answers.append(ExtractedAnswer(label: finalLabel, content: normalizeLaTeXDelimiters(finalContent)))
            }
        }
        return deduplicateExtractedAnswers(answers)
    }
    
    nonisolated func extractQuestionSubparts(_ question: String) -> [(subpart: String, content: String)] {
        let normalized = normalizeLaTeXDelimiters(question).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return [] }
        
        // Strict line-start pattern for question subparts: (a), a), (i), i)
        // Must be preceded by start of line and followed by space + letter/number/math
        let pattern = #"(?m)^[ \t]*(?:(?:Part|Subpart)\s*)?(?:\(([a-jA-J]|i{1,4}|iv|v|vi{1,3})\)|([a-jA-J]|i{1,4}|iv|v|vi{1,3})[\).])(?=[ \t]+[A-Za-z0-9\$\\]|[ \t]*\n)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        
        let ns = normalized as NSString
        let matches = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }
        
        var subparts: [(subpart: String, content: String)] = []
        let firstMatchLocation = matches[0].range.location
        
        // If the first explicit match is (b) or (ii), and there is substantial preamble text before it, infer (a) or (i)
        let firstLetter: String = {
            let m = matches[0]
            if m.range(at: 1).location != NSNotFound { return ns.substring(with: m.range(at: 1)).lowercased() }
            if m.range(at: 2).location != NSNotFound { return ns.substring(with: m.range(at: 2)).lowercased() }
            return ""
        }()
        
        if (firstLetter == "b" || firstLetter == "ii") && firstMatchLocation > 25 {
            let preamble = ns.substring(to: firstMatchLocation).trimmingCharacters(in: .whitespacesAndNewlines)
            if !preamble.isEmpty {
                let inferredLabel = (firstLetter == "b") ? "(a)" : "(i)"
                subparts.append((subpart: inferredLabel, content: preamble))
            }
        }
        
        for (idx, m) in matches.enumerated() {
            var letter = ""
            if m.range(at: 1).location != NSNotFound {
                letter = ns.substring(with: m.range(at: 1)).lowercased()
            } else if m.range(at: 2).location != NSNotFound {
                letter = ns.substring(with: m.range(at: 2)).lowercased()
            }
            guard !letter.isEmpty else { continue }
            
            let contentStart = m.range.location + m.range.length
            let contentEnd = (idx + 1 < matches.count) ? matches[idx + 1].range.location : ns.length
            if contentEnd > contentStart {
                let text = ns.substring(with: NSRange(location: contentStart, length: contentEnd - contentStart)).trimmingCharacters(in: .whitespacesAndNewlines)
                subparts.append((subpart: "(\(letter))", content: text))
            }
        }
        
        return subparts.count >= 2 ? subparts : []
    }
    
    nonisolated func questionHasSubparts(_ question: String) -> Bool {
        return extractQuestionSubparts(question).count >= 2
    }
    
    nonisolated func splitSolutionIntoSubparts(_ solution: String, expectedSubparts: [String] = []) -> [(subpart: String, content: String)] {
        let normalized = normalizeLaTeXDelimiters(solution).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return [] }
        
        var results = [(subpart: String, content: String)]()
        let subRegex = #"(?i)(?:^|\s|\(|\b(?:Part|Subpart|Question|Problem)\s*\d*\s*\(?)([a-jA-J]|i{1,4}|iv|v|vi{1,3}|ix|x)(?:\)|\.|\s|$)"#
        let compiledSubRegex = try? NSRegularExpression(pattern: subRegex, options: [])
        
        // 1. Check if the solution is structured with markdown section headers (### ...)
        if normalized.contains("###") {
            let blocks = normalized.components(separatedBy: "\n###")
            
            for b in blocks {
                let trimmedBlock = b.replacingOccurrences(of: #"^\s*###\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedBlock.isEmpty { continue }
                
                let lines = trimmedBlock.components(separatedBy: .newlines)
                let header = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                
                let isContinuation = header.lowercased().contains("continuation")
                let nsHeader = header as NSString
                let match = compiledSubRegex?.firstMatch(in: header, options: [], range: NSRange(location: 0, length: nsHeader.length))
                
                if let m = match, !isContinuation, m.numberOfRanges > 1 {
                    let letter = nsHeader.substring(with: m.range(at: 1)).lowercased()
                    let subLabel = "(\(letter))"
                    let blockContent = body.isEmpty ? header : body
                    
                    if let existingIdx = results.firstIndex(where: { $0.subpart == subLabel }) {
                        results[existingIdx].content += "\n\n" + blockContent
                    } else {
                        results.append((subpart: subLabel, content: blockContent))
                    }
                } else {
                    // Check if the body or continuation block contains an explicit inline subpart marker (e.g. "d) what if instead...")
                    let inlinePattern = #"(?m)^[ \t]*(?:\(([a-jA-J]|i{1,4}|iv|v|vi{1,3})\)|([a-jA-J]|i{1,4}|iv|v|vi{1,3})\))[ \t]+"#
                    if let inlineRegex = try? NSRegularExpression(pattern: inlinePattern, options: []),
                       let inlineMatch = inlineRegex.firstMatch(in: body, options: [], range: NSRange(location: 0, length: (body as NSString).length)) {
                        let nsBody = body as NSString
                        let splitLoc = inlineMatch.range.location
                        let prePart = nsBody.substring(to: splitLoc).trimmingCharacters(in: .whitespacesAndNewlines)
                        let postPart = nsBody.substring(from: splitLoc).trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if !prePart.isEmpty {
                            if !results.isEmpty {
                                results[results.count - 1].content += "\n\n" + prePart
                            } else {
                                results.append((subpart: "(a)", content: prePart))
                            }
                        }
                        
                        var letter = ""
                        if inlineMatch.range(at: 1).location != NSNotFound { letter = nsBody.substring(with: inlineMatch.range(at: 1)).lowercased() }
                        else if inlineMatch.range(at: 2).location != NSNotFound { letter = nsBody.substring(with: inlineMatch.range(at: 2)).lowercased() }
                        let subLabel = !letter.isEmpty ? "(\(letter))" : "(d)"
                        results.append((subpart: subLabel, content: postPart))
                    } else if !results.isEmpty {
                        results[results.count - 1].content += "\n\n" + trimmedBlock
                    } else {
                        results.append((subpart: "(a)", content: trimmedBlock))
                    }
                }
            }
            
            if results.count >= 2 {
                return results
            }
        }
        
        // 2. Standard inline / plain-text subpart regex matching (e.g. (a), Part (b), 1. (a))
        let pattern = "(?m)^\\s*(?:###\\s*)?(?:(?:Part|Subpart|Question|Problem)\\s*\\d*\\s*)?\\(?([a-jA-J]|i{1,4}|iv|v|vi{1,3}|ix|x)\\)?[\\.:\\s]+(.*?)(?=(?:^\\s*(?:###\\s*)?(?:(?:Part|Subpart|Question|Problem)\\s*\\d*\\s*)?\\(?(?:[a-jA-J]|i{1,4}|iv|v|vi{1,3}|ix|x)\\)?[\\.:\\s]+)|\\z)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let nsStr = normalized as NSString
            let matches = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: nsStr.length))
            
            var inlineResults = [(subpart: String, content: String)]()
            for match in matches {
                if match.numberOfRanges > 2 {
                    let labelRange = match.range(at: 1)
                    let contentRange = match.range(at: 2)
                    let label = nsStr.substring(with: labelRange).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let content = nsStr.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        inlineResults.append((subpart: "(\(label))", content: content))
                    }
                }
            }
            
            if inlineResults.count >= 2 {
                return inlineResults
            }
        }
        
        return [("Full", normalized)]
    }
    
    func generateStepsFromAnswer(question: String, answer: String, problemNumber: Int? = nil) async -> [String] {
        await withUserPriority {
            let provider = taskProvider(for: "route_steps", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            let qPrefix = question.prefix(60).replacingOccurrences(of: "\n", with: " ")
            self.logToFile("[AI Helper LOG] generateStepsFromAnswer called with model '\(model)' (provider: \(provider)) for question: '\(qPrefix)...'")
            
            let qSubparts = self.extractQuestionSubparts(question)
            let hasSubparts = qSubparts.count >= 2
            
            // 1. If the question has multiple distinct subparts, decompose by subpart
            if hasSubparts {
                let solSubparts = self.splitSolutionIntoSubparts(answer, expectedSubparts: qSubparts.map { $0.subpart })
                self.logToFile("[AI Helper LOG] Question has \(qSubparts.count) subparts: \(qSubparts.map { $0.subpart }.joined(separator: ", ")). Solution yielded \(solSubparts.count) segments.")
                
                var reassembledSteps = [String]()
                for qSub in qSubparts {
                    let matchingSol = solSubparts.first(where: { $0.subpart.lowercased() == qSub.subpart.lowercased() })?.content ?? answer
                    self.logToFile("[AI Helper LOG] Generating steps for subpart \(qSub.subpart) on \(provider)...")
                    
                    let subPrompt = """
                    You are an expert university physics educator. Break down subpart \(qSub.subpart) into 2 to 4 numbered pedagogical derivation steps.

                    Context Question for \(qSub.subpart):
                    ---
                    \(qSub.content)
                    ---

                    Full Question Context:
                    ---
                    \(question)
                    ---

                    Worked Solution for \(qSub.subpart):
                    ---
                    \(matchingSol)
                    ---

                    Pedagogical Structure:
                    - Step 1: Conceptual Setup & Physical Principles (State laws, definitions - Severity Level 1 diagnostic).
                    - Step 2: Governing Formulation (Governing equations, substitutions - Severity Level 2 diagnostic).
                    - Step 3+: Mathematical Derivations & Final Evaluation.

                    Critical OCR Notation Reconciliation:
                    The solution was transcribed from handwritten notes and may contain visual OCR misreadings (such as '|4>' or '|u>' instead of '|\\psi>', '\\rho' instead of 'p', 'A' instead of 'x', '\\text{thmco}' instead of '\\hbar m \\omega'). You MUST actively correct all symbols and notations to match the variables defined in the Question statement.

                    Formatting Instructions:
                    - Wrap every step strictly inside [STEP] and [/STEP] tags.
                    - Always include:
                      [STEP]
                      Tier: <Conceptual Setup | Governing Formulation | Algebraic Derivation>
                      Subpart: \(qSub.subpart)
                      Content: <clear explanation followed by display math in $$...$$ on separate lines>
                      [/STEP]
                    - Wrap all inline variables in $...$.
                    - NO emojis. NO conversational filler. NO markdown code fences.
                    - CRITICAL: Do NOT use markdown bold asterisks (**) anywhere. Write plain text for headers and explanations.

                    Output ONLY the [STEP] blocks.
                    """
                    
                    if let res = await callOllama(prompt: subPrompt, model: model, timeout: 240.0, overrideProvider: provider) {
                        let partSteps = self.parseStepsFromLLMResponse(res, hasSubparts: true)
                        reassembledSteps.append(contentsOf: partSteps)
                        self.logToFile("[AI Helper LOG] Subpart \(qSub.subpart) generated \(partSteps.count) steps.")
                    }
                }
                
                if !reassembledSteps.isEmpty {
                    self.logToFile("[AI Helper LOG] Successfully reassembled \(reassembledSteps.count) total steps across \(qSubparts.count) subparts for the unified question.")
                    return reassembledSteps
                }
            }
            
            // 2. Single-pass generation for unified questions (or when subparts decomposition isn't needed)
            let prompt = hasSubparts ? """
            You are an expert university physics educator. Break down the following worked physics solution into 2 to 6 numbered pedagogical derivation steps.

            Question:
            ---
            \(question)
            ---

            Worked Solution:
            ---
            \(answer)
            ---

            Pedagogical Structure:
            - Step 1: Conceptual Setup & Physical Principles (State laws, definitions, boundary conditions - Severity Level 1 diagnostic).
            - Step 2: Governing Equations & Formulation (Set up differential forms, state equations, substitutions - Severity Level 2 diagnostic).
            - Step 3+: Algebraic Derivations, Integration & Final Result (Step 3+ Calculation slips).
            - Clearly label each step with its subpart (e.g. (a), (b) or (i), (ii)).
            - Tabular Problems: If the problem is a table or data sheet, do NOT make up artificial differential equations. Step 1 should present the conceptual principles, rules, and definitions. Step 2 should present the completed table in standard LaTeX $$ \\begin{array}{...} ... \\end{array} $$ format.

            Critical OCR Notation Reconciliation:
            The solution was transcribed from handwritten notes and may contain visual OCR misreadings (such as '|4>' or '|u>' instead of '|\\psi>', '\\rho' instead of 'p', 'A' instead of 'x', '\\text{thmco}' instead of '\\hbar m \\omega'). You MUST actively correct all symbols and notations to match the variables defined in the Question statement.

            Formatting Instructions:
            - Wrap every step strictly inside [STEP] and [/STEP] tags.
            - Inside each block, provide clear explanations followed by centered display math ($$...$$) on separate lines.
            - Wrap all inline variables in $...$.
            - NO emojis. NO conversational filler. NO markdown code fences.
            - CRITICAL: Do NOT use markdown bold asterisks (**) anywhere. Write plain text headers and text.

            Example format:
            [STEP]
            Tier: Conceptual Setup
            Subpart: (a)
            Content: State the fundamental physical principles and conditions...
            [/STEP]
            [STEP]
            Tier: Governing Formulation
            Subpart: (a)
            Content: Set up the governing equations:
            $$
            ...
            $$
            [/STEP]
            [STEP]
            Tier: Algebraic Derivation
            Subpart: (a)
            Content: Carry out the derivation and evaluate...
            [/STEP]

            Output ONLY the [STEP] blocks.
            """ : """
            You are an expert university physics educator. Break down the following worked physics solution into 2 to 6 numbered pedagogical derivation steps.

            Question:
            ---
            \(question)
            ---

            Worked Solution:
            ---
            \(answer)
            ---

            Pedagogical Structure:
            - Step 1: Conceptual Setup & Physical Principles (State laws, definitions, boundary conditions - Severity Level 1 diagnostic).
            - Step 2: Governing Equations & Formulation (Set up differential forms, state equations, substitutions - Severity Level 2 diagnostic).
            - Step 3+: Algebraic Derivations, Integration & Final Result (Step 3+ Calculation slips).
            - CRITICAL: This question is a unified problem with NO subparts (no part a, b, etc.). Do NOT output any 'Subpart:' line. Do NOT label steps with (a), (b), or (i).
            - Tabular Problems: If the problem is a table or data sheet, do NOT make up artificial differential equations. Step 1 should present the conceptual principles, rules, and definitions. Step 2 should present the completed table in standard LaTeX $$ \\begin{array}{...} ... \\end{array} $$ format.

            Critical OCR Notation Reconciliation:
            The solution was transcribed from handwritten notes and may contain visual OCR misreadings (such as '|4>' or '|u>' instead of '|\\psi>', '\\rho' instead of 'p', 'A' instead of 'x', '\\text{thmco}' instead of '\\hbar m \\omega'). You MUST actively correct all symbols and notations to match the variables defined in the Question statement.

            Formatting Instructions:
            - Wrap every step strictly inside [STEP] and [/STEP] tags.
            - Inside each block, provide clear explanations followed by centered display math ($$...$$) on separate lines.
            - Wrap all inline variables in $...$.
            - NO emojis. NO conversational filler. NO markdown code fences.
            - CRITICAL: Do NOT use markdown bold asterisks (**) anywhere. Write plain text headers and text.

            Example format:
            [STEP]
            Tier: Conceptual Setup
            Content: State the fundamental physical principles and conditions...
            [/STEP]
            [STEP]
            Tier: Governing Formulation
            Content: Set up the governing equations:
            $$
            ...
            $$
            [/STEP]
            [STEP]
            Tier: Algebraic Derivation
            Content: Carry out the derivation and evaluate...
            [/STEP]

            Output ONLY the [STEP] blocks.
            """
            
            guard let res = await callOllama(prompt: prompt, model: model, timeout: 180.0, overrideProvider: provider) else {
                return []
            }
            let steps = self.parseStepsFromLLMResponse(res, hasSubparts: hasSubparts)
            return steps
        }
    }
    
    nonisolated func isStepHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        
        let lower = trimmed.lowercased()
        if lower.contains("step-by-step") || lower.contains("steps:") || lower.contains("steps to") || lower.contains("following steps") {
            return false
        }
        
        // 1. Check for "step" pattern (e.g. "Step 1:", "STEP:", "Step:", "### Step 3.")
        let stepPattern = "^[\\*#_\\s\\-]*step[s\\s\\-]*(\\d+|:|\\s+)"
        if let regex = try? NSRegularExpression(pattern: stepPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        
        // 2. Check for subparts like (i), (ii), (a), (b), ①, ② followed by content
        let subpartHeaderPattern = "^[\\*#_\\s]*(?:\\(([a-fA-F]|i{1,4}|iv|v|vi{1,3}|ix|x)\\)|([a-fA-F]|i{1,4}|iv|v|vi{1,3}|ix|x)\\.|[①-⑩]|•\\s*Path\\s+[A-Z]\\s*:|(?:Part|Phase|Stage)\\s+[A-Z0-9]+:)\\s+"
        if let regex = try? NSRegularExpression(pattern: subpartHeaderPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        
        // 3. Check for numbered list pattern (e.g. "1. ", "1) ") followed by words
        let numberPattern = "^[\\*#_\\s]*\\d+[\\.\\):]\\s+[A-Za-z\\$]"
        if let regex = try? NSRegularExpression(pattern: numberPattern, options: []) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        
        // 4. Check for bullet list pattern (e.g. "- First", "* Compute", "• Step")
        let bulletPattern = "^[\\*#_\\s]*[-*•]\\s+[A-Za-z\\$]"
        if let regex = try? NSRegularExpression(pattern: bulletPattern, options: []) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        
        return false
    }
    
    nonisolated func cleanStepText(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip markdown bold **text** -> text and lingering asterisks
        text = text.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
        
        // Strip markdown headers: ### etc.
        text = text.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        
        // If it starts with Step X:, clean the prefix
        let lower = text.lowercased()
        if lower.contains("step") {
            let stepPrefixPattern = "^[\\*#_\\s\\-]*step[s\\s\\-]*\\d*[:.]*[\\*_]*\\s*"
            text = text.replacingOccurrences(of: stepPrefixPattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        
        // Strip leading numbering: e.g. "1. ", "2) "
        text = text.replacingOccurrences(of: "^\\d+[\\.\\):]\\s*", with: "", options: .regularExpression)
        
        // Strip leading bullets: e.g. "- ", "* ", "• "
        text = text.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
        
        // Strip remaining leading bold/italic markers or colons
        text = text.replacingOccurrences(of: "^[:\\*_\\s]+", with: "", options: .regularExpression)
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    nonisolated func cleanDiagnosticTier(_ raw: String) -> String {
        var unstarred = raw.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
        unstarred = unstarred.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
        let lower = unstarred.lowercased()
        if lower.contains("concept") || lower.contains("principle") || lower.contains("setup") {
            return "Conceptual Setup"
        } else if lower.contains("govern") || lower.contains("formulat") || lower.contains("equation") {
            return "Governing Formulation"
        } else if lower.contains("algebra") || lower.contains("derivat") || lower.contains("calculat") || lower.contains("integrat") {
            return "Algebraic Derivation"
        } else if lower.contains("interpret") || lower.contains("analys") || lower.contains("meaning") {
            return "Interpretation & Analysis"
        } else if lower.contains("verif") || lower.contains("evaluat") || lower.contains("result") || lower.contains("complet") {
            return "Verification & Result"
        }
        var cleaned = unstarred.replacingOccurrences(of: #"[\$\\][a-zA-Z0-9_\{\}\\]*"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"[\[\]\(\)\*#]"#, with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    nonisolated func parseStepsFromLLMResponse(_ res: String, hasSubparts: Bool = true) -> [String] {
        self.logToFile("[AI Helper LOG] Parsing LLM response into steps. Raw response length: \(res.count)")
        
        var strippedRes = res.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        strippedRes = strippedRes.replacingOccurrences(of: #"(?i)\[/?think\]"#, with: "", options: .regularExpression)
        let normalizedRes = normalizeLaTeXDelimiters(strippedRes)
        
        // 1. Check for explicit [STEP] blocks (supporting unclosed final [/STEP] tag)
        if normalizedRes.contains("[STEP]") {
            var extractedBlocks = [String]()
            let rawParts = normalizedRes.components(separatedBy: "[STEP]")
            
            for part in rawParts.dropFirst() {
                var blockContent = part
                if let closeRange = blockContent.range(of: "[/STEP]") {
                    blockContent = String(blockContent[..<closeRange.lowerBound])
                }
                blockContent = blockContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if blockContent.isEmpty { continue }
                
                // Strip markdown bold **text** -> text and lingering asterisks
                blockContent = blockContent.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
                blockContent = blockContent.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
                
                // Parse structured Tier: / Subpart: / Content:
                if blockContent.localizedCaseInsensitiveContains("Content:") {
                    var tierStr = ""
                    var subpartStr = ""
                    var contentStr = ""
                    let lines = blockContent.components(separatedBy: .newlines)
                    var readingContent = false
                    for line in lines {
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = trimmedLine.lowercased()
                        if lower.starts(with: "tier:") {
                            tierStr = trimmedLine.replacingOccurrences(of: "(?i)^tier:\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                        } else if lower.starts(with: "subpart:") {
                            subpartStr = trimmedLine.replacingOccurrences(of: "(?i)^subpart:\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                        } else if lower.starts(with: "content:") {
                            readingContent = true
                            let c = trimmedLine.replacingOccurrences(of: "(?i)^content:\\s*", with: "", options: .regularExpression)
                            if !c.isEmpty { contentStr = c }
                        } else if readingContent {
                            contentStr += (contentStr.isEmpty ? "" : "\n") + line
                        }
                    }
                    if !contentStr.isEmpty {
                        var formatted = ""
                        let cleanTier = cleanDiagnosticTier(tierStr)
                        if !cleanTier.isEmpty {
                            formatted += "[\(cleanTier)] "
                        }
                        if hasSubparts && !subpartStr.isEmpty && subpartStr.lowercased() != "full" && subpartStr.lowercased() != "none" {
                            formatted += "\(subpartStr) "
                        }
                        if !formatted.isEmpty {
                            formatted += "\n\n"
                        }
                        formatted += contentStr.trimmingCharacters(in: .whitespacesAndNewlines)
                        blockContent = formatted
                    }
                } else {
                    // If the LLM omitted "Content:" but outputted a Tier heading like "Tier: ...", "Conceptual Setup...", or "Step 1: ..."
                    let lines = blockContent.components(separatedBy: .newlines)
                    var tierStr = ""
                    var contentLines = [String]()
                    for (idx, line) in lines.enumerated() {
                        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = trimmedLine.lowercased()
                        if idx == 0 || (idx == 1 && tierStr.isEmpty) {
                            if lower.starts(with: "tier:") {
                                tierStr = trimmedLine.replacingOccurrences(of: "(?i)^tier:\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                                continue
                            } else if lower.contains("conceptual") || lower.contains("governing") || lower.contains("algebraic") || lower.contains("identification") || lower.contains("data collection") || lower.contains("principle") {
                                tierStr = cleanDiagnosticTier(trimmedLine)
                                continue
                            }
                        }
                        contentLines.append(line)
                    }
                    let remainingContent = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !remainingContent.isEmpty {
                        var formatted = ""
                        let cleanTier = cleanDiagnosticTier(tierStr)
                        if !cleanTier.isEmpty {
                            formatted += "[\(cleanTier)]\n\n"
                        }
                        formatted += remainingContent
                        blockContent = formatted
                    }
                }
                
                // Strip raw leftover tag markers
                blockContent = blockContent.replacingOccurrences(of: #"(?i)\[/?step\]"#, with: "", options: .regularExpression)
                blockContent = blockContent.replacingOccurrences(of: #"(?m)^(?i)content:\s*"#, with: "", options: .regularExpression)
                blockContent = blockContent.replacingOccurrences(of: #"(?m)^(?i)tier:\s*[^\n]*\n?"#, with: "", options: .regularExpression)
                
                if !hasSubparts {
                    blockContent = blockContent.replacingOccurrences(of: #"(?m)^(?i)subpart:\s*[^\n]*\n?"#, with: "", options: .regularExpression)
                }
                
                let cleanedBlock = blockContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedBlock.isEmpty {
                    extractedBlocks.append(normalizeLaTeXDelimiters(cleanedBlock))
                }
            }
            
            if !extractedBlocks.isEmpty {
                self.logToFile("[AI Helper LOG] Parsed \(extractedBlocks.count) explicit [STEP] blocks.")
                for (i, step) in extractedBlocks.enumerated() {
                    self.logToFile("[AI Helper LOG] Step \(i+1): '\(step.prefix(80))...'")
                }
                return extractedBlocks
            }
        }
        
        let lines = normalizedRes.components(separatedBy: .newlines)
        
        // 2. Fallback to step headers (e.g. Step 1:, (a), 1., etc.)
        let hasStepHeader = lines.contains { isStepHeader($0) }
        if !hasStepHeader {
            // Group paragraphs: consolidate short equation-only paragraphs with preceding description
            let rawParagraphs = normalizedRes.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            var consolidated = [String]()
            for p in rawParagraphs {
                let cleanP = p.replacingOccurrences(of: #"(?i)\[/?step\]"#, with: "", options: .regularExpression)
                              .replacingOccurrences(of: #"(?m)^(?i)content:\s*"#, with: "", options: .regularExpression)
                              .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanP.isEmpty { continue }
                
                let isFormulaOnly = (cleanP.starts(with: "$$") && cleanP.hasSuffix("$$")) ||
                                   (cleanP.starts(with: "\\[") && cleanP.hasSuffix("\\]")) ||
                                   (cleanP.count < 75 && cleanP.contains("="))
                
                if isFormulaOnly && !consolidated.isEmpty {
                    consolidated[consolidated.count - 1] += "\n\n" + cleanP
                } else {
                    consolidated.append(cleanP)
                }
            }
            
            if consolidated.count > 1 {
                // Tier untagged paragraphs so they don't look untiered
                var tieredSteps = [String]()
                let tierLabels = ["Conceptual Setup", "Governing Formulation", "Algebraic Derivation", "Verification & Result"]
                for (idx, p) in consolidated.enumerated() {
                    let tier = (idx < tierLabels.count) ? tierLabels[idx] : "Algebraic Derivation"
                    if !p.starts(with: "[") {
                        tieredSteps.append("[\(tier)]\n\n\(p)")
                    } else {
                        tieredSteps.append(p)
                    }
                }
                self.logToFile("[AI Helper LOG] Consolidated untagged text into \(tieredSteps.count) tiered steps.")
                return tieredSteps
            }
        }
        
        var steps = [String]()
        var currentStepText = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let lower = trimmed.lowercased()
            if lower.contains("hope this helps") || lower.contains("let me know if you need") || lower.contains("feel free to ask") {
                self.logToFile("[AI Helper LOG] Skipping outro line: '\(trimmed)'")
                continue
            }
            
            // Skip introductory conversational line before the first step header
            if steps.isEmpty && currentStepText.isEmpty {
                if lower.hasPrefix("here is") || lower.hasPrefix("here's") || lower.hasPrefix("here are") ||
                   lower.contains("step-by-step") || lower.contains("steps to") || lower.contains("following steps") ||
                   lower.hasPrefix("below is") || lower.hasPrefix("sure") {
                    self.logToFile("[AI Helper LOG] Skipping intro line: '\(trimmed)'")
                    continue
                }
            }
            
            if isStepHeader(trimmed) {
                if !currentStepText.isEmpty {
                    steps.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentStepText = cleanStepText(trimmed)
            } else {
                if !currentStepText.isEmpty {
                    currentStepText += "\n" + trimmed
                } else {
                    currentStepText = trimmed
                }
            }
        }
        
        if !currentStepText.isEmpty {
            steps.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        
        if steps.isEmpty {
            self.logToFile("[AI Helper LOG] No steps detected. Falling back to paragraph split.")
            let paragraphs = res.components(separatedBy: "\n\n")
            for para in paragraphs {
                let trimmedPara = para.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPara.isEmpty {
                    steps.append(normalizeLaTeXDelimiters(trimmedPara))
                }
            }
        }
        
        self.logToFile("[AI Helper LOG] Parsed \(steps.count) steps.")
        return steps
    }
    
    nonisolated func splitSolutionIntoSteps(_ solution: String) -> [String] {
        let normalized = normalizeLaTeXDelimiters(solution).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return [] }
        
        // 1. Check for explicit step headers (e.g. [STEP], STEP:, Step 1:, etc.)
        let parsed = parseStepsFromLLMResponse(normalized)
        if parsed.count > 1 {
            return parsed
        }
        
        // 2. Check for subparts (including markdown ### headers like "### Problem 8 (a)", "### Part (c)")
        let subparts = splitSolutionIntoSubparts(normalized)
        if subparts.count > 1 {
            return subparts.map { sub in
                "### Part \(sub.subpart)\n\n\(sub.content)"
            }
        }
        
        // 3. Check for subpart labels: (a), (b), (c), (i), (ii), (iii), Part 1:, • Path A:, ①-⑩
        let subpartPattern = "(?m)(?:^|\\n\\s*)(?:###\\s*)?(?:(?:Part|Subpart|Question|Problem)\\s*\\d*\\s*)?(?:\\(([a-jA-J]|i{1,4}|iv|v|vi{1,3}|ix|x)\\)|([a-jA-J]|i{1,4}|iv|v|vi{1,3}|ix|x)\\.|•\\s*Path\\s+[A-Z]\\s*:|[①-⑩]|(?:Part|Phase|Stage)\\s+[A-Z0-9]+:)"
        if let regex = try? NSRegularExpression(pattern: subpartPattern, options: []) {
            let nsString = normalized as NSString
            let matches = regex.matches(in: normalized, options: [], range: NSRange(location: 0, length: nsString.length))
            if matches.count > 1 {
                var rawSteps: [String] = []
                for i in 0..<matches.count {
                    let start = matches[i].range.location
                    let end = (i + 1 < matches.count) ? matches[i + 1].range.location : nsString.length
                    let chunk = nsString.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if chunk.count > 5 {
                        rawSteps.append(chunk)
                    } else if !rawSteps.isEmpty && !chunk.isEmpty {
                        rawSteps[rawSteps.count - 1] += "\n" + chunk
                    }
                }
                if rawSteps.count > 1 {
                    return rawSteps
                }
            }
        }
        
        // 4. Split by double-newlines (paragraphs)
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 }
        if paragraphs.count > 1 {
            return paragraphs
        }
        
        return [normalized]
    }
    
    func matchQuestionsAndAnswers(questions: [ExtractedProblem], answers: [ExtractedAnswer]) async -> [ExtractedProblem] {
        guard !answers.isEmpty else { return questions }
        
        let provider = taskProvider(for: "route_matching", defaultProvider: "tailscale")
        let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
        
        var qList = ""
        for i in 0..<questions.count {
            let qPreview = questions[i].content.prefix(1500).replacingOccurrences(of: "\n", with: " ")
            qList += "Question ID \(i):\n\(qPreview)\n---\n"
        }
        
        var aList = ""
        for i in 0..<answers.count {
            let contentPreview = answers[i].content.prefix(1500).replacingOccurrences(of: "\n", with: " ")
            aList += "Answer ID \(i) [Label: \(answers[i].label)]: \(contentPreview)\n---\n"
        }
        
        let prompt = """
        You are an expert physics teaching assistant. Match each extracted question with its corresponding worked answer/solution from the lists below.
        
        Questions:
        ===
        \(qList)
        ===
        
        Answers:
        ===
        \(aList)
        ===
        
        Instructions:
        For each question, determine if there is a matching worked answer that genuinely solves it:
        - If a genuine match exists, output:
        MATCH: Question ID X -> Answer ID Y
        - If NO corresponding answer exists in the answers list (for example, if the answer sheet does not contain solutions for this question), output:
        MATCH: Question ID X -> NONE
        
        Strict Rules:
        1. Match based on physics concepts, variables, equations, and problem context.
        2. A question can match at most one answer.
        3. CRITICAL: NEVER pair a question with an unrelated answer. If you are not confident that an answer genuinely belongs to the question, you MUST output NONE.
        4. Output ONLY the MATCH lines with no extra text.
        """
        
        guard let res = await callOllama(prompt: prompt, model: model, timeout: 60.0, overrideProvider: provider) else { return questions }
        
        var updatedQuestions = questions
        let lines = res.components(separatedBy: .newlines)
        
        var matches = [(Int, Int)]()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("->") else { continue }
            
            let parts = trimmed.components(separatedBy: "->")
            if parts.count == 2 {
                let qPart = parts[0].lowercased().replacingOccurrences(of: "match:", with: "").replacingOccurrences(of: "question id", with: "").replacingOccurrences(of: "question", with: "").trimmingCharacters(in: .whitespaces)
                let aPart = parts[1].lowercased().replacingOccurrences(of: "answer id", with: "").replacingOccurrences(of: "answer", with: "").trimmingCharacters(in: .whitespaces)
                
                if aPart.contains("none") {
                    continue
                }
                
                let qDigits = qPart.filter { $0.isNumber }
                let aDigits = aPart.filter { $0.isNumber }
                
                if let qIdx = Int(qDigits), let aIdx = Int(aDigits) {
                    if qIdx >= 0 && qIdx < updatedQuestions.count && aIdx >= 0 && aIdx < answers.count {
                        matches.append((qIdx, aIdx))
                    }
                }
            }
        }
        
        if !matches.isEmpty {
            for (qIdx, aIdx) in matches {
                let ansContent = answers[aIdx].content
                let steps = self.splitSolutionIntoSteps(ansContent)
                
                updatedQuestions[qIdx].solution = ansContent
                updatedQuestions[qIdx].steps = !steps.isEmpty ? steps : [ansContent]
                self.logToFile("[AI Batch Importer LOG] Matched Question \(qIdx) -> Answer \(aIdx) [\(answers[aIdx].label)]. Prepared \(updatedQuestions[qIdx].steps.count) steps.")
            }
        }
        
        return updatedQuestions
    }
    
    func matchAndMergeSolutions(extractedAnswers: [ExtractedAnswer]) async {
        guard !extractedAnswers.isEmpty else { return }
        
        let currentQuestions = self.sessionExtractedProblems
        guard !currentQuestions.isEmpty else { return }
        
        let matchedQuestions = await matchQuestionsAndAnswers(questions: currentQuestions, answers: extractedAnswers)
        
        DispatchQueue.main.async {
            self.sessionExtractedProblems = matchedQuestions
        }
    }
    
    public func cleanQuestionContent(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip code block fences (e.g. ```, ```markdown, ```latex) and raw triple backticks/single quotes
        text = text.replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.replacingOccurrences(of: "'''", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Strip top-level question prefixes like "1)", "1.", "Problem 1:", "Question 2.", "Q1:", "**1.**", etc.
        // But PRESERVE sub-questions like "(a)", "(b)", "(i)", "(ii)", "a)", "i)"
        let patterns = [
            #"^[#*\s]*(?:Problem|Question|Exercise|Task|Q)\s*\d+(?:\.\d+)?\s*(?::|\.|\)|-)?\s*[*#\s]*"#,
            #"^[#*\s]*\d+(?:\.\d+)?\s*(?::|\.|\)|-)\s*[*#\s]*"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if let match = regex.firstMatch(in: text, options: [], range: range), match.range.location == 0 {
                    if let swiftRange = Range(match.range, in: text) {
                        text = String(text[swiftRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
        }
        return text
    }
    
    /// Extracts a genuine problem/question number from label headers like "Problem 1a", "Question 2 (a)", "Problem 7 (i)"
    /// while ignoring inline math subscripts like "$A_2$".
    nonisolated public func extractProblemNumberFromLabel(_ label: String) -> Int? {
        let pattern = #"(?:Problem|Question|Exercise|Task|Q)\s*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let ns = label as NSString
            if let match = regex.firstMatch(in: label, options: [], range: NSRange(location: 0, length: ns.length)) {
                let numRange = match.range(at: 1)
                if numRange.location != NSNotFound {
                    return Int(ns.substring(with: numRange))
                }
            }
        }
        return nil
    }
    
    /// Derives a complete worked solution and pedagogical step breakdown directly from a question statement
    /// when no solution is provided in the answer key document.
    public func deriveSolutionAndSteps(question: String) async -> (solution: String, steps: [String]) {
        await withUserPriority {
            let provider = taskProvider(for: "route_steps", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            self.logToFile("[AI Helper LOG] deriveSolutionAndSteps called with model '\(model)' (\(provider)) for question: '\(question.prefix(60))...'")
            
            let hasSubparts = questionHasSubparts(question)
            
            let prompt = """
            You are an expert university physics educator and professor.
            Provide a complete, rigorous worked solution and structured pedagogical derivation steps for the following physics problem:

            Question:
            ---
            \(question)
            ---

            Pedagogical Structure:
            - Step 1: Conceptual Setup & Physical Principles (State laws, definitions, boundary conditions - Severity Level 1 diagnostic).
            - Step 2: Governing Equations & Formulation (Set up differential forms, state equations, substitutions - Severity Level 2 diagnostic).
            - Step 3+: Algebraic Derivations, Integration & Final Result.
            \(hasSubparts ? "- Clearly label each step with its subpart (e.g. Subpart: (a), Subpart: (b))." : "- This question has NO subparts. Do NOT output a Subpart line.")

            Formatting Instructions:
            - Wrap every step strictly inside [STEP] and [/STEP] tags.
            - Inside each block, provide:
              Tier: <Conceptual Setup | Governing Formulation | Algebraic Derivation>
              \(hasSubparts ? "Subpart: <e.g. (a) or (b)>\n" : "")Content: <explanation with equations in $$...$$>
            - Wrap all inline variables in $...$.
            - NO emojis. NO conversational filler. NO markdown code fences.
            - CRITICAL: Do NOT use markdown bold asterisks (**) anywhere. Write plain text headers and text.

            Format your response strictly as:
            [WORKED_SOLUTION]
            <full comprehensive worked solution with equations>
            [/WORKED_SOLUTION]

            [STEPS]
            [STEP]
            Tier: Conceptual Setup
            \(hasSubparts ? "Subpart: (a)\n" : "")Content: State the fundamental physical principles...
            [/STEP]
            ...
            [/STEPS]
            """
            
            guard let res = await callOllama(prompt: prompt, model: model, timeout: 120.0, overrideProvider: provider) else {
                return ("", [])
            }
            
            var workedSolution = ""
            if let solStart = res.range(of: "[WORKED_SOLUTION]"),
               let solEnd = res.range(of: "[/WORKED_SOLUTION]") {
                workedSolution = String(res[solStart.upperBound..<solEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            let parsedSteps = self.parseStepsFromLLMResponse(res, hasSubparts: hasSubparts)
            
            if workedSolution.isEmpty && !parsedSteps.isEmpty {
                workedSolution = parsedSteps.joined(separator: "\n\n")
            }
            
            return (workedSolution, parsedSteps)
        }
    }
    
    public func parseExtractedProblems(_ text: String) -> [ExtractedProblem] {
        var problems: [ExtractedProblem] = []
        var strippedText = text.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        strippedText = strippedText.replacingOccurrences(of: #"(?i)\[/PROBLEM\]"#, with: "[PROBLEM]", options: .regularExpression)
        let normalizedText = normalizeLaTeXDelimiters(strippedText)
        let blocks = normalizedText.components(separatedBy: "[PROBLEM]")
        
        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var questionText = ""
            var hintText = ""
            var solutionText = ""
            var stepsList = [String]()
            var currentSection = ""
            var currentStepText = ""
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                let lower = trimmed.lowercased()
                
                if lower.starts(with: "question:") || (lower.contains("question:") && currentSection != "question" && currentSection != "solution") {
                    if !currentStepText.isEmpty {
                        stepsList.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        currentStepText = ""
                    }
                    currentSection = "question"
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        questionText = val
                    }
                } else if lower.starts(with: "hint:") || (lower.contains("hint:") && currentSection != "question" && currentSection != "solution") {
                    if !currentStepText.isEmpty {
                        stepsList.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        currentStepText = ""
                    }
                    currentSection = "hint"
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        hintText = val
                    }
                } else if lower.starts(with: "solution:") || (lower.contains("solution:") && currentSection != "question") {
                    if !currentStepText.isEmpty {
                        stepsList.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        currentStepText = ""
                    }
                    currentSection = "solution"
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        solutionText = val
                    }
                } else if lower.starts(with: "step") || (lower.contains("step ") && lower.contains(":")) {
                    if !currentStepText.isEmpty {
                        stepsList.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
                        currentStepText = ""
                    }
                    currentSection = "step"
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        currentStepText = val
                    } else {
                        currentStepText = trimmed
                    }
                } else {
                    if currentSection == "question" {
                        if !questionText.isEmpty { questionText += "\n" }
                        questionText += line
                    } else if currentSection == "hint" {
                        if !hintText.isEmpty { hintText += "\n" }
                        hintText += line
                    } else if currentSection == "solution" {
                        if !solutionText.isEmpty { solutionText += "\n" }
                        solutionText += line
                    } else if currentSection == "step" {
                        if !currentStepText.isEmpty { currentStepText += "\n" }
                        currentStepText += line
                    }
                }
            }
            
            if !currentStepText.isEmpty {
                stepsList.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            
            var q = normalizeLaTeXDelimiters(questionText.trimmingCharacters(in: .whitespacesAndNewlines))
            q = cleanQuestionContent(q)
            var h = normalizeLaTeXDelimiters(hintText.trimmingCharacters(in: .whitespacesAndNewlines))
            h = cleanQuestionContent(h)
            let sol = normalizeLaTeXDelimiters(solutionText.trimmingCharacters(in: .whitespacesAndNewlines))
            
            if !q.isEmpty {
                var finalSteps = stepsList
                if finalSteps.isEmpty && !sol.isEmpty {
                    finalSteps = splitSolutionIntoSteps(sol)
                }
                
                problems.append(ExtractedProblem(content: q, solutionHint: h, solution: sol, steps: finalSteps))
            }
        }
        return problems
    }
    
    nonisolated func logToFile(_ message: String) {
        print(message)
        let appDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".physics_study_app")
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        let logURL = appDir.appendingPathComponent("batch_importer_run.log")
        let logPath = logURL.path
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        
        if let data = logLine.data(using: .utf8) {
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
    
    private init() {
        startAutoReconnectMonitor()
        startEngineStatusMonitor()
    }
    
    private func withUserPriority<T>(_ block: () async -> T) async -> T {
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
    
    // MARK: - Tailscale & Network Discovery
    
    func scanTailscaleNetwork() async -> [DiscoveredAIHost] {
        await MainActor.run {
            self.isScanningTailscale = true
        }
        defer {
            Task { @MainActor in
                self.isScanningTailscale = false
            }
        }
        
        var candidateTargets: [(name: String, ipOrHost: String, port: Int)] = []
        
        // 1. Current configured host
        let currentTailHost = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
        if !currentTailHost.isEmpty, let url = URL(string: currentTailHost), let host = url.host {
            candidateTargets.append((name: "Current Host", ipOrHost: host, port: url.port ?? 11434))
        }
        
        // 2. Discover peers from Tailscale CLI / status
        let cliPeers = await discoverTailscalePeersFromCLI()
        for peer in cliPeers {
            if !candidateTargets.contains(where: { $0.ipOrHost == peer.ip }) {
                candidateTargets.append((name: peer.name, ipOrHost: peer.ip, port: 11434))
            }
        }
        
        // 3. Local machine option
        if !candidateTargets.contains(where: { $0.ipOrHost == "127.0.0.1" || $0.ipOrHost == "localhost" }) {
            candidateTargets.append((name: "Local Machine", ipOrHost: "127.0.0.1", port: 11434))
        }
        
        // 4. Concurrently probe each candidate
        var discovered: [DiscoveredAIHost] = []
        await withTaskGroup(of: DiscoveredAIHost?.self) { group in
            for target in candidateTargets {
                group.addTask {
                    await self.probeHost(name: target.name, ipOrHost: target.ipOrHost, port: target.port)
                }
            }
            
            for await result in group {
                if let host = result {
                    discovered.append(host)
                }
            }
        }
        
        let sorted = discovered.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            return a.responseTimeMs < b.responseTimeMs
        }
        
        await MainActor.run {
            self.discoveredHosts = sorted
        }
        
        return sorted
    }
    
    func probeHost(name: String, ipOrHost: String, port: Int = 11434) async -> DiscoveredAIHost? {
        let scheme = ipOrHost.hasPrefix("http://") || ipOrHost.hasPrefix("https://") ? "" : "http://"
        let hostURLString = "\(scheme)\(ipOrHost):\(port)"
        guard let baseURL = URL(string: hostURLString) else { return nil }
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 2.0
        
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let tags = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return nil }
            
            let allModels = tags.models.map { $0.name }
            let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream", "gemma3", "pixtral"]
            let visionModels = allModels.filter { name in
                let lower = name.lowercased()
                return visionKeywords.contains { lower.contains($0) }
            }
            let generalModels = allModels.filter { name in
                let lower = name.lowercased()
                return !visionKeywords.contains { lower.contains($0) }
            }
            
            let displayName = (name.isEmpty || name == "Current Host") ? ipOrHost : name
            return DiscoveredAIHost(
                name: displayName,
                ip: ipOrHost,
                port: port,
                hostURL: hostURLString,
                models: allModels,
                generalModels: generalModels,
                visionModels: visionModels,
                isOnline: true,
                responseTimeMs: duration
            )
        } catch {
            return nil
        }
    }
    
    private func discoverTailscalePeersFromCLI() async -> [(name: String, ip: String)] {
        let possiblePaths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/usr/bin/tailscale"
        ]
        
        var peers: [(name: String, ip: String)] = []
        
        for path in possiblePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let selfObj = json["Self"] as? [String: Any],
                       let hostName = selfObj["HostName"] as? String,
                       let ips = selfObj["TailscaleIPs"] as? [String],
                       let v4 = ips.first(where: { $0.contains(".") }) {
                        peers.append((name: "\(hostName) (This Device)", ip: v4))
                    }
                    
                    if let peerDict = json["Peer"] as? [String: [String: Any]] {
                        for (_, info) in peerDict {
                            let hostName = (info["HostName"] as? String) ?? "Tailscale Peer"
                            if let ips = info["TailscaleIPs"] as? [String],
                               let v4 = ips.first(where: { $0.contains(".") }) {
                                peers.append((name: hostName, ip: v4))
                            }
                        }
                    }
                }
                if !peers.isEmpty { break }
            } catch {
                continue
            }
        }
        
        return peers
    }

    // MARK: - Tailscale Auto-Reconnect & Health Monitoring
    
    @discardableResult
    func attemptAutoReconnect() async -> Bool {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        
        await MainActor.run {
            self.isAutoReconnecting = true
            self.autoReconnectAttempts += 1
        }
        defer {
            Task { @MainActor in
                self.isAutoReconnecting = false
            }
        }
        
        if provider == "local" {
            let running = await isOllamaRunning()
            if running {
                await MainActor.run {
                    self.isAIDisconnected = false
                    self.disconnectionMessage = ""
                    self.autoReconnectAttempts = 0
                }
                return true
            }
            await ensureLocalOllamaRunning()
            let nowRunning = await isOllamaRunning()
            await MainActor.run {
                if nowRunning {
                    self.isAIDisconnected = false
                    self.disconnectionMessage = ""
                    self.autoReconnectAttempts = 0
                }
            }
            return nowRunning
        }
        
        if provider == "tailscale" {
            // 1. Direct probe to configured Tailscale host
            let currentTailHost = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
            if !currentTailHost.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: currentTailHost, defaultHost: "http://localhost:11434") {
                let tagsUrl = baseURL.appendingPathComponent("api/tags")
                var req = URLRequest(url: tagsUrl)
                req.timeoutInterval = 3.5
                if let (data, resp) = try? await session.data(for: req),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let tags = try? JSONDecoder().decode(TagsResponse.self, from: data),
                   !tags.models.isEmpty {
                    await MainActor.run {
                        self.isAIDisconnected = false
                        self.disconnectionMessage = ""
                        self.autoReconnectAttempts = 0
                    }
                    self.logToFile("[AI Helper LOG] Auto-reconnected to configured Tailscale host (\(currentTailHost)).")
                    return true
                }
            }
            
            // 2. Discover peers from Tailscale CLI / status and probe for Ollama
            let peers = await discoverTailscalePeersFromCLI()
            for peer in peers {
                if let probed = await probeHost(name: peer.name, ipOrHost: peer.ip, port: 11434), probed.isOnline {
                    await MainActor.run {
                        UserDefaults.standard.set(probed.hostURL, forKey: "tailscale_host")
                        let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host") ?? ""
                        if vHost.isEmpty || !probed.visionModels.isEmpty {
                            UserDefaults.standard.set(probed.hostURL, forKey: "vision_tailscale_host")
                        }
                        if !probed.generalModels.isEmpty {
                            let curModel = UserDefaults.standard.string(forKey: "tailscale_model_general") ?? ""
                            if curModel.isEmpty || !probed.generalModels.contains(curModel) {
                                let chosen = probed.generalModels.first(where: { $0.contains("coder") || $0.contains("14b") }) ?? probed.generalModels[0]
                                UserDefaults.standard.set(chosen, forKey: "tailscale_model_general")
                            }
                        }
                        if !probed.visionModels.isEmpty {
                            let curVModel = UserDefaults.standard.string(forKey: "vision_tailscale_model") ?? ""
                            if curVModel.isEmpty || !probed.visionModels.contains(curVModel) {
                                UserDefaults.standard.set(probed.visionModels[0], forKey: "vision_tailscale_model")
                            }
                        }
                        self.isAIDisconnected = false
                        self.disconnectionMessage = ""
                        self.autoReconnectAttempts = 0
                    }
                    self.logToFile("[AI Helper LOG] Auto-reconnected to active Tailscale peer '\(peer.name)' at \(probed.hostURL).")
                    return true
                }
            }
            
            // 3. Still unreachable
            await MainActor.run {
                self.isAIDisconnected = true
                self.disconnectionMessage = "Tailscale Disconnected (Reconnecting...)"
            }
            return false
        }
        
        let running = await isOllamaRunning()
        await MainActor.run {
            if running {
                self.isAIDisconnected = false
                self.disconnectionMessage = ""
                self.autoReconnectAttempts = 0
            }
        }
        return running
    }
    
    func startAutoReconnectMonitor() {
        Task {
            print("[AI Helper] Tailscale auto-reconnect monitor running.")
            while true {
                do {
                    let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
                    let isDisconnected = await MainActor.run { self.isAIDisconnected }
                    
                    if provider == "tailscale" || isDisconnected {
                        if isDisconnected {
                            // When disconnected, actively probe every 3.5 seconds
                            let restored = await self.attemptAutoReconnect()
                            if restored {
                                print("[AI Helper] Auto-reconnect monitor successfully restored connection.")
                            }
                            try await Task.sleep(nanoseconds: 3_500_000_000)
                        } else {
                            // When connected, periodic background check every 15 seconds
                            let online = await self.isOllamaRunning()
                            if !online {
                                await MainActor.run {
                                    self.isAIDisconnected = true
                                    self.disconnectionMessage = "Tailscale Disconnected (Reconnecting...)"
                                }
                                self.logToFile("[AI Helper LOG] Auto-reconnect monitor detected dropped Tailscale link. Initiating auto-reconnect...")
                                _ = await self.attemptAutoReconnect()
                            }
                            try await Task.sleep(nanoseconds: 15_000_000_000)
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    
    func probeTailscaleHost() async -> Bool {
        var host = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty {
            host = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "") else {
            return false
        }
        let url = baseURL.appendingPathComponent("api/version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await probeSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            return false
        } catch {
            return false
        }
    }
    
    func startEngineStatusMonitor() {
        Task {
            print("[AI Helper] Remote engine connectivity monitor running.")
            var probeCounter = 0
            var remoteIsOnline = false
            
            while true {
                do {
                    // Actively probe remote reachability every ~2.4s (every 2 cycles)
                    probeCounter += 1
                    if probeCounter >= 2 || !remoteIsOnline {
                        probeCounter = 0
                        remoteIsOnline = await self.probeTailscaleHost()
                    }
                    
                    let onlineNow = remoteIsOnline
                    await MainActor.run {
                        self.isRemoteOnline = onlineNow
                        self.remoteStatusMessage = onlineNow ? "Connected" : "Not Connected"
                    }
                    
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                } catch {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    // MARK: - API communication helpers
    
    nonisolated func isVisionModelName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream", "pixtral", "gemma3"]
        return visionKeywords.contains { lower.contains($0) }
    }

    func fetchAvailableOllamaModels(host: String? = nil, forceLocal: Bool = false) async -> [String] {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        let targetHost: String
        if let h = host, !h.isEmpty {
            targetHost = h
        } else {
            if provider == "tailscale" {
                let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                targetHost = !tHost.isEmpty ? tHost : vHost
            } else {
                targetHost = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
        }
        
        guard !targetHost.isEmpty else { return [] }
        guard let baseURL = AIHelper.normalizedOllamaURL(from: targetHost, defaultHost: "") else { return [] }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.map { $0.name }.sorted()
        } catch {
            print("[AI Helper] Could not fetch available models from \(url.absoluteString): \(error)")
            return []
        }
    }

    func getOllamaModel(forProvider provider: String? = nil, forceLocal: Bool = false) async -> String {
        let effProvider = forceLocal ? "local" : (provider ?? UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        if effProvider != "local" && effProvider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "cloud_model_name") ?? "gpt-4o-mini"
            return cloudModel
        }
        
        let preferredKey = effProvider == "tailscale" ? "tailscale_model_general" : "local_model_general"
        let preferred = UserDefaults.standard.string(forKey: preferredKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let installed = await fetchAvailableOllamaModels(forceLocal: effProvider == "local")
        if !installed.isEmpty {
            if !preferred.isEmpty && installed.contains(preferred) {
                return preferred
            }
            if !preferred.isEmpty, let match = installed.first(where: { $0.lowercased().contains(preferred.lowercased()) }) {
                return match
            }
            if let nonVision = installed.first(where: { !self.isVisionModelName($0) }) {
                UserDefaults.standard.set(nonVision, forKey: preferredKey)
                return nonVision
            }
            if let firstModel = installed.first {
                UserDefaults.standard.set(firstModel, forKey: preferredKey)
                return firstModel
            }
        }
        
        return preferred
    }
    
    func getOllamaVisionModel(forceLocal: Bool = false) async -> String? {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local"))
        if provider != "local" && provider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
            return cloudModel
        }
        let preferredKey = provider == "tailscale" ? "vision_tailscale_model" : "local_model_vision"
        let preferred = UserDefaults.standard.string(forKey: preferredKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let host: String
        if provider == "tailscale" {
            let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            host = !vHost.isEmpty ? vHost : tHost
        } else {
            host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        }
        
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "") else {
            return !preferred.isEmpty ? preferred : nil
        }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let availableNames = tags.models.map { $0.name }
            
            if !preferred.isEmpty, availableNames.contains(preferred) {
                return preferred
            }
            if !preferred.isEmpty, let match = availableNames.first(where: { $0.lowercased() == preferred.lowercased() }) {
                return match
            }
            
            for m in tags.models {
                if isVisionModelName(m.name) {
                    UserDefaults.standard.set(m.name, forKey: preferredKey)
                    return m.name
                }
            }
            
            if let first = availableNames.first {
                UserDefaults.standard.set(first, forKey: preferredKey)
                return first
            }
        } catch {
            print("[AI Helper] Warning: Error checking for vision model: \(error)")
        }
        
        return !preferred.isEmpty ? preferred : nil
    }
    
    func hasRepetitiveGlitch(_ text: String) -> Bool {
        // Match 5 or more identical characters in a row, excluding spaces, dashes, asterisks, equals, dots, underscores, and newlines
        let pattern = "([^ \\-\\*=\\._\\n\\r])\\1{4,}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
    
    // MARK: - Fast Network Pre-Flight & Local Fallback
    
    public func isTailscaleReachable() async -> Bool {
        let host = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "") else { return false }
        let tagsUrl = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: tagsUrl)
        req.timeoutInterval = 2.5
        if let (data, resp) = try? await session.data(for: req),
           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
           let tags = try? JSONDecoder().decode(TagsResponse.self, from: data),
           !tags.models.isEmpty {
            return true
        }
        return false
    }
    
    private func fallbackToLocalOllama(
        prompt: String,
        images: [String]? = nil,
        timeout: TimeInterval,
        options: OllamaOptions? = nil,
        overrideThink: Bool? = nil
    ) async -> String? {
        await ensureLocalOllamaRunning()
        let localHost = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        guard let localBaseURL = AIHelper.normalizedOllamaURL(from: localHost, defaultHost: "http://localhost:11434") else { return nil }
        let tagsUrl = localBaseURL.appendingPathComponent("api/tags")
        var checkReq = URLRequest(url: tagsUrl)
        checkReq.timeoutInterval = 2.0
        
        let hasModels: Bool
        if let (data, resp) = try? await session.data(for: checkReq),
           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
           let tags = try? JSONDecoder().decode(TagsResponse.self, from: data),
           !tags.models.isEmpty {
            hasModels = true
        } else {
            hasModels = false
        }
        
        guard hasModels else {
            self.logToFile("[AI Helper LOG] Local Ollama fallback unavailable (no models or server offline).")
            return nil
        }
        
        let fallbackModel: String
        if images != nil && !(images?.isEmpty ?? true) {
            fallbackModel = await getOllamaVisionModel(forceLocal: true) ?? ""
        } else {
            fallbackModel = await getOllamaModel(forceLocal: true)
        }
        guard !fallbackModel.isEmpty else {
            self.logToFile("[AI Helper LOG] Fallback to Local Ollama failed: no local model available.")
            return nil
        }
        self.logToFile("[AI Helper LOG] Seamlessly falling back to Local Ollama with model '\(fallbackModel)'...")
        if let localResult = await callAPIOnce(prompt: prompt, model: fallbackModel, images: images, timeout: timeout, provider: "local", options: options, overrideThink: overrideThink) {
            if !hasRepetitiveGlitch(localResult) {
                return localResult
            }
        }
        return nil
    }

    func callOllama(
        prompt: String,
        model: String,
        images: [String]? = nil,
        timeout: TimeInterval = 300.0,
        forceLocal: Bool = false,
        overrideProvider: String? = nil,
        options: OllamaOptions? = nil,
        overrideThink: Bool? = nil
    ) async -> String? {
        let hasImages = images != nil && !(images?.isEmpty ?? true)
        let isWasBusy = self.isAIBusy
        
        let effectiveProvider: String
        if let ov = overrideProvider, !ov.isEmpty {
            effectiveProvider = ov
        } else if forceLocal {
            effectiveProvider = "local"
        } else if hasImages {
            effectiveProvider = UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        } else {
            effectiveProvider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        }
        
        if !isWasBusy {
            let taskDesc: String
            if effectiveProvider == "tailscale" {
                taskDesc = hasImages ? "Processing Tailscale Vision Request..." : "Processing Tailscale AI Request..."
            } else if effectiveProvider == "local" {
                taskDesc = hasImages ? "Processing Local Vision Request..." : "Processing Local AI Request..."
            } else {
                let pName = self.providerInfo(for: effectiveProvider, isVision: hasImages).name
                taskDesc = hasImages ? "Processing \(pName) Vision Request..." : "Processing \(pName) Request..."
            }
            startAITask(
                description: taskDesc,
                isVision: hasImages,
                forceLocal: effectiveProvider == "local",
                provider: effectiveProvider
            )
        }
        defer {
            if !isWasBusy {
                finishAITask(force: true)
            }
        }
        
        let targetModel: String
        let effectiveImages: [String]? = images
        
        if effectiveProvider == "tailscale" {
            let prefModel = hasImages ?
                (UserDefaults.standard.string(forKey: "vision_tailscale_model") ?? "") :
                (UserDefaults.standard.string(forKey: "tailscale_model_general") ?? "")
            let resolvedPref = !prefModel.isEmpty ? prefModel : (hasImages ? (await getOllamaVisionModel() ?? "") : (await getOllamaModel()))
            targetModel = model.isEmpty ? resolvedPref : model
            self.logToFile("[AI Helper LOG] \(hasImages ? "Vision" : "Text") request using Tailscale model (\(effectiveProvider)): \(targetModel)")
        } else if effectiveProvider == "local" {
            await ensureLocalOllamaRunning()
            let prefModel = hasImages ?
                (UserDefaults.standard.string(forKey: "local_model_vision") ?? "") :
                (UserDefaults.standard.string(forKey: "local_model_general") ?? "")
            let resolvedPref = !prefModel.isEmpty ? prefModel : (hasImages ? (await getOllamaVisionModel(forceLocal: true) ?? "") : (await getOllamaModel(forceLocal: true)))
            targetModel = model.isEmpty ? resolvedPref : model
            self.logToFile("[AI Helper LOG] \(hasImages ? "Vision" : "Text") request using local model: \(targetModel)")
        } else {
            let prefModel = hasImages ?
                (UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o") :
                (UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud")
            targetModel = model.isEmpty ? prefModel : model
            self.logToFile("[AI Helper LOG] \(hasImages ? "Vision" : "Text") request using cloud model (\(effectiveProvider)): \(targetModel)")
        }
        
        // Fast pre-flight check if Tailscale is selected
        if effectiveProvider == "tailscale" && !forceLocal {
            if let lastTimeout = self.lastTailscaleTimeoutTime, Date().timeIntervalSince(lastTimeout) < self.tailscaleCooldownSeconds {
                let remaining = Int(self.tailscaleCooldownSeconds - Date().timeIntervalSince(lastTimeout))
                self.logToFile("[AI Helper LOG] Tailscale in cooldown after recent timeout (\(remaining)s remaining). Bypassing remote call and falling back to Local Ollama immediately.")
                if let fallbackResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                    return fallbackResult
                }
            }
            
            let reachable = await isTailscaleReachable()
            if !reachable {
                self.logToFile("[AI Helper LOG] Fast pre-flight probe: Tailscale host unreachable (link down or server stopped). Bypassing remote retries and immediately falling back to Local Ollama.")
                if let fallbackResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                    return fallbackResult
                }
            }
        }
        
        let maxRetries = (effectiveProvider == "tailscale") ? 1 : 3
        for attempt in 1...maxRetries {
            self.logToFile("[AI Helper LOG] callOllama (\(effectiveProvider)) attempt \(attempt)/\(maxRetries) for model: \(targetModel)")
            // Cap per-attempt remote timeout to 90s to avoid indefinite hangs
            let perAttemptTimeout = (effectiveProvider == "tailscale") ? min(timeout, 90.0) : timeout
            if let result = await callAPIOnce(prompt: prompt, model: targetModel, images: effectiveImages, timeout: perAttemptTimeout, provider: effectiveProvider, options: options, overrideThink: overrideThink) {
                if hasRepetitiveGlitch(result) {
                    self.logToFile("[AI Helper LOG] Repetitive glitch detected (attempt \(attempt)/\(maxRetries)): '\(result.prefix(100))...'")
                    continue
                }
                if effectiveProvider == "tailscale" {
                    self.lastTailscaleTimeoutTime = nil
                }
                await MainActor.run {
                    if self.isAIDisconnected {
                        self.isAIDisconnected = false
                        self.disconnectionMessage = ""
                        self.autoReconnectAttempts = 0
                    }
                }
                return result
            } else {
                self.logToFile("[AI Helper LOG] callAPIOnce returned nil (attempt \(attempt)/\(maxRetries))")
                if effectiveProvider == "tailscale" {
                    self.lastTailscaleTimeoutTime = Date()
                    self.logToFile("[AI Helper LOG] Tailscale request failed or timed out. Entering 3-minute cooldown and immediately falling back to Local Ollama...")
                    if let localResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                        return localResult
                    }
                    break
                } else if effectiveProvider != "local" {
                    self.logToFile("[AI Helper LOG] Cloud provider (\(effectiveProvider)) request failed or timed out; skipping duplicate retries.")
                    break
                } else if attempt < maxRetries {
                    let online = await self.isOllamaRunning()
                    if !online {
                        self.logToFile("[AI Helper LOG] AI host unreachable on attempt \(attempt), stopping retries.")
                        break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        
        // Automatic Fallback: If Tailscale was unreachable, check if Local Ollama is available
        if effectiveProvider == "tailscale" && !forceLocal {
            if let localResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                return localResult
            }
        }
        
        await MainActor.run {
            self.isAIDisconnected = true
            if effectiveProvider == "tailscale" {
                self.disconnectionMessage = "Tailscale Disconnected"
            } else if effectiveProvider == "local" {
                self.disconnectionMessage = "Ollama Server Offline"
            } else {
                let name = self.providerInfo(for: effectiveProvider).name
                self.disconnectionMessage = "\(name) Disconnected"
            }
            self.isAIBusy = false
            self.isProcessing = false
            self.activeProcessingNoteIds.removeAll()
            self.finishAITask(force: true)
        }
        return nil
    }
    
    private func callAPIOnce(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval, provider: String, options: OllamaOptions? = nil, overrideThink: Bool? = nil) async -> String? {
        if provider == "local" || provider == "tailscale" {
            let host: String
            if provider == "tailscale" {
                if images != nil {
                    let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    host = !vHost.isEmpty ? vHost : tHost
                } else {
                    host = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
                }
            } else {
                host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
            guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "http://localhost:11434") else {
                self.logToFile("[AI Helper LOG] No valid host configured for \(provider).")
                return nil
            }
            let url = baseURL.appendingPathComponent("api/generate")
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            
            let isVision = (provider == "cloud_vision") || (images != nil && !(images?.isEmpty ?? true))
            let defaultThinking: Bool
            if provider == "local" {
                if isVision {
                    defaultThinking = UserDefaults.standard.bool(forKey: "local_vision_thinking_enabled")
                } else {
                    defaultThinking = UserDefaults.standard.object(forKey: "local_text_thinking_enabled") != nil
                        ? UserDefaults.standard.bool(forKey: "local_text_thinking_enabled")
                        : UserDefaults.standard.bool(forKey: "ai_text_thinking_enabled")
                }
            } else {
                if isVision {
                    defaultThinking = UserDefaults.standard.bool(forKey: "remote_vision_thinking_enabled")
                } else {
                    defaultThinking = UserDefaults.standard.object(forKey: "remote_text_thinking_enabled") != nil
                        ? UserDefaults.standard.bool(forKey: "remote_text_thinking_enabled")
                        : UserDefaults.standard.bool(forKey: "ai_text_thinking_enabled")
                }
            }
            let requestedThink = overrideThink ?? defaultThinking
            let thinkingEnabled = requestedThink && isModelThinkingCapable(model)
            
            self.logToFile("[AI Helper LOG] Calling \(provider) Ollama (\(model), \(isVision ? "vision" : "text"), think: \(thinkingEnabled), streaming: true)...")
            let body = GenerateRequest(model: model, prompt: prompt, stream: true, images: images, options: options, think: thinkingEnabled)
            do {
                request.httpBody = try JSONEncoder().encode(body)
                let (asyncBytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.logToFile("[AI Helper LOG] Non-HTTP response from \(provider) Ollama")
                    return nil
                }
                if httpResponse.statusCode != 200 {
                    self.logToFile("[AI Helper LOG] HTTP \(httpResponse.statusCode) from \(provider) Ollama (\(url.absoluteString))")
                    return nil
                }
                
                var accumulatedResponse = ""
                var chunkCount = 0
                var isDone = false
                
                for try await line in asyncBytes.lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedLine.isEmpty else { continue }
                    
                    guard let lineData = trimmedLine.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(GenerateResponse.self, from: lineData) else {
                        continue
                    }
                    
                    if let err = chunk.error, !err.isEmpty {
                        self.logToFile("[AI Helper LOG] \(provider) streaming chunk error: \(err)")
                        return nil
                    }
                    
                    if let resp = chunk.response {
                        accumulatedResponse += resp
                        chunkCount += 1
                    }
                    if let th = chunk.thinking, !th.isEmpty {
                        chunkCount += 1
                    }
                    
                    if chunkCount % 4 == 0 {
                        await MainActor.run {
                            self.batchTokensGenerated += 4
                            self.lastStreamingActivityDate = Date()
                        }
                    }
                    
                    if chunk.done == true {
                        isDone = true
                        break
                    }
                }
                
                await MainActor.run {
                    self.lastStreamingActivityDate = Date()
                }
                
                var cleanText = accumulatedResponse.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                cleanText = cleanText.replacingOccurrences(of: #"(?i)\[/?think\]"#, with: "", options: .regularExpression)
                let trimmed = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty && !isDone {
                    self.logToFile("[AI Helper LOG] \(provider) stream ended without completing.")
                    return nil
                }
                return trimmed
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with \(provider) Ollama (\(url.absoluteString)): \(error.localizedDescription)")
                return nil
            }
        } else {
            let isVisionTask = (provider == "cloud_vision") || (images != nil && !(images?.isEmpty ?? true))
            
            var baseUrl = ""
            var apiKey = ""
            
            if isVisionTask {
                let vBase = UserDefaults.standard.string(forKey: "vision_api_base_url")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let vKey = UserDefaults.standard.string(forKey: "vision_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !vBase.isEmpty {
                    baseUrl = vBase
                    apiKey = vKey
                }
            }
            
            if baseUrl.isEmpty {
                baseUrl = UserDefaults.standard.string(forKey: "cloud_api_base_url")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                apiKey = UserDefaults.standard.string(forKey: "cloud_api_key") ?? ""
            }
            
            let cleanBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let isAnthropic = cleanBase.contains("anthropic.com") || provider == "anthropic" || model.lowercased().contains("claude")
            let isGemini = cleanBase.contains("generativelanguage.googleapis.com") || provider == "gemini" || model.lowercased().contains("gemini")
            
            let endpoint: String
            if isAnthropic {
                if cleanBase.isEmpty {
                    endpoint = "https://api.anthropic.com/v1/messages"
                } else if cleanBase.hasSuffix("/messages") {
                    endpoint = cleanBase
                } else if cleanBase.hasSuffix("/v1") {
                    endpoint = "\(cleanBase)/messages"
                } else {
                    endpoint = "\(cleanBase)/v1/messages"
                }
            } else if isGemini {
                if cleanBase.contains("/openai") {
                    if cleanBase.hasSuffix("/chat/completions") {
                        endpoint = cleanBase
                    } else {
                        endpoint = "\(cleanBase)/chat/completions"
                    }
                } else {
                    endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
                }
            } else {
                if cleanBase.isEmpty {
                    endpoint = "https://api.openai.com/v1/chat/completions"
                } else if cleanBase.hasSuffix("/chat/completions") {
                    endpoint = cleanBase
                } else if cleanBase.hasSuffix("/v1") {
                    endpoint = "\(cleanBase)/chat/completions"
                } else {
                    endpoint = "\(cleanBase)/v1/chat/completions"
                }
            }
            
            guard let url = URL(string: endpoint) else {
                self.logToFile("[AI Helper LOG] Invalid API Base URL configured: '\(baseUrl)' (resolved endpoint: '\(endpoint)')")
                return nil
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            
            if isAnthropic {
                if !apiKey.isEmpty {
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                }
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                if !apiKey.isEmpty {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
            }
            
            do {
                let maxOutTokens = options?.num_predict ?? 8192
                if isAnthropic {
                    var contentBlocks: [[String: Any]] = []
                    
                    if let images = images {
                        for imgBase64 in images {
                            var cleanBase64 = imgBase64
                            if let commaIdx = cleanBase64.firstIndex(of: ",") {
                                cleanBase64 = String(cleanBase64[cleanBase64.index(after: commaIdx)...])
                            }
                            cleanBase64 = cleanBase64.trimmingCharacters(in: .whitespacesAndNewlines)
                            let mediaType = cleanBase64.hasPrefix("/9j/") ? "image/jpeg" : "image/png"
                            contentBlocks.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": cleanBase64
                                ]
                            ])
                        }
                    }
                    
                    contentBlocks.append([
                        "type": "text",
                        "text": prompt
                    ])
                    
                    let anthropicBody: [String: Any] = [
                        "model": model,
                        "max_tokens": maxOutTokens,
                        "messages": [
                            [
                                "role": "user",
                                "content": contentBlocks
                            ]
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: anthropicBody, options: [])
                } else {
                    var messagesContent: [[String: Any]] = []
                    messagesContent.append([
                        "type": "text",
                        "text": prompt
                    ])
                    
                    if let images = images {
                        for imgBase64 in images {
                            var cleanBase64 = imgBase64
                            if let commaIdx = cleanBase64.firstIndex(of: ",") {
                                cleanBase64 = String(cleanBase64[cleanBase64.index(after: commaIdx)...])
                            }
                            cleanBase64 = cleanBase64.trimmingCharacters(in: .whitespacesAndNewlines)
                            let mediaType = cleanBase64.hasPrefix("/9j/") ? "image/jpeg" : "image/png"
                            messagesContent.append([
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:\(mediaType);base64,\(cleanBase64)"
                                ]
                            ])
                        }
                    }
                    
                    var bodyDict: [String: Any] = [
                        "model": model,
                        "max_tokens": maxOutTokens,
                        "messages": [
                            [
                                "role": "user",
                                "content": images != nil ? messagesContent as Any : prompt as Any
                            ]
                        ],
                        "stream": false
                    ]
                    if let temp = options?.temperature {
                        bodyDict["temperature"] = temp
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
                }
                
                let (data, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let errBody = String(data: data, encoding: .utf8) ?? ""
                    self.logToFile("[AI Helper LOG] HTTP \(httpResponse.statusCode) from \(provider) (\(url.absoluteString)): \(errBody)")
                    return nil
                }
                
                if let responseJSON = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    if isAnthropic {
                        if let contentArray = responseJSON["content"] as? [[String: Any]] {
                            let textParts = contentArray.compactMap { block -> String? in
                                if (block["type"] as? String) == "text" {
                                    return block["text"] as? String
                                }
                                return nil
                            }
                            let combined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !combined.isEmpty {
                                return combined
                            }
                        } else if let errorDict = responseJSON["error"] as? [String: Any],
                                   let msg = errorDict["message"] as? String {
                            self.logToFile("[AI Helper LOG] Anthropic error message: \(msg)")
                            return nil
                        }
                    } else {
                        if let choices = responseJSON["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let message = firstChoice["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            return content.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let errorDict = responseJSON["error"] as? [String: Any],
                                  let msg = errorDict["message"] as? String {
                            self.logToFile("[AI Helper LOG] Cloud API error message: \(msg)")
                            return nil
                        }
                    }
                }
                
                let rawString = String(data: data, encoding: .utf8) ?? "Unable to decode string"
                self.logToFile("[AI Helper LOG] Unexpected \(provider) response structure: \(rawString)")
                return nil
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with \(provider) API (\(url)): \(error.localizedDescription)")
                return nil
            }
        }
    }
    
    func pullOllamaModel(modelName: String) async -> Bool {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let host = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "tailscale_host") ?? "") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        guard !host.isEmpty, let bURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: provider == "tailscale" ? "" : "http://localhost:11434") else { return false }
        let url = bURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600.0
        
        let body = PullRequest(model: modelName, stream: false)
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("[AI Helper] Successfully pulled model \(modelName)")
                return true
            }
        } catch {
            print("[AI Helper] Error pulling model \(modelName): \(error)")
        }
        return false
    }
    
    // MARK: - Unified Extraction & Transcription Disk Cache
    
    private var transcriptionCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ProjectNobel/transcription_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func transcriptionCacheKey(for path: String, isAnswer: Bool) -> String {
        var key = path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let modDate = attrs[.modificationDate] as? Date,
           let size = attrs[.size] as? Int {
            key += "_\(Int(modDate.timeIntervalSince1970))_\(size)"
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        let hexString = digest.compactMap { String(format: "%02x", $0) }.joined()
        let suffix = isAnswer ? "_answers.json" : "_questions.json"
        return "\(hexString)\(suffix)"
    }
    
    public func clearTranscriptionCache() {
        let dir = transcriptionCacheDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files {
                try? FileManager.default.removeItem(at: f)
            }
        }
        self.logToFile("[AI Batch Importer LOG] Cleared all cached transcriptions from disk.")
    }
    
    // MARK: - Automated Cross-Page Boundary Stitcher (Solution 1)
    
    public func stitchExtractedProblems(rawProblems: [ExtractedProblem]) async -> [ExtractedProblem] {
        guard rawProblems.count > 1 else { return rawProblems }
        
        let preSplitProblems = preSplitProblemHeaders(rawProblems: rawProblems)
        guard preSplitProblems.count > 1 else { return preSplitProblems }
        
        // 1. Primary AI Problem Stitcher
        if let aiStitched = await stitchProblemsWithAIModel(fragments: preSplitProblems), !aiStitched.isEmpty {
            self.logToFile("[AI Batch Importer LOG] AI problem stitching complete: consolidated \(preSplitProblems.count) fragments into \(aiStitched.count) unified problems.")
            return aiStitched
        }
        
        // 2. Deterministic Fallback if AI server unavailable
        self.logToFile("[AI Batch Importer LOG] AI problem stitching unavailable or failed; executing deterministic boundary stitcher fallback.")
        return stitchExtractedProblemsDeterministically(preSplitProblems: preSplitProblems)
    }
    
    /// Pre-splits any single extracted problem that contains embedded problem headers
    /// (e.g. OCR bundled continuation of Problem 2 and "Problem 3:" into one block)
    public func preSplitProblemHeaders(rawProblems: [ExtractedProblem]) -> [ExtractedProblem] {
        var preSplitProblems = [ExtractedProblem]()
        let probHeaderPattern = #"(?m)^(?=(?:Problem|Question|Exercise|Task)\s+\d+[:\.\s])"#
        
        for item in rawProblems {
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let regex = try? NSRegularExpression(pattern: probHeaderPattern, options: [.caseInsensitive]) {
                let nsContent = content as NSString
                let matches = regex.matches(in: content, options: [], range: NSRange(location: 0, length: nsContent.length))
                let needsSplit = matches.contains { $0.range.location > 0 }
                if needsSplit {
                    var lastIndex = 0
                    for match in matches {
                        let splitLoc = match.range.location
                        if splitLoc > lastIndex {
                            let part = nsContent.substring(with: NSRange(location: lastIndex, length: splitLoc - lastIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
                            if !part.isEmpty {
                                var splitItem = item
                                splitItem.id = UUID()
                                splitItem.content = part
                                preSplitProblems.append(splitItem)
                            }
                        }
                        lastIndex = splitLoc
                    }
                    if lastIndex < nsContent.length {
                        let remaining = nsContent.substring(with: NSRange(location: lastIndex, length: nsContent.length - lastIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !remaining.isEmpty {
                            var splitItem = item
                            splitItem.id = UUID()
                            splitItem.content = remaining
                            preSplitProblems.append(splitItem)
                        }
                    }
                    continue
                }
            }
            preSplitProblems.append(item)
        }
        return preSplitProblems
    }
    
    /// AI-powered problem stitcher: uses LLM semantic reasoning to consolidate split problem fragments
    public func stitchProblemsWithAIModel(fragments: [ExtractedProblem]) async -> [ExtractedProblem]? {
        await withUserPriority {
            let provider = taskProvider(for: "route_stitching", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            self.logToFile("[AI Batch Importer LOG] Calling AI model '\(model)' (\(provider)) to stitch \(fragments.count) page fragments...")
            
            await MainActor.run {
                self.pipelineCurrentPhase = "AI Stitching Problems..."
                if provider == "local" {
                    self.isLocalActive = true
                    self.localTaskStatus = "AI Stitching (\(fragments.count) fragments)..."
                } else {
                    self.isRemoteActive = true
                    self.remoteTaskStatus = "AI Stitching (\(fragments.count) fragments)..."
                }
            }
            defer {
                Task { @MainActor in
                    self.isLocalActive = false
                    self.isRemoteActive = false
                }
            }
            
            var fragmentList = [String]()
            for (idx, f) in fragments.enumerated() {
                fragmentList.append("""
                [FRAGMENT \(idx + 1)]
                \(f.content.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
            }
            let fragmentsBody = fragmentList.joined(separator: "\n\n")
            
            let prompt = """
            You are an expert university physics educator and document reconstruction assistant.
            Below are \(fragments.count) sequentially extracted text fragments from consecutive pages of a physics problem set.
            Due to PDF page breaks, some problems are split across consecutive fragments (for example, Fragment 1 contains part (a) at the bottom of a page, and Fragment 2 contains parts (b) and (c) at the top of the next page).
            
            Your task:
            Reconstruct and output the exact list of complete, individual, unified physics problems by stitching together consecutive fragments that belong to the same problem.
            
            Strict Rules:
            1. Consolidate consecutive fragments that belong to the same physics problem into a single complete problem.
            2. Eliminate any page seam artifacts (such as "Continued overleaf", "Page X of Y", "Turn over", or repeated problem headers at page boundaries).
            3. Preserve ALL physics formulas, mathematical variables, and LaTeX delimiters ($...$ for inline, $$...$$ for block equations) with 100% exact fidelity. Do NOT summarize, shorten, or alter any questions or numbers.
            4. Retain all subparts (e.g. (a), (b), (c) and (i), (ii), (iii)) in the unified question. Do NOT prefix top-level numbers like "Problem 1:" or "1." because the application handles problem numbering.
            5. Output each reconstructed problem strictly in this format:
            [PROBLEM]
            Question: <complete question statement with all subparts and LaTeX>
            Hint: <concise solution hint with LaTeX if present, or leave empty>
            [PROBLEM]
            
            Output ONLY the [PROBLEM] blocks. Do NOT include any introductory or conversational text.
            
            Sequential Fragments:
            ---
            \(fragmentsBody)
            ---
            """
            
            let response = await callOllama(prompt: prompt, model: model, timeout: 180.0, overrideProvider: provider)
            
            guard let rawText = response, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            
            let normalized = normalizeLaTeXDelimiters(rawText)
            let parsed = parseExtractedProblems(normalized)
            guard !parsed.isEmpty else { return nil }
            
            var cleaned = [ExtractedProblem]()
            for var p in parsed {
                p.content = cleanQuestionContent(p.content)
                cleaned.append(p)
            }
            return cleaned
        }
    }
    
    /// Deterministic boundary stitcher fallback
    public func stitchExtractedProblemsDeterministically(preSplitProblems: [ExtractedProblem]) -> [ExtractedProblem] {
        var merged = [ExtractedProblem]()
        var i = 0
        while i < preSplitProblems.count {
            var cur = preSplitProblems[i]
            while i + 1 < preSplitProblems.count {
                let nxt = preSplitProblems[i + 1]
                let (isCont, reason) = isProblemContinuation(prevContent: cur.content, nextContent: nxt.content)
                if isCont {
                    self.logToFile("[AI Batch Importer LOG] Stitching problem fragment \(i + 1) with fragment \(i + 2) (\(reason))")
                    cur.content = mergeFragmentContents(c1: cur.content, c2: nxt.content)
                    if cur.solutionHint.isEmpty && !nxt.solutionHint.isEmpty {
                        cur.solutionHint = nxt.solutionHint
                    }
                    if cur.solution.isEmpty && !nxt.solution.isEmpty {
                        cur.solution = nxt.solution
                    }
                    if !nxt.steps.isEmpty {
                        cur.steps.append(contentsOf: nxt.steps)
                    }
                    i += 1
                } else {
                    break
                }
            }
            cur.content = cleanQuestionContent(cur.content)
            merged.append(cur)
            i += 1
        }
        return merged
    }
    
    private func isProblemContinuation(prevContent: String, nextContent: String) -> (Bool, String) {
        var strippedNext = nextContent.trimmingCharacters(in: .whitespacesAndNewlines)
        strippedNext = strippedNext.replacingOccurrences(of: #"^[#*`\s]+"#, with: "", options: .regularExpression)
        let strippedPrev = prevContent.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if strippedNext.isEmpty { return (false, "") }
        
        // 1. Lowercase start (mid-sentence continuation, e.g. "for some real...", "second eigenstate...")
        if let firstChar = strippedNext.first, firstChar.isLetter && firstChar.isLowercase {
            return (true, "lowercase sentence continuation")
        }
        
        // 2. Starts with continuation punctuation or math (e.g. ",", ";", ")", "=", "+", "-", "$$")
        let contPunctuation = [",", ";", ")", "=", "+", "-", "$$"]
        for p in contPunctuation {
            if strippedNext.starts(with: p) {
                return (true, "continuation punctuation '\(p)'")
            }
        }
        let contWords = ["and ", "where ", "such that ", "with ", "in the case of "]
        for w in contWords {
            if strippedNext.lowercased().starts(with: w) {
                return (true, "continuation conjunction '\(w.trimmingCharacters(in: .whitespaces))'")
            }
        }
        
        // 3. Previous ended with incomplete phrase or dangling conjunction
        let prevIncompletePattern = #"(?:and|such that|Find this|with|is|the|where|in the case of the|for the position and|\,,|\,)\s*$"#
        if let regex = try? NSRegularExpression(pattern: prevIncompletePattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: (strippedPrev as NSString).length)
            if regex.firstMatch(in: strippedPrev, options: [], range: range) != nil {
                return (true, "previous fragment ended with incomplete phrase")
            }
        }
        
        // 4. Next starts with continuation subpart (b), (c), (ii), (iii), etc.
        // Standalone questions never start with (b), (c), or (ii)
        let subpartPattern = #"^\(?([b-fB-F]|ii|iii|iv|v|vi)\)[\.\s]"#
        if let regex = try? NSRegularExpression(pattern: subpartPattern, options: []) {
            let range = NSRange(location: 0, length: (strippedNext as NSString).length)
            if let m = regex.firstMatch(in: strippedNext, options: [], range: range), m.range.location == 0 {
                return (true, "continuation subpart letter")
            }
        }
        
        // 5. Overlap detection (page boundary OCR repeated text snippet)
        let sampleLen = min(40, strippedNext.count)
        if sampleLen >= 20 {
            let prefix = String(strippedNext.prefix(sampleLen))
            if strippedPrev.contains(prefix) {
                return (true, "page boundary overlap bleed")
            }
        }
        
        return (false, "")
    }
    
    private func mergeFragmentContents(c1: String, c2: String) -> String {
        var trimmed1 = c1.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmed2 = c2.trimmingCharacters(in: .whitespacesAndNewlines)
        
        trimmed1 = trimmed1.replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
        trimmed1 = trimmed1.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        trimmed2 = trimmed2.replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
        trimmed2 = trimmed2.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for boundary overlap to deduplicate bleed
        let maxOverlap = min(120, trimmed2.count)
        if maxOverlap >= 20 {
            for testLen in stride(from: maxOverlap, through: 20, by: -1) {
                let snip = String(trimmed2.prefix(testLen))
                if let range = trimmed1.range(of: snip, options: .backwards) {
                    let nonOverlappingPrefix = String(trimmed1[..<range.lowerBound])
                    return nonOverlappingPrefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + trimmed2
                }
            }
        }
        
        return trimmed1 + "\n\n" + trimmed2
    }
    
    /// Unified extraction: renders PDF pages to images and transcribes via the visual AI model, caching results to disk to avoid repeated OCR.
    func extractProblemsUnified(item: ExtractionQueueItem, onPageExtracted: (@MainActor ([ExtractedProblem]) async -> Void)? = nil) async -> [ExtractedProblem] {
        if item.type == .pdf {
            let pdfPath = item.pathOrName
            let cacheURL = transcriptionCacheDirectory.appendingPathComponent(transcriptionCacheKey(for: pdfPath, isAnswer: false))
            
            // 1. Check persistent disk cache first (problems are already boundary-stitched and cleaned)
            if let cachedData = try? Data(contentsOf: cacheURL),
               let cachedProblems = try? JSONDecoder().decode([ExtractedProblem].self, from: cachedData),
               !cachedProblems.isEmpty {
                self.logToFile("[AI Batch Importer LOG] Using cached visual question transcription for '\(pdfPath)' (\(cachedProblems.count) problems). Skipping visual OCR.")
                self.addBatchLiveEvent("Question OCR loaded from cache (\(cachedProblems.count) problems).")
                await MainActor.run {
                    let pageCount = PDFDocument(url: URL(fileURLWithPath: pdfPath))?.pageCount ?? 1
                    self.localPagesCompleted = min(self.localPagesTotal, self.localPagesCompleted + pageCount)
                    self.localTaskStatus = "Done (Loaded from Cache)"
                    self.isLocalActive = false
                }
                if let onPageExtracted = onPageExtracted {
                    await onPageExtracted(cachedProblems)
                }
                return cachedProblems
            }
            
            // 2. Perform local visual OCR
            self.logToFile("[AI Batch Importer LOG] PDF '\(pdfPath)' — rendering page images for visual AI transcription")
            let images = convertPDFToImages(path: pdfPath, maxPages: 100)
            self.addBatchLiveEvent("Rendering \(images.count) PDF pages for visual OCR.")
            await MainActor.run {
                self.isLocalActive = true
                self.isRemoteActive = false
                self.localPagesTotal = max(self.localPagesTotal, images.count)
                self.localTaskStatus = "Transcribing page 1 of \(images.count)..."
                self.pipelineCurrentPhase = "Phase 1/2: Local OCR"
            }
            var allProblems = [ExtractedProblem]()
            for (idx, base64) in images.enumerated() {
                await MainActor.run {
                    self.localTaskStatus = "Transcribing page \(idx + 1) of \(images.count)..."
                }
                self.logToFile("[AI Batch Importer LOG] Visual transcription for page \(idx + 1)/\(images.count) of \(pdfPath)")
                if let rawText = await extractProblemsFromImage(base64Image: base64) {
                    if rawText != "MODEL_NOT_FOUND" && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let normalized = normalizeLaTeXDelimiters(rawText)
                        let parsed = parseExtractedProblems(normalized)
                        self.logToFile("[AI Batch Importer LOG] Page \(idx + 1) parsed \(parsed.count) problems.")
                        self.addBatchLiveEvent("Page \(idx + 1)/\(images.count): \(parsed.count) candidate questions parsed.")
                        allProblems.append(contentsOf: parsed)
                        if let onPageExtracted = onPageExtracted {
                            await onPageExtracted(parsed)
                        }
                    }
                }
                await MainActor.run {
                    self.localPagesCompleted = min(self.localPagesTotal, self.localPagesCompleted + 1)
                }
            }
            
            // Local Visual OCR is now complete
            await MainActor.run {
                self.localPagesCompleted = self.localPagesTotal
                self.localTaskStatus = "Done (\(images.count) pgs OCR'd)"
                self.isLocalActive = false
            }
            
            // 2b. Automatically stitch problems that were split across PDF page boundaries (Text AI on Remote Engine)
            if images.count > 1 && allProblems.count > 1 {
                self.logToFile("[AI Batch Importer LOG] Running automated boundary stitcher on \(allProblems.count) raw page fragments...")
                self.addBatchLiveEvent("Stitching \(allProblems.count) raw fragments across PDF page boundaries...")
                let stitched = await self.stitchExtractedProblems(rawProblems: allProblems)
                self.logToFile("[AI Batch Importer LOG] Stitching complete: consolidated \(allProblems.count) fragments into \(stitched.count) unified problems.")
                self.addBatchLiveEvent("Consolidated into \(stitched.count) unified questions.")
                allProblems = stitched
            }
            
            // 3. Persist unified problems to disk cache
            if !allProblems.isEmpty, let encoded = try? JSONEncoder().encode(allProblems) {
                try? encoded.write(to: cacheURL)
                self.logToFile("[AI Batch Importer LOG] Saved \(allProblems.count) problems to transcription disk cache for '\(pdfPath)'.")
            }
            return allProblems
        } else if item.type == .image, let base64 = item.imageBase64 {
            self.logToFile("[AI Batch Importer LOG] Using visual AI model for image: \(item.pathOrName)")
            if let rawText = await extractProblemsFromImage(base64Image: base64) {
                if rawText != "MODEL_NOT_FOUND" && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let normalized = normalizeLaTeXDelimiters(rawText)
                    let parsed = parseExtractedProblems(normalized)
                    self.logToFile("[AI Batch Importer LOG] Image parsed \(parsed.count) problems.")
                    if let onPageExtracted = onPageExtracted {
                        await onPageExtracted(parsed)
                    }
                    return parsed
                }
            }
        }
        return []
    }
    
    func extractAnswersUnified(item: ExtractionQueueItem, onPageExtracted: (@MainActor ([ExtractedAnswer]) async -> Void)? = nil) async -> [ExtractedAnswer] {
        if item.type == .pdf {
            let pdfPath = item.pathOrName
            let cacheURL = transcriptionCacheDirectory.appendingPathComponent(transcriptionCacheKey(for: pdfPath, isAnswer: true))
            
            // 1. Check persistent disk cache first
            if let cachedData = try? Data(contentsOf: cacheURL),
               let cachedAnswers = try? JSONDecoder().decode([ExtractedAnswer].self, from: cachedData),
               !cachedAnswers.isEmpty {
                self.logToFile("[AI Batch Importer LOG] Using cached visual answer extraction for '\(pdfPath)' (\(cachedAnswers.count) answers). Skipping visual OCR.")
                let pageCount = PDFDocument(url: URL(fileURLWithPath: pdfPath))?.pageCount ?? 1
                await MainActor.run {
                    self.localPagesCompleted = min(self.localPagesTotal, self.localPagesCompleted + pageCount)
                }
                if let onPageExtracted = onPageExtracted {
                    await onPageExtracted(cachedAnswers)
                }
                return cachedAnswers
            }
            
            // 2. Perform local visual OCR
            self.logToFile("[AI Batch Importer LOG] PDF '\(pdfPath)' — rendering page images for visual AI answer extraction")
            let images = convertPDFToImages(path: pdfPath, maxPages: 100)
            await MainActor.run {
                self.isLocalActive = true
                self.pipelineCurrentPhase = "Phase 1/2: Local OCR"
            }
            var allAnswers = [ExtractedAnswer]()
            for (idx, base64) in images.enumerated() {
                await MainActor.run {
                    self.isLocalActive = true
                    self.localTaskStatus = "Transcribing answer page \(idx + 1) of \(images.count)..."
                }
                self.logToFile("[AI Batch Importer LOG] Visual answer extraction for page \(idx + 1)/\(images.count) of \(pdfPath)")
                if let rawText = await extractAnswersFromImage(base64Image: base64) {
                    if rawText != "MODEL_NOT_FOUND" && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let normalized = normalizeLaTeXDelimiters(rawText)
                        let parsed = parseExtractedAnswers(normalized)
                        self.logToFile("[AI Batch Importer LOG] Page \(idx + 1) parsed \(parsed.count) answers.")
                        allAnswers.append(contentsOf: parsed)
                        if let onPageExtracted = onPageExtracted {
                            await onPageExtracted(parsed)
                        }
                    }
                }
                await MainActor.run {
                    self.localPagesCompleted = min(self.localPagesTotal, self.localPagesCompleted + 1)
                }
            }
            
            // 3. Persist to disk cache
            if !allAnswers.isEmpty, let encoded = try? JSONEncoder().encode(allAnswers) {
                try? encoded.write(to: cacheURL)
                self.logToFile("[AI Batch Importer LOG] Saved \(allAnswers.count) answers to transcription disk cache for '\(pdfPath)'.")
            }
            return allAnswers
        } else if item.type == .image, let base64 = item.imageBase64 {
            self.logToFile("[AI Batch Importer LOG] Using visual AI model for image: \(item.pathOrName)")
            if let rawText = await extractAnswersFromImage(base64Image: base64) {
                if rawText != "MODEL_NOT_FOUND" && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let normalized = normalizeLaTeXDelimiters(rawText)
                    let parsed = parseExtractedAnswers(normalized)
                    self.logToFile("[AI Batch Importer LOG] Image parsed \(parsed.count) answers.")
                    if let onPageExtracted = onPageExtracted {
                        await onPageExtracted(parsed)
                    }
                    return parsed
                }
            }
        }
        return []
    }
    
    // MARK: - PDF Text Extraction
    
    func extractTextPagesFromPDF(path: String, maxPages: Int = 15) -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            print("[AI Helper] Error opening PDF document at \(path)")
            return []
        }
        var pages = [String]()
        let numPages = min(document.pageCount, maxPages)
        for i in 0..<numPages {
            if let page = document.page(at: i), let pageText = page.string {
                let trimmed = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    pages.append(trimmed)
                }
            }
        }
        return pages
    }
    
    func extractTextFromPDF(path: String, maxPages: Int = 15) -> String {
        return extractTextPagesFromPDF(path: path, maxPages: maxPages).joined(separator: "\n\n")
    }
    
    /// Determines if a PDF is visual (scanned/image-only) by checking if text extraction yields meaningful content.
    /// A PDF is considered visual if extracted text is empty or too short to be useful (< 20 chars per page on average).
    func isVisualPDF(path: String) -> Bool {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return false }
        let numPages = min(document.pageCount, 15)
        guard numPages > 0 else { return false }
        
        var totalChars = 0
        for i in 0..<numPages {
            if let page = document.page(at: i), let pageText = page.string {
                totalChars += pageText.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
        }
        let avgCharsPerPage = totalChars / numPages
        return avgCharsPerPage < 20
    }
    
    func convertPDFToImages(path: String, maxPages: Int = 100) -> [String] {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            print("[AI Helper] Error opening PDF for image conversion at \(path)")
            return []
        }
        var base64Images = [String]()
        let numPages = min(document.pageCount, maxPages)
        for i in 0..<numPages {
            guard let page = document.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            if bounds.width > 0 && bounds.height > 0 {
                // Optimal resolution for Qwen2.5-VL: max 1280px dimension, preserving aspect ratio
                let maxDim: CGFloat = 1280.0
                let currentMax = max(bounds.width, bounds.height)
                let scale = currentMax > maxDim ? (maxDim / currentMax) : 1.25
                let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                let image = page.thumbnail(of: size, for: .mediaBox)
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                    let base64 = jpegData.base64EncodedString()
                    base64Images.append(base64)
                }
            }
        }
        return base64Images
    }
    
    // MARK: - Summarization & Difficulty rating
    
    func isDefaultTitle(_ title: String, moduleName: String? = nil) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        
        if let modName = moduleName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !modName.isEmpty {
            if lower == modName || lower == "\(modName) coursebook" || lower == "\(modName) notes" || lower == "\(modName) lectures" {
                return true
            }
        }
        
        // 1. File extensions or unformatted filenames
        if lower.hasSuffix(".pdf") || lower.hasSuffix(".txt") || lower.hasSuffix(".md") {
            return true
        }
        
        // 2. Contains underscores (raw filename style e.g. lecture_01_notes)
        if lower.contains("_") { return true }
        
        // 3. Raw numbers only (e.g. "01", "1", "12")
        if lower.range(of: "^[0-9]+$", options: .regularExpression) != nil { return true }
        
        // 4. Starts with digit prefix e.g. "9. Basic Algebra", "10. Logarithms", "0curvilinear", "1 - Vector Calculus"
        if lower.range(of: "^[0-9]+[._ -]", options: .regularExpression) != nil { return true }
        
        // 5. Generic lecture/chapter patterns (using strict boundary regex to avoid false positives like "WKB Approximation" or "Second Law"):
        let genericPatterns = [
            "^lecture(\\s*[0-9]+|\\s*[ivxlcdm]+)?$",
            "^lec(\\s*|\\.)[0-9]+$",
            "^chapter(\\s*[0-9]+|\\s*[ivxlcdm]+)?$",
            "^ch(\\s*|\\.)[0-9]+$",
            "^week(\\s*[0-9]+)?$",
            "^wk(\\s*|\\.)[0-9]+$",
            "^section(\\s*[0-9]+|\\s*[ivxlcdm]+)?$",
            "^sec(\\s*|\\.)[0-9]+$",
            "^unit(\\s*[0-9]+)?$",
            "^part(\\s*[0-9]+|\\s*[a-z]|\\s*[ivxlcdm]+)?$",
            "^doc(\\s*|\\.)[0-9]+$",
            "^file(\\s*|\\.)[0-9]+$",
            "^live(\\s*[0-9]+)?$",
            "^notes(\\s*[0-9]+)?$",
            "^handout(\\s*[0-9]+)?$"
        ]
        
        for pattern in genericPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
    
    private func cleanFilenameTitle(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: "-", with: " ")
        text = text.replacingOccurrences(of: "^[0-9]+[.\\s]*", with: "", options: .regularExpression)
        
        let wordsToRemove = ["live", "week", "lecture", "chapter", "notes", "curt", "curtis"]
        var components = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        components.removeAll { comp in
            let lower = comp.lowercased()
            return wordsToRemove.contains(where: {
                lower == $0 || (lower.hasPrefix($0) && lower.count <= $0.count + 3 && lower.dropFirst($0.count).allSatisfy { $0.isNumber })
            })
        }
        let cleaned = components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.capitalized.isEmpty ? raw : cleaned.capitalized
    }
    
    func generateDescriptiveTitle(noteId: Int) async {
        guard let note = DatabaseManager.shared.getNote(id: noteId) else { return }
        
        let pdfText = extractTextFromPDF(path: note.filePath)
        let rawFileName = URL(fileURLWithPath: note.filePath).deletingPathExtension().lastPathComponent
        
        var moduleName = ""
        if let modId = DatabaseManager.shared.getModuleId(forTopicId: note.topicId),
           let mod = DatabaseManager.shared.getModules().first(where: { $0.id == modId }) {
            moduleName = mod.name
        }
        
        startAITask(description: "Renaming Title...")
        defer {
            finishAITask()
            Task { @MainActor in
                NotificationCenter.default.post(name: NSNotification.Name("NoteAnalysisCompleted"), object: nil, userInfo: ["noteId": noteId])
                NotificationCenter.default.post(name: NSNotification.Name("NoteTitleUpdated"), object: nil, userInfo: ["noteId": noteId])
            }
        }
        
        var chosenTitle = ""
        
        if !pdfText.isEmpty {
            var truncatedText = pdfText
            if pdfText.count > 3500 {
                truncatedText = String(pdfText.prefix(3500))
            }
            
            let model = await getOllamaModel()
            let prompt = """
            You are an expert physics academic assistant. Create a VERY SHORT descriptive topic title for these lecture notes from the course '\(moduleName)' (original file: '\(rawFileName)').
            
            CRITICAL FORMAT RULES:
            1. Length MUST be 1 to 4 words maximum (ideally 2 to 3 words). Examples: "Schrödinger Equation", "Quantum Operators", "Wave Mechanics", "Perturbation Theory", "Angular Momentum", "Thermodynamics", "Fourier Series", "Vector Calculus", "Coulomb's Law".
            2. Do NOT include words like 'Lecture', 'Notes', 'Chapter', 'Week', 'Live', or numbers like '1', '2', 'Lecture 1', 'Week 0'.
            3. Do NOT repeat the course/module name '\(moduleName)' or generic course titles. Describe the SPECIFIC physics concept/topic taught in this individual lecture.
            4. Output ONLY the raw short topic title. Do NOT use quotes, bullet points, markdown formatting, or introductory filler.
            
            Lecture Text:
            \(truncatedText)
            """
            
            if let res = await callOllama(prompt: prompt, model: model) {
                var cleaned = res.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
                                 .trimmingCharacters(in: .whitespacesAndNewlines)
                let lines = cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if let first = lines.first {
                    cleaned = first
                }
                cleaned = cleaned.replacingOccurrences(of: "\"", with: "")
                cleaned = cleaned.replacingOccurrences(of: "'", with: "")
                cleaned = cleaned.replacingOccurrences(of: "*", with: "")
                cleaned = cleaned.replacingOccurrences(of: "#", with: "")
                if cleaned.lowercased().hasPrefix("title:") {
                    cleaned = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if cleaned.hasPrefix("- ") || cleaned.hasPrefix("• ") {
                    cleaned = String(cleaned.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // If the model returned the module name, reject it
                if !cleaned.isEmpty && !moduleName.isEmpty && cleaned.lowercased() == moduleName.lowercased() {
                    cleaned = ""
                }
                
                if !cleaned.isEmpty {
                    if cleaned.count > 50 {
                        cleaned = String(cleaned.prefix(50))
                    }
                    if !isDefaultTitle(cleaned, moduleName: moduleName) {
                        chosenTitle = cleaned
                    }
                }
            }
            
            // Smart local fallback: inspect first lines of PDF text for section or topic titles
            if chosenTitle.isEmpty {
                let lines = pdfText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                for line in lines.prefix(20) {
                    let stripped = line.replacingOccurrences(of: "^([0-9]+[.\\s]+)+", with: "", options: .regularExpression)
                                       .replacingOccurrences(of: "^(section|chapter|lecture)\\s*[0-9.:]*\\s*", with: "", options: [.regularExpression, .caseInsensitive])
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
                    if stripped.count >= 4 && stripped.count <= 45 && !stripped.contains("http") && !stripped.contains("@") {
                        if stripped.lowercased() != moduleName.lowercased() && !self.isDefaultTitle(stripped, moduleName: moduleName) {
                            chosenTitle = stripped
                            break
                        }
                    }
                }
            }
        }
        
        if chosenTitle.isEmpty {
            // Extract from note AI summary heading if available
            if let summary = note.aiSummary, !summary.isEmpty {
                let sLines = summary.components(separatedBy: .newlines)
                for l in sLines {
                    let trimmed = l.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                        let header = trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                        if !header.isEmpty && header.lowercased() != moduleName.lowercased() && !isDefaultTitle(header, moduleName: moduleName) {
                            chosenTitle = header
                            break
                        }
                    }
                }
            }
        }
        
        if chosenTitle.isEmpty {
            let cleaned = cleanFilenameTitle(rawFileName)
            if !isDefaultTitle(cleaned, moduleName: moduleName) {
                chosenTitle = cleaned
            }
        }
        
        if !chosenTitle.isEmpty && !isDefaultTitle(chosenTitle, moduleName: moduleName) {
            _ = DatabaseManager.shared.updateNoteTitle(topicId: note.topicId, noteId: note.id, newTitle: chosenTitle)
            self.failedNoteTimes.removeValue(forKey: noteId)
            print("[AI Helper] Renamed Note ID \(noteId) title to: '\(chosenTitle)'")
        } else {
            self.failedNoteTimes[noteId] = Date()
            print("[AI Helper] Could not generate non-default title for Note ID \(noteId) — cooling down for 5 minutes.")
        }
    }
    
    func renameAllNotesWithAI(moduleId: Int? = nil) async {
        let notes = DatabaseManager.shared.getNotes(forModuleId: moduleId)
        print("[AI Helper] Manually triggered AI renaming for \(notes.count) notes...")
        for (idx, note) in notes.enumerated() {
            startAITask(description: "Renaming Lecture Titles...", current: idx + 1, total: notes.count)
            await generateDescriptiveTitle(noteId: note.id)
        }
        finishAITask()
    }
    
    func processNoteSync(noteId: Int) async {
        print("[AI Helper] Beginning background analysis for Note ID: \(noteId)")
        guard let note = DatabaseManager.shared.getNote(id: noteId) else {
            print("[AI Helper] Note ID \(noteId) not found in database.")
            self.failedNoteTimes[noteId] = Date()
            return
        }
        
        _ = await MainActor.run {
            self.activeProcessingNoteIds.insert(noteId)
        }
        startAITask(description: "Generating AI Summary (\(note.title))")
        
        defer {
            Task { @MainActor in
                self.activeProcessingNoteIds.remove(noteId)
                if self.activeProcessingNoteIds.isEmpty {
                    self.finishAITask(force: true)
                }
            }
        }
        
        // Auto-generate short descriptive title if generic
        var moduleName = ""
        if let modId = DatabaseManager.shared.getModuleId(forTopicId: note.topicId),
           let mod = DatabaseManager.shared.getModules().first(where: { $0.id == modId }) {
            moduleName = mod.name
        }
        if isDefaultTitle(note.title, moduleName: moduleName) {
            await generateDescriptiveTitle(noteId: noteId)
        }
        
        // Check if file physically exists on disk
        if !FileManager.default.fileExists(atPath: note.filePath) {
            print("[AI Helper] Note file physically missing at \(note.filePath). Blacklisting to avoid infinite loops.")
            self.failedNoteTimes[noteId] = Date()
            return
        }
        
        // Extract text
        let pdfText = extractTextFromPDF(path: note.filePath, maxPages: 25)
        var summaryRes: String? = nil
        
        let summaryPromptTemplate = """
        Summarize the following physics lecture into a minimal, formula-first study guide.

        CRITICAL FORMAT RULES:
        1. Start directly with 1 short sentence introducing the core physical topic intuition.
        2. Provide 3 to 4 key concept sections following this exact structure:
           ### [Concept Name]
           $$ [Centred Key LaTeX Equation] $$
           1 short sentence explaining what the equation expresses physically and what the symbols represent.
        3. AIRINESS & FIT: Keep text strictly to 1 short sentence per section so notes fit on a single screen without clutter.
        4. LATEX ACCURACY: Wrap all centered display equations in $$ equation $$ and all inline math variables in $ symbol $ (e.g. $SO(n)$, $aH = \\{ah | h \\in H\\}$). Ensure all curly braces {{ }} are balanced.
        5. NO ASTERISKS: Do NOT use double asterisks ** or single asterisks * anywhere in your output. Use plain text for headers and descriptions.
        6. NO FILLER: Do NOT include any filler text, intros, outros, 'Applications in Physics', 'Problem-Solving Skills', or concluding summaries. End directly after the last equation.

        Example format:
        Electrostatics describes forces between stationary charges in space.

        ### Coulomb's Law
        $$ F = \\frac{1}{4\\pi\\varepsilon_0} \\frac{q_1 q_2}{r^2} $$
        Electrostatic force F drops off with the square of separation distance r between charges q1 and q2.

        ### Electric Field Strength
        $$ \\mathbf{E} = \\frac{\\mathbf{F}}{q_0} $$
        Electric field E represents force per unit positive test charge q0.

        Now, synthesize the following lecture notes using the exact format above:
        """
        
        if !pdfText.isEmpty && pdfText.count >= 40 {
            var truncatedText = pdfText
            if pdfText.count > 5000 {
                truncatedText = String(pdfText.prefix(5000))
            }
            let model = await getOllamaModel()
            let prompt = "\(summaryPromptTemplate)\n\nLecture notes:\n\(truncatedText)"
            summaryRes = await callOllama(prompt: prompt, model: model)
        } else {
            // Visual / Scanned PDF or sparse text — convert pages to images and use vision model
            print("[AI Helper] Note ID \(noteId) text is sparse/empty (\(pdfText.count) chars) — attempting visual extraction via vision model...")
            let images = convertPDFToImages(path: note.filePath, maxPages: 4)
            if !images.isEmpty {
                if let visionModel = await getOllamaVisionModel(), !visionModel.isEmpty {
                    let prompt = "\(summaryPromptTemplate)\n\nPlease extract and summarize the core physics equations and concepts from these lecture note pages into the required formula-first format."
                    summaryRes = await callOllama(prompt: prompt, model: visionModel, images: images, timeout: 300.0)
                }
            }
        }
        
        if let res = summaryRes {
            var cleanedSummary = res.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = cleanedSummary.components(separatedBy: .newlines)
            if let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                let introPrefixes = ["here is", "here's", "sure", "based on", "the following", "this is", "the summary"]
                if firstLine.hasSuffix(":") && introPrefixes.contains(where: { firstLine.hasPrefix($0) }) {
                    lines.removeFirst()
                    cleanedSummary = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            _ = DatabaseManager.shared.updateNoteAI(noteId: noteId, summary: cleanedSummary, primer: nil)
            self.failedNoteTimes.removeValue(forKey: noteId)
            print("[AI Helper] Completed analysis for Note ID: \(noteId)")
            
            // Also generate pre-lecture primer automatically
            let moduleId = DatabaseManager.shared.getModuleId(forTopicId: note.topicId)
            let allNotes = DatabaseManager.shared.getNotes(forModuleId: moduleId)
            let prevNoteId: Int? = {
                if let idx = allNotes.firstIndex(where: { $0.id == noteId }), idx > 0 {
                    return allNotes[idx - 1].id
                }
                return nil
            }()
            _ = await generatePreLecturePrimer(currentNoteId: noteId, prevNoteId: prevNoteId)
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("NoteAnalysisCompleted"), object: nil, userInfo: ["noteId": noteId])
            }
        } else {
            print("[AI Helper] Failed to generate summary for Note ID: \(noteId)")
            self.failedNoteTimes[noteId] = Date()
        }
    }
    
    func ensureNoteSummarized(noteId: Int) async {
        guard !isNoteFailed(noteId: noteId) else { return }
        guard let note = DatabaseManager.shared.getNote(id: noteId) else { return }
        if note.aiSummary == nil || note.aiSummary?.isEmpty == true || note.aiSummary?.contains("Unable to generate summary") == true {
            print("[AI Helper] Summarizing note ID \(noteId) for pre-lecture prep...")
            await processNoteSync(noteId: noteId)
        }
    }
    
    // MARK: - LaTeX helpers
    
    func cleanLaTeXOutput(_ text: String?) -> String? {
        guard var result = text?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        
        // 1. Strip think tags (including unclosed think tags if output was cut off)
        if result.contains("<think>") {
            if let endThinkRange = result.range(of: "</think>") {
                result = String(result[endThinkRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                result = result.replacingOccurrences(of: "(?s)<think>.*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        if result.isEmpty { return nil }
        
        // 2. Extract markdown code fences if present (e.g. ```latex ... ```)
        if result.contains("```") {
            let pattern = "(?s)```(?:latex|tex)?\\s*([\\s\\S]*?)\\s*```"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: result.utf16.count)
                if let match = regex.firstMatch(in: result, options: [], range: range),
                   let codeRange = Range(match.range(at: 1), in: result) {
                    result = String(result[codeRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if result.hasPrefix("```") {
                let lines = result.components(separatedBy: .newlines)
                var inner = lines
                if inner.first?.hasPrefix("```") == true { inner.removeFirst() }
                if inner.last?.hasPrefix("```") == true { inner.removeLast() }
                result = inner.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // 3. If wrapped in $$ ... $$ or \[ ... \] with text around it, extract the formula
        if let startDouble = result.range(of: "$$"),
           let endDouble = result.range(of: "$$", options: .backwards),
           startDouble.lowerBound < endDouble.lowerBound {
            result = String(result[startDouble.upperBound..<endDouble.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let startBracket = result.range(of: "\\["),
                  let endBracket = result.range(of: "\\]", options: .backwards),
                  startBracket.lowerBound < endBracket.lowerBound {
            result = String(result[startBracket.upperBound..<endBracket.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // 4. Strip single outer delimiters ($...$, \(...\))
        if result.hasPrefix("$$") && result.hasSuffix("$$") && result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("$") && result.hasSuffix("$") && result.count >= 2 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("\\[") && result.hasSuffix("\\]") && result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("\\(") && result.hasSuffix("\\)") && result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // 5. Strip common conversational introductory prefixes
        let introPrefixes = [
            "Here is the LaTeX code:",
            "Here is the LaTeX:",
            "LaTeX code:",
            "LaTeX:",
            "The LaTeX code is:",
            "The equation in LaTeX is:",
            "The LaTeX representation is:",
            "Here is the translated LaTeX:",
            "Here is the formula:",
            "The formula is:",
            "The equation is:",
            "Equation:",
            "Here is the transcribed LaTeX:",
            "Here is the transcribed equation:",
            "Transcribed equation:"
        ]
        for prefix in introPrefixes {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Check for embedded "The equation is:" or "Formula is:" after any reasoning prose
        if let eqRange = result.range(of: #"(?i)(?:the\s+)?(?:equation|formula)\s+is:\s*"#, options: .regularExpression) {
            let candidate = String(result[eqRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                result = candidate
            }
        }
        
        // 6. Strip any residual surrounding delimiters after removing intro prefix
        if result.hasPrefix("$$") && result.hasSuffix("$$") && result.count >= 4 {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("$") && result.hasSuffix("$") && result.count >= 2 {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return result.isEmpty ? nil : result
    }
    
    func translateToLaTeX(rawEquation: String) async -> String? {
        startAITask(description: "Translating LaTeX Equation...")
        defer {
            finishAITask(force: true)
        }
        return await withUserPriority {
            let routeProvider = taskProvider(for: "route_translation", defaultProvider: "local")
            let useLocal = latexAlwaysLocal || routeProvider == "local"
            let model = await getOllamaModel(forProvider: useLocal ? "local" : routeProvider, forceLocal: useLocal)
            let prompt = """
            You are a mathematical LaTeX translator. Translate the following plain-text equation description or expression into clean, valid raw LaTeX code.
            Do NOT include <think> tags or conversational filler. Return ONLY the raw LaTeX code itself.

            Example input: integral from a to b of x squared dx
            Example output: \\int_{a}^{b} x^2 \\, dx

            Example input: schrodinger equation
            Example output: i\\hbar\\frac{\\partial}{\\partial t}\\text{\\Psi}(\\mathbf{r},t) = \\hat{H}\\text{\\Psi}(\\mathbf{r},t)

            Now, translate this equation:
            \(rawEquation)
            """
            
            let fastOptions = OllamaOptions(temperature: 0.0, num_predict: 1024, top_p: 0.9)
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal, overrideProvider: useLocal ? "local" : routeProvider, options: fastOptions, overrideThink: false)
            // Bidirectional fallback: if preferred provider failed, try the opposite (Local <-> Remote)
            if res == nil {
                let fallbackUseLocal = !useLocal
                self.logToFile("[AI Helper LOG] LaTeX translation failed on preferred provider, trying fallback (forceLocal: \(fallbackUseLocal))...")
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal, options: fastOptions, overrideThink: false)
            }
            return cleanLaTeXOutput(res)
        }
    }
    
    func translateImageToLaTeX(base64Image: String) async -> String? {
        startAITask(description: "Transcribing Equation Image...")
        defer {
            finishAITask(force: true)
        }
        return await withUserPriority {
            let routeProvider = taskProvider(for: "route_translation", isVision: true, defaultProvider: "local")
            let useLocal = latexAlwaysLocal || routeProvider == "local"
            let prompt = """
            Transcribe the mathematical equation or expression in this image into valid LaTeX format. \
            Do NOT wrap the equation in any delimiters like $ or $$ or \\[ or \\]. \
            Do NOT include <think> tags or conversational filler. Return ONLY the raw LaTeX code itself.
            """
            let fastOptions = OllamaOptions(temperature: 0.0, num_predict: 1024, top_p: 0.9)
            
            // 1. Initial attempt with preferred provider
            var res: String? = nil
            if let visionModel = await getOllamaVisionModel(forceLocal: useLocal) {
                res = await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 120.0, forceLocal: useLocal, overrideProvider: useLocal ? "local" : routeProvider, options: fastOptions, overrideThink: false)
            }
            
            // 2. Bidirectional fallback (Local <-> Tailscale)
            if res == nil {
                let fallbackUseLocal = !useLocal
                self.logToFile("[AI Helper LOG] LaTeX image transcription failed on preferred provider, trying fallback (forceLocal: \(fallbackUseLocal))...")
                if let fallbackVisionModel = await getOllamaVisionModel(forceLocal: fallbackUseLocal) {
                    res = await callOllama(prompt: prompt, model: fallbackVisionModel, images: [base64Image], timeout: 120.0, forceLocal: fallbackUseLocal, options: fastOptions, overrideThink: false)
                }
            }
            
            // 3. Fallback to Cloud Vision if configured
            if res == nil {
                let visionProvider = UserDefaults.standard.string(forKey: "vision_provider") ?? "local"
                let cloudKey = UserDefaults.standard.string(forKey: "vision_api_key") ?? ""
                let cloudBase = UserDefaults.standard.string(forKey: "vision_api_base_url") ?? ""
                if (visionProvider != "local" && visionProvider != "tailscale") || !cloudKey.isEmpty || !cloudBase.isEmpty {
                    let cloudModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
                    res = await callAPIOnce(prompt: prompt, model: cloudModel, images: [base64Image], timeout: 120.0, provider: "cloud_vision", overrideThink: false)
                }
            }
            
            return cleanLaTeXOutput(res)
        }
    }
    
    func extractProblemsFromPDF(pdfText: String) async -> String? {
        await withUserPriority {
            let provider = taskProvider(for: "route_vision", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            let prompt = """
            You are a physics teaching assistant. Analyze the following text extracted from a physics document/homework:
            ---
            \(pdfText)
            ---
            Extract and transcribe ALL individual practice questions or problems found in the text.
            
            Strict Formatting & Transcription Rules:
            1. Transcribe the COMPLETE question statement including all subparts (e.g. (i), (ii), (a), (b), (c)) so the problem is fully self-contained.
            2. Spread the question across multiple lines for readability. Big equations and mathematical derivations MUST be on their own separate lines.
            3. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            4. Do NOT include exam mark totals, question points, or score designations (e.g. strip '[5 marks]', '(10 marks)').
            5. Provide a concise relevant Hint for the problem with formulas wrapped in dollar signs.
            
            Format each extracted problem strictly as follows:
            [PROBLEM]
            Question: <clear complete question text with all subparts and equations wrapped in dollar signs>
            Hint: <concise solution hint with LaTeX wrapped in dollar signs>
            [PROBLEM]

            Output ONLY the structured [PROBLEM] blocks. Do NOT include any conversation, conversational filler, or introductory text.
            """
            
            return await callOllama(prompt: prompt, model: model, timeout: 120.0, overrideProvider: provider)
        }
    }
    
    func extractProblemsFromImage(base64Image: String) async -> String? {
        await withUserPriority {
            let provider = taskProvider(for: "route_vision", isVision: true, defaultProvider: "local")
            guard let visionModel = await getOllamaVisionModel(forceLocal: provider == "local") else {
                return "MODEL_NOT_FOUND"
            }
            let prompt = """
            You are a physics teaching assistant. Analyze this image containing physics practice questions or problems.
            Transcribe and extract ALL individual practice problems from the image.
            
            Strict Formatting Rules:
            1. Transcribe the COMPLETE question statement including all subparts (e.g. (i), (ii), (a), (b), (c)) so the problem is fully self-contained.
            2. Do NOT include top-level question numbering prefixes like "1)", "1.", "Problem 1:", "2)" because the app already numbers each problem. KEEP sub-question labels like (a), (b), (c) and (i), (ii), (iii).
            3. Spread the question across multiple lines for readability. Equations MUST be on their own separate lines.
            4. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            5. Do NOT include exam mark totals, question points, or score designations (e.g. strip '[5 marks]', '(10 marks)').
            6. Provide a concise relevant Hint for the problem with formulas wrapped in dollar signs.

            Format each extracted problem strictly as follows:
            [PROBLEM]
            Question: <clear complete question text with all subparts and equations wrapped in dollar signs>
            Hint: <concise solution hint with LaTeX wrapped in dollar signs>
            [PROBLEM]

            Output ONLY the structured [PROBLEM] blocks. Do NOT include any introduction, explanations, or conversational filler.
            """
            
            return await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 180.0, overrideProvider: provider)
        }
    }
    
    func classifyProblemTopic(problemContent: String, moduleId: Int) async -> Int? {
        await withUserPriority {
            let topics = DatabaseManager.shared.getTopics(forModuleId: moduleId)
            let notes = DatabaseManager.shared.getNotes(forModuleId: moduleId)
            
            var topicContexts = [String]()
            for topic in topics {
                let matchingNotes = notes.filter { $0.topicId == topic.id }
                let summaries = matchingNotes.compactMap { $0.aiSummary }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let combinedSummary = summaries.joined(separator: "\n")
                
                var contextStr = "Week \(topic.week): \(topic.name)"
                if !combinedSummary.isEmpty {
                    contextStr += "\nSummary of concepts covered:\n\(combinedSummary)"
                }
                topicContexts.append(contextStr)
            }
            
            let topicListStr = topicContexts.joined(separator: "\n\n---\n\n")
            let provider = taskProvider(for: "route_classification", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            let prompt = """
            You are a physics teaching assistant. Analyze the following practice problem:
            ---
            \(problemContent)
            ---
            Based on the problem description, physical concepts, and equations, classify which of the following lecture topics/weeks it belongs to.
            
            Available Topics and their Summaries:
            \(topicListStr)
            
            Output ONLY the week number (an integer, e.g. 3) that is the best fit. If the problem is general, covers multiple weeks, or does not fit any specific week, output '0'.
            Do NOT include any other text, explanation, or markdown formatting. Output only the digit.
            """
            
            if let res = await callOllama(prompt: prompt, model: model, timeout: 60.0, overrideProvider: provider) {
                let cleaned = res.trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = cleaned.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                return Int(digits)
            }
            return nil
        }
    }
    
    // MARK: - Pre-Lecture Primer
    
    func generatePreLecturePrimer(currentNoteId: Int, prevNoteId: Int? = nil, forceRegenerate: Bool = false) async -> String? {
        if !forceRegenerate,
           let cached = DatabaseManager.shared.getNote(id: currentNoteId)?.preLecturePrimer,
           !cached.isEmpty,
           !cached.contains("Unable to generate pre-lecture primer") {
            return cached
        }
        
        if forceRegenerate {
            _ = DatabaseManager.shared.clearPreLecturePrimer(noteId: currentNoteId)
        }
        
        await ensureNoteSummarized(noteId: currentNoteId)
        
        guard let currNote = DatabaseManager.shared.getNote(id: currentNoteId) else {
            self.failedNoteTimes[currentNoteId] = Date()
            return nil
        }
        
        var prevNote: Note? = nil
        if let prevId = prevNoteId {
            await ensureNoteSummarized(noteId: prevId)
            prevNote = DatabaseManager.shared.getNote(id: prevId)
        }
        
        let model = await getOllamaModel()
        let prompt: String
        
        if let prev = prevNote {
            prompt = """
            You are a helpful physics academic assistant. Create a 'Pre-Lecture Primer' for my upcoming lecture.

            Current Lecture: '\(currNote.title)'
            Previous Lecture: '\(prev.title)'

            Here is what was covered in the previous lecture:
            \(prev.aiSummary ?? "")

            Here is the content/summary of the current lecture:
            \(currNote.aiSummary ?? "")

            Please generate a response with the following exact structure, starting directly with the headers. Do NOT include any conversational intro or outro filler.

            [What Happened in the Last Lecture]
            A concise, 1-2 sentence summary of the key concepts from the last lecture.

            [How it Links into This Lecture]
            A 1-2 sentence explanation of how the concepts from the last lecture connect or lead into the topics of this upcoming lecture.

            [What You Will Learn Today]
            A brief, high-level overview (2-3 sentences) giving a clear understanding of what will be learned today.

            [Three Open Questions for the Lecture]
            A list of 3 thought-provoking, open-ended questions about this lecture's topic that I should try to solve during class. Format as:
            - 1. [First Question]
            - 2. [Second Question]
            - 3. [Third Question]
            """
        } else {
            prompt = """
            You are a helpful physics academic assistant. Create a 'Pre-Lecture Primer' for my upcoming lecture.

            This is the first lecture of the module: '\(currNote.title)'
            Here is the content/summary of the current lecture:
            \(currNote.aiSummary ?? "")

            Please generate a response with the following exact structure, starting directly with the headers. Do NOT include any conversational intro or outro filler.

            [What You Will Learn Today]
            A brief, high-level overview (2-3 sentences) giving a clear understanding of what will be learned today.

            [Three Open Questions for the Lecture]
            A list of 3 thought-provoking, open-ended questions about this lecture's topic that I should try to solve during class. Format as:
            - 1. [First Question]
            - 2. [Second Question]
            - 3. [Third Question]
            """
        }
        
        let primerRes = await callOllama(prompt: prompt, model: model)
        if let res = primerRes, !res.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = DatabaseManager.shared.updateNoteAI(noteId: currentNoteId, summary: currNote.aiSummary, primer: res)
            self.failedNoteTimes.removeValue(forKey: currentNoteId)
            return res
        } else {
            self.failedNoteTimes[currentNoteId] = Date()
            let finalPrimer = "Unable to generate pre-lecture primer. Please verify the AI server is online."
            _ = DatabaseManager.shared.updateNoteAI(noteId: currentNoteId, summary: currNote.aiSummary, primer: finalPrimer)
            return finalPrimer
        }
    }
    
    func regeneratePreLecturePrimersForReorderedNotes(notesInOrder: [Note], affectedNoteIds: Set<Int>) async {
        let total = affectedNoteIds.count
        guard total > 0 else { return }
        
        startAITask(description: "Updating Pre-Lecture Recaps...", current: 0, total: total)
        var count = 0
        
        for (idx, note) in notesInOrder.enumerated() {
            if affectedNoteIds.contains(note.id) {
                count += 1
                startAITask(description: "Updating Pre-Lecture Recap (\(note.title)...)", current: count, total: total)
                let prevNoteId = idx > 0 ? notesInOrder[idx - 1].id : nil
                _ = await generatePreLecturePrimer(currentNoteId: note.id, prevNoteId: prevNoteId)
            }
        }
        finishAITask()
    }
    
    // MARK: - Feynman sandbox & dialogues
    
    func evaluateFeynmanSummary(explanation: String, noteTitle: String, aiSummary: String) async -> String? {
        await withUserPriority {
            let routeProvider = taskProvider(for: "route_feynman", defaultProvider: "local")
            let useLocal = feynmanAlwaysLocal || routeProvider == "local"
            let model = await getOllamaModel(forProvider: useLocal ? "local" : routeProvider, forceLocal: useLocal)
            let prompt = """
            You are a physics professor. The user is using the Feynman technique to explain a lecture note they just studied.
            Lecture Note Title: \(noteTitle)
            Reference Summary (overview and key concepts): 
            \(aiSummary)

            The user's explanation:
            \(explanation)

            Assess the user's explanation. Grade it out of 10 (integer rating) based on accuracy, completeness, and clarity. \
            List any important concepts, terms, or equations from the reference summary that the user left out or explained poorly. \
            If the explanation covers all key concepts, write "- None" under Concepts Left Out.

            Your response MUST follow this exact structure:
            Rating: [X]/10
            Feedback: [1-2 sentences of general encouragement/feedback]
            Concepts Left Out:
            - [Concept/Equation 1]: [brief note why it is important]
            - [Concept/Equation 2]: [brief note why it is important]

            Do NOT include any conversational introduction or outro. Start directly with 'Rating:'.
            """
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal, overrideProvider: useLocal ? "local" : routeProvider)
            if res == nil {
                let fallbackUseLocal = !useLocal
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal)
            }
            return res?.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    func getFeynmanDialogueResponse(noteTitle: String, aiSummary: String, chatHistory: [FeynmanChat]) async -> String? {
        await withUserPriority {
            let routeProvider = taskProvider(for: "route_feynman", defaultProvider: "local")
            let useLocal = feynmanAlwaysLocal || routeProvider == "local"
            let model = await getOllamaModel(forProvider: useLocal ? "local" : routeProvider, forceLocal: useLocal)
            var historyStr = ""
            
            let lastMsgs = chatHistory.suffix(6)
            for msg in lastMsgs {
                let roleLabel = msg.role == "assistant" ? "Student" : "User"
                historyStr += "\(roleLabel): \(msg.content)\n"
            }
            
            let prompt = """
            You are a curious, slightly confused physics student who is trying to understand a lecture topic from the user. \
            The lecture note is: '\(noteTitle)'.
            Here is the reference summary of the topic: 
            \(aiSummary)

            You want to learn this topic from the user using the Feynman technique. Ask probing, conceptual questions \
            or point out potential logical gaps in their explanations. Be friendly, polite, but analytically rigorous (like a good student trying to really learn it). \
            Keep your responses relatively brief (1-3 sentences) so it feels like a natural conversation. \
            Do NOT use any emojis anywhere in your response.

            Conversation History:
            \(historyStr)
            Student:
            """
            
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal, overrideProvider: useLocal ? "local" : routeProvider)
            if res == nil {
                let fallbackUseLocal = !useLocal
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal)
            }
            let cleaned = res?.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned?.isEmpty == false ? cleaned : nil) ?? "I'm having a bit of trouble formulating my thoughts right now. Could you please rephrase or expand on your previous explanation?"
        }
    }
    
    func generateFeynmanStartingQuestion(noteTitle: String, aiSummary: String) async -> String? {
        await withUserPriority {
            let routeProvider = taskProvider(for: "route_feynman", defaultProvider: "local")
            let useLocal = feynmanAlwaysLocal || routeProvider == "local"
            let model = await getOllamaModel(forProvider: useLocal ? "local" : routeProvider, forceLocal: useLocal)
            let prompt = """
            You are a curious physics student. The user just studied a lecture notes topic: '\(noteTitle)'.
            Here is the reference summary of the topic: 
            \(aiSummary)

            Ask the user one specific, conceptual question to test their understanding of this topic. \
            Do NOT ask them to explain the entire topic or summarize it. Instead, ask about a specific mechanism, \
            implication, equation, or physical scenario related to the topic. \
            Keep your question brief and sound like a student speaking (1-2 sentences). Do NOT use any emojis.

            Student Question:
            """
            
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal, overrideProvider: useLocal ? "local" : routeProvider)
            if res == nil {
                let fallbackUseLocal = !useLocal
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal)
            }
            let cleaned = res?.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return (cleaned?.isEmpty == false ? cleaned : nil) ?? "Can you explain the main physical concepts and principles covered in the '\(noteTitle)' lecture?"
        }
    }
    
    // MARK: - Background Processor
    
    func isOllamaRunning() async -> Bool {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        if provider == "local" || provider == "tailscale" {
            let host: String
            if provider == "tailscale" {
                host = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
            } else {
                host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
            guard !host.isEmpty, let bURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "http://localhost:11434") else { return false }
            let url = bURL.appendingPathComponent("api/tags")
            var request = URLRequest(url: url)
            request.timeoutInterval = provider == "tailscale" ? 3.0 : 2.0
            do {
                let (_, response) = try await session.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    return true
                }
                return false
            } catch {
                return false
            }
        } else {
            // For cloud/hermes/openai/groq/anthropic/gemini providers, check the cloud API base URL
            let baseUrl = UserDefaults.standard.string(forKey: "cloud_api_base_url") ?? ""
            let cleanBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let isAnthropic = cleanBase.contains("anthropic.com") || provider == "anthropic"
            let isGemini = cleanBase.contains("generativelanguage.googleapis.com") || provider == "gemini"
            
            let modelsUrlString: String
            if isAnthropic {
                modelsUrlString = "https://api.anthropic.com/v1/models"
            } else if isGemini {
                modelsUrlString = "https://generativelanguage.googleapis.com/v1beta/openai/models"
            } else if cleanBase.hasSuffix("/v1") || cleanBase.hasSuffix("/v1beta") {
                modelsUrlString = "\(cleanBase)/models"
            } else if cleanBase.isEmpty {
                modelsUrlString = "https://api.openai.com/v1/models"
            } else {
                modelsUrlString = "\(cleanBase)/v1/models"
            }
            guard let url = URL(string: modelsUrlString) else { return false }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3.0
            let apiKey = UserDefaults.standard.string(forKey: "cloud_api_key") ?? ""
            if isAnthropic {
                if !apiKey.isEmpty {
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                }
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                if !apiKey.isEmpty {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
            }
            do {
                let (_, response) = try await session.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode < 500 {
                    return true
                }
                return false
            } catch {
                return false
            }
        }
    }
    
    private static var isStartingLocalOllama = false
    
    /// Ensures local Ollama is running safely without spawning duplicate zombie processes.
    func ensureLocalOllamaRunning() async {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        if let _ = try? await session.data(for: request) {
            return // Running and healthy
        }
        
        guard !Self.isStartingLocalOllama else { return }
        Self.isStartingLocalOllama = true
        defer { Self.isStartingLocalOllama = false }
        
        // Check if an Ollama process is already running in macOS
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "ollama"]
        if (try? pgrep.run()) != nil {
            pgrep.waitUntilExit()
            if pgrep.terminationStatus == 0 {
                self.logToFile("[AI Helper LOG] Ollama process already active in system, awaiting readiness...")
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    var checkReq = URLRequest(url: url)
                    checkReq.timeoutInterval = 2.0
                    if let _ = try? await session.data(for: checkReq) {
                        return
                    }
                }
                return
            }
        }
        
        self.logToFile("[AI Helper LOG] Launching Ollama application...")
        let openTask = Process()
        openTask.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            openTask.arguments = ["-a", "Ollama", "--background"]
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ollama") {
            openTask.executableURL = URL(fileURLWithPath: "/usr/local/bin/ollama")
            openTask.arguments = ["serve"]
        } else {
            openTask.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ollama")
            openTask.arguments = ["serve"]
        }
        do {
            try openTask.run()
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                var checkReq = URLRequest(url: url)
                checkReq.timeoutInterval = 1.5
                if let _ = try? await session.data(for: checkReq) {
                    self.logToFile("[AI Helper LOG] Local Ollama is now ready.")
                    return
                }
            }
            self.logToFile("[AI Helper LOG] Local Ollama did not respond within 10s.")
        } catch {
            self.logToFile("[AI Helper LOG] Failed to launch Ollama: \(error.localizedDescription)")
        }
    }
    
    func startBackgroundProcessor() {
        Task {
            print("[AI Helper] Background processor manager started.")
            while true {
                do {
                    let bgEnabled = await MainActor.run { self.isBackgroundAIEnabled }
                    if !bgEnabled {
                        await MainActor.run {
                            self.activeJobDescription = "Background AI Disabled"
                        }
                        try await Task.sleep(nanoseconds: 10_000_000_000) // Sleep 10s when disabled
                        continue
                    }
                    
                    // Check if any interactive user request is active. If so, yield.
                    let isUserBusy = await MainActor.run { self.activeUserRequestsCount > 0 }
                    if isUserBusy {
                        try await Task.sleep(nanoseconds: 2_000_000_000) // Sleep 2s
                        continue
                    }
                    
                    let pendingJob = await self.getNextPendingJob()
                    let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
                    let isLocalProvider = (provider == "local")
                    
                    if let job = pendingJob {
                        // Pending work found! Make sure power saving mode is disengaged
                        await MainActor.run {
                            if self.isPowerSavingMode {
                                self.isPowerSavingMode = false
                                print("[AI Helper] Pending AI tasks detected — exiting Power Saving Mode.")
                                if isLocalProvider {
                                    PhysicsStudyApp.startOllamaServer()
                                }
                            }
                        }
                        
                        let online = await self.isOllamaRunning()
                        if online {
                            await MainActor.run {
                                if self.isAIDisconnected {
                                    self.isAIDisconnected = false
                                    self.disconnectionMessage = ""
                                }
                            }
                            if self.awakeActivityToken == nil {
                                self.awakeActivityToken = ProcessInfo.processInfo.beginActivity(
                                    options: [.background, .idleSystemSleepDisabled],
                                    reason: "Processing AI summaries and primers overnight"
                                )
                                print("[AI Helper] System sleep disabled while processing queue.")
                            }
                            
                            self.isProcessing = true
                            self.activeJobDescription = job.description
                            
                            let task = Task {
                                await job.task()
                            }
                            await MainActor.run {
                                self.currentBackgroundTask = task
                            }
                            
                            await task.value
                            
                            await MainActor.run {
                                self.currentBackgroundTask = nil
                            }
                            
                            self.isProcessing = false
                            self.activeJobDescription = "Idle"
                            try await Task.sleep(nanoseconds: 2_000_000_000) // 2s cooldown
                            continue
                        } else {
                            await MainActor.run {
                                let prov = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
                                self.isAIDisconnected = true
                                self.disconnectionMessage = prov == "tailscale" ? "Tailscale Disconnected (Reconnecting...)" : "AI Server Offline"
                                self.isProcessing = false
                                self.isAIBusy = false
                                self.activeJobDescription = "AI Server Offline"
                            }
                            if provider == "tailscale" {
                                _ = await self.attemptAutoReconnect()
                            }
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            continue
                        }
                    } else {
                        // No pending jobs in the queue
                        if let token = self.awakeActivityToken {
                            ProcessInfo.processInfo.endActivity(token)
                            self.awakeActivityToken = nil
                            print("[AI Helper] System sleep re-enabled (queue idle).")
                        }
                        
                        // Check for power saver (only when queue is empty and provider is local)
                        await MainActor.run {
                            if isLocalProvider && self.isAutoPowerSaverEnabled {
                                let idleTime = Date().timeIntervalSince(self.lastAIAccessTimestamp)
                                if idleTime > 300 && !self.isPowerSavingMode {
                                    self.isPowerSavingMode = true
                                    self.activeJobDescription = "Power Saving Mode"
                                    print("[AI Helper] 5 minutes of AI inactivity reached — entering Power Saving Mode.")
                                    PhysicsStudyApp.stopOllamaServer()
                                }
                            }
                            if !self.isPowerSavingMode {
                                self.activeJobDescription = "Idle"
                            }
                        }
                        
                        try await Task.sleep(nanoseconds: 8_000_000_000) // 8s idle sleep
                    }
                } catch {
                    print("[AI Helper] Error in background processor: \(error)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    
    struct PendingJob {
        let description: String
        let task: () async -> Void
    }
    
    private func getNextPendingJob() async -> PendingJob? {
        let allModules = DatabaseManager.shared.getModules()
        
        // Pass 1: Prioritize missing note summaries across ALL modules first!
        for module in allModules {
            let notes = DatabaseManager.shared.getNotes(forModuleId: module.id)
            for note in notes {
                guard !note.filePath.isEmpty else { continue }
                if (note.aiSummary == nil || note.aiSummary?.isEmpty == true || note.aiSummary?.contains("Unable to generate summary") == true) && !self.isNoteFailed(noteId: note.id) {
                    return PendingJob(description: "Analyze Note (Note ID \(note.id))") {
                        await self.processNoteSync(noteId: note.id)
                    }
                }
            }
        }
        
        // Pass 2: Rename generic lecture titles across all modules
        for module in allModules {
            let notes = DatabaseManager.shared.getNotes(forModuleId: module.id)
            for note in notes {
                guard !note.filePath.isEmpty else { continue }
                if self.isDefaultTitle(note.title, moduleName: module.name) && !self.isNoteFailed(noteId: note.id) {
                    return PendingJob(description: "Rename Title (Note ID \(note.id))") {
                        await self.generateDescriptiveTitle(noteId: note.id)
                    }
                }
            }
        }
        
        // Pass 3: Missing pre-lecture primers across all modules
        for module in allModules {
            let notes = DatabaseManager.shared.getNotes(forModuleId: module.id)
            for (idx, note) in notes.enumerated() {
                guard !note.filePath.isEmpty else { continue }
                if (note.preLecturePrimer == nil || note.preLecturePrimer?.isEmpty == true || note.preLecturePrimer?.contains("Unable to generate pre-lecture primer") == true) && !self.isNoteFailed(noteId: note.id) {
                    let prevNoteId = idx > 0 ? notes[idx - 1].id : nil
                    return PendingJob(description: "Primer (Note ID \(note.id))") {
                        _ = await self.generatePreLecturePrimer(currentNoteId: note.id, prevNoteId: prevNoteId)
                    }
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Problem Solution & Steps Generation
    
    func generateProblemSolution(content: String) async -> String {
        await withUserPriority {
            let provider = taskProvider(for: "route_math", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            let prompt = """
            You are an expert physics solver. Solve the following practice problem step-by-step:
            ---
            \(content)
            ---
            Provide a clean, precise, and accurate solution. Use LaTeX formatting for all mathematical equations.
            ALWAYS wrap all inline math variables, formulas, and math symbols in single dollar signs (e.g. $x_i$, $\theta$), and all block equations in double dollar signs (e.g. $$E = mc^2$$) on their own lines. Never output naked equations or symbols without delimiters.
            Output ONLY the final solution and explanation. Do not include conversational introduction or general filler.
            """
            return await callOllama(prompt: prompt, model: model, timeout: 120.0, overrideProvider: provider) ?? ""
        }
    }
    
    func generateProblemSteps(content: String, solution: String) async -> [String] {
        await withUserPriority {
            let provider = taskProvider(for: "route_steps", defaultProvider: "tailscale")
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
            self.logToFile("[AI Helper LOG] generateProblemSteps called for content: '\(content.prefix(60))...' with solution: '\(solution.prefix(60))...'")
            let prompt = """
            You are a physics teaching assistant. Break down the following practice problem and its solution into a sequence of simple, clear step-by-step instructions or scaffolding questions.
            
            Problem:
            \(content)
            
            Full Solution:
            \(solution)
            
            Break it down into at least 2 and at most 6 distinct, sequential, and actionable steps.
            ALWAYS wrap all math formulas, variables, and math symbols inside each step in standard single dollar signs (e.g. $F = ma$, $q$, $\\theta$). Never leave them without delimiters.
            Format the output strictly as a list with each step starting with 'Step X:' (e.g. 'Step 1: Calculate the charge...', 'Step 2: Find the electric field...').
            Do NOT include introduction, general filler, or raw markdown lists. Output only the steps.
            """
            self.logToFile("[AI Helper LOG] Sending prompt to Ollama (\(model), provider: \(provider))...")
            guard let res = await callOllama(prompt: prompt, model: model, timeout: 120.0, overrideProvider: provider) else {
                self.logToFile("[AI Helper LOG] callOllama returned nil in generateProblemSteps")
                return []
            }
            self.logToFile("[AI Helper LOG] Received response from Ollama. Length: \(res.count)")
            let steps = self.parseStepsFromLLMResponse(res)
            self.logToFile("[AI Helper LOG] Returning \(steps.count) steps.")
            return steps
        }
    }
    
    func curatePreExamFlashcards(moduleId: Int, moduleCode: String) async {
        await withUserPriority {
            self.isAIBusy = true
            self.currentAITaskDescription = "Curating Phase 1 Cards for \(moduleCode)..."
            self.logToFile("[AI Helper LOG] curatePreExamFlashcards started for module ID \(moduleId) (\(moduleCode)).")
            
            let allCards = DatabaseManager.shared.getFlashcards(forModuleId: moduleId)
            // Strict exclusion: exclude flagged cards (reserved for QA/editing) and trivial/overly basic cards
            let eligibleCards = allCards.filter { card in
                if card.isFlagged { return false }
                let trimmedFront = card.front.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedBack = card.back.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedFront.count < 8 || trimmedBack.count < 3 { return false }
                return true
            }
            let cardPool = eligibleCards.isEmpty ? allCards : eligibleCards
            self.logToFile("[AI Helper LOG] Total eligible non-flagged cards found for module \(moduleCode): \(cardPool.count)")
            
            guard !cardPool.isEmpty else {
                self.isAIBusy = false
                self.currentAITaskDescription = ""
                return
            }
            
            // Stratified Semester Sampling across creation/ID spectrum to ensure equal representation of early, mid, and late lectures
            let candidates: [Flashcard]
            if cardPool.count <= 50 {
                candidates = cardPool.shuffled()
            } else {
                let sortedById = cardPool.sorted(by: { $0.id < $1.id })
                let bucketCount = 5
                let chunkSize = max(1, sortedById.count / bucketCount)
                var sampled: [Flashcard] = []
                for i in 0..<bucketCount {
                    let start = i * chunkSize
                    let end = (i == bucketCount - 1) ? sortedById.count : min((i + 1) * chunkSize, sortedById.count)
                    if start < end {
                        let bucketSlice = Array(sortedById[start..<end])
                        let bucketHard = bucketSlice.sorted(by: { $0.easeFactor < $1.easeFactor }).prefix(5)
                        let bucketRandom = bucketSlice.filter { c in !bucketHard.contains(where: { $0.id == c.id }) }.shuffled().prefix(5)
                        sampled.append(contentsOf: bucketHard)
                        sampled.append(contentsOf: bucketRandom)
                    }
                }
                candidates = sampled.shuffled()
            }
            
            var cardSummaries: [[String: Any]] = []
            for c in candidates {
                cardSummaries.append([
                    "id": c.id,
                    "front": String(c.front.prefix(150)),
                    "back": String(c.back.prefix(150)),
                    "easeFactor": c.easeFactor
                ])
            }
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: cardSummaries, options: []),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                let fallback = Array(candidates.shuffled().prefix(25)).map(\.id)
                UserDefaults.standard.set(fallback, forKey: "pre_exam_ai_cards_\(moduleId)")
                self.aiCuratedCardsVersion += 1
                self.isAIBusy = false
                self.currentAITaskDescription = ""
                return
            }
            
            let model = await getOllamaModel()
            let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
            self.logToFile("[AI Helper LOG] Dispatching pre-exam card curation to provider: \(provider), model: \(model)...")
            
            let prompt = """
            You are a STEM exam coach for module \(moduleCode). Select the 25 BEST flashcards for a 40-minute pre-exam memory priming session from the candidates below.
            
            UNIFORM SEMESTER COVERAGE REQUIREMENT:
            The candidates below span early, middle, and recent/late lectures of the module.
            Select 25 cards that provide BALANCED, EVEN COVERAGE across the ENTIRE course.
            DO NOT cluster your selections in early lectures — ensure recent and later lecture topics are strongly represented in Phase 1!
            
            Categorize and pick cards representing:
            1. Core Definitions and Theorems
            2. Validity and Applicability Constraints
            3. Boundary Conditions and Limiting Cases
            4. Notation and Sign Conventions
            
            STRICT EXCLUSION RULES:
            1. EXCLUDE any trivial, elementary, or overly basic flashcards (e.g. basic unit definitions or single-word trivial facts).
            2. EXCLUDE cards requiring long multi-step calculations or multi-page derivations.
            3. Focus ONLY on high-yield, non-trivial core concepts, validity conditions, boundary cases, and notation traps.
            
            Candidates JSON:
            \(jsonString)
            
            OUTPUT REQUIREMENT:
            Return ONLY a raw JSON array of up to 25 integer card IDs, e.g. [12, 45, 3, 19, 88]. Do NOT include any markdown formatting, code block markers, or commentary text.
            """
            
            var selectedIds: [Int] = []
            if let response = await callOllama(prompt: prompt, model: model) {
                self.logToFile("[AI Helper LOG] Response received (length \(response.count)): '\(response.prefix(150))...'")
                
                let strippedResponse = response.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                let arrayPattern = #"\[\s*\d+(?:\s*,\s*\d+)*\s*\]"#
                if let range = strippedResponse.range(of: arrayPattern, options: .regularExpression) {
                    let jsonSubstring = String(strippedResponse[range])
                    if let data = jsonSubstring.data(using: .utf8),
                       let ids = try? JSONSerialization.jsonObject(with: data, options: []) as? [Int],
                       !ids.isEmpty {
                        selectedIds = ids
                        self.logToFile("[AI Helper LOG] Successfully parsed \(ids.count) AI-selected card IDs: \(ids)")
                    } else {
                        self.logToFile("[AI Helper LOG] Substring JSON array extraction failed for string: '\(jsonSubstring.prefix(100))'")
                    }
                } else {
                    self.logToFile("[AI Helper LOG] No integer JSON array found in response.")
                }
            } else {
                self.logToFile("[AI Helper LOG] callOllama returned nil during pre-exam curation.")
            }
            
            if selectedIds.isEmpty {
                self.logToFile("[AI Helper LOG] AI curation returned 0 valid IDs — executing randomized candidate fallback deck.")
                selectedIds = Array(candidates.shuffled().prefix(min(25, candidates.count))).map(\.id)
            }
            
            UserDefaults.standard.set(selectedIds, forKey: "pre_exam_ai_cards_\(moduleId)")
            UserDefaults.standard.synchronize()
            self.aiCuratedCardsVersion += 1
            self.isAIBusy = false
            self.currentAITaskDescription = ""
            self.logToFile("[AI Helper LOG] Pre-exam card curation completed for module \(moduleCode). Saved \(selectedIds.count) card IDs to persistent UserDefaults.")
        }
    }
}
