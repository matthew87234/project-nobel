import SwiftUI
import AppKit
import WebKit
import Charts
@preconcurrency import UserNotifications

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

enum ActiveChartPopup: String, Identifiable {
    case weeklyAvgTime = "Weekly Average Time Distribution"
    case dueProjection = "7-Day Due Cards Workload Projection"
    case easeDistribution = "Ease Factor & Mastery Distribution"
    case cumulativeCreated = "Cumulative Flashcards Growth"
    
    var id: String { rawValue }
}

enum FlashcardMode {
    case start
    case review
    case add
    case manage
}

enum SessionPreset: String, CaseIterable, Identifiable {
    case short = "Short"
    case optimal = "Optimal"
    case long = "Long"
    case custom = "Custom"
    
    var id: String { rawValue }
    
    var baseCardCount: Int {
        switch self {
        case .short: return 10
        case .optimal: return 30
        case .long: return 60
        case .custom: return 25
        }
    }
}

enum SessionFocusFilter: String, CaseIterable, Identifiable {
    case allDue = "All Due Cards"
    case lowEase = "Weak Cards"
    
    var id: String { rawValue }
}

struct FlipCardView: View {
    let front: String
    let back: String
    @Binding var isFlipped: Bool
    var isFlagged: Bool = false
    var onToggleFlag: (() -> Void)? = nil
    
    var body: some View {
        ZStack {
            // Front Card
            VStack {
                HStack {
                    Spacer()
                    if isFlagged {
                        Image(systemName: "flag.fill")
                            .foregroundColor(.purple)
                            .padding(.top, 14)
                            .padding(.trailing, 16)
                    }
                }
                Spacer()
                if isLaTeX(front) {
                    LaTeXView(latex: front)
                        .frame(height: 130)
                        .padding(.horizontal, 20)
                } else {
                    Text(front)
                        .font(.system(size: 20, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 25)
                }
                Spacer()
                Text("Click to Flip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
            .opacity(isFlipped ? 0.0 : 1.0)
            .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0.0, y: 1.0, z: 0.0))
            
            // Back Card
            VStack {
                HStack {
                    Spacer()
                    if let onToggleFlag = onToggleFlag {
                        Button(action: onToggleFlag) {
                            HStack(spacing: 4) {
                                Image(systemName: isFlagged ? "flag.fill" : "flag")
                                    .foregroundColor(isFlagged ? .purple : .secondary)
                                Text(isFlagged ? "Flagged" : "Flag")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(isFlagged ? .purple : .secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.purple.opacity(isFlagged ? 0.15 : 0.06))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .padding(.top, 12)
                        .padding(.trailing, 14)
                    }
                }
                Spacer()
                if isLaTeX(back) {
                    LaTeXView(latex: back)
                        .frame(height: 130)
                        .padding(.horizontal, 20)
                } else {
                    Text(back)
                        .font(.system(size: 20, weight: .medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 25)
                }
                Spacer()
                Text("Click to Flip")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
            .opacity(isFlipped ? 1.0 : 0.0)
            .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0.0, y: 1.0, z: 0.0))
        }
        .frame(height: 280)
        .frame(maxWidth: 520)
        .pointingHandCursor()
    }
}

struct MetricCardView: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color
    let onClick: (() -> Void)?
    
    @State private var isHovered: Bool = false
    
    init(title: String, value: String, subtitle: String, color: Color, onClick: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.color = color
        self.onClick = onClick
    }
    
    var body: some View {
        Button(action: {
            onClick?()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if onClick != nil {
                        Image(systemName: "chart.bar.fill")
                            .font(.caption)
                            .foregroundColor(isHovered ? color : .secondary.opacity(0.6))
                    }
                }
                
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered && onClick != nil ? color.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: isHovered && onClick != nil ? 1.5 : 1)
            )
            .shadow(color: isHovered && onClick != nil ? color.opacity(0.15) : Color.clear, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hover
            }
        }
    }
}
struct PresetCardView: View {
    let cardCount: Int
    let estimatedMinutes: Int
    let isSelected: Bool
    let isRecommended: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(cardCount) Cards")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? .blue : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    
                    Spacer()
                    
                    if isRecommended {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(4)
                            .background(Color.blue.opacity(0.18))
                            .foregroundColor(.blue)
                            .clipShape(Circle())
                            .help("Recommended Target")
                    }
                }
                
                Text("Est: ~\(estimatedMinutes) Mins")
                    .font(.system(.subheadline, design: .monospaced))
                    .bold()
                    .foregroundColor(isSelected ? .blue : .secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.08) : Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

struct FlashcardsView: View {
    let activeModuleId: Int?
    var activeYear: Int = 1
    let mode: FlashcardMode
    let isExamMode: Bool
    var isActive: Bool = true
    
    @State private var currentMode: FlashcardMode = .start
    
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
    @State private var requeuedCount: Int = 0
    @State private var cardRequeueCounts: [Int: Int] = [:]
    
    // Session Presets & Settings State
    @State private var selectedPreset: SessionPreset = .optimal
    @State private var customCardCount: Int = 25
    @State private var targetCardCount: Int = 30
    @State private var targetSessionMinutes: Int = 15
    @State private var sessionFocusFilter: SessionFocusFilter = .allDue
    @State private var cardsReviewedInSession: Int = 0
    @State private var isSessionComplete: Bool = false
    @State private var allCards: [Flashcard] = []
    
    // Idle 5-Minute Prompt & Graph Popups State
    @State private var secondsSinceLastCard: Int = 0
    @State private var showIdlePrompt: Bool = false
    @State private var activeChartPopup: ActiveChartPopup? = nil
    
    // Manage & Edit State
    @State private var selectedCards = Set<Flashcard.ID>()
    @State private var searchField: String = ""
    @State private var editingCard: Flashcard? = nil
    @State private var editFrontText: String = ""
    @State private var editBackText: String = ""
    @State private var showEditCardSheet: Bool = false
    
    // Flagged Correction Queue State
    @State private var flaggedCorrectionQueue: [Flashcard] = []
    @State private var flaggedCardIdx: Int = 0
    @State private var isCorrectingFlaggedCards: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            switch currentMode {
            case .start:
                startBody
            case .review:
                reviewBody
            case .add:
                addBody
            case .manage:
                manageBody
            }
        }
        .onAppear {
            if currentMode != .review || dueCards.isEmpty || isSessionComplete {
                currentMode = mode
            }
            if isActive {
                if currentMode == .review && !dueCards.isEmpty && !isSessionComplete {
                    startTimer()
                } else {
                    loadInitialData()
                    if currentMode == .add {
                        setupFlaggedCorrectionQueue()
                        focusedField = .front
                    }
                }
            }
        }
        .onChange(of: currentMode) { _, newMode in
            loadInitialData()
            if newMode == .add {
                setupFlaggedCorrectionQueue()
            }
        }
        .onChange(of: activeModuleId) { oldValue, newValue in
            currentMode = mode
            dueCards.removeAll()
            isSessionComplete = false
            currentCardIdx = 0
            if isActive {
                loadInitialData()
            }
        }
        .onChange(of: isActive) { oldValue, newValue in
            if newValue {
                if currentMode == .review && !dueCards.isEmpty && !isSessionComplete {
                    startTimer()
                } else {
                    loadInitialData()
                    if mode == .add {
                        focusedField = .front
                    }
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
        if currentMode == .review {
            loadDueCards()
            startTimer()
        } else if currentMode == .manage {
            loadAllCards()
        } else {
            loadAllCards()
            loadDueCards()
        }
    }
    
    private func startTimer() {
        fcTimer?.invalidate()
        fcTimerSeconds = 0
        secondsSinceLastCard = 0
        showIdlePrompt = false
        
        fcTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                guard !showIdlePrompt else { return }
                
                fcTimerSeconds += 1
                secondsSinceLastCard += 1
                
                if fcTimerSeconds % 10 == 0 {
                    DatabaseManager.shared.addStudyTime(flashcardsDelta: 10, problemsDelta: 0)
                    if let modId = activeModuleId {
                        DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: 10, problemsDelta: 0)
                    }
                }
                
                if secondsSinceLastCard >= 300 && !showIdlePrompt {
                    showIdlePrompt = true
                }
            }
        }
    }
    
    private func deductIdleTime(seconds: Int) {
        fcTimerSeconds = max(0, fcTimerSeconds - seconds)
        DatabaseManager.shared.addStudyTime(flashcardsDelta: -seconds, problemsDelta: 0)
        if let modId = activeModuleId {
            DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: -seconds, problemsDelta: 0)
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
    
    private var weeklyAverageSecondsPerCard: Double {
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: sevenDaysAgo)
        
        let (avgFc, _) = DatabaseManager.shared.getAvgSolveTimes(timeframeStartDate: dateStr, moduleId: nil)
        return avgFc
    }
    
    private var weeklyAverageTimeFormatted: String {
        let avg = weeklyAverageSecondsPerCard
        if avg <= 0.0 {
            return "N/A"
        } else if avg < 60.0 {
            return String(format: "%.1fs", avg)
        } else {
            let mins = Int(avg) / 60
            let secs = Int(avg) % 60
            return "\(mins)m \(secs)s"
        }
    }
    
    private var averageSecondsPerCard: Double {
        let calendar = Calendar.current
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: thirtyDaysAgo)
        
        let (avgFc, _) = DatabaseManager.shared.getAvgSolveTimes(timeframeStartDate: dateStr, moduleId: nil)
        if avgFc >= 5.0 && avgFc <= 120.0 {
            return avgFc
        }
        return 30.0 // Default 30 seconds fallback per card
    }
    
    private func estimatedMinutes(forCardCount count: Int) -> Int {
        let seconds = Double(count) * averageSecondsPerCard
        return max(1, Int(ceil(seconds / 60.0)))
    }
    
    private func startNewSession(studyAhead: Bool = false) {
        let cardCount = (selectedPreset == .custom) ? customCardCount : selectedPreset.baseCardCount
        targetCardCount = cardCount
        targetSessionMinutes = estimatedMinutes(forCardCount: cardCount)
        
        loadDueCards(limit: cardCount, studyAhead: studyAhead)
        cardsReviewedInSession = 0
        requeuedCount = 0
        isSessionComplete = false
        currentMode = .review
        startTimer()
    }
    
    private func formatSessionTime(_ totalSeconds: Int) -> String {
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    @ObservedObject private var ankiEngine = AnkiSyncEngine.shared
    
    // MARK: - Start Landing View
    
    private var startBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RatioTrackerBar(isExamMode: isExamMode)
                
                // Statistics Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricCardView(
                        title: "Weekly Avg / Card",
                        value: weeklyAverageTimeFormatted,
                        subtitle: "7-day avg pace",
                        color: .blue,
                        onClick: { activeChartPopup = .weeklyAvgTime }
                    )
                    MetricCardView(
                        title: "Due for Review",
                        value: "\(dueCards.count)",
                        subtitle: "Ready for practice",
                        color: .orange,
                        onClick: { activeChartPopup = .dueProjection }
                    )
                    MetricCardView(
                        title: "Mastery Level",
                        value: calculateMasteryPercentage(),
                        subtitle: "Ease \u{2265} 2.2 & reps \u{2265} 1",
                        color: .green,
                        onClick: { activeChartPopup = .easeDistribution }
                    )
                    MetricCardView(
                        title: "Total Cards",
                        value: "\(allCards.count)",
                        subtitle: isExamMode ? "Selected module" : "Across Year \(activeYear) modules",
                        color: .purple,
                        onClick: { activeChartPopup = .cumulativeCreated }
                    )
                }
                
                // Session Setup & Target Duration Configurator
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Session Target Presets")
                            .font(.title3)
                            .bold()
                        
                        Spacer()
                        
                        Text("Pace: ~\(Int(averageSecondsPerCard))s / card")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 14) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(SessionPreset.allCases) { preset in
                                let count = (preset == .custom) ? customCardCount : preset.baseCardCount
                                let estMins = estimatedMinutes(forCardCount: count)
                                PresetCardView(
                                    cardCount: count,
                                    estimatedMinutes: estMins,
                                    isSelected: selectedPreset == preset,
                                    isRecommended: preset == .optimal
                                ) {
                                    selectedPreset = preset
                                }
                            }
                        }
                        
                        if selectedPreset == .custom {
                            HStack {
                                Text("Custom Card Target:")
                                    .font(.subheadline)
                                    .bold()
                                
                                Stepper("\(customCardCount) Cards", value: $customCardCount, in: 5...200, step: 5)
                                    .frame(width: 160)
                                
                                Text("Est: ~\(estimatedMinutes(forCardCount: customCardCount)) Mins")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 4)
                        }
                        
                        HStack {
                            Text("Focus Filter:")
                                .font(.subheadline)
                                .bold()
                            
                            Picker("", selection: $sessionFocusFilter) {
                                ForEach(SessionFocusFilter.allCases) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 260)
                        }
                        .padding(.top, 4)
                        
                        Divider()
                            .padding(.vertical, 4)
                        
                        let activeCount = (selectedPreset == .custom) ? customCardCount : selectedPreset.baseCardCount
                        
                        if dueCards.isEmpty {
                            VStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(.green)
                                        .font(.title3)
                                    Text("All Caught Up for Today")
                                        .font(.headline)
                                        .foregroundColor(.green)
                                    Spacer()
                                    Text("\(allCards.count) Total Cards In Deck")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(12)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                                
                                HStack(spacing: 12) {
                                    Button(action: {
                                        startNewSession(studyAhead: true)
                                    }) {
                                        HStack {
                                            Image(systemName: "bolt.fill")
                                            Text("Study Ahead (\(min(activeCount, max(allCards.count, 1))) Cards • Extra Practice)")
                                                .font(.headline)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .pointingHandCursor()
                                    
                                    Button(action: {
                                        ankiEngine.syncWithAnki()
                                    }) {
                                        HStack(spacing: 8) {
                                            if ankiEngine.isSyncing {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "arrow.triangle.2.circlepath")
                                                    .font(.title2)
                                            }
                                            Text(ankiEngine.isSyncing ? "Syncing..." : "Sync with Anki")
                                                .font(.headline)
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.large)
                                    .pointingHandCursor()
                                }
                            }
                        } else {
                            HStack(spacing: 12) {
                                Button(action: {
                                    startNewSession(studyAhead: false)
                                }) {
                                    HStack {
                                        Image(systemName: "play.circle.fill")
                                            .font(.title2)
                                        Text("Start Review Session (\(min(activeCount, dueCards.count)) of \(dueCards.count) Due • Est: ~\(estimatedMinutes(forCardCount: min(activeCount, dueCards.count))) Mins)")
                                            .font(.headline)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .pointingHandCursor()
                                
                                Button(action: {
                                    ankiEngine.syncWithAnki()
                                }) {
                                    HStack(spacing: 8) {
                                        if ankiEngine.isSyncing {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .font(.title2)
                                        }
                                        Text(ankiEngine.isSyncing ? "Syncing..." : "Sync with Anki")
                                            .font(.headline)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .pointingHandCursor()
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
                }
            }
            .padding(24)
        }
        .sheet(item: $activeChartPopup) { popup in
            chartPopupSheet(for: popup)
        }
    }
    
    private func calculateMasteryPercentage() -> String {
        guard !allCards.isEmpty else { return "0%" }
        let mastered = allCards.filter { $0.repetitions >= 1 && $0.easeFactor >= 2.2 }.count
        let pct = Int(Double(mastered) / Double(allCards.count) * 100.0)
        return "\(pct)%"
    }
    
    // MARK: - Review Body
    
    private var reviewBody: some View {
        VStack(spacing: 15) {
            // 80/20 ratio tracker bar (above Back button)
            RatioTrackerBar(isExamMode: isExamMode)
                .padding(.horizontal)
                .padding(.top, 10)
            
            // Header Bar: Navigation & Progress
            HStack {
                Button(action: {
                    fcTimer?.invalidate()
                    logActiveSeconds()
                    currentMode = .start
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                
                Spacer()
                
                Text("Cards Reviewed: \(cardsReviewedInSession)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            
            if isSessionComplete {
                sessionCompleteView
            } else if dueCards.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.green)
                        .padding(.bottom, 12)
                    
                    Text("All Caught Up!")
                        .font(.title2)
                        .bold()
                    
                    Text("No flashcards found for the selected session filter. Great job!")
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    
                    Button("Return to Flashcard Centre") {
                        currentMode = .start
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                    .padding(.top, 16)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentCardIdx < dueCards.count {
                let card = dueCards[currentCardIdx]
                VStack(spacing: 16) {
                    HStack {
                        Spacer()
                        
                        Text("Card \(currentCardIdx + 1) of \(dueCards.count)")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        if requeuedCount > 0 {
                            Text("(+\(requeuedCount) re-queued)")
                                .font(.caption)
                                .bold()
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12))
                                .cornerRadius(4)
                        }
                        
                        Spacer()
                    }
                    
                    FlipCardView(
                        front: card.front,
                        back: card.back,
                        isFlipped: $isFlipped,
                        isFlagged: card.isFlagged,
                        onToggleFlag: { toggleCurrentCardFlag() }
                    )
                    .pointingHandCursor()
                    .onTapGesture {
                        withAnimation(.spring()) {
                            isFlipped.toggle()
                        }
                    }
                    
                    if isFlipped {
                        // Rating buttons with next review estimate intervals
                        VStack(spacing: 10) {
                            Text("How well did you remember this?")
                                .font(.subheadline)
                                .bold()
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 8) {
                                Button(action: { rateRecall(quality: 1) }) {
                                    VStack(spacing: 2) {
                                        Text("1. Again").bold()
                                        Text(estimateNextReviewText(card: card, quality: 1))
                                            .font(.caption2)
                                            .opacity(0.85)
                                    }
                                    .frame(minWidth: 70)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(.red)
                                .pointingHandCursor()
                                
                                Button(action: { rateRecall(quality: 2) }) {
                                    VStack(spacing: 2) {
                                        Text("2. Hard").bold()
                                        Text(estimateNextReviewText(card: card, quality: 2))
                                            .font(.caption2)
                                            .opacity(0.85)
                                    }
                                    .frame(minWidth: 70)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(.orange)
                                .pointingHandCursor()
                                
                                Button(action: { rateRecall(quality: 3) }) {
                                    VStack(spacing: 2) {
                                        Text("3. Good").bold()
                                        Text(estimateNextReviewText(card: card, quality: 3))
                                            .font(.caption2)
                                            .opacity(0.85)
                                    }
                                    .frame(minWidth: 70)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(.yellow)
                                .pointingHandCursor()
                                
                                Button(action: { rateRecall(quality: 4) }) {
                                    VStack(spacing: 2) {
                                        Text("4. Easy").bold()
                                        Text(estimateNextReviewText(card: card, quality: 4))
                                            .font(.caption2)
                                            .opacity(0.85)
                                    }
                                    .frame(minWidth: 70)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(.blue)
                                .pointingHandCursor()
                                
                                Button(action: { rateRecall(quality: 5) }) {
                                    VStack(spacing: 2) {
                                        Text("5. Perfect").bold()
                                        Text(estimateNextReviewText(card: card, quality: 5))
                                            .font(.caption2)
                                            .opacity(0.85)
                                    }
                                    .frame(minWidth: 70)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .tint(.green)
                                .pointingHandCursor()
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
                        .pointingHandCursor()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            ZStack {
                if !dueCards.isEmpty && currentCardIdx < dueCards.count && !isSessionComplete {
                    Button("") {
                        withAnimation(.spring()) {
                            isFlipped.toggle()
                        }
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    
                    if isFlipped {
                        Button("") { rateRecall(quality: 1) }
                            .keyboardShortcut("1", modifiers: [])
                            .opacity(0).frame(width: 0, height: 0)
                        
                        Button("") { rateRecall(quality: 2) }
                            .keyboardShortcut("2", modifiers: [])
                            .opacity(0).frame(width: 0, height: 0)
                        
                        Button("") { rateRecall(quality: 3) }
                            .keyboardShortcut("3", modifiers: [])
                            .opacity(0).frame(width: 0, height: 0)
                        
                        Button("") { rateRecall(quality: 4) }
                            .keyboardShortcut("4", modifiers: [])
                            .opacity(0).frame(width: 0, height: 0)
                        
                        Button("") { rateRecall(quality: 5) }
                            .keyboardShortcut("5", modifiers: [])
                            .opacity(0).frame(width: 0, height: 0)
                        
                        Button("") { toggleCurrentCardFlag() }
                            .keyboardShortcut("f", modifiers: [])
                            .opacity(0).frame(width: 0, height: 0)
                    }
                }
            }
        )
        .alert("Are you still there?", isPresented: $showIdlePrompt) {
            Button("I'm Still Here (Keep 5 Mins)") {
                secondsSinceLastCard = 0
                showIdlePrompt = false
            }
            Button("Deduct 5 Mins & Resume", role: .destructive) {
                deductIdleTime(seconds: 300)
                secondsSinceLastCard = 0
                showIdlePrompt = false
            }
            Button("Return to Flashcard Centre", role: .cancel) {
                deductIdleTime(seconds: 300)
                fcTimer?.invalidate()
                logActiveSeconds()
                showIdlePrompt = false
                currentMode = .start
            }
        } message: {
            Text("You haven't reviewed a flashcard in 5 minutes. The timer is currently paused.")
        }
    }
    
    private var sessionCompleteView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "star.fill")
                .font(.system(size: 64))
                .foregroundColor(.yellow)
            
            Text("Session Complete!")
                .font(.system(size: 28, weight: .bold))
            
            Text("Great job on completing your flashcard study session.")
                .foregroundColor(.secondary)
            
            VStack(spacing: 12) {
                HStack {
                    Text("Cards Reviewed:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(cardsReviewedInSession)").bold()
                }
                Divider()
                HStack {
                    Text("Total Session Time:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatSessionTime(fcTimerSeconds)).bold()
                }
                Divider()
                HStack {
                    Text("Session Goal:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(targetSessionMinutes == 0 ? "Unlimited" : "\(targetSessionMinutes) minutes").bold()
                }
            }
            .padding()
            .frame(maxWidth: 360)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
            
            Button("Return to Flashcard Centre") {
                fcTimer?.invalidate()
                logActiveSeconds()
                currentMode = .start
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
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
    
    private func loadDueCards(limit: Int? = nil, studyAhead: Bool = false) {
        let today = formatDate(Date())
        let targetModId = isExamMode ? activeModuleId : nil
        let targetYear = isExamMode ? nil : activeYear
        var cards: [Flashcard] = []
        
        switch sessionFocusFilter {
        case .allDue:
            if studyAhead {
                cards = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId).shuffled()
            } else {
                cards = DatabaseManager.shared.getDueFlashcards(forYear: targetYear, forModuleId: targetModId, today: today).shuffled()
            }
        case .lowEase:
            let all = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId)
            cards = all.filter { $0.easeFactor < 2.3 }.shuffled()
        }
        
        if let maxCards = limit, cards.count > maxCards {
            cards = Array(cards.prefix(maxCards))
        }
        
        self.dueCards = cards
        self.currentCardIdx = 0
        self.isFlipped = false
        self.cardRequeueCounts.removeAll()
    }
    
    private func calculateNextInterval(card: Flashcard, quality: Int) -> Int {
        if quality == 1 {
            return 1
        }
        
        let reps = card.repetitions
        let ease = card.easeFactor
        
        switch quality {
        case 2: // Hard
            if reps == 0 { return 1 }
            return max(1, Int(Double(card.interval) * 1.2))
        case 3: // Good
            if reps == 0 { return 2 }
            if reps == 1 { return 6 }
            return max(2, Int(Double(card.interval) * ease))
        case 4: // Easy
            if reps == 0 { return 4 }
            if reps == 1 { return 10 }
            return max(4, Int(Double(card.interval) * ease * 1.3))
        case 5: // Perfect
            if reps == 0 { return 7 }
            if reps == 1 { return 14 }
            return max(7, Int(Double(card.interval) * ease * 1.6))
        default:
            return 1
        }
    }
    
    private func rateRecall(quality: Int) {
        guard currentCardIdx < dueCards.count else { return }
        let card = dueCards[currentCardIdx]
        
        // SM-2 Spaced Repetition Algorithm
        let interval = calculateNextInterval(card: card, quality: quality)
        var easeFactor = card.easeFactor
        var repetitions = card.repetitions
        
        if quality >= 3 {
            repetitions += 1
        } else {
            repetitions = 0
        }
        
        easeFactor = easeFactor + (0.1 - (5.0 - Double(quality)) * (0.08 + (5.0 - Double(quality)) * 0.02))
        if easeFactor < 1.3 {
            easeFactor = 1.3
        }
        
        let calendar = Calendar.current
        let nextReview = calendar.date(byAdding: .day, value: interval, to: Date()) ?? Date()
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
        secondsSinceLastCard = 0
        
        // If rating is 1 (Again), re-queue card to the end of the pile max 2 times (3 total views)
        if quality == 1 {
            let previousRequeues = cardRequeueCounts[card.id, default: 0]
            if previousRequeues < 2 {
                cardRequeueCounts[card.id] = previousRequeues + 1
                dueCards.append(card)
                requeuedCount += 1
            }
        }
        
        // Advance
        withAnimation {
            isFlipped = false
            cardsReviewedInSession += 1
            if currentCardIdx + 1 < dueCards.count {
                currentCardIdx += 1
            } else {
                isSessionComplete = true
                fcTimer?.invalidate()
                logActiveSeconds()
            }
        }
    }
    
    private func estimateNextReviewText(card: Flashcard, quality: Int) -> String {
        if quality == 1 {
            return "< 10m"
        }
        
        let interval = calculateNextInterval(card: card, quality: quality)
        if interval <= 1 {
            return "1d"
        } else if interval < 30 {
            return "\(interval)d"
        } else {
            let months = String(format: "%.1f", Double(interval) / 30.0)
            return "\(months)mo"
        }
    }
    
    private func toggleCurrentCardFlag() {
        guard currentCardIdx < dueCards.count else { return }
        let card = dueCards[currentCardIdx]
        let newFlag = !card.isFlagged
        _ = DatabaseManager.shared.setFlashcardFlag(id: card.id, isFlagged: newFlag)
        dueCards[currentCardIdx].isFlagged = newFlag
    }
    
    private func setupFlaggedCorrectionQueue() {
        let flagged = allCards.filter { $0.isFlagged }
        self.flaggedCorrectionQueue = flagged
        self.flaggedCardIdx = 0
        if !flagged.isEmpty {
            self.isCorrectingFlaggedCards = true
            self.frontText = flagged[0].front
            self.backText = flagged[0].back
        } else {
            self.isCorrectingFlaggedCards = false
            self.frontText = ""
            self.backText = ""
        }
    }
    
    private func saveAndAdvanceFlaggedCard(unflag: Bool, cardId: Int) {
        _ = DatabaseManager.shared.updateFlashcard(
            id: cardId,
            front: frontText.trimmingCharacters(in: .whitespacesAndNewlines),
            back: backText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if unflag {
            _ = DatabaseManager.shared.setFlashcardFlag(id: cardId, isFlagged: false)
        }
        loadAllCards()
        
        let flaggedRemaining = allCards.filter { $0.isFlagged }
        self.flaggedCorrectionQueue = flaggedRemaining
        
        if flaggedCardIdx < flaggedRemaining.count {
            self.frontText = flaggedRemaining[flaggedCardIdx].front
            self.backText = flaggedRemaining[flaggedCardIdx].back
        } else if !flaggedRemaining.isEmpty {
            self.flaggedCardIdx = 0
            self.frontText = flaggedRemaining[0].front
            self.backText = flaggedRemaining[0].back
        } else {
            self.isCorrectingFlaggedCards = false
            self.frontText = ""
            self.backText = ""
            self.focusedField = .front
        }
    }
    
    // MARK: - Add Card Body
    
    private var addBody: some View {
        Form {
            if isCorrectingFlaggedCards && flaggedCardIdx < flaggedCorrectionQueue.count {
                let card = flaggedCorrectionQueue[flaggedCardIdx]
                Section(header: HStack {
                    Image(systemName: "flag.fill").foregroundColor(.purple)
                    Text("Correcting Flagged Card (\(flaggedCardIdx + 1) of \(flaggedCorrectionQueue.count))").font(.headline)
                    Spacer()
                    Button("Skip to Create New Cards") {
                        isCorrectingFlaggedCards = false
                        frontText = ""
                        backText = ""
                        focusedField = .front
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Question (Front):").bold()
                        TextEditor(text: $frontText)
                            .font(.body)
                            .focused($focusedField, equals: .front)
                            .onKeyPress(.tab) {
                                focusedField = .back
                                return .handled
                            }
                            .frame(height: 80)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                            )
                        
                        Text("Answer (Back):").bold()
                        TextEditor(text: $backText)
                            .font(.body)
                            .focused($focusedField, equals: .back)
                            .onKeyPress(.tab) {
                                focusedField = .front
                                return .handled
                            }
                            .frame(height: 80)
                            .padding(4)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.purple.opacity(0.4), lineWidth: 1)
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
                            .pointingHandCursor()
                            
                            Spacer()
                            
                            Button("Keep Flagged & Next") {
                                saveAndAdvanceFlaggedCard(unflag: false, cardId: card.id)
                            }
                            .buttonStyle(.bordered)
                            .pointingHandCursor()
                            
                            Button("Save & Unflag") {
                                saveAndAdvanceFlaggedCard(unflag: true, cardId: card.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .pointingHandCursor()
                            .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 10)
                }
            } else {
                Section(header: HStack {
                    Text("Create Flashcard").font(.headline)
                    Spacer()
                    let flaggedRemaining = allCards.filter { $0.isFlagged }
                    if !flaggedRemaining.isEmpty {
                        Button("Review Flagged Cards (\(flaggedRemaining.count))") {
                            setupFlaggedCorrectionQueue()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointingHandCursor()
                    }
                }) {
                    if activeModuleId == nil {
                        Text("Select a module in the sidebar first before adding cards.")
                            .foregroundColor(.red)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Front Content:").bold()
                            TextEditor(text: $frontText)
                                .font(.body)
                                .focused($focusedField, equals: .front)
                                .onKeyPress(.tab) {
                                    focusedField = .back
                                    return .handled
                                }
                                .frame(height: 80)
                                .padding(4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                 )
                            
                            Text("Back Content:").bold()
                            TextEditor(text: $backText)
                                .font(.body)
                                .focused($focusedField, equals: .back)
                                .onKeyPress(.tab) {
                                    focusedField = .front
                                    return .handled
                                }
                                .frame(height: 80)
                                .padding(4)
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
                                .pointingHandCursor()
                                
                                Spacer()
                                
                                Button(action: {
                                    saveCard()
                                }) {
                                    Text("Add Flashcard")
                                        .padding(.horizontal, 15)
                                }
                                .buttonStyle(.borderedProminent)
                                .pointingHandCursor()
                                .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .padding(.vertical, 10)
                    }
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
            sendAppNotification(title: "Flashcard Added", body: "Successfully created new flashcard.")
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
                    
                    Text("Describe an equation in plain text or paste an image from your clipboard, and AI will convert it into clean LaTeX code.")
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
                            
                            Button("Paste Image from Clipboard") {
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
                                Text("Translating via AI model...")
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
                    let wrapped = wrapInLaTeXDelimiters(latexResult)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(wrapped, forType: .string)
                }
                .buttonStyle(.bordered)
                .disabled(latexResult.isEmpty || latexResult.hasPrefix("Error:") || latexResult.hasPrefix("No vision model"))
                
                Button("Paste to Front Content") {
                    let wrapped = wrapInLaTeXDelimiters(latexResult)
                    frontText += (frontText.isEmpty ? "" : " ") + wrapped
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.bordered)
                .disabled(latexResult.isEmpty || latexResult.hasPrefix("Error:") || latexResult.hasPrefix("No vision model"))
                
                Button("Paste to Back Content") {
                    let wrapped = wrapInLaTeXDelimiters(latexResult)
                    backText += (backText.isEmpty ? "" : " ") + wrapped
                    showLatexHelper = false
                    resetLatexHelper()
                }
                .buttonStyle(.borderedProminent)
                .disabled(latexResult.isEmpty || latexResult.hasPrefix("Error:") || latexResult.hasPrefix("No vision model"))
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
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateToLaTeX(rawEquation: latexInput)
            DispatchQueue.main.async {
                self.isTranslatingLaTeX = false
                if let latex = res {
                    let wrapped = self.wrapInLaTeXDelimiters(latex)
                    self.latexResult = wrapped
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(wrapped, forType: .string)
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
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(wrapped, forType: .string)
                    }
                } else {
                    self.latexResult = "Error: Could not transcribe equation image. Verify that your AI host (Local or Tailscale) is connected."
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
                    .onChange(of: searchField) { _, _ in
                        loadAllCards()
                    }
            }
            .padding(.horizontal)
            .padding(.top, 15)
            
            List(selection: $selectedCards) {
                ForEach(allCards) { card in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 6) {
                                if card.isFlagged {
                                    Image(systemName: "flag.fill")
                                        .foregroundColor(.purple)
                                        .font(.caption)
                                        .padding(.top, 2)
                                }
                                Text("Q:").bold()
                                if isLaTeX(card.front) {
                                    LaTeXView(latex: card.front)
                                        .frame(height: 50)
                                } else {
                                    Text(card.front)
                                        .bold()
                                }
                            }
                            
                            HStack(alignment: .top, spacing: 6) {
                                Text("A:").foregroundColor(.secondary).font(.subheadline).bold()
                                if isLaTeX(card.back) {
                                    LaTeXView(latex: card.back)
                                        .frame(height: 50)
                                } else {
                                    Text(card.back)
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        
                        Spacer()
                        
                        Button(action: {
                            _ = DatabaseManager.shared.setFlashcardFlag(id: card.id, isFlagged: !card.isFlagged)
                            loadAllCards()
                        }) {
                            Image(systemName: card.isFlagged ? "flag.fill" : "flag")
                                .foregroundColor(card.isFlagged ? .purple : .secondary)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button("Edit") {
                            editingCard = card
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
                
                Button("Edit Selected") {
                    if let cardId = selectedCards.first, let card = allCards.first(where: { $0.id == cardId }) {
                        editingCard = card
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selectedCards.count != 1)
                
                Button("Toggle Flag") {
                    for cardId in selectedCards {
                        if let card = allCards.first(where: { $0.id == cardId }) {
                            _ = DatabaseManager.shared.setFlashcardFlag(id: card.id, isFlagged: !card.isFlagged)
                        }
                    }
                    loadAllCards()
                }
                .buttonStyle(.bordered)
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
        .sheet(item: $editingCard) { card in
            EditFlashcardSheetView(
                card: card,
                onSave: { newFront, newBack in
                    _ = DatabaseManager.shared.updateFlashcard(
                        id: card.id,
                        front: newFront,
                        back: newBack
                    )
                    loadAllCards()
                    editingCard = nil
                },
                onCancel: {
                    editingCard = nil
                }
            )
        }
    }
    
struct EditFlashcardSheetView: View {
    let card: Flashcard
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    
    @State private var frontText: String
    @State private var backText: String
    
    @State private var showLatexHelper: Bool = false
    @State private var latexInput: String = ""
    @State private var latexResult: String = ""
    @State private var latexClipboardImage: NSImage? = nil
    @State private var latexImageBase64: String = ""
    @State private var isTranslatingLaTeX: Bool = false
    
    init(card: Flashcard, onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.card = card
        self.onSave = onSave
        self.onCancel = onCancel
        _frontText = State(initialValue: card.front)
        _backText = State(initialValue: card.back)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Edit Flashcard")
                        .font(.title2)
                        .bold()
                    Spacer()
                }
                
                // Front (Question) Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Front Content (Plain Text):")
                        .bold()
                    TextEditor(text: $frontText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 75)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Front Rendered Preview:").font(.caption).bold().foregroundColor(.secondary)
                        if isLaTeX(frontText) {
                            LaTeXView(latex: frontText)
                                .frame(height: 55)
                                .padding(4)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        } else {
                            Text(frontText.isEmpty ? "No content" : frontText)
                                .font(.body)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                    }
                }
                
                // Back (Answer) Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Back Content (Plain Text):")
                        .bold()
                    TextEditor(text: $backText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 75)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Back Rendered Preview:").font(.caption).bold().foregroundColor(.secondary)
                        if isLaTeX(backText) {
                            LaTeXView(latex: backText)
                                .frame(height: 55)
                                .padding(4)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        } else {
                            Text(backText.isEmpty ? "No content" : backText)
                                .font(.body)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                        }
                    }
                }
                
                HStack {
                    Button("AI LaTeX Helper") {
                        showLatexHelper = true
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Button("Cancel") {
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Save Changes") {
                        let trimmedFront = frontText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedBack = backText.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmedFront, trimmedBack)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
        }
        .frame(width: 580, height: 560)
        .sheet(isPresented: $showLatexHelper) {
            editorLatexHelperSheet
        }
    }
    
    private var editorLatexHelperSheet: some View {
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Equation Description:").bold()
                            TextField("e.g. integral from 0 to infinity", text: $latexInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { translateTextToLatex() }
                            
                            Button("Translate Text") { translateTextToLatex() }
                                .buttonStyle(.bordered)
                                .disabled(latexInput.isEmpty || isTranslatingLaTeX)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Clipboard Image Preview:").bold()
                            if let img = latexClipboardImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 60)
                                    .border(Color.secondary.opacity(0.3))
                            } else {
                                VStack { Text("No Image Pasted").foregroundColor(.secondary).font(.caption) }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 60)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            
                            Button("Paste Image") { pasteClipboardImage() }
                                .buttonStyle(.bordered)
                                .disabled(isTranslatingLaTeX)
                        }
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result LaTeX Code:").bold()
                        if isTranslatingLaTeX {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Translating...").foregroundColor(.secondary)
                            }
                        } else {
                            TextEditor(text: $latexResult)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 60)
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    
                    if !latexResult.isEmpty && !latexResult.hasPrefix("Error:") && !latexResult.hasPrefix("No vision model") {
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
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Paste to Front Content") {
                    let wrapped = wrapInLaTeXDelimiters(latexResult)
                    frontText += (frontText.isEmpty ? "" : " ") + wrapped
                    showLatexHelper = false
                }
                .buttonStyle(.bordered)
                .disabled(latexResult.isEmpty || latexResult.hasPrefix("Error:") || latexResult.hasPrefix("No vision model"))
                
                Button("Paste to Back Content") {
                    let wrapped = wrapInLaTeXDelimiters(latexResult)
                    backText += (backText.isEmpty ? "" : " ") + wrapped
                    showLatexHelper = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(latexResult.isEmpty || latexResult.hasPrefix("Error:") || latexResult.hasPrefix("No vision model"))
            }
        }
        .padding(20)
        .frame(width: 580, height: 500)
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
    
    private func wrapInLaTeXDelimiters(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }
        if trimmed.contains("$") || trimmed.contains("\\(") || trimmed.contains("\\[") {
            return text
        }
        if trimmed.contains("\n") {
            return "$$\n" + trimmed + "\n$$"
        } else {
            return "$" + trimmed + "$"
        }
    }
}
    
    private func loadAllCards() {
        let query = searchField.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetModId = (currentMode == .manage || isExamMode) ? activeModuleId : nil
        let targetYear = (currentMode == .manage || isExamMode) ? nil : activeYear
        let cards = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId)
        
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
                    let front = card.front.replacingOccurrences(of: "\"", with: "\"\"")
                    let back = card.back.replacingOccurrences(of: "\"", with: "\"\"")
                    csvText += "\"\(front)\",\"\(back)\"\n"
                }
                try? csvText.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    
    func wrapInLaTeXDelimiters(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return text }
        if trimmed.contains("$") || trimmed.contains("\\(") || trimmed.contains("\\[") {
            return text
        }
        if trimmed.contains("\n") {
            return "$$\n" + trimmed + "\n$$"
        } else {
            return "$" + trimmed + "$"
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    @ViewBuilder
    private func chartPopupSheet(for popup: ActiveChartPopup) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(popup.rawValue)
                        .font(.title2)
                        .bold()
                    Text("Interactive visual analytics for your flashcard deck")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    activeChartPopup = nil
                }
                .buttonStyle(.borderedProminent)
            }
            
            Divider()
            
            switch popup {
            case .weeklyAvgTime:
                WeeklyAvgTimeChartView(moduleId: nil)
            case .dueProjection:
                DueProjectionChartView(moduleId: nil)
            case .easeDistribution:
                EaseDistributionChartView(allCards: allCards)
            case .cumulativeCreated:
                CumulativeCreatedChartView(moduleId: nil, allCards: allCards)
            }
        }
        .padding(24)
        .frame(width: 680, height: 500)
    }
}

// MARK: - Flashcard Metric Chart Views

struct WeeklyAvgTimeChartView: View {
    let moduleId: Int?
    
    @State private var timeBins: [(rangeLabel: String, count: Int)] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Card Completion Time Distribution")
                        .font(.headline)
                    Text("Frequency of completion times over the past 7 days (Y: Frequency, X: Time Range)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            if timeBins.allSatisfy({ $0.count == 0 }) {
                VStack(spacing: 8) {
                    Image(systemName: "timer")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No completion time logs recorded in the last 7 days.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(10)
            } else {
                Chart {
                    ForEach(timeBins, id: \.rangeLabel) { bin in
                        BarMark(
                            x: .value("Time Range", bin.rangeLabel),
                            y: .value("Frequency", bin.count)
                        )
                        .foregroundStyle(Color.blue.gradient)
                        .cornerRadius(4)
                        .annotation(position: .top) {
                            if bin.count > 0 {
                                Text("\(bin.count)")
                                    .font(.caption2)
                                    .bold()
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .chartYAxisLabel("Frequency (Cards)")
                .chartXAxisLabel("Time per Flashcard")
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(10)
            }
        }
        .onAppear {
            timeBins = DatabaseManager.shared.getWeeklyTimeDistribution(moduleId: moduleId)
        }
    }
}

struct DueProjectionChartView: View {
    let moduleId: Int?
    
    @State private var projections: [(dayLabel: String, dateString: String, count: Int)] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("7-Day Review Workload Projection")
                        .font(.headline)
                    Text("Forecasted due cards for today and the next 6 days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Chart {
                ForEach(projections, id: \.dateString) { item in
                    BarMark(
                        x: .value("Day", item.dayLabel),
                        y: .value("Due Cards", item.count)
                    )
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        Text("\(item.count)")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.orange)
                    }
                    
                    LineMark(
                        x: .value("Day", item.dayLabel),
                        y: .value("Due Cards", item.count)
                    )
                    .foregroundStyle(Color.orange)
                    .symbol(Circle())
                }
            }
            .chartYAxisLabel("Count of Due Cards")
            .chartXAxisLabel("Forecast Date")
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .onAppear {
            projections = DatabaseManager.shared.getDueProjection(moduleId: moduleId)
        }
    }
}

struct EaseDistributionChartView: View {
    let allCards: [Flashcard]
    
    struct EaseBinItem: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
    }
    
    private var easeBins: [EaseBinItem] {
        let b1 = allCards.filter { $0.easeFactor < 1.5 }.count
        let b2 = allCards.filter { $0.easeFactor >= 1.5 && $0.easeFactor < 1.8 }.count
        let b3 = allCards.filter { $0.easeFactor >= 1.8 && $0.easeFactor < 2.1 }.count
        let b4 = allCards.filter { $0.easeFactor >= 2.1 && $0.easeFactor < 2.4 }.count
        let b5 = allCards.filter { $0.easeFactor >= 2.4 && $0.easeFactor < 2.7 }.count
        let b6 = allCards.filter { $0.easeFactor >= 2.7 }.count
        
        return [
            EaseBinItem(label: "< 1.5", count: b1, color: .red),
            EaseBinItem(label: "1.5 - 1.8", count: b2, color: .orange),
            EaseBinItem(label: "1.8 - 2.1", count: b3, color: .yellow),
            EaseBinItem(label: "2.1 - 2.4", count: b4, color: .teal),
            EaseBinItem(label: "2.4 - 2.7", count: b5, color: .green),
            EaseBinItem(label: "2.7+", count: b6, color: .blue)
        ]
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ease Factor & Mastery Breakdown")
                        .font(.headline)
                    Text("Distribution of recall ease factors (Y: Frequency, X: Ease Level)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            Chart(easeBins) { bin in
                BarMark(
                    x: .value("Ease Level", bin.label),
                    y: .value("Cards", bin.count)
                )
                .foregroundStyle(bin.color.gradient)
                .cornerRadius(4)
                .annotation(position: .top) {
                    if bin.count > 0 {
                        Text("\(bin.count)")
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.secondary)
                    }
                }
            }
            .chartYAxisLabel("Frequency (Cards)")
            .chartXAxisLabel("Ease Level Factor")
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
    }
}

struct CumulativeCreatedChartView: View {
    let moduleId: Int?
    let allCards: [Flashcard]
    
    @State private var cumulativeData: [(dateLabel: String, count: Int)] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cumulative Flashcard Growth")
                        .font(.headline)
                    Text("Cumulative total flashcards created over time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            
            if cumulativeData.isEmpty {
                VStack {
                    Spacer()
                    Text("No creation history recorded.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(cumulativeData, id: \.dateLabel) { item in
                        AreaMark(
                            x: .value("Date", item.dateLabel),
                            y: .value("Total Cards", item.count)
                        )
                        .foregroundStyle(LinearGradient(colors: [Color.purple.opacity(0.5), Color.purple.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        
                        LineMark(
                            x: .value("Date", item.dateLabel),
                            y: .value("Total Cards", item.count)
                        )
                        .foregroundStyle(Color.purple)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .symbol(Circle())
                    }
                }
                .chartYAxisLabel("Cumulative Total Cards")
                .chartXAxisLabel("Creation Date")
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(10)
            }
        }
        .onAppear {
            cumulativeData = DatabaseManager.shared.getCumulativeCardsCreated(moduleId: moduleId)
        }
    }
}
