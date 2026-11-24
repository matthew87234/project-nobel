import Foundation
import PDFKit
import AppKit

extension AIHelper {
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
    
    func cleanFilenameTitle(_ raw: String) -> String {
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
            _ = DatabaseManager.shared.updateNoteSummary(noteId: noteId, summary: cleanedSummary)
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
        let routeProvider = taskProvider(for: "route_translation", defaultProvider: "local")
        let useLocal = (routeProvider == "local")
        let effectiveProv = useLocal ? "local" : routeProvider
        startAITask(description: "Translating LaTeX Equation...", forceLocal: useLocal, provider: effectiveProv)
        defer {
            finishAITask(force: true)
        }
        return await withUserPriority {
            let model = await getOllamaModel(forProvider: effectiveProv, forceLocal: useLocal)
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
            var res = await callOllama(prompt: prompt, model: model, forceLocal: useLocal, overrideProvider: effectiveProv, options: fastOptions, overrideThink: false)
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
        let routeProvider = taskProvider(for: "route_translation", isVision: true, defaultProvider: "local")
        let useLocal = (routeProvider == "local")
        let effectiveProv = useLocal ? "local" : routeProvider
        startAITask(description: "Transcribing Equation Image...", isVision: true, forceLocal: useLocal, provider: effectiveProv)
        defer {
            finishAITask(force: true)
        }
        return await withUserPriority {
            let prompt = """
            Transcribe the mathematical equation or expression in this image into valid LaTeX format. \
            Do NOT wrap the equation in any delimiters like $ or $$ or \\[ or \\]. \
            Do NOT include <think> tags or conversational filler. Return ONLY the raw LaTeX code itself.
            """
            let fastOptions = OllamaOptions(temperature: 0.0, num_predict: 1024, top_p: 0.9)
            
            // 1. Initial attempt with preferred provider
            var res: String? = nil
            if let visionModel = await getOllamaVisionModel(forceLocal: useLocal) {
                res = await callOllama(prompt: prompt, model: visionModel, images: [base64Image], timeout: 120.0, forceLocal: useLocal, overrideProvider: effectiveProv, options: fastOptions, overrideThink: false)
            }
            
            // 2. Bidirectional fallback (Local <-> Tailscale)
            if res == nil {
                let fallbackUseLocal = !useLocal
                self.logToFile("[AI Helper LOG] LaTeX image transcription failed on preferred provider, trying fallback (forceLocal: \(fallbackUseLocal))...")
                if let fallbackVisionModel = await getOllamaVisionModel(forceLocal: fallbackUseLocal) {
                    res = await callOllama(prompt: prompt, model: fallbackVisionModel, images: [base64Image], timeout: 120.0, forceLocal: fallbackUseLocal, options: fastOptions, overrideThink: false)
                }
            }
            
            // 3. Fallback to Cloud Vision only if explicitly in cloud mode
            let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
            if res == nil && preset == "cloud_frontier" {
                let visionProvider = UserDefaults.standard.string(forKey: "vision_provider") ?? "local"
                let cloudKey = KeychainHelper.get(account: "vision_api_key")
                if (visionProvider != "local" && visionProvider != "tailscale") && !cloudKey.isEmpty {
                    let cloudModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
                    self.updateActiveTaskProvider(provider: visionProvider, isVision: true, forceLocal: false)
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
            let useLocal = (routeProvider == "local")
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
            let useLocal = (routeProvider == "local")
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
            let useLocal = (routeProvider == "local")
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
}
