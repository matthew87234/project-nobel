import SwiftUI

enum ProblemMode {
    case review
    case add
    case manage
}

struct ProblemsView: View {
    let activeModuleId: Int?
    let mode: ProblemMode
    let isExamMode: Bool
    
    // Add Problem State
    @State private var topics: [Topic] = []
    @State private var selectedTopic: Topic?
    @State private var problemContent: String = ""
    @State private var solutionHint: String = ""
    
    // Review State
    @State private var currentProblem: Problem?
    @State private var showHint: Bool = false
    @State private var prTimerSeconds: Int = 0
    @State private var isTimerActive: Bool = false
    
    let problemsTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    // Manage State
    @State private var allProblems: [Problem] = []
    @State private var selectedProblems = Set<Problem.ID>()
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
            loadInitialData()
        }
        .onChange(of: activeModuleId) { _ in
            loadInitialData()
        }
        .onDisappear {
            isTimerActive = false
            logActiveSeconds()
        }
        .onReceive(problemsTimer) { _ in
            guard isTimerActive && mode == .review && currentProblem != nil else { return }
            prTimerSeconds += 1
            if prTimerSeconds % 10 == 0 {
                // Log time to database every 10 seconds
                DatabaseManager.shared.addStudyTime(flashcardsDelta: 0, problemsDelta: 10)
                if let modId = activeModuleId {
                    DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: 0, problemsDelta: 10)
                }
            }
        }
    }
    
    private func loadInitialData() {
        if mode == .review {
            loadRandomProblem()
            prTimerSeconds = 0
            isTimerActive = true
        } else if mode == .add {
            loadTopics()
        } else if mode == .manage {
            loadAllProblems()
        }
    }
    
    private func logActiveSeconds() {
        let remainder = prTimerSeconds % 10
        if remainder > 0 {
            DatabaseManager.shared.addStudyTime(flashcardsDelta: 0, problemsDelta: remainder)
            if let modId = activeModuleId {
                DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: 0, problemsDelta: remainder)
            }
        }
    }
    
    // MARK: - Review Body
    
    private var reviewBody: some View {
        VStack(spacing: 15) {
            // 80/20 progress bar
            RatioTrackerBar()
                .padding(.horizontal)
                .padding(.top, 10)
            
            if let problem = currentProblem {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Interleaving Problem Practice")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Problem Content:")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.secondary)
                        
                        ScrollView {
                            Text(problem.content)
                                .font(.title3)
                                .lineSpacing(6)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(12)
                    }
                    
                    if showHint {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("HINT / SOLUTION:")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.orange)
                            
                            Text(problem.solutionHint)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(12)
                        .border(Color.orange.opacity(0.15), width: 1)
                        .transition(.opacity)
                    }
                    
                    HStack(spacing: 15) {
                        Button(showHint ? "Hide Hint" : "Check Hint") {
                            withAnimation {
                                showHint.toggle()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        
                        Spacer()
                        
                        Button("Checked Solution") {
                            markProblemSolved(problem)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 12)
                    Text("No practice problems found.")
                        .font(.title2)
                        .bold()
                    Text(isExamMode ? "Please create a problem under this module first." : "Create a module and add problems to start interleaving practice.")
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private func loadRandomProblem() {
        let modId = isExamMode ? activeModuleId : nil
        let probs = DatabaseManager.shared.getProblems(forModuleId: modId)
        self.currentProblem = probs.randomElement()
        self.showHint = false
    }
    
    private func markProblemSolved(_ problem: Problem) {
        _ = DatabaseManager.shared.incrementProblemSolvedCount(id: problem.id)
        DatabaseManager.shared.logActivity("interleaving", moduleId: activeModuleId)
        
        loadRandomProblem()
    }
    
    // MARK: - Add Body
    
    private var addBody: some View {
        Form {
            Section(header: Text("Add Practice Problem").font(.headline)) {
                if activeModuleId == nil {
                    Text("Select a module in the sidebar first before adding problems.")
                        .foregroundColor(.red)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Select Topic / Week:", selection: $selectedTopic) {
                            if topics.isEmpty {
                                Text("No topics found. Upload a note to create a week topic.").tag(nil as Topic?)
                            } else {
                                ForEach(topics) { topic in
                                    Text("Week \(topic.week): \(topic.name)").tag(topic as Topic?)
                                }
                            }
                        }
                        .frame(maxWidth: 350)
                        
                        Text("Problem Content:").bold()
                        TextEditor(text: $problemContent)
                            .frame(height: 100)
                            .border(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        
                        Text("Solution Hint:").bold()
                        TextEditor(text: $solutionHint)
                            .frame(height: 100)
                            .border(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        
                        HStack {
                            Spacer()
                            Button("Add Problem") {
                                saveProblem()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedTopic == nil || problemContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
        .padding(25)
    }
    
    private func loadTopics() {
        guard let modId = activeModuleId else {
            self.topics = []
            self.selectedTopic = nil
            return
        }
        self.topics = DatabaseManager.shared.getTopics(forModuleId: modId)
        self.selectedTopic = topics.first
    }
    
    private func saveProblem() {
        guard let topic = selectedTopic else { return }
        let success = DatabaseManager.shared.addProblem(topicId: topic.id, content: problemContent, hint: solutionHint)
        if success {
            problemContent = ""
            solutionHint = ""
            
            let notification = NSUserNotification()
            notification.title = "Problem Added"
            notification.informativeText = "Successfully created practice problem."
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
    
    // MARK: - Manage Body
    
    private var manageBody: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Manage Problems")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                TextField("Search problems...", text: $searchField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onChange(of: searchField) { _ in
                        loadAllProblems()
                    }
            }
            .padding(.horizontal)
            .padding(.top, 15)
            
            List(selection: $selectedProblems) {
                ForEach(allProblems) { prob in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prob.content)
                                .lineLimit(2)
                                .bold()
                            
                            Text("Hint: \(prob.solutionHint)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                                .lineLimit(1)
                            
                            Text("Solved count: \(prob.solvedCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue)
                        }
                        Spacer()
                    }
                }
            }
            .listStyle(.bordered)
            
            HStack {
                Button("Delete Selected") {
                    deleteSelectedProblems()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .disabled(selectedProblems.isEmpty)
                
                Spacer()
            }
            .padding()
        }
    }
    
    private func loadAllProblems() {
        let query = searchField.trimmingCharacters(in: .whitespacesAndNewlines)
        let probs = DatabaseManager.shared.getProblems(forModuleId: activeModuleId)
        
        if query.isEmpty {
            self.allProblems = probs
        } else {
            self.allProblems = probs.filter {
                $0.content.lowercased().contains(query.lowercased()) ||
                $0.solutionHint.lowercased().contains(query.lowercased())
            }
        }
    }
    
    private func deleteSelectedProblems() {
        for probId in selectedProblems {
            _ = DatabaseManager.shared.deleteProblem(id: probId)
        }
        selectedProblems.removeAll()
        loadAllProblems()
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
