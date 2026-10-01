import SwiftUI

struct PreExamRoutineView: View {
    let activeModule: Module?
    var initialPhase: Int = 1
    var startInEditor: Bool = false
    let onFinishWarmup: () -> Void
    
    @ObservedObject private var aiHelper = AIHelper.shared
    @State private var activePhase: Int = 1
    @State private var currentCardIndex: Int = 0
    @State private var isFlipped: Bool = false
    @State private var phaseTimeRemainingSeconds: Int = 2400
    @State private var timer: Timer? = nil
    @State private var curatedCards: [Flashcard] = []
    
    // Phase 2 State
    @State private var warmupProblems: [Problem] = []
    @State private var topicsMap: [Int: Topic] = [:]
    @State private var currentProblemIndex: Int = 0
    @State private var showSetupStrategy: Bool = false
    @State private var pinnedProblemIds: Set<Int> = []
    
    // Phase 3 State
    @State private var phase3SubTab: Int = 0 // 0: Prepared Notes, 1: Pinned Problems, 2: Mental Reset
    @State private var isEditingNotes: Bool = false
    @State private var preparedNotesText: String = ""
    @State private var resetTimerSeconds: Int = 900 // 15:00
    @State private var isResetTimerRunning: Bool = false
    @State private var resetTimer: Timer? = nil
    @State private var breathingPhaseIndex: Int = 0 // 0: Inhale, 1: Hold, 2: Exhale, 3: Hold
    @State private var breathingScale: CGFloat = 1.0
    @State private var breathingTimer: Timer? = nil
    @State private var checklistCompleted: [Bool] = [false, false, false, false]
    
    // LaTeX AI Helper State
    @State private var showLatexHelper: Bool = false
    @State private var latexInput: String = ""
    @State private var latexClipboardImage: NSImage? = nil
    @State private var latexImageBase64: String = ""
    @State private var latexResult: String = ""
    @State private var isTranslatingLaTeX: Bool = false
    
    private var phaseDurationMinutes: Int {
        guard let mod = activeModule, !mod.testDate.isEmpty else { return 40 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parsedDate = formatter.date(from: mod.testDate)
        if parsedDate == nil {
            let fallbackFormatter = DateFormatter()
            fallbackFormatter.dateFormat = "yyyy-MM-dd"
            parsedDate = fallbackFormatter.date(from: mod.testDate)
        }
        guard let examDate = parsedDate else { return 40 }
        let timeUntilExamSeconds = examDate.timeIntervalSince(Date())
        let timeUntilExamMinutes = Int(timeUntilExamSeconds / 60)
        
        if timeUntilExamMinutes > 0 && timeUntilExamMinutes < 120 {
            return max(5, timeUntilExamMinutes / 3)
        }
        return 40
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Navigation Bar (3 Clean Sections, No Time in Titles)
            HStack(spacing: 12) {
                PhaseHeaderTab(
                    phaseNumber: 1,
                    title: "Phase 1: Formula Priming",
                    isActive: activePhase == 1,
                    isCompleted: activePhase > 1
                ) {
                    activePhase = 1
                    resetPhaseTimer()
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                PhaseHeaderTab(
                    phaseNumber: 2,
                    title: "Phase 2: Setup Warmup",
                    isActive: activePhase == 2,
                    isCompleted: activePhase > 2
                ) {
                    activePhase = 2
                    resetPhaseTimer()
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                PhaseHeaderTab(
                    phaseNumber: 3,
                    title: "Phase 3: Reset & Dump",
                    isActive: activePhase == 3,
                    isCompleted: false
                ) {
                    activePhase = 3
                    resetPhaseTimer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
            
            Divider()
            
            // MARK: - Main Phase Body Content
            VStack {
                if activePhase == 1 {
                    phase1View
                } else if activePhase == 2 {
                    phase2View
                } else {
                    phase3View
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.textBackgroundColor))
        }
        .sheet(isPresented: $showLatexHelper) {
            latexHelperSheet
        }
        .onAppear {
            if startInEditor {
                activePhase = 3
                phase3SubTab = 0
                isEditingNotes = true
            } else if initialPhase > 1 {
                activePhase = initialPhase
            }
            loadCuratedCards()
            loadPhase2WarmupProblems()
            loadPreparedNotes()
            resetPhaseTimer()
            startTimer()
        }
        .onChange(of: activeModule?.id) { _, _ in
            loadCuratedCards()
            loadPhase2WarmupProblems()
            loadPreparedNotes()
        }
        .onChange(of: startInEditor) { _, shouldEdit in
            if shouldEdit {
                activePhase = 3
                phase3SubTab = 0
                isEditingNotes = true
                loadPreparedNotes()
            }
        }
        .onChange(of: initialPhase) { _, phase in
            activePhase = phase
        }
        .onChange(of: aiHelper.aiCuratedCardsVersion) { _, _ in
            loadCuratedCards()
        }
        .onDisappear {
            stopTimer()
            stopResetTimer()
            stopBreathingGuide()
        }
    }
    
    // MARK: - Phase 1: Formula Priming (Flashcards)
    @ViewBuilder
    private var phase1View: some View {
        if curatedCards.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No Flashcards Selected for Phase 1")
                    .font(.title2)
                    .bold()
                Text("Run the AI Pre-Exam Selection from the bottom-left sidebar to curate your 25 priming cards.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding()
        } else {
            VStack(spacing: 16) {
                // Header Counter & Progress Bar
                VStack(spacing: 8) {
                    HStack {
                        Text("Card \(currentCardIndex + 1) of \(curatedCards.count)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        Spacer()
                        if let mod = activeModule {
                            Text(mod.code)
                                .font(.caption)
                                .bold()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                    
                    ProgressView(value: Double(currentCardIndex + 1), total: Double(curatedCards.count))
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 40)
                .padding(.top, 16)
                
                // Native 3D FlipCardView (Matching main Flashcard Review UI with LaTeX support)
                let card = curatedCards[min(currentCardIndex, curatedCards.count - 1)]
                
                FlipCardView(
                    front: card.front,
                    back: card.back,
                    isFlipped: $isFlipped,
                    isFlagged: card.isFlagged
                )
                .frame(maxWidth: 640, minHeight: 300)
                .padding(.horizontal, 40)
                .pointingHandCursor()
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        isFlipped.toggle()
                    }
                }
                
                // Navigation Action Bar (Without SM-2 Rating Buttons)
                HStack(spacing: 16) {
                    Button(action: {
                        if currentCardIndex > 0 {
                            withAnimation {
                                currentCardIndex -= 1
                                isFlipped = false
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Previous Card")
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHandCursor()
                    .disabled(currentCardIndex == 0)
                    
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            isFlipped.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Flip Card")
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .pointingHandCursor()
                    
                    Button(action: {
                        if currentCardIndex < curatedCards.count - 1 {
                            withAnimation {
                                currentCardIndex += 1
                                isFlipped = false
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text("Next Card")
                            Image(systemName: "chevron.right")
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHandCursor()
                    .disabled(currentCardIndex >= curatedCards.count - 1)
                }
                .padding(.bottom, 24)
            }
        }
    }
    
    // MARK: - Phase 2: High-Yield Problem Setup Warmup
    @ViewBuilder
    private var phase2View: some View {
        if warmupProblems.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.orange)
                Text("No Practice Problems for Phase 2")
                    .font(.title2)
                    .bold()
                Text("Add practice problems to your topics in the Problems tab to generate an even-spread setup warmup deck.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                
                Button("Proceed to Phase 3: Identity Dump →") {
                    withAnimation {
                        activePhase = 3
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.top, 8)
            }
            .padding(40)
        } else {
            let problem = warmupProblems[min(currentProblemIndex, warmupProblems.count - 1)]
            let topic = topicsMap[problem.topicId]
            let (step1, step2, remainderNote) = extractStep1And2(from: problem)
            let isPinned = pinnedProblemIds.contains(problem.id)
            
            VStack(spacing: 12) {
                // Header Counter & Progress Bar
                VStack(spacing: 8) {
                    HStack {
                        Text("Problem \(currentProblemIndex + 1) of \(warmupProblems.count)")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        if let t = topic {
                            Text("Week \(t.week): \(t.name)")
                                .font(.caption)
                                .bold()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.12))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            togglePinProblem(problem.id)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isPinned ? "pin.fill" : "pin")
                                Text(isPinned ? "Pinned to Phase 3" : "Pin to Phase 3")
                            }
                            .font(.caption)
                            .bold()
                            .foregroundColor(isPinned ? .purple : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isPinned ? Color.purple.opacity(0.15) : Color.secondary.opacity(0.1))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    
                    ProgressView(value: Double(currentProblemIndex + 1), total: Double(warmupProblems.count))
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 40)
                .padding(.top, 12)
                
                // Problem Statement Card + 30s Scratch Prompt
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // 30-Second Scratch Guidance Banner
                        HStack(spacing: 8) {
                            Image(systemName: "pencil.line")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.orange)
                            Text("30s Scratch Goal: Write Step 1 (Governing Law) and Step 2 (Starting Equation) on scrap paper. Do not solve full algebra.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                        .cornerRadius(8)
                        
                        // Problem Statement
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Problem Statement")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            if isLaTeX(problem.content) {
                                LaTeXView(latex: problem.content)
                                    .frame(minHeight: 70)
                            } else {
                                Text(problem.content)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        
                        // Setup Strategy Card (Step 1 & Step 2)
                        if showSetupStrategy {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "lightbulb.fill")
                                        .foregroundColor(.orange)
                                    Text("Setup Strategy (Step 1 & Step 2)")
                                        .font(.headline)
                                    Spacer()
                                }
                                
                                // Step 1
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Step 1: Problem Classification & Governing Law")
                                        .font(.caption)
                                        .bold()
                                        .foregroundColor(.blue)
                                    if isLaTeX(step1) {
                                        LaTeXView(latex: step1)
                                            .frame(minHeight: 40)
                                    } else {
                                        Text(step1)
                                            .font(.body)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.blue.opacity(0.06))
                                .cornerRadius(8)
                                
                                // Step 2
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Step 2: Coordinate Frame & Initial Equation Setup")
                                        .font(.caption)
                                        .bold()
                                        .foregroundColor(.green)
                                    if isLaTeX(step2) {
                                        LaTeXView(latex: step2)
                                            .frame(minHeight: 40)
                                    } else {
                                        Text(step2)
                                            .font(.body)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.green.opacity(0.06))
                                .cornerRadius(8)
                                
                                if let rem = remainderNote {
                                    Text(rem)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding(.top, 2)
                                }
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 4)
                }
                
                // Problem Controls Action Bar
                HStack(spacing: 16) {
                    Button(action: {
                        if currentProblemIndex > 0 {
                            withAnimation {
                                currentProblemIndex -= 1
                                showSetupStrategy = false
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Previous Problem")
                        }
                        .frame(minWidth: 140)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .pointingHandCursor()
                    .disabled(currentProblemIndex == 0)
                    
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            showSetupStrategy.toggle()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: showSetupStrategy ? "eye.slash.fill" : "eye.fill")
                            Text(showSetupStrategy ? "Hide Strategy" : "Reveal Setup Strategy")
                        }
                        .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
                    .pointingHandCursor()
                    
                    if currentProblemIndex < warmupProblems.count - 1 {
                        Button(action: {
                            withAnimation {
                                currentProblemIndex += 1
                                showSetupStrategy = false
                            }
                        }) {
                            HStack(spacing: 4) {
                                Text("Next Problem")
                                Image(systemName: "chevron.right")
                            }
                            .frame(minWidth: 140)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .pointingHandCursor()
                    } else {
                        Button(action: {
                            withAnimation {
                                activePhase = 3
                            }
                        }) {
                            HStack(spacing: 4) {
                                Text("Proceed to Phase 3 →")
                                    .bold()
                            }
                            .frame(minWidth: 140)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.large)
                        .pointingHandCursor()
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }
    
    // MARK: - Phase 3: Core Identity Dump & Mental Reset
    @ViewBuilder
    private var phase3View: some View {
        VStack(spacing: 0) {
            // Phase 3 Sub-Navigation Tabs Bar
            HStack(spacing: 8) {
                Phase3TabButton(
                    title: "Prepared Notes",
                    icon: "doc.text.fill",
                    isSelected: phase3SubTab == 0,
                    action: { phase3SubTab = 0 }
                )
                
                Phase3TabButton(
                    title: "Pinned Problems (\(pinnedProblemIds.count))",
                    icon: "pin.fill",
                    isSelected: phase3SubTab == 1,
                    action: { phase3SubTab = 1 }
                )
                
                Phase3TabButton(
                    title: "Mental Reset",
                    icon: "brain.head.profile",
                    isSelected: phase3SubTab == 2,
                    action: { phase3SubTab = 2 }
                )
                
                Spacer()
                
                if phase3SubTab == 0 {
                    Button(action: {
                        withAnimation {
                            if isEditingNotes {
                                savePreparedNotes()
                            }
                            isEditingNotes.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isEditingNotes ? "checkmark.circle.fill" : "pencil")
                            Text(isEditingNotes ? "Done Editing" : "Edit Notes")
                        }
                        .font(.caption)
                        .bold()
                        .foregroundColor(isEditingNotes ? .green : .blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isEditingNotes ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Sub-Tab Body Content
            VStack {
                if phase3SubTab == 0 {
                    preparedNotesView
                } else if phase3SubTab == 1 {
                    pinnedProblemsTabView
                } else {
                    mentalResetTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Sub-Tab 0: Prepared Notes (Editor / Viewer)
    @ViewBuilder
    private var preparedNotesView: some View {
        if isEditingNotes {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pre-Exam Prepared Notes Editor")
                            .font(.headline)
                        Text("Write down LaTeX formulas and key notes you want fresh before the exam. Saved automatically.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    HStack(spacing: 10) {
                        Button(action: {
                            showLatexHelper = true
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                Text("AI Help / Paste Screenshot")
                            }
                            .font(.caption)
                            .bold()
                            .foregroundColor(.purple)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Describe an equation or paste a screenshot from clipboard to convert into LaTeX code")
                        
                        Button(action: {
                            withAnimation {
                                savePreparedNotes()
                                isEditingNotes = false
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                Text("Save & Done")
                            }
                            .font(.caption)
                            .bold()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                
                // Text Editor & Live LaTeX Preview Stack
                GeometryReader { geo in
                    VStack(spacing: 10) {
                        // Text Editor
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Editor (Markdown & LaTeX)")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            TextEditor(text: $preparedNotesText)
                                .font(.system(.body, design: .monospaced))
                                .padding(8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        }
                        .frame(height: geo.size.height * 0.52)
                        
                        // Live Preview Panel
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Live Math Preview")
                                .font(.caption2)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    if isLaTeX(preparedNotesText) {
                                        LaTeXView(latex: preparedNotesText)
                                            .frame(minHeight: 80)
                                    } else {
                                        Text(preparedNotesText.isEmpty ? "(Preview will appear here as you type)" : preparedNotesText)
                                            .font(.system(size: 15))
                                            .foregroundColor(preparedNotesText.isEmpty ? .secondary : .primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(12)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        }
                        .frame(height: geo.size.height * 0.44)
                    }
                    .padding(.horizontal, 24)
                }
            }
        } else {
            // Notes Viewer
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("1-Page Formula & Identity Cheat Sheet")
                                .font(.title2)
                                .bold()
                            Text("Review your pre-written notes now before closing your computer 15 minutes prior to the exam.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        
                        Button(action: {
                            withAnimation {
                                isEditingNotes = true
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil")
                                Text("Edit Notes")
                            }
                            .font(.caption)
                            .bold()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    if preparedNotesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.badge.plus")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("No Prepared Notes Yet")
                                .font(.headline)
                            Text("Click 'Edit Notes' above to type in formulas, definitions, and reminders to review right before your exam.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            
                            Button("Edit Notes Now") {
                                withAnimation {
                                    isEditingNotes = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(40)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            if isLaTeX(preparedNotesText) {
                                LaTeXView(latex: preparedNotesText)
                                    .frame(minHeight: 180)
                            } else {
                                Text(preparedNotesText)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
                .padding(24)
            }
        }
    }
    
    // MARK: - Sub-Tab 1: Pinned Problems Page (Phase 2 Review)
    @ViewBuilder
    private var pinnedProblemsTabView: some View {
        let pinnedList = warmupProblems.filter { pinnedProblemIds.contains($0.id) }
        
        if pinnedList.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "pin.slash")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("No Pinned Problems")
                    .font(.title2)
                    .bold()
                Text("When practicing problems in Phase 2 (Setup Warmup), click 'Pin to Phase 3' on any tricky setups you want to review here.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                
                Button("Go to Phase 2: Setup Warmup") {
                    withAnimation {
                        activePhase = 2
                    }
                }
                .buttonStyle(.bordered)
                .padding(.top, 8)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Phase 2 Pinned Setups (\(pinnedList.count))")
                                .font(.title2)
                                .bold()
                            Text("Tricky problem classifications and starting equations pinned during your Phase 2 warmup.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    
                    ForEach(pinnedList) { prob in
                        let topic = topicsMap[prob.topicId]
                        let (s1, s2, _) = extractStep1And2(from: prob)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                if let t = topic {
                                    Text("Week \(t.week): \(t.name)")
                                        .font(.caption)
                                        .bold()
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.orange.opacity(0.12))
                                        .foregroundColor(.orange)
                                        .cornerRadius(4)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    togglePinProblem(prob.id)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "pin.slash")
                                        Text("Unpin")
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                            }
                            
                            // Problem Text
                            if isLaTeX(prob.content) {
                                LaTeXView(latex: prob.content)
                                    .frame(minHeight: 50)
                            } else {
                                Text(prob.content)
                                    .font(.system(size: 14, weight: .medium))
                            }
                            
                            Divider()
                            
                            // Step 1
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Step 1: Governing Law & Symmetry")
                                    .font(.caption2)
                                    .bold()
                                    .foregroundColor(.blue)
                                if isLaTeX(s1) {
                                    LaTeXView(latex: s1).frame(minHeight: 35)
                                } else {
                                    Text(s1).font(.callout)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.blue.opacity(0.06))
                            .cornerRadius(6)
                            
                            // Step 2
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Step 2: Coordinate Frame & Initial Equation Setup")
                                    .font(.caption2)
                                    .bold()
                                    .foregroundColor(.green)
                                if isLaTeX(s2) {
                                    LaTeXView(latex: s2).frame(minHeight: 35)
                                } else {
                                    Text(s2).font(.callout)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.06))
                            .cornerRadius(6)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
                .padding(24)
            }
        }
    }
    
    // MARK: - Sub-Tab 2: Mental Reset & Breathing Grounding
    @ViewBuilder
    private var mentalResetTabView: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 4-4-4-4 Box Breathing Visualizer
                VStack(spacing: 20) {
                    HStack {
                        Image(systemName: "wind")
                            .foregroundColor(.blue)
                        Text("4-4-4-4 Box Breathing Pacer")
                            .font(.headline)
                        Spacer()
                    }
                    
                    let phaseNames = ["Inhale", "Hold", "Exhale", "Hold"]
                    let currentPhaseName = phaseNames[breathingPhaseIndex]
                    
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 130, height: 130)
                            .scaleEffect(breathingScale)
                            .animation(.easeInOut(duration: 4.0), value: breathingScale)
                        
                        Circle()
                            .stroke(Color.blue.opacity(0.4), lineWidth: 2)
                            .frame(width: 130, height: 130)
                        
                        VStack(spacing: 2) {
                            Text(currentPhaseName)
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            Text("4s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 230)
                    .padding(.vertical, 6)
                    
                    HStack(spacing: 8) {
                        Button(action: {
                            if breathingTimer != nil {
                                stopBreathingGuide()
                            } else {
                                startBreathingGuide()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: breathingTimer != nil ? "pause.circle.fill" : "play.circle.fill")
                                Text(breathingTimer != nil ? "Pause Breathing Guide" : "Start Breathing Guide")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .pointingHandCursor()
                    }
                }
                .padding(24)
                .frame(maxWidth: 540)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.blue.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.2), lineWidth: 1))
                
                // Pre-Flight Checklist
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pre-Flight Exam Checklist")
                        .font(.headline)
                    
                    ChecklistRow(title: "Calculator in correct Angle Mode (Radian vs Degree)", isChecked: $checklistCompleted[0])
                    ChecklistRow(title: "2 working pens, pencils, ruler, eraser ready", isChecked: $checklistCompleted[1])
                    ChecklistRow(title: "Student ID & water bottle ready on desk", isChecked: $checklistCompleted[2])
                    ChecklistRow(title: "First 60s Strategy: Flip paper & write down 5 key identities immediately", isChecked: $checklistCompleted[3])
                }
                .padding(18)
                .frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(NSColor.controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                
                // Action: Enter Exam Mode
                Button(action: {
                    onFinishWarmup()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.title3)
                        Text("Enter Exam Mode / Begin Exam")
                            .font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .pointingHandCursor()
                .padding(.bottom, 20)
            }
            .padding(24)
        }
    }
    
    // MARK: - Helpers
    private func loadCuratedCards() {
        guard let mod = activeModule else { return }
        let cardIdsKey = "pre_exam_ai_cards_\(mod.id)"
        let allCards = DatabaseManager.shared.getFlashcards(forModuleId: mod.id).filter { !$0.isFlagged }
        
        if let storedIds = UserDefaults.standard.array(forKey: cardIdsKey) as? [Int], !storedIds.isEmpty {
            let matched = storedIds.compactMap { id in allCards.first(where: { $0.id == id }) }
            if !matched.isEmpty {
                curatedCards = matched
                return
            }
        }
        
        // Fallback to top 25 SM-2 non-flagged cards if AI curation hasn't been run yet or stored IDs no longer match
        curatedCards = Array(allCards.sorted(by: { $0.easeFactor < $1.easeFactor }).prefix(25))
    }
    
    private func loadPhase2WarmupProblems() {
        guard let mod = activeModule else { return }
        let topics = DatabaseManager.shared.getTopics(forModuleId: mod.id).sorted(by: { $0.week < $1.week })
        topicsMap = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0) })
        
        let allProblems = DatabaseManager.shared.getProblems(forModuleId: mod.id).filter { !$0.isFlagged }
        guard !allProblems.isEmpty else {
            warmupProblems = []
            return
        }
        
        var selected: [Problem] = []
        if !topics.isEmpty {
            // Even spread: pick 1-2 problems per topic across all weeks
            for topic in topics {
                let topicProbs = allProblems.filter { $0.topicId == topic.id }
                if let best = topicProbs.sorted(by: { $0.severityLevel > $1.severityLevel }).first {
                    selected.append(best)
                }
            }
            
            // If fewer than 8 problems, fill in from remaining problems across topics
            if selected.count < 8 {
                let remaining = allProblems.filter { p in !selected.contains(where: { $0.id == p.id }) }
                let needed = min(8 - selected.count, remaining.count)
                selected.append(contentsOf: remaining.shuffled().prefix(needed))
            }
            
            // Cap at 12 problems maximum
            if selected.count > 12 {
                selected = Array(selected.prefix(12))
            }
        } else {
            // If no topics defined, sample 8-12 evenly across ID range
            let sorted = allProblems.sorted(by: { $0.id < $1.id })
            let strideCount = max(1, sorted.count / min(10, sorted.count))
            selected = Array(stride(from: 0, to: sorted.count, by: strideCount).map { sorted[$0] }.prefix(12))
        }
        
        warmupProblems = selected
        
        // Load pinned problem notes
        let pinnedKey = "pre_exam_pinned_problems_\(mod.id)"
        if let stored = UserDefaults.standard.array(forKey: pinnedKey) as? [Int] {
            pinnedProblemIds = Set(stored)
        }
    }
    
    private func extractStep1And2(from problem: Problem) -> (step1: String, step2: String, remainderNote: String?) {
        // Try parsing JSON steps array first
        if let data = problem.steps.data(using: .utf8),
           let steps = try? JSONDecoder().decode([String].self, from: data),
           !steps.isEmpty {
            let s1 = steps.count > 0 ? steps[0] : "Classify problem symmetry and determine governing physical law / theorem."
            let s2 = steps.count > 1 ? steps[1] : "Formulate coordinate system, vector decomposition, and initial boundary equation."
            let remainder = steps.count > 2 ? "\(steps.count - 2) additional algebraic steps omitted to preserve exam focus." : nil
            return (s1, s2, remainder)
        }
        
        // Try parsing newline-delimited steps
        let rawSteps = problem.steps.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !rawSteps.isEmpty {
            let s1 = rawSteps.count > 0 ? rawSteps[0] : "Classify problem symmetry and determine governing physical law / theorem."
            let s2 = rawSteps.count > 1 ? rawSteps[1] : "Formulate coordinate system, vector decomposition, and initial boundary equation."
            let remainder = rawSteps.count > 2 ? "\(rawSteps.count - 2) additional algebraic steps omitted to preserve exam focus." : nil
            return (s1, s2, remainder)
        }
        
        // Fallback to solution hint / solution text
        let hint = problem.solutionHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let sol = problem.solution.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let s1 = !hint.isEmpty ? hint : "Classify problem archetype and apply governing law."
        let s2 = !sol.isEmpty ? String(sol.prefix(250)) : "Substitute initial conditions into governing equation."
        return (s1, s2, nil)
    }
    
    private func togglePinProblem(_ problemId: Int) {
        guard let mod = activeModule else { return }
        if pinnedProblemIds.contains(problemId) {
            pinnedProblemIds.remove(problemId)
        } else {
            pinnedProblemIds.insert(problemId)
        }
        let pinnedKey = "pre_exam_pinned_problems_\(mod.id)"
        UserDefaults.standard.set(Array(pinnedProblemIds), forKey: pinnedKey)
        UserDefaults.standard.synchronize()
    }
    
    private func loadPreparedNotes() {
        guard let mod = activeModule else { return }
        let notesKey = "pre_exam_prepared_notes_\(mod.id)"
        if let stored = UserDefaults.standard.string(forKey: notesKey) {
            if stored.contains("% 1-Page Core Identities & Formulas") {
                preparedNotesText = ""
                UserDefaults.standard.removeObject(forKey: notesKey)
            } else {
                preparedNotesText = stored
            }
        } else {
            preparedNotesText = ""
        }
    }
    
    private func savePreparedNotes() {
        guard let mod = activeModule else { return }
        let notesKey = "pre_exam_prepared_notes_\(mod.id)"
        UserDefaults.standard.set(preparedNotesText, forKey: notesKey)
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - LaTeX AI Helper Methods & Sheet
    private var latexHelperSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("AI LaTeX Equation & Screenshot Translator")
                        .font(.title2)
                        .bold()
                    
                    Text("Paste an image from your clipboard (e.g. screenshot of a formula or notes) or describe an equation in plain text, and AI will convert it into clean LaTeX code.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 15) {
                        // Left Column: Plain text input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Equation Description:")
                                .bold()
                            TextField("e.g. divergence of B is zero", text: $latexInput)
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
                            Text("Clipboard Screenshot Preview:")
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
                            
                            Button("Paste Screenshot from Clipboard") {
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
                                Text("Translating equation via AI...")
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
                    if !latexResult.isEmpty && !latexResult.hasPrefix("Error:") && !latexResult.hasPrefix("No vision model") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Live Math Preview:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            LaTeXView(latex: latexResult)
                                .frame(height: 60)
                                .background(Color.secondary.opacity(0.05))
                                .cornerRadius(6)
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Button("Insert into Notes") {
                    let wrapped = wrapInLaTeXDelimiters(latexResult)
                    preparedNotesText += (preparedNotesText.isEmpty ? "" : "\n\n") + wrapped
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(latexResult.isEmpty || latexResult.hasPrefix("Error:") || latexResult.hasPrefix("No vision model"))
            }
        }
        .padding(20)
        .frame(width: 580, height: 500)
    }
    
    private func wrapInLaTeXDelimiters(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") { return trimmed }
        if trimmed.hasPrefix("$") && trimmed.hasSuffix("$") { return trimmed }
        if trimmed.hasPrefix("\\[") && trimmed.hasSuffix("\\]") { return trimmed }
        if trimmed.hasPrefix("\\(") && trimmed.hasSuffix("\\)") { return trimmed }
        return "$$\n\(trimmed)\n$$"
    }
    
    private func pasteClipboardImage() {
        if let image = NSImage(pasteboard: NSPasteboard.general) {
            self.latexClipboardImage = image
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
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateToLaTeX(rawEquation: latexInput)
            DispatchQueue.main.async {
                self.isTranslatingLaTeX = false
                if let latex = res {
                    let wrapped = self.wrapInLaTeXDelimiters(latex)
                    self.latexResult = wrapped
                } else {
                    self.latexResult = "Error: Could not translate equation. Verify that your AI host (Local or Tailscale) is connected."
                }
            }
        }
    }
    
    private func translateImageToLatex() {
        self.isTranslatingLaTeX = true
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateImageToLaTeX(base64Image: latexImageBase64)
            DispatchQueue.main.async {
                self.isTranslatingLaTeX = false
                if let latex = res {
                    if latex == "MODEL_NOT_FOUND" {
                        self.latexResult = "No vision model found on AI server. Please pull qwen2.5vl."
                    } else {
                        let wrapped = self.wrapInLaTeXDelimiters(latex)
                        self.latexResult = wrapped
                    }
                } else {
                    self.latexResult = "Error: Could not transcribe equation image. Verify that your AI host (Local or Tailscale) is connected."
                }
            }
        }
    }
    
    private func resetLatexHelper() {
        latexInput = ""
        latexClipboardImage = nil
        latexImageBase64 = ""
        latexResult = ""
        isTranslatingLaTeX = false
    }
    
    private func startResetTimer() {
        isResetTimerRunning = true
        resetTimer?.invalidate()
        resetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if self.resetTimerSeconds > 0 {
                    self.resetTimerSeconds -= 1
                } else {
                    self.pauseResetTimer()
                }
            }
        }
    }
    
    private func pauseResetTimer() {
        isResetTimerRunning = false
        resetTimer?.invalidate()
        resetTimer = nil
    }
    
    private func resetResetTimer() {
        pauseResetTimer()
        resetTimerSeconds = 900
    }
    
    private func stopResetTimer() {
        resetTimer?.invalidate()
        resetTimer = nil
        isResetTimerRunning = false
    }
    
    private func startBreathingGuide() {
        stopBreathingGuide()
        breathingPhaseIndex = 0
        breathingScale = 1.45 // Begin expansion
        
        breathingTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { _ in
            Task { @MainActor in
                self.breathingPhaseIndex = (self.breathingPhaseIndex + 1) % 4
                if self.breathingPhaseIndex == 0 {
                    // Inhale
                    self.breathingScale = 1.45
                } else if self.breathingPhaseIndex == 1 {
                    // Hold
                    self.breathingScale = 1.45
                } else if self.breathingPhaseIndex == 2 {
                    // Exhale
                    self.breathingScale = 1.0
                } else {
                    // Hold
                    self.breathingScale = 1.0
                }
            }
        }
    }
    
    private func stopBreathingGuide() {
        breathingTimer?.invalidate()
        breathingTimer = nil
        breathingScale = 1.0
        breathingPhaseIndex = 0
    }
    
    private func resetPhaseTimer() {
        phaseTimeRemainingSeconds = phaseDurationMinutes * 60
    }
    
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if self.phaseTimeRemainingSeconds > 0 {
                    self.phaseTimeRemainingSeconds -= 1
                }
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Phase 3 Sub-Tab Button Component
struct Phase3TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

// MARK: - Checklist Row Component
struct ChecklistRow: View {
    let title: String
    @Binding var isChecked: Bool
    
    var body: some View {
        Button(action: {
            isChecked.toggle()
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(isChecked ? .green : .secondary)
                
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(isChecked ? .secondary : .primary)
                    .strikethrough(isChecked, color: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

// MARK: - Phase Header Tab Component (No Time in Title)
struct PhaseHeaderTab: View {
    let phaseNumber: Int
    let title: String
    let isActive: Bool
    let isCompleted: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isActive ? Color.blue : (isCompleted ? Color.green : Color.secondary.opacity(0.2)))
                        .frame(width: 22, height: 22)
                    
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(phaseNumber)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isActive ? .white : .primary)
                    }
                }
                
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .bold : .medium))
                    .foregroundColor(isActive ? .primary : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.blue.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
