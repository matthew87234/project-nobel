import Foundation
import PDFKit
import CryptoKit

extension AIHelper {
    func queueProblemForClassification(content: String, solutionHint: String, moduleId: Int, solution: String = "", steps: [String] = []) {
        let item = QueueItem(content: content, solutionHint: solutionHint, moduleId: moduleId, solution: solution, steps: steps)
        
        let classProv = self.taskProvider(for: "route_classification", defaultProvider: "tailscale")
        let info = self.providerInfo(for: classProv)
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
    
    func processNextQueueItem() {
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
    
    func extractSheetNumber(_ filename: String) -> Int? {
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
        let extractProv = self.taskProvider(for: "route_vision", isVision: hasImages, defaultProvider: "local")
        let info = self.providerInfo(for: extractProv, isVision: hasImages)
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
    
    func processNextExtractionQueueItem() {
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
        let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
        let aiProv = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let visProv = UserDefaults.standard.string(forKey: "vision_provider") ?? aiProv
        let globalActive = isVision ? visProv : aiProv
        
        if preset == "local_only" || (aiProv == "local" && (!isVision || visProv == "local")) {
            return "local"
        }
        
        if preset == "hybrid_twotier" {
            if key == "route_translation" || key == "route_vision" || key == "route_feynman" || isVision {
                return "local"
            }
        }
        
        let isCloud = preset == "cloud_frontier" && ["openai", "anthropic", "gemini", "groq", "hermes", "cloud"].contains(globalActive)

        if let val = UserDefaults.standard.string(forKey: key), !val.isEmpty {
            if val == "cloud" {
                if isCloud {
                    return globalActive
                }
                return defaultProvider ?? (aiProv == "local" ? "local" : "tailscale")
            }
            if isCloud && val == "tailscale" {
                return globalActive
            }
            if !isCloud && ["openai", "anthropic", "gemini", "groq", "hermes", "cloud"].contains(val) {
                return defaultProvider ?? (aiProv == "local" ? "local" : "tailscale")
            }
            return val
        }
        
        if let def = defaultProvider {
            if def == "tailscale" && isCloud {
                return globalActive
            }
            return def
        }
        return isCloud ? globalActive : (aiProv == "local" ? "local" : "tailscale")
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

    // MARK: - Unified Extraction & Transcription Disk Cache
    
    var transcriptionCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ProjectNobel/transcription_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    func transcriptionCacheKey(for path: String, isAnswer: Bool) -> String {
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
    
    func isProblemContinuation(prevContent: String, nextContent: String) -> (Bool, String) {
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
    
    func mergeFragmentContents(c1: String, c2: String) -> String {
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
}
