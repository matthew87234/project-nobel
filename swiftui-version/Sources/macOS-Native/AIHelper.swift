import Foundation
import PDFKit

struct GenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
    let images: [String]?
    
    init(model: String, prompt: String, stream: Bool = false, images: [String]? = nil) {
        self.model = model
        self.prompt = prompt
        self.stream = stream
        self.images = images
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
            return true
        }
        return UserDefaults.standard.bool(forKey: "latex_always_local")
    }
    
    var feynmanAlwaysLocal: Bool {
        if UserDefaults.standard.object(forKey: "feynman_always_local") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "feynman_always_local")
    }
    
    private let session = URLSession.shared
    private var baseURL: URL {
        let host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return URL(string: cleanHost) ?? URL(string: "http://localhost:11434")!
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

    func pairQuestionsAndAnswers(questions: [PendingExtractionItem], answers: [PendingExtractionItem]) -> [ExtractionGroup] {
        var groups = [ExtractionGroup]()
        
        for q in questions {
            var matchedAnswers = [PendingExtractionItem]()
            let qSheetNum = extractSheetNumber(q.pathOrName)
            
            for a in answers {
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
            groups.append(ExtractionGroup(questionItem: q, answerItems: matchedAnswers))
        }
        return groups
    }
    
    func queueGroupsForExtraction(groups: [ExtractionGroup]) {
        self.sessionExtractedProblems = []
        self.sessionExtractedAnswers = []
        
        if !self.isClassifyingProblems {
            self.isClassifyingProblems = true
            self.classificationQueueCount = 0
            self.classificationCompletedCount = 0
        }
        
        self.queueStatusText = "Extracting Problems..."
        var totalTasks = 0
        for g in groups {
            totalTasks += 1
            totalTasks += g.answerItems.count
        }
        self.classificationQueueCount += totalTasks
        
        self.logToFile("[AI Batch Importer LOG] Queued \(groups.count) extraction groups. Clear session state completed.")
        for g in groups {
            let qType: ExtractionQueueItem.ItemType = (g.questionItem.type == .pdf) ? .pdf : .image
            let qItem = ExtractionQueueItem(type: qType, pathOrName: g.questionItem.pathOrName, imageBase64: g.questionItem.imageBase64, isAnswerSource: false, originalPdfPath: g.questionItem.originalPdfPath)
            
            var aItems = [ExtractionQueueItem]()
            for ans in g.answerItems {
                let aType: ExtractionQueueItem.ItemType = (ans.type == .pdf) ? .pdf : .image
                let aItem = ExtractionQueueItem(type: aType, pathOrName: ans.pathOrName, imageBase64: ans.imageBase64, isAnswerSource: true, originalPdfPath: ans.originalPdfPath)
                aItems.append(aItem)
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
            
            // 1. Extract Questions
            let qItem = group.questionItem
            self.logToFile("[AI Batch Importer LOG] --------------------------------------------------")
            self.logToFile("[AI Batch Importer LOG] Starting extraction for group question item: \(qItem.pathOrName)")
            
            let startQExtract = Date()
            extractedQuestions = await extractProblemsUnified(item: qItem)
            let endQExtract = Date().timeIntervalSince(startQExtract)
            self.logToFile("[AI Batch Importer LOG] Parsed \(extractedQuestions.count) individual questions from group question item. (Took \(String(format: "%.2f", endQExtract))s)")
            
            // 2. Extract Answers (if any)
            var endAExtract: TimeInterval = 0.0
            if !group.answerItems.isEmpty {
                let startAExtract = Date()
                self.logToFile("[AI Batch Importer LOG] Starting answer extraction for \(group.answerItems.count) answer items sequentially.")
                
                for aItem in group.answerItems {
                    self.logToFile("[AI Batch Importer LOG] Starting answer extraction for group answer item: \(aItem.pathOrName)")
                    let fileAnswers = await extractAnswersUnified(item: aItem)
                    extractedAnswers.append(contentsOf: fileAnswers)
                    
                    DispatchQueue.main.async {
                        self.classificationCompletedCount += 1
                    }
                }
                
                endAExtract = Date().timeIntervalSince(startAExtract)
                self.logToFile("[AI Batch Importer LOG] Answer extraction completed sequentially. Parsed \(extractedAnswers.count) total answers. (Took \(String(format: "%.2f", endAExtract))s)")
                
                // Add extracted answers to the session list of all answers
                let newAnswers = extractedAnswers
                DispatchQueue.main.async {
                    self.sessionExtractedAnswers.append(contentsOf: newAnswers)
                    self.logToFile("[AI Batch Importer LOG] Accumulated new answers. Total answers in session: \(self.sessionExtractedAnswers.count)")
                }
            }
            
            // 3. Match questions in the current group with newly extracted answers BEFORE displaying them
            var matchedQuestions = extractedQuestions
            var endGroupMatch: TimeInterval = 0.0
            if !extractedAnswers.isEmpty && !extractedQuestions.isEmpty {
                let startGroupMatch = Date()
                self.logToFile("[AI Batch Importer LOG] Running final matching pass for group and generating steps...")
                matchedQuestions = await matchQuestionsAndAnswers(questions: extractedQuestions, answers: extractedAnswers)
                endGroupMatch = Date().timeIntervalSince(startGroupMatch)
                self.logToFile("[AI Batch Importer LOG] Final group matching completed. (Took \(String(format: "%.2f", endGroupMatch))s)")
            }
            
            // 4. Update the screen (only once everything is matched and step-by-step solutions are generated!)
            let finalQuestions = matchedQuestions
            DispatchQueue.main.async {
                self.classificationCompletedCount += 1 // Increment for question task
                
                // Add the matched questions (with steps) to the session
                self.sessionExtractedProblems.append(contentsOf: finalQuestions)
                self.logToFile("[AI Batch Importer LOG] Appended \(finalQuestions.count) fully matched questions with steps to session list.")
            }
            
            // 5. Cross-page match fallback:
            // Match ALL questions currently in the session with ALL answers extracted so far!
            // This ensures questions on other sheets/pages get matched against answers in the accumulated answer list!
            try? await Task.sleep(nanoseconds: 100_000_000) // Brief pause to ensure append is registered
            
            let allQuestions = self.sessionExtractedProblems
            let allAnswers = self.sessionExtractedAnswers
            var endCrossMatch: TimeInterval = 0.0
            if !allAnswers.isEmpty && !allQuestions.isEmpty {
                let startCrossMatch = Date()
                self.logToFile("[AI Batch Importer LOG] Running cross-page matching fallback with \(allQuestions.count) questions and \(allAnswers.count) answers...")
                let crossMatched = await matchQuestionsAndAnswers(questions: allQuestions, answers: allAnswers)
                endCrossMatch = Date().timeIntervalSince(startCrossMatch)
                
                DispatchQueue.main.async {
                    for updatedQ in crossMatched {
                        if let idx = self.sessionExtractedProblems.firstIndex(where: {
                            return $0.id == updatedQ.id || $0.content == updatedQ.content
                        }) {
                            // Update steps if found
                            if !updatedQ.steps.isEmpty {
                                self.logToFile("[AI Batch Importer LOG] Cross-page match success: Updated Question '\(updatedQ.content.prefix(30))...' with steps.")
                                self.sessionExtractedProblems[idx].steps = updatedQ.steps
                                self.sessionExtractedProblems[idx].solution = ""
                            }
                        }
                    }
                }
            }
            
            let totalGroupTime = Date().timeIntervalSince(startGroupTime)
            self.logToFile("[AI Batch Importer LOG] ==================================================")
            self.logToFile("[AI Batch Importer LOG] GROUP RUN TIMING REPORT SUMMARY:")
            self.logToFile("[AI Batch Importer LOG] Question Extraction:  \(String(format: "%.2f", endQExtract))s")
            self.logToFile("[AI Batch Importer LOG] Answer Extraction:    \(String(format: "%.2f", endAExtract))s")
            self.logToFile("[AI Batch Importer LOG] Within-Group Matching: \(String(format: "%.2f", endGroupMatch))s")
            self.logToFile("[AI Batch Importer LOG] Cross-Page Matching:  \(String(format: "%.2f", endCrossMatch))s")
            self.logToFile("[AI Batch Importer LOG] Total Processing Time: \(String(format: "%.2f", totalGroupTime))s")
            self.logToFile("[AI Batch Importer LOG] ==================================================")
            
            DispatchQueue.main.async {
                self.isProcessingExtractionQueue = false
                self.processNextExtractionQueueItem()
            }
        }
    }
    
    // MARK: - Answer extraction and matching helpers
    
    struct ExtractedAnswer {
        let label: String
        let content: String
    }
    
    func extractAnswers(fromText text: String) async -> String? {
        await withUserPriority {
            let model = await getOllamaModel()
            let prompt = """
            You are a physics teaching assistant. Analyze the following text containing solutions, answers, or an answer key:
            ---
            \(text)
            ---
            Extract and list all individual answers or solutions from the text.
            For each answer/solution:
            1. Keep the full explanation, steps, or final numbers intact.
            2. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            
            Format the output strictly as follows:
            [ANSWER]
            Label: <e.g. 'Question 1', 'Problem 2.3', or briefly summarize what the answer is about if no label exists>
            Content: <the full answer text, steps, or final answer code, with equations wrapped in dollar signs>
            [ANSWER]
            Label: <label or brief summary>
            Content: <answer text>
            
            Do NOT include any introduction, explanations, or conversational filler. Output only the structured list.
            """
            return await callOllama(prompt: prompt, model: model)
        }
    }
    
    func extractAnswersFromImage(base64Image: String) async -> String? {
        await withUserPriority {
            guard let visionModel = await getOllamaVisionModel() else { return "MODEL_NOT_FOUND" }
            let prompt = """
            You are a physics teaching assistant. Analyze this image containing solutions, answers, or an answer key.
            Extract and list all individual answers or solutions from the image.
            For each answer/solution:
            1. Keep the full explanation, steps, or final numbers intact.
            2. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            
            Format the output strictly as follows:
            [ANSWER]
            Label: <e.g. 'Question 1', 'Problem 2.3', or briefly summarize what the answer is about if no label exists>
            Content: <the full answer text, steps, or final answer code, with equations wrapped in dollar signs>
            [ANSWER]
            Label: <label or brief summary>
            Content: <answer text>
            
            Do NOT include any introduction, explanations, or conversational filler. Output only the structured list.
            """
            return await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 120.0)
        }
    }
    
    func parseExtractedAnswers(_ text: String) -> [ExtractedAnswer] {
        var answers: [ExtractedAnswer] = []
        let blocks = text.components(separatedBy: "[ANSWER]")
        
        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var labelText = ""
            var contentText = ""
            var isReadingContent = false
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                let lower = trimmed.lowercased()
                
                if lower.contains("label:") {
                    isReadingContent = false
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        labelText = val
                    }
                } else if lower.contains("content:") {
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
                answers.append(ExtractedAnswer(label: finalLabel, content: finalContent))
            }
        }
        return answers
    }
    
    func generateStepsFromAnswer(question: String, answer: String) async -> [String] {
        await withUserPriority {
            let model = await getOllamaModel()
            self.logToFile("[AI Helper LOG] generateStepsFromAnswer called for question: '\(question.prefix(60))...' with answer: '\(answer.prefix(60))...'")
            let prompt = """
            You are a physics teaching assistant. You are given a physics question and its solution/answer:
            
            Question:
            ---
            \(question)
            ---
            
            Solution/Answer:
            ---
            \(answer)
            ---
            
            Your task is to break down this solution/answer into a logical, sequential series of steps (a multi-step solution).
            Rules:
            1. Each step should represent one logical jump, calculation, or explanation.
            2. Keep the explanation and math clear.
            3. ALWAYS wrap all math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations.
            4. Format the output strictly as a list of steps, each step prefixed with "STEP:". For example:
               STEP: State the given variables and convert units.
               STEP: Apply the formula $$F = ma$$.
               STEP: Calculate the final force $F = 10\\text{ N}$.
            
            Do NOT include any introduction, conversational filler, or general notes. Output only the structured list of steps.
            """
            
            self.logToFile("[AI Helper LOG] Sending prompt to Ollama (\(model))...")
            guard let res = await callOllama(prompt: prompt, model: model) else {
                self.logToFile("[AI Helper LOG] callOllama returned nil in generateStepsFromAnswer")
                return []
            }
            self.logToFile("[AI Helper LOG] Received response from Ollama. Length: \(res.count)")
            let steps = self.parseStepsFromLLMResponse(res)
            self.logToFile("[AI Helper LOG] Returning \(steps.count) steps.")
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
        
        // 2. Check for numbered list pattern (e.g. "1.", "1)", "1:")
        let numberPattern = "^[\\*#_\\s]*\\d+[\\.\\):]"
        if let regex = try? NSRegularExpression(pattern: numberPattern, options: []) {
            let range = NSRange(location: 0, length: trimmed.utf16.count)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        
        // 3. Check for bullet points (e.g. "- ", "* ", "• ", "+ ") followed by some content
        let bulletPattern = "^[\\s]*[-*•+][\\s]+"
        if let regex = try? NSRegularExpression(pattern: bulletPattern, options: []) {
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
        var prefixLength = 0
        
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
            prefixLength = text.distance(from: text.startIndex, to: stepRange.upperBound) + charsToSkip
        }
        
        if prefixLength > 0 {
            text = String(text.dropFirst(prefixLength))
        } else {
            while !text.isEmpty {
                let first = text.first!
                if first.isNumber || first == " " || first == "." || first == ":" || first == "-" || first == "*" || first == "•" || first == "+" || first == ")" || first == "#" || first == "_" {
                    text.removeFirst()
                } else {
                    break
                }
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
                    steps.append(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                currentStepText = cleanStepText(trimmed)
                self.logToFile("[AI Helper LOG] Found new step header. Initial text: '\(currentStepText)'")
            } else {
                if !currentStepText.isEmpty {
                    currentStepText += "\n" + trimmed
                } else {
                    self.logToFile("[AI Helper LOG] Skipping intro/filler line before steps start: '\(trimmed)'")
                }
            }
        }
        
        if !currentStepText.isEmpty {
            steps.append(currentStepText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        if steps.isEmpty {
            self.logToFile("[AI Helper LOG] No steps detected. Falling back to paragraph split.")
            let paragraphs = res.components(separatedBy: "\n\n")
            for para in paragraphs {
                let trimmedPara = para.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPara.isEmpty {
                    steps.append(trimmedPara)
                }
            }
        }
        
        self.logToFile("[AI Helper LOG] Parsed \(steps.count) steps.")
        for (i, step) in steps.enumerated() {
            self.logToFile("[AI Helper LOG] Step \(i+1): '\(step)'")
        }
        
        return steps
    }
    
    func matchQuestionsAndAnswers(questions: [ExtractedProblem], answers: [ExtractedAnswer]) async -> [ExtractedProblem] {
        guard !answers.isEmpty else { return questions }
        
        let model = await getOllamaModel()
        
        var qList = ""
        for i in 0..<questions.count {
            qList += "Question ID \(i):\n\(questions[i].content)\n---\n"
        }
        
        var aList = ""
        for i in 0..<answers.count {
            // Include up to 2000 characters of each answer to keep all math content intact for matching
            let contentPreview = answers[i].content.prefix(2000).replacingOccurrences(of: "\n", with: " ")
            aList += "Answer ID \(i) [Label: \(answers[i].label)]: \(contentPreview)\n---\n"
        }
        
        let prompt = """
        You are a physics teaching assistant. You are given a list of extracted questions and a list of extracted answers/solutions.
        Your task is to match each question with its corresponding answer/solution based on mathematical content, question numbers, or contextual labels.
        
        Questions:
        ===
        \(qList)
        ===
        
        Answers:
        ===
        \(aList)
        ===
        
        For each match you find, output it in the following format:
        MATCH: Question ID X -> Answer ID Y
        
        Rules:
        1. You must find a match for every question from ID 0 to \(questions.count - 1). Every question has a corresponding answer in the list.
        2. A question can match at most one answer.
        3. An answer can match at most one question.
        4. Output ONLY the MATCH lines. Do NOT add introduction, conversational filler, or general notes.
        """
        
        guard let res = await callOllama(prompt: prompt, model: model) else { return questions }
        
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
                let qPart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let aPart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                
                let qNum = String(qPart.filter { $0.isNumber })
                let aNum = String(aPart.filter { $0.isNumber })
                
                if let qIdx = Int(qNum), let aIdx = Int(aNum) {
                    if qIdx >= 0 && qIdx < updatedQuestions.count && aIdx >= 0 && aIdx < answers.count {
                        matches.append((qIdx, aIdx))
                    }
                }
            }
        }
        
        if !matches.isEmpty {
            for (qIdx, aIdx) in matches {
                let questionContent = updatedQuestions[qIdx].content
                let ansContent = answers[aIdx].content
                
                self.logToFile("[AI Batch Importer LOG] Generating step-by-step solution for Question \(qIdx) sequentially...")
                let steps = await self.generateStepsFromAnswer(question: questionContent, answer: ansContent)
                let finalAnswerText: String
                if ansContent.lowercased().contains("final answer:") {
                    finalAnswerText = ansContent
                } else {
                    finalAnswerText = "Final Answer: \(ansContent)"
                }
                
                var finalSteps = steps
                if finalSteps.isEmpty {
                    finalSteps = [finalAnswerText]
                } else {
                    finalSteps.append(finalAnswerText)
                }
                
                updatedQuestions[qIdx].steps = finalSteps
                updatedQuestions[qIdx].solution = ""
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
    
    public func parseExtractedProblems(_ text: String) -> [ExtractedProblem] {
        var problems: [ExtractedProblem] = []
        let blocks = text.components(separatedBy: "[PROBLEM]")
        
        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var questionText = ""
            var hintText = ""
            var currentSection = ""
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                
                let lower = trimmed.lowercased()
                
                if lower.contains("question:") {
                    currentSection = "question"
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        questionText = val
                    }
                } else if lower.contains("hint:") {
                    currentSection = "hint"
                    if let colonRange = trimmed.range(of: ":") {
                        let val = trimmed[colonRange.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*_~ \t"))
                        hintText = val
                    }
                } else {
                    if currentSection == "question" {
                        if !questionText.isEmpty { questionText += "\n" }
                        questionText += line
                    } else if currentSection == "hint" {
                        if !hintText.isEmpty { hintText += "\n" }
                        hintText += line
                    }
                }
            }
            
            let q = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let h = hintText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                let combined: String
                if !h.isEmpty {
                    combined = q + "\n\nHint:\n" + h
                } else {
                    combined = q
                }
                problems.append(ExtractedProblem(content: combined, solutionHint: ""))
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
    
    private init() {}
    
    private func withUserPriority<T>(_ block: () async -> T) async -> T {
        await MainActor.run {
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
    
    // MARK: - API communication helpers
    
    func getOllamaModel(forceLocal: Bool = false) async -> String {
        // If using a cloud provider, return the configured cloud model name
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        if provider != "local" && provider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud"
            return cloudModel
        }
        if provider == "tailscale" {
            if let preferred = UserDefaults.standard.string(forKey: "tailscale_model_general"), !preferred.isEmpty {
                return preferred
            }
        } else {
            if let preferred = UserDefaults.standard.string(forKey: "local_model_general"), !preferred.isEmpty {
                return preferred
            }
        }
        let defaultModel = "qwen2.5-coder:7b"
        let host = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "tailscale_host") ?? "http://100.100.100.100:11434") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let baseURL = URL(string: cleanHost) else { return defaultModel }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            
            // 1. Try to find qwen2.5-coder:7b or general qwen2.5-coder
            for m in tags.models {
                if m.name.lowercased().contains("qwen2.5-coder:7b") {
                    return m.name
                }
            }
            for m in tags.models {
                if m.name.lowercased().contains("qwen2.5-coder") {
                    return m.name
                }
            }
            
            // 2. Try to find qwen2.5:7b or standard text qwen2.5 (excluding vision)
            for m in tags.models {
                if (m.name.lowercased().contains("qwen2.5:7b") || m.name.lowercased().contains("qwen2.5")) && !m.name.lowercased().contains("vl") {
                    return m.name
                }
            }
            
            // 3. Fallback to qwen2.5vl:7b
            for m in tags.models {
                if m.name.lowercased().contains("qwen2.5vl:7b") || m.name.lowercased().contains("qwen2.5-vl:7b") {
                    return m.name
                }
            }
            for m in tags.models {
                if m.name.lowercased().contains("qwen2.5vl") || m.name.lowercased().contains("qwen2.5-vl") {
                    return m.name
                }
            }
            
            if let first = tags.models.first {
                return first.name
            }
        } catch {
            print("[AI Helper] Warning: Could not connect to Ollama to list models (\(error)). Defaulting to \(defaultModel).")
        }
        return defaultModel
    }
    
    func getOllamaVisionModel(forceLocal: Bool = false) async -> String? {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "vision_provider") ?? "local")
        if provider == "tailscale" {
            if let preferred = UserDefaults.standard.string(forKey: "vision_tailscale_model"), !preferred.isEmpty {
                return preferred
            }
        } else {
            if let preferred = UserDefaults.standard.string(forKey: "local_model_vision"), !preferred.isEmpty {
                return preferred
            }
        }
        
        let defaultVisionModel = "qwen2.5vl:7b"
        let host = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "vision_tailscale_host") ?? "http://100.100.100.100:11434") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let baseURL = URL(string: cleanHost) else { return defaultVisionModel }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
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
    
    func callOllama(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval = 180.0, forceLocal: Bool = false) async -> String? {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        let maxRetries = 2
        
        let targetModel: String
        let effectiveProvider: String
        let effectiveImages: [String]?
        if provider == "local" || provider == "tailscale" {
            if provider == "local" {
                await ensureLocalOllamaRunning()
            }
            targetModel = model
            effectiveProvider = provider
            effectiveImages = images
        } else if images != nil {
            // Vision request — check vision_provider setting
            let visionProvider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "vision_provider") ?? "local")
            if visionProvider == "local" || visionProvider == "tailscale" {
                // Local or Tailscale Ollama vision model
                if visionProvider == "local" {
                    await ensureLocalOllamaRunning()
                }
                let visionModel = await getOllamaVisionModel(forceLocal: forceLocal) ?? model
                targetModel = visionModel
                effectiveProvider = visionProvider
                effectiveImages = images
                self.logToFile("[AI Helper LOG] Vision request using \(visionProvider) vision model: \(visionModel)")
            } else {
                // Cloud vision model — use vision-specific settings
                targetModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
                effectiveProvider = "cloud_vision"
                effectiveImages = images
                self.logToFile("[AI Helper LOG] Vision request using cloud vision model: \(targetModel)")
            }
        } else {
            targetModel = UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud"
            effectiveProvider = provider
            effectiveImages = images
        }
        
        for attempt in 1...maxRetries {
            self.logToFile("[AI Helper LOG] callOllama (\(effectiveProvider)) attempt \(attempt)/\(maxRetries) for model: \(targetModel)")
            if let result = await callAPIOnce(prompt: prompt, model: targetModel, images: effectiveImages, timeout: timeout, provider: effectiveProvider) {
                if hasRepetitiveGlitch(result) {
                    self.logToFile("[AI Helper LOG] Repetitive glitch detected (attempt \(attempt)/\(maxRetries)): '\(result.prefix(100))...'")
                    continue
                }
                return result
            } else {
                self.logToFile("[AI Helper LOG] callAPIOnce returned nil (attempt \(attempt)/\(maxRetries))")
            }
        }
        return nil
    }
    
    private func callAPIOnce(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval, provider: String) async -> String? {
        if provider == "local" || provider == "tailscale" {
            let host: String
            if provider == "tailscale" {
                if images != nil {
                    host = UserDefaults.standard.string(forKey: "vision_tailscale_host") ?? "http://100.100.100.100:11434"
                } else {
                    host = UserDefaults.standard.string(forKey: "tailscale_host") ?? "http://100.100.100.100:11434"
                }
            } else {
                host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let url = URL(string: "\(cleanHost)/api/generate") else { return nil }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            
            let body = GenerateRequest(model: model, prompt: prompt, stream: false, images: images)
            do {
                request.httpBody = try JSONEncoder().encode(body)
                let (data, _) = try await session.data(for: request)
                let responseObj = try JSONDecoder().decode(GenerateResponse.self, from: data)
                return responseObj.response.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with local Ollama: \(error)")
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
        let host = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "tailscale_host") ?? "http://100.100.100.100:11434") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let bURL = URL(string: cleanHost) else { return false }
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
    
    /// Unified extraction: tries text extraction first (fast, cloud model), falls back to vision model if the content is visual.
    /// For PDFs: extracts text → if text is meaningful, sends to text model. If text is empty/sparse, converts to images and sends to vision model.
    /// For images: if originalPdfPath is available, tries text from the PDF first. Otherwise sends directly to vision model.
    func extractProblemsUnified(item: ExtractionQueueItem) async -> [ExtractedProblem] {
        if item.type == .pdf {
            let pdfPath = item.pathOrName
            let isVisual = isVisualPDF(path: pdfPath)
            self.logToFile("[AI Batch Importer LOG] PDF '\(pdfPath)' — isVisual: \(isVisual)")
            
            if !isVisual {
                // Text-based PDF — extract text and use text model
                let pdfText = extractTextFromPDF(path: pdfPath, maxPages: 15)
                self.logToFile("[AI Batch Importer LOG] Extracted \(pdfText.count) characters from PDF: \(pdfPath)")
                if let rawText = await extractProblemsFromPDF(pdfText: pdfText) {
                    self.logToFile("[AI Batch Importer LOG] Text model response for problems:\n\(rawText)")
                    return parseExtractedProblems(rawText)
                }
            } else {
                // Visual PDF — convert to images and use vision model
                self.logToFile("[AI Batch Importer LOG] Visual PDF — converting to page images for vision model")
                let images = convertPDFToImages(path: pdfPath, maxPages: 15)
                var allProblems = [ExtractedProblem]()
                for (idx, base64) in images.enumerated() {
                    self.logToFile("[AI Batch Importer LOG] Vision extraction for page \(idx + 1) of \(pdfPath)")
                    if let rawText = await extractProblemsFromImage(base64Image: base64) {
                        if rawText != "MODEL_NOT_FOUND" {
                            self.logToFile("[AI Batch Importer LOG] Vision model response for page \(idx + 1):\n\(rawText)")
                            allProblems.append(contentsOf: parseExtractedProblems(rawText))
                        }
                    }
                }
                return allProblems
            }
        } else if item.type == .image, let base64 = item.imageBase64 {
            // For images with an original PDF, try text extraction first
            if let pdfPath = item.originalPdfPath, !isVisualPDF(path: pdfPath) {
                self.logToFile("[AI Batch Importer LOG] Image has text-extractable original PDF '\(pdfPath)' — using text model")
                let pdfText = extractTextFromPDF(path: pdfPath, maxPages: 15)
                if !pdfText.isEmpty {
                    if let rawText = await extractProblemsFromPDF(pdfText: pdfText) {
                        self.logToFile("[AI Batch Importer LOG] Text model response for problems from PDF:\n\(rawText)")
                        return parseExtractedProblems(rawText)
                    }
                }
            }
            // Fall through to vision model
            self.logToFile("[AI Batch Importer LOG] Using vision model for image: \(item.pathOrName)")
            if let rawText = await extractProblemsFromImage(base64Image: base64) {
                if rawText != "MODEL_NOT_FOUND" {
                    self.logToFile("[AI Batch Importer LOG] Vision model response:\n\(rawText)")
                    return parseExtractedProblems(rawText)
                }
            }
        }
        return []
    }
    
    /// Unified answer extraction: same logic as extractProblemsUnified but for answers.
    func extractAnswersUnified(item: ExtractionQueueItem) async -> [ExtractedAnswer] {
        if item.type == .pdf {
            let pdfPath = item.pathOrName
            let isVisual = isVisualPDF(path: pdfPath)
            self.logToFile("[AI Batch Importer LOG] PDF '\(pdfPath)' — isVisual: \(isVisual)")
            
            if !isVisual {
                let pdfText = extractTextFromPDF(path: pdfPath, maxPages: 15)
                self.logToFile("[AI Batch Importer LOG] Extracted \(pdfText.count) characters from PDF: \(pdfPath)")
                if let rawText = await extractAnswers(fromText: pdfText) {
                    self.logToFile("[AI Batch Importer LOG] Text model response for answers:\n\(rawText)")
                    return parseExtractedAnswers(rawText)
                }
            } else {
                self.logToFile("[AI Batch Importer LOG] Visual PDF — converting to page images for vision model")
                let images = convertPDFToImages(path: pdfPath, maxPages: 15)
                var allAnswers = [ExtractedAnswer]()
                for (idx, base64) in images.enumerated() {
                    self.logToFile("[AI Batch Importer LOG] Vision extraction for page \(idx + 1) of \(pdfPath)")
                    if let rawText = await extractAnswersFromImage(base64Image: base64) {
                        if rawText != "MODEL_NOT_FOUND" {
                            self.logToFile("[AI Batch Importer LOG] Vision model response for page \(idx + 1):\n\(rawText)")
                            allAnswers.append(contentsOf: parseExtractedAnswers(rawText))
                        }
                    }
                }
                return allAnswers
            }
        } else if item.type == .image, let base64 = item.imageBase64 {
            if let pdfPath = item.originalPdfPath, !isVisualPDF(path: pdfPath) {
                self.logToFile("[AI Batch Importer LOG] Image has text-extractable original PDF '\(pdfPath)' — using text model")
                let pdfText = extractTextFromPDF(path: pdfPath, maxPages: 15)
                if !pdfText.isEmpty {
                    if let rawText = await extractAnswers(fromText: pdfText) {
                        self.logToFile("[AI Batch Importer LOG] Text model response for answers from PDF:\n\(rawText)")
                        return parseExtractedAnswers(rawText)
                    }
                }
            }
            self.logToFile("[AI Batch Importer LOG] Using vision model for image: \(item.pathOrName)")
            if let rawText = await extractAnswersFromImage(base64Image: base64) {
                if rawText != "MODEL_NOT_FOUND" {
                    self.logToFile("[AI Batch Importer LOG] Vision model response:\n\(rawText)")
                    return parseExtractedAnswers(rawText)
                }
            }
        }
        return []
    }
    
    // MARK: - PDF Text Extraction
    
    /// Checks if a PDF has extractable text or is a scanned/visual PDF (image-only).
    /// Returns the extracted text, or empty string if it's a visual PDF.
    func extractTextFromPDF(path: String, maxPages: Int = 15) -> String {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            print("[AI Helper] Error opening PDF document at \(path) (could be permission denied or corrupted file).")
            return ""
        }
        
        var pdfText = ""
        let numPages = min(document.pageCount, maxPages)
        for i in 0..<numPages {
            if let page = document.page(at: i), let pageText = page.string {
                pdfText += pageText + "\n"
            }
        }
        return pdfText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    
    func processNoteSync(noteId: Int) async {
        print("[AI Helper] Beginning background analysis for Note ID: \(noteId)")
        
        guard let note = DatabaseManager.shared.getNote(id: noteId) else {
            print("[AI Helper] Note ID \(noteId) not found in database.")
            return
        }
        
        // Extract text
        let pdfText = extractTextFromPDF(path: note.filePath)
        if pdfText.isEmpty {
            // Check if the file physically exists on disk
            if !FileManager.default.fileExists(atPath: note.filePath) {
                print("[AI Helper] Note file physically missing at \(note.filePath). Blacklisting to avoid infinite loops.")
                self.failedNoteTimes[noteId] = Date()
                return
            }
            // If it exists but read failed (possibly waiting for macOS permission dialog), skip with a cooldown so we don't spin in a tight loop.
            print("[AI Helper] Note file exists but could not be read (possibly permission pending). Cooldown for 5 minutes.")
            self.failedNoteTimes[noteId] = Date()
            return
        }
        
        // Truncate to ~4000 characters to avoid model context bloat
        var truncatedText = pdfText
        if pdfText.count > 4000 {
            truncatedText = String(pdfText.prefix(4000))
        }
        
        let model = await getOllamaModel()
        
        // Generate summary
        let summaryPrompt = """
        You are a helpful physics academic assistant. Summarize the following physics lecture notes. \
        Start directly with the overview paragraph. Do NOT include any introductory or concluding conversational filler (e.g., 'Here is the summary:', 'Sure!', or 'Let me know if you need more help'). \
        Your output MUST follow this exact structure:

        [Overview Paragraph]
        A single short paragraph (2-3 sentences) summarizing the core topic of the lecture, the fundamental physical concepts introduced, and how it connects to the broader subject.

        [Key Concepts & Equations]
        A list of 3-5 bullet points using the dash '-' symbol, listing key concepts and equations using the format '- [Concept Name]: [Formula/Details]'.

        Here is an example of the exact format required:
        This lecture introduces the principles of electrostatics, focusing on Coulomb's law and the concept of electric field strength. It explains how charge distributions produce force fields in space and defines the mathematical foundation for calculating electric field vectors. This forms the basis for understanding more advanced electromagnetic phenomena.

        - Coulomb's Law: F = k * (q1 * q2) / r^2
        - Electric Field Strength: E = F / q
        - Superposition Principle for multiple charges
        - Electric Field Lines and their properties

        Now, summarize the following lecture notes using the exact format shown above:

        Lecture notes:
        \(truncatedText)
        """
        let summaryRes = await callOllama(prompt: summaryPrompt, model: model)
        if let res = summaryRes {
            var cleanedSummary = res
            var lines = res.components(separatedBy: .newlines)
            if let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                let introPrefixes = ["here is", "here's", "sure", "based on", "the following", "this is", "the summary"]
                if firstLine.hasSuffix(":") && introPrefixes.contains(where: { firstLine.hasPrefix($0) }) {
                    lines.removeFirst()
                    cleanedSummary = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            _ = DatabaseManager.shared.updateNoteAI(noteId: noteId, summary: cleanedSummary, primer: nil)
            print("[AI Helper] Completed analysis for Note ID: \(noteId)")
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
        guard var result = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        
        if result.hasPrefix("```") {
            let lines = result.components(separatedBy: .newlines)
            if lines.count >= 3 && lines.first?.hasPrefix("```") == true && lines.last?.hasPrefix("```") == true {
                result = lines[1..<(lines.count - 1)].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        if result.hasPrefix("$$") && result.hasSuffix("$$") {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("$") && result.hasSuffix("$") {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("\\[") && result.hasSuffix("\\]") {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.hasPrefix("\\(") && result.hasSuffix("\\)") {
            result = String(result.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return result
    }
    
    func translateToLaTeX(rawEquation: String) async -> String? {
        await withUserPriority {
            let useLocal = latexAlwaysLocal
            let model = await getOllamaModel(forceLocal: useLocal)
            let prompt = """
            You are a mathematical LaTeX translator. Translate the following plain-text equation description or expression into clean, valid raw LaTeX code.
            Do NOT include any delimiters (do NOT wrap in $ or $$ or \\[ or \\]). Do NOT include any conversational filler, explanation, or notes. Return only the raw LaTeX code itself.

            Example input: integral from a to b of x squared dx
            Example output: \\int_{a}^{b} x^2 \\, dx

            Example input: schrodinger equation
            Example output: i\\hbar\\frac{\\partial}{\\partial t}\\text{\\Psi}(\\mathbf{r},t) = \\hat{H}\\text{\\Psi}(\\mathbf{r},t)

            Now, translate this equation:
            \(rawEquation)
            """
            
            let res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
            return cleanLaTeXOutput(res)
        }
    }
    
    func translateImageToLaTeX(base64Image: String) async -> String? {
        await withUserPriority {
            let useLocal = latexAlwaysLocal
            guard let visionModel = await getOllamaVisionModel(forceLocal: useLocal) else {
                return "MODEL_NOT_FOUND"
            }
            
            let prompt = """
            Transcribe the mathematical equation or expression in this image into valid LaTeX format. \
            Do NOT wrap the equation in any delimiters like $ or $$ or \\[ or \\]. \
            Return ONLY the raw LaTeX code itself. Do NOT include any conversational text, explanations, intro, or outro.
            """
            
            let res = await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 90.0, forceLocal: useLocal)
            return cleanLaTeXOutput(res)
        }
    }
    
    func extractProblemsFromPDF(pdfText: String) async -> String? {
        await withUserPriority {
            let model = await getOllamaModel()
            let prompt = """
            You are a physics teaching assistant. Analyze the following text extracted from a physics document/homework:
            ---
            \(pdfText)
            ---
            Extract and identify ALL individual practice questions or problems from the text.
            For each problem, transcribe or formulate a clear question that specifies exactly what the user needs to solve, calculate, or prove.
            
            CRITICAL REQUIREMENT:
            Only extract problems that are ACTUALLY present and visible in the provided text. Do NOT make up, extrapolate, or hallucinate additional problems. If the text has only one question, output exactly one [PROBLEM] block. If the text has zero problems, output nothing. Do not repeat the same question.
            
            Strict Formatting Rules for the 'Question' field:
            1. Phrase the question as a direct instruction or question so the user knows exactly what they are expected to do.
            2. Spread the question across multiple lines. Try and use more lines for readability; do NOT clump everything into a single dense paragraph of text. Use paragraph breaks and line breaks to segment information.
            3. Big equations, mathematical derivations, or non-trivial formulas MUST be placed on their own separate lines to stand out clearly.
            4. ALWAYS wrap all math equations, math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations. Never leave LaTeX raw or naked without delimiters.
            5. Do NOT include any exam mark totals, question points, score designations, or grade weight indicators (e.g. do NOT write '[5 marks]', '(10 marks)', '[Total: 4 points]', etc.). Strip all such mark references completely from the question content.
            
            Then, provide a concise but helpful solution hint for the problem. If the problem is extremely basic or trivial, you may omit the hint (leave the Hint field empty). Otherwise, always generate a hint to guide the student. ALWAYS wrap all LaTeX math in standard dollar sign delimiters inside the hint as well.

            Format the output strictly as follows:
            [PROBLEM]
            Question: <clear question/instruction text, spread across multiple lines, with equations on separate lines>
            Hint: <concise solution hint with LaTeX wrapped in delimiters, or leave blank if not needed>
            [PROBLEM]
            Question: <clear question/instruction text, spread across multiple lines, with equations on separate lines>
            Hint: <concise solution hint with LaTeX wrapped in delimiters, or leave blank if not needed>

            Do NOT include any introduction, explanations, or conversational filler. Output only the structured list.
            Do NOT wrap the 'Question:' or 'Hint:' labels in any markdown formatting like bold asterisks (e.g. do NOT write '**Question:**' or '- Question:'). Simply start the line with 'Question:' or 'Hint:'.
            """
            
            return await callOllama(prompt: prompt, model: model)
        }
    }
    
    func extractProblemsFromImage(base64Image: String) async -> String? {
        await withUserPriority {
            guard let visionModel = await getOllamaVisionModel() else {
                return "MODEL_NOT_FOUND"
            }
            let prompt = """
            You are a physics teaching assistant. Analyze this image containing physics practice questions or problems.
            Transcribe and extract ALL individual practice problems from the image.
            For each problem, transcribe or formulate a clear question that specifies exactly what the user needs to solve, calculate, or prove.
            
            CRITICAL REQUIREMENT:
            Only extract problems that are ACTUALLY present and visible in the provided image. Do NOT make up, extrapolate, or hallucinate additional problems. If the image has only one question, output exactly one [PROBLEM] block. If the image has zero problems, output nothing. Do not repeat the same question.
            
            Strict Formatting Rules for the 'Question' field:
            1. Phrase the question as a direct instruction or question so the user knows exactly what they are expected to do.
            2. Spread the question across multiple lines. Try and use more lines for readability; do NOT clump everything into a single dense paragraph of text. Use paragraph breaks and line breaks to segment information.
            3. Big equations, mathematical derivations, or non-trivial formulas MUST be placed on their own separate lines to stand out clearly.
            4. ALWAYS wrap all math equations, math formulas, variables, and math symbols in standard single dollar signs (e.g. $x_i$, $\theta$) for inline math, and double dollar signs (e.g. $$E = mc^2$$) on separate lines for block equations. Never leave LaTeX raw or naked without delimiters.
            5. Do NOT include any exam mark totals, question points, score designations, or grade weight indicators (e.g. do NOT write '[5 marks]', '(10 marks)', '[Total: 4 points]', etc.). Strip all such mark references completely from the question content.
            
            Then, provide a concise but helpful solution hint for the problem. If the problem is extremely basic or trivial, you may omit the hint (leave the Hint field empty). Otherwise, always generate a hint to guide the student. ALWAYS wrap all LaTeX math in standard dollar sign delimiters inside the hint as well.

            Format the output strictly as follows:
            [PROBLEM]
            Question: <clear question/instruction text, spread across multiple lines, with equations on separate lines>
            Hint: <concise solution hint with LaTeX wrapped in delimiters, or leave blank if not needed>
            [PROBLEM]
            Question: <clear question/instruction text, spread across multiple lines, with equations on separate lines>
            Hint: <concise solution hint with LaTeX wrapped in delimiters, or leave blank if not needed>

            Do NOT include any introduction, explanations, or conversational filler. Output only the structured list.
            Do NOT wrap the 'Question:' or 'Hint:' labels in any markdown formatting like bold asterisks (e.g. do NOT write '**Question:**' or '- Question:'). Simply start the line with 'Question:' or 'Hint:'.
            """
            
            return await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 120.0)
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
            let model = await getOllamaModel()
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
            
            if let res = await callOllama(prompt: prompt, model: model) {
                let cleaned = res.trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = cleaned.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                return Int(digits)
            }
            return nil
        }
    }
    
    // MARK: - Pre-Lecture Primer
    
    func generatePreLecturePrimer(currentNoteId: Int, prevNoteId: Int? = nil) async -> String? {
        if let cached = DatabaseManager.shared.getNote(id: currentNoteId)?.preLecturePrimer, !cached.isEmpty {
            return cached
        }
        
        await ensureNoteSummarized(noteId: currentNoteId)
        
        guard let currNote = DatabaseManager.shared.getNote(id: currentNoteId) else { return nil }
        
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
        let finalPrimer = primerRes ?? "Unable to generate pre-lecture primer. Please verify Ollama is running and has the model qwen2.5vl:7b installed."
        _ = DatabaseManager.shared.updateNoteAI(noteId: currentNoteId, summary: currNote.aiSummary, primer: finalPrimer)
        return finalPrimer
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
            return await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
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
            Do NOT use sparkles emoji ('✨') anywhere in your response.

            Conversation History:
            \(historyStr)
            Student:
            """
            
            let res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
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
            Keep your question brief and sound like a student speaking (1-2 sentences). Do NOT use sparkles emoji ('✨').

            Student Question:
            """
            
            let res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal)
            return res ?? "Can you explain the main physical concepts and principles covered in the '\(noteTitle)' lecture?"
        }
    }
    
    // MARK: - Background Processor
    
    func isOllamaRunning() async -> Bool {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        if provider == "local" || provider == "tailscale" {
            let host: String
            if provider == "tailscale" {
                host = UserDefaults.standard.string(forKey: "tailscale_host") ?? "http://100.100.100.100:11434"
            } else {
                host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let bURL = URL(string: cleanHost) else { return false }
            let url = bURL.appendingPathComponent("api/tags")
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.0
            do {
                _ = try await session.data(for: request)
                return true
            } catch {
                return false
            }
        } else {
            // For cloud/hermes providers, check the cloud API base URL
            let baseUrl = UserDefaults.standard.string(forKey: "cloud_api_base_url") ?? ""
            let cleanBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let url = URL(string: "\(cleanBase)/models") else { return false }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3.0
            let apiKey = UserDefaults.standard.string(forKey: "cloud_api_key") ?? ""
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            do {
                _ = try await session.data(for: request)
                return true
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
                    // Check if any user request is active. If so, wait.
                    let isUserBusy = await MainActor.run { self.activeUserRequestsCount > 0 }
                    if isUserBusy {
                        try await Task.sleep(nanoseconds: 1_000_000_000) // Sleep 1s and check again
                        continue
                    }
                    
                    let online = await self.isOllamaRunning()
                    
                    // Recheck user request count after checking Ollama state
                    let isUserBusyAfterCheck = await MainActor.run { self.activeUserRequestsCount > 0 }
                    if isUserBusyAfterCheck {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    
                    if online, let job = await self.getNextPendingJob() {
                        // Prevent system sleep while jobs are processing
                        if self.awakeActivityToken == nil {
                            self.awakeActivityToken = ProcessInfo.processInfo.beginActivity(
                                options: [.background, .idleSystemSleepDisabled],
                                reason: "Processing AI summaries and primers overnight"
                            )
                            print("[AI Helper] System sleep disabled while processing queue.")
                        }
                        
                        self.isProcessing = true
                        self.activeJobDescription = job.description
                        
                        // Run background job as a cancellable Task
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
                        try await Task.sleep(nanoseconds: 3_000_000_000) // Sleep 3s cooldown
                    } else {
                        // Re-enable system sleep when idle
                        if let token = self.awakeActivityToken {
                            ProcessInfo.processInfo.endActivity(token)
                            self.awakeActivityToken = nil
                            print("[AI Helper] System sleep re-enabled (queue idle).")
                        }
                        
                        self.activeJobDescription = online ? "Idle" : "Waiting for Ollama..."
                        try await Task.sleep(nanoseconds: online ? 5_000_000_000 : 1_000_000_000)
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
        // Fetch all notes
        let allModules = DatabaseManager.shared.getModules()
        
        for module in allModules {
            let notes = DatabaseManager.shared.getNotes(forModuleId: module.id)
            for (idx, note) in notes.enumerated() {
                // Skip processing if note file path is empty
                guard !note.filePath.isEmpty else {
                    continue
                }
                
                // If summary is missing or has error text
                if (note.aiSummary == nil || note.aiSummary?.isEmpty == true || note.aiSummary?.contains("Unable to generate summary") == true) && !self.isNoteFailed(noteId: note.id) {
                    return PendingJob(description: "Summary (Note ID \(note.id))") {
                        await self.processNoteSync(noteId: note.id)
                    }
                }
                
                // If pre-lecture primer is missing or has error text
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
            let model = await getOllamaModel()
            let prompt = """
            You are an expert physics solver. Solve the following practice problem step-by-step:
            ---
            \(content)
            ---
            Provide a clean, precise, and accurate solution. Use LaTeX formatting for all mathematical equations.
            ALWAYS wrap all inline math variables, formulas, and math symbols in single dollar signs (e.g. $x_i$, $\theta$), and all block equations in double dollar signs (e.g. $$E = mc^2$$) on their own lines. Never output naked equations or symbols without delimiters.
            Output ONLY the final solution and explanation. Do not include conversational introduction or general filler.
            """
            return await callOllama(prompt: prompt, model: model) ?? ""
        }
    }
    
    func generateProblemSteps(content: String, solution: String) async -> [String] {
        await withUserPriority {
            let model = await getOllamaModel()
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
            guard let res = await callOllama(prompt: prompt, model: model) else {
                self.logToFile("[AI Helper LOG] callOllama returned nil in generateProblemSteps")
                return []
            }
            self.logToFile("[AI Helper LOG] Received response from Ollama. Length: \(res.count)")
            let steps = self.parseStepsFromLLMResponse(res)
            self.logToFile("[AI Helper LOG] Returning \(steps.count) steps.")
            return steps
        }
    }
}
