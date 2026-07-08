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

@MainActor class AIHelper: ObservableObject {
    static let shared = AIHelper()
    
    private let session = URLSession.shared
    private let baseURL = URL(string: "http://localhost:11434")!
    
    // Track processing thread states
    @Published var activeJobDescription: String = "Idle"
    @Published var isProcessing: Bool = false
    
    private init() {}
    
    // MARK: - API communication helpers
    
    func getOllamaModel() async -> String {
        let defaultModel = "qwen2.5vl:7b"
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            
            // 1. Try to find qwen2.5vl:7b
            for m in tags.models {
                if m.name.lowercased().contains("qwen2.5vl:7b") || m.name.lowercased().contains("qwen2.5-vl:7b") {
                    return m.name
                }
            }
            
            // 2. Try to find any other qwen2.5vl
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
    
    func getOllamaVisionModel() async -> String? {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let keywords = ["qwen", "vision", "llava", "minicpm", "moondream"]
            for kw in keywords {
                for m in tags.models {
                    if m.name.lowercased().contains(kw) {
                        return m.name
                    }
                }
            }
        } catch {
            print("[AI Helper] Warning: Error checking for vision model: \(error)")
        }
        return nil
    }
    
    func callOllama(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval = 60.0) async -> String? {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        
        let body = GenerateRequest(model: model, prompt: prompt, stream: false, images: images)
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
            
            let (data, _) = try await session.data(for: request)
            let responseObj = try JSONDecoder().decode(GenerateResponse.self, from: data)
            return responseObj.response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[AI Helper] Error communicating with local Ollama: \(error)")
            return nil
        }
    }
    
    func pullOllamaModel(modelName: String) async -> Bool {
        let url = baseURL.appendingPathComponent("api/pull")
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
    
    // MARK: - PDF Text Extraction
    
    func extractTextFromPDF(path: String, maxPages: Int = 3) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            print("[AI Helper] PDF path does not exist: \(path)")
            return ""
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            print("[AI Helper] Error opening PDF document at \(path)")
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
    
    // MARK: - Summarization & Difficulty rating
    
    func processNoteSync(noteId: Int) async {
        print("[AI Helper] Beginning background analysis for Note ID: \(noteId)")
        
        guard let note = DatabaseManager.shared.getNote(id: noteId) else {
            print("[AI Helper] Note ID \(noteId) not found in database.")
            return
        }
        
        // Fetch module details
        let modules = DatabaseManager.shared.getModules()
        var moduleCode = ""
        var moduleName = ""
        var moduleId = 0
        
        // Find which module this note belongs to by matching note's topic_id
        let notesRows = DatabaseManager.shared.query(sql: """
            SELECT t.module_id, t.name as topic_name
            FROM topics t
            WHERE t.id = ?
        """, params: [note.topicId])
        
        if let row = notesRows.first {
            moduleId = row["module_id"] as? Int ?? 0
            if let m = modules.first(where: { $0.id == moduleId }) {
                moduleCode = m.code
                moduleName = m.name
            }
        }
        
        // Fetch other topics in the module
        let otherTopicsRows = DatabaseManager.shared.query(sql: """
            SELECT name FROM topics WHERE module_id = ? AND id != ?
        """, params: [moduleId, note.topicId])
        let otherTopics = otherTopicsRows.compactMap { $0["name"] as? String }
        
        // Extract text
        var pdfText = extractTextFromPDF(path: note.filePath)
        if pdfText.isEmpty {
            pdfText = "Physics lecture note titled: \(note.title)"
        } else {
            // Truncate to ~4000 characters to avoid model context bloat
            if pdfText.count > 4000 {
                pdfText = String(pdfText.prefix(4000))
            }
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
        \(pdfText)
        """
        
        let summaryRes = await callOllama(prompt: summaryPrompt, model: model)
        var cleanedSummary = summaryRes ?? "Unable to generate summary. Please check if Ollama is running and has the model qwen2.5vl:7b installed."
        if let res = summaryRes {
            var lines = res.components(separatedBy: .newlines)
            if let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                let introPrefixes = ["here is", "here's", "sure", "based on", "the following", "this is", "the summary"]
                if firstLine.hasSuffix(":") && introPrefixes.contains(where: { firstLine.hasPrefix($0) }) {
                    lines.removeFirst()
                    cleanedSummary = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        // Generate difficulty rating
        let topicsList = otherTopics.isEmpty ? "None uploaded yet" : otherTopics.joined(separator: ", ")
        let difficultyPrompt = """
        You are a physics professor. Analyze the following physics lecture notes and determine its difficulty compared to typical university physics module materials.
        The course module is: \(moduleCode) - \(moduleName)
        Other topics covered in this module: \(topicsList)
        
        Based on the content of the lecture notes below, classify the difficulty of this topic as: Easy, Medium, or Hard.
        Also provide a 1-sentence explanation of why it is rated this way, specifically comparing its conceptual or mathematical complexity to other topics in this module.
        
        Your response MUST follow this exact format:
        Difficulty: [Easy/Medium/Hard] - [1-sentence explanation]
        
        Do NOT include any conversational filler. Start your response directly with 'Difficulty:'.
        
        Lecture notes text:
        \(pdfText)
        """
        
        let diffRes = await callOllama(prompt: difficultyPrompt, model: model)
        var cleanedDifficulty = diffRes ?? "Medium - Default rating due to local model response error."
        if let res = diffRes {
            if res.lowercased().hasPrefix("difficulty:") {
                let temp = String(res.dropFirst("difficulty:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if temp.hasPrefix("-") || temp.hasPrefix(":") {
                    cleanedDifficulty = String(temp.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    cleanedDifficulty = temp
                }
            }
        }
        
        _ = DatabaseManager.shared.updateNoteAI(noteId: noteId, summary: cleanedSummary, difficulty: cleanedDifficulty, primer: nil)
        print("[AI Helper] Completed analysis for Note ID: \(noteId)")
    }
    
    func ensureNoteSummarized(noteId: Int) async {
        guard let note = DatabaseManager.shared.getNote(id: noteId) else { return }
        if note.aiSummary == nil || note.aiSummary?.isEmpty == true {
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
        let model = await getOllamaModel()
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
        
        let res = await callOllama(prompt: prompt, model: model)
        return cleanLaTeXOutput(res)
    }
    
    func translateImageToLaTeX(base64Image: String) async -> String? {
        guard let visionModel = await getOllamaVisionModel() else {
            return "MODEL_NOT_FOUND"
        }
        
        let prompt = """
        Transcribe the mathematical equation or expression in this image into valid LaTeX format. \
        Do NOT wrap the equation in any delimiters like $ or $$ or \\[ or \\]. \
        Return ONLY the raw LaTeX code itself. Do NOT include any conversational text, explanations, intro, or outro.
        """
        
        let res = await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 90.0)
        return cleanLaTeXOutput(res)
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
        _ = DatabaseManager.shared.updateNoteAI(noteId: currentNoteId, summary: currNote.aiSummary, difficulty: currNote.difficulty, primer: finalPrimer)
        return finalPrimer
    }
    
    // MARK: - Feynman sandbox & dialogues
    
    func evaluateFeynmanSummary(explanation: String, noteTitle: String, aiSummary: String) async -> String? {
        let model = await getOllamaModel()
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
        return await callOllama(prompt: prompt, model: model)
    }
    
    func getFeynmanDialogueResponse(noteTitle: String, aiSummary: String, chatHistory: [FeynmanChat]) async -> String? {
        let model = await getOllamaModel()
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
        return await callOllama(prompt: prompt, model: model)
    }
    
    func generateFeynmanStartingQuestion(noteTitle: String, aiSummary: String) async -> String? {
        let model = await getOllamaModel()
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
        return await callOllama(prompt: prompt, model: model)
    }
    
    // MARK: - Background Processor
    
    func isOllamaRunning() async -> Bool {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        do {
            _ = try await session.data(for: request)
            return true
        } catch {
            return false
        }
    }
    
    func startBackgroundProcessor() {
        Task {
            print("[AI Helper] Background processor manager started.")
            while true {
                do {
                    let online = await self.isOllamaRunning()
                    if online, let job = await self.getNextPendingJob() {
                        self.isProcessing = true
                        self.activeJobDescription = job.description
                        await job.task()
                        self.isProcessing = false
                        self.activeJobDescription = "Idle"
                        try await Task.sleep(nanoseconds: 3_000_000_000) // Sleep 3s cooldown
                    } else {
                        self.activeJobDescription = online ? "Idle" : "Waiting for Ollama..."
                        try await Task.sleep(nanoseconds: 5_000_000_000) // Sleep 5s
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
                // Skip processing if note file is missing or invalid to avoid infinite loops
                guard !note.filePath.isEmpty, FileManager.default.fileExists(atPath: note.filePath) else {
                    continue
                }
                
                // If summary/difficulty is missing
                if note.aiSummary == nil || note.aiSummary?.isEmpty == true || note.difficulty == nil || note.difficulty?.isEmpty == true {
                    return PendingJob(description: "Summary (Note ID \(note.id))") {
                        await self.processNoteSync(noteId: note.id)
                    }
                }
                
                // If pre-lecture primer is missing
                if note.preLecturePrimer == nil || note.preLecturePrimer?.isEmpty == true {
                    let prevNoteId = idx > 0 ? notes[idx - 1].id : nil
                    return PendingJob(description: "Primer (Note ID \(note.id))") {
                        _ = await self.generatePreLecturePrimer(currentNoteId: note.id, prevNoteId: prevNoteId)
                    }
                }
            }
        }
        return nil
    }
}
