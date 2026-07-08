import SwiftUI

struct FeynmanManagerView: View {
    @Binding var isPresented: Bool
    
    @State private var sessions: [FeynmanSession] = []
    @State private var selectedSessionId: Int? = nil
    @State private var searchQuery: String = ""
    @State private var selectedModuleIdFilter: Int? = nil // nil means "All Modules"
    @State private var modules: [Module] = []
    
    // Edit session sheet state
    @State private var editingSession: FeynmanSession? = nil
    @State private var showEditSheet: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Manage Feynman Sessions")
                    .font(.title)
                    .bold()
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
            }
            .padding()
            
            // Search and Filter controls
            HStack(spacing: 15) {
                TextField("Search concepts/explanations...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchQuery) { _ in
                        loadSessions()
                    }
                
                Picker("Module:", selection: $selectedModuleIdFilter) {
                    Text("All Modules").tag(nil as Int?)
                    ForEach(modules) { mod in
                        Text(mod.code).tag(mod.id as Int?)
                    }
                }
                .frame(width: 200)
                .onChange(of: selectedModuleIdFilter) { _ in
                    loadSessions()
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            
            // Sessions List Table
            if sessions.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)
                    Text("No Feynman sessions logged.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.2))
                .cornerRadius(12)
                .padding(.horizontal)
            } else {
                Table(sessions, selection: $selectedSessionId) {
                    TableColumn("Concept Title") { session in
                        Text(session.concept).bold()
                    }
                    TableColumn("Explanation Snippet") { session in
                        Text(session.explanation)
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                    TableColumn("Date Created") { session in
                        Text(session.createdDate)
                    }
                }
                .padding(.horizontal)
            }
            
            // Actions footer
            HStack(spacing: 12) {
                Button("View / Edit Session...") {
                    if let selId = selectedSessionId, let sel = sessions.first(where: { $0.id == selId }) {
                        editingSession = sel
                        showEditSheet = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSessionId == nil)
                
                Button("Delete Session", role: .destructive) {
                    deleteSelectedSession()
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .disabled(selectedSessionId == nil)
                
                Spacer()
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 450)
        .onAppear {
            loadModules()
            loadSessions()
        }
        .sheet(isPresented: $showEditSheet) {
            if let session = editingSession {
                FeynmanSessionEditView(isPresented: $showEditSheet, session: session, modules: modules) {
                    loadSessions()
                }
            }
        }
    }
    
    private func loadModules() {
        self.modules = DatabaseManager.shared.getModules()
    }
    
    private func loadSessions() {
        self.sessions = DatabaseManager.shared.getFeynmanSessions(
            moduleId: selectedModuleIdFilter,
            searchQuery: searchQuery
        )
    }
    
    private func deleteSelectedSession() {
        guard let selId = selectedSessionId else { return }
        
        let alert = NSAlert()
        alert.messageText = "Confirm Delete"
        alert.informativeText = "Are you sure you want to delete this Feynman session log?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            let success = DatabaseManager.shared.deleteFeynmanSession(id: selId)
            if success {
                selectedSessionId = nil
                loadSessions()
            }
        }
    }
}

struct FeynmanSessionEditView: View {
    @Binding var isPresented: Bool
    let session: FeynmanSession
    let modules: [Module]
    let onSave: () -> Void
    
    @State private var selectedModuleId: Int?
    @State private var concept: String = ""
    @State private var explanation: String = ""
    
    var body: some View {
        VStack(spacing: 15) {
            Text("Feynman Session Details")
                .font(.title2)
                .bold()
                .padding(.top)
            
            Form {
                Section {
                    Picker("Module Assignment:", selection: $selectedModuleId) {
                        Text("None / General").tag(nil as Int?)
                        ForEach(modules) { mod in
                            Text("\(mod.code) - \(mod.name)").tag(mod.id as Int?)
                        }
                    }
                    
                    TextField("Concept Title:", text: $concept)
                    
                    VStack(alignment: .leading) {
                        Text("Explanation / Teaching log:")
                            .font(.subheadline)
                            .bold()
                        TextEditor(text: $explanation)
                            .frame(height: 200)
                            .border(Color.secondary.opacity(0.2))
                    }
                }
            }
            .padding(.horizontal)
            
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Save Changes") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(concept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear {
            self.selectedModuleId = session.moduleId > 0 ? session.moduleId : nil
            self.concept = session.concept
            self.explanation = session.explanation
        }
    }
    
    private func saveChanges() {
        let success = DatabaseManager.shared.updateFeynmanSession(
            id: session.id,
            moduleId: selectedModuleId,
            concept: concept,
            explanation: explanation
        )
        if success {
            onSave()
            isPresented = false
        }
    }
}
