import SwiftUI
import Combine

@MainActor
struct PostLectureView: View {
    let activeModuleId: Int?
    
    let sandboxTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    @State private var section: String = "Summary Sandbox" // "Summary Sandbox" vs "Dialogue Partner"
    @State private var notes: [Note] = []
    @State private var selectedNote: Note?
    
    // Sandbox States
    @State private var explanationText: String = ""
    @State private var timerSeconds: Int = 300
    @State private var timerRunning: Bool = false
    @State private var sandboxRating: String = ""
    @State private var sandboxFeedback: String = ""
    @State private var sandboxConcepts: [String] = []
    @State private var isRating: Bool = false
    
    // Dialogue States
    @State private var chatMessages: [FeynmanChat] = []
    @State private var chatInputText: String = ""
    @State private var isGeneratingChatResponse: Bool = false
    
    // Feedback & Confirmation States
    @ObservedObject private var aiHelper = AIHelper.shared
    @State private var feedbackAlertTitle: String = ""
    @State private var feedbackAlertMessage: String = ""
    @State private var showFeedbackAlert: Bool = false
    @State private var showResetDialogueConfirm: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Lecture Selection & Section Segmented Picker
            HStack(spacing: 20) {
                Picker("Lecture", selection: $selectedNote) {
                    if notes.isEmpty {
                        Text("No lectures found").tag(nil as Note?)
                    } else {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            Text("Lecture \(index + 1) - \(note.title)").tag(note as Note?)
                        }
                    }
                }
                .frame(width: 250)
                
                Picker("", selection: $section) {
                    Text("Summary Sandbox").tag("Summary Sandbox")
                    Text("Dialogue Partner").tag("Dialogue Partner")
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            if let note = selectedNote {
                if section == "Summary Sandbox" {
                    sandboxView(note: note)
                } else {
                    dialogueView(note: note)
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "rectangle.and.pencil.and.ellipsis")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 10)
                    Text(activeModuleId == nil ? "Please select or create an active module first." : "Upload a PDF note in Notes & Topics to start.")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: activeModuleId) { _, _ in
            loadNotes()
        }
        .onChange(of: selectedNote?.id) { _, _ in
            resetSandbox()
            loadChats(for: selectedNote)
        }
        .onChange(of: aiHelper.isAIBusy) { _, isBusy in
            if !isBusy {
                loadNotes()
            }
        }
        .onAppear {
            loadNotes()
        }
        .alert(feedbackAlertTitle, isPresented: $showFeedbackAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(feedbackAlertMessage)
        }
        .alert("Reset Dialogue?", isPresented: $showResetDialogueConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                if let note = selectedNote {
                    resetDialogue(note: note)
                }
            }
        } message: {
            Text("This will permanently erase the conversation history for this lecture and start a new session.")
        }
        .onReceive(sandboxTimer) { _ in
            if timerRunning {
                if timerSeconds > 0 {
                    timerSeconds -= 1
                } else {
                    timerRunning = false
                }
            }
        }
    }
    
    // MARK: - Summary Sandbox View
    
    private func sandboxView(note: Note) -> some View {
        HStack(spacing: 20) {
            // Left Column: Writing area + Timer
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Explain the lecture concept in your own words:")
                        .font(.headline)
                    Spacer()
                    
                    // Timer UI
                    HStack(spacing: 8) {
                        Text(formatTimer(timerSeconds))
                            .font(.system(.body, design: .monospaced))
                            .bold()
                            .foregroundColor(timerSeconds < 60 ? .red : .primary)
                        
                        Button(action: {
                            toggleTimer()
                        }) {
                            Image(systemName: timerRunning ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(timerRunning ? "Pause timer" : "Start timer")
                        
                        Button(action: {
                            resetTimer()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Reset timer")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                TextEditor(text: $explanationText)
                    .font(.system(.body))
                    .padding(5)
                    .border(Color.secondary.opacity(0.2), width: 1)
                    .cornerRadius(4)
                
                if (note.aiSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Generate an AI Summary in Study Guide first before assessing or starting dialogue.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                
                HStack {
                    Spacer()
                    Button(action: {
                        rateExplanation(note: note)
                    }) {
                        if isRating {
                            ProgressView().controlSize(.small).padding(.horizontal, 10)
                        } else {
                            Text("Rate My Explanation")
                                .font(.headline)
                                .frame(height: 30)
                                .padding(.horizontal, 20)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRating)
                }
            }
            .frame(maxWidth: .infinity)
            
            Divider()
            
            // Right Column: Assessment result
            VStack(alignment: .leading, spacing: 15) {
                Text("AI Feynman Assessment")
                    .font(.headline)
                
                if sandboxRating.isEmpty && sandboxFeedback.isEmpty && !isRating {
                    VStack {
                        Spacer()
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                        Text("Assess your summary above to see score and feedback.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                } else if isRating {
                    VStack {
                        Spacer()
                        ProgressView()
                            .padding(.bottom, 10)
                        Text("Analyzing explanation against lecture summary...")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text("Rating:")
                                    .bold()
                                Spacer()
                                Text(sandboxRating)
                                    .font(.title2)
                                    .bold()
                                    .foregroundColor(ratingColor)
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Feedback:")
                                    .bold()
                                if isLaTeX(sandboxFeedback) {
                                    LaTeXView(latex: sandboxFeedback)
                                        .allowsHitTesting(false)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(sandboxFeedback)
                                        .lineSpacing(4)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Concepts Left Out / Explained Poorly:")
                                    .bold()
                                    .foregroundColor(.red.opacity(0.8))
                                
                                if sandboxConcepts.isEmpty {
                                    Text("Excellent job! You covered all the key concepts of the lecture.")
                                        .font(.subheadline)
                                        .italic()
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(sandboxConcepts, id: \.self) { concept in
                                        HStack(alignment: .top) {
                                            Text("•")
                                            if isLaTeX(concept) {
                                                LaTeXView(latex: concept)
                                                    .allowsHitTesting(false)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            } else {
                                                Text(concept)
                                                    .font(.subheadline)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.05))
                            .cornerRadius(10)
                            .border(Color.red.opacity(0.1), width: 1)
                        }
                    }
                }
            }
            .frame(width: 320)
        }
        .padding(20)
    }
    
    // MARK: - Dialogue Partner View
    
    private func dialogueView(note: Note) -> some View {
        VStack(spacing: 0) {
            // Chat Message List
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        if chatMessages.isEmpty {
                            VStack {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                    .padding(.bottom, 8)
                                Text("Curious Student Dialogue Partner")
                                    .font(.headline)
                                Text("Click below to start a Feynman learning session.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                if (note.aiSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Label("Generate an AI Summary in Study Guide first before assessing or starting dialogue.", systemImage: "info.circle")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .padding(.top, 4)
                                }
                                
                                Button("Start Conversation") {
                                    startDialogueSession(note: note)
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 10)
                            }
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(chatMessages) { msg in
                                HStack {
                                    if msg.role == "user" {
                                        Spacer()
                                        Group {
                                            if isLaTeX(msg.content) {
                                                LaTeXView(latex: msg.content)
                                                    .frame(maxWidth: 480, alignment: .leading)
                                            } else {
                                                Text(msg.content)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                        .frame(maxWidth: 500, alignment: .trailing)
                                    } else {
                                        Group {
                                            if isLaTeX(msg.content) {
                                                LaTeXView(latex: msg.content)
                                                    .frame(maxWidth: 480, alignment: .leading)
                                            } else {
                                                Text(msg.content)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .foregroundColor(.primary)
                                        .cornerRadius(12)
                                        .frame(maxWidth: 500, alignment: .leading)
                                        Spacer()
                                    }
                                }
                                .id(msg.id)
                            }
                            
                            if isGeneratingChatResponse {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Student is typing...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .id("typing_indicator")
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: chatMessages) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isGeneratingChatResponse) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            Divider()
            
            // Text Input bar
            HStack(spacing: 12) {
                Button("Reset Dialogue", role: .destructive) {
                    showResetDialogueConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(chatMessages.isEmpty || isGeneratingChatResponse)
                
                TextField("Explain details to the student...", text: $chatInputText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        sendChatMessage(note: note)
                    }
                    .disabled(chatMessages.isEmpty || isGeneratingChatResponse)
                
                Button(action: {
                    sendChatMessage(note: note)
                }) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Send message")
                .disabled(chatInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeneratingChatResponse)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
    
    // MARK: - Logic & Database integrations
    
    private func loadNotes() {
        guard let modId = activeModuleId else {
            self.notes = []
            self.selectedNote = nil
            return
        }
        let currentSelectedId = selectedNote?.id
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        if let curId = currentSelectedId, let matching = notes.first(where: { $0.id == curId }) {
            self.selectedNote = matching
        } else {
            self.selectedNote = notes.first
        }
    }
    
    private func loadChats(for note: Note?) {
        guard let note = note else {
            self.chatMessages = []
            return
        }
        self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: note.id)
    }
    
    // Summary Sandbox Logic
    private func toggleTimer() {
        timerRunning.toggle()
    }
    
    private func resetTimer() {
        timerRunning = false
        timerSeconds = 300
    }
    
    private func resetSandbox() {
        resetTimer()
        explanationText = ""
        sandboxRating = ""
        sandboxFeedback = ""
        sandboxConcepts = []
        isRating = false
    }
    
    private func rateExplanation(note: Note) {
        let freshNote = DatabaseManager.shared.getNote(id: note.id) ?? note
        if freshNote != note {
            self.selectedNote = freshNote
        }
        guard let summary = freshNote.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            feedbackAlertTitle = "Lecture Summary Required"
            feedbackAlertMessage = "This lecture does not have an AI summary yet. Open Study Guide to generate the summary first."
            showFeedbackAlert = true
            return
        }
        self.isRating = true
        Task {
            let res = await AIHelper.shared.evaluateFeynmanSummary(
                explanation: explanationText,
                noteTitle: freshNote.title,
                aiSummary: summary
            )
            
            DispatchQueue.main.async {
                self.isRating = false
                if let response = res {
                    parseSandboxAssessment(response)
                    
                    // Save to feynman_sessions
                    _ = DatabaseManager.shared.addFeynmanSession(
                        moduleId: activeModuleId,
                        concept: freshNote.title,
                        explanation: explanationText
                    )
                } else {
                    self.feedbackAlertTitle = "Assessment Unavailable"
                    self.feedbackAlertMessage = "Could not reach the AI provider to evaluate your explanation. Check your AI connection and try again."
                    self.showFeedbackAlert = true
                }
            }
        }
    }
    
    private func parseSandboxAssessment(_ text: String) {
        var ratingVal = ""
        var feedbackVal = ""
        var conceptsVal: [String] = []
        
        let lines = text.components(separatedBy: .newlines)
        var parsingConcepts = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            if trimmed.lowercased().hasPrefix("rating:") {
                ratingVal = String(trimmed.dropFirst("rating:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                parsingConcepts = false
            } else if trimmed.lowercased().hasPrefix("feedback:") {
                feedbackVal = String(trimmed.dropFirst("feedback:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                parsingConcepts = false
            } else if trimmed.lowercased().hasPrefix("concepts left out:") {
                parsingConcepts = true
            } else if parsingConcepts {
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("•") || trimmed.hasPrefix("*") {
                    let concept = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !concept.isEmpty && !concept.lowercased().hasPrefix("none") {
                        conceptsVal.append(concept)
                    }
                }
            }
        }
        
        self.sandboxRating = ratingVal
        self.sandboxFeedback = feedbackVal
        self.sandboxConcepts = conceptsVal
    }
    
    private var ratingColor: Color {
        if let scorePart = sandboxRating.components(separatedBy: "/").first, let score = Int(scorePart.trimmingCharacters(in: .whitespaces)) {
            if score >= 8 {
                return .green
            } else if score >= 5 {
                return .orange
            } else {
                return .red
            }
        }
        return .secondary
    }
    
    // Dialogue Chat Logic
    private func startDialogueSession(note: Note) {
        let freshNote = DatabaseManager.shared.getNote(id: note.id) ?? note
        if freshNote != note {
            self.selectedNote = freshNote
        }
        guard let summary = freshNote.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            feedbackAlertTitle = "Lecture Summary Required"
            feedbackAlertMessage = "This lecture does not have an AI summary yet. Open Study Guide to generate the summary first."
            showFeedbackAlert = true
            return
        }
        self.isGeneratingChatResponse = true
        
        Task {
            let res = await AIHelper.shared.generateFeynmanStartingQuestion(noteTitle: freshNote.title, aiSummary: summary)
            DispatchQueue.main.async {
                self.isGeneratingChatResponse = false
                if let question = res {
                    _ = DatabaseManager.shared.addFeynmanChat(noteId: freshNote.id, role: "assistant", content: question)
                    self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: freshNote.id)
                } else {
                    self.feedbackAlertTitle = "AI Unavailable"
                    self.feedbackAlertMessage = "Could not reach the AI provider to start the dialogue session. Check your AI connection and try again."
                    self.showFeedbackAlert = true
                }
            }
        }
    }
    
    private func sendChatMessage(note: Note) {
        let text = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        let freshNote = DatabaseManager.shared.getNote(id: note.id) ?? note
        if freshNote != note {
            self.selectedNote = freshNote
        }
        
        self.chatInputText = ""
        _ = DatabaseManager.shared.addFeynmanChat(noteId: freshNote.id, role: "user", content: text)
        self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: freshNote.id)
        
        self.isGeneratingChatResponse = true
        
        // Log activity count in database
        DatabaseManager.shared.logActivity("interleaving", moduleId: activeModuleId) // Dialogue is active problem-interleaving-solving
        
        Task {
            let response = await AIHelper.shared.getFeynmanDialogueResponse(
                noteTitle: freshNote.title,
                aiSummary: freshNote.aiSummary ?? "",
                chatHistory: self.chatMessages
            )
            
            DispatchQueue.main.async {
                self.isGeneratingChatResponse = false
                if let reply = response {
                    _ = DatabaseManager.shared.addFeynmanChat(noteId: freshNote.id, role: "assistant", content: reply)
                    self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: freshNote.id)
                } else {
                    self.feedbackAlertTitle = "AI Unavailable"
                    self.feedbackAlertMessage = "Could not reach the AI provider to continue the dialogue. Check your AI connection and try again."
                    self.showFeedbackAlert = true
                }
            }
        }
    }
    
    private func resetDialogue(note: Note) {
        _ = DatabaseManager.shared.clearFeynmanChats(forNoteId: note.id)
        self.chatMessages = []
        startDialogueSession(note: note)
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if isGeneratingChatResponse {
                proxy.scrollTo("typing_indicator", anchor: .bottom)
            } else if let last = chatMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
    
    private func formatTimer(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
