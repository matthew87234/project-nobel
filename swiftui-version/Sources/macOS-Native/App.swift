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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
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
        if CommandLine.arguments.contains("--test") || CommandLine.arguments.contains("--run-tests") {
            TestRunner.runTests()
            exit(0)
        }
        
        if UserDefaults.standard.object(forKey: "background_ai_enabled") == nil {
            UserDefaults.standard.set(true, forKey: "background_ai_enabled")
        }
        
        // Only launch Ollama serve if using local provider.
        PhysicsStudyApp.startOllamaServer()
        
        // Start AI Background Processor sequentially
        AIHelper.shared.startBackgroundProcessor()
    }
    
    var body: some Scene {
        WindowGroup {
            mainView
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
    private var testProgramBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 7, height: 7)
            
            Text("TEST PROGRAM")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .foregroundColor(.orange)
            
            Text("•")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary.opacity(0.6))
            
            Text("Desktop Sandbox Environment (physics_study_desktop.db)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            Color(NSColor.windowBackgroundColor)
                .overlay(Color.orange.opacity(0.08))
        )
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.orange.opacity(0.25)),
            alignment: .bottom
        )
    }
    
    @ViewBuilder
    private var aiStatusView: some View {
        if aiHelper.isAIDisconnected {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if aiHelper.isAutoReconnecting || aiHelper.isRetryingConnection {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.blue)
                    }
                    
                    Text(aiHelper.disconnectionMessage.isEmpty ? "Tailscale Disconnected" : aiHelper.disconnectionMessage)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.blue)
                    
                    Spacer()
                }
                
                HStack(spacing: 6) {
                    Text(aiHelper.isAutoReconnecting ? "Auto-reconnecting..." : "AI server unreachable.")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if (UserDefaults.standard.string(forKey: "ai_provider") ?? "local") != "local" {
                        Button(action: {
                            UserDefaults.standard.set("local", forKey: "ai_provider")
                            UserDefaults.standard.set("local", forKey: "vision_provider")
                            aiHelper.retryConnectionAndQueue()
                        }) {
                            Text("Use Local AI")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundColor(.primary)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Switch to local Ollama on this Mac")
                    }
                    
                    Button(action: {
                        aiHelper.retryConnectionAndQueue()
                    }) {
                        HStack(spacing: 4) {
                            if aiHelper.isRetryingConnection || aiHelper.isAutoReconnecting {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            Text((aiHelper.isRetryingConnection || aiHelper.isAutoReconnecting) ? "Checking..." : "Reconnect Now")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(aiHelper.isRetryingConnection || aiHelper.isAutoReconnecting)
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
        } else if aiHelper.isPipelineActive || (aiHelper.isAIBusy && !aiHelper.currentAITaskDescription.isEmpty) || aiHelper.isClassifyingProblems || (aiHelper.isProcessing && aiHelper.activeJobDescription != "Idle" && aiHelper.activeJobDescription != "Background AI Disabled" && aiHelper.activeJobDescription != "Power Saving Mode" && aiHelper.activeJobDescription != "AI Server Offline") || !aiHelper.activeProcessingNoteIds.isEmpty {
            // Active Sequential Pipeline Status Card
            VStack(alignment: .leading, spacing: 7) {
                // Header: Phase badge & overall remaining count
                HStack(spacing: 5) {
                    Circle()
                        .fill(aiHelper.isLocalActive ? Color.green : (aiHelper.isRemoteActive ? Color.blue : Color.secondary))
                        .frame(width: 7, height: 7)
                    
                    Text(aiHelper.pipelineCurrentPhase.isEmpty || aiHelper.pipelineCurrentPhase == "Idle" ? "AI PIPELINE" : aiHelper.pipelineCurrentPhase.uppercased())
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // High-level summary of remaining items required before completion
                    if aiHelper.localPagesTotal > 0 || aiHelper.remoteProblemsTotal > 0 {
                        let localRem = aiHelper.localPagesRemaining
                        let remoteRem = aiHelper.remoteProblemsRemaining
                        if localRem > 0 && remoteRem > 0 {
                            Text("\(localRem) pgs + \(remoteRem) probs left")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                        } else if localRem > 0 {
                            Text("\(localRem) pgs left")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.green)
                        } else if remoteRem > 0 {
                            Text("\(remoteRem) probs left")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.blue)
                        } else {
                            Text("Finishing")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Divider()
                    .opacity(0.35)
                
                // Machine 1: Local Engine
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(aiHelper.isLocalActive ? .green : .secondary)
                        
                        Text("Local Engine")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(aiHelper.isLocalActive ? .primary : .secondary)
                        
                        if aiHelper.isLocalActive {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        
                        Spacer()
                        
                        // Local Active Status Badge
                        HStack(spacing: 3) {
                            Circle()
                                .fill(aiHelper.isLocalActive ? Color.green : Color.secondary.opacity(0.6))
                                .frame(width: 6, height: 6)
                            Text(aiHelper.isLocalActive ? "Active" : "Ready")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((aiHelper.isLocalActive ? Color.green : Color.secondary).opacity(0.14))
                        .foregroundColor(aiHelper.isLocalActive ? .green : .secondary)
                        .cornerRadius(4)
                    }
                    
                    // Local Progress info
                    HStack(spacing: 4) {
                        if aiHelper.localPagesTotal > 0 {
                            if aiHelper.localPagesRemaining > 0 {
                                Text("\(aiHelper.localPagesCompleted) of \(aiHelper.localPagesTotal) pages")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(aiHelper.localPagesRemaining) left")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.green)
                                Text("Done (\(aiHelper.localPagesTotal) pages OCR'd)")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        } else {
                            Text(aiHelper.isLocalActive ? aiHelper.localTaskStatus : "Standby")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(aiHelper.isLocalActive ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
                .padding(5)
                .background((aiHelper.isLocalActive ? Color.green.opacity(0.08) : Color.clear))
                .cornerRadius(6)
                
                Divider()
                    .opacity(0.35)
                
                // Machine 2: Remote Engine
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(aiHelper.isRemoteOnline ? (aiHelper.isRemoteActive ? .blue : .secondary) : .orange)
                        
                        Text("Remote Engine")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(aiHelper.isRemoteOnline ? (aiHelper.isRemoteActive ? .primary : .secondary) : .secondary)
                        
                        if aiHelper.isRemoteActive && aiHelper.isRemoteOnline {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        
                        Spacer()
                        
                        // Remote Active Status or Offline Badge
                        if !aiHelper.isRemoteOnline {
                            HStack(spacing: 3) {
                                Image(systemName: "wifi.slash")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Offline")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                        } else {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(aiHelper.isRemoteActive ? Color.blue : Color.secondary.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                Text(aiHelper.isRemoteActive ? "Active" : "Ready")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background((aiHelper.isRemoteActive ? Color.blue : Color.secondary).opacity(0.14))
                            .foregroundColor(aiHelper.isRemoteActive ? .blue : .secondary)
                            .cornerRadius(4)
                        }
                    }
                    
                    // Remote Progress info
                    HStack(spacing: 4) {
                        if !aiHelper.isRemoteOnline {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.orange)
                            Text("Not Connected (\(aiHelper.activeAIProvider.name) unreachable)")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.orange)
                                .lineLimit(1)
                            Spacer()
                        } else if aiHelper.remoteProblemsTotal > 0 {
                            if aiHelper.remoteProblemsRemaining > 0 {
                                Text("\(aiHelper.remoteProblemsCompleted) of \(aiHelper.remoteProblemsTotal) problems")
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(aiHelper.remoteProblemsRemaining) left")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(.secondary)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.blue)
                                Text("Done (\(aiHelper.remoteProblemsTotal) problems)")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        } else if aiHelper.localPagesRemaining > 0 {
                            Text("Queued (waiting for OCR)")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                        } else {
                            Text(aiHelper.isRemoteActive ? aiHelper.remoteTaskStatus : "Standby")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(aiHelper.isRemoteActive ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
                .padding(5)
                .background((aiHelper.isRemoteActive ? Color.blue.opacity(0.08) : (!aiHelper.isRemoteOnline ? Color.orange.opacity(0.06) : Color.clear)))
                .cornerRadius(6)
            }
            .padding(9)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.92))
            .cornerRadius(9)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(aiHelper.isLocalActive ? Color.green.opacity(0.4) : (aiHelper.isRemoteActive ? Color.blue.opacity(0.4) : Color.secondary.opacity(0.2)), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: aiHelper.isLocalActive || aiHelper.isRemoteActive || aiHelper.isPipelineActive)
        } else {
            // Idle Standby Status Strip (compact, unobtrusive)
            HStack(spacing: 8) {
                // Local Engine Status
                HStack(spacing: 4) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 9))
                        .foregroundColor(aiHelper.isLocalActive ? .green : .secondary)
                    Circle()
                        .fill(aiHelper.isLocalActive ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(aiHelper.isLocalActive ? "Local Active" : "Local Ready")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(aiHelper.isLocalActive ? .green : .secondary)
                }
                .help("Local Engine status: \(aiHelper.isLocalActive ? "Active" : "Ready")")
                
                Text("•")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary.opacity(0.4))
                
                // Remote Engine Status
                HStack(spacing: 4) {
                    if aiHelper.isRemoteOnline {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9))
                            .foregroundColor(aiHelper.isRemoteActive ? .blue : .secondary)
                        Circle()
                            .fill(aiHelper.isRemoteActive ? Color.blue : Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(aiHelper.isRemoteActive ? "Remote Active" : "Remote Ready")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(aiHelper.isRemoteActive ? .blue : .secondary)
                    } else {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text("Remote Offline")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                }
                .help(aiHelper.isRemoteOnline ? "Remote Engine is connected (\(aiHelper.activeAIProvider.name))" : "Remote Engine is not connected")
                
                Spacer()
                
                if !aiHelper.isRemoteOnline {
                    HStack(spacing: 3) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 8))
                        Text("Remote Offline")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.orange)
                    .help("Remote Engine is not reachable")
                } else if aiHelper.isLocalActive || aiHelper.isRemoteActive {
                    HStack(spacing: 3) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Active")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor)
                    }
                } else {
                    Text("Idle")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(aiHelper.isRemoteOnline ? Color.clear : Color.orange.opacity(0.25), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
    
    @ViewBuilder
    private var modulePicker: some View {
        if !modules.isEmpty {
            Picker("Module", selection: $activeModuleId) {
                ForEach(modules) { mod in
                    let label = "\(mod.code): \(mod.name)"
                    Text(label).tag(Optional(mod.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder
    private var flashcardManagerSheet: some View {
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
    
    @ViewBuilder
    private var problemManagerSheet: some View {
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

    @ViewBuilder
    private var mainView: some View {
        VStack(spacing: 0) {
            if DatabaseManager.isDesktopApp {
                testProgramBanner
            }
            
            NavigationSplitView {
                sidebarView
            } detail: {
                detailView
            }
            .navigationSplitViewStyle(.balanced)
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                examDateBadge
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                modulePicker
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
            flashcardManagerSheet
        }
        .sheet(isPresented: $showProblemManager) {
            problemManagerSheet
        }
        .sheet(isPresented: $aiHelper.showTailscaleSetupModal) {
            AIDevicePickerView()
        }
        .onAppear {
            restoreSettings()
            let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
            let tailHost = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
            if provider == "tailscale" && tailHost.isEmpty {
                aiHelper.showTailscaleSetupModal = true
            }
        }
        .onChange(of: activeYear) { _, newValue in
            handleActiveYearChanged(to: newValue)
        }
        .onChange(of: activeModuleId) { _, newValue in
            handleActiveModuleChanged(to: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            AnkiSyncEngine.shared.syncWithAnkiSynchronously()
            PhysicsStudyApp.stopOllamaServer()
        }
    }
    
    private func handleActiveYearChanged(to year: Int) {
        Task {
            DatabaseManager.shared.setSetting(key: "active_year", value: String(year))
        }
        refreshSidebarModules()
    }
    
    private func handleActiveModuleChanged(to moduleId: Int?) {
        Task {
            let valStr = moduleId.map { String($0) } ?? ""
            DatabaseManager.shared.setSetting(key: "active_module_id", value: valStr)
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                sidebarSelection = "Dashboard"
            }) {
                Text("Project Nobel")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .focusable(false)
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
    }
    
    @ViewBuilder
    private var examDateBadge: some View {
        if let activeMod = modules.first(where: { $0.id == activeModuleId }), !activeMod.testDate.isEmpty {
            let helpText = activeMod.daysRemainingFormatted.isEmpty ? "Exam Date for \(activeMod.code): \(activeMod.testDateFormattedDateOnly)" : "Exam Date for \(activeMod.code): \(activeMod.daysRemainingFormatted) (\(activeMod.testDateFormattedDateOnly))"
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
            .help(helpText)
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
        .focusable(false)
        .pointingHandCursor()
        .onHover { hover in
            isHovered = hover
        }
    }
}

