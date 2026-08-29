import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct PhysicsStudyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State private var activeYear: Int = 1
    @State private var activeModuleId: Int? = nil
    @State private var sidebarSelection: String? = "Dashboard"
    @State private var isExamMode: Bool = false
    @State private var modules: [Module] = []
    @ObservedObject private var aiHelper = AIHelper.shared
    
    // Auxiliary Window Toggles
    @State private var showModuleManager: Bool = false
    @State private var showFlashcardManager: Bool = false
    @State private var showProblemManager: Bool = false
    @State private var showRedoConfirmationAlert: Bool = false
    @State private var preExamInitialPhase: Int = 1
    @State private var preExamStartInEditor: Bool = false
    
    private var activeModuleName: String {
        if let activeModuleId = activeModuleId,
           let active = modules.first(where: { $0.id == activeModuleId }) {
            return "\(active.code) - \(active.name)"
        }
        return "Project Nobel"
    }
    
    static var ollamaProcess: Process?
    
    static func startOllamaServer() {
        guard ollamaProcess == nil || !(ollamaProcess?.isRunning ?? false) else { return }
        let currentProvider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        guard currentProvider == "local" else { return }
        
        let process = Process()
        let paths = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        var execPath = "ollama"
        for p in paths {
            if FileManager.default.fileExists(atPath: p) {
                execPath = p
                break
            }
        }
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["serve"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        
        do {
            try process.run()
            PhysicsStudyApp.ollamaProcess = process
            print("[PhysicsStudyApp] Spawned background Ollama CLI server: \(execPath)")
        } catch {
            print("[PhysicsStudyApp] Error spawning background Ollama CLI: \(error)")
        }
    }
    
    static func stopOllamaServer() {
        if let process = ollamaProcess, process.isRunning {
            process.terminate()
            ollamaProcess = nil
            print("[PhysicsStudyApp] Terminated background Ollama server for Power Saving Mode.")
        }
    }
    
    init() {
        // One-time migration: fix stale UserDefaults from older app versions
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        if provider == "hermes" {
            let baseUrl = UserDefaults.standard.string(forKey: "cloud_api_base_url") ?? ""
            let modelName = UserDefaults.standard.string(forKey: "cloud_model_name") ?? ""
            if baseUrl == "http://localhost:1234/v1" || baseUrl.isEmpty {
                UserDefaults.standard.set("http://ollama1:11434/v1", forKey: "cloud_api_base_url")
            }
            if modelName == "glm" || modelName.isEmpty {
                UserDefaults.standard.set("glm-5.2:cloud", forKey: "cloud_model_name")
            }
        }
        
        // Ensure local model defaults are persisted (@AppStorage only writes when the Settings view is rendered)
        if UserDefaults.standard.string(forKey: "local_model_vision") == nil {
            UserDefaults.standard.set("qwen2.5vl:7b", forKey: "local_model_vision")
        }
        if UserDefaults.standard.string(forKey: "local_model_general") == nil {
            UserDefaults.standard.set("qwen2.5-coder:7b", forKey: "local_model_general")
        }
        
        // Only launch Ollama serve if using local provider.
        PhysicsStudyApp.startOllamaServer()
        
        // Start AI Background Processor sequentially
        AIHelper.shared.startBackgroundProcessor()
    }
    
    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                // Sidebar
                VStack(alignment: .leading, spacing: 10) {
                    Button(action: {
                        sidebarSelection = "Dashboard"
                    }) {
                        Text("Project Nobel")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .padding(.horizontal)
                    .padding(.top, 20)
                    
                    // Sidebar Navigation Links
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            sidebarListContent
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                    }
                    .id(isExamMode)
                    
                    preExamSidebarControls
                    
                    aiStatusView
                }
                .frame(minWidth: 220)
                .background(.ultraThinMaterial)
            } detail: {
                // Detail Pane
                detailView
            }
            .navigationSplitViewStyle(.balanced)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if let activeMod = modules.first(where: { $0.id == activeModuleId }), !activeMod.testDate.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(activeMod.testDateFormattedDateOnly)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .help(activeMod.daysRemainingFormatted.isEmpty ? "Exam Date for \(activeMod.code): \(activeMod.testDateFormattedDateOnly)" : "Exam Date for \(activeMod.code): \(activeMod.daysRemainingFormatted) (\(activeMod.testDateFormattedDateOnly))")
                    }
                }
                
                ToolbarItemGroup(placement: .primaryAction) {
                    if !modules.isEmpty {
                        Picker("Module", selection: $activeModuleId) {
                            ForEach(modules) { mod in
                                Text("\(mod.code): \(mod.name)").tag(mod.id as Int?)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                    }
                }
            }
            .frame(minWidth: 450, minHeight: 450)
            .navigationTitle("")
            .sheet(isPresented: $showModuleManager) {
                ModuleManagerView(isPresented: $showModuleManager, onRefresh: {
                    refreshSidebarModules()
                })
            }
            .sheet(isPresented: $showFlashcardManager) {
                FlashcardsView(activeModuleId: activeModuleId, activeYear: activeYear, mode: .manage, isExamMode: isExamMode)
                    .frame(width: 780, height: 520)
                    .overlay(
                        VStack {
                            HStack {
                                Spacer()
                                Button("Close") {
                                    showFlashcardManager = false
                                }
                                .buttonStyle(.bordered)
                                .pointingHandCursor()
                                .padding()
                            }
                            Spacer()
                        }
                    )
            }
            .sheet(isPresented: $showProblemManager) {
                ProblemsView(activeModuleId: activeModuleId, activeYear: activeYear, mode: .manage, isExamMode: isExamMode)
                    .frame(width: 600, height: 450)
                    .overlay(
                        VStack {
                            HStack {
                                Spacer()
                                Button("Close") {
                                    showProblemManager = false
                                }
                                .buttonStyle(.bordered)
                                .pointingHandCursor()
                                .padding()
                            }
                            Spacer()
                        }
                    )
            }
            .onAppear {
                restoreSettings()
            }
            .onChange(of: activeYear) { oldValue, newValue in
                Task {
                    DatabaseManager.shared.setSetting(key: "active_year", value: String(newValue))
                }
                refreshSidebarModules()
            }
            .onChange(of: activeModuleId) { oldValue, newValue in
                Task {
                    if let val = newValue {
                        DatabaseManager.shared.setSetting(key: "active_module_id", value: String(val))
                    } else {
                        DatabaseManager.shared.setSetting(key: "active_module_id", value: "")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Auto-sync with Anki before app terminates
                AnkiSyncEngine.shared.syncWithAnkiSynchronously()
                
                PhysicsStudyApp.ollamaProcess?.terminate()
                
                if PhysicsStudyApp.ollamaProcess != nil {
                    let killProcess = Process()
                    killProcess.launchPath = "/usr/bin/killall"
                    killProcess.arguments = ["ollama"]
                    try? killProcess.run()
                }
            }
        }
        .commands {
            CommandGroup(after: .importExport) {
                Button("Sync with Anki") {
                    AnkiSyncEngine.shared.syncWithAnki()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            
            // Add navigation & Mode to the standard macOS View menu
            CommandGroup(after: .sidebar) {
                Picker("Mode", selection: Binding<Bool>(
                    get: { isExamMode },
                    set: { newValue in
                        isExamMode = newValue
                        if newValue {
                            let hiddenPanes = ["Notes & Topics", "Add Flashcard", "Add Problem", "Pre-Lecture", "Post-Lecture"]
                            if let sel = sidebarSelection, hiddenPanes.contains(sel) {
                                sidebarSelection = "Study"
                            }
                        }
                    }
                )) {
                    Text("General Mode").tag(false)
                    Text("Exam Mode").tag(true)
                }
                .pickerStyle(.inline)
                
                Button("Toggle Exam Mode") {
                    let newValue = !isExamMode
                    isExamMode = newValue
                    if newValue {
                        let hiddenPanes = ["Notes & Topics", "Add Flashcard", "Add Problem", "Pre-Lecture", "Post-Lecture"]
                        if let sel = sidebarSelection, hiddenPanes.contains(sel) {
                            sidebarSelection = "Study"
                        }
                    }
                }
                .keyboardShortcut("e", modifiers: .command)
                
                Divider()
                
                Button("Go to Dashboard") { sidebarSelection = "Dashboard" }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Go to Study Guide") { sidebarSelection = "Study" }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Go to Flashcards") { sidebarSelection = "Flashcards" }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Go to Problems") { sidebarSelection = "Problems" }
                    .keyboardShortcut("4", modifiers: .command)
                
                if !isExamMode {
                    Button("Go to Pre-Lecture") { sidebarSelection = "Pre-Lecture" }
                        .keyboardShortcut("5", modifiers: .command)
                    Button("Go to Post-Lecture") { sidebarSelection = "Post-Lecture" }
                        .keyboardShortcut("6", modifiers: .command)
                }
            }
            
            // Unified Module Menu containing academic selections, module cycling, and managers
            CommandMenu("Module") {
                Picker("Active Year", selection: $activeYear) {
                    Text("Year 1").tag(1)
                    Text("Year 2").tag(2)
                    Text("Year 3").tag(3)
                    Text("Year 4").tag(4)
                }
                .pickerStyle(.inline)
                
                Picker("Active Module", selection: $activeModuleId) {
                    if modules.isEmpty {
                        Text("No Modules Found").tag(nil as Int?)
                    } else {
                        ForEach(modules) { m in
                            Text("\(m.code) - \(m.name)").tag(m.id as Int?)
                        }
                    }
                }
                .pickerStyle(.inline)
                
                Divider()
                
                Button("Next Module") {
                    switchToNextModule()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                
                Button("Previous Module") {
                    switchToPreviousModule()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                
                Divider()
                
                Button("Manage Modules...") {
                    showModuleManager = true
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                
                Button("Manage Flashcards...") {
                    showFlashcardManager = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                
                Button("Manage Problems...") {
                    showProblemManager = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
        
        Settings {
            SettingsView()
        }
        
        MenuBarExtra {
            Button("Open Project Nobel") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            
            Divider()
            
            Button("Dashboard") {
                sidebarSelection = "Dashboard"
                NSApp.activate(ignoringOtherApps: true)
            }
            
            Button("Study Guide") {
                sidebarSelection = "Study"
                NSApp.activate(ignoringOtherApps: true)
            }
            
            Button("Flashcards") {
                sidebarSelection = "Flashcards"
                NSApp.activate(ignoringOtherApps: true)
            }
            
            Button("Practice Problems") {
                sidebarSelection = "Problems"
                NSApp.activate(ignoringOtherApps: true)
            }
            
            Divider()
            
            Button("Quit Project Nobel") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: path) {
                let _ = (nsImage.size = NSSize(width: 18, height: 18))
                Image(nsImage: nsImage)
            } else if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
                      let nsImage = NSImage(contentsOfFile: path) {
                let _ = (nsImage.size = NSSize(width: 18, height: 18))
                Image(nsImage: nsImage)
            } else {
                Image(systemName: "atom")
            }
        }
    }
    
    // MARK: - Views routing
    
    @ViewBuilder
    private var sidebarListContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("STUDY MODE")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            
            SidebarNavButton(title: "Study", icon: "book.pages", tag: "Study", selection: $sidebarSelection)
            SidebarNavButton(title: "Flashcards", icon: "square.stack", tag: "Flashcards", selection: $sidebarSelection)
            SidebarNavButton(title: "Problems", icon: "pencil.and.outline", tag: "Problems", selection: $sidebarSelection)
            
            if !isExamMode {
                SidebarNavButton(title: "Pre-Lecture", icon: "lightbulb.min", tag: "Pre-Lecture", selection: $sidebarSelection)
                SidebarNavButton(title: "Post-Lecture", icon: "bubble.left.and.bubble.right", tag: "Post-Lecture", selection: $sidebarSelection)
            }
        }
        
        if !isExamMode {
            VStack(alignment: .leading, spacing: 3) {
                Text("ADD CONTENT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                
                SidebarNavButton(title: "Notes & Topics", icon: "doc.badge.plus", tag: "Notes & Topics", selection: $sidebarSelection)
                SidebarNavButton(title: "Add Flashcard", icon: "plus.rectangle", tag: "Add Flashcard", selection: $sidebarSelection)
                SidebarNavButton(title: "Add Problem", icon: "pencil.line", tag: "Add Problem", selection: $sidebarSelection)
            }
        }
    }
    
    @ViewBuilder
    private var preExamSidebarControls: some View {
        if let activeMod = modules.first(where: { $0.id == activeModuleId }), isExamMode {
            let cardIdsKey = "pre_exam_ai_cards_\(activeMod.id)"
            let hasGeneratedAICards = (UserDefaults.standard.array(forKey: cardIdsKey) as? [Int])?.isEmpty == false
                
                HStack(spacing: 0) {
                    // Main Integrated Pre-Exam Button (Starts from Phase 1)
                    Button(action: {
                        preExamInitialPhase = 1
                        preExamStartInEditor = false
                        sidebarSelection = "PreExamRoutine"
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.green)
                            
                            Text("Pre-Exam Routine")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.primary)
                            
                            Spacer()
                        }
                        .padding(.leading, 10)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    
                    // Top-Right Integrated Redo AI Action Button
                    Button(action: {
                        if aiHelper.isAIBusy { return }
                        if hasGeneratedAICards {
                            showRedoConfirmationAlert = true
                        } else {
                            runAICuration(for: activeMod)
                            preExamInitialPhase = 3
                            preExamStartInEditor = true
                            sidebarSelection = "PreExamRoutine"
                        }
                    }) {
                        Group {
                            if aiHelper.isAIBusy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: hasGeneratedAICards ? "arrow.triangle.2.circlepath" : "sparkles")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(6)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .disabled(aiHelper.isAIBusy)
                    .help(hasGeneratedAICards ? "Redo AI Pre-Exam Selection / Edit Notes" : "Run AI Pre-Exam Selection")
                    .padding(.trailing, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(sidebarSelection == "PreExamRoutine" ? Color.green.opacity(0.22) : Color.green.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.green.opacity(0.35), lineWidth: 1)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .alert("Pre-Exam Options", isPresented: $showRedoConfirmationAlert) {
                    Button("Redo AI Selection", role: .destructive) {
                        runAICuration(for: activeMod)
                        preExamInitialPhase = 3
                        preExamStartInEditor = true
                        sidebarSelection = "PreExamRoutine"
                    }
                    Button("Change / Edit Notes") {
                        preExamInitialPhase = 3
                        preExamStartInEditor = true
                        sidebarSelection = "PreExamRoutine"
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Select 'Redo AI Selection' to curate fresh Phase 1 flashcards and edit your Phase 3 prepared notes, or 'Change / Edit Notes' to update your formulas.")
                }
            }
    }
    
    private func runAICuration(for module: Module) {
        Task {
            await AIHelper.shared.curatePreExamFlashcards(moduleId: module.id, moduleCode: module.code)
        }
    }
    
    @ViewBuilder
    private var aiStatusView: some View {
        if aiHelper.isAIDisconnected {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.blue)
                    
                    Text(aiHelper.disconnectionMessage.isEmpty ? "Tailscale Disconnected" : aiHelper.disconnectionMessage)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                    
                    Spacer()
                }
                
                HStack(spacing: 6) {
                    Text("AI server unreachable.")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: {
                        aiHelper.retryConnectionAndQueue()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .bold))
                            Text("Try Again")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .help("Check AI server connection and resume processing")
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.95))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 15)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if aiHelper.isAIBusy || aiHelper.isClassifyingProblems || aiHelper.isProcessing || !aiHelper.activeProcessingNoteIds.isEmpty {
            let (isLocal, providerName) = aiHelper.activeAIProvider
            let taskText: String = {
                if !aiHelper.currentAITaskDescription.isEmpty {
                    return aiHelper.currentAITaskDescription
                } else if !aiHelper.activeProcessingNoteIds.isEmpty {
                    return "Generating AI Summary..."
                } else if aiHelper.isClassifyingProblems {
                    return aiHelper.queueStatusText
                } else {
                    return aiHelper.activeJobDescription
                }
            }()
            let total = aiHelper.activeProgressTotal > 0 ? aiHelper.activeProgressTotal : (aiHelper.isClassifyingProblems ? aiHelper.classificationQueueCount : 0)
            let current = aiHelper.activeProgressCurrent > 0 ? aiHelper.activeProgressCurrent : (aiHelper.isClassifyingProblems ? aiHelper.classificationCompletedCount : 0)
            
            VStack(alignment: .leading, spacing: 8) {
                // Top Row: Local vs Tailscale/Remote AI Badge
                HStack(spacing: 6) {
                    Image(systemName: isLocal ? "laptopcomputer" : "network")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isLocal ? .green : .blue)
                    
                    Text(providerName.uppercased())
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isLocal ? Color.green : Color.blue).opacity(0.18))
                        .foregroundColor(isLocal ? .green : .blue)
                        .cornerRadius(4)
                    
                    Spacer()
                }
                
                // Middle Row: Task description
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    
                    Text(taskText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                
                // Bottom Row: Progress bar & percentage
                VStack(alignment: .leading, spacing: 4) {
                    if total > 0 {
                        let pct = Int((Double(current) / Double(max(total, 1))) * 100)
                        ProgressView(value: Double(current), total: Double(max(total, 1)))
                            .progressViewStyle(.linear)
                            .tint(isLocal ? Color.green : Color.blue)
                        
                        HStack {
                            Text("\(current) of \(total) completed")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(pct)%")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(isLocal ? .green : .blue)
                        }
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(isLocal ? Color.green : Color.blue)
                    }
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.85))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isLocal ? Color.green.opacity(0.3) : Color.blue.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 15)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: aiHelper.isAIBusy || !aiHelper.activeProcessingNoteIds.isEmpty || aiHelper.isProcessing)
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection {
        case "Dashboard":
            DashboardView(activeYear: activeYear)
        case "Study":
            StudyView(activeModuleId: activeModuleId)
        case "Flashcards":
            FlashcardsView(activeModuleId: activeModuleId, activeYear: activeYear, mode: .start, isExamMode: isExamMode, isActive: true)
        case "Problems":
            ProblemsView(activeModuleId: activeModuleId, activeYear: activeYear, mode: .review, isExamMode: isExamMode, isActive: true)
        case "Pre-Lecture":
            PreLectureView(activeModuleId: activeModuleId)
        case "Post-Lecture":
            PostLectureView(activeModuleId: activeModuleId)
        case "Notes & Topics":
            ModulesView(activeModuleId: activeModuleId)
        case "Add Flashcard":
            FlashcardsView(activeModuleId: activeModuleId, activeYear: activeYear, mode: .add, isExamMode: isExamMode, isActive: true)
        case "Add Problem":
            ProblemsView(activeModuleId: activeModuleId, activeYear: activeYear, mode: .add, isExamMode: isExamMode, isActive: true)
        case "Settings":
            SettingsView()
        case "PreExamRoutine":
            let activeMod = modules.first(where: { $0.id == activeModuleId })
            PreExamRoutineView(
                activeModule: activeMod,
                initialPhase: preExamInitialPhase,
                startInEditor: preExamStartInEditor,
                onFinishWarmup: {
                    sidebarSelection = "Dashboard"
                    isExamMode = true
                }
            )
        default:
            DashboardView(activeYear: activeYear)
        }
    }
    
    // MARK: - Logic functions
    
    private func refreshSidebarModules() {
        let loaded = DatabaseManager.shared.getModules(forYear: activeYear)
        self.modules = loaded
        if let currentId = activeModuleId, loaded.contains(where: { $0.id == currentId }) {
            // Keep current module active if it's still valid for this year
        } else {
            if let first = loaded.first {
                self.activeModuleId = first.id
            } else {
                self.activeModuleId = nil
            }
        }
    }
    
    private func restoreSettings() {
        let savedYear = DatabaseManager.shared.getSetting(key: "active_year").flatMap(Int.init) ?? 1
        self.activeYear = savedYear
        
        let loaded = DatabaseManager.shared.getModules(forYear: savedYear)
        self.modules = loaded
        
        let savedModuleId = DatabaseManager.shared.getSetting(key: "active_module_id").flatMap(Int.init)
        if let savedModuleId = savedModuleId, loaded.contains(where: { $0.id == savedModuleId }) {
            self.activeModuleId = savedModuleId
        } else if let first = loaded.first {
            self.activeModuleId = first.id
        } else {
            self.activeModuleId = nil
        }
    }
    
    private func switchToNextModule() {
        guard !modules.isEmpty else { return }
        if let currentId = activeModuleId, let index = modules.firstIndex(where: { $0.id == currentId }) {
            let nextIndex = (index + 1) % modules.count
            activeModuleId = modules[nextIndex].id
        } else if let first = modules.first {
            activeModuleId = first.id
        }
    }
    
    private func switchToPreviousModule() {
        guard !modules.isEmpty else { return }
        if let currentId = activeModuleId, let index = modules.firstIndex(where: { $0.id == currentId }) {
            let prevIndex = (index - 1 + modules.count) % modules.count
            activeModuleId = modules[prevIndex].id
        } else if let first = modules.first {
            activeModuleId = first.id
        }
    }
}

// MARK: - Custom Interactive Sidebar Nav Button with Pointing Hand
struct SidebarNavButton: View {
    let title: String
    let icon: String
    let tag: String
    @Binding var selection: String?
    
    var isSelected: Bool {
        selection == tag
    }
    
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: {
            selection = tag
        }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .frame(width: 18)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.85))
                
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.blue.opacity(0.16) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover in
            isHovered = hover
        }
    }
}

