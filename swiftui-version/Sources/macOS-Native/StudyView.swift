import SwiftUI
import AppKit

struct StudyView: View {
    let activeModuleId: Int?
    
    @State private var notes: [Note] = []
    @State private var selectedNote: Note?
    @State private var summaryText: String = ""
    @State private var isAnalyzing: Bool = false
    
    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Pane: List of Notes
            VStack(alignment: .leading, spacing: 10) {
                Text("Lectures & Notes")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top, 10)
                
                if notes.isEmpty {
                    VStack {
                        Spacer()
                        Text(activeModuleId == nil ? "Create a module first using Edit -> Manage Modules." : "No notes uploaded.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    List(notes, selection: $selectedNote) { note in
                        HStack {
                            Image(systemName: "doc.plaintext")
                            Text(note.title)
                                .lineLimit(1)
                        }
                        .tag(note)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(width: 250)
            
            Divider()
            
            // Right Pane: Summary & Details
            VStack {
                if let note = selectedNote {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text(note.title)
                                    .font(.title)
                                    .bold()
                                
                                Spacer()
                                
                                Button(action: {
                                    regenerateSummary()
                                }) {
                                    Label("Redo", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            
                            // AI Summary Card
                            VStack(alignment: .leading, spacing: 12) {
                                Text("AI SUMMARY")
                                    .font(.caption)
                                    .bold()
                                    .foregroundColor(.secondary)
                                
                                if isAnalyzing && summaryText.isEmpty {
                                    HStack {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Generating AI Summary...")
                                            .foregroundColor(.secondary)
                                    }
                                } else {
                                    Text(summaryText)
                                        .textSelection(.enabled)
                                        .lineSpacing(4)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(12)
                            
                            // Action Panel
                            HStack {
                                // View PDF Button
                                Button(action: {
                                    openFullscreenPDF(path: note.filePath)
                                }) {
                                    Label("View PDF", systemImage: "doc.viewfinder")
                                        .font(.headline)
                                        .frame(height: 35)
                                        .padding(.horizontal, 15)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                
                                Spacer()
                            }
                        }
                        .padding(25)
                    }
                } else {
                    VStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 10)
                        Text("Select a note to view summary")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: activeModuleId) { _ in
            loadNotes()
        }
        .onChange(of: selectedNote) { note in
            displayNoteDetails(note)
        }
        .onAppear {
            loadNotes()
        }
        .onReceive(timer) { _ in
            checkBackgroundProcessComplete()
        }
    }
    
    private func loadNotes() {
        guard let modId = activeModuleId else {
            self.notes = []
            self.selectedNote = nil
            return
        }
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        if let first = notes.first {
            self.selectedNote = first
        } else {
            self.selectedNote = nil
        }
    }
    
    private func displayNoteDetails(_ note: Note?) {
        guard let note = note else {
            self.summaryText = ""
            self.isAnalyzing = false
            return
        }
        
        if let summary = note.aiSummary, !summary.isEmpty {
            self.summaryText = summary
            self.isAnalyzing = false
        } else {
            self.summaryText = ""
            self.isAnalyzing = true
            
            // Trigger async analysis if Ollama is running and not already queued
            Task {
                await AIHelper.shared.ensureNoteSummarized(noteId: note.id)
                // Reload note data
                if let updated = DatabaseManager.shared.getNote(id: note.id) {
                    DispatchQueue.main.async {
                        if self.selectedNote?.id == note.id {
                            self.notes = DatabaseManager.shared.getNotes(forModuleId: self.activeModuleId ?? 0)
                            self.selectedNote = updated
                        }
                    }
                }
            }
        }
    }
    
    private func checkBackgroundProcessComplete() {
        guard let note = selectedNote else { return }
        if isAnalyzing {
            if let updated = DatabaseManager.shared.getNote(id: note.id) {
                if let summary = updated.aiSummary, !summary.isEmpty {
                    self.summaryText = summary
                    self.isAnalyzing = false
                    // refresh sidebar list cache
                    self.notes = DatabaseManager.shared.getNotes(forModuleId: self.activeModuleId ?? 0)
                }
            }
        }
    }
    
    private func regenerateSummary() {
        guard let note = selectedNote else { return }
        // Clear database cache
        _ = DatabaseManager.shared.updateNoteAI(noteId: note.id, summary: nil, primer: nil)
        
        // Fetch the fresh note from database (which now has nil summary) and reload
        if let freshNote = DatabaseManager.shared.getNote(id: note.id) {
            self.selectedNote = freshNote
            displayNoteDetails(freshNote)
        }
    }
    
    private func openFullscreenPDF(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }
}
