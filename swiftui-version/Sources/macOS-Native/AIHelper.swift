import Foundation
import PDFKit

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
    
    init(model: String, prompt: String, stream: Bool = false, images: [String]? = nil, keep_alive: String? = "60m", options: OllamaOptions? = nil) {
        self.model = model
        self.prompt = prompt
        self.stream = stream
        self.images = images
        self.keep_alive = keep_alive
        self.options = options
    }
}

struct GenerateResponse: Codable {
    let response: String
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
    
    nonisolated static func normalizedOllamaURL(from rawHost: String?, defaultHost: String = "http://localhost:11434") -> URL? {
        let input = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var host = input.isEmpty ? defaultHost : input
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
    
    // Tailscale Network Discovery State
    @Published var discoveredHosts: [DiscoveredAIHost] = []
    @Published var isScanningTailscale: Bool = false
    @Published var showTailscaleSetupModal: Bool = false
    
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
            return UserDefaults.standard.string(forKey: "local_model_general") ?? "qwen2.5-coder:14b"
        } else if provider == "tailscale" {
            return UserDefaults.standard.string(forKey: "tailscale_model_general") ?? "qwen2.5-coder:14b"
        } else {
            return UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud"
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
    
    func startAITask(description: String, isVision: Bool = false, forceLocal: Bool = false, current: Int = 0, total: Int = 0) {
        let info: (isLocal: Bool, name: String)
        if forceLocal {
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
    }
    
    func finishAITask(force: Bool = false) {
        if force || self.activeProcessingNoteIds.isEmpty {
            self.isAIBusy = false
            self.currentAITaskDescription = ""
            self.activeProgressCurrent = 0
            self.activeProgressTotal = 0
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
    private var isProcessingExtractionQueue: Bool = false
    
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
        
        self.logToFile("[AI Batch Importer LOG] Queued \(groups.count) extraction groups. Clear session state completed.")
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
            // Check if both queues are empty to clear progress bar
            if classificationCompletedCount >= classificationQueueCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if self.extractionQueue.isEmpty && self.classificationQueue.isEmpty {
                        self.isClassifyingProblems = false
                        self.classificationQueueCount = 0
                        self.classificationCompletedCount = 0
                        self.queueStatusText = "Assigning Problems"
                    }
                }
            }
            return
        }
        
        isProcessingExtractionQueue = true
        let group = extractionQueue.removeFirst()
        
        Task {
            let startGroupTime = Date()
            var extractedQuestions = [ExtractedProblem]()
            var extractedAnswers = [ExtractedAnswer]()
            
            // 1. Extract Questions via visual transcription on Laptop
            let qItem = group.questionItem
            self.logToFile("[AI Batch Importer LOG] --------------------------------------------------")
            self.logToFile("[AI Batch Importer LOG] Starting extraction for group question item: \(qItem.pathOrName)")
            
            let startQExtract = Date()
            extractedQuestions = await self.extractProblemsUnified(item: qItem)
            let endQExtract = Date().timeIntervalSince(startQExtract)
            self.logToFile("[AI Batch Importer LOG] Parsed \(extractedQuestions.count) individual questions from group question item. (Took \(String(format: "%.2f", endQExtract))s)")
            
            self.classificationCompletedCount += 1 // Increment for question task
            
            // 2. Extract Answers (if any)
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
                
                endAExtract = Date().timeIntervalSince(startAExtract)
                self.logToFile("[AI Batch Importer LOG] Answer extraction completed. Parsed \(extractedAnswers.count) total answers. (Took \(String(format: "%.2f", endAExtract))s)")
                
                // 3. Fast match answers to questions and attach steps BEFORE displaying on screen
                let startMatch = Date()
                if !extractedAnswers.isEmpty && !extractedQuestions.isEmpty {
                    // Match by label/number heuristic first
                    for i in 0..<extractedQuestions.count {
                        if extractedQuestions[i].solution.isEmpty {
                            let qTargetNum = i + 1
                            if let matchAns = extractedAnswers.first(where: { ans in
                                let digits = ans.label.filter { $0.isNumber }
                                return Int(digits) == qTargetNum
                            }) {
                                extractedQuestions[i].solution = matchAns.content
                                let steps = self.splitSolutionIntoSteps(matchAns.content)
                                extractedQuestions[i].steps = !steps.isEmpty ? steps : [matchAns.content]
                                self.logToFile("[AI Batch Importer LOG] Attached answer for Question \(i + 1) [\(matchAns.label)] (\(extractedQuestions[i].steps.count) steps)")
                            }
                        }
                    }
                    
                    // Fallback to semantic matching for any remaining unassigned questions
                    let stillUnassigned = extractedQuestions.enumerated().filter { $0.element.solution.isEmpty }
                    if !stillUnassigned.isEmpty {
                        let unassignedQs = stillUnassigned.map { $0.element }
                        let matched = await self.matchQuestionsAndAnswers(questions: unassignedQs, answers: extractedAnswers)
                        for matchedQ in matched {
                            if let idx = extractedQuestions.firstIndex(where: { $0.id == matchedQ.id || $0.content == matchedQ.content }) {
                                if !matchedQ.solution.isEmpty {
                                    extractedQuestions[idx].solution = matchedQ.solution
                                    extractedQuestions[idx].steps = matchedQ.steps
                                }
                            }
                        }
                    }
                }
                endMatch = Date().timeIntervalSince(startMatch)
            }
            
            // 4. Output questions to screen (with their steps already populated if solutions exist)
            self.sessionExtractedProblems.append(contentsOf: extractedQuestions)
            self.logToFile("[AI Batch Importer LOG] Appended \(extractedQuestions.count) questions (with steps if available) to session list.")
            
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
    
    struct ExtractedAnswer {
        let label: String
        let content: String
    }
    
    func normalizeLaTeXDelimiters(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "\\[", with: "$$")
        result = result.replacingOccurrences(of: "\\]", with: "$$")
        result = result.replacingOccurrences(of: "\\(", with: "$")
        result = result.replacingOccurrences(of: "\\)", with: "$")
        return result
    }

    func isTaskLocal(_ key: String, defaultLocal: Bool = false) -> Bool {
        if let val = UserDefaults.standard.string(forKey: key) {
            return val == "local"
        }
        return defaultLocal
    }

    func extractAnswers(fromText text: String) async -> String? {
        await withUserPriority {
            let useLocal = isTaskLocal("route_math", defaultLocal: false)
            let model = await getOllamaModel(forceLocal: useLocal)
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
            return await callOllama(prompt: prompt, model: model, timeout: 120.0, forceLocal: useLocal)
        }
    }
    
    func extractAnswersFromImage(base64Image: String) async -> String? {
        await withUserPriority {
            let useLocal = isTaskLocal("route_vision", defaultLocal: true)
            guard let visionModel = await getOllamaVisionModel(forceLocal: useLocal) else { return "MODEL_NOT_FOUND" }
            let prompt = """
            You are a physics teaching assistant. Analyze this image containing solutions, answers, or an answer key.
            Extract and list all individual answers or solutions from the image.
            For each answer/solution:
            1. Keep the full mathematical derivations, calculations, intermediate steps, and final formulas intact.
            2. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            
            Format the output strictly as follows:
            [ANSWER]
            Label: <e.g. 'Problem 1', 'Question 2 (i)', or briefly summarize what the answer is about if no label exists>
            Content: <the full answer text, steps, or final answer code, with equations wrapped in dollar signs>
            [ANSWER]
            
            Do NOT include any introduction, explanations, or conversational filler. Output only the structured list.
            """
            return await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 180.0, forceLocal: useLocal)
        }
    }
    
    func parseExtractedAnswers(_ text: String) -> [ExtractedAnswer] {
        var answers: [ExtractedAnswer] = []
        let normalizedText = normalizeLaTeXDelimiters(text)
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
        return answers
    }
    
    func generateStepsFromAnswer(question: String, answer: String) async -> [String] {
        await withUserPriority {
            let useLocal = isTaskLocal("route_steps", defaultLocal: false)
            let model = await getOllamaModel(forceLocal: useLocal)
            self.logToFile("[AI Helper LOG] generateStepsFromAnswer called for question: '\(question.prefix(60))...'")
            let prompt = """
            You are an expert physics teaching assistant. Break down the following worked physics solution into 2 to 6 clear, numbered, pedagogical derivation steps.
            
            Question:
            ---
            \(question)
            ---
            
            Solution:
            ---
            \(answer)
            ---
            
            Rules:
            1. Each step MUST represent one clear derivation stage, equation manipulation, physical principle, or mathematical substitution.
            2. If the solution contains subparts (e.g. (i), (ii), (a), (b)), break each subpart and its main derivation stages into distinct steps.
            3. Preserve ALL mathematical derivations, formulas, integrals, boundary conditions, and final answers exactly.
            4. Wrap all math formulas, variables, and math symbols in standard single dollar signs ($...$) for inline math, and double dollar signs ($$...$$) on separate lines for display equations.
            5. Provide concise explanatory text before or alongside equations (e.g., 'Differentiate the Helmholtz free energy $F$ w.r.t. $V_1$:', 'Apply the thermodynamic definition for $P_i$:', etc.).
            6. Prefix each step with 'STEP:'. For example:
               STEP: State the differential form $$dG = \\alpha dx + \\beta \\frac{x}{y} dy$$.
               STEP: Compute the partial derivatives $$\\left(\\frac{\\partial A}{\\partial y}\\right)_x = 0 \\quad \\text{and} \\quad \\left(\\frac{\\partial B}{\\partial x}\\right)_y = \\frac{\\beta}{y}$$.
               STEP: Check for exactness. Since $$\\left(\\frac{\\partial A}{\\partial y}\\right)_x \\neq \\left(\\frac{\\partial B}{\\partial x}\\right)_y$$, the differential form is inexact.
            
            Output ONLY the list of steps starting with 'STEP:'. Do NOT include any conversation, markdown code fences, or introductory filler.
            """
            
            guard let res = await callOllama(prompt: prompt, model: model, timeout: 120.0, forceLocal: useLocal) else {
                return []
            }
            let steps = self.parseStepsFromLLMResponse(res)
            return steps
        }
    }
    
    func isStepHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        
        // 1. Check for "step" pattern (e.g. "Step 1:", "STEP:", "Step:")
        let stepPattern = "^[\\*#_\\s\\-]*step[s\\s\\-]*(\\d+|:|\\s+)"
        if let regex = try? NSRegularExpression(pattern: stepPattern, options: [.caseInsensitive]) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                let lower = trimmed.lowercased()
                if lower.contains("step-by-step") || lower.contains("steps:") || lower.contains("steps to") || lower.contains("following steps") {
                    return false
                }
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
        
        // 3. Check for numbered list pattern (e.g. "1. ", "1) ") followed by words (not just an isolated equation number)
        let numberPattern = "^[\\*#_\\s]*\\d+[\\.\\):]\\s+[A-Za-z\\$]"
        if let regex = try? NSRegularExpression(pattern: numberPattern, options: []) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        
        return false
    }
    
    func cleanStepText(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        
        // If it starts with Step X:, clean the prefix
        if let stepRange = lower.range(of: "step") {
            let sub = lower[stepRange.upperBound...]
            var charsToSkip = 0
            for char in sub {
                if char.isNumber || char == " " || char == ":" || char == "." || char == "-" || char == "*" || char == "_" || char == "#" || char == "•" || char == "+" || char == ")" {
                    charsToSkip += 1
                } else {
                    break
                }
            }
            let prefixLength = text.distance(from: text.startIndex, to: stepRange.upperBound) + charsToSkip
            if prefixLength > 0 && prefixLength < text.count {
                text = String(text.dropFirst(prefixLength))
            }
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func parseStepsFromLLMResponse(_ res: String) -> [String] {
        self.logToFile("[AI Helper LOG] Parsing LLM response into steps. Raw response length: \(res.count)")
        
        var steps = [String]()
        let lines = res.components(separatedBy: .newlines)
        
        var currentStepText = ""
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            let lower = trimmed.lowercased()
            if lower.contains("hope this helps") || lower.contains("let me know if you need") || lower.contains("feel free to ask") {
                self.logToFile("[AI Helper LOG] Skipping outro line: '\(trimmed)'")
                continue
            }
            
            if isStepHeader(trimmed) {
                if !currentStepText.isEmpty {
                    steps.append(normalizeLaTeXDelimiters(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentStepText = cleanStepText(trimmed)
                self.logToFile("[AI Helper LOG] Found new step header. Initial text: '\(currentStepText.prefix(60))...'")
            } else {
                if !currentStepText.isEmpty {
                    currentStepText += "\n" + trimmed
                } else {
                    // Do NOT drop initial math derivation lines
                    currentStepText = trimmed
                    self.logToFile("[AI Helper LOG] Starting initial step with: '\(trimmed.prefix(60))...'")
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
        for (i, step) in steps.enumerated() {
            self.logToFile("[AI Helper LOG] Step \(i+1): '\(step.prefix(80))...'")
        }
        
        return steps
    }
    
    func splitSolutionIntoSteps(_ solution: String) -> [String] {
        let normalized = normalizeLaTeXDelimiters(solution).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return [] }
        
        // 1. Check for explicit step headers (e.g. STEP:, Step 1:, etc.)
        let parsed = parseStepsFromLLMResponse(normalized)
        if parsed.count > 1 {
            return parsed
        }
        
        // 2. Check for subpart labels: (a), (b), (c), (i), (ii), (iii), Part 1:, • Path A:, ①-⑩
        let subpartPattern = "(?m)(?:^|\\n\\s*)(?:\\(([a-fA-F]|i{1,4}|iv|v|vi{1,3}|ix|x)\\)|([a-fA-F]|i{1,4}|iv|v|vi{1,3}|ix|x)\\.|•\\s*Path\\s+[A-Z]\\s*:|[①-⑩]|(?:Part|Phase|Stage)\\s+[A-Z0-9]+:)"
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
        
        // 3. Split by double-newlines (paragraphs)
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
        
        let useLocal = isTaskLocal("route_matching", defaultLocal: false)
        let model = await getOllamaModel(forceLocal: useLocal)
        
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
        You are a physics teaching assistant. Match each extracted question with its corresponding worked answer/solution from the lists below.
        
        Questions:
        ===
        \(qList)
        ===
        
        Answers:
        ===
        \(aList)
        ===
        
        For each match, output strictly:
        MATCH: Question ID X -> Answer ID Y
        
        Rules:
        1. Match based on question numbers, mathematical equations, variables, and physical concepts.
        2. A question can match at most one answer.
        3. Output ONLY the MATCH lines with no extra text.
        """
        
        guard let res = await callOllama(prompt: prompt, model: model, timeout: 120.0, forceLocal: useLocal) else { return questions }
        
        var updatedQuestions = questions
        let lines = res.components(separatedBy: .newlines)
        
        var matches = [(Int, Int)]()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("->") else { continue }
            
            let cleanLine = trimmed.lowercased()
                .replacingOccurrences(of: "match:", with: "")
                .replacingOccurrences(of: "question id", with: "")
                .replacingOccurrences(of: "question", with: "")
                .replacingOccurrences(of: "answer id", with: "")
                .replacingOccurrences(of: "answer", with: "")
                .trimmingCharacters(in: .whitespaces)
                
            let parts = cleanLine.components(separatedBy: "->")
            if parts.count == 2 {
                let qNum = String(parts[0].filter { $0.isNumber })
                let aNum = String(parts[1].filter { $0.isNumber })
                
                if let qIdx = Int(qNum), let aIdx = Int(aNum) {
                    if qIdx >= 0 && qIdx < updatedQuestions.count && aIdx >= 0 && aIdx < answers.count {
                        matches.append((qIdx, aIdx))
                    }
                }
            }
        }
        
        if matches.isEmpty && questions.count == answers.count {
            for i in 0..<questions.count {
                matches.append((i, i))
            }
        }
        
        if !matches.isEmpty {
            for (qIdx, aIdx) in matches {
                let ansContent = answers[aIdx].content
                let steps = self.splitSolutionIntoSteps(ansContent)
                
                updatedQuestions[qIdx].solution = ansContent
                updatedQuestions[qIdx].steps = !steps.isEmpty ? steps : [ansContent]
                self.logToFile("[AI Batch Importer LOG] Matched Question \(qIdx) -> Answer \(aIdx). Prepared \(updatedQuestions[qIdx].steps.count) steps.")
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
    
    public func parseExtractedProblems(_ text: String) -> [ExtractedProblem] {
        var problems: [ExtractedProblem] = []
        let normalizedText = normalizeLaTeXDelimiters(text)
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
            let h = normalizeLaTeXDelimiters(hintText.trimmingCharacters(in: .whitespacesAndNewlines))
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
    
    func logToFile(_ message: String) {
        print(message)
        let logPath = "/Users/matthewt/Projects/PhysicsStudyApp/batch_importer_run.log"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let logLine = "[\(timestamp)] \(message)\n"
        
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }
    
    private init() {
        startAutoReconnectMonitor()
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
            let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream"]
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
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
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

    // MARK: - API communication helpers
    
    func fetchAvailableOllamaModels(host: String? = nil, forceLocal: Bool = false) async -> [String] {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        let targetHost: String
        if let h = host, !h.isEmpty {
            targetHost = h
        } else {
            targetHost = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "tailscale_host") ?? "") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        }
        
        guard !targetHost.isEmpty else { return [] }
        guard let baseURL = AIHelper.normalizedOllamaURL(from: targetHost, defaultHost: "http://localhost:11434") else { return [] }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.map { $0.name }.sorted()
        } catch {
            print("[AI Helper] Could not fetch available models from \(url.absoluteString): \(error)")
            return []
        }
    }

    func getOllamaModel(forceLocal: Bool = false) async -> String {
        // If using a cloud provider, return the configured cloud model name
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        if provider != "local" && provider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud"
            return cloudModel
        }
        
        let preferredKey = provider == "tailscale" ? "tailscale_model_general" : "local_model_general"
        let preferred = UserDefaults.standard.string(forKey: preferredKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        // Dynamically fetch installed models from Ollama server
        let installed = await fetchAvailableOllamaModels(forceLocal: forceLocal)
        if !installed.isEmpty {
            // 1. If preferred model is in installed models list, return it
            if !preferred.isEmpty && installed.contains(preferred) {
                return preferred
            }
            // 2. If preferred substring matches an installed model (e.g. qwen2.5-coder:14b or deepseek-r1)
            if !preferred.isEmpty, let match = installed.first(where: { $0.lowercased().contains(preferred.lowercased()) }) {
                return match
            }
            // 3. Prefer non-vision general/coder models (e.g. qwen2.5-coder, deepseek, llama)
            if let targetText = installed.first(where: { !$0.lowercased().contains("vl") && !$0.lowercased().contains("vision") && ($0.lowercased().contains("coder") || $0.lowercased().contains("qwen") || $0.lowercased().contains("deepseek") || $0.lowercased().contains("llama")) }) {
                return targetText
            }
            // 4. Any non-vision model
            if let nonVision = installed.first(where: { !$0.lowercased().contains("vl") && !$0.lowercased().contains("vision") }) {
                return nonVision
            }
            // 5. Fallback
            return installed.first ?? (provider == "tailscale" ? "qwen2.5-coder:14b" : "qwen2.5-coder:7b")
        }
        
        return preferred.isEmpty ? (provider == "tailscale" ? "qwen2.5-coder:14b" : "qwen2.5-coder:7b") : preferred
    }
    
    func getOllamaVisionModel(forceLocal: Bool = false) async -> String? {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local"))
        if provider != "local" && provider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
            return cloudModel
        }
        if provider == "tailscale" {
            let preferred = UserDefaults.standard.string(forKey: "vision_tailscale_model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !preferred.isEmpty {
                return preferred
            }
        } else {
            let preferred = UserDefaults.standard.string(forKey: "local_model_vision")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !preferred.isEmpty {
                return preferred
            }
        }
        
        let defaultVisionModel = "qwen2.5vl:7b"
        let host: String
        if provider == "tailscale" {
            let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            host = !vHost.isEmpty ? vHost : tHost
        } else {
            host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        }
        
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "http://localhost:11434") else { return defaultVisionModel }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            
            // 1. Prioritize explicit Qwen VL (Vision Language) models
            for m in tags.models {
                let name = m.name.lowercased()
                if name.contains("qwen") && (name.contains("vl") || name.contains("vision")) {
                    return m.name
                }
            }
            
            // 2. Fallback to other VL models
            for m in tags.models {
                let name = m.name.lowercased()
                if name.contains("vl") || name.contains("vision") || name.contains("llava") || name.contains("minicpm") || name.contains("moondream") {
                    return m.name
                }
            }
            
            // 3. Last fallback (excluding known coder/text models)
            let keywords = ["qwen", "llava", "minicpm", "moondream"]
            for kw in keywords {
                for m in tags.models {
                    let name = m.name.lowercased()
                    if name.contains(kw) && !name.contains("coder") && !name.contains("text") {
                        return m.name
                    }
                }
            }
        } catch {
            print("[AI Helper] Warning: Error checking for vision model: \(error)")
        }
        return defaultVisionModel
    }
    
    private func hasRepetitiveGlitch(_ text: String) -> Bool {
        // Match 5 or more identical characters in a row, excluding spaces, dashes, asterisks, equals, dots, underscores, and newlines
        let pattern = "([^ \\-\\*=\\._\\n\\r])\\1{4,}"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
    
    func callOllama(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval = 300.0, forceLocal: Bool = false, options: OllamaOptions? = nil) async -> String? {
        let hasImages = images != nil && !(images?.isEmpty ?? true)
        let isWasBusy = self.isAIBusy
        if !isWasBusy {
            startAITask(
                description: hasImages ? "Processing Vision Request..." : "Processing AI Request...",
                isVision: hasImages,
                forceLocal: forceLocal
            )
        }
        defer {
            if !isWasBusy {
                finishAITask(force: true)
            }
        }
        
        let targetModel: String
        let effectiveProvider: String
        let effectiveImages: [String]? = images
        
        if hasImages {
            let visionProvider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local"))
            if visionProvider == "local" || visionProvider == "tailscale" {
                if visionProvider == "local" {
                    await ensureLocalOllamaRunning()
                }
                let visionModel = await getOllamaVisionModel(forceLocal: forceLocal) ?? model
                targetModel = visionModel
                effectiveProvider = visionProvider
                self.logToFile("[AI Helper LOG] Vision request using \(visionProvider) vision model: \(visionModel)")
            } else {
                targetModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
                effectiveProvider = "cloud_vision"
                self.logToFile("[AI Helper LOG] Vision request using cloud vision model (\(visionProvider)): \(targetModel)")
            }
        } else {
            let textProvider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
            if textProvider == "local" || textProvider == "tailscale" {
                if textProvider == "local" {
                    await ensureLocalOllamaRunning()
                }
                targetModel = model.isEmpty ? await getOllamaModel(forceLocal: forceLocal) : model
                effectiveProvider = textProvider
                self.logToFile("[AI Helper LOG] Text request using \(textProvider) model: \(targetModel)")
            } else {
                targetModel = UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud"
                effectiveProvider = textProvider
                self.logToFile("[AI Helper LOG] Text request using cloud model (\(textProvider)): \(targetModel)")
            }
        }
        
        let maxRetries = (effectiveProvider == "tailscale") ? 2 : 3
        for attempt in 1...maxRetries {
            self.logToFile("[AI Helper LOG] callOllama (\(effectiveProvider)) attempt \(attempt)/\(maxRetries) for model: \(targetModel)")
            if let result = await callAPIOnce(prompt: prompt, model: targetModel, images: effectiveImages, timeout: timeout, provider: effectiveProvider, options: options) {
                if hasRepetitiveGlitch(result) {
                    self.logToFile("[AI Helper LOG] Repetitive glitch detected (attempt \(attempt)/\(maxRetries)): '\(result.prefix(100))...'")
                    continue
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
                if attempt < maxRetries {
                    if effectiveProvider == "tailscale" {
                        self.logToFile("[AI Helper LOG] Tailscale request attempt \(attempt) failed, attempting auto-reconnect...")
                        let reconnected = await self.attemptAutoReconnect()
                        if reconnected {
                            self.logToFile("[AI Helper LOG] Auto-reconnected to Tailscale successfully, retrying request immediately.")
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        } else {
                            let backoff = UInt64(attempt) * 1_500_000_000
                            self.logToFile("[AI Helper LOG] Waiting \(Double(backoff) / 1e9)s for Tailscale link to recover before attempt \(attempt + 1)...")
                            try? await Task.sleep(nanoseconds: backoff)
                        }
                    } else {
                        let online = await self.isOllamaRunning()
                        if !online {
                            self.logToFile("[AI Helper LOG] AI host unreachable on attempt \(attempt), stopping retries.")
                            break
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
        
        // Automatic Fallback: If Tailscale was unreachable, check if Local Ollama is available
        if effectiveProvider == "tailscale" && !forceLocal {
            self.logToFile("[AI Helper LOG] Tailscale host unreachable, checking Local Ollama fallback...")
            let localHost = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            if let localBaseURL = AIHelper.normalizedOllamaURL(from: localHost, defaultHost: "http://localhost:11434") {
                let tagsUrl = localBaseURL.appendingPathComponent("api/tags")
                var checkReq = URLRequest(url: tagsUrl)
                checkReq.timeoutInterval = 1.0
                if let (data, resp) = try? await session.data(for: checkReq),
                   let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
                   let tags = try? JSONDecoder().decode(TagsResponse.self, from: data),
                   !tags.models.isEmpty {
                    let fallbackModel: String
                    if effectiveImages != nil {
                        fallbackModel = await getOllamaVisionModel(forceLocal: true) ?? "qwen2.5vl:7b"
                    } else {
                        fallbackModel = await getOllamaModel(forceLocal: true)
                    }
                    self.logToFile("[AI Helper LOG] Seamlessly falling back to Local Ollama with model '\(fallbackModel)'...")
                    if let localResult = await callAPIOnce(prompt: prompt, model: fallbackModel, images: effectiveImages, timeout: timeout, provider: "local", options: options) {
                        if !hasRepetitiveGlitch(localResult) {
                            return localResult
                        }
                    }
                }
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
    
    private func callAPIOnce(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval, provider: String, options: OllamaOptions? = nil) async -> String? {
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
            
            let body = GenerateRequest(model: model, prompt: prompt, stream: false, images: images, options: options)
            do {
                request.httpBody = try JSONEncoder().encode(body)
                let (data, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let errBody = String(data: data, encoding: .utf8) ?? ""
                    self.logToFile("[AI Helper LOG] HTTP \(httpResponse.statusCode) from \(provider) Ollama (\(url.absoluteString)): \(errBody)")
                    return nil
                }
                let responseObj = try JSONDecoder().decode(GenerateResponse.self, from: data)
                return responseObj.response.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with \(provider) Ollama (\(url.absoluteString)): \(error.localizedDescription)")
                return nil
            }
        } else {
            // Determine which API settings to use — text cloud or vision cloud
            let baseUrl: String
            let apiKey: String
            if provider == "cloud_vision" {
                baseUrl = UserDefaults.standard.string(forKey: "vision_api_base_url") ?? ""
                apiKey = UserDefaults.standard.string(forKey: "vision_api_key") ?? ""
            } else {
                baseUrl = UserDefaults.standard.string(forKey: "cloud_api_base_url") ?? ""
                apiKey = UserDefaults.standard.string(forKey: "cloud_api_key") ?? ""
            }
            let cleanBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            // If the base URL already ends with /v1, don't double-append it
            let endpoint: String
            if cleanBase.hasSuffix("/v1") {
                endpoint = "\(cleanBase)/chat/completions"
            } else {
                endpoint = "\(cleanBase)/v1/chat/completions"
            }
            guard let url = URL(string: endpoint) else {
                self.logToFile("[AI Helper LOG] Invalid API Base URL configured: '\(baseUrl)'")
                return nil
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            
            // Format for Chat Completion endpoint
            var messagesContent: [[String: Any]] = []
            messagesContent.append([
                "type": "text",
                "text": prompt
            ])
            
            if let images = images {
                for imgBase64 in images {
                    messagesContent.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/png;base64,\(imgBase64)"
                        ]
                    ])
                }
            }
            
            let bodyDict: [String: Any] = [
                "model": model,
                "messages": [
                    [
                        "role": "user",
                        "content": images != nil ? messagesContent as Any : prompt as Any
                    ]
                ],
                "stream": false
            ]
            
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
                let (data, _) = try await session.data(for: request)
                
                if let responseJSON = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    if let choices = responseJSON["choices"] as? [[String: Any]],
                       let firstChoice = choices.first,
                       let message = firstChoice["message"] as? [String: Any],
                       let content = message["content"] as? String {
                        return content.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if let errorDict = responseJSON["error"] as? [String: Any],
                              let msg = errorDict["message"] as? String {
                        self.logToFile("[AI Helper LOG] OpenAI-compatible API error message: \(msg)")
                        return nil
                    }
                }
                
                let rawString = String(data: data, encoding: .utf8) ?? "Unable to decode string"
                self.logToFile("[AI Helper LOG] Unexpected OpenAI response structure: \(rawString)")
                return nil
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with OpenAI-compatible API (\(url)): \(error)")
                return nil
            }
        }
    }
    
    func pullOllamaModel(modelName: String) async -> Bool {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let host = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "tailscale_host") ?? "http://100.64.0.4:11434") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        guard let bURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: provider == "tailscale" ? "http://100.64.0.4:11434" : "http://localhost:11434") else { return false }
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
    
    // MARK: - Unified Extraction
    
    /// Unified extraction: renders all PDF pages to high-resolution images and transcribes via the visual AI model (Qwen2.5-VL), ensuring complete visual comprehension of math, layouts, and derivations.
    func extractProblemsUnified(item: ExtractionQueueItem, onPageExtracted: (@MainActor ([ExtractedProblem]) async -> Void)? = nil) async -> [ExtractedProblem] {
        if item.type == .pdf {
            let pdfPath = item.pathOrName
            self.logToFile("[AI Batch Importer LOG] PDF '\(pdfPath)' — rendering high-res page images for visual AI transcription")
            let images = convertPDFToImages(path: pdfPath, maxPages: 25)
            var allProblems = [ExtractedProblem]()
            for (idx, base64) in images.enumerated() {
                self.logToFile("[AI Batch Importer LOG] Visual transcription for page \(idx + 1)/\(images.count) of \(pdfPath)")
                if let rawText = await extractProblemsFromImage(base64Image: base64) {
                    if rawText != "MODEL_NOT_FOUND" {
                        let normalized = normalizeLaTeXDelimiters(rawText)
                        let parsed = parseExtractedProblems(normalized)
                        self.logToFile("[AI Batch Importer LOG] Page \(idx + 1) parsed \(parsed.count) problems.")
                        allProblems.append(contentsOf: parsed)
                        if let onPageExtracted = onPageExtracted {
                            await onPageExtracted(parsed)
                        }
                    }
                }
            }
            return allProblems
        } else if item.type == .image, let base64 = item.imageBase64 {
            self.logToFile("[AI Batch Importer LOG] Using visual AI model for image: \(item.pathOrName)")
            if let rawText = await extractProblemsFromImage(base64Image: base64) {
                if rawText != "MODEL_NOT_FOUND" {
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
            self.logToFile("[AI Batch Importer LOG] PDF '\(pdfPath)' — rendering high-res page images for visual AI answer extraction")
            let images = convertPDFToImages(path: pdfPath, maxPages: 25)
            var allAnswers = [ExtractedAnswer]()
            for (idx, base64) in images.enumerated() {
                self.logToFile("[AI Batch Importer LOG] Visual answer extraction for page \(idx + 1)/\(images.count) of \(pdfPath)")
                if let rawText = await extractAnswersFromImage(base64Image: base64) {
                    if rawText != "MODEL_NOT_FOUND" {
                        let normalized = normalizeLaTeXDelimiters(rawText)
                        let parsed = parseExtractedAnswers(normalized)
                        self.logToFile("[AI Batch Importer LOG] Page \(idx + 1) parsed \(parsed.count) answers.")
                        allAnswers.append(contentsOf: parsed)
                        if let onPageExtracted = onPageExtracted {
                            await onPageExtracted(parsed)
                        }
                    }
                }
            }
            return allAnswers
        } else if item.type == .image, let base64 = item.imageBase64 {
            self.logToFile("[AI Batch Importer LOG] Using visual AI model for image: \(item.pathOrName)")
            if let rawText = await extractAnswersFromImage(base64Image: base64) {
                if rawText != "MODEL_NOT_FOUND" {
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
    
    func convertPDFToImages(path: String, maxPages: Int = 15) -> [String] {
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
                // Render at 1.5x scale for optimal OCR quality
                let size = CGSize(width: bounds.width * 1.5, height: bounds.height * 1.5)
                let image = page.thumbnail(of: size, for: .mediaBox)
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    let base64 = pngData.base64EncodedString()
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
                let visionModel = await getOllamaVisionModel() ?? "qwen2.5vl:7b"
                let prompt = "\(summaryPromptTemplate)\n\nPlease extract and summarize the core physics equations and concepts from these lecture note pages into the required formula-first format."
                summaryRes = await callOllama(prompt: prompt, model: visionModel, images: images, timeout: 300.0)
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
    
    private func cleanLaTeXOutput(_ text: String?) -> String? {
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
            "Here is the formula:"
        ]
        for prefix in introPrefixes {
            if result.lowercased().hasPrefix(prefix.lowercased()) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
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
            let useLocal = latexAlwaysLocal
            let model = await getOllamaModel(forceLocal: useLocal)
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
            
            let fastOptions = OllamaOptions(temperature: 0.0, num_predict: 512, top_p: 0.9)
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal, options: fastOptions)
            // Bidirectional fallback: if preferred provider failed, try the opposite (Local <-> Remote)
            if res == nil {
                let fallbackUseLocal = !useLocal
                self.logToFile("[AI Helper LOG] LaTeX translation failed on preferred provider, trying fallback (forceLocal: \(fallbackUseLocal))...")
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal, options: fastOptions)
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
            let useLocal = latexAlwaysLocal
            let prompt = """
            Transcribe the mathematical equation or expression in this image into valid LaTeX format. \
            Do NOT wrap the equation in any delimiters like $ or $$ or \\[ or \\]. \
            Do NOT include <think> tags or conversational filler. Return ONLY the raw LaTeX code itself.
            """
            let fastOptions = OllamaOptions(temperature: 0.0, num_predict: 512, top_p: 0.9)
            
            // 1. Initial attempt with preferred provider
            var res: String? = nil
            if let visionModel = await getOllamaVisionModel(forceLocal: useLocal) {
                res = await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 120.0, forceLocal: useLocal, options: fastOptions)
            }
            
            // 2. Bidirectional fallback (Local <-> Tailscale)
            if res == nil {
                let fallbackUseLocal = !useLocal
                self.logToFile("[AI Helper LOG] LaTeX image transcription failed on preferred provider, trying fallback (forceLocal: \(fallbackUseLocal))...")
                if let fallbackVisionModel = await getOllamaVisionModel(forceLocal: fallbackUseLocal) {
                    res = await callOllama(prompt: prompt, model: fallbackVisionModel, images: [base64Image], timeout: 120.0, forceLocal: fallbackUseLocal, options: fastOptions)
                }
            }
            
            // 3. Fallback to Cloud Vision if configured
            if res == nil {
                let visionProvider = UserDefaults.standard.string(forKey: "vision_provider") ?? "local"
                let cloudKey = UserDefaults.standard.string(forKey: "vision_api_key") ?? ""
                let cloudBase = UserDefaults.standard.string(forKey: "vision_api_base_url") ?? ""
                if (visionProvider != "local" && visionProvider != "tailscale") || !cloudKey.isEmpty || !cloudBase.isEmpty {
                    let cloudModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
                    res = await callAPIOnce(prompt: prompt, model: cloudModel, images: [base64Image], timeout: 120.0, provider: "cloud_vision")
                }
            }
            
            return cleanLaTeXOutput(res)
        }
    }
    
    func extractProblemsFromPDF(pdfText: String) async -> String? {
        await withUserPriority {
            let useLocal = isTaskLocal("route_problem_extraction", defaultLocal: false)
            let model = await getOllamaModel(forceLocal: useLocal)
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
            
            return await callOllama(prompt: prompt, model: model, timeout: 120.0, forceLocal: useLocal)
        }
    }
    
    func extractProblemsFromImage(base64Image: String) async -> String? {
        await withUserPriority {
            let useLocal = isTaskLocal("route_vision", defaultLocal: true)
            guard let visionModel = await getOllamaVisionModel(forceLocal: useLocal) else {
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
            
            return await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 180.0, forceLocal: useLocal)
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
            let useLocal = isTaskLocal("route_classification", defaultLocal: false)
            let model = await getOllamaModel(forceLocal: useLocal)
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
            
            if let res = await callOllama(prompt: prompt, model: model, timeout: 60.0, forceLocal: useLocal) {
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
            let useLocal = feynmanAlwaysLocal
            let model = await getOllamaModel(forceLocal: useLocal)
            let prompt = """
            You are a physics professor. The user is using the Feynman technique to explain a lecture note they just studied.
            Lecture Note Title: \(noteTitle)
            Reference Summary (overview and key concepts): 
            \(aiSummary)

            The user's explanation:
            \(explanation)

            Assess the user's explanation. Grade it out of 10 (integer rating) based on accuracy, completeness, and clarity. \
            List any important concepts, terms, or equations from the reference summary that the user left out or explained poorly.

            Your response MUST follow this exact structure:
            Rating: [X]/10
            Feedback: [1-2 sentences of general encouragement/feedback]
            Concepts Left Out:
            - [Concept/Equation 1]: [brief note why it is important]
            - [Concept/Equation 2]: [brief note why it is important]

            Do NOT include any conversational introduction or outro. Start directly with 'Rating:'.
            """
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
            if res == nil {
                let fallbackUseLocal = !useLocal
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal)
            }
            return res
        }
    }
    
    func getFeynmanDialogueResponse(noteTitle: String, aiSummary: String, chatHistory: [FeynmanChat]) async -> String? {
        await withUserPriority {
            let useLocal = feynmanAlwaysLocal
            let model = await getOllamaModel(forceLocal: useLocal)
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
            
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
            if res == nil {
                let fallbackUseLocal = !useLocal
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal)
            }
            return res ?? "I'm having a bit of trouble formulating my thoughts right now. Could you please rephrase or expand on your previous explanation?"
        }
    }
    
    func generateFeynmanStartingQuestion(noteTitle: String, aiSummary: String) async -> String? {
        await withUserPriority {
            let useLocal = feynmanAlwaysLocal
            let model = await getOllamaModel(forceLocal: useLocal)
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
            
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
            if res == nil {
                let fallbackUseLocal = !useLocal
                let fallbackModel = await getOllamaModel(forceLocal: fallbackUseLocal)
                res = await callOllama(prompt: prompt, model: fallbackModel, forceLocal: fallbackUseLocal)
            }
            return res ?? "Can you explain the main physical concepts and principles covered in the '\(noteTitle)' lecture?"
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
            let modelsUrlString: String
            if cleanBase.hasSuffix("/v1") || cleanBase.hasSuffix("/v1beta") {
                modelsUrlString = "\(cleanBase)/models"
            } else {
                modelsUrlString = "\(cleanBase)/v1/models"
            }
            guard let url = URL(string: modelsUrlString) else { return false }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3.0
            let apiKey = UserDefaults.standard.string(forKey: "cloud_api_key") ?? ""
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
    
    /// Ensures local Ollama is running. Used for lazy startup when a cloud provider
    /// is selected but a vision request needs to fall back to a local vision model.
    func ensureLocalOllamaRunning() async {
        // Quick check — is it already running?
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        do {
            _ = try await session.data(for: request)
            return // Already running
        } catch {
            // Not running — start it
        }
        
        self.logToFile("[AI Helper LOG] Starting local Ollama for vision fallback...")
        let process = Process()
        let paths = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        var execPath = "ollama"
        for p in paths {
            if FileManager.default.fileExists(atPath: p) {
                execPath = p
                break
            }
        }
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["serve"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            // Wait for Ollama to be ready (up to 10 seconds)
            for _ in 0..<10 {
                var checkReq = URLRequest(url: url)
                checkReq.timeoutInterval = 1.0
                if let _ = try? await session.data(for: checkReq) {
                    self.logToFile("[AI Helper LOG] Local Ollama started successfully for vision fallback.")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self.logToFile("[AI Helper LOG] Local Ollama did not become ready within 10s.")
        } catch {
            self.logToFile("[AI Helper LOG] Error starting local Ollama: \(error)")
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
            let useLocal = isTaskLocal("route_math", defaultLocal: false)
            let model = await getOllamaModel(forceLocal: useLocal)
            let prompt = """
            You are an expert physics solver. Solve the following practice problem step-by-step:
            ---
            \(content)
            ---
            Provide a clean, precise, and accurate solution. Use LaTeX formatting for all mathematical equations.
            ALWAYS wrap all inline math variables, formulas, and math symbols in single dollar signs (e.g. $x_i$, $\theta$), and all block equations in double dollar signs (e.g. $$E = mc^2$$) on their own lines. Never output naked equations or symbols without delimiters.
            Output ONLY the final solution and explanation. Do not include conversational introduction or general filler.
            """
            return await callOllama(prompt: prompt, model: model, timeout: 120.0, forceLocal: useLocal) ?? ""
        }
    }
    
    func generateProblemSteps(content: String, solution: String) async -> [String] {
        await withUserPriority {
            let useLocal = isTaskLocal("route_steps", defaultLocal: false)
            let model = await getOllamaModel(forceLocal: useLocal)
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
            self.logToFile("[AI Helper LOG] Sending prompt to Ollama (\(model))...")
            guard let res = await callOllama(prompt: prompt, model: model, timeout: 120.0, forceLocal: useLocal) else {
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
                
                if let start = response.firstIndex(of: "["),
                   let end = response.lastIndex(of: "]"),
                   start <= end {
                    let jsonSubstring = String(response[start...end])
                    if let data = jsonSubstring.data(using: .utf8),
                       let ids = try? JSONSerialization.jsonObject(with: data, options: []) as? [Int],
                       !ids.isEmpty {
                        selectedIds = ids
                        self.logToFile("[AI Helper LOG] Successfully parsed \(ids.count) AI-selected card IDs: \(ids)")
                    } else {
                        self.logToFile("[AI Helper LOG] Substring JSON array extraction failed for string: '\(jsonSubstring.prefix(100))'")
                    }
                } else {
                    self.logToFile("[AI Helper LOG] No '[' or ']' brackets found in response.")
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
