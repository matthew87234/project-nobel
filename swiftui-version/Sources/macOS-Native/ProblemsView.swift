import SwiftUI
import Charts
import WebKit
import UniformTypeIdentifiers
import Combine
@preconcurrency import UserNotifications

enum ActiveProblemChartPopup: String, Identifiable {
    case dueProjection = "Interleaving Review Schedule"
    case flaggedBreakdown = "Flagged Problems Status"
    case severityDistribution = "Problem Mastery & Severity Levels"
    case topicDistribution = "Problem Count per Topic / Week"
    
    var id: String { self.rawValue }
}

private func sendAppNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}

private func calcLaTeXMinHeight(_ text: String) -> CGFloat {
    let lines = text.components(separatedBy: .newlines).count
    let hasDisplayMath = text.contains("$$") || text.contains("\\[")
    let displayMathCount = max(0, text.components(separatedBy: "$$").count - 1)
    let calculated = CGFloat(lines * 28 + (hasDisplayMath ? max(1, displayMathCount) * 55 : 25))
    return max(60, min(800, calculated))
}

enum ReviewSubMode {
    case centre
    case practice
}

enum ProblemPreset: String, CaseIterable, Identifiable {
    case five = "5 Problems"
    case ten = "10 Problems"
    case fifteen = "15 Problems"
    case custom = "Custom"
    
    var id: String { self.rawValue }
    var baseCount: Int {
        switch self {
        case .five: return 5
        case .ten: return 10
        case .fifteen: return 15
        case .custom: return 10
        }
    }
}

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

@MainActor
struct ProblemsView: View {
    let activeModuleId: Int?
    var activeYear: Int = 1
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
    
    // Flagged Correction State
    @State private var isCorrectingFlaggedProblems: Bool = false
    @State private var flaggedCorrectionQueue: [Problem] = []
    @State private var flaggedProblemIdx: Int = 0
    
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
    
    // Review State & Problem Centre
    @State private var activeProblemChartPopup: ActiveProblemChartPopup? = nil
    @State private var reviewSubMode: ReviewSubMode = .centre
    @State private var selectedPreset: ProblemPreset = .ten
    @State private var customProblemCount: Int = 10
    @State private var targetProblemCount: Int = 10
    @State private var problemsSolvedInSession: Int = 0
    @State private var markedFailedStep: Int = 0
    @State private var dueProblems: [Problem] = []
    @State private var currentDueProblemIdx: Int = 0
    
    @State private var currentProblem: Problem?
    @State private var showHint: Bool = false
    @State private var showSolution: Bool = false
    @State private var revealedStepCount: Int = 0
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
    
    @ViewBuilder
    private func problemChartPopupSheet(for popup: ActiveProblemChartPopup) -> some View {
        let targetModId = isExamMode ? activeModuleId : nil
        let targetYear = isExamMode ? nil : activeYear
        
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(popup.rawValue)
                        .font(.title2)
                        .bold()
                    Text("Interactive visual analytics for your interleaving problems")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    activeProblemChartPopup = nil
                }
                .buttonStyle(.borderedProminent)
            }
            
            Divider()
            
            switch popup {
            case .dueProjection:
                ProblemDueProjectionChartView(moduleId: targetModId, year: targetYear)
            case .flaggedBreakdown:
                ProblemFlaggedChartView(moduleId: targetModId, year: targetYear)
            case .severityDistribution:
                ProblemSeverityChartView(moduleId: targetModId, year: targetYear)
            case .topicDistribution:
                ProblemTopicChartView(moduleId: targetModId, year: targetYear)
            }
        }
        .padding(24)
        .frame(width: 680, height: 500)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .review:
                if reviewSubMode == .centre {
                    problemCentreBody
                } else {
                    reviewBody
                }
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
        .sheet(item: $activeProblemChartPopup) { popup in
            problemChartPopupSheet(for: popup)
        }
        .sheet(isPresented: $showEditQuestionModal) {
            VStack(spacing: 15) {
                HStack {
                    Text("Edit Practice Problem & Steps").font(.headline)
                    Spacer()
                    Button("Done") {
                        showEditQuestionModal = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Question Text")
                            .font(.caption)
                            .bold()
                            .foregroundColor(.secondary)
                        
                        if currentExtractionIndex < extractedProblems.count {
                            TextEditor(text: $aiHelper.sessionExtractedProblems[currentExtractionIndex].content)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 120)
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                            
                            if isLaTeX(extractedProblems[currentExtractionIndex].content) {
                                Text("Live LaTeX Preview:")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.secondary)
                                LaTeXView(latex: extractedProblems[currentExtractionIndex].content)
                                    .frame(minHeight: 80)
                                    .padding(8)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                    .border(Color.secondary.opacity(0.15))
                            }
                            
                            Divider().padding(.vertical, 4)
                            
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("Multi-step Solution Steps:").bold()
                                    Spacer()
                                    Button(action: {
                                        aiHelper.sessionExtractedProblems[currentExtractionIndex].steps.append("")
                                    }) {
                                        Label("Add Step", systemImage: "plus.circle")
                                    }
                                    .buttonStyle(.bordered)
                                }
                                
                                ForEach(0..<extractedProblems[currentExtractionIndex].steps.count, id: \.self) { idx in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(idx + 1).")
                                            .font(.caption)
                                            .bold()
                                            .foregroundColor(.secondary)
                                            .padding(.top, 6)
                                        
                                        TextField("Step instruction / equation...", text: Binding(
                                            get: {
                                                guard idx < extractedProblems[currentExtractionIndex].steps.count else { return "" }
                                                return extractedProblems[currentExtractionIndex].steps[idx]
                                            },
                                            set: { newVal in
                                                guard idx < extractedProblems[currentExtractionIndex].steps.count else { return }
                                                aiHelper.sessionExtractedProblems[currentExtractionIndex].steps[idx] = newVal
                                            }
                                        ), axis: .vertical)
                                        .lineLimit(2...6)
                                        .textFieldStyle(.roundedBorder)
                                        
                                        Button(action: {
                                            aiHelper.sessionExtractedProblems[currentExtractionIndex].steps.remove(at: idx)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.top, 6)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
            .frame(width: 700, height: 600)
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
    
    // MARK: - Review Body & Problem Centre
    
    private var problemCentreBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RatioTrackerBar(isExamMode: isExamMode)
                
                let targetModId = isExamMode ? activeModuleId : nil
                let targetYear = isExamMode ? nil : activeYear
                let modProblems = DatabaseManager.shared.getProblems(forYear: targetYear, forModuleId: targetModId)
                let dueList = modProblems.filter { p in
                    if p.nextReviewDate.isEmpty { return true }
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    let todayStr = formatter.string(from: Date())
                    return p.nextReviewDate <= todayStr
                }
                let flaggedList = modProblems.filter { $0.isFlagged }
                let masteredCount = modProblems.filter { $0.severityLevel >= 3 }.count
                let masteryPercent = modProblems.isEmpty ? 100 : Int(Double(masteredCount) / Double(modProblems.count) * 100)
                
                // Statistics Grid (Clickable Chart Metric Cards)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricCardView(
                        title: "Due Interleaving",
                        value: "\(dueList.count)",
                        subtitle: "Ready for practice",
                        color: .blue,
                        onClick: { activeProblemChartPopup = .dueProjection }
                    )
                    MetricCardView(
                        title: "Flagged Problems",
                        value: "\(flaggedList.count)",
                        subtitle: "Items marked for edit",
                        color: .purple,
                        onClick: { activeProblemChartPopup = .flaggedBreakdown }
                    )
                    MetricCardView(
                        title: "Mastery Rate",
                        value: "\(masteryPercent)%",
                        subtitle: "\(masteredCount) of \(modProblems.count) mastered",
                        color: .green,
                        onClick: { activeProblemChartPopup = .severityDistribution }
                    )
                    MetricCardView(
                        title: "Total Problems",
                        value: "\(modProblems.count)",
                        subtitle: isExamMode ? "In active module" : "Across Year \(activeYear) modules",
                        color: .orange,
                        onClick: { activeProblemChartPopup = .topicDistribution }
                    )
                }
                
                // Session Setup & Target Count Presets
                VStack(alignment: .leading, spacing: 16) {
                    Text("Session Problem Presets").font(.title3).bold()
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ProblemPreset.allCases) { preset in
                            let count = (preset == .custom) ? customProblemCount : preset.baseCount
                            
                            VStack(spacing: 8) {
                                Text("\(count) Problems")
                                    .font(.headline)
                                    .bold()
                                Text(preset == .custom ? "Custom Target" : "Preset Batch")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity)
                            .background(selectedPreset == preset ? Color.blue.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(selectedPreset == preset ? Color.blue : Color.secondary.opacity(0.15), lineWidth: selectedPreset == preset ? 2 : 1)
                            )
                            .pointingHandCursor()
                            .onTapGesture {
                                selectedPreset = preset
                            }
                        }
                    }
                    
                    if selectedPreset == .custom {
                        HStack {
                            Text("Custom Problem Count: \(customProblemCount)")
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            Stepper("", value: $customProblemCount, in: 1...50)
                                .labelsHidden()
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    
                    if dueList.isEmpty && !modProblems.isEmpty {
                        VStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.title3)
                                Text("All Caught Up for Today")
                                    .font(.headline)
                                    .foregroundColor(.green)
                                Spacer()
                                Text("\(modProblems.count) Total Problems")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(12)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                            
                            Button(action: {
                                startNewProblemSession(studyAhead: true)
                            }) {
                                HStack {
                                    Spacer()
                                    Image(systemName: "bolt.fill")
                                    let targetCount = selectedPreset == .custom ? customProblemCount : selectedPreset.baseCount
                                    Text("Study Ahead (\(min(targetCount, modProblems.count)) Problems • Extra Practice)")
                                        .font(.headline)
                                        .bold()
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .controlSize(.large)
                            .pointingHandCursor()
                        }
                    } else {
                        Button(action: {
                            startNewProblemSession(studyAhead: false)
                        }) {
                            HStack {
                                Spacer()
                                Image(systemName: "play.fill")
                                let targetCount = selectedPreset == .custom ? customProblemCount : selectedPreset.baseCount
                                Text("Start Interleaving Session (\(min(targetCount, dueList.count)) of \(dueList.count) Due)")
                                    .font(.headline)
                                    .bold()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .controlSize(.large)
                        .pointingHandCursor()
                        .disabled(modProblems.isEmpty)
                    }
                }
                .padding(20)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                
                // Diagnostic Severity Breakdown
                VStack(alignment: .leading, spacing: 12) {
                    Text("Diagnostic Error Breakdown").font(.headline)
                    
                    let level1Count = modProblems.filter { $0.lastFailedStep == 1 }.count
                    let level2Count = modProblems.filter { $0.lastFailedStep == 2 }.count
                    let level3Count = modProblems.filter { $0.lastFailedStep >= 3 }.count
                    let level4Count = modProblems.filter { $0.lastFailedStep == 0 && $0.solvedCount > 0 }.count
                    
                    HStack(spacing: 12) {
                        HStack {
                            Circle().fill(Color.red).frame(width: 10, height: 10)
                            Text("Step 1 Setup Errors: \(level1Count)").font(.caption).bold()
                        }
                        Spacer()
                        HStack {
                            Circle().fill(Color.orange).frame(width: 10, height: 10)
                            Text("Step 2 Math Errors: \(level2Count)").font(.caption).bold()
                        }
                        Spacer()
                        HStack {
                            Circle().fill(Color.yellow).frame(width: 10, height: 10)
                            Text("Step 3+ Slips: \(level3Count)").font(.caption).bold()
                        }
                        Spacer()
                        HStack {
                            Circle().fill(Color.green).frame(width: 10, height: 10)
                            Text("Flawless Solved: \(level4Count)").font(.caption).bold()
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            .padding(25)
        }
    }
    
    private func startNewProblemSession(studyAhead: Bool = false) {
        let today = formatDate(Date())
        let targetModId = isExamMode ? activeModuleId : nil
        let targetYear = isExamMode ? nil : activeYear
        
        let pool: [Problem]
        if studyAhead {
            pool = DatabaseManager.shared.getProblems(forYear: targetYear, forModuleId: targetModId)
        } else {
            let dueList = DatabaseManager.shared.getDueProblems(forYear: targetYear, forModuleId: targetModId, today: today)
            pool = dueList
        }
        
        let count = (selectedPreset == .custom) ? customProblemCount : selectedPreset.baseCount
        self.targetProblemCount = count
        
        let sorted = pool.sorted { p1, p2 in
            if p1.severityLevel != p2.severityLevel {
                return p1.severityLevel < p2.severityLevel
            }
            return p1.nextReviewDate < p2.nextReviewDate
        }
        
        self.dueProblems = Array(sorted.prefix(count))
        self.currentDueProblemIdx = 0
        self.problemsSolvedInSession = 0
        self.markedFailedStep = 0
        
        if let firstProb = self.dueProblems.first {
            self.currentProblem = firstProb
            self.showHint = false
            self.showSolution = false
            self.revealedStepCount = 0
            self.reviewSubMode = .practice
        }
    }
    
    private var reviewBody: some View {
        VStack(spacing: 15) {
            RatioTrackerBar(isExamMode: isExamMode)
                .padding(.horizontal)
                .padding(.top, 10)
            
            HStack {
                Button(action: {
                    reviewSubMode = .centre
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Problem Centre")
                    }
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                
                Spacer()
                
                if !dueProblems.isEmpty && currentDueProblemIdx < dueProblems.count {
                    Text("Problem \(currentDueProblemIdx + 1) of \(dueProblems.count)")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            if let problem = currentProblem {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Interleaving Problem Practice")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: {
                            let newFlag = !problem.isFlagged
                            _ = DatabaseManager.shared.setProblemFlagged(id: problem.id, isFlagged: newFlag)
                            let modId = isExamMode ? activeModuleId : nil
                            let probs = DatabaseManager.shared.getProblems(forModuleId: modId)
                            if let updated = probs.first(where: { $0.id == problem.id }) {
                                self.currentProblem = updated
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: problem.isFlagged ? "flag.fill" : "flag")
                                    .foregroundColor(problem.isFlagged ? .purple : .secondary)
                                Text(problem.isFlagged ? "Flagged" : "Flag")
                                    .font(.caption)
                                    .foregroundColor(problem.isFlagged ? .purple : .secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(problem.isFlagged ? Color.purple.opacity(0.12) : Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Flag this problem for later review/correction in Add Problems section")
                    }
                    
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
                                
                                let steps = parseSteps(problem.steps)
                                let totalSteps = steps.count
                                let isShowingSteps = !steps.isEmpty ? (revealedStepCount > 0) : showSolution
                                
                                if isShowingSteps {
                                    Divider()
                                        .padding(.vertical, 5)
                                    
                                    VStack(alignment: .leading, spacing: 12) {
                                        if !steps.isEmpty {
                                            VStack(alignment: .leading, spacing: 10) {
                                                Text("SOLUTION STEPS (\(min(revealedStepCount, totalSteps)) OF \(totalSteps)):")
                                                    .font(.caption)
                                                    .bold()
                                                    .foregroundColor(.blue)
                                                
                                                ForEach(0..<min(revealedStepCount, totalSteps), id: \.self) { idx in
                                                    let stepNum = idx + 1
                                                    let isErrorStep = (markedFailedStep == stepNum)
                                                    StepRowPracticeView(
                                                        stepNum: stepNum,
                                                        stepText: steps[idx],
                                                        isErrorStep: isErrorStep,
                                                        onToggleError: {
                                                            if markedFailedStep == stepNum {
                                                                markedFailedStep = 0
                                                            } else {
                                                                markedFailedStep = stepNum
                                                            }
                                                        }
                                                    )
                                                }
                                            }
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.blue.opacity(0.04))
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                            )
                                        } else if !problem.solution.isEmpty {
                                            let sol = problem.solution
                                            VStack(alignment: .leading, spacing: 8) {
                                                Text("SOLUTION:")
                                                    .font(.caption)
                                                    .bold()
                                                    .foregroundColor(.blue)
                                                
                                                if isLaTeX(sol) {
                                                    LaTeXView(latex: sol)
                                                        .frame(minHeight: calcLaTeXMinHeight(sol))
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                } else {
                                                    Text(sol)
                                                        .font(.body)
                                                        .lineSpacing(4)
                                                        .textSelection(.enabled)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                            }
                                            .padding()
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.blue.opacity(0.04))
                                            .cornerRadius(12)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                            )
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
                        let steps = parseSteps(problem.steps)
                        let totalSteps = steps.count
                        let isAllRevealed = !steps.isEmpty ? (revealedStepCount >= totalSteps) : showSolution
                        
                        Button(isAllRevealed ? "Hide Solution" : "Show Step of the Solution") {
                            withAnimation {
                                if steps.isEmpty {
                                    showSolution.toggle()
                                } else {
                                    if revealedStepCount < totalSteps {
                                        revealedStepCount += 1
                                    } else {
                                        revealedStepCount = 0
                                    }
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .pointingHandCursor()
                        
                        Spacer()
                        
                        Button("Completed") {
                            let steps = parseSteps(problem.steps)
                            _ = DatabaseManager.shared.recordProblemPracticeResult(id: problem.id, failedStep: markedFailedStep, totalSteps: steps.count)
                            
                            problemsSolvedInSession += 1
                            markedFailedStep = 0
                            
                            if currentDueProblemIdx < dueProblems.count - 1 {
                                currentDueProblemIdx += 1
                                currentProblem = dueProblems[currentDueProblemIdx]
                                showHint = false
                                showSolution = false
                                revealedStepCount = 0
                            } else {
                                reviewSubMode = .centre
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(markedFailedStep > 0 ? .orange : .green)
                        .controlSize(.large)
                        .pointingHandCursor()
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
        let today = formatDate(Date())
        let targetModId = isExamMode ? activeModuleId : nil
        let targetYear = isExamMode ? nil : activeYear
        let dueProbs = DatabaseManager.shared.getDueProblems(forYear: targetYear, forModuleId: targetModId, today: today)
        if let randomDue = dueProbs.randomElement() {
            self.currentProblem = randomDue
        } else {
            let allProbs = DatabaseManager.shared.getProblems(forYear: targetYear, forModuleId: targetModId)
            self.currentProblem = allProbs.randomElement()
        }
        self.showHint = false
        self.showSolution = false
        self.revealedStepCount = 0
    }
    
    private func markProblemSolved(_ problem: Problem) {
        _ = DatabaseManager.shared.incrementProblemSolvedCount(id: problem.id)
        DatabaseManager.shared.logActivity("interleaving", moduleId: activeModuleId)
        
        loadRandomProblem()
    }
    
    private func setupFlaggedCorrectionQueue() {
        let allProbs = DatabaseManager.shared.getProblems(forModuleId: activeModuleId)
        let flagged = allProbs.filter { $0.isFlagged }
        self.flaggedCorrectionQueue = flagged
        self.flaggedProblemIdx = 0
        if !flagged.isEmpty {
            let p = flagged[0]
            self.problemContent = p.content
            self.solutionHint = p.solutionHint
            self.problemSolution = p.solution
            let rawSteps = p.steps.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            self.problemSteps = rawSteps
            if let t = topics.first(where: { $0.id == p.topicId }) {
                self.selectedTopic = t
            }
            self.isCorrectingFlaggedProblems = true
        }
    }
    
    private func saveAndAdvanceFlaggedProblem(unflag: Bool, problemId: Int) {
        guard let topic = selectedTopic else { return }
        let stepStr = problemSteps.joined(separator: "\n\n")
        _ = DatabaseManager.shared.updateProblem(id: problemId, topicId: topic.id, content: problemContent, hint: solutionHint, solution: problemSolution, steps: stepStr)
        if unflag {
            _ = DatabaseManager.shared.setProblemFlagged(id: problemId, isFlagged: false)
        }
        
        let allProbs = DatabaseManager.shared.getProblems(forModuleId: activeModuleId)
        let flaggedRemaining = allProbs.filter { $0.isFlagged }
        self.flaggedCorrectionQueue = flaggedRemaining
        
        if flaggedProblemIdx < flaggedRemaining.count {
            let p = flaggedRemaining[flaggedProblemIdx]
            self.problemContent = p.content
            self.solutionHint = p.solutionHint
            self.problemSolution = p.solution
            self.problemSteps = p.steps.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let t = topics.first(where: { $0.id == p.topicId }) {
                self.selectedTopic = t
            }
        } else if !flaggedRemaining.isEmpty {
            self.flaggedProblemIdx = 0
            let p = flaggedRemaining[0]
            self.problemContent = p.content
            self.solutionHint = p.solutionHint
            self.problemSolution = p.solution
            self.problemSteps = p.steps.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let t = topics.first(where: { $0.id == p.topicId }) {
                self.selectedTopic = t
            }
        } else {
            self.isCorrectingFlaggedProblems = false
            self.problemContent = ""
            self.solutionHint = ""
            self.problemSolution = ""
            self.problemSteps = []
        }
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
                
                let flaggedRemaining = DatabaseManager.shared.getProblems(forModuleId: activeModuleId).filter { $0.isFlagged }
                if !flaggedRemaining.isEmpty && !isCorrectingFlaggedProblems {
                    Button(action: {
                        setupFlaggedCorrectionQueue()
                    }) {
                        Label("Review Flagged Problems (\(flaggedRemaining.count))", systemImage: "flag.fill")
                            .foregroundColor(.purple)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                }
                
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
                if isCorrectingFlaggedProblems {
                    flaggedCorrectionForm
                } else if addSubMode == .manual {
                    manualAddForm
                } else {
                    aiBatchImporterForm
                }
            }
        }
    }
    
    private var flaggedCorrectionForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            if flaggedProblemIdx < flaggedCorrectionQueue.count {
                let problem = flaggedCorrectionQueue[flaggedProblemIdx]
                
                HStack {
                    Image(systemName: "flag.fill").foregroundColor(.purple).font(.title2)
                    Text("Correcting Flagged Problem (\(flaggedProblemIdx + 1) of \(flaggedCorrectionQueue.count))")
                        .font(.headline)
                        .foregroundColor(.purple)
                    
                    Spacer()
                    
                    Button("Skip to Create New Problems") {
                        isCorrectingFlaggedProblems = false
                        problemContent = ""
                        solutionHint = ""
                        problemSolution = ""
                        problemSteps = []
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                }
                .padding(12)
                .background(Color.purple.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                )
                
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Problem Content / Question:").bold()
                        TextEditor(text: $problemContent)
                            .frame(height: 90)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Solution Hint (Optional):").bold()
                        TextEditor(text: $solutionHint)
                            .frame(height: 50)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Solution / Steps:").bold()
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(0..<problemSteps.count, id: \.self) { idx in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(idx + 1).").bold().foregroundColor(.purple).padding(.top, 4)
                                    TextField("Step \(idx + 1)...", text: $problemSteps[idx], axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(2...6)
                                    Button(action: {
                                        problemSteps.remove(at: idx)
                                    }) {
                                        Image(systemName: "trash").foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                }
                            }
                            
                            Button(action: {
                                problemSteps.append("")
                            }) {
                                Label("Add Step", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .pointingHandCursor()
                        }
                    }
                    
                    // Live LaTeX Preview
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live LaTeX Preview:").bold()
                        VStack(alignment: .leading, spacing: 10) {
                            if isLaTeX(problemContent) {
                                LaTeXView(latex: problemContent)
                                    .frame(minHeight: calcLaTeXMinHeight(problemContent))
                            } else {
                                Text(problemContent)
                                    .font(.body)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    }
                    
                    HStack(spacing: 12) {
                        Spacer()
                        
                        Button("Keep Flagged & Next") {
                            saveAndAdvanceFlaggedProblem(unflag: false, problemId: problem.id)
                        }
                        .buttonStyle(.bordered)
                        .pointingHandCursor()
                        
                        Button("Save & Unflag") {
                            saveAndAdvanceFlaggedProblem(unflag: true, problemId: problem.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .pointingHandCursor()
                        .disabled(problemContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedTopic == nil)
                    }
                    .padding(.top, 10)
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .padding(25)
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
                            .pointingHandCursor()
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
                                .pointingHandCursor()
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
                        .pointingHandCursor()
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
                        BatchImporterQueueView(
                            pendingQuestions: $pendingQuestions,
                            pendingAnswers: $pendingAnswers,
                            selectedTopic: selectedTopic,
                            onSelectFiles: { isAnswer in selectFiles(isAnswer: isAnswer) },
                            onPasteClipboardImage: { isAnswer in pasteClipboardImage(isAnswer: isAnswer) },
                            onDropFiles: { urls, isAnswer in handleDroppedURLs(urls: urls, isAnswer: isAnswer) },
                            onPreviewItem: { item in previewItem(item) },
                            onExtract: { runExtraction() }
                        )
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
                                    
                                     Divider().padding(.vertical, 4)
                                     
                                     VStack(alignment: .leading, spacing: 8) {
                                         HStack {
                                             Text("Solution & Steps:").font(.caption).bold().foregroundColor(.blue)
                                             Spacer()
                                             Button(action: {
                                                 showEditQuestionModal = true
                                             }) {
                                                 Label("Edit Question & Steps", systemImage: "pencil")
                                                     .font(.caption)
                                             }
                                             .buttonStyle(.bordered)
                                         }
                                         
                                         let currentProb = extractedProblems[currentExtractionIndex]
                                         if !currentProb.steps.isEmpty {
                                             VStack(alignment: .leading, spacing: 8) {
                                                 ForEach(0..<currentProb.steps.count, id: \.self) { idx in
                                                     HStack(alignment: .top, spacing: 6) {
                                                         Text("\(idx + 1).")
                                                             .bold()
                                                             .foregroundColor(.blue)
                                                             .padding(.top, 2)
                                                         
                                                         if isLaTeX(currentProb.steps[idx]) {
                                                             LaTeXView(latex: currentProb.steps[idx])
                                                                 .frame(minHeight: calcLaTeXMinHeight(currentProb.steps[idx]))
                                                                 .frame(maxWidth: .infinity, alignment: .leading)
                                                         } else {
                                                             Text(currentProb.steps[idx])
                                                                 .font(.body)
                                                                 .lineSpacing(2)
                                                                 .textSelection(.enabled)
                                                                 .frame(maxWidth: .infinity, alignment: .leading)
                                                         }
                                                     }
                                                     .padding(8)
                                                     .background(Color(NSColor.controlBackgroundColor))
                                                     .cornerRadius(6)
                                                     .overlay(
                                                         RoundedRectangle(cornerRadius: 6)
                                                             .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                                     )
                                                 }
                                             }
                                         } else if !currentProb.solution.isEmpty {
                                             VStack(alignment: .leading, spacing: 6) {
                                                 if isLaTeX(currentProb.solution) {
                                                     LaTeXView(latex: currentProb.solution)
                                                         .frame(minHeight: calcLaTeXMinHeight(currentProb.solution))
                                                         .frame(maxWidth: .infinity, alignment: .leading)
                                                 } else {
                                                     Text(currentProb.solution)
                                                         .font(.body)
                                                         .lineSpacing(2)
                                                         .textSelection(.enabled)
                                                         .frame(maxWidth: .infinity, alignment: .leading)
                                                 }
                                             }
                                             .padding(8)
                                             .background(Color(NSColor.controlBackgroundColor))
                                             .cornerRadius(6)
                                             .overlay(
                                                 RoundedRectangle(cornerRadius: 6)
                                                     .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                             )
                                         } else {
                                             Text("No solution steps extracted yet. Click 'Edit Question & Steps' to add steps.")
                                                 .font(.caption)
                                                 .foregroundColor(.secondary)
                                                 .italic()
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
    
    private func handleDroppedURLs(urls: [URL], isAnswer: Bool) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                let item = PendingExtractionItem(type: .pdf, pathOrName: url.path, isAnswerSource: isAnswer)
                if isAnswer {
                    if !pendingAnswers.contains(where: { $0.pathOrName == url.path }) {
                        pendingAnswers.append(item)
                    }
                } else {
                    if !pendingQuestions.contains(where: { $0.pathOrName == url.path }) {
                        pendingQuestions.append(item)
                    }
                }
            } else if ["png", "jpeg", "jpg", "tiff", "heic", "webp"].contains(ext) {
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
                    sendAppNotification(title: "Problem Imported", body: "Successfully imported practice problem to Week \(topic.week).")
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
                    sendAppNotification(title: "Problem Added", body: "Successfully created practice problem.")
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
                                        ), axis: .vertical)
                                        .lineLimit(2...6)
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
            sendAppNotification(title: "Problem Updated", body: "Successfully saved modifications.")
            loadAllProblems()
        }
    }
    
    private func deleteProblem(id: Int) {
        let success = DatabaseManager.shared.deleteProblem(id: id)
        if success {
            sendAppNotification(title: "Problem Deleted", body: "Successfully deleted practice problem.")
            
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

struct PendingItemRowView: View {
    let item: PendingExtractionItem
    let onPreview: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: item.type == .pdf ? "doc.text" : "photo")
                .foregroundColor(item.type == .pdf ? .blue : .green)
            Text(item.displayName)
                .lineLimit(1)
            Spacer()
            
            Button(action: onPreview) {
                Image(systemName: "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Preview file in system app")
            
            Button(action: onDelete) {
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

final class ProblemURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls = [URL]()
    
    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }
    
    var collectedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

@MainActor
struct BatchImporterQueueView: View {
    @Binding var pendingQuestions: [PendingExtractionItem]
    @Binding var pendingAnswers: [PendingExtractionItem]
    let selectedTopic: Topic?
    let onSelectFiles: (Bool) -> Void
    let onPasteClipboardImage: (Bool) -> Void
    let onDropFiles: ([URL], Bool) -> Void
    let onPreviewItem: (PendingExtractionItem) -> Void
    let onExtract: () -> Void
    
    @State private var showSeparateAnswerBox: Bool = false
    @State private var isTargetedMain: Bool = false
    @State private var isTargetedAnswers: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            // UNIFIED SOURCE DOCUMENTS BOX
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Source Documents & Images:").bold().font(.headline)
                        Text("Drag & drop PDFs or images here (or click Select Files). AI extracts questions & answers automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                
                HStack(spacing: 12) {
                    Button(action: { onSelectFiles(false) }) {
                        Label("Select Files", systemImage: "plus.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { onPasteClipboardImage(false) }) {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button(action: {
                        withAnimation { showSeparateAnswerBox.toggle() }
                    }) {
                        Label(showSeparateAnswerBox ? "Hide Separate Answer Box" : "+ Add Separate Answer File", systemImage: "link")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected Source Documents (\(pendingQuestions.count))").bold()
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if pendingQuestions.isEmpty {
                                VStack(spacing: 6) {
                                    Image(systemName: isTargetedMain ? "arrow.down.doc.fill" : "arrow.down.doc")
                                        .font(.system(size: 26))
                                        .foregroundColor(isTargetedMain ? .blue : .secondary)
                                    Text(isTargetedMain ? "Drop files here..." : "Drag & drop files here or click Select Files above")
                                        .foregroundColor(isTargetedMain ? .blue : .secondary)
                                        .font(.subheadline)
                                        .bold(isTargetedMain)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                            } else {
                                ForEach(pendingQuestions) { item in
                                    PendingItemRowView(
                                        item: item,
                                        onPreview: { onPreviewItem(item) },
                                        onDelete: { pendingQuestions.removeAll(where: { $0.id == item.id }) }
                                    )
                                }
                            }
                        }
                    }
                    .frame(height: 120)
                    .border(isTargetedMain ? Color.blue : Color.secondary.opacity(0.15), width: isTargetedMain ? 2 : 1)
                    .cornerRadius(6)
                }
            }
            .padding()
            .background(isTargetedMain ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isTargetedMain ? Color.blue : Color.secondary.opacity(0.15), lineWidth: isTargetedMain ? 2 : 1)
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargetedMain) { providers in
                let group = DispatchGroup()
                let collector = ProblemURLCollector()
                for provider in providers {
                    group.enter()
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url {
                            collector.append(url)
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .main) {
                    let urls = collector.collectedURLs
                    if !urls.isEmpty {
                        onDropFiles(urls, false)
                    }
                }
                return true
            }
            
            // SEPARATE ANSWERS BOX (OPTIONAL / ADVANCED)
            if showSeparateAnswerBox || !pendingAnswers.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    Text("Separate Answer/Solution Key Files (Optional):").bold().font(.headline)
                    
                    HStack(spacing: 12) {
                        Button(action: { onSelectFiles(true) }) {
                            Label("Select Answer Files", systemImage: "plus.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: { onPasteClipboardImage(true) }) {
                            Label("Paste Answer Image", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Answer Items (\(pendingAnswers.count))").bold()
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if pendingAnswers.isEmpty {
                                    VStack(spacing: 6) {
                                        Image(systemName: isTargetedAnswers ? "arrow.down.doc.fill" : "arrow.down.doc")
                                            .font(.system(size: 24))
                                            .foregroundColor(isTargetedAnswers ? .blue : .secondary)
                                        Text(isTargetedAnswers ? "Drop answer files here..." : "Drag & drop answer files here (AI automatically scans main document if empty)")
                                            .foregroundColor(isTargetedAnswers ? .blue : .secondary)
                                            .font(.caption)
                                            .italic()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 15)
                                } else {
                                    ForEach(pendingAnswers) { item in
                                        PendingItemRowView(
                                            item: item,
                                            onPreview: { onPreviewItem(item) },
                                            onDelete: { pendingAnswers.removeAll(where: { $0.id == item.id }) }
                                        )
                                    }
                                }
                            }
                        }
                        .frame(height: 100)
                        .border(isTargetedAnswers ? Color.blue : Color.secondary.opacity(0.15), width: isTargetedAnswers ? 2 : 1)
                        .cornerRadius(6)
                    }
                }
                .padding()
                .background(isTargetedAnswers ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isTargetedAnswers ? Color.blue : Color.secondary.opacity(0.15), lineWidth: isTargetedAnswers ? 2 : 1)
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargetedAnswers) { providers in
                    let group = DispatchGroup()
                    let collector = ProblemURLCollector()
                    for provider in providers {
                        group.enter()
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            if let url = url {
                                collector.append(url)
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) {
                        let urls = collector.collectedURLs
                        if !urls.isEmpty {
                            onDropFiles(urls, true)
                        }
                    }
                    return true
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            
            HStack {
                Spacer()
                Button("Extract & Process Problems") {
                    onExtract()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(pendingQuestions.isEmpty || selectedTopic == nil)
            }
        }
    }
}

struct ProblemStepRowView: View {
    let index: Int
    let stepText: String
    let onEdit: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1).")
                .font(.body).bold()
                .foregroundColor(.blue)
                .padding(.top, 4)
            
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
            
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .help("Edit this step text in pop-up window")
            .padding(.top, 4)
            
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Delete step")
            .padding(.top, 4)
        }
    }
}

struct StepRowPracticeView: View {
    let stepNum: Int
    let stepText: String
    let isErrorStep: Bool
    let onToggleError: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(stepNum).")
                .font(.body)
                .bold()
                .foregroundColor(isErrorStep ? .red : .blue)
                .padding(.top, 4)
            
            VStack(alignment: .leading, spacing: 4) {
                if isLaTeX(stepText) {
                    LaTeXView(latex: stepText)
                        .frame(minHeight: calcLaTeXMinHeight(stepText))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(stepText)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            Button(action: onToggleError) {
                Image(systemName: isErrorStep ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isErrorStep ? .red : .secondary)
                    .padding(6)
                    .background(isErrorStep ? Color.red.opacity(0.15) : Color.secondary.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help(isErrorStep ? "Step marked as error/stopped point (Click to clear)" : "Signal that you got stuck or made a mistake at this step")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isErrorStep ? Color.red.opacity(0.08) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isErrorStep ? Color.red.opacity(0.4) : Color.blue.opacity(0.2), lineWidth: isErrorStep ? 2 : 1)
        )
        .padding(.vertical, 2)
    }
}

// MARK: - Problem Metric Chart Popup Views

@MainActor
struct ProblemDueProjectionChartView: View {
    let moduleId: Int?
    var year: Int? = nil
    @State private var projections: [(dayLabel: String, dateString: String, count: Int)] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("7-Day Interleaving Workload Projection").font(.headline)
            Text("Forecasted due problems for today and the next 6 days").font(.caption).foregroundColor(.secondary)
            
            Chart {
                ForEach(projections, id: \.dateString) { item in
                    BarMark(
                        x: .value("Day", item.dayLabel),
                        y: .value("Due Problems", item.count)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        Text("\(item.count)").font(.caption2).bold().foregroundColor(.blue)
                    }
                }
            }
            .chartYAxisLabel("Due Problems")
            .chartXAxisLabel("Forecast Date")
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .onAppear { loadProjections() }
    }
    
    private func loadProjections() {
        let modProbs = DatabaseManager.shared.getProblems(forYear: year, forModuleId: moduleId)
        let calendar = Calendar.current
        let today = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE d"
        
        var result: [(dayLabel: String, dateString: String, count: Int)] = []
        for dayOffset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            let dStr = formatter.string(from: date)
            let label = (dayOffset == 0) ? "Today" : dayFormatter.string(from: date)
            let count = modProbs.filter { p in
                if p.nextReviewDate.isEmpty { return dayOffset == 0 }
                if dayOffset == 0 {
                    return p.nextReviewDate <= dStr
                } else {
                    return p.nextReviewDate == dStr
                }
            }.count
            result.append((dayLabel: label, dateString: dStr, count: count))
        }
        self.projections = result
    }
}

@MainActor
struct ProblemSeverityChartView: View {
    let moduleId: Int?
    var year: Int? = nil
    
    struct SeverityBin: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
    }
    
    @State private var bins: [SeverityBin] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Problem Mastery & Diagnostic Errors").font(.headline)
            Text("Distribution of performance based on step-level error diagnostics").font(.caption).foregroundColor(.secondary)
            
            Chart {
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Category", bin.label),
                        y: .value("Problems", bin.count)
                    )
                    .foregroundStyle(bin.color.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        Text("\(bin.count)").font(.caption2).bold().foregroundColor(bin.color)
                    }
                }
            }
            .chartYAxisLabel("Count of Problems")
            .chartXAxisLabel("Mastery Category")
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .onAppear { loadBins() }
    }
    
    private func loadBins() {
        let modProbs = DatabaseManager.shared.getProblems(forYear: year, forModuleId: moduleId)
        let lvl1 = modProbs.filter { $0.lastFailedStep == 1 }.count
        let lvl2 = modProbs.filter { $0.lastFailedStep == 2 }.count
        let lvl3 = modProbs.filter { $0.lastFailedStep >= 3 }.count
        let lvl4 = modProbs.filter { $0.lastFailedStep == 0 && $0.solvedCount > 0 }.count
        let unattempted = modProbs.filter { $0.lastFailedStep == 0 && $0.solvedCount == 0 }.count
        
        self.bins = [
            SeverityBin(label: "Step 1 Error", count: lvl1, color: .red),
            SeverityBin(label: "Step 2 Error", count: lvl2, color: .orange),
            SeverityBin(label: "Step 3+ Slip", count: lvl3, color: .yellow),
            SeverityBin(label: "Flawless", count: lvl4, color: .green),
            SeverityBin(label: "New / Unsolved", count: unattempted, color: .purple)
        ]
    }
}

@MainActor
struct ProblemTopicChartView: View {
    let moduleId: Int?
    var year: Int? = nil
    
    struct TopicBin: Identifiable {
        let id = UUID()
        let topicName: String
        let count: Int
    }
    
    @State private var topicBins: [TopicBin] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Problems per Topic / Week").font(.headline)
            Text("Distribution of practice questions across course topics").font(.caption).foregroundColor(.secondary)
            
            Chart {
                ForEach(topicBins) { bin in
                    BarMark(
                        x: .value("Topic", bin.topicName),
                        y: .value("Problems", bin.count)
                    )
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        Text("\(bin.count)").font(.caption2).bold().foregroundColor(.orange)
                    }
                }
            }
            .chartYAxisLabel("Problems")
            .chartXAxisLabel("Topic")
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .onAppear { loadTopics() }
    }
    
    private func loadTopics() {
        let modProbs = DatabaseManager.shared.getProblems(forYear: year, forModuleId: moduleId)
        let topics: [Topic]
        if let modId = moduleId {
            topics = DatabaseManager.shared.getTopics(forModuleId: modId)
        } else {
            let modules = DatabaseManager.shared.getModules(forYear: year)
            topics = modules.flatMap { DatabaseManager.shared.getTopics(forModuleId: $0.id) }
        }
        
        var result: [TopicBin] = []
        for t in topics {
            let count = modProbs.filter { $0.topicId == t.id }.count
            result.append(TopicBin(topicName: "W\(t.week): \(t.name)", count: count))
        }
        self.topicBins = result
    }
}

@MainActor
struct ProblemFlaggedChartView: View {
    let moduleId: Int?
    var year: Int? = nil
    
    struct FlagBin: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
    }
    
    @State private var bins: [FlagBin] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flagged Problems Status").font(.headline)
            Text("Breakdown of problems flagged for correction versus active practice problems").font(.caption).foregroundColor(.secondary)
            
            Chart {
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Status", bin.label),
                        y: .value("Problems", bin.count)
                    )
                    .foregroundStyle(bin.color.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        Text("\(bin.count)").font(.caption2).bold().foregroundColor(bin.color)
                    }
                }
            }
            .chartYAxisLabel("Problems")
            .chartXAxisLabel("Flag Status")
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .onAppear { loadFlagged() }
    }
    
    private func loadFlagged() {
        let modProbs = DatabaseManager.shared.getProblems(forYear: year, forModuleId: moduleId)
        let flagged = modProbs.filter { $0.isFlagged }.count
        let clean = modProbs.filter { !$0.isFlagged }.count
        
        self.bins = [
            FlagBin(label: "Flagged for Edit", count: flagged, color: .purple),
            FlagBin(label: "Active Practice", count: clean, color: .blue)
        ]
    }
}
