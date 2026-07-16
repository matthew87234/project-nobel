import SwiftUI
import Charts

struct HeatmapView: View {
    let secondsData: [String: Int]
    
    private var dates: [[Date]] {
        let calendar = Calendar.current
        let today = Date()
        
        let weekday = calendar.component(.weekday, from: today)
        let daysToSubtract = (weekday - 2 + 7) % 7
        let nearestMonday = calendar.date(byAdding: .day, value: -daysToSubtract, to: today)!
        let startDate = calendar.date(byAdding: .weekOfYear, value: -52, to: nearestMonday)!
        
        var grid: [[Date]] = Array(repeating: [], count: 7)
        for week in 0..<53 {
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
        guard grid.count > 0, grid[0].count == 53 else { return [] }
        
        var lastMonth = -1
        for col in 0..<53 {
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
        let grid = dates
        VStack(alignment: .leading, spacing: 4) {
            // Month labels row
            HStack(spacing: 0) {
                Spacer().frame(width: 25)
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: 12)
                    ForEach(monthLabels, id: \.index) { labelInfo in
                        Text(labelInfo.label)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .offset(x: CGFloat(labelInfo.index) * 11)
                    }
                }
            }
            .frame(height: 12)
            
            HStack(spacing: 6) {
                // Day labels column
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mon").font(.system(size: 8)).foregroundColor(.secondary)
                    Spacer()
                    Text("Wed").font(.system(size: 8)).foregroundColor(.secondary)
                    Spacer()
                    Text("Fri").font(.system(size: 8)).foregroundColor(.secondary)
                }
                .frame(height: 74)
                
                // Grid of cells
                HStack(spacing: 3) {
                    ForEach(0..<53, id: \.self) { col in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { row in
                                if col < grid[row].count {
                                    let date = grid[row][col]
                                    let dateStr = formatDate(date)
                                    let seconds = secondsData[dateStr] ?? 0
                                    cellColor(for: seconds)
                                        .frame(width: 8, height: 8)
                                        .cornerRadius(1)
                                        .help("\(formatUKDate(date)): \(formatMinutes(seconds)) studied")
                                } else {
                                    Color.clear.frame(width: 8, height: 8)
                                }
                            }
                        }
                    }
                }
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
    
    @State private var heatmapData: [String: Int] = [:]
    @State private var modules: [Module] = []
    
    // AI Tracker
    @State private var completedTasks: Int = 0
    @State private var totalTasks: Int = 0
    @State private var completionPercentage: Int = 100
    @State private var activeJob: String = "Idle"
    @State private var isProcessing: Bool = false
    
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
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
                .padding(.horizontal)
                .padding(.top, 20)
                
                // 1. Metrics Cards (Always 1 row)
                HStack(spacing: 15) {
                    metricCard(title: "FLASHCARDS CREATED", value: "\(flashcardsCreated)", subtitle: timeframe)
                    metricCard(title: "PROBLEMS CREATED", value: "\(problemsCreated)", subtitle: timeframe)
                    metricCard(title: "AVG FLASHCARD TIME", value: formatAverageTime(avgFlashcardSolveTime), subtitle: timeframe)
                    metricCard(title: "AVG PROBLEM TIME", value: formatAverageTime(avgProblemSolveTime), subtitle: timeframe)
                }
                .padding(.horizontal)
                
                // 2. Twin Charts Row (Responsive Grid side by side)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: .infinity))], spacing: 20) {
                    // Bar Chart
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Time Spent")
                            .font(.headline)
                        
                        Chart {
                            ForEach(studyTimeBarData, id: \.label) { item in
                                BarMark(
                                    x: .value("Interval", item.label),
                                    y: .value("Minutes", item.flashcards)
                                )
                                .foregroundStyle(Color.blue)
                                .position(by: .value("Type", "Flashcards"))
                                
                                BarMark(
                                    x: .value("Interval", item.label),
                                    y: .value("Minutes", item.problems)
                                )
                                .foregroundStyle(Color.green)
                                .position(by: .value("Type", "Problems"))
                            }
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
                        Text("Study Time Distribution")
                            .font(.headline)
                        
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
                            Chart {
                                SectorMark(
                                    angle: .value("Time", Double(flashcardsStudySeconds)),
                                    innerRadius: .ratio(0.6),
                                    angularInset: 1.5
                                )
                                .foregroundStyle(Color.blue)
                                .annotation(position: .overlay) {
                                    Text("\(roundedPercent(fcPercent))%")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                
                                SectorMark(
                                    angle: .value("Time", Double(problemsStudySeconds)),
                                    innerRadius: .ratio(0.6),
                                    angularInset: 1.5
                                )
                                .foregroundStyle(Color.green)
                                .annotation(position: .overlay) {
                                    Text("\(roundedPercent(100.0 - fcPercent))%")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(height: 200)
                            .chartForegroundStyleScale([
                                "Flashcards": Color.blue,
                                "Problems": Color.green
                            ])
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                
                // 3. Heatmap Row
                VStack(alignment: .leading, spacing: 15) {
                    Text("Daily Study Activity Heatmap")
                        .font(.headline)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HeatmapView(secondsData: heatmapData)
                            .padding(.vertical, 8)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(12)
                .padding(.horizontal)
                
                // 4. Module Study Time Table & AI Progress Tracker (Responsive Grid)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: .infinity))], spacing: 20) {
                    // Module Study Time Table
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
                            .frame(width: 220)
                            .onChange(of: selectedSemesterFilter) { oldValue, newValue in
                                loadDashboard()
                            }
                        }
                        
                        VStack(spacing: 0) {
                            // Headers
                            HStack {
                                Text("Module").bold().frame(width: 100, alignment: .leading)
                                Text("Name").bold().frame(maxWidth: .infinity, alignment: .leading)
                                Text("Duration").bold().frame(width: 80, alignment: .trailing)
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
                                                .frame(width: 100, alignment: .leading)
                                            Text(m.name)
                                                .lineLimit(1)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(formatSeconds(totalSecs))
                                                .frame(width: 80, alignment: .trailing)
                                        }
                                        .padding(.vertical, 4)
                                        Divider()
                                    }
                                }
                            }
                            .frame(height: 150)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    
                    // AI Background Task Progress Tracker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local AI Progress Tracker")
                            .font(.headline)
                        
                        Spacer()
                        
                        HStack {
                            Text("Completion Rate:")
                                .font(.subheadline)
                            Spacer()
                            Text("\(completionPercentage)%")
                                .font(.headline)
                                .foregroundColor(completionPercentage == 100 ? .green : .orange)
                        }
                        
                        ProgressView(value: Double(completionPercentage) / 100.0)
                            .progressViewStyle(.linear)
                            
                        HStack {
                            Text("Task Status:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            if isProcessing {
                                Text("ACTIVE")
                                    .font(.caption)
                                    .bold()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(4)
                            } else {
                                Text("IDLE")
                                    .font(.caption)
                                    .bold()
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.2))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(4)
                            }
                        }
                        
                        if isProcessing {
                            Text("Processing: \(activeJob)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                        
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            loadDashboard()
        }
        .onChange(of: activeYear) { oldValue, newValue in
            loadDashboard()
        }
        .onReceive(timer) { _ in
            pollAIStatus()
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
    
    private func loadDashboard() {
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
        pollAIStatus()
    }
    
    private func loadHeatmap() {
        let modId = selectedHeatmapModuleId == -1 ? nil : selectedHeatmapModuleId
        self.heatmapData = DatabaseManager.shared.getDailyStudySecondsLastYear(moduleId: modId)
    }
    
    private func pollAIStatus() {
        let allNotesRows = DatabaseManager.shared.query(sql: "SELECT id, file_path, ai_summary, pre_lecture_primer FROM notes")
        
        let fileManager = FileManager.default
        var total = 0
        var sumDone = 0
        var primerDone = 0
        
        for row in allNotesRows {
            let noteId = row["id"] as? Int ?? 0
            if AIHelper.shared.isNoteFailed(noteId: noteId) {
                continue
            }
            
            let filePath = row["file_path"] as? String ?? ""
            guard !filePath.isEmpty else {
                continue
            }
            
            total += 1
            
            if let sum = row["ai_summary"] as? String, !sum.isEmpty {
                sumDone += 1
            }
            if let primer = row["pre_lecture_primer"] as? String, !primer.isEmpty {
                primerDone += 1
            }
        }
        
        if total == 0 {
            self.completionPercentage = 100
            self.completedTasks = 0
            self.totalTasks = 0
        } else {
            self.totalTasks = total * 2
            self.completedTasks = sumDone + primerDone
            self.completionPercentage = Int((Double(completedTasks) / Double(totalTasks)) * 100)
        }
        
        self.isProcessing = AIHelper.shared.isProcessing
        self.activeJob = AIHelper.shared.activeJobDescription
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
