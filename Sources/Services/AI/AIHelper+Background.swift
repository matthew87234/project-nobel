import Foundation
import PDFKit

extension AIHelper {
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
            let apiKey = KeychainHelper.get(account: "cloud_api_key")
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
    

    /// Ensures local Ollama is running safely without blocking MainActor or spawning duplicate processes.
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
        
        let alreadyActive = await Task.detached(priority: .utility) { () -> Bool in
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-x", "ollama"]
            pgrep.standardOutput = FileHandle.nullDevice
            pgrep.standardError = FileHandle.nullDevice
            guard (try? pgrep.run()) != nil else { return false }
            pgrep.waitUntilExit()
            return pgrep.terminationStatus == 0
        }.value
        
        if alreadyActive {
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
        
        let fm = FileManager.default
        let launchSpec: (executable: String, arguments: [String])? = {
            if fm.fileExists(atPath: "/Applications/Ollama.app") {
                return ("/usr/bin/open", ["-a", "Ollama", "--background"])
            } else if fm.fileExists(atPath: "/usr/local/bin/ollama") {
                return ("/usr/local/bin/ollama", ["serve"])
            } else if fm.fileExists(atPath: "/opt/homebrew/bin/ollama") {
                return ("/opt/homebrew/bin/ollama", ["serve"])
            }
            return nil
        }()
        
        guard let spec = launchSpec else {
            self.logToFile("[AI Helper LOG] Ollama binary not installed in standard paths.")
            return
        }
        
        self.logToFile("[AI Helper LOG] Launching Ollama application...")
        let launchError: Error? = await Task.detached(priority: .utility) {
            let openTask = Process()
            openTask.executableURL = URL(fileURLWithPath: spec.executable)
            openTask.arguments = spec.arguments
            openTask.standardOutput = FileHandle.nullDevice
            openTask.standardError = FileHandle.nullDevice
            do {
                try openTask.run()
                return nil
            } catch {
                return error
            }
        }.value
        
        if let launchError {
            self.logToFile("[AI Helper LOG] Failed to launch Ollama: \(launchError.localizedDescription)")
            return
        }
        
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
    }
    
    func startBackgroundProcessor() {
        guard !isBackgroundProcessorStarted else { return }
        isBackgroundProcessorStarted = true
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
                        // If remote provider is disconnected and all 3 auto-retries are exhausted, wait for manual Retry
                        if !isLocalProvider && self.autoReconnectExhausted {
                            await MainActor.run {
                                self.isProcessing = false
                                self.activeJobDescription = "AI Server Offline"
                            }
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            continue
                        }
                        
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
                                    self.autoReconnectAttempts = 0
                                    self.autoReconnectExhausted = false
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
                                self.isAIDisconnected = true
                                self.disconnectionMessage = isLocalProvider ? "Local Ollama Offline" : "\(self.remoteEngineName) Disconnected"
                                self.isProcessing = false
                                self.isAIBusy = false
                                self.activeJobDescription = "AI Server Offline"
                            }
                            if !isLocalProvider && !self.autoReconnectExhausted {
                                _ = await self.attemptAutoReconnect(manualRetry: false)
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
    
    func getNextPendingJob() async -> PendingJob? {
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
            let provider = isLocalOnlyMode ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
            startAITask(description: "Curating Phase 1 Cards for \(moduleCode)...", forceLocal: provider == "local", provider: provider)
            defer {
                finishAITask(force: true)
            }
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
                return
            }
            
            let model = await getOllamaModel(forProvider: provider, forceLocal: provider == "local")
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
            if let response = await callOllama(prompt: prompt, model: model, forceLocal: provider == "local", overrideProvider: provider) {
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
            self.logToFile("[AI Helper LOG] Pre-exam card curation completed for module \(moduleCode). Saved \(selectedIds.count) card IDs to persistent UserDefaults.")
        }
    }
}
