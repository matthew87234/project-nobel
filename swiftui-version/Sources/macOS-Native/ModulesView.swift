import SwiftUI
import AppKit

struct ModulesView: View {
    let activeModuleId: Int?
    
    @State private var notes: [Note] = []
    @State private var editableTitles: [Int: String] = [:] // Map noteId -> title
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Notes & Topics")
                .font(.system(size: 28, weight: .bold))
                .padding(.horizontal)
                .padding(.top, 20)
            
            HStack(spacing: 12) {
                Button(action: {
                    linkPDFNote()
                }) {
                    Label("Link PDF File(s)", systemImage: "doc.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeModuleId == nil)
                
                Button(action: {
                    linkNotesFolder()
                }) {
                    Label("Link Notes Folder", systemImage: "folder.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .disabled(activeModuleId == nil)
                
                Spacer()
            }
            .padding(.horizontal)
            
            // Scrollable List of Linked Notes
            ScrollView {
                VStack(spacing: 12) {
                    if notes.isEmpty {
                        VStack(spacing: 10) {
                            Spacer().frame(height: 50)
                            Image(systemName: "tray")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            Text(activeModuleId == nil ? "Select a module in the sidebar first." : "No notes linked. Click 'Link PDF File(s)' or 'Link Notes Folder' to add lectures.")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(notes) { note in
                            noteItemRow(note)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .onChange(of: activeModuleId) { _ in
            loadNotes()
        }
        .onAppear {
            loadNotes()
        }
    }
    
    private func noteItemRow(_ note: Note) -> some View {
        let filename = URL(fileURLWithPath: note.filePath).lastPathComponent
        let titleBinding = Binding(
            get: { self.editableTitles[note.id] ?? note.title },
            set: { self.editableTitles[note.id] = $0 }
        )
        
        return HStack(spacing: 15) {
            // File Info
            Text(filename)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            
            // Title Editor Entry
            TextField("Lecture Title", text: titleBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            
            // Save Title Button
            Button("Save Title") {
                saveTitle(note: note)
            }
            .buttonStyle(.bordered)
            
            // Open PDF Button
            Button("Open PDF") {
                openPDF(path: note.filePath)
            }
            .buttonStyle(.bordered)
            
            // Delete Button
            Button(role: .destructive, action: {
                deleteNote(note)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 5)
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - Helper Logic
    
    private func loadNotes() {
        guard let modId = activeModuleId else {
            self.notes = []
            self.editableTitles.removeAll()
            return
        }
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        for note in notes {
            self.editableTitles[note.id] = note.title
        }
    }
    
    private func linkPDFNote() {
        guard let modId = activeModuleId else { return }
        
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.pdf]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "Select PDF Notes"
        
        openPanel.begin { response in
            if response == .OK {
                for url in openPanel.urls {
                    let filePath = url.path
                    
                    // Avoid duplicate links for the same file in this module
                    if DatabaseManager.shared.noteExists(moduleId: modId, filePath: filePath) {
                        continue
                    }
                    
                    let title = url.deletingPathExtension().lastPathComponent
                    
                    let maxWeek = DatabaseManager.shared.getMaxWeek(forModuleId: modId)
                    let nextWeek = maxWeek + 1
                    
                    if let noteId = DatabaseManager.shared.addTopicAndNote(moduleId: modId, week: nextWeek, title: title, filePath: filePath) {
                        // Start background processing for AI summary
                        Task {
                            await AIHelper.shared.processNoteSync(noteId: noteId)
                        }
                    }
                }
                loadNotes()
            }
        }
    }
    
    private func linkNotesFolder() {
        guard let modId = activeModuleId else { return }
        
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Folder holding Notes"
        
        openPanel.begin { response in
            if response == .OK, let folderURL = openPanel.url {
                let fileManager = FileManager.default
                var pdfURLs: [URL] = []
                
                // Recursively find PDF files
                if let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        if fileURL.pathExtension.lowercased() == "pdf" {
                            pdfURLs.append(fileURL)
                        }
                    }
                }
                
                pdfURLs.sort { $0.path < $1.path }
                
                for url in pdfURLs {
                    let filePath = url.path
                    
                    // Avoid duplicate links for the same file in this module
                    if DatabaseManager.shared.noteExists(moduleId: modId, filePath: filePath) {
                        continue
                    }
                    
                    let title = url.deletingPathExtension().lastPathComponent
                    
                    let maxWeek = DatabaseManager.shared.getMaxWeek(forModuleId: modId)
                    let nextWeek = maxWeek + 1
                    
                    if let noteId = DatabaseManager.shared.addTopicAndNote(moduleId: modId, week: nextWeek, title: title, filePath: filePath) {
                        Task {
                            await AIHelper.shared.processNoteSync(noteId: noteId)
                        }
                    }
                }
                loadNotes()
            }
        }
    }
    
    private func saveTitle(note: Note) {
        let newTitle = (editableTitles[note.id] ?? note.title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else { return }
        
        let success = DatabaseManager.shared.updateNoteTitle(topicId: note.topicId, noteId: note.id, newTitle: newTitle)
        if success {
            loadNotes()
        }
    }
    
    private func openPDF(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
    
    private func deleteNote(_ note: Note) {
        let alert = NSAlert()
        alert.messageText = "Confirm Delete"
        alert.informativeText = "Are you sure you want to delete this lecture note? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            let success = DatabaseManager.shared.deleteNote(topicId: note.topicId, noteId: note.id)
            if success {
                loadNotes()
            }
        }
    }
}
