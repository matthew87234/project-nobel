import SwiftUI

@MainActor
struct ModuleManagerView: View {
    @Binding var isPresented: Bool
    let onRefresh: () -> Void
    
    @State private var modules: [Module] = []
    @State private var yearFilter: String = "All Years"
    @State private var selectedModule: Module?
    
    // Add/Edit sheet states
    @State private var showEditSheet: Bool = false
    @State private var editingModule: Module? // nil means Add
    @State private var codeEntry: String = ""
    @State private var nameEntry: String = ""
    @State private var semesterEntry: Int = 1
    @State private var yearEntry: Int = 1
    @State private var hasTestDate: Bool = false
    @State private var testDateEntry: Date = Date()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("Manage Modules")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                Picker("Filter by Year:", selection: $yearFilter) {
                    Text("All Years").tag("All Years")
                    Text("Year 1").tag("Year 1")
                    Text("Year 2").tag("Year 2")
                    Text("Year 3").tag("Year 3")
                    Text("Year 4").tag("Year 4")
                }
                .frame(width: 200)
                .onChange(of: yearFilter) { _, _ in
                    loadModules()
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // List / Table of modules
            List(modules, selection: $selectedModule) { m in
                HStack {
                    Text(m.code)
                        .font(.system(.body, design: .monospaced))
                        .bold()
                        .frame(width: 90, alignment: .leading)
                    
                    Text(m.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Text("Sem \(m.semester)")
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .leading)
                    
                    Text("Yr \(m.year)")
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .leading)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.caption)
                            .foregroundColor(m.testDate.isEmpty ? .secondary.opacity(0.6) : .orange)
                        Text(m.testDateFormattedDateOnly)
                            .font(.caption)
                            .foregroundColor(m.testDate.isEmpty ? .secondary : .primary)
                    }
                    .frame(width: 120, alignment: .trailing)
                    .help(m.testDate.isEmpty ? "No Exam Set" : "\(m.testDateFormattedDateOnly) (\(m.daysRemainingFormatted))")
                }
                .tag(m)
            }
            .listStyle(.inset)
            .frame(minHeight: 250)
            
            Divider()
            
            // Actions Button bar
            HStack(spacing: 15) {
                // Add Module Button
                Button(action: {
                    openAddDialog()
                }) {
                    Label("Add Module...", systemImage: "plus")
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                
                // Edit Module Button
                Button(action: {
                    openEditDialog()
                }) {
                    Label("Edit Module...", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .disabled(selectedModule == nil)
                
                // Delete Module Button
                Button(role: .destructive, action: {
                    deleteSelectedModule()
                }) {
                    Label("Delete Module", systemImage: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)
                .disabled(selectedModule == nil)
                
                Spacer()
                
                Button("Close") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 680, height: 460)
        .onAppear {
            loadModules()
        }
        .sheet(isPresented: $showEditSheet) {
            editModuleSheet
        }
    }
    
    // MARK: - Add / Edit Sheet
    
    private var editModuleSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(editingModule == nil ? "Add New Module" : "Edit Module")
                .font(.headline)
            
            Form {
                TextField("Module Code:", text: $codeEntry)
                TextField("Module Name:", text: $nameEntry)
                
                Picker("Semester:", selection: $semesterEntry) {
                    Text("Semester 1").tag(1)
                    Text("Semester 2").tag(2)
                }
                
                Picker("Year:", selection: $yearEntry) {
                    Text("Year 1").tag(1)
                    Text("Year 2").tag(2)
                    Text("Year 3").tag(3)
                    Text("Year 4").tag(4)
                }
                
                Toggle("Set Exam Date & Time", isOn: $hasTestDate)
                
                if hasTestDate {
                    DatePicker("Exam Date & Time:", selection: $testDateEntry, displayedComponents: [.date, .hourAndMinute])
                }
            }
            .padding(.vertical, 10)
            
            HStack {
                Button("Cancel") {
                    showEditSheet = false
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save Module") {
                    saveModule()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(codeEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420, height: hasTestDate ? 320 : 280)
    }
    
    // MARK: - Logic functions
    
    private func loadModules() {
        let yearVal: Int?
        if yearFilter == "All Years" {
            yearVal = nil
        } else {
            yearVal = Int(yearFilter.components(separatedBy: " ")[1])
        }
        self.modules = DatabaseManager.shared.getModules(forYear: yearVal)
        self.selectedModule = nil
    }
    
    private func openAddDialog() {
        editingModule = nil
        codeEntry = ""
        nameEntry = ""
        semesterEntry = 1
        hasTestDate = false
        testDateEntry = Date()
        
        if yearFilter != "All Years", let year = Int(yearFilter.components(separatedBy: " ")[1]) {
            yearEntry = year
        } else {
            yearEntry = 1
        }
        showEditSheet = true
    }
    
    private func openEditDialog() {
        guard let m = selectedModule else { return }
        editingModule = m
        codeEntry = m.code
        nameEntry = m.name
        semesterEntry = m.semester
        yearEntry = m.year
        
        if !m.testDate.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            if let date = formatter.date(from: m.testDate) {
                testDateEntry = date
                hasTestDate = true
            } else {
                testDateEntry = Date()
                hasTestDate = false
            }
        } else {
            testDateEntry = Date()
            hasTestDate = false
        }
        
        showEditSheet = true
    }
    
    private func saveModule() {
        let code = codeEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty && !name.isEmpty else { return }
        
        let testDateStr: String
        if hasTestDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            testDateStr = formatter.string(from: testDateEntry)
        } else {
            testDateStr = ""
        }
        
        let success: Bool
        if let editing = editingModule {
            success = DatabaseManager.shared.updateModule(id: editing.id, code: code, name: name, semester: semesterEntry, year: yearEntry, testDate: testDateStr)
        } else {
            success = DatabaseManager.shared.addModule(code: code, name: name, semester: semesterEntry, year: yearEntry, testDate: testDateStr)
        }
        
        if success {
            showEditSheet = false
            loadModules()
            onRefresh()
        } else {
            // Show duplicate code warning alert
            let alert = NSAlert()
            alert.messageText = "Duplicate Code"
            alert.informativeText = "A module with code '\(code)' already exists."
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
    
    private func deleteSelectedModule() {
        guard let m = selectedModule else { return }
        
        let alert = NSAlert()
        alert.messageText = "Confirm Delete"
        alert.informativeText = "Deleting this module will delete all its topics, notes, flashcards, problems, study logs, and feynman chats. This action cannot be undone.\n\nAre you sure you want to delete it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            let success = DatabaseManager.shared.deleteModule(id: m.id)
            if success {
                loadModules()
                onRefresh()
            }
        }
    }
}
