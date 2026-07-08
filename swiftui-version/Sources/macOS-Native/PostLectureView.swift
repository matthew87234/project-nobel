import SwiftUI

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
    
    var body: some View {
        VStack(spacing: 0) {
            // Lecture Selection & Section Segmented Picker
            HStack(spacing: 20) {
                Picker("Lecture", selection: $selectedNote) {
                    if notes.isEmpty {
                        Text("No lectures found").tag(nil as Note?)
                    } else {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            Text("Wk \(index + 1) - \(note.title)").tag(note as Note?)
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
        .onChange(of: activeModuleId) { _ in
            loadNotes()
        }
        .onChange(of: selectedNote) { note in
            resetSandbox()
            loadChats(for: note)
        }
        .onAppear {
            loadNotes()
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
                        
                        Button(action: {
                            resetTimer()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                                Text(sandboxFeedback)
                                    .lineSpacing(4)
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
                                            Text(concept)
                                                .font(.subheadline)
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
                                        Text(msg.content)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color.blue)
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                            .frame(maxWidth: 500, alignment: .trailing)
                                            .textSelection(.enabled)
                                    } else {
                                        Text(msg.content)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .foregroundColor(.primary)
                                            .cornerRadius(12)
                                            .frame(maxWidth: 500, alignment: .leading)
                                            .textSelection(.enabled)
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
                .onChange(of: chatMessages) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isGeneratingChatResponse) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }
            
            Divider()
            
            // Text Input bar
            HStack(spacing: 12) {
                Button("Reset Dialogue", role: .destructive) {
                    resetDialogue(note: note)
                }
                .buttonStyle(.bordered)
                
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
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        self.selectedNote = notes.first
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
        guard let summary = note.aiSummary, !summary.isEmpty else {
            // Note needs to be summarized first
            return
        }
        self.isRating = true
        Task {
            let res = await AIHelper.shared.evaluateFeynmanSummary(
                explanation: explanationText,
                noteTitle: note.title,
                aiSummary: summary
            )
            
            DispatchQueue.main.async {
                self.isRating = false
                if let response = res {
                    parseSandboxAssessment(response)
                    
                    // Save to feynman_sessions
                    _ = DatabaseManager.shared.addFeynmanSession(
                        moduleId: activeModuleId,
                        concept: note.title,
                        explanation: explanationText
                    )
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
                    conceptsVal.append(concept)
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
        guard let summary = note.aiSummary, !summary.isEmpty else { return }
        self.isGeneratingChatResponse = true
        
        Task {
            let res = await AIHelper.shared.generateFeynmanStartingQuestion(noteTitle: note.title, aiSummary: summary)
            DispatchQueue.main.async {
                self.isGeneratingChatResponse = false
                if let question = res {
                    _ = DatabaseManager.shared.addFeynmanChat(noteId: note.id, role: "assistant", content: question)
                    self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: note.id)
                }
            }
        }
    }
    
    private func sendChatMessage(note: Note) {
        let text = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        self.chatInputText = ""
        _ = DatabaseManager.shared.addFeynmanChat(noteId: note.id, role: "user", content: text)
        self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: note.id)
        
        self.isGeneratingChatResponse = true
        
        // Log activity count in database
        DatabaseManager.shared.logActivity("interleaving", moduleId: activeModuleId) // Dialogue is active problem-interleaving-solving
        
        Task {
            let response = await AIHelper.shared.getFeynmanDialogueResponse(
                noteTitle: note.title,
                aiSummary: note.aiSummary ?? "",
                chatHistory: self.chatMessages
            )
            
            DispatchQueue.main.async {
                self.isGeneratingChatResponse = false
                if let reply = response {
                    _ = DatabaseManager.shared.addFeynmanChat(noteId: note.id, role: "assistant", content: reply)
                    self.chatMessages = DatabaseManager.shared.getFeynmanChats(forNoteId: note.id)
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
