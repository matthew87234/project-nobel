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
    
    // Auxiliary Window Toggles
    @State private var showModuleManager: Bool = false
    @State private var showFlashcardManager: Bool = false
    @State private var showProblemManager: Bool = false
    
    private var activeModuleName: String {
        if let activeModuleId = activeModuleId,
           let active = modules.first(where: { $0.id == activeModuleId }) {
            return "\(active.code) - \(active.name)"
        }
        return "Project Nobel"
    }
    
    static var ollamaProcess: Process?
    
    init() {
        // Launch Ollama serve CLI in the background
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
                    .padding(.horizontal)
                    .padding(.top, 20)
                    
                    // Sidebar Navigation Links List
                    List(selection: $sidebarSelection) {
                        Section(header: Text("STUDY MODE").font(.caption).bold()) {
                            Label("Study", systemImage: "book.pages")
                                .tag("Study")
                            Label("Flashcards", systemImage: "square.stack")
                                .tag("Flashcards")
                            Label("Problems", systemImage: "pencil.and.outline")
                                .tag("Problems")
                            
                            if !isExamMode {
                                Label("Pre-Lecture", systemImage: "lightbulb.min")
                                    .tag("Pre-Lecture")
                                Label("Post-Lecture", systemImage: "bubble.left.and.bubble.right")
                                    .tag("Post-Lecture")
                            }
                        }
                        
                        if !isExamMode {
                            Section(header: Text("ADD CONTENT").font(.caption).bold()) {
                                Label("Notes & Topics", systemImage: "doc.badge.plus")
                                    .tag("Notes & Topics")
                                Label("Add Flashcard", systemImage: "plus.rectangle")
                                    .tag("Add Flashcard")
                                Label("Add Problem", systemImage: "pencil.line")
                                    .tag("Add Problem")
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .id(isExamMode)
                }
                .frame(minWidth: 200)
            } detail: {
                // Detail Pane
                detailView
                    .id(activeModuleId)
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: 450, minHeight: 450)
            .navigationTitle(activeModuleName)
            .sheet(isPresented: $showModuleManager) {
                ModuleManagerView(isPresented: $showModuleManager, onRefresh: {
                    refreshSidebarModules()
                })
            }
            .sheet(isPresented: $showFlashcardManager) {
                FlashcardsView(activeModuleId: activeModuleId, mode: .manage, isExamMode: isExamMode)
                    .frame(width: 600, height: 450)
                    .overlay(
                        VStack {
                            HStack {
                                Spacer()
                                Button("Close") {
                                    showFlashcardManager = false
                                }
                                .buttonStyle(.bordered)
                                .padding()
                            }
                            Spacer()
                        }
                    )
            }
            .sheet(isPresented: $showProblemManager) {
                ProblemsView(activeModuleId: activeModuleId, mode: .manage, isExamMode: isExamMode)
                    .frame(width: 600, height: 450)
                    .overlay(
                        VStack {
                            HStack {
                                Spacer()
                                Button("Close") {
                                    showProblemManager = false
                                }
                                .buttonStyle(.bordered)
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
                DatabaseManager.shared.setSetting(key: "active_year", value: String(newValue))
                refreshSidebarModules()
            }
            .onChange(of: activeModuleId) { oldValue, newValue in
                if let val = newValue {
                    DatabaseManager.shared.setSetting(key: "active_module_id", value: String(val))
                } else {
                    DatabaseManager.shared.setSetting(key: "active_module_id", value: "")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                // Cleanly stop the background Ollama server when application exits
                PhysicsStudyApp.ollamaProcess?.terminate()
                
                let killProcess = Process()
                killProcess.launchPath = "/usr/bin/killall"
                killProcess.arguments = ["ollama"]
                try? killProcess.run()
            }
        }
        .commands {
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
    }
    
    // MARK: - Views routing
    
    @ViewBuilder
    private var detailView: some View {
        switch sidebarSelection {
        case "Dashboard":
            DashboardView(activeYear: activeYear)
        case "Study":
            StudyView(activeModuleId: activeModuleId)
        case "Flashcards":
            FlashcardsView(activeModuleId: activeModuleId, mode: .review, isExamMode: isExamMode)
        case "Problems":
            ProblemsView(activeModuleId: activeModuleId, mode: .review, isExamMode: isExamMode)
        case "Pre-Lecture":
            PreLectureView(activeModuleId: activeModuleId)
        case "Post-Lecture":
            PostLectureView(activeModuleId: activeModuleId)
        case "Notes & Topics":
            ModulesView(activeModuleId: activeModuleId)
        case "Add Flashcard":
            FlashcardsView(activeModuleId: activeModuleId, mode: .add, isExamMode: isExamMode)
        case "Add Problem":
            ProblemsView(activeModuleId: activeModuleId, mode: .add, isExamMode: isExamMode)
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
