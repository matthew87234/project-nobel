import SwiftUI
import AppKit

struct ModulesView: View {
    let activeModuleId: Int?
    
    @State private var notes: [Note] = []
    @State private var draftNotes: [Note] = []
    @State private var editableTitles: [Int: String] = [:] // Map noteId -> title
    @State private var redoingNoteIds: Set<Int> = []
    
    private var isOrderChanged: Bool {
        return draftNotes.map(\.id) != notes.map(\.id)
    }
    
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
                .pointingHandCursor()
                .disabled(activeModuleId == nil)
                
                Button(action: {
                    linkNotesFolder()
                }) {
                    Label("Link Notes Folder", systemImage: "folder.badge.plus")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(activeModuleId == nil)
                
                if isOrderChanged {
                    Button(action: {
                        commitNewOrder()
                    }) {
                        Label("Save Order & Update Recaps", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .pointingHandCursor()
                    
                    Button(action: {
                        self.draftNotes = self.notes
                    }) {
                        Text("Reset Order")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
                
                Spacer()
            }
            .padding(.horizontal)
            
            // Scrollable List of Linked Notes
            ScrollView {
                VStack(spacing: 12) {
                    if draftNotes.isEmpty {
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
                        ForEach(draftNotes) { note in
                            noteItemRow(note)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .onChange(of: activeModuleId) { _, _ in
            loadNotes()
        }
        .onAppear {
            loadNotes()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NoteAnalysisCompleted"))) { _ in
            loadNotes()
        }
    }
    
    private func noteItemRow(_ note: Note) -> some View {
        let filename = URL(fileURLWithPath: note.filePath).lastPathComponent
        let titleBinding = Binding(
            get: { self.editableTitles[note.id] ?? note.title },
            set: { newValue in
                self.editableTitles[note.id] = newValue
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    _ = DatabaseManager.shared.updateNoteTitle(topicId: note.topicId, noteId: note.id, newTitle: trimmed)
                }
            }
        )
        let idx = draftNotes.firstIndex(where: { $0.id == note.id }) ?? 0
        let isFirst = idx == 0
        let isLast = idx == draftNotes.count - 1
        let isRedoing = redoingNoteIds.contains(note.id)
        
        return HStack(spacing: 10) {
            // Reorder Up / Down Controls
            VStack(spacing: 2) {
                Button(action: { moveNoteUp(note) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(isFirst)
                .opacity(isFirst ? 0.3 : 1.0)
                
                Button(action: { moveNoteDown(note) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .disabled(isLast)
                .opacity(isLast ? 0.3 : 1.0)
            }
            .frame(width: 14)
            
            // Lecture Index Badge
            Text("\(idx + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.15))
                .foregroundColor(.blue)
                .cornerRadius(5)
            
            // File Info
            Text(filename)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            
            // Title Editor Entry
            TextField("Lecture Title", text: titleBinding)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            
            // Redo AI Title Icon Button
            Button(action: {
                redoTitle(note: note)
            }) {
                if isRedoing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .pointingHandCursor()
            .disabled(isRedoing)
            .help("Redo AI Title")
            
            // Open PDF Button
            Button("Open PDF") {
                openPDF(path: note.filePath)
            }
            .buttonStyle(.bordered)
            .pointingHandCursor()
            
            // Delete Button
            Button(role: .destructive, action: {
                deleteNote(note)
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
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
            self.draftNotes = []
            self.editableTitles.removeAll()
            return
        }
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        self.draftNotes = self.notes
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
    
    private func redoTitle(note: Note) {
        redoingNoteIds.insert(note.id)
        Task {
            await AIHelper.shared.generateDescriptiveTitle(noteId: note.id)
            self.editableTitles.removeValue(forKey: note.id)
            loadNotes()
            redoingNoteIds.remove(note.id)
        }
    }
    
    private func moveNoteUp(_ note: Note) {
        guard let idx = draftNotes.firstIndex(where: { $0.id == note.id }), idx > 0 else { return }
        draftNotes.swapAt(idx, idx - 1)
    }
    
    private func moveNoteDown(_ note: Note) {
        guard let idx = draftNotes.firstIndex(where: { $0.id == note.id }), idx < draftNotes.count - 1 else { return }
        draftNotes.swapAt(idx, idx + 1)
    }
    
    private func commitNewOrder() {
        var affectedNoteIds = Set<Int>()
        
        for (draftIdx, note) in draftNotes.enumerated() {
            let prevDraftId = draftIdx > 0 ? draftNotes[draftIdx - 1].id : nil
            
            // Find note's original previous note ID
            let origIdx = notes.firstIndex(where: { $0.id == note.id })
            let prevOrigId: Int?
            if let oIdx = origIdx, oIdx > 0 {
                prevOrigId = notes[oIdx - 1].id
            } else {
                prevOrigId = nil
            }
            
            // If preceding note changed OR position changed
            if prevDraftId != prevOrigId || origIdx != draftIdx {
                affectedNoteIds.insert(note.id)
            }
        }
        
        // Clear pre-lecture primers for affected notes so AI regenerates "Last Lecture Recap"
        for noteId in affectedNoteIds {
            _ = DatabaseManager.shared.clearPreLecturePrimer(noteId: noteId)
        }
        
        // Save new order to SQLite
        if DatabaseManager.shared.updateNoteOrder(notesInOrder: draftNotes) {
            let updatedDraft = draftNotes
            self.notes = updatedDraft
            
            // Regenerate pre-lecture primers for affected notes in background
            Task {
                await AIHelper.shared.regeneratePreLecturePrimersForReorderedNotes(notesInOrder: updatedDraft, affectedNoteIds: affectedNoteIds)
                loadNotes()
            }
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
