import SwiftUI
import Charts
import Combine

struct DayStudyDetailPopover: View {
    let date: Date
    let breakdown: DatabaseManager.DailyStudyBreakdown?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundColor(.blue)
                    .font(.headline)
                Text(formatFullDate(date))
                    .font(.headline)
                    .bold()
                Spacer()
            }
            
            Divider()
            
            let fcSecs = breakdown?.flashcardsSeconds ?? 0
            let pbSecs = breakdown?.problemsSeconds ?? 0
            let totalSecs = fcSecs + pbSecs
            
            if totalSecs > 0 {
                VStack(spacing: 10) {
                    HStack {
                        Text("Total Time Studied:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatDuration(totalSecs))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                    }
                    
                    // Flashcards Row
                    HStack(spacing: 8) {
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                        Text("Flashcards")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text(formatDuration(fcSecs))
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.blue)
                        let pct = Int((Double(fcSecs) / Double(totalSecs)) * 100)
                        Text("(\(pct)%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Problems Row
                    HStack(spacing: 8) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("Problems")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text(formatDuration(pbSecs))
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(.green)
                        let pct = Int((Double(pbSecs) / Double(totalSecs)) * 100)
                        Text("(\(pct)%)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    // Mini Ratio Progress Bar
                    GeometryReader { geo in
                        let fcRatio = CGFloat(fcSecs) / CGFloat(totalSecs)
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.blue)
                                .frame(width: max(4, (geo.size.width - 2) * fcRatio))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.green)
                                .frame(width: max(4, (geo.size.width - 2) * (1.0 - fcRatio)))
                        }
                    }
                    .frame(height: 6)
                    .padding(.top, 4)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundColor(.secondary)
                    Text("No study activity logged on this day.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
    
    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return "\(h)h \(m)m"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else if s > 0 {
            return "\(s)s"
        }
        return "0m"
    }
}

struct HeatmapView: View {
    let secondsData: [String: DatabaseManager.DailyStudyBreakdown]
    @State private var selectedDate: Date? = nil
    @State private var showPopover: Bool = false
    private let weeksCount = 53
    private let cellSpacing: CGFloat = 1.8
    
    private var dates: [[Date]] {
        let calendar = Calendar.current
        let today = Date()
        
        let weekday = calendar.component(.weekday, from: today)
        let daysToSubtract = (weekday - 2 + 7) % 7
        let nearestMonday = calendar.date(byAdding: .day, value: -daysToSubtract, to: today)!
        let startDate = calendar.date(byAdding: .weekOfYear, value: -(weeksCount - 1), to: nearestMonday)!
        
        var grid: [[Date]] = Array(repeating: [], count: 7)
        for week in 0..<weeksCount {
            for day in 0..<7 {
                if let date = calendar.date(byAdding: .day, value: week * 7 + day, to: startDate) {
                    grid[day].append(date)
                }
            }
        }
        return grid
    }
    
    private var monthLabels: [(index: Int, label: String)] {
        let calendar = Calendar.current
        var labels: [(index: Int, label: String)] = []
        let grid = dates
        guard grid.count > 0, grid[0].count == weeksCount else { return [] }
        
        var lastMonth = -1
        for col in 0..<weeksCount {
            let date = grid[0][col]
            let month = calendar.component(.month, from: date)
            if month != lastMonth {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM"
                labels.append((index: col, label: formatter.string(from: date)))
                lastMonth = month
            }
        }
        return labels
    }
    
    var body: some View {
        GeometryReader { geo in
            let availWidth = max(260, geo.size.width - 25)
            let colWidth = availWidth / CGFloat(weeksCount)
            let cellSize = max(3.5, colWidth - cellSpacing)
            let grid = dates
            
            VStack(alignment: .leading, spacing: 4) {
                // Month labels row
                HStack(spacing: 0) {
                    Spacer().frame(width: 22)
                    ZStack(alignment: .leading) {
                        Color.clear.frame(height: 12)
                        ForEach(monthLabels, id: \.index) { labelInfo in
                            Text(labelInfo.label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.secondary)
                                .offset(x: CGFloat(labelInfo.index) * colWidth)
                        }
                    }
                }
                .frame(height: 12)
                
                HStack(spacing: 4) {
                    // Day labels column
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mon").font(.system(size: 8)).foregroundColor(.secondary)
                        Spacer()
                        Text("Wed").font(.system(size: 8)).foregroundColor(.secondary)
                        Spacer()
                        Text("Fri").font(.system(size: 8)).foregroundColor(.secondary)
                    }
                    .frame(height: (cellSize * 7) + (cellSpacing * 6))
                    
                    // Grid of cells
                    HStack(spacing: cellSpacing) {
                        ForEach(0..<weeksCount, id: \.self) { col in
                            VStack(spacing: cellSpacing) {
                                ForEach(0..<7, id: \.self) { row in
                                    if col < grid[row].count {
                                        let date = grid[row][col]
                                        let dateStr = formatDate(date)
                                        let breakdown = secondsData[dateStr]
                                        let seconds = breakdown?.totalSeconds ?? 0
                                        cellColor(for: seconds)
                                            .frame(width: cellSize, height: cellSize)
                                            .cornerRadius(1)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 1)
                                                    .stroke(selectedDate == date && showPopover ? Color.blue : Color.clear, lineWidth: 1)
                                            )
                                            .contentShape(Rectangle())
                                            .pointingHandCursor()
                                            .onTapGesture {
                                                selectedDate = date
                                                showPopover = true
                                            }
                                            .help("\(formatUKDate(date)): \(formatMinutes(seconds)) studied (Click for details)")
                                    } else {
                                        Color.clear.frame(width: cellSize, height: cellSize)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 90)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            if let date = selectedDate {
                DayStudyDetailPopover(date: date, breakdown: secondsData[formatDate(date)])
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func formatUKDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy"
        return formatter.string(from: date)
    }
    
    private func formatMinutes(_ seconds: Int) -> String {
        let mins = seconds / 60
        if mins == 0 && seconds > 0 {
            return "1 min"
        }
        return "\(mins) mins"
    }
    
    private func cellColor(for seconds: Int) -> Color {
        let mins = Double(seconds) / 60.0
        if mins <= 0 {
            return Color.primary.opacity(0.08)
        } else if mins < 30 {
            return Color.blue.opacity(0.25)
        } else if mins < 60 {
            return Color.blue.opacity(0.5)
        } else if mins < 120 {
            // HIG standard blue
            return Color.blue.opacity(0.75)
        } else {
            return Color.blue
        }
    }
}

struct DashboardView: View {
    let activeYear: Int

    @State private var timeframe: String = "This Week"
    @State private var selectedHeatmapModuleId: Int = -1 // -1 means All
    @State private var selectedSemesterFilter: String
    
    @State private var studyTimeBarData: [(label: String, flashcards: Int, problems: Int)] = []
    @State private var flashcardsStudySeconds: Int = 0
    @State private var problemsStudySeconds: Int = 0
    
    @State private var flashcardsCreated: Int = 0
    @State private var problemsCreated: Int = 0
    
    @State private var avgFlashcardSolveTime: Double = 0.0
    @State private var avgProblemSolveTime: Double = 0.0
    
    @State private var heatmapData: [String: DatabaseManager.DailyStudyBreakdown] = [:]
    @State private var modules: [Module] = []
    
    // AI Tracker
    @State private var completedTasks: Int = 0
    @State private var totalTasks: Int = 0
    @State private var completionPercentage: Int = 100
    @State private var activeJob: String = "Idle"
    @State private var isProcessing: Bool = false
    
    let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    
    init(activeYear: Int) {
        self.activeYear = activeYear
        
        let month = Calendar.current.component(.month, from: Date())
        let defaultSem: String
        if [9, 10, 11, 12, 1].contains(month) {
            defaultSem = "Semester 1"
        } else if [2, 3, 4, 5, 6].contains(month) {
            defaultSem = "Semester 2"
        } else {
            defaultSem = "Both"
        }
        self._selectedSemesterFilter = State(initialValue: defaultSem)
        
        let yearModules = DatabaseManager.shared.getModules(forYear: activeYear)
        let filteredModules: [Module]
        if defaultSem == "Semester 1" {
            filteredModules = yearModules.filter { $0.semester == 1 }
        } else if defaultSem == "Semester 2" {
            filteredModules = yearModules.filter { $0.semester == 2 }
        } else {
            filteredModules = yearModules
        }
        self._modules = State(initialValue: filteredModules)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                // Header Row
                ViewThatFits(in: .horizontal) {
                    // Level 1: Full horizontal row
                    HStack(spacing: 12) {
                        Text("Dashboard")
                            .font(.system(size: 28, weight: .bold))
                        
                        Spacer()
                        
                        Picker("Module", selection: $selectedHeatmapModuleId) {
                            Text("All Modules").tag(-1)
                            ForEach(modules) { m in
                                Text("\(m.code) - \(m.name)").tag(m.id)
                            }
                        }
                        .frame(width: 220)
                        .onChange(of: selectedHeatmapModuleId) { oldValue, newValue in
                            loadDashboard()
                        }
                        
                        Picker("", selection: $timeframe) {
                            Text("Today").tag("Today")
                            Text("This Week").tag("This Week")
                            Text("This Month").tag("This Month")
                            Text("All Time").tag("All Time")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 320)
                        .onChange(of: timeframe) { oldValue, newValue in
                            loadDashboard()
                        }
                    }
                    
                    // Level 2: Title on top, Pickers side-by-side
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dashboard")
                            .font(.system(size: 28, weight: .bold))
                        
                        HStack(spacing: 12) {
                            Picker("Module", selection: $selectedHeatmapModuleId) {
                                Text("All Modules").tag(-1)
                                ForEach(modules) { m in
                                    Text("\(m.code) - \(m.name)").tag(m.id)
                                }
                            }
                            .frame(width: 220)
                            .onChange(of: selectedHeatmapModuleId) { oldValue, newValue in
                                loadDashboard()
                            }
                            
                            Spacer()
                            
                            Picker("", selection: $timeframe) {
                                Text("Today").tag("Today")
                                Text("This Week").tag("This Week")
                                Text("This Month").tag("This Month")
                                Text("All Time").tag("All Time")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 320)
                            .onChange(of: timeframe) { oldValue, newValue in
                                loadDashboard()
                            }
                        }
                    }
                    
                    // Level 3: Fully vertical stacked (menu style dropdown for timeframe)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Dashboard")
                            .font(.system(size: 28, weight: .bold))
                        
                        Picker("Module", selection: $selectedHeatmapModuleId) {
                            Text("All Modules").tag(-1)
                            ForEach(modules) { m in
                                Text("\(m.code) - \(m.name)").tag(m.id)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .onChange(of: selectedHeatmapModuleId) { oldValue, newValue in
                            loadDashboard()
                        }
                        
                        Picker("Timeframe", selection: $timeframe) {
                            Text("Today").tag("Today")
                            Text("This Week").tag("This Week")
                            Text("This Month").tag("This Month")
                            Text("All Time").tag("All Time")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .onChange(of: timeframe) { oldValue, newValue in
                            loadDashboard()
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                
                // 1. Metrics Cards (Always 1 row)
                HStack(spacing: 15) {
                    metricCard(title: "FLASHCARDS CREATED", value: "\(flashcardsCreated)", subtitle: timeframe)
                    metricCard(title: "PROBLEMS CREATED", value: "\(problemsCreated)", subtitle: timeframe)
                    metricCard(title: "AVG FLASHCARD TIME", value: formatAverageTime(avgFlashcardSolveTime), subtitle: timeframe)
                    metricCard(title: "AVG PROBLEM TIME", value: formatAverageTime(avgProblemSolveTime), subtitle: timeframe)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                
                // 2. Twin Charts Row (50/50 Equal Split Grid)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                    // Bar Chart
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Time Spent")
                            .font(.headline)
                        
                        Chart(flattenedBarData) { item in
                            BarMark(
                                x: .value("Interval", item.label),
                                y: .value("Minutes", item.minutes)
                            )
                            .foregroundStyle(item.category == "Flashcards" ? Color.blue : Color.green)
                            .position(by: .value("Type", item.category))
                        }
                        .frame(height: 200)
                        .chartForegroundStyleScale([
                            "Flashcards": Color.blue,
                            "Problems": Color.green
                        ])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    
                    // Donut Chart
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Study Time Distribution")
                                .font(.headline)
                            Spacer()
                            Text(timeframe)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if flashcardsStudySeconds == 0 && problemsStudySeconds == 0 {
                            VStack {
                                Spacer()
                                Text("No study logs recorded for this period.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                        } else {
                            ZStack {
                                Chart {
                                    SectorMark(
                                        angle: .value("Time", Double(flashcardsStudySeconds)),
                                        innerRadius: .ratio(0.65),
                                        angularInset: 2.0
                                    )
                                    .foregroundStyle(Color.blue)
                                    .annotation(position: .overlay) {
                                        if fcPercent > 12 {
                                            Text("\(roundedPercent(fcPercent))%")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                    
                                    SectorMark(
                                        angle: .value("Time", Double(problemsStudySeconds)),
                                        innerRadius: .ratio(0.65),
                                        angularInset: 2.0
                                    )
                                    .foregroundStyle(Color.green)
                                    .annotation(position: .overlay) {
                                        if (100.0 - fcPercent) > 12 {
                                            Text("\(roundedPercent(100.0 - fcPercent))%")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .frame(height: 200)
                                .chartForegroundStyleScale([
                                    "Flashcards": Color.blue,
                                    "Problems": Color.green
                                ])
                                
                                // Central Summary Badge
                                VStack(spacing: 2) {
                                    let totalSecs = flashcardsStudySeconds + problemsStudySeconds
                                    Text(formatSeconds(totalSecs))
                                        .font(.system(size: 16, weight: .bold, design: .rounded))
                                        .foregroundColor(.primary)
                                    Text("Total Time")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                
                // 3. Heatmap (Left) & Module Study Time Table (Right) (50/50 Equal Split Grid)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                    // Left: Heatmap
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Daily Study Activity Heatmap")
                                .font(.headline)
                            Spacer()
                            Text("Past Year")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HeatmapView(secondsData: heatmapData)
                            .padding(.vertical, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    
                    // Right: Module Study Time Table
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Module Study Time")
                                .font(.headline)
                            Spacer()
                            Picker("", selection: $selectedSemesterFilter) {
                                Text("Semester 1").tag("Semester 1")
                                Text("Semester 2").tag("Semester 2")
                                Text("Both").tag("Both")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 200)
                            .onChange(of: selectedSemesterFilter) { oldValue, newValue in
                                loadDashboard()
                            }
                        }
                        
                        VStack(spacing: 0) {
                            // Headers
                            HStack {
                                Text("Module").bold().frame(width: 90, alignment: .leading)
                                Text("Name").bold().frame(maxWidth: .infinity, alignment: .leading)
                                Text("Duration").bold().frame(width: 75, alignment: .trailing)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 8)
                            
                            Divider()
                            
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(modules) { m in
                                        let times = DatabaseManager.shared.getModuleTotalStudyTime(forModuleId: m.id, timeframe: timeframe)
                                        let totalSecs = times.flashcards + times.problems
                                        HStack {
                                            Text(m.code)
                                                .font(.system(.body, design: .monospaced))
                                                .frame(width: 90, alignment: .leading)
                                            Text(m.name)
                                                .lineLimit(1)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(formatSeconds(totalSecs))
                                                .frame(width: 75, alignment: .trailing)
                                        }
                                        .padding(.vertical, 4)
                                        Divider()
                                    }
                                }
                            }
                            .frame(height: 100)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            loadDashboard()
        }
        .onChange(of: activeYear) { oldValue, newValue in
            loadDashboard()
        }
    }
    
    // MARK: - Helper views
    
    private func metricCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
    
    // MARK: - Calculations and queries
    
    @MainActor private func loadDashboard() {
        // Created counts
        let counts = DatabaseManager.shared.getCreatedCounts(timeframe: timeframe, moduleId: selectedHeatmapModuleId)
        self.flashcardsCreated = counts.flashcards
        self.problemsCreated = counts.problems
        
        // Averages
        let startStr = getStartDateStr()
        let avgs = DatabaseManager.shared.getAvgSolveTimes(timeframeStartDate: startStr, moduleId: selectedHeatmapModuleId)
        self.avgFlashcardSolveTime = avgs.flashcardAvg
        self.avgProblemSolveTime = avgs.problemAvg
        
        // Bar data (minutes spent)
        self.studyTimeBarData = DatabaseManager.shared.getStudyTimeBarData(timeframe: timeframe, moduleId: selectedHeatmapModuleId)
        
        // Donut data: Query overall study times for the period
        self.flashcardsStudySeconds = 0
        self.problemsStudySeconds = 0
        
        let studyRows: [[String: Any]]
        if selectedHeatmapModuleId != -1 {
            studyRows = DatabaseManager.shared.query(sql: """
                SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb 
                FROM module_study_time 
                WHERE module_id = ? AND date >= ?
            """, params: [selectedHeatmapModuleId, startStr])
        } else {
            studyRows = DatabaseManager.shared.query(sql: """
                SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb 
                FROM daily_study_time 
                WHERE date >= ?
            """, params: [startStr])
        }
        
        if let row = studyRows.first {
            self.flashcardsStudySeconds = row["fc"] as? Int ?? 0
            self.problemsStudySeconds = row["pb"] as? Int ?? 0
        }
        
        // Modules list - filter by activeYear and selectedSemesterFilter
        let yearModules = DatabaseManager.shared.getModules(forYear: activeYear)
        let filteredModules: [Module]
        if selectedSemesterFilter == "Semester 1" {
            filteredModules = yearModules.filter { $0.semester == 1 }
        } else if selectedSemesterFilter == "Semester 2" {
            filteredModules = yearModules.filter { $0.semester == 2 }
        } else {
            filteredModules = yearModules
        }
        self.modules = filteredModules
        
        // Reset selected module filter if it's not in the current list of modules
        if selectedHeatmapModuleId != -1 && !filteredModules.contains(where: { $0.id == selectedHeatmapModuleId }) {
            self.selectedHeatmapModuleId = -1
        }
        
        loadHeatmap()
    }
    
    private var flattenedBarData: [BarChartItem] {
        var items: [BarChartItem] = []
        for item in studyTimeBarData {
            items.append(BarChartItem(id: "\(item.label)-fc", label: item.label, category: "Flashcards", minutes: item.flashcards))
            items.append(BarChartItem(id: "\(item.label)-prob", label: item.label, category: "Problems", minutes: item.problems))
        }
        return items
    }
    
    @MainActor private func loadHeatmap() {
        let modId = selectedHeatmapModuleId == -1 ? nil : selectedHeatmapModuleId
        self.heatmapData = DatabaseManager.shared.getDailyStudyBreakdownLastYear(moduleId: modId)
    }
    
    private func getStartDateStr() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let today = Date()
        
        if timeframe == "Today" {
            return formatter.string(from: today)
        } else if timeframe == "This Week" {
            let start = calendar.date(byAdding: .day, value: -7, to: today)!
            return formatter.string(from: start)
        } else if timeframe == "This Month" {
            let start = calendar.date(byAdding: .day, value: -30, to: today)!
            return formatter.string(from: start)
        } else {
            return "1970-01-01"
        }
    }
    
    private var totalStudySeconds: Int {
        return flashcardsStudySeconds + problemsStudySeconds
    }
    
    private var fcPercent: Double {
        guard totalStudySeconds > 0 else { return 0.0 }
        return (Double(flashcardsStudySeconds) / Double(totalStudySeconds)) * 100.0
    }
    
    private func roundedPercent(_ value: Double) -> Int {
        return Int(round(value))
    }
    
    private func formatSeconds(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        return "\(m)m"
    }
    
    private func formatAverageTime(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0s" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        
        if h > 0 {
            return "\(h)h \(m)m \(s)s"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }
}

struct BarChartItem: Identifiable {
    let id: String
    let label: String
    let category: String
    let minutes: Int
}
