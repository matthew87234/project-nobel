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
    return 16
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

struct ExtractedProblem: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var content: String
    var solutionHint: String
    var solution: String = ""
    var steps: [String] = []
    var isSelected: Bool = true
    
    var missingSubparts: [String] {
        extractMissingSubparts(question: content, solution: solution, steps: steps)
    }
}

/// Analyzes question text against its solution/steps to identify any subparts asked in the question (e.g. (a), (b), (c)) that lack an answer
func extractMissingSubparts(question: String, solution: String, steps: [String]) -> [String] {
    let questionPattern = #"(?m)(?:^[ \t]*(?:\(([a-z])\)|([a-z])[\).])\s)|(?:\b(?:Part|Subpart|part|subpart)\b\s*\(?([a-z])\)?)"#
    guard let qRegex = try? NSRegularExpression(pattern: questionPattern, options: []) else { return [] }
    let ns = question as NSString
    let matches = qRegex.matches(in: question, options: [], range: NSRange(location: 0, length: ns.length))
    var asked = [String]()
    for m in matches {
        var letter: String? = nil
        if m.range(at: 1).location != NSNotFound {
            letter = ns.substring(with: m.range(at: 1)).lowercased()
        } else if m.range(at: 2).location != NSNotFound {
            letter = ns.substring(with: m.range(at: 2)).lowercased()
        } else if m.range(at: 3).location != NSNotFound {
            letter = ns.substring(with: m.range(at: 3)).lowercased()
        }
        if let l = letter, l.count == 1, l >= "a", l <= "j", !asked.contains(l) {
            asked.append(l)
        }
    }
    guard !asked.isEmpty else { return [] }
    let combined = solution + "\n" + steps.joined(separator: "\n")
    if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return asked
    }
    var covered = Set<String>()
    for sub in asked {
        let p = #"(?i)(?:\([ \t]*"# + sub + #"[ \t]*\)|(?:^|\n|[ \t])"# + sub + #"[\).:][ \t\n]|(?:Part|Subpart|Question|Problem)\b\s*\d*\s*\(?"# + sub + #"(?:\)|[:.\s]|$))"#
        if let reg = try? NSRegularExpression(pattern: p, options: []) {
            let combNs = combined as NSString
            if reg.firstMatch(in: combined, options: [], range: NSRange(location: 0, length: combNs.length)) != nil {
                covered.insert(sub)
            }
        }
    }
    return asked.filter { !covered.contains($0) }
}

extension Problem {
    var missingSubparts: [String] {
        extractMissingSubparts(question: content, solution: solution, steps: [steps])
    }
}

// MARK: - Pedagogical Diagnostic Categories & Step Parsing

enum PedagogicalTier: String, CaseIterable {
    case conceptualSetup = "Conceptual Setup"
    case governingFormulation = "Governing Formulation"
    case algebraicDerivation = "Algebraic Derivation"
    case interpretation = "Interpretation & Analysis"
    case verification = "Verification & Result"
    
    var icon: String {
        switch self {
        case .conceptualSetup: return "brain.head.profile"
        case .governingFormulation: return "function"
        case .algebraicDerivation: return "plusminus"
        case .interpretation: return "chart.line.uptrend.xyaxis"
        case .verification: return "checkmark.seal"
        }
    }
    
    var color: Color {
        switch self {
        case .conceptualSetup: return .blue
        case .governingFormulation: return .purple
        case .algebraicDerivation: return .teal
        case .interpretation: return .orange
        case .verification: return .green
        }
    }
    
    var diagnosticLevel: Int {
        switch self {
        case .conceptualSetup: return 1
        case .governingFormulation: return 2
        case .algebraicDerivation: return 3
        case .interpretation: return 4
        case .verification: return 4
        }
    }
}

struct StepComponents {
    let tier: PedagogicalTier?
    let customTierName: String?
    let subpart: String?
    let content: String
}

func parsePedagogicalStep(_ rawStep: String) -> StepComponents {
    var trimmed = rawStep.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        return StepComponents(tier: nil, customTierName: nil, subpart: nil, content: "")
    }
    
    // Strip markdown bold **text** -> text and lingering asterisks
    trimmed = trimmed.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
    trimmed = trimmed.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
    
    // Pattern 1: [Tier] (subpart)\n\nContent or [Tier]\n\nContent
    let bracketPattern = #"^\[([^\]]+)\](?:\s*(?:\(([a-zA-Z0-9]+)\)|([a-fA-F]|i{1,4}|iv|v|vi{1,3}|[1-9])(?:\.|\:|\s+)))?\s*\n*(.*)"#
    if let regex = try? NSRegularExpression(pattern: bracketPattern, options: [.dotMatchesLineSeparators]) {
        let nsStr = trimmed as NSString
        let matches = regex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: nsStr.length))
        if let match = matches.first, match.numberOfRanges > 1 {
            let rawTier = nsStr.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            var rawSub = ""
            if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
                rawSub = nsStr.substring(with: match.range(at: 2))
            } else if match.numberOfRanges > 3 && match.range(at: 3).location != NSNotFound {
                rawSub = nsStr.substring(with: match.range(at: 3))
            }
            var body = ""
            if match.numberOfRanges > 4 && match.range(at: 4).location != NSNotFound {
                body = nsStr.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            let cleanTier = cleanTierString(rawTier)
            let tierEnum = matchPedagogicalTier(cleanTier)
            let customTier = tierEnum == nil && !cleanTier.isEmpty ? cleanTier : nil
            let subpart = formatSubpart(rawSub)
            
            return StepComponents(tier: tierEnum, customTierName: customTier, subpart: subpart, content: body.isEmpty ? trimmed : body)
        }
    }
    
    // Pattern 2: Tier: ... \nSubpart: ... \nContent: ...
    if trimmed.localizedCaseInsensitiveContains("Content:") {
        var tierStr = ""
        var subpartStr = ""
        var contentStr = ""
        let lines = trimmed.components(separatedBy: .newlines)
        var readingContent = false
        for line in lines {
            let lTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = lTrimmed.lowercased()
            if lower.starts(with: "tier:") {
                tierStr = lTrimmed.replacingOccurrences(of: "(?i)^tier:\\s*", with: "", options: .regularExpression)
            } else if lower.starts(with: "subpart:") {
                subpartStr = lTrimmed.replacingOccurrences(of: "(?i)^subpart:\\s*", with: "", options: .regularExpression)
            } else if lower.starts(with: "content:") {
                readingContent = true
                let c = lTrimmed.replacingOccurrences(of: "(?i)^content:\\s*", with: "", options: .regularExpression)
                if !c.isEmpty { contentStr = c }
            } else if readingContent {
                contentStr += (contentStr.isEmpty ? "" : "\n") + line
            }
        }
        if !contentStr.isEmpty {
            let cleanTier = cleanTierString(tierStr)
            let tierEnum = matchPedagogicalTier(cleanTier)
            let customTier = tierEnum == nil && !cleanTier.isEmpty ? cleanTier : nil
            let subpart = formatSubpart(subpartStr)
            return StepComponents(tier: tierEnum, customTierName: customTier, subpart: subpart, content: contentStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    
    // Pattern 3: Heading line followed by content (e.g. Conceptual Setup & Physical Principles)
    let lines = trimmed.components(separatedBy: .newlines)
    if lines.count >= 2 {
        let firstLine = lines[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = firstLine.lowercased()
        if lower.contains("conceptual") || lower.contains("governing") || lower.contains("algebraic") || lower.contains("identification") || lower.contains("data collection") || lower.contains("tier:") {
            let cleanHeader = cleanTierString(firstLine.replacingOccurrences(of: "(?i)^tier:\\s*", with: "", options: .regularExpression))
            let tierEnum = matchPedagogicalTier(cleanHeader)
            let customTier = tierEnum == nil && !cleanHeader.isEmpty ? cleanHeader : nil
            let remainingLines = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return StepComponents(tier: tierEnum, customTierName: customTier, subpart: nil, content: remainingLines)
        }
    }
    
    return StepComponents(tier: nil, customTierName: nil, subpart: nil, content: trimmed)
}

func cleanTierString(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: #"[\$\\][a-zA-Z0-9_\{\}\\]*"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[\[\]\(\)\*#]"#, with: "", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func matchPedagogicalTier(_ name: String) -> PedagogicalTier? {
    let lower = name.lowercased()
    if lower.contains("concept") || lower.contains("principle") || lower.contains("setup") {
        return .conceptualSetup
    } else if lower.contains("govern") || lower.contains("formulat") || lower.contains("equation") {
        return .governingFormulation
    } else if lower.contains("algebra") || lower.contains("derivat") || lower.contains("calculat") || lower.contains("integrat") {
        return .algebraicDerivation
    } else if lower.contains("interpret") || lower.contains("analys") || lower.contains("meaning") {
        return .interpretation
    } else if lower.contains("verif") || lower.contains("evaluat") || lower.contains("result") {
        return .verification
    }
    return nil
}

func formatSubpart(_ raw: String) -> String? {
    let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "() \t\n*#"))
    let lower = clean.lowercased()
    if lower.isEmpty || lower == "full" || lower == "none" || lower == "part" {
        return nil
    }
    return "Part (\(clean))"
}

struct PedagogicalStepRowView: View {
    let stepNumber: Int
    let stepText: String
    var isErrorStep: Bool = false
    var onToggleError: (() -> Void)? = nil
    
    var body: some View {
        let components = parsePedagogicalStep(stepText)
        
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Step Number Badge
                Text("Step \(stepNumber)")
                    .font(.caption2.bold())
                    .foregroundColor(isErrorStep ? .red : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isErrorStep ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                    .cornerRadius(5)
                
                // Diagnostic Category Badge
                if let tier = components.tier {
                    HStack(spacing: 4) {
                        Image(systemName: tier.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(tier.rawValue)
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tier.color.opacity(0.12))
                    .foregroundColor(tier.color)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(tier.color.opacity(0.25), lineWidth: 0.8)
                    )
                } else if let custom = components.customTierName, !custom.isEmpty {
                    Text(custom)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }
                
                // Genuine Subpart Badge
                if let sub = components.subpart {
                    Text(sub)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.primary)
                        .cornerRadius(4)
                }
                
                Spacer()
                
                if let onToggleError = onToggleError {
                    Button(action: onToggleError) {
                        Image(systemName: isErrorStep ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(isErrorStep ? .red : .secondary)
                            .padding(5)
                            .background(isErrorStep ? Color.red.opacity(0.15) : Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(isErrorStep ? "Step marked as error point (Click to clear)" : "Signal that you got stuck or made a mistake at this step")
                }
            }
            
            // Content body: rendered with LaTeXView or Text
            if isLaTeX(components.content) {
                LaTeXView(latex: components.content)
                    .frame(minHeight: calcLaTeXMinHeight(components.content))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(LocalizedStringKey(components.content))
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isErrorStep ? Color.red.opacity(0.06) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isErrorStep ? Color.red.opacity(0.4) : Color.blue.opacity(0.15), lineWidth: isErrorStep ? 1.5 : 1)
        )
        .padding(.vertical, 2)
    }
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
    @State private var isRegeneratingSteps: Bool = false
    @State private var showCacheClearedAlert: Bool = false
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
                aiHelper.sanitizeSessionExtractedProblems()
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
            guard isActive && isTimerActive && mode == .review && reviewSubMode == .practice && currentProblem != nil else { return }
            prTimerSeconds += 1
            if prTimerSeconds % 10 == 0 {
                // Log time to database every 10 seconds
                DatabaseManager.shared.addStudyTime(flashcardsDelta: 0, problemsDelta: 10)
                let modId = (currentProblem != nil ? DatabaseManager.shared.getModuleId(forTopicId: currentProblem!.topicId) : nil) ?? activeModuleId
                if let modId = modId {
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
        .alert("Transcription Cache Cleared", isPresented: $showCacheClearedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("All cached OCR and transcription files have been wiped. Your next batch import will perform a completely fresh visual extraction.")
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
                                    if isRegeneratingSteps {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .frame(width: 16, height: 16)
                                    } else {
                                        Button(action: {
                                            regenerateStepsForCurrentExtraction()
                                        }) {
                                            Label("AI Step Breakdown", systemImage: "wand.and.stars")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(currentExtractionIndex >= extractedProblems.count || extractedProblems[currentExtractionIndex].solution.isEmpty)
                                    }
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
            if reviewSubMode == .practice && currentProblem != nil {
                isTimerActive = true
            } else {
                isTimerActive = false
            }
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
            let modId = (currentProblem != nil ? DatabaseManager.shared.getModuleId(forTopicId: currentProblem!.topicId) : nil) ?? activeModuleId
            if let modId = modId {
                DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: 0, problemsDelta: remainder)
            }
            prTimerSeconds = 0
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
                    guard !p.isFlagged else { return false }
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
            self.prTimerSeconds = 0
            self.isTimerActive = true
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
                    isTimerActive = false
                    logActiveSeconds()
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
                            if let updated = DatabaseManager.shared.getProblem(id: problem.id) {
                                self.currentProblem = updated
                                if currentDueProblemIdx < dueProblems.count && dueProblems[currentDueProblemIdx].id == problem.id {
                                    dueProblems[currentDueProblemIdx] = updated
                                }
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
                                                HStack(spacing: 8) {
                                                    Text("SOLUTION STEPS (\(min(revealedStepCount, totalSteps)) OF \(totalSteps)):")
                                                        .font(.caption)
                                                        .bold()
                                                        .foregroundColor(.blue)
                                                    
                                                    let missing = problem.missingSubparts
                                                    if !missing.isEmpty {
                                                        HStack(spacing: 4) {
                                                            Image(systemName: "exclamationmark.triangle.fill")
                                                                .foregroundColor(.orange)
                                                                .font(.system(size: 10))
                                                            Text("Missing: \(missing.map { "Part (\($0))" }.joined(separator: ", "))")
                                                                .font(.caption2.bold())
                                                                .foregroundColor(.orange)
                                                        }
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.orange.opacity(0.12))
                                                        .cornerRadius(4)
                                                    }
                                                }
                                                
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
                            let probModId = DatabaseManager.shared.getModuleId(forTopicId: problem.topicId) ?? activeModuleId
                            DatabaseManager.shared.logActivity("interleaving", moduleId: probModId)
                            
                            problemsSolvedInSession += 1
                            markedFailedStep = 0
                            
                            if currentDueProblemIdx < dueProblems.count - 1 {
                                currentDueProblemIdx += 1
                                currentProblem = dueProblems[currentDueProblemIdx]
                                showHint = false
                                showSolution = false
                                revealedStepCount = 0
                            } else {
                                isTimerActive = false
                                logActiveSeconds()
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
        let steps = parseSteps(problem.steps)
        _ = DatabaseManager.shared.recordProblemPracticeResult(id: problem.id, failedStep: markedFailedStep, totalSteps: steps.count)
        _ = DatabaseManager.shared.incrementProblemSolvedCount(id: problem.id)
        DatabaseManager.shared.logActivity("interleaving", moduleId: activeModuleId)
        markedFailedStep = 0
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
            self.problemSteps = parseSteps(p.steps)
            if let t = topics.first(where: { $0.id == p.topicId }) {
                self.selectedTopic = t
            }
            self.isCorrectingFlaggedProblems = true
        }
    }
    
    private func saveAndAdvanceFlaggedProblem(unflag: Bool, problemId: Int) {
        guard let topic = selectedTopic else { return }
        let stepStr = encodeSteps(problemSteps)
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
            self.problemSteps = parseSteps(p.steps)
            if let t = topics.first(where: { $0.id == p.topicId }) {
                self.selectedTopic = t
            }
        } else if !flaggedRemaining.isEmpty {
            self.flaggedProblemIdx = 0
            let p = flaggedRemaining[0]
            self.problemContent = p.content
            self.solutionHint = p.solutionHint
            self.problemSolution = p.solution
            self.problemSteps = parseSteps(p.steps)
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
                
                if addSubMode == .aiBatch {
                    Button(action: {
                        aiHelper.clearTranscriptionCache()
                        showCacheClearedAlert = true
                    }) {
                        Label("Clear Cache", systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Clear cached OCR and transcription files to force a completely fresh extraction")
                }
                
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
                    
                    if isExtracting || aiHelper.isBatchImportActive || aiHelper.isClassifyingProblems {
                        BatchImportProgressCardView(
                            aiHelper: aiHelper,
                            onCancel: {
                                aiHelper.cancelExtractionQueue()
                                isExtracting = false
                            }
                        )
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
                                            .frame(minHeight: calcLaTeXMinHeight(extractedProblems[currentExtractionIndex].content))
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
                                         HStack(spacing: 8) {
                                             Text("Solution & Steps:").font(.caption).bold().foregroundColor(.blue)
                                             
                                             let curProb = extractedProblems[currentExtractionIndex]
                                             let missing = curProb.missingSubparts
                                             if !missing.isEmpty {
                                                 HStack(spacing: 4) {
                                                     Image(systemName: "exclamationmark.triangle.fill")
                                                         .foregroundColor(.orange)
                                                         .font(.system(size: 10))
                                                     Text("Missing: \(missing.map { "Part (\($0))" }.joined(separator: ", "))")
                                                         .font(.caption2.bold())
                                                         .foregroundColor(.orange)
                                                 }
                                                 .padding(.horizontal, 7)
                                                 .padding(.vertical, 2.5)
                                                 .background(Color.orange.opacity(0.12))
                                                 .cornerRadius(5)
                                                 .help("These subparts were detected in the question statement but do not have an answer in the solution.")
                                             } else if curProb.solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && curProb.steps.isEmpty {
                                                 HStack(spacing: 4) {
                                                     Image(systemName: "questionmark.circle.fill")
                                                         .foregroundColor(.red)
                                                         .font(.system(size: 10))
                                                     Text("No Solution in Answer Key")
                                                         .font(.caption2.bold())
                                                         .foregroundColor(.red)
                                                 }
                                                 .padding(.horizontal, 7)
                                                 .padding(.vertical, 2.5)
                                                 .background(Color.red.opacity(0.12))
                                                 .cornerRadius(5)
                                             }
                                             
                                             Spacer()
                                             
                                             if isRegeneratingSteps {
                                                 ProgressView()
                                                     .scaleEffect(0.7)
                                                     .frame(width: 16, height: 16)
                                                 Text("Generating Steps...")
                                                     .font(.caption)
                                                     .foregroundColor(.secondary)
                                             } else {
                                                 Button(action: {
                                                     regenerateStepsForCurrentExtraction()
                                                 }) {
                                                     Label("Auto-Generate Steps", systemImage: "wand.and.stars")
                                                         .font(.caption)
                                                 }
                                                 .buttonStyle(.bordered)
                                                 .disabled(extractedProblems.isEmpty || currentExtractionIndex >= extractedProblems.count || extractedProblems[currentExtractionIndex].solution.isEmpty)
                                                 .help("Break down the solution into pedagogical steps using \(aiHelper.activeAIProvider.name)")
                                             }
                                             
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
                                                     PedagogicalStepRowView(
                                                         stepNumber: idx + 1,
                                                         stepText: currentProb.steps[idx]
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
                let isAnswerFile = isAnswer || aiHelper.isAnswerFilename(url.lastPathComponent)
                if ext == "pdf" {
                    let item = PendingExtractionItem(type: .pdf, pathOrName: url.path, imageBase64: nil, isAnswerSource: isAnswerFile, originalPdfPath: url.path)
                    if isAnswerFile {
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
                        let item = PendingExtractionItem(type: .image, pathOrName: url.path, imageBase64: base64Str, isAnswerSource: isAnswerFile)
                        if isAnswerFile {
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
            let isAnswerFile = isAnswer || aiHelper.isAnswerFilename(url.lastPathComponent)
            if ext == "pdf" {
                let item = PendingExtractionItem(type: .pdf, pathOrName: url.path, isAnswerSource: isAnswerFile)
                if isAnswerFile {
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
                    let item = PendingExtractionItem(type: .image, pathOrName: url.path, imageBase64: base64Str, isAnswerSource: isAnswerFile)
                    if isAnswerFile {
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
    
    private func regenerateStepsForCurrentExtraction() {
        guard currentExtractionIndex < extractedProblems.count else { return }
        let q = extractedProblems[currentExtractionIndex].content
        let sol = extractedProblems[currentExtractionIndex].solution
        
        isRegeneratingSteps = true
        Task {
            let newSteps: [String]
            if !sol.isEmpty {
                newSteps = await aiHelper.generateStepsFromAnswer(question: q, answer: sol)
            } else {
                let (derivedSol, derivedSteps) = await aiHelper.deriveSolutionAndSteps(question: q)
                if !derivedSol.isEmpty {
                    await MainActor.run {
                        if currentExtractionIndex < aiHelper.sessionExtractedProblems.count {
                            aiHelper.sessionExtractedProblems[currentExtractionIndex].solution = derivedSol
                        }
                    }
                }
                newSteps = derivedSteps
            }
            await MainActor.run {
                if currentExtractionIndex < aiHelper.sessionExtractedProblems.count && !newSteps.isEmpty {
                    aiHelper.sessionExtractedProblems[currentExtractionIndex].steps = newSteps
                    aiHelper.sanitizeSessionExtractedProblems()
                }
                isRegeneratingSteps = false
            }
        }
    }
    
    private func parseSteps(_ jsonStr: String) -> [String] {
        let trimmed = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "[]" else { return [] }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        return trimmed.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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

@MainActor
struct BatchImportProgressCardView: View {
    @ObservedObject var aiHelper: AIHelper
    let onCancel: () -> Void
    
    @State private var timeString: String = "00:00"
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header: Title, Active Phase, Active Engine, Stop button
            HStack(spacing: 10) {
                if aiHelper.isBatchImportActive || aiHelper.isProcessingExtractionQueue {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                }
                
                Text("Batch Import Progress Breakdown")
                    .font(.system(size: 13, weight: .bold))
                
                // Phase Pill
                Text(aiHelper.pipelineCurrentPhase)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .cornerRadius(5)
                
                // Active Engine / Cooldown Badge
                if aiHelper.isTailscaleInCooldown {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("Tailscale Cooldown (Fallback Local: \(aiHelper.tailscaleCooldownRemainingSeconds)s)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(5)
                } else if aiHelper.isRemoteActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Remote Engine Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12))
                    .cornerRadius(5)
                } else if aiHelper.isLocalActive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.blue).frame(width: 6, height: 6)
                        Text("Local Apple Silicon Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(5)
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        Text("Engine Idle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(5)
                }
                
                Spacer()
                
                if aiHelper.isBatchImportActive || aiHelper.isProcessingExtractionQueue {
                    Button(action: onCancel) {
                        Text("Cancel Extraction")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            Divider()
            
            // Dual Progress Columns
            HStack(alignment: .top, spacing: 20) {
                // Left Column: Phase 1 (Local OCR)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Phase 1: Visual OCR", systemImage: "doc.text.viewfinder")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text("\(aiHelper.localPagesCompleted)/\(max(1, aiHelper.localPagesTotal)) pages")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    ProgressView(value: Double(aiHelper.localPagesCompleted), total: Double(max(1, aiHelper.localPagesTotal)))
                        .tint(.blue)
                    
                    Text(aiHelper.localTaskStatus)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.secondary.opacity(0.04))
                .cornerRadius(8)
                
                // Right Column: Phase 2 (Derivations & Matching)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Phase 2: Derivations", systemImage: "function")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Text("\(aiHelper.remoteProblemsCompleted)/\(max(1, aiHelper.remoteProblemsTotal)) problems")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    ProgressView(value: Double(aiHelper.remoteProblemsCompleted), total: Double(max(1, aiHelper.remoteProblemsTotal)))
                        .tint(.indigo)
                    
                    Text(aiHelper.remoteTaskStatus)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.secondary.opacity(0.04))
                .cornerRadius(8)
            }
            
            // Telemetry Status Bar: Tokens generated, streaming heartbeat, elapsed time
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 10))
                    Text("\(aiHelper.batchTokensGenerated) tokens generated")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                
                HStack(spacing: 5) {
                    let isStreamingRecent: Bool = {
                        guard let date = aiHelper.lastStreamingActivityDate else { return false }
                        return Date().timeIntervalSince(date) < 5.0
                    }()
                    Circle()
                        .fill(isStreamingRecent ? Color.green : (aiHelper.isBatchImportActive ? Color.orange : Color.secondary))
                        .frame(width: 6, height: 6)
                    Text(isStreamingRecent ? "Streaming actively" : (aiHelper.isBatchImportActive ? "Awaiting model response" : "Idle"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Elapsed: \(timeString)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            
            // Live Events Feed
            if !aiHelper.batchLiveEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Activity Log")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(aiHelper.batchLiveEvents.suffix(12).enumerated()), id: \.offset) { idx, event in
                                    Text(event)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(idx)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 80)
                        .background(Color(NSColor.textBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .onReceive(timer) { _ in
            if let start = aiHelper.batchStartTime {
                let elapsed = Int(Date().timeIntervalSince(start))
                let mins = elapsed / 60
                let secs = elapsed % 60
                timeString = String(format: "%02d:%02d", mins, secs)
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
        PedagogicalStepRowView(
            stepNumber: stepNum,
            stepText: stepText,
            isErrorStep: isErrorStep,
            onToggleError: onToggleError
        )
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
        let modProbs = DatabaseManager.shared.getProblems(forYear: year, forModuleId: moduleId).filter { !$0.isFlagged }
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
