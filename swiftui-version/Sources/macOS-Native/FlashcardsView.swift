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

struct FlashcardScheduler {
    /// Shuffles cards while interleaving across modules in randomized round-robin waves
    /// so cards from the same module do not clump together in multi-module study mode.
    static func interleavedShuffle(_ cards: [Flashcard]) -> [Flashcard] {
        guard cards.count > 1 else { return cards }
        var byModule: [Int: [Flashcard]] = [:]
        for card in cards {
            byModule[card.moduleId, default: []].append(card)
        }
        if byModule.count <= 1 {
            return cards.shuffled()
        }
        for modId in byModule.keys {
            byModule[modId]?.shuffle()
        }
        var result: [Flashcard] = []
        result.reserveCapacity(cards.count)
        while !byModule.isEmpty {
            let activeModIds = Array(byModule.keys).shuffled()
            for modId in activeModIds {
                if var list = byModule[modId], !list.isEmpty {
                    result.append(list.removeFirst())
                    if list.isEmpty {
                        byModule.removeValue(forKey: modId)
                    } else {
                        byModule[modId] = list
                    }
                }
            }
        }
        return result
    }
    
    /// Builds a prioritized, randomized session deck that prevents 1-day interval cards
    /// from starving brand-new untouched cards (`repetitions == 0 && interval == 0`)
    /// and oldest overdue cards, then shuffles the chosen deck across modules.
    static func buildSessionDeck(
        candidates: [Flashcard],
        targetCount: Int,
        today: String,
        studyAhead: Bool,
        recentlyReviewedIds: Set<Int> = []
    ) -> [Flashcard] {
        guard !candidates.isEmpty else { return [] }
        let limit = targetCount > 0 ? min(targetCount, candidates.count) : candidates.count
        
        let freshPool = candidates.filter { !recentlyReviewedIds.contains($0.id) }
        let recentPool = candidates.filter { recentlyReviewedIds.contains($0.id) }
        
        var selected = selectPrioritizedCards(from: freshPool, count: limit, today: today, studyAhead: studyAhead)
        if selected.count < limit && !recentPool.isEmpty {
            let needed = limit - selected.count
            let fallback = selectPrioritizedCards(from: recentPool, count: needed, today: today, studyAhead: studyAhead)
            selected.append(contentsOf: fallback)
        }
        
        return interleavedShuffle(selected)
    }
    
    private static func selectPrioritizedCards(
        from pool: [Flashcard],
        count: Int,
        today: String,
        studyAhead: Bool
    ) -> [Flashcard] {
        guard !pool.isEmpty, count > 0 else { return [] }
        if pool.count <= count {
            return pool
        }
        
        if studyAhead {
            // Prioritize cards with fewer repetitions and earlier review dates, randomized within repetition tiers
            let groupedByReps = Dictionary(grouping: pool) { $0.repetitions }
            var ordered: [Flashcard] = []
            for reps in groupedByReps.keys.sorted() {
                if let tier = groupedByReps[reps] {
                    ordered.append(contentsOf: interleavedShuffle(tier))
                }
                if ordered.count >= count { break }
            }
            return Array(ordered.prefix(count))
        }
        
        // 1. Brand-new untouched cards (never reviewed once: repetitions == 0 && interval == 0)
        var untouched = interleavedShuffle(pool.filter { $0.repetitions == 0 && $0.interval == 0 })
        
        // 2. Overdue cards (already reviewed or scheduled in the past: nextReviewDate < today)
        let overdueRaw = pool.filter {
            !($0.repetitions == 0 && $0.interval == 0) &&
            !$0.nextReviewDate.isEmpty &&
            $0.nextReviewDate < today
        }
        // Group overdue cards by their due date (oldest first) and shuffle within each date bucket
        let overdueByDate = Dictionary(grouping: overdueRaw) { $0.nextReviewDate }
        var overdue: [Flashcard] = []
        for dateKey in overdueByDate.keys.sorted() {
            if let bucket = overdueByDate[dateKey] {
                overdue.append(contentsOf: interleavedShuffle(bucket))
            }
        }
        
        // 3. Due today (including yesterday's 1-day interval cards whose nextReviewDate == today)
        var dueToday = interleavedShuffle(pool.filter {
            !($0.repetitions == 0 && $0.interval == 0) &&
            ($0.nextReviewDate.isEmpty || $0.nextReviewDate >= today)
        })
        
        var chosen: [Flashcard] = []
        chosen.reserveCapacity(count)
        
        // Allocate up to 50% of session to untouched cards first so unseen cards are never starved
        let untouchedQuota = min(untouched.count, max(1, Int(ceil(Double(count) * 0.5))))
        if untouchedQuota > 0 {
            chosen.append(contentsOf: untouched.prefix(untouchedQuota))
            untouched.removeFirst(untouchedQuota)
        }
        
        // Next, fill from oldest overdue cards
        let remainingAfterUntouched = count - chosen.count
        if remainingAfterUntouched > 0 && !overdue.isEmpty {
            let takeOverdue = min(remainingAfterUntouched, overdue.count)
            chosen.append(contentsOf: overdue.prefix(takeOverdue))
            overdue.removeFirst(takeOverdue)
        }
        
        // Next, fill from cards due today
        let remainingAfterOverdue = count - chosen.count
        if remainingAfterOverdue > 0 && !dueToday.isEmpty {
            let takeToday = min(remainingAfterOverdue, dueToday.count)
            chosen.append(contentsOf: dueToday.prefix(takeToday))
            dueToday.removeFirst(takeToday)
        }
        
        // Finally, if slots still remain (e.g. >50% of due pool is brand-new untouched cards), top up from remaining untouched/overdue
        if chosen.count < count && !untouched.isEmpty {
            let needed = min(count - chosen.count, untouched.count)
            chosen.append(contentsOf: untouched.prefix(needed))
        }
        if chosen.count < count && !overdue.isEmpty {
            let needed = min(count - chosen.count, overdue.count)
            chosen.append(contentsOf: overdue.prefix(needed))
        }
        
        return chosen
    }
    
    private static func round1(_ value: Double) -> Double {
        return (value * 10.0).rounded() / 10.0
    }
    
    /// Calculates the next SM-2 review interval in days (to 1 decimal place) for the 5-button scale.
    /// Uses the card's ease factor directly on every review so no two cards with different ease/intervals show identical flat numbers.
    static func calculateNextInterval(card: Flashcard, quality: Int) -> Double {
        if quality == 1 {
            return 1.0
        }
        
        let effectiveReps = (card.repetitions == 0 && card.interval > 0) ? 1 : card.repetitions
        let ease = max(1.3, card.easeFactor)
        
        if effectiveReps == 0 {
            switch quality {
            case 2: return round1(max(1.2, 0.8 * ease)) // Hard (~2.0d at ease 2.5)
            case 3: return round1(max(2.0, 1.5 * ease)) // Good (~3.8d at ease 2.5)
            case 4: return round1(max(3.5, 2.5 * ease)) // Easy (~6.3d at ease 2.5)
            case 5: return round1(max(5.0, 3.8 * ease)) // Perfect (~9.5d at ease 2.5)
            default: return 1.0
            }
        }
        
        let base = max(card.interval, 1.8 + 0.6 * Double(effectiveReps))
        switch quality {
        case 2: // Hard
            return round1(max(card.interval + 0.8, base * 1.25))
        case 3: // Good
            return round1(max(card.interval + 1.5, base * ease))
        case 4: // Easy
            return round1(max(card.interval + 3.0, base * ease * 1.3))
        case 5: // Perfect
            return round1(max(card.interval + 5.0, base * ease * 1.6))
        default:
            return 1.0
        }
    }
    
    static func calculateNextRepetitions(card: Flashcard, quality: Int) -> Int {
        let effectiveReps = (card.repetitions == 0 && card.interval > 0) ? 1 : card.repetitions
        if quality >= 3 {
            return effectiveReps + 1
        } else if quality == 2 {
            // Hard means recalled with effort; keep progress at >= 1 so it does not reset like Again (1)
            return max(1, effectiveReps)
        } else {
            return 0
        }
    }
    
    /// Updates ease factor calibrated for a 5-button scale (where 3 = Good is neutral +0.00, not -0.14).
    static func calculateNextEaseFactor(currentEase: Double, quality: Int) -> Double {
        let delta: Double
        switch quality {
        case 1: delta = -0.20 // Again
        case 2: delta = -0.15 // Hard
        case 3: delta = 0.00  // Good (neutral — do not penalize ease on Good recall)
        case 4: delta = 0.10  // Easy
        case 5: delta = 0.15  // Perfect
        default: delta = 0.00
        }
        return max(1.3, currentEase + delta)
    }
}

struct FlipCardEffect<Back: View>: AnimatableModifier {
    var angle: Double
    let backView: Back
    
    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }
    
    func body(content: Content) -> some View {
        let normalizedAngle = angle.truncatingRemainder(dividingBy: 360)
        let positiveAngle = normalizedAngle < 0 ? normalizedAngle + 360 : normalizedAngle
        let isShowingFront = positiveAngle < 90 || positiveAngle > 270
        let lift = abs(sin(positiveAngle * .pi / 180.0))
        
        ZStack {
            content
                .opacity(isShowingFront ? 1.0 : 0.0)
                .allowsHitTesting(isShowingFront)
                .rotation3DEffect(
                    .degrees(angle),
                    axis: (x: 0.0, y: 1.0, z: 0.0),
                    perspective: 0.55
                )
            
            backView
                .opacity(isShowingFront ? 0.0 : 1.0)
                .allowsHitTesting(!isShowingFront)
                .rotation3DEffect(
                    .degrees(angle - 180.0),
                    axis: (x: 0.0, y: 1.0, z: 0.0),
                    perspective: 0.55
                )
        }
        .scaleEffect(1.0 + 0.025 * lift)
        .shadow(
            color: Color.black.opacity(0.08 + 0.07 * lift),
            radius: 6.0 + 9.0 * lift,
            x: 0,
            y: 3.0 + 6.0 * lift
        )
    }
}

struct FlipCardView: View {
    let front: String
    let back: String
    var isFlipped: Bool
    var isFlagged: Bool = false
    var moduleName: String? = nil
    var moduleCode: String? = nil
    var onToggleFlag: (() -> Void)? = nil
    
    @State private var isHoveringBadge: Bool = false
    
    private var moduleTooltip: String {
        if let code = moduleCode, !code.isEmpty, let name = moduleName, !name.isEmpty {
            return "\(code): \(name)"
        }
        return moduleName ?? moduleCode ?? "Module Context"
    }
    
    @ViewBuilder
    private var moduleBadge: some View {
        if let name = moduleName, !name.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "book.closed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(isHoveringBadge ? 0.16 : 0.08))
            .cornerRadius(6)
            .onHover { hovering in
                isHoveringBadge = hovering
            }
            .help(moduleTooltip)
        }
    }
    
    @ViewBuilder
    private var frontCard: some View {
        VStack {
            HStack(alignment: .center) {
                moduleBadge
                
                Spacer()
                
                if isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundColor(.purple)
                        .font(.system(size: 12))
                        .padding(.trailing, 2)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)
            
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    @ViewBuilder
    private var backCard: some View {
        VStack {
            HStack(alignment: .center) {
                moduleBadge
                
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
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)
            
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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    var body: some View {
        frontCard
            .modifier(
                FlipCardEffect(
                    angle: isFlipped ? 180.0 : 0.0,
                    backView: backCard
                )
            )
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

@MainActor
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
    @State private var isGeneratingFrontLatex: Bool = false
    @State private var isGeneratingBackLatex: Bool = false
    
    enum FocusField: Hashable {
        case front
        case back
    }
    @FocusState private var focusedField: FocusField?
    
    // Review State
    @State private var dueCards: [Flashcard] = []
    @State private var sessionCards: [Flashcard] = []
    @State private var currentCardIdx: Int = 0
    @State private var flippedCardKey: String? = nil
    
    private var isFlipped: Bool {
        guard currentCardIdx < sessionCards.count else { return false }
        return flippedCardKey == "\(sessionCards[currentCardIdx].id)_\(currentCardIdx)"
    }
    
    private func toggleCurrentCardFlip() {
        guard currentCardIdx < sessionCards.count else { return }
        let key = "\(sessionCards[currentCardIdx].id)_\(currentCardIdx)"
        if flippedCardKey == key {
            flippedCardKey = nil
        } else {
            flippedCardKey = key
        }
    }
    
    private func setCurrentCardFlipped(_ flipped: Bool) {
        guard currentCardIdx < sessionCards.count else { return }
        let key = "\(sessionCards[currentCardIdx].id)_\(currentCardIdx)"
        if flipped {
            flippedCardKey = key
        } else if flippedCardKey == key {
            flippedCardKey = nil
        }
    }
    @State private var fcTimerSeconds: Int = 0
    @State private var fcTimer: Timer?
    @State private var requeuedCount: Int = 0
    @State private var cardRequeueCounts: [Int: Int] = [:]
    @State private var recentSessionCardIds: Set<Int> = []
    
    // Session Presets & Settings State
    @State private var selectedPreset: SessionPreset = .optimal
    @State private var customCardCount: Int = 25
    @State private var targetCardCount: Int = 30
    @State private var targetSessionMinutes: Int = 15
    @State private var sessionFocusFilter: SessionFocusFilter = .allDue
    @State private var cardsReviewedInSession: Int = 0
    @State private var isSessionComplete: Bool = false
    @State private var allCards: [Flashcard] = []
    @State private var modulesDict: [Int: Module] = [:]
    
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
            loadModules()
            if currentMode != .review || sessionCards.isEmpty || isSessionComplete {
                currentMode = mode
            }
            if isActive {
                if currentMode == .review && !sessionCards.isEmpty && !isSessionComplete {
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
            if newMode != .review {
                loadInitialData()
            }
            if newMode == .add {
                setupFlaggedCorrectionQueue()
            }
        }
        .onChange(of: activeModuleId) { oldValue, newValue in
            currentMode = mode
            dueCards.removeAll()
            sessionCards.removeAll()
            isSessionComplete = false
            currentCardIdx = 0
            if isActive {
                loadInitialData()
            }
        }
        .onChange(of: activeYear) { oldValue, newValue in
            loadModules()
            if isActive {
                loadInitialData()
            }
        }
        .onChange(of: isActive) { oldValue, newValue in
            if newValue {
                if currentMode == .review && !sessionCards.isEmpty && !isSessionComplete {
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
        .onChange(of: sessionFocusFilter) { _, _ in
            if currentMode == .start {
                loadDueCards()
            }
        }
        .onDisappear {
            fcTimer?.invalidate()
            logActiveSeconds()
        }
    }
    
    private func loadModules() {
        let all = DatabaseManager.shared.getModules()
        self.modulesDict = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
    
    private func loadInitialData() {
        loadModules()
        if currentMode == .manage {
            loadAllCards()
        } else if currentMode == .review {
            // Already initialized in startNewSession; do not reload/wipe session cards
            if sessionCards.isEmpty && !isSessionComplete {
                loadDueCards()
            }
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
                    let modId = (currentCardIdx < sessionCards.count) ? sessionCards[currentCardIdx].moduleId : activeModuleId
                    if let modId = modId {
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
        let modId = (currentCardIdx < sessionCards.count) ? sessionCards[currentCardIdx].moduleId : activeModuleId
        if let modId = modId {
            DatabaseManager.shared.addModuleStudyTime(moduleId: modId, flashcardsDelta: -seconds, problemsDelta: 0)
        }
    }
    
    private func logActiveSeconds() {
        let remainder = fcTimerSeconds % 10
        if remainder > 0 {
            DatabaseManager.shared.addStudyTime(flashcardsDelta: remainder, problemsDelta: 0)
            let modId = (currentCardIdx < sessionCards.count) ? sessionCards[currentCardIdx].moduleId : activeModuleId
            if let modId = modId {
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
        if modulesDict.isEmpty {
            loadModules()
        }
        let cardCount = (selectedPreset == .custom) ? customCardCount : selectedPreset.baseCardCount
        targetCardCount = cardCount
        targetSessionMinutes = estimatedMinutes(forCardCount: cardCount)
        
        let targetModId = isExamMode ? activeModuleId : nil
        let targetYear = isExamMode ? nil : activeYear
        let today = formatDate(Date())
        var pool: [Flashcard] = []
        
        switch sessionFocusFilter {
        case .allDue:
            if studyAhead {
                pool = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId)
            } else {
                pool = DatabaseManager.shared.getDueFlashcards(forYear: targetYear, forModuleId: targetModId, today: today)
            }
        case .lowEase:
            if studyAhead {
                let all = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId)
                pool = all.filter { $0.easeFactor < 2.3 }
            } else {
                let due = DatabaseManager.shared.getDueFlashcards(forYear: targetYear, forModuleId: targetModId, today: today)
                pool = due.filter { $0.easeFactor < 2.3 }
            }
        }
        
        pool = FlashcardScheduler.buildSessionDeck(
            candidates: pool,
            targetCount: cardCount,
            today: today,
            studyAhead: studyAhead,
            recentlyReviewedIds: recentSessionCardIds
        )
        
        self.sessionCards = pool
        self.currentCardIdx = 0
        self.flippedCardKey = nil
        self.cardRequeueCounts.removeAll()
        self.cardsReviewedInSession = 0
        self.requeuedCount = 0
        self.isSessionComplete = false
        self.currentMode = .review
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
                    sessionCards.removeAll()
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
            } else if sessionCards.isEmpty {
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
                        sessionCards.removeAll()
                        currentMode = .start
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                    .padding(.top, 16)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if currentCardIdx < sessionCards.count {
                let card = sessionCards[currentCardIdx]
                VStack(spacing: 16) {
                    HStack {
                        Spacer()
                        
                        Text("Card \(currentCardIdx + 1) of \(sessionCards.count)")
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
                    
                    let currentMod = modulesDict[card.moduleId]
                    let cardKey = "\(card.id)_\(currentCardIdx)"
                    let isCardFlipped = (flippedCardKey == cardKey)
                    
                    FlipCardView(
                        front: card.front,
                        back: card.back,
                        isFlipped: isCardFlipped,
                        isFlagged: card.isFlagged,
                        moduleName: currentMod?.name,
                        moduleCode: currentMod?.code,
                        onToggleFlag: { toggleCurrentCardFlag() }
                    )
                    .id(cardKey)
                    .transition(.opacity)
                    .pointingHandCursor()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            toggleCurrentCardFlip()
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
                                setCurrentCardFlipped(true)
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
                if !sessionCards.isEmpty && currentCardIdx < sessionCards.count && !isSessionComplete {
                    Button("") {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            toggleCurrentCardFlip()
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
                sessionCards.removeAll()
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
                sessionCards.removeAll()
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
                cards = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId)
            } else {
                cards = DatabaseManager.shared.getDueFlashcards(forYear: targetYear, forModuleId: targetModId, today: today)
            }
        case .lowEase:
            if studyAhead {
                let all = DatabaseManager.shared.getFlashcards(forYear: targetYear, forModuleId: targetModId)
                cards = all.filter { $0.easeFactor < 2.3 }
            } else {
                let due = DatabaseManager.shared.getDueFlashcards(forYear: targetYear, forModuleId: targetModId, today: today)
                cards = due.filter { $0.easeFactor < 2.3 }
            }
        }
        
        cards = FlashcardScheduler.buildSessionDeck(
            candidates: cards,
            targetCount: limit ?? cards.count,
            today: today,
            studyAhead: studyAhead,
            recentlyReviewedIds: recentSessionCardIds
        )
        
        self.dueCards = cards
    }
    
    private func calculateNextInterval(card: Flashcard, quality: Int) -> Double {
        return FlashcardScheduler.calculateNextInterval(card: card, quality: quality)
    }
    
    private func rateRecall(quality: Int) {
        guard currentCardIdx < sessionCards.count else { return }
        let card = sessionCards[currentCardIdx]
        
        // SM-2 Spaced Repetition Algorithm (5-button scale, 1-decimal-place interval)
        let interval = calculateNextInterval(card: card, quality: quality)
        let easeFactor = FlashcardScheduler.calculateNextEaseFactor(
            currentEase: card.easeFactor,
            quality: quality
        )
        let repetitions = FlashcardScheduler.calculateNextRepetitions(
            card: card,
            quality: quality
        )
        
        let calendar = Calendar.current
        let daysToAdd = max(1, Int(interval.rounded()))
        let nextReview = calendar.date(byAdding: .day, value: daysToAdd, to: Date()) ?? Date()
        let nextReviewStr = formatDate(nextReview)
        
        _ = DatabaseManager.shared.updateFlashcardReview(
            id: card.id,
            interval: interval,
            easeFactor: easeFactor,
            repetitions: repetitions,
            nextReviewDate: nextReviewStr
        )
        
        recentSessionCardIds.insert(card.id)
        
        // Log study activity
        DatabaseManager.shared.logActivity("flashcard", moduleId: card.moduleId)
        secondsSinceLastCard = 0
        
        // If rating is 1 (Again), re-queue card into the latter portion of the remaining deck max 2 times (3 total views)
        if quality == 1 {
            let previousRequeues = cardRequeueCounts[card.id, default: 0]
            if previousRequeues < 2 {
                cardRequeueCounts[card.id] = previousRequeues + 1
                var updatedCard = card
                updatedCard.interval = interval
                updatedCard.easeFactor = easeFactor
                updatedCard.repetitions = repetitions
                updatedCard.nextReviewDate = nextReviewStr
                
                let remaining = sessionCards.count - (currentCardIdx + 1)
                if remaining >= 4 {
                    let minOffset = max(3, remaining / 2)
                    let insertIdx = Int.random(in: (currentCardIdx + 1 + minOffset)...sessionCards.count)
                    sessionCards.insert(updatedCard, at: insertIdx)
                } else {
                    sessionCards.append(updatedCard)
                }
                requeuedCount += 1
            }
        }
        
        // Advance: Card N stays on its answer while smoothly fading out, Card N+1 enters on its question
        withAnimation(.easeInOut(duration: 0.15)) {
            cardsReviewedInSession += 1
            if currentCardIdx + 1 < sessionCards.count {
                currentCardIdx += 1
            } else {
                isSessionComplete = true
                flippedCardKey = nil
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
        if interval < 30.0 {
            return String(format: "%.1fd", interval)
        } else {
            let months = String(format: "%.1f", interval / 30.0)
            return "\(months)mo"
        }
    }
    
    private func toggleCurrentCardFlag() {
        guard currentCardIdx < sessionCards.count else { return }
        let card = sessionCards[currentCardIdx]
        let newFlag = !card.isFlagged
        _ = DatabaseManager.shared.setFlashcardFlag(id: card.id, isFlagged: newFlag)
        sessionCards[currentCardIdx].isFlagged = newFlag
        if let idx = dueCards.firstIndex(where: { $0.id == card.id }) {
            dueCards[idx].isFlagged = newFlag
        }
    }
    
    private func setupFlaggedCorrectionQueue() {
        let flagged = DatabaseManager.shared.getFlaggedFlashcards(
            forYear: activeModuleId == nil ? activeYear : nil,
            forModuleId: activeModuleId
        )
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
        
        let flaggedRemaining = DatabaseManager.shared.getFlaggedFlashcards(
            forYear: activeModuleId == nil ? activeYear : nil,
            forModuleId: activeModuleId
        )
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isCorrectingFlaggedCards && flaggedCardIdx < flaggedCorrectionQueue.count {
                    let card = flaggedCorrectionQueue[flaggedCardIdx]
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
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
                        }
                        .padding(.bottom, 4)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Question (Front):").bold()
                                if isGeneratingFrontLatex {
                                    Spacer()
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.small)
                                        Text("Generating LaTeX...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            
                            TextEditor(text: $frontText)
                                .font(.body)
                                .focused($focusedField, equals: .front)
                                .onKeyPress(.tab) {
                                    focusedField = .back
                                    return .handled
                                }
                                .frame(height: 80)
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                                )
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Answer (Back):").bold()
                                if isGeneratingBackLatex {
                                    Spacer()
                                    HStack(spacing: 5) {
                                        ProgressView().controlSize(.small)
                                        Text("Generating LaTeX...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            
                            TextEditor(text: $backText)
                                .font(.body)
                                .focused($focusedField, equals: .back)
                                .onKeyPress(.tab) {
                                    focusedField = .front
                                    return .handled
                                }
                                .frame(height: 80)
                                .padding(6)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                                )
                        }
                        
                        // Live LaTeX Preview
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Live LaTeX Preview:").bold()
                            VStack(alignment: .leading, spacing: 8) {
                                if !frontText.isEmpty || !backText.isEmpty || isGeneratingFrontLatex || isGeneratingBackLatex {
                                    if !frontText.isEmpty || isGeneratingFrontLatex {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Front:").font(.caption).foregroundColor(.secondary)
                                            let clean = AILatexPlaceholder.cleanText(frontText)
                                            if !clean.isEmpty {
                                                if isLaTeX(clean) {
                                                    LaTeXView(latex: clean)
                                                        .frame(height: 45)
                                                } else {
                                                    Text(clean)
                                                        .font(.body)
                                                        .padding(.horizontal, 4)
                                                }
                                            }
                                            if isGeneratingFrontLatex || AILatexPlaceholder.hasPlaceholder(frontText) {
                                                AILaTeXGeneratingView()
                                                    .frame(height: 42)
                                            }
                                        }
                                    }
                                    if !backText.isEmpty || isGeneratingBackLatex {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Back:").font(.caption).foregroundColor(.secondary)
                                            let clean = AILatexPlaceholder.cleanText(backText)
                                            if !clean.isEmpty {
                                                if isLaTeX(clean) {
                                                    LaTeXView(latex: clean)
                                                        .frame(height: 45)
                                                } else {
                                                    Text(clean)
                                                        .font(.body)
                                                        .padding(.horizontal, 4)
                                                }
                                            }
                                            if isGeneratingBackLatex || AILatexPlaceholder.hasPlaceholder(backText) {
                                                AILaTeXGeneratingView()
                                                    .frame(height: 42)
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
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.windowBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                        }
                        
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
                            .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeneratingFrontLatex || isGeneratingBackLatex)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Create Flashcard")
                                .font(.title2)
                                .bold()
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
                        }
                        
                        if activeModuleId == nil {
                            Text("Select a module in the sidebar first before adding cards.")
                                .foregroundColor(.red)
                                .padding(.vertical, 8)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Front Content:").bold()
                                    if isGeneratingFrontLatex {
                                        Spacer()
                                        HStack(spacing: 5) {
                                            ProgressView().controlSize(.small)
                                            Text("Generating LaTeX...")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                
                                TextEditor(text: $frontText)
                                    .font(.body)
                                    .focused($focusedField, equals: .front)
                                    .onKeyPress(.tab) {
                                        focusedField = .back
                                        return .handled
                                    }
                                    .frame(height: 80)
                                    .padding(6)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                     )
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Back Content:").bold()
                                    if isGeneratingBackLatex {
                                        Spacer()
                                        HStack(spacing: 5) {
                                            ProgressView().controlSize(.small)
                                            Text("Generating LaTeX...")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                
                                TextEditor(text: $backText)
                                    .font(.body)
                                    .focused($focusedField, equals: .back)
                                    .onKeyPress(.tab) {
                                        focusedField = .front
                                        return .handled
                                    }
                                    .frame(height: 80)
                                    .padding(6)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                     )
                            }
                            
                            // Live LaTeX Preview
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Live LaTeX Preview:").bold()
                                VStack(alignment: .leading, spacing: 8) {
                                    if !frontText.isEmpty || !backText.isEmpty || isGeneratingFrontLatex || isGeneratingBackLatex {
                                        if !frontText.isEmpty || isGeneratingFrontLatex {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Front:").font(.caption).foregroundColor(.secondary)
                                                let clean = AILatexPlaceholder.cleanText(frontText)
                                                if !clean.isEmpty {
                                                    if isLaTeX(clean) {
                                                        LaTeXView(latex: clean)
                                                            .frame(height: 45)
                                                    } else {
                                                        Text(clean)
                                                            .font(.body)
                                                            .padding(.horizontal, 4)
                                                    }
                                                }
                                                if isGeneratingFrontLatex || AILatexPlaceholder.hasPlaceholder(frontText) {
                                                    AILaTeXGeneratingView()
                                                        .frame(height: 42)
                                                }
                                            }
                                        }
                                        if !backText.isEmpty || isGeneratingBackLatex {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Back:").font(.caption).foregroundColor(.secondary)
                                                let clean = AILatexPlaceholder.cleanText(backText)
                                                if !clean.isEmpty {
                                                    if isLaTeX(clean) {
                                                        LaTeXView(latex: clean)
                                                            .frame(height: 45)
                                                    } else {
                                                        Text(clean)
                                                            .font(.body)
                                                            .padding(.horizontal, 4)
                                                    }
                                                }
                                                if isGeneratingBackLatex || AILatexPlaceholder.hasPlaceholder(backText) {
                                                    AILaTeXGeneratingView()
                                                        .frame(height: 42)
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
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                                )
                            }
                            
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
                                .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeneratingFrontLatex || isGeneratingBackLatex)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 800, alignment: .leading)
        }
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
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Translating equation via AI model...")
                                    .font(.subheadline)
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
                
                Button(action: {
                    pasteOrQueueLatex(target: .front)
                }) {
                    HStack(spacing: 5) {
                        if isTranslatingLaTeX {
                            Text("Paste to Front & Continue")
                        } else {
                            Text("Paste to Front Content")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(latexInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && latexClipboardImage == nil && latexResult.isEmpty)
                
                Button(action: {
                    pasteOrQueueLatex(target: .back)
                }) {
                    HStack(spacing: 5) {
                        if isTranslatingLaTeX {
                            Text("Paste to Back & Continue")
                        } else {
                            Text("Paste to Back Content")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(latexInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && latexClipboardImage == nil && latexResult.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580, height: 500)
    }
    
    private func pasteClipboardImage() {
        if let image = NSImage(pasteboard: NSPasteboard.general) {
            self.latexClipboardImage = image
            if let optimized = AIHelper.optimizeImageForOCR(image) {
                self.latexImageBase64 = optimized
                translateImageToLatex(base64: optimized)
            }
        }
    }
    
    private func pasteOrQueueLatex(target: FocusField) {
        if !latexResult.isEmpty && !latexResult.hasPrefix("Error:") && !latexResult.hasPrefix("No vision model") {
            let wrapped = wrapInLaTeXDelimiters(latexResult)
            if target == .front {
                AILatexPlaceholder.replaceOrAppend(in: &frontText, with: wrapped)
            } else {
                AILatexPlaceholder.replaceOrAppend(in: &backText, with: wrapped)
            }
            showLatexHelper = false
            resetLatexHelper()
            return
        }
        
        let pendingInput = latexInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingImg = latexClipboardImage
        let pendingB64 = latexImageBase64
        
        if target == .front {
            isGeneratingFrontLatex = true
            focusedField = .front
        } else {
            isGeneratingBackLatex = true
            focusedField = .back
        }
        
        showLatexHelper = false
        
        if !isTranslatingLaTeX {
            if !pendingInput.isEmpty {
                translateTextToLatex(input: pendingInput, target: target)
            } else if !pendingB64.isEmpty {
                translateImageToLatex(base64: pendingB64, target: target)
            } else if let img = pendingImg, let opt = AIHelper.optimizeImageForOCR(img) {
                translateImageToLatex(base64: opt, target: target)
            }
        }
    }
    
    private func translateTextToLatex(input: String? = nil, target: FocusField? = nil) {
        let textToTranslate = input ?? self.latexInput
        guard !textToTranslate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        self.isTranslatingLaTeX = true
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateToLaTeX(rawEquation: textToTranslate)
            await MainActor.run {
                self.applyLatexTranslationResult(res, target: target)
            }
        }
    }
    
    private func translateImageToLatex(base64: String? = nil, target: FocusField? = nil) {
        let b64 = base64 ?? self.latexImageBase64
        guard !b64.isEmpty else { return }
        
        self.isTranslatingLaTeX = true
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateImageToLaTeX(base64Image: b64)
            await MainActor.run {
                self.applyLatexTranslationResult(res, target: target)
            }
        }
    }
    
    private func applyLatexTranslationResult(_ res: String?, target: FocusField? = nil) {
        self.isTranslatingLaTeX = false
        if let latex = res, !latex.isEmpty {
            if latex == "MODEL_NOT_FOUND" {
                self.latexResult = "No vision model found on AI server. Please configure or pull a vision model in Settings."
                cleanUpPendingPlaceholders()
                sendAppNotification(title: "Vision Model Missing", body: "Please configure or pull a vision model on your AI server.")
            } else {
                let wrapped = self.wrapInLaTeXDelimiters(latex)
                self.latexResult = wrapped
                
                var inserted = false
                if target == .front || isGeneratingFrontLatex || AILatexPlaceholder.hasPlaceholder(frontText) {
                    AILatexPlaceholder.replaceOrAppend(in: &frontText, with: wrapped)
                    self.isGeneratingFrontLatex = false
                    inserted = true
                }
                
                if target == .back || isGeneratingBackLatex || AILatexPlaceholder.hasPlaceholder(backText) {
                    AILatexPlaceholder.replaceOrAppend(in: &backText, with: wrapped)
                    self.isGeneratingBackLatex = false
                    inserted = true
                }
                
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(wrapped, forType: .string)
                
                if inserted {
                    sendAppNotification(title: "LaTeX Ready", body: "AI generated equation inserted into flashcard.")
                }
            }
        } else {
            self.latexResult = "Error: Could not translate equation. Verify that your AI host (Local or Tailscale) is connected."
            cleanUpPendingPlaceholders()
            sendAppNotification(title: "LaTeX Failed", body: "Could not translate equation. Check AI connection.")
        }
    }
    
    private func cleanUpPendingPlaceholders() {
        self.isGeneratingFrontLatex = false
        self.isGeneratingBackLatex = false
        self.frontText = AILatexPlaceholder.cleanText(self.frontText)
        self.backText = AILatexPlaceholder.cleanText(self.backText)
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
                            if let mod = modulesDict[card.moduleId] {
                                HStack(spacing: 4) {
                                    Image(systemName: "book.closed")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("\(mod.code) • \(mod.name)")
                                        .font(.caption2)
                                        .bold()
                                }
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(4)
                            }
                            
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
    
@MainActor
struct EditFlashcardSheetView: View {
    let card: Flashcard
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    
    @State private var frontText: String
    @State private var backText: String
    
    @State private var isGeneratingFrontLatex: Bool = false
    @State private var isGeneratingBackLatex: Bool = false
    
    @State private var showLatexHelper: Bool = false
    @State private var latexInput: String = ""
    @State private var latexResult: String = ""
    @State private var latexClipboardImage: NSImage? = nil
    @State private var latexImageBase64: String = ""
    @State private var isTranslatingLaTeX: Bool = false
    
    enum EditFocusField: Hashable {
        case front
        case back
    }
    @FocusState private var focusedField: EditFocusField?
    
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
                    HStack {
                        Text("Front Content (Plain Text):")
                            .bold()
                        if isGeneratingFrontLatex {
                            Spacer()
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Generating LaTeX...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    TextEditor(text: $frontText)
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .front)
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
                        let clean = AILatexPlaceholder.cleanText(frontText)
                        if !clean.isEmpty {
                            if isLaTeX(clean) {
                                LaTeXView(latex: clean)
                                    .frame(height: 45)
                            } else {
                                Text(clean)
                                    .font(.body)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(NSColor.windowBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                            }
                        }
                        if isGeneratingFrontLatex || AILatexPlaceholder.hasPlaceholder(frontText) {
                            AILaTeXGeneratingView()
                                .frame(height: 42)
                        }
                    }
                }
                
                // Back (Answer) Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Back Content (Plain Text):")
                            .bold()
                        if isGeneratingBackLatex {
                            Spacer()
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text("Generating LaTeX...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    TextEditor(text: $backText)
                        .font(.system(.body, design: .monospaced))
                        .focused($focusedField, equals: .back)
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
                        let clean = AILatexPlaceholder.cleanText(backText)
                        if !clean.isEmpty {
                            if isLaTeX(clean) {
                                LaTeXView(latex: clean)
                                    .frame(height: 45)
                            } else {
                                Text(clean)
                                    .font(.body)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(NSColor.windowBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                            }
                        }
                        if isGeneratingBackLatex || AILatexPlaceholder.hasPlaceholder(backText) {
                            AILaTeXGeneratingView()
                                .frame(height: 42)
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
                    .disabled(frontText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || backText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeneratingFrontLatex || isGeneratingBackLatex)
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
                    
                    Text("Describe an equation in plain text or paste an image from your clipboard, and AI will convert it into clean LaTeX code.")
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
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Translating equation via AI model...")
                                    .font(.subheadline)
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
                
                Button(action: {
                    pasteOrQueueLatex(target: .front)
                }) {
                    HStack(spacing: 5) {
                        if isTranslatingLaTeX {
                            Text("Paste to Front & Continue")
                        } else {
                            Text("Paste to Front Content")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(latexInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && latexClipboardImage == nil && latexResult.isEmpty)
                
                Button(action: {
                    pasteOrQueueLatex(target: .back)
                }) {
                    HStack(spacing: 5) {
                        if isTranslatingLaTeX {
                            Text("Paste to Back & Continue")
                        } else {
                            Text("Paste to Back Content")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(latexInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && latexClipboardImage == nil && latexResult.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 580, height: 500)
    }
    
    private func pasteClipboardImage() {
        if let image = NSImage(pasteboard: NSPasteboard.general) {
            self.latexClipboardImage = image
            if let optimized = AIHelper.optimizeImageForOCR(image) {
                self.latexImageBase64 = optimized
                translateImageToLatex(base64: optimized)
            }
        }
    }
    
    private func pasteOrQueueLatex(target: EditFocusField) {
        if !latexResult.isEmpty && !latexResult.hasPrefix("Error:") && !latexResult.hasPrefix("No vision model") {
            let wrapped = wrapInLaTeXDelimiters(latexResult)
            if target == .front {
                AILatexPlaceholder.replaceOrAppend(in: &frontText, with: wrapped)
            } else {
                AILatexPlaceholder.replaceOrAppend(in: &backText, with: wrapped)
            }
            showLatexHelper = false
            resetLatexHelper()
            return
        }
        
        let pendingInput = latexInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingImg = latexClipboardImage
        let pendingB64 = latexImageBase64
        
        if target == .front {
            isGeneratingFrontLatex = true
            focusedField = .front
        } else {
            isGeneratingBackLatex = true
            focusedField = .back
        }
        
        showLatexHelper = false
        
        if !isTranslatingLaTeX {
            if !pendingInput.isEmpty {
                translateTextToLatex(input: pendingInput, target: target)
            } else if !pendingB64.isEmpty {
                translateImageToLatex(base64: pendingB64, target: target)
            } else if let img = pendingImg, let opt = AIHelper.optimizeImageForOCR(img) {
                translateImageToLatex(base64: opt, target: target)
            }
        }
    }
    
    private func translateTextToLatex(input: String? = nil, target: EditFocusField? = nil) {
        let textToTranslate = input ?? self.latexInput
        guard !textToTranslate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        self.isTranslatingLaTeX = true
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateToLaTeX(rawEquation: textToTranslate)
            await MainActor.run {
                self.applyLatexTranslationResult(res, target: target)
            }
        }
    }
    
    private func translateImageToLatex(base64: String? = nil, target: EditFocusField? = nil) {
        let b64 = base64 ?? self.latexImageBase64
        guard !b64.isEmpty else { return }
        
        self.isTranslatingLaTeX = true
        self.latexResult = ""
        Task {
            let res = await AIHelper.shared.translateImageToLaTeX(base64Image: b64)
            await MainActor.run {
                self.applyLatexTranslationResult(res, target: target)
            }
        }
    }
    
    private func applyLatexTranslationResult(_ res: String?, target: EditFocusField? = nil) {
        self.isTranslatingLaTeX = false
        if let latex = res, !latex.isEmpty {
            if latex == "MODEL_NOT_FOUND" {
                self.latexResult = "No vision model found on AI server. Please configure or pull a vision model in Settings."
                cleanUpPendingPlaceholders()
                sendAppNotification(title: "Vision Model Missing", body: "Please configure or pull a vision model on your AI server.")
            } else {
                let wrapped = self.wrapInLaTeXDelimiters(latex)
                self.latexResult = wrapped
                
                var inserted = false
                if target == .front || isGeneratingFrontLatex || AILatexPlaceholder.hasPlaceholder(frontText) {
                    AILatexPlaceholder.replaceOrAppend(in: &frontText, with: wrapped)
                    self.isGeneratingFrontLatex = false
                    inserted = true
                }
                if target == .back || isGeneratingBackLatex || AILatexPlaceholder.hasPlaceholder(backText) {
                    AILatexPlaceholder.replaceOrAppend(in: &backText, with: wrapped)
                    self.isGeneratingBackLatex = false
                    inserted = true
                }
                
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(wrapped, forType: .string)
                
                if inserted {
                    sendAppNotification(title: "LaTeX Ready", body: "AI generated equation inserted into flashcard.")
                }
            }
        } else {
            self.latexResult = "Error: Could not transcribe equation. Verify that your AI host (Local or Tailscale) is connected."
            cleanUpPendingPlaceholders()
            sendAppNotification(title: "LaTeX Failed", body: "Could not translate equation. Check AI connection.")
        }
    }
    
    private func cleanUpPendingPlaceholders() {
        self.isGeneratingFrontLatex = false
        self.isGeneratingBackLatex = false
        self.frontText = AILatexPlaceholder.cleanText(self.frontText)
        self.backText = AILatexPlaceholder.cleanText(self.backText)
    }
    
    private func resetLatexHelper() {
        latexInput = ""
        latexResult = ""
        latexClipboardImage = nil
        latexImageBase64 = ""
        isTranslatingLaTeX = false
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
            
            let targetModId = isExamMode ? activeModuleId : nil
            switch popup {
            case .weeklyAvgTime:
                WeeklyAvgTimeChartView(moduleId: targetModId)
            case .dueProjection:
                DueProjectionChartView(moduleId: targetModId)
            case .easeDistribution:
                EaseDistributionChartView(allCards: allCards)
            case .cumulativeCreated:
                CumulativeCreatedChartView(moduleId: targetModId, allCards: allCards)
            }
        }
        .padding(24)
        .frame(width: 680, height: 500)
    }
}

// MARK: - Flashcard Metric Chart Views

@MainActor
struct WeeklyAvgTimeChartView: View {
    let moduleId: Int?
    
    @State private var timeBins: [(rangeLabel: String, count: Int)] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Card Completion Time Distribution")
                        .font(.headline)
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

@MainActor
struct DueProjectionChartView: View {
    let moduleId: Int?
    
    @State private var projections: [(dayLabel: String, dateString: String, count: Int)] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("7-Day Review Workload Projection")
                        .font(.headline)
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

@MainActor
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

@MainActor
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
