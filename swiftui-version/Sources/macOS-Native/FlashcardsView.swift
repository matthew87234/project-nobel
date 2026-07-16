import SwiftUI
import AppKit
import WebKit

enum FlashcardMode {
    case review
    case add
    case manage
}

struct FlipCardView: View {
    let front: String
    let back: String
    @Binding var isFlipped: Bool
    
    var body: some View {
        ZStack {
            // Front Card
            VStack {
                Spacer()
                if isLaTeX(front) {
                    LaTeXView(latex: front)
                        .frame(height: 120)
                        .padding(.horizontal, 20)
                } else {
                    Text(front)
                        .font(.system(size: 20, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(30)
                }
                Spacer()
                Text("Click to Flip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
            .opacity(isFlipped ? 0.0 : 1.0)
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0.0, y: 1.0, z: 0.0))
            
            // Back Card
            VStack {
                Spacer()
                if isLaTeX(back) {
                    LaTeXView(latex: back)
                        .frame(height: 120)
                        .padding(.horizontal, 20)
                } else {
                    Text(back)
                        .font(.system(size: 20, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(30)
                }
                Spacer()
                Text("Click to Flip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
            .opacity(isFlipped ? 1.0 : 0.0)
            .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0.0, y: 1.0, z: 0.0))
        }
        .frame(height: 250)
        .frame(maxWidth: 500)
    }
}

struct FlashcardsView: View {
    let activeModuleId: Int?
    let mode: FlashcardMode
    let isExamMode: Bool
    var isActive: Bool = true
    
    // Add Card State
    @State private var frontText: String = ""
    @State private var backText: String = ""
    @State private var showLatexHelper: Bool = false
    @State private var latexInput: String = ""
    @State private var latexResult: String = ""
    @State private var latexImageBase64: String = ""
    @State private var latexClipboardImage: NSImage? = nil
    @State private var isTranslatingLaTeX: Bool = false
    
    enum FocusField: Hashable {
        case front
        case back
    }
    @FocusState private var focusedField: FocusField?
    
    // Review State
    @State private var dueCards: [Flashcard] = []
    @State private var currentCardIdx: Int = 0
    @State private var isFlipped: Bool = false
    @State private var fcTimerSeconds: Int = 0
    @State private var fcTimer: Timer?
    
    // Manage State
    @State private var allCards: [Flashcard] = []
    @State private var selectedCards = Set<Flashcard.ID>()
    @State private var searchField: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .review:
                reviewBody
            case .add:
                addBody
            case .manage:
                manageBody
            }
        }
        .onAppear {
            if isActive {
                loadInitialData()
                if mode == .add {
                    focusedField = .front
                }
            }
        }
        .onChange(of: activeModuleId) { oldValue, newValue in
            if isActive {
                loadInitialData()
            }
        }
        .onChange(of: isActive) { oldValue, newValue in
            if newValue {
                loadInitialData()
                if mode == .add {
                    focusedField = .front
                }
            } else {
                fcTimer?.invalidate()
                logActiveSeconds()
            }
        }
        .onDisappear {
            fcTimer?.invalidate()
            logActiveSeconds()
        }
    }
    
    private func loadInitialData() {
        if mode == .review {
            loadDueCards()
            startTimer()
        } else if mode == .manage {
            loadAllCards()
        }
    }
    
    private func startTimer() {
        fcTimer?.invalidate()
        fcTimerSeconds = 0
        fcTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            fcTimerSeconds += 1
            if fcTimerSeconds % 10 == 0 {
                // Log time to database every 10 seconds
                DatabaseManager.shared.addStudyTime(flashcardsDelta: 10, problemsDelta: 0)
                if let modId = activeModuleId {
                    DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: 10, problemsDelta: 0)
                }
            }
        }
    }
    
    private func logActiveSeconds() {
        let remainder = fcTimerSeconds % 10
        if remainder > 0 {
            DatabaseManager.shared.addStudyTime(flashcardsDelta: remainder, problemsDelta: 0)
            if let modId = activeModuleId {
                DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: remainder, problemsDelta: 0)
            }
        }
    }
    
    // MARK: - Review Body
    
    private var reviewBody: some View {
        VStack(spacing: 15) {
            // 80/20 progress bar at the top
            RatioTrackerBar()
                .padding(.horizontal)
                .padding(.top, 10)
            
            if dueCards.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.green)
                        .padding(.bottom, 12)
                    
                    Text("All Caught Up!")
                        .font(.title2)
                        .bold()
                    
                    Text("No due flashcards for today. Keep up the good work!")
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentCardIdx < dueCards.count {
                let card = dueCards[currentCardIdx]
                VStack(spacing: 20) {
                    Text("Reviewing Flashcards (\(currentCardIdx + 1)/\(dueCards.count))")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    FlipCardView(front: card.front, back: card.back, isFlipped: $isFlipped)
                        .onTapGesture {
                            withAnimation(.spring()) {
                                isFlipped.toggle()
                            }
                        }
                    
                    if isFlipped {
                        // Rating buttons (1-5 quality)
                        VStack(spacing: 10) {
                            Text("Rate your recall quality:")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 10) {
                                ForEach(1...5, id: \.self) { score in
                                    Button("\(score)") {
                                        rateRecall(quality: score)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .tint(ratingButtonColor(score))
                                }
                            }
                        }
                        .transition(.opacity)
                    } else {
                        Button("Show Answer") {
                            withAnimation(.spring()) {
                                isFlipped = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            ZStack {
                if !dueCards.isEmpty && currentCardIdx < dueCards.count {
                    if !isFlipped {
                        Button("") {
                            withAnimation(.spring()) {
                                isFlipped = true
                            }
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                    } else {
                        Button("") {
                            rateRecall(quality: 1)
                        }
                        .keyboardShortcut("1", modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        
                        Button("") {
                            rateRecall(quality: 3)
                        }
                        .keyboardShortcut("2", modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        
                        Button("") {
                            rateRecall(quality: 5)
                        }
                        .keyboardShortcut("3", modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                    }
                }
            }
        )
    }
    
    private func ratingButtonColor(_ score: Int) -> Color? {
        switch score {
        case 1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .blue
        case 5: return .green
        default: return nil
        }
    }
    
    private func loadDueCards() {
        let today = formatDate(Date())
        let modId = isExamMode ? activeModuleId : nil
        self.dueCards = DatabaseManager.shared.getDueFlashcards(forModuleId: modId, today: today).shuffled()
        self.currentCardIdx = 0
        self.isFlipped = false
    }
    
    private func rateRecall(quality: Int) {
        guard currentCardIdx < dueCards.count else { return }
        let card = dueCards[currentCardIdx]
        
        // SM-2 Spaced Repetition Algorithm
        var interval = card.interval
        var easeFactor = card.easeFactor
        var repetitions = card.repetitions
        
        if quality >= 3 {
            if repetitions == 0 {
                interval = 1
            } else if repetitions == 1 {
                interval = 6
            } else {
                interval = Int(Double(interval) * easeFactor)
            }
            repetitions += 1
        } else {
            repetitions = 0
            interval = 1
        }
        
        easeFactor = easeFactor + (0.1 - (5.0 - Double(quality)) * (0.08 + (5.0 - Double(quality)) * 0.02))
        if easeFactor < 1.3 {
            easeFactor = 1.3
        }
        
        let calendar = Calendar.current
        let nextReview = calendar.date(byAdding: .day, value: interval, to: Date())!
        let nextReviewStr = formatDate(nextReview)
        
        _ = DatabaseManager.shared.updateFlashcardReview(
            id: card.id,
            interval: interval,
            easeFactor: easeFactor,
            repetitions: repetitions,
            nextReviewDate: nextReviewStr
        )
        
        // Log study activity
        DatabaseManager.shared.logActivity("flashcard", moduleId: activeModuleId)
        
        // Advance
        withAnimation {
            isFlipped = false
            currentCardIdx += 1
            if currentCardIdx >= dueCards.count {
                loadDueCards() // Reload if done
            }
        }
    }
    
    // MARK: - Add Card Body
    
    private var addBody: some View {
        Form {
            Section(header: Text("Create Flashcard").font(.headline)) {
                if activeModuleId == nil {
                    Text("Select a module in the sidebar first before adding cards.")
                        .foregroundColor(.red)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Front Content:").bold()
                        TextField("", text: $frontText, axis: .vertical)
                            .focused($focusedField, equals: .front)
                            .onKeyPress(.tab) {
                                focusedField = .back
                                return .handled
                            }
                            .lineLimit(4, reservesSpace: true)
                            .textFieldStyle(.plain)
                            .padding(6)
                            .frame(height: 80, alignment: .topLeading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        
                        Text("Back Content:").bold()
                        TextField("", text: $backText, axis: .vertical)
                            .focused($focusedField, equals: .back)
                            .onKeyPress(.tab) {
                                focusedField = .front
                                return .handled
                            }
                            .lineLimit(4, reservesSpace: true)
                            .textFieldStyle(.plain)
                            .padding(6)
                            .frame(height: 80, alignment: .topLeading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        
                        // Live LaTeX Preview
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Live LaTeX Preview:").bold()
                            VStack(alignment: .leading, spacing: 8) {
                                if !frontText.isEmpty || !backText.isEmpty {
                                    if !frontText.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Front:").font(.caption).foregroundColor(.secondary)
                                            if isLaTeX(frontText) {
                                                LaTeXView(latex: frontText)
                                                    .frame(height: 60)
                                            } else {
                                                Text(frontText)
                                                    .font(.body)
                                                    .padding(.horizontal, 4)
                                            }
                                        }
                                    }
                                    if !backText.isEmpty {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Back:").font(.caption).foregroundColor(.secondary)
                                            if isLaTeX(backText) {
                                                LaTeXView(latex: backText)
                                                    .frame(height: 60)
                                            } else {
                                                Text(backText)
                                                    .font(.body)
                                                    .padding(.horizontal, 4)
                                            }
                                        }
                                    }
                                } else {
                                    Text("Preview will appear here as you type.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.vertical, 5)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.windowBackgroundColor))
                            .cornerRadius(6)
                            .border(Color.secondary.opacity(0.15), width: 1)
                        }
                        .padding(.vertical, 5)
                        
                        HStack {
                            Button(action: {
                                showLatexHelper = true
                            }) {
                                 Label("LaTeX Helper", systemImage: "textformat.math")
                            }
                            .buttonStyle(.bordered)
                            
                            Spacer()
                            
                            Button(action: {
                                saveCard()
                            }) {
                                Text("Add Flashcard")
                                    .padding(.horizontal, 15)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(25)
        .sheet(isPresented: $showLatexHelper) {
            latexHelperSheet
        }
    }
    
    private func saveCard() {
        guard let modId = activeModuleId else { return }
        let success = DatabaseManager.shared.addFlashcard(moduleId: modId, front: frontText, back: backText)
        if success {
            frontText = ""
            backText = ""
            focusedField = .front
            // Trigger feedback
            let notification = NSUserNotification()
            notification.title = "Flashcard Added"
            notification.informativeText = "Successfully created new flashcard."
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
    
    // MARK: - LaTeX Helper Sheet
    
    private var latexHelperSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("LaTeX Equation Translator")
                        .font(.title2)
                        .bold()
                    
                    Text("Describe an equation in plain text or paste an image from your clipboard, and local AI (Qwen) will convert it into raw LaTeX code.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 15) {
                        // Left Column: Plain text input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Equation Description:")
                                .bold()
                            TextField("e.g. integral from 0 to infinity of e to the minus x squared", text: $latexInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    translateTextToLatex()
                                }
                            
                            Button("Translate Text") {
                                translateTextToLatex()
                            }
                            .buttonStyle(.bordered)
                            .disabled(latexInput.isEmpty || isTranslatingLaTeX)
                        }
                        
                        Divider()
                        
                        // Right Column: Clipboard image input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Clipboard Image Preview:")
                                .bold()
                            
                            if let img = latexClipboardImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 60)
                                    .border(Color.secondary.opacity(0.3))
                            } else {
                                VStack {
                                    Text("No Image Pasted")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                            }
                            
                            Button("📋 Paste Image from Clipboard") {
                                pasteClipboardImage()
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTranslatingLaTeX)
                        }
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    // Result Output Box
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result LaTeX Code:")
                            .bold()
                        
                        if isTranslatingLaTeX {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Translating via local Qwen model...")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            TextEditor(text: $latexResult)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 60)
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    
                    // Result Preview
                    if !latexResult.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Equation Preview:").bold()
                            LaTeXView(latex: latexResult)
                                .frame(height: 70)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .border(Color.secondary.opacity(0.15), width: 1)
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Button("Close") {
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Copy to Clipboard") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("$\(latexResult)$", forType: .string)
                }
                .buttonStyle(.bordered)
                .disabled(latexResult.isEmpty)
                
                Button("Paste to Front Content") {
                    frontText += "$\(latexResult)$"
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.bordered)
                .disabled(latexResult.isEmpty)
                
                Button("Paste to Back Content") {
                    backText += "$\(latexResult)$"
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.borderedProminent)
                .disabled(latexResult.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580, height: 500)
    }
    
    private func pasteClipboardImage() {
        if let image = NSImage(pasteboard: NSPasteboard.general) {
            self.latexClipboardImage = image
            // Convert to base64
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                self.latexImageBase64 = pngData.base64EncodedString()
                translateImageToLatex()
            }
        }
    }
    
    private func translateTextToLatex() {
        self.isTranslatingLaTeX = true
        Task {
            let res = await AIHelper.shared.translateToLaTeX(rawEquation: latexInput)
            DispatchQueue.main.async {
                self.isTranslatingLaTeX = false
                if let latex = res {
                    self.latexResult = latex
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("$\(latex)$", forType: .string)
                }
            }
        }
    }
    
    private func translateImageToLatex() {
        self.isTranslatingLaTeX = true
        Task {
            let res = await AIHelper.shared.translateImageToLaTeX(base64Image: latexImageBase64)
            DispatchQueue.main.async {
                self.isTranslatingLaTeX = false
                if let latex = res {
                    if latex == "MODEL_NOT_FOUND" {
                        self.latexResult = "No local vision model found. Please pull qwen2.5vl."
                    } else {
                        self.latexResult = latex
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString("$\(latex)$", forType: .string)
                    }
                }
            }
        }
    }
    
    private func resetLatexHelper() {
        latexInput = ""
        latexResult = ""
        latexClipboardImage = nil
        latexImageBase64 = ""
        isTranslatingLaTeX = false
    }
    
    // MARK: - Manage Body
    
    private var manageBody: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Manage Flashcards")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                TextField("Search flashcards...", text: $searchField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: searchField) { _ in
                        loadAllCards()
                    }
            }
            .padding(.horizontal)
            .padding(.top, 15)
            
            List(selection: $selectedCards) {
                ForEach(allCards) { card in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Q: \(card.front)")
                                .bold()
                            Text("A: \(card.back)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                }
            }
            .listStyle(.bordered)
            
            HStack {
                Button("Delete Selected") {
                    deleteSelectedCards()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .disabled(selectedCards.isEmpty)
                
                Spacer()
                
                Button("Export Selected to Anki") {
                    exportSelectedToAnki()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCards.isEmpty)
            }
            .padding()
        }
    }
    
    private func loadAllCards() {
        let query = searchField.trimmingCharacters(in: .whitespacesAndNewlines)
        let cards = DatabaseManager.shared.getFlashcards(forModuleId: activeModuleId)
        
        if query.isEmpty {
            self.allCards = cards
        } else {
            self.allCards = cards.filter {
                $0.front.lowercased().contains(query.lowercased()) ||
                $0.back.lowercased().contains(query.lowercased())
            }
        }
    }
    
    private func deleteSelectedCards() {
        for cardId in selectedCards {
            _ = DatabaseManager.shared.deleteFlashcard(id: cardId)
        }
        selectedCards.removeAll()
        loadAllCards()
    }
    
    private func exportSelectedToAnki() {
        let selectedList = allCards.filter { selectedCards.contains($0.id) }
        guard !selectedList.isEmpty else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "anki_export.csv"
        savePanel.title = "Export Flashcards for Anki"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                var csvText = ""
                for card in selectedList {
                    // Escape CSV fields
                    let front = card.front.replacingOccurrences(of: "\"", with: "\"\"")
                    let back = card.back.replacingOccurrences(of: "\"", with: "\"\"")
                    csvText += "\"\(front)\",\"\(back)\"\n"
                }
                try? csvText.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - LaTeX Rendering Components

func isLaTeX(_ text: String) -> Bool {
    let lower = text.lowercased()
    if text.contains("$") { return true }
    if text.contains("\\") { return true }
    if text.contains("{") && text.contains("}") { return true }
    if text.contains("_") || text.contains("^") { return true }
    if lower.contains("begin{") && lower.contains("end{") { return true }
    return false
}

struct LaTeXView: NSViewRepresentable {
    let latex: String
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let escapedLatex = latex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/contrib/auto-render.min.js"></script>
            <style>
                body {
                    margin: 0;
                    padding: 0px 4px;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    background-color: transparent;
                    color: currentColor;
                    box-sizing: border-box;
                    text-align: left;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #FFFFFF; }
                }
                @media (prefers-color-scheme: light) {
                    body { color: #000000; }
                }
                .math-content {
                    font-size: 14px;
                    line-height: 1.35;
                    max-width: 100%;
                    word-wrap: break-word;
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body>
            <div class="math-content" id="math-render"></div>
            <script>
                try {
                    let rawText = `\(escapedLatex)`.trim();
                    let container = document.getElementById("math-render");
                    container.textContent = rawText;
                    renderMathInElement(container, {
                        delimiters: [
                            {left: "$$", right: "$$", display: true},
                            {left: "$", right: "$", display: false},
                            {left: "\\\\(", right: "\\\\)", display: false},
                            {left: "\\\\[", right: "\\\\]", display: true}
                        ],
                        throwOnError: false
                    });
                } catch (e) {
                    document.getElementById("math-render").innerText = e.message;
                }
            </script>
        </body>
        </html>
        """
        nsView.loadHTMLString(html, baseURL: nil)
    }
}
