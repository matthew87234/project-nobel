import SwiftUI
import AppKit
import Combine

@MainActor
struct StudyView: View {
    let activeModuleId: Int?
    
    @State private var notes: [Note] = []
    @State private var selectedNote: Note?
    @State private var summaryText: String = ""
    @State private var isAnalyzing: Bool = false
    
    let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Pane: List of Notes
            VStack(alignment: .leading, spacing: 10) {
                Text("Lectures & Notes")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 10)
                
                if notes.isEmpty {
                    VStack {
                        Spacer()
                        Text(activeModuleId == nil ? "Create a module first using Edit -> Manage Modules." : "No notes uploaded.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(Array(notes.enumerated()), id: \.element.id, selection: $selectedNote) { index, note in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(selectedNote == note ? Color.white.opacity(0.3) : Color.blue.opacity(0.15))
                                .foregroundColor(selectedNote == note ? .white : .blue)
                                .cornerRadius(4)
                            
                            Text(note.title)
                                .font(.system(.subheadline, design: .rounded))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .pointingHandCursor()
                        .tag(note)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 250)
            
            Divider()
            
            // Right Pane: Summary & Details
            VStack {
                if let note = selectedNote {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text(note.title)
                                    .font(.title)
                                    .bold()
                                
                                Spacer()
                                
                                Button(action: {
                                    regenerateSummary()
                                }) {
                                    Label("Redo", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .pointingHandCursor()
                            }
                            
                            // AI Summary Card
                            VStack(alignment: .leading, spacing: 12) {
                                Text("AI SUMMARY")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.secondary)
                                
                                if AIHelper.shared.isAIDisconnected && summaryText.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 8) {
                                            Image(systemName: "wifi.slash")
                                                .foregroundColor(.blue)
                                                .font(.headline)
                                            Text(AIHelper.shared.disconnectionMessage.isEmpty ? "Tailscale Disconnected" : AIHelper.shared.disconnectionMessage)
                                                .font(.headline)
                                                .foregroundColor(.blue)
                                        }
                                        Text("Unable to connect to external AI server to generate summary.")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        
                                        Button(action: {
                                            AIHelper.shared.retryConnectionAndQueue()
                                            displayNoteDetails(selectedNote)
                                        }) {
                                            HStack(spacing: 6) {
                                                if AIHelper.shared.isRetryingConnection {
                                                    ProgressView()
                                                        .controlSize(.mini)
                                                } else {
                                                    Image(systemName: "arrow.clockwise")
                                                }
                                                Text(AIHelper.shared.isRetryingConnection ? "Checking..." : "Try Again")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.blue)
                                        .controlSize(.small)
                                        .disabled(AIHelper.shared.isRetryingConnection)
                                        .pointingHandCursor()
                                    }
                                    .padding(.vertical, 4)
                                } else if isAnalyzing {
                                    HStack {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Generating AI Summary...")
                                            .foregroundColor(.secondary)
                                    }
                                } else if summaryText.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("No AI summary generated yet.")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        
                                        Button(action: {
                                            regenerateSummary()
                                        }) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "sparkles")
                                                Text("Generate AI Summary")
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.blue)
                                        .controlSize(.small)
                                        .pointingHandCursor()
                                    }
                                    .padding(.vertical, 4)
                                } else {
                                    CondensedSummaryView(summaryText: summaryText)
                                }
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                            .cornerRadius(12)
                            
                            // Action Panel
                            HStack {
                                // View PDF Button
                                Button(action: {
                                    openFullscreenPDF(path: note.filePath)
                                }) {
                                    Label("View PDF", systemImage: "doc.viewfinder")
                                        .font(.headline)
                                        .frame(height: 35)
                                        .padding(.horizontal, 15)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .pointingHandCursor()
                                
                                Spacer()
                            }
                        }
                        .padding(25)
                    }
                } else {
                    VStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 10)
                        Text("Select a note to view summary")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: activeModuleId) { _, _ in
            loadNotes()
        }
        .onChange(of: selectedNote) { _, note in
            displayNoteDetails(note)
        }
        .onChange(of: AIHelper.shared.isAIBusy) { _, isBusy in
            if !isBusy {
                checkBackgroundProcessComplete()
            }
        }
        .onAppear {
            loadNotes()
        }
        .onReceive(timer) { _ in
            checkBackgroundProcessComplete()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NoteAnalysisCompleted"))) { notification in
            if let modId = activeModuleId {
                self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
            }
            if let noteId = notification.userInfo?["noteId"] as? Int, noteId == selectedNote?.id {
                if let updated = DatabaseManager.shared.getNote(id: noteId) {
                    self.selectedNote = updated
                    self.summaryText = updated.aiSummary ?? ""
                    self.isAnalyzing = false
                }
            }
        }
    }
    
    private func loadNotes() {
        guard let modId = activeModuleId else {
            self.notes = []
            self.selectedNote = nil
            return
        }
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        if let first = notes.first {
            self.selectedNote = first
        } else {
            self.selectedNote = nil
        }
    }
    
    private func displayNoteDetails(_ note: Note?) {
        guard let note = note else {
            self.summaryText = ""
            self.isAnalyzing = false
            return
        }
        
        let targetId = note.id
        if AIHelper.shared.isProcessingNote(id: targetId) {
            self.summaryText = ""
            self.isAnalyzing = true
        } else if let summary = note.aiSummary, !summary.isEmpty {
            self.summaryText = summary
            self.isAnalyzing = false
        } else {
            self.summaryText = ""
            self.isAnalyzing = true
            
            // Trigger async analysis if Ollama is running and not already queued
            Task {
                await AIHelper.shared.ensureNoteSummarized(noteId: targetId)
            }
        }
    }
    
    private func checkBackgroundProcessComplete() {
        guard let modId = activeModuleId else { return }
        let latestNotes = DatabaseManager.shared.getNotes(forModuleId: modId)
        
        // If titles or note list changed, update live notes array
        if latestNotes.map(\.title) != notes.map(\.title) || latestNotes.map(\.id) != notes.map(\.id) {
            let currentSelectedId = selectedNote?.id
            self.notes = latestNotes
            if let selectedId = currentSelectedId, let updatedSelected = latestNotes.first(where: { $0.id == selectedId }) {
                self.selectedNote = updatedSelected
            } else if let first = latestNotes.first {
                self.selectedNote = first
            }
        }
        
        guard let note = selectedNote else { return }
        if let currentFresh = DatabaseManager.shared.getNote(id: note.id) {
            let isStillProcessing = AIHelper.shared.isProcessingNote(id: note.id)
            if !isStillProcessing {
                if let summary = currentFresh.aiSummary, !summary.isEmpty {
                    if self.summaryText != summary {
                        self.summaryText = summary
                    }
                    self.isAnalyzing = false
                }
            } else {
                self.isAnalyzing = true
            }
        }
    }
    
    private func regenerateSummary() {
        guard let note = selectedNote else { return }
        let targetId = note.id
        // Clear database cache & state
        _ = DatabaseManager.shared.updateNoteAI(noteId: targetId, summary: nil, primer: nil)
        self.summaryText = ""
        self.isAnalyzing = true
        
        // Trigger background AI task
        Task {
            await AIHelper.shared.processNoteSync(noteId: targetId)
        }
    }
    
    private func openFullscreenPDF(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Condensed Lecture Notes Document View
struct CondensedSummaryView: View {
    let summaryText: String
    
    enum SummaryBlock {
        case heading(String)
        case paragraph(String)
        case equation(String)
        case bullet(String)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let blocks = parseBlocks(summaryText)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: 3, height: 15)
                            .cornerRadius(2)
                        
                        Text(text)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 6)
                    
                case .paragraph(let text):
                    if isLaTeX(text) {
                        LaTeXView(latex: text)
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 24, maxHeight: 120)
                    } else {
                        Text(LocalizedStringKey(text))
                            .font(.system(size: 13, weight: .regular))
                            .lineSpacing(3)
                            .foregroundColor(.primary.opacity(0.9))
                    }
                    
                case .equation(let eqText):
                    let formattedEq = cleanEquation(eqText)
                    HStack {
                        Spacer()
                        LaTeXView(latex: "$$ " + formattedEq + " $$")
                            .allowsHitTesting(false)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48, idealHeight: 65, maxHeight: 140)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    
                case .bullet(let text):
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                        if isLaTeX(text) {
                            LaTeXView(latex: text)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 24, maxHeight: 90)
                        } else {
                            Text(LocalizedStringKey(text))
                                .font(.system(size: 13, weight: .regular))
                                .lineSpacing(2)
                        }
                    }
                }
            }
        }
    }
    
    private func parseBlocks(_ text: String) -> [SummaryBlock] {
        var blocks: [SummaryBlock] = []
        let rawLines = text.components(separatedBy: .newlines)
        
        var currentParagraph: [String] = []
        var inEquationBlock = false
        var equationBuffer: [String] = []
        
        func flushParagraph() {
            if !currentParagraph.isEmpty {
                let joined = currentParagraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty {
                    // Split long paragraphs (>160 chars) into short 1-2 sentence chunks to eliminate text clutter
                    if joined.count > 160 && joined.contains(". ") {
                        let sentences = joined.components(separatedBy: ". ")
                        var currentChunk: [String] = []
                        for s in sentences {
                            let trimmed = s.trimmingCharacters(in: .whitespaces)
                            if trimmed.isEmpty { continue }
                            let sentenceWithDot = trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?") ? trimmed : trimmed + "."
                            currentChunk.append(sentenceWithDot)
                            if currentChunk.count >= 2 {
                                blocks.append(.paragraph(currentChunk.joined(separator: " ")))
                                currentChunk.removeAll()
                            }
                        }
                        if !currentChunk.isEmpty {
                            blocks.append(.paragraph(currentChunk.joined(separator: " ")))
                        }
                    } else {
                        blocks.append(.paragraph(joined))
                    }
                }
                currentParagraph.removeAll()
            }
        }
        
        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            
            // Check for $$ display equation
            if line.hasPrefix("$$") && line.hasSuffix("$$") && line.count > 4 {
                flushParagraph()
                let eq = String(line.dropFirst(2).dropLast(2))
                blocks.append(.equation(eq))
                continue
            } else if line.hasPrefix("$$") {
                flushParagraph()
                inEquationBlock = true
                let content = String(line.dropFirst(2))
                if !content.isEmpty { equationBuffer.append(content) }
                continue
            } else if line.hasSuffix("$$") && inEquationBlock {
                let content = String(line.dropLast(2))
                if !content.isEmpty { equationBuffer.append(content) }
                blocks.append(.equation(equationBuffer.joined(separator: " ")))
                equationBuffer.removeAll()
                inEquationBlock = false
                continue
            } else if inEquationBlock {
                equationBuffer.append(line)
                continue
            }
            
            // Check for Markdown headers or brackets
            if line.hasPrefix("### ") || line.hasPrefix("## ") || line.hasPrefix("# ") || (line.hasPrefix("[") && line.hasSuffix("]")) {
                flushParagraph()
                var title = line
                if title.hasPrefix("#") {
                    title = title.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                } else if title.hasPrefix("[") && title.hasSuffix("]") {
                    title = String(title.dropFirst().dropLast())
                }
                
                let lowerTitle = title.lowercased()
                let genericEndingTitles = [
                    "applications in physics",
                    "applications in physics and mathematics",
                    "problem-solving skills",
                    "conclusion",
                    "summary & takeaways",
                    "summary and takeaways",
                    "practical applications",
                    "concluding remarks"
                ]
                
                // If this is a generic conclusion section, stop parsing trailing filler
                if genericEndingTitles.contains(where: { lowerTitle.contains($0) }) {
                    break
                }
                
                blocks.append(.heading(title))
                continue
            }
            
            // Check for bullet points
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                let bulletContent = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                
                // If bullet is a standalone equation (e.g. contains '=')
                if bulletContent.contains("=") && bulletContent.count < 60 && !bulletContent.contains("Overview") {
                    blocks.append(.equation(bulletContent))
                } else {
                    blocks.append(.bullet(bulletContent))
                }
                continue
            }
            
            // Check if line looks like an equation standalone
            if (line.hasPrefix("F =") || line.hasPrefix("E =") || line.hasPrefix("V =") || line.contains(" = ")) && line.count < 70 && !line.contains("This lecture") && !line.contains("Overview") {
                flushParagraph()
                blocks.append(.equation(line))
                continue
            }
            
            currentParagraph.append(line)
        }
        
        flushParagraph()
        return blocks
    }
    
    private func cleanEquation(_ eq: String) -> String {
        var clean = eq.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("$$") { clean = String(clean.dropFirst(2)) }
        if clean.hasSuffix("$$") { clean = String(clean.dropLast(2)) }
        if clean.hasPrefix("$") { clean = String(clean.dropFirst()) }
        if clean.hasSuffix("$") { clean = String(clean.dropLast()) }
        clean = clean.replacingOccurrences(of: "\\\\", with: "\\")
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
