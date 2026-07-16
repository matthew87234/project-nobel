import SwiftUI
import WebKit

enum ProblemMode {
    case review
    case add
    case manage
}

enum ProblemAddSubMode {
    case manual
    case aiBatch
}

struct ExtractedProblem: Identifiable, Hashable {
    let id = UUID()
    var content: String
    var solutionHint: String
    var solution: String = ""
    var steps: [String] = []
    var isSelected: Bool = true
}

struct ProblemsView: View {
    let activeModuleId: Int?
    let mode: ProblemMode
    let isExamMode: Bool
    var isActive: Bool = true
    
    // Add Problem State
    @State private var topics: [Topic] = []
    @State private var selectedTopic: Topic?
    @State private var problemContent: String = ""
    @State private var solutionHint: String = ""
    @State private var problemSolution: String = ""
    @State private var problemSteps: [String] = []
    
    // Add Sub-mode selection
    @State private var addSubMode: ProblemAddSubMode = .manual
    
    // AI Batch State
    @State private var pendingQuestions: [PendingExtractionItem] = []
    @State private var pendingAnswers: [PendingExtractionItem] = []
    @State private var showRemoveAlert: Bool = false
    @State private var showAIAssignmentAlert: Bool = false
    @State private var showEditQuestionModal: Bool = false
    @State private var editingStepIndex: Int? = nil
    @State private var showEditStepModal: Bool = false
    @State private var isExtracting: Bool = false
    private var extractedProblems: [ExtractedProblem] {
        aiHelper.sessionExtractedProblems
    }
    @State private var currentExtractionIndex: Int = 0
    @ObservedObject private var aiHelper = AIHelper.shared
    
    // Review State
    @State private var currentProblem: Problem?
    @State private var showHint: Bool = false
    @State private var showSolution: Bool = false
    @State private var prTimerSeconds: Int = 0
    @State private var isTimerActive: Bool = false
    
    let problemsTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    // Manage State
    enum ManageSortOption: String, CaseIterable, Identifiable {
        case date = "Date Created"
        case weekAsc = "Week (Low to High)"
        case weekDesc = "Week (High to Low)"
        
        var id: String { self.rawValue }
    }
    @State private var allProblems: [Problem] = []
    @State private var editingProblemId: Problem.ID? = nil
    @State private var filterWeek: Int = 0
    @State private var editContent: String = ""
    @State private var editHint: String = ""
    @State private var editTopicId: Int = 0
    @State private var editSolution: String = ""
    @State private var editSteps: [String] = []
    @State private var sortOption: ManageSortOption = .date
    
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
            }
        }
        .onChange(of: aiHelper.isClassifyingProblems) { oldValue, newValue in
            if !newValue {
                refreshTopics()
            }
        }
        .onChange(of: editingProblemId) { oldValue, newValue in
            if let id = newValue,
               let prob = allProblems.first(where: { $0.id == id }) {
                editContent = prob.content
                editHint = prob.solutionHint
                editTopicId = prob.topicId
                editSolution = prob.solution
                editSteps = parseSteps(prob.steps)
            } else {
                editContent = ""
                editHint = ""
                editTopicId = 0
                editSolution = ""
                editSteps = []
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
            } else {
                isTimerActive = false
                logActiveSeconds()
            }
        }
        .onDisappear {
            isTimerActive = false
            logActiveSeconds()
        }
        .onReceive(problemsTimer) { _ in
            guard isActive && isTimerActive && mode == .review && currentProblem != nil else { return }
            prTimerSeconds += 1
            if prTimerSeconds % 10 == 0 {
                // Log time to database every 10 seconds
                DatabaseManager.shared.addStudyTime(flashcardsDelta: 0, problemsDelta: 10)
                if let modId = activeModuleId {
                    DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: 0, problemsDelta: 10)
                }
            }
        }
        .alert(isPresented: $showRemoveAlert) {
            Alert(
                title: Text("Remove Extracted Problem"),
                message: Text("Are you sure you want to remove this problem from the extracted list?"),
                primaryButton: .destructive(Text("Remove")) {
                    removeCurrentExtractedProblem()
                },
                secondaryButton: .cancel()
            )
        }
        .alert("AI Week Assignment", isPresented: $showAIAssignmentAlert) {
            Button("All Problems") {
                saveAllImportedProblemsWithAIAssignment()
            }
            Button("Just Current") {
                saveImportedProblemsWithAIAssignment()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Would you like to let AI assign weeks for all imported problems, or just the currently selected one?")
        }
        .sheet(isPresented: $showEditQuestionModal) {
            VStack(spacing: 15) {
                HStack {
                    Text("Edit Question Text").font(.headline)
                    Spacer()
                    Button("Done") {
                        showEditQuestionModal = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top)
                
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Plain Text Editor").font(.caption).bold().foregroundColor(.secondary)
                        if currentExtractionIndex < extractedProblems.count {
                            TextEditor(text: $aiHelper.sessionExtractedProblems[currentExtractionIndex].content)
                                .font(.system(.body, design: .monospaced))
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                    .padding()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live LaTeX Rendering").font(.caption).bold().foregroundColor(.secondary)
                        Group {
                            if currentExtractionIndex < extractedProblems.count {
                                if isLaTeX(extractedProblems[currentExtractionIndex].content) {
                                    LaTeXView(latex: extractedProblems[currentExtractionIndex].content)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    ScrollView {
                                        Text(extractedProblems[currentExtractionIndex].content)
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .border(Color.secondary.opacity(0.15))
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                    .padding()
                }
            }
            .frame(width: 800, height: 600)
        }
        .sheet(isPresented: $showEditStepModal) {
            let stepNum = (editingStepIndex ?? 0) + 1
            VStack(spacing: 15) {
                HStack {
                    Text("Edit Step \(stepNum) Text").font(.headline)
                    Spacer()
                    Button("Done") {
                        showEditStepModal = false
                        editingStepIndex = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top)
                
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Plain Text Editor").font(.caption).bold().foregroundColor(.secondary)
                        if let idx = editingStepIndex, currentExtractionIndex < extractedProblems.count, idx < extractedProblems[currentExtractionIndex].steps.count {
                            TextEditor(text: Binding(
                                get: { extractedProblems[currentExtractionIndex].steps[idx] },
                                set: { newVal in
                                    aiHelper.sessionExtractedProblems[currentExtractionIndex].steps[idx] = newVal
                                }
                            ))
                            .font(.system(.body, design: .monospaced))
                            .border(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    .padding()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live LaTeX Rendering").font(.caption).bold().foregroundColor(.secondary)
                        Group {
                            if let idx = editingStepIndex, currentExtractionIndex < extractedProblems.count, idx < extractedProblems[currentExtractionIndex].steps.count {
                                let stepText = extractedProblems[currentExtractionIndex].steps[idx]
                                if isLaTeX(stepText) {
                                    LaTeXView(latex: stepText)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                } else {
                                    ScrollView {
                                        Text(stepText)
                                            .font(.body)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        .border(Color.secondary.opacity(0.15))
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    .padding()
                }
            }
            .frame(width: 800, height: 500)
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
            loadTopics()
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
                            VStack(alignment: .leading, spacing: 15) {
                                if isLaTeX(problem.content) {
                                    LaTeXView(latex: problem.content)
                                        .frame(minHeight: 160)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(problem.content)
                                        .font(.title3)
                                        .lineSpacing(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                
                                if showSolution {
                                    Divider()
                                        .padding(.vertical, 5)
                                    
                                    VStack(alignment: .leading, spacing: 15) {
                                        let steps = parseSteps(problem.steps)
                                        if !steps.isEmpty {
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("SOLUTION STEPS:")
                                                    .font(.caption)
                                                    .bold()
                                                    .foregroundColor(.blue)
                                                
                                                ForEach(0..<steps.count, id: \.self) { idx in
                                                    HStack(alignment: .top, spacing: 6) {
                                                        Text("\(idx + 1).")
                                                            .bold()
                                                            .foregroundColor(.blue)
                                                            .padding(.top, 2)
                                                        
                                                        if isLaTeX(steps[idx]) {
                                                            LaTeXView(latex: steps[idx])
                                                                .frame(minHeight: 35)
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                        } else {
                                                            Text(steps[idx])
                                                                .font(.body)
                                                                .lineSpacing(2)
                                                                .textSelection(.enabled)
                                                        }
                                                    }
                                                }
                                            }
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.blue.opacity(0.06))
                                            .cornerRadius(12)
                                            .border(Color.blue.opacity(0.15), width: 1)
                                        }
                                    }
                                    .transition(.opacity)
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(12)
                    }
                    
                    HStack(spacing: 15) {
                        Button(showSolution ? "Hide Solution" : "Check Solution") {
                            withAnimation {
                                showSolution.toggle()
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
        self.showSolution = false
    }
    
    private func markProblemSolved(_ problem: Problem) {
        _ = DatabaseManager.shared.incrementProblemSolvedCount(id: problem.id)
        DatabaseManager.shared.logActivity("interleaving", moduleId: activeModuleId)
        
        loadRandomProblem()
    }
    
    // MARK: - Add Body
    
    private var addBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Picker("", selection: $addSubMode) {
                    Text("Manual Entry").tag(ProblemAddSubMode.manual)
                    Text("AI Batch Importer").tag(ProblemAddSubMode.aiBatch)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                
                Spacer()
                
                Picker("Target Topic / Week:", selection: $selectedTopic) {
                    if topics.isEmpty {
                        Text("No topics found").tag(nil as Topic?)
                    } else {
                        ForEach(topics) { topic in
                            Text("Week \(topic.week): \(topic.name)").tag(topic as Topic?)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)
            }
            .padding(.horizontal, 25)
            .padding(.top, 15)
            .padding(.bottom, 10)
            
            Divider()
            
            ScrollView {
                if addSubMode == .manual {
                    manualAddForm
                } else {
                    aiBatchImporterForm
                }
            }
        }
    }
    
    private var manualAddForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            if activeModuleId == nil {
                Text("Select a module in the sidebar first before adding problems.")
                    .foregroundColor(.red)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Problem Content:").bold()
                        TextEditor(text: $problemContent)
                            .frame(height: 100)
                            .border(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        
                        if !problemContent.isEmpty && isLaTeX(problemContent) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Content Live LaTeX Preview:").font(.caption).bold().foregroundColor(.secondary)
                                LaTeXView(latex: problemContent)
                                    .frame(minHeight: 100)
                                    .padding(4)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    

                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Accurate Solution (Optional - AI will generate if empty):").bold()
                        TextEditor(text: $problemSolution)
                            .frame(height: 100)
                            .border(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Multi-step Solution Steps (Optional - AI will generate if empty):").bold()
                            Spacer()
                            Button(action: {
                                problemSteps.append("")
                            }) {
                                Label("Add Step", systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        
                        ForEach(0..<problemSteps.count, id: \.self) { idx in
                            HStack(spacing: 8) {
                                Text("\(idx + 1).")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                TextField("Step instruction...", text: Binding(
                                    get: {
                                        guard idx < problemSteps.count else { return "" }
                                        return problemSteps[idx]
                                    },
                                    set: { newVal in
                                        guard idx < problemSteps.count else { return }
                                        problemSteps[idx] = newVal
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                
                                Button(action: {
                                    problemSteps.remove(at: idx)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    HStack {
                        Spacer()
                        Button("Add Problem") {
                            saveProblem()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(selectedTopic == nil || problemContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(25)
            }
        }
    }
    
    private var aiBatchImporterForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            if activeModuleId == nil {
                Text("Select a module in the sidebar first before adding problems.")
                    .foregroundColor(.red)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    
                    if extractedProblems.isEmpty {
                        VStack(spacing: 20) {
                            // QUESTIONS BOX
                            VStack(alignment: .leading, spacing: 15) {
                                Text("Queue Question Sources:").bold().font(.headline)
                                
                                HStack(spacing: 12) {
                                    Button(action: {
                                        selectFiles(isAnswer: false)
                                    }) {
                                        Label("Select Files", systemImage: "plus.viewfinder")
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button(action: {
                                        pasteClipboardImage(isAnswer: false)
                                    }) {
                                        Label("Paste Image", systemImage: "doc.on.clipboard")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                
                                // Queue display
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Selected Question Items (\(pendingQuestions.count))").bold()
                                    
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            if pendingQuestions.isEmpty {
                                                Text("No question PDFs or images queued yet.")
                                                    .foregroundColor(.secondary)
                                                    .italic()
                                                    .frame(maxWidth: .infinity, alignment: .center)
                                                    .padding(.vertical, 15)
                                            } else {
                                                ForEach(pendingQuestions) { item in
                                                    HStack {
                                                        Image(systemName: item.type == .pdf ? "doc.text" : "photo")
                                                            .foregroundColor(item.type == .pdf ? .blue : .green)
                                                        Text(URL(fileURLWithPath: item.pathOrName).lastPathComponent)
                                                            .lineLimit(1)
                                                        Spacer()
                                                        
                                                        Button(action: {
                                                            previewItem(item)
                                                        }) {
                                                            Image(systemName: "eye")
                                                                .foregroundColor(.secondary)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Preview file in system app")
                                                        
                                                        Button(action: {
                                                            pendingQuestions.removeAll(where: { $0.id == item.id })
                                                        }) {
                                                            Image(systemName: "trash")
                                                                .foregroundColor(.red)
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(Color.secondary.opacity(0.05))
                                                    .cornerRadius(6)
                                                }
                                            }
                                        }
                                    }
                                    .frame(height: 110)
                                    .border(Color.secondary.opacity(0.15))
                                    .cornerRadius(6)
                                }
                            }
                            .padding()
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                            
                            // ANSWERS BOX
                            VStack(alignment: .leading, spacing: 15) {
                                Text("Queue Answer/Solution Sources (Optional):").bold().font(.headline)
                                
                                HStack(spacing: 12) {
                                    Button(action: {
                                        selectFiles(isAnswer: true)
                                    }) {
                                        Label("Select Files", systemImage: "plus.viewfinder")
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button(action: {
                                        pasteClipboardImage(isAnswer: true)
                                    }) {
                                        Label("Paste Image", systemImage: "doc.on.clipboard")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                
                                // Queue display
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Selected Answer Items (\(pendingAnswers.count))").bold()
                                    
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 6) {
                                            if pendingAnswers.isEmpty {
                                                Text("No answer PDFs or images queued yet (AI will solve questions on-demand).")
                                                    .foregroundColor(.secondary)
                                                    .italic()
                                                    .frame(maxWidth: .infinity, alignment: .center)
                                                    .padding(.vertical, 15)
                                            } else {
                                                ForEach(pendingAnswers) { item in
                                                    HStack {
                                                        Image(systemName: item.type == .pdf ? "doc.text" : "photo")
                                                            .foregroundColor(item.type == .pdf ? .blue : .green)
                                                        Text(URL(fileURLWithPath: item.pathOrName).lastPathComponent)
                                                            .lineLimit(1)
                                                        Spacer()
                                                        
                                                        Button(action: {
                                                            previewItem(item)
                                                        }) {
                                                            Image(systemName: "eye")
                                                                .foregroundColor(.secondary)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .help("Preview file in system app")
                                                        
                                                        Button(action: {
                                                            pendingAnswers.removeAll(where: { $0.id == item.id })
                                                        }) {
                                                            Image(systemName: "trash")
                                                                .foregroundColor(.red)
                                                        }
                                                        .buttonStyle(.plain)
                                                    }
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 6)
                                                    .background(Color.secondary.opacity(0.05))
                                                    .cornerRadius(6)
                                                }
                                            }
                                        }
                                    }
                                    .frame(height: 110)
                                    .border(Color.secondary.opacity(0.15))
                                    .cornerRadius(6)
                                }
                            }
                            .padding()
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                            
                            HStack {
                                Spacer()
                                Button("Extract & Match Problems") {
                                    runExtraction()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(pendingQuestions.isEmpty || selectedTopic == nil)
                            }
                        }
                    }
                    
                    if isExtracting {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Local Qwen model is analyzing and transcribing practice problems...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    }
                    
                    if !extractedProblems.isEmpty {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text("Parsed/Extracted Questions").font(.headline)
                                Spacer()
                                Text("Problem \(currentExtractionIndex + 1) of \(extractedProblems.count)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Button(action: {
                                    showEditQuestionModal = true
                                }) {
                                    Image(systemName: "pencil")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.plain)
                                .help("Edit question text in pop-up window")
                                .padding(.trailing, 8)
                                    
                                Button(action: {
                                    showRemoveAlert = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this extracted problem from list")
                            }
                            
                            // Navigation & Selection Row
                            HStack(spacing: 12) {
                                Button(action: {
                                    if currentExtractionIndex > 0 {
                                        currentExtractionIndex -= 1
                                    }
                                }) {
                                    Image(systemName: "chevron.left")
                                    Text("Previous")
                                }
                                .disabled(currentExtractionIndex == 0)
                                
                                Button(action: {
                                    if currentExtractionIndex < extractedProblems.count - 1 {
                                        currentExtractionIndex += 1
                                    }
                                }) {
                                    Text("Next")
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(currentExtractionIndex == extractedProblems.count - 1)
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            
                            if currentExtractionIndex < extractedProblems.count {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Question Preview:").font(.caption).bold()
                                    
                                    if isLaTeX(extractedProblems[currentExtractionIndex].content) {
                                        LaTeXView(latex: extractedProblems[currentExtractionIndex].content)
                                            .frame(minHeight: 120)
                                            .padding(8)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                            )
                                    } else {
                                        Text(extractedProblems[currentExtractionIndex].content)
                                            .font(.body)
                                            .lineSpacing(2)
                                            .padding(12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(8)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                            )
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("Multi-step Solution Steps (Optional - AI will generate if empty):").bold()
                                            Spacer()
                                            Button(action: {
                                                aiHelper.sessionExtractedProblems[currentExtractionIndex].steps.append("")
                                            }) {
                                                Label("Add Step", systemImage: "plus.circle")
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                        
                                         ForEach(0..<extractedProblems[currentExtractionIndex].steps.count, id: \.self) { idx in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("\(idx + 1).")
                                                    .font(.body).bold()
                                                    .foregroundColor(.blue)
                                                    .padding(.top, 4)
                                                
                                                let stepText = extractedProblems[currentExtractionIndex].steps[idx]
                                                if isLaTeX(stepText) {
                                                    LaTeXView(latex: stepText)
                                                        .frame(minHeight: 40)
                                                        .padding(6)
                                                        .background(Color(NSColor.controlBackgroundColor))
                                                        .cornerRadius(6)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 6)
                                                                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                                                        )
                                                } else {
                                                    Text(stepText.isEmpty ? "(Empty step - click edit icon to add text)" : stepText)
                                                        .font(.body)
                                                        .foregroundColor(stepText.isEmpty ? .secondary : .primary)
                                                        .padding(6)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .background(Color(NSColor.controlBackgroundColor))
                                                        .cornerRadius(6)
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 6)
                                                                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                                                        )
                                                }
                                                
                                                Button(action: {
                                                    editingStepIndex = idx
                                                    showEditStepModal = true
                                                }) {
                                                    Image(systemName: "pencil")
                                                        .foregroundColor(.blue)
                                                }
                                                .buttonStyle(.plain)
                                                .help("Edit this step text in pop-up window")
                                                .padding(.top, 4)
                                                
                                                Button(action: {
                                                    aiHelper.sessionExtractedProblems[currentExtractionIndex].steps.remove(at: idx)
                                                }) {
                                                    Image(systemName: "trash")
                                                        .foregroundColor(.red)
                                                }
                                                .buttonStyle(.plain)
                                                .help("Delete this step")
                                                .padding(.top, 4)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }
                                .padding()
                                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                )
                            }
                            
                            HStack(spacing: 12) {
                                Spacer()
                                
                                Button("Import to Week \(selectedTopic?.week ?? 1)") {
                                    saveImportedProblemsToSelectedWeek()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .controlSize(.large)
                                .disabled(selectedTopic == nil)
                                
                                Button("Let AI Assign Weeks") {
                                     showAIAssignmentAlert = true
                                 }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .controlSize(.large)
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(25)
            }
        }
    }
    
    private func selectFiles(isAnswer: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    let item = PendingExtractionItem(type: .pdf, pathOrName: url.path, imageBase64: nil, isAnswerSource: isAnswer, originalPdfPath: url.path)
                    if isAnswer {
                        if !pendingAnswers.contains(where: { $0.pathOrName == url.path }) {
                            pendingAnswers.append(item)
                        }
                    } else {
                        if !pendingQuestions.contains(where: { $0.pathOrName == url.path }) {
                            pendingQuestions.append(item)
                        }
                    }
                } else if ext == "png" || ext == "jpeg" || ext == "jpg" || ext == "tiff" {
                    if let image = NSImage(contentsOf: url),
                       let tiff = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiff),
                       let pngData = bitmap.representation(using: .png, properties: [:]) {
                        let base64Str = pngData.base64EncodedString()
                        let item = PendingExtractionItem(type: .image, pathOrName: url.path, imageBase64: base64Str, isAnswerSource: isAnswer)
                        if isAnswer {
                            if !pendingAnswers.contains(where: { $0.pathOrName == url.path }) {
                                pendingAnswers.append(item)
                            }
                        } else {
                            if !pendingQuestions.contains(where: { $0.pathOrName == url.path }) {
                                pendingQuestions.append(item)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func pasteClipboardImage(isAnswer: Bool) {
        if let image = NSImage(pasteboard: NSPasteboard.general) {
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let base64Str = pngData.base64EncodedString()
                let count = isAnswer ? (pendingAnswers.filter { $0.type == .image }.count + 1) : (pendingQuestions.filter { $0.type == .image }.count + 1)
                let namePrefix = isAnswer ? "Answer Image" : "Question Image"
                let item = PendingExtractionItem(type: .image, pathOrName: "\(namePrefix) \(count)", imageBase64: base64Str, isAnswerSource: isAnswer)
                if isAnswer {
                    pendingAnswers.append(item)
                } else {
                    pendingQuestions.append(item)
                }
            }
        }
    }
    
    private func runExtraction() {
        let groups = aiHelper.pairQuestionsAndAnswers(questions: pendingQuestions, answers: pendingAnswers)
        
        pendingQuestions = []
        pendingAnswers = []
        
        aiHelper.queueGroupsForExtraction(groups: groups)
    }
    
    private func previewItem(_ item: PendingExtractionItem) {
        if item.type == .pdf {
            let url = URL(fileURLWithPath: item.pathOrName)
            NSWorkspace.shared.open(url)
        } else if item.type == .image {
            if item.pathOrName.starts(with: "/") {
                let url = URL(fileURLWithPath: item.pathOrName)
                NSWorkspace.shared.open(url)
            } else if let base64 = item.imageBase64,
                      let data = Data(base64Encoded: base64) {
                let tempDir = FileManager.default.temporaryDirectory
                let safeName = item.pathOrName.replacingOccurrences(of: " ", with: "_")
                let tempURL = tempDir.appendingPathComponent("\(safeName).png")
                do {
                    try data.write(to: tempURL)
                    NSWorkspace.shared.open(tempURL)
                } catch {
                    print("Failed to write preview image: \(error)")
                }
            }
        }
    }
    
    private func saveImportedProblemsToSelectedWeek() {
        guard let topic = selectedTopic else { return }
        guard currentExtractionIndex < extractedProblems.count else { return }
        let prob = extractedProblems[currentExtractionIndex]
        guard !prob.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        let content = prob.content
        let hint = prob.solutionHint
        var sol = prob.solution
        var steps = prob.steps
        
        // Remove current problem immediately
        aiHelper.sessionExtractedProblems.remove(at: currentExtractionIndex)
        
        // Adjust current index
        if extractedProblems.isEmpty {
            currentExtractionIndex = 0
        } else if currentExtractionIndex >= extractedProblems.count {
            currentExtractionIndex = extractedProblems.count - 1
        }
        
        Task {
            if sol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sol = await AIHelper.shared.generateProblemSolution(content: content)
            }
            
            if steps.isEmpty {
                steps = await AIHelper.shared.generateProblemSteps(content: content, solution: sol)
            }
            
            let stepsStr = encodeSteps(steps)
            let success = DatabaseManager.shared.addProblem(
                topicId: topic.id,
                content: content,
                hint: hint,
                solution: sol,
                steps: stepsStr
            )
            
            if success {
                DispatchQueue.main.async {
                    let notification = NSUserNotification()
                    notification.title = "Problem Imported"
                    notification.informativeText = "Successfully imported practice problem to Week \(topic.week)."
                    NSUserNotificationCenter.default.deliver(notification)
                    refreshTopics()
                }
            }
        }
    }
    
    private func saveImportedProblemsWithAIAssignment() {
        guard let moduleId = activeModuleId else { return }
        guard currentExtractionIndex < extractedProblems.count else { return }
        let prob = extractedProblems[currentExtractionIndex]
        guard !prob.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // Queue the problem for classification and background generation in the background
        AIHelper.shared.queueProblemForClassification(
            content: prob.content,
            solutionHint: prob.solutionHint,
            moduleId: moduleId,
            solution: prob.solution,
            steps: prob.steps
        )
        
        // Remove current problem immediately
        aiHelper.sessionExtractedProblems.remove(at: currentExtractionIndex)
        
        // Adjust current index
        if extractedProblems.isEmpty {
            currentExtractionIndex = 0
        } else if currentExtractionIndex >= extractedProblems.count {
            currentExtractionIndex = extractedProblems.count - 1
        }
    }
    
    private func saveAllImportedProblemsWithAIAssignment() {
        guard let moduleId = activeModuleId else { return }
        let problemsToAssign = extractedProblems
        for prob in problemsToAssign {
            guard !prob.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            AIHelper.shared.queueProblemForClassification(
                content: prob.content,
                solutionHint: prob.solutionHint,
                moduleId: moduleId,
                solution: prob.solution,
                steps: prob.steps
            )
        }
        
        // Clear all problems from session
        aiHelper.sessionExtractedProblems.removeAll()
        currentExtractionIndex = 0
    }
    
    private func refreshTopics() {
        guard let modId = activeModuleId else { return }
        self.topics = DatabaseManager.shared.getTopics(forModuleId: modId)
        if self.selectedTopic == nil {
            self.selectedTopic = self.topics.first
        }
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
        let content = problemContent
        let hint = solutionHint
        var sol = problemSolution
        var steps = problemSteps
        
        problemContent = ""
        solutionHint = ""
        problemSolution = ""
        problemSteps = []
        
        Task {
            if sol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sol = await AIHelper.shared.generateProblemSolution(content: content)
            }
            
            if steps.isEmpty {
                steps = await AIHelper.shared.generateProblemSteps(content: content, solution: sol)
            }
            
            let stepsStr = encodeSteps(steps)
            let success = DatabaseManager.shared.addProblem(
                topicId: topic.id,
                content: content,
                hint: hint,
                solution: sol,
                steps: stepsStr
            )
            
            if success {
                DispatchQueue.main.async {
                    let notification = NSUserNotification()
                    notification.title = "Problem Added"
                    notification.informativeText = "Successfully created practice problem."
                    NSUserNotificationCenter.default.deliver(notification)
                }
            }
        }
    }
    
    // MARK: - Manage Body
    
    private var manageBody: some View {
        HStack(spacing: 0) {
            // Left Pane: List of problems and filters
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Problems")
                            .font(.title2)
                            .bold()
                        
                        Spacer()
                        
                        Picker("Filter:", selection: $filterWeek) {
                            Text("All Weeks").tag(0)
                            ForEach(availableWeeks, id: \.self) { wk in
                                Text("Week \(wk)").tag(wk)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 130)
                        .onChange(of: filterWeek) { oldValue, newValue in
                            loadAllProblems()
                        }
                    }
                    
                    Picker("Sort by:", selection: $sortOption) {
                        ForEach(ManageSortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: sortOption) { oldValue, newValue in
                        loadAllProblems()
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 15)
                .padding(.bottom, 10)
                
                Divider()
                
                List(selection: $editingProblemId) {
                    ForEach(allProblems) { prob in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(prob.content)
                                    .lineLimit(2)
                                    .bold()
                                
                                Spacer()
                                
                                if let week = getWeekNumber(for: prob.topicId) {
                                    Text("W\(week)")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundColor(.blue)
                                        .cornerRadius(3)
                                }
                            }
                            
                            Text(prob.solutionHint.isEmpty ? "No hint" : prob.solutionHint)
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        .tag(prob.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 280)
            
            Divider()
            
            // Right Pane: Detailed Problem Editor
            VStack {
                if let probId = editingProblemId,
                   let _ = allProblems.first(where: { $0.id == probId }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 15) {
                            Text("Edit Practice Problem")
                                .font(.title3)
                                .bold()
                                .padding(.bottom, 5)
                            
                            Text("Question Text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .bold()
                            
                            TextEditor(text: $editContent)
                                .frame(height: 120)
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                            

                            Text("Accurate Solution")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .bold()
                            
                            TextEditor(text: $editSolution)
                                .frame(height: 100)
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Multi-step Solution Steps:").bold()
                                    Spacer()
                                    Button(action: {
                                        editSteps.append("")
                                    }) {
                                        Label("Add Step", systemImage: "plus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                
                                ForEach(0..<editSteps.count, id: \.self) { idx in
                                    HStack(spacing: 8) {
                                        Text("\(idx + 1).")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        
                                        TextField("Step instruction...", text: Binding(
                                            get: {
                                                guard idx < editSteps.count else { return "" }
                                                return editSteps[idx]
                                            },
                                            set: { newVal in
                                                guard idx < editSteps.count else { return }
                                                editSteps[idx] = newVal
                                            }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        
                                        Button(action: {
                                            editSteps.remove(at: idx)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            
                            Text("Assigned Topic (Week)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .bold()
                            
                            Picker("Topic:", selection: $editTopicId) {
                                ForEach(topics) { topic in
                                    Text("Week \(topic.week): \(topic.name)").tag(topic.id)
                                }
                            }
                            .pickerStyle(.menu)
                            
                            HStack(spacing: 12) {
                                Button("Save Changes") {
                                    saveProblemEdits(probId: probId)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                
                                Button("Delete Problem") {
                                    deleteProblem(id: probId)
                                }
                                .buttonStyle(.bordered)
                                .foregroundColor(.red)
                                
                                Spacer()
                            }
                            .padding(.top, 10)
                        }
                        .padding(20)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "pencil.and.outline")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Select a problem to edit")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
    
    private func getWeekNumber(for topicId: Int) -> Int? {
        return self.topics.first(where: { $0.id == topicId })?.week
    }
    
    private var availableWeeks: [Int] {
        Array(Set(topics.map { $0.week })).sorted()
    }
    
    private func loadAllProblems() {
        let probs = DatabaseManager.shared.getProblems(forModuleId: activeModuleId)
        
        var filteredProbs: [Problem]
        if filterWeek == 0 {
            filteredProbs = probs
        } else {
            filteredProbs = probs.filter { getWeekNumber(for: $0.topicId) == filterWeek }
        }
        
        switch sortOption {
        case .date:
            self.allProblems = filteredProbs
        case .weekAsc:
            self.allProblems = filteredProbs.sorted { p1, p2 in
                let w1 = getWeekNumber(for: p1.topicId) ?? 0
                let w2 = getWeekNumber(for: p2.topicId) ?? 0
                return w1 < w2
            }
        case .weekDesc:
            self.allProblems = filteredProbs.sorted { p1, p2 in
                let w1 = getWeekNumber(for: p1.topicId) ?? 0
                let w2 = getWeekNumber(for: p2.topicId) ?? 0
                return w1 > w2
            }
        }
    }
    
    private func saveProblemEdits(probId: Int) {
        let stepsStr = encodeSteps(editSteps)
        let success = DatabaseManager.shared.updateProblem(
            id: probId,
            topicId: editTopicId,
            content: editContent,
            hint: editHint,
            solution: editSolution,
            steps: stepsStr
        )
        if success {
            let notification = NSUserNotification()
            notification.title = "Problem Updated"
            notification.informativeText = "Successfully saved modifications."
            NSUserNotificationCenter.default.deliver(notification)
            loadAllProblems()
        }
    }
    
    private func deleteProblem(id: Int) {
        let success = DatabaseManager.shared.deleteProblem(id: id)
        if success {
            let notification = NSUserNotification()
            notification.title = "Problem Deleted"
            notification.informativeText = "Successfully deleted practice problem."
            NSUserNotificationCenter.default.deliver(notification)
            
            editingProblemId = nil
            loadAllProblems()
        }
    }
    private func removeCurrentExtractedProblem() {
        guard currentExtractionIndex < extractedProblems.count else { return }
        aiHelper.sessionExtractedProblems.remove(at: currentExtractionIndex)
        if extractedProblems.isEmpty {
            currentExtractionIndex = 0
        } else if currentExtractionIndex >= extractedProblems.count {
            currentExtractionIndex = extractedProblems.count - 1
        }
    }
    
    private func parseSteps(_ jsonStr: String) -> [String] {
        guard let data = jsonStr.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    
    private func encodeSteps(_ steps: [String]) -> String {
        guard let data = try? JSONEncoder().encode(steps) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
