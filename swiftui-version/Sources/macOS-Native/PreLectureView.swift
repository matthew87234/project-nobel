import SwiftUI

struct PrimerSectionItem: Identifiable {
    let id = UUID()
    let title: String
    let content: String
}

struct PreLectureView: View {
    let activeModuleId: Int?
    
    @State private var notes: [Note] = []
    @State private var selectedNote: Note?
    @State private var primerText: String = ""
    @State private var parsedSections: [PrimerSectionItem] = []
    @State private var isGenerating: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Dropdown Selector Row
            HStack {
                Picker("Lecture Note:", selection: $selectedNote) {
                    if notes.isEmpty {
                        Text("No notes found").tag(nil as Note?)
                    } else {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                            Text("Week \(index + 1): \(note.title)").tag(note as Note?)
                        }
                    }
                }
                .frame(width: 300)
                
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Primer Detail Area
            ScrollView {
                if let note = selectedNote {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Pre-Lecture Prep Primer")
                            .font(.title2)
                            .bold()
                        
                        Text("Review this primer to build cognitive anchors before entering your lecture for: \(note.title)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if isGenerating && primerText.isEmpty {
                            VStack(spacing: 15) {
                                Spacer().frame(height: 50)
                                ProgressView()
                                Text("Qwen is generating pre-lecture primer...")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else if parsedSections.isEmpty && !primerText.isEmpty {
                            // Fallback raw display
                            Text(primerText)
                                .padding()
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(12)
                        } else if parsedSections.isEmpty {
                            VStack {
                                Spacer().frame(height: 50)
                                Text("No primer generated. Ensure note has summary and try again.")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            // Render parsed sections in cards
                            ForEach(parsedSections) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(section.title.uppercased())
                                        .font(.caption)
                                        .bold()
                                        .foregroundColor(sectionTitleColor(section.title))
                                    
                                    Text(section.content)
                                        .font(.body)
                                        .lineSpacing(4)
                                        .textSelection(.enabled)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(cardBackgroundColor(section.title))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(cardBorderColor(section.title), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(25)
                } else {
                    VStack {
                        Spacer().frame(height: 100)
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                            .padding(.bottom, 10)
                        Text(activeModuleId == nil ? "Please select or create an active module first." : "Upload a note in Notes & Topics to view primer.")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: activeModuleId) { _ in
            loadNotes()
        }
        .onChange(of: selectedNote) { note in
            loadPrimer(for: note)
        }
        .onAppear {
            loadNotes()
        }
    }
    
    private func loadNotes() {
        guard let modId = activeModuleId else {
            self.notes = []
            self.selectedNote = nil
            return
        }
        self.notes = DatabaseManager.shared.getNotes(forModuleId: modId)
        self.selectedNote = notes.first
    }
    
    private func loadPrimer(for note: Note?) {
        guard let note = note else {
            self.primerText = ""
            self.parsedSections = []
            self.isGenerating = false
            return
        }
        
        if let primer = note.preLecturePrimer, !primer.isEmpty {
            self.primerText = primer
            self.parsedSections = parsePrimerSections(primer)
            self.isGenerating = false
        } else {
            self.primerText = ""
            self.parsedSections = []
            self.isGenerating = true
            
            Task {
                // Find previous note index in notes list
                let idx = notes.firstIndex(where: { $0.id == note.id }) ?? 0
                let prevId = idx > 0 ? notes[idx - 1].id : nil
                
                let res = await AIHelper.shared.generatePreLecturePrimer(currentNoteId: note.id, prevNoteId: prevId)
                
                DispatchQueue.main.async {
                    if self.selectedNote?.id == note.id {
                        self.isGenerating = false
                        if let primer = res {
                            self.primerText = primer
                            self.parsedSections = parsePrimerSections(primer)
                        }
                    }
                }
            }
        }
    }
    
    private func parsePrimerSections(_ text: String) -> [PrimerSectionItem] {
        var items: [PrimerSectionItem] = []
        let pattern = "\\[([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        
        for i in 0..<matches.count {
            let match = matches[i]
            guard let titleRange = Range(match.range(at: 1), in: text) else { continue }
            let title = String(text[titleRange])
            
            let contentStart = match.range.location + match.range.length
            let contentEnd = i + 1 < matches.count ? matches[i+1].range.location : text.count
            
            guard contentEnd > contentStart else { continue }
            let contentNsRange = NSRange(location: contentStart, length: contentEnd - contentStart)
            guard let contentRange = Range(contentNsRange, in: text) else { continue }
            let content = String(text[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            
            items.append(PrimerSectionItem(title: title, content: content))
        }
        
        return items
    }
    
    private func sectionTitleColor(_ title: String) -> Color {
        let t = title.lowercased()
        if t.contains("last lecture") || t.contains("happened") {
            return .secondary
        } else if t.contains("links") {
            return .blue
        } else if t.contains("learn today") {
            return .green
        } else {
            return .orange
        }
    }
    
    private func cardBackgroundColor(_ title: String) -> Color {
        let t = title.lowercased()
        if t.contains("open questions") {
            return Color.orange.opacity(0.04)
        } else if t.contains("learn today") {
            return Color.green.opacity(0.04)
        } else if t.contains("links") {
            return Color.blue.opacity(0.04)
        } else {
            return Color(NSColor.controlBackgroundColor)
        }
    }
    
    private func cardBorderColor(_ title: String) -> Color {
        let t = title.lowercased()
        if t.contains("open questions") {
            return Color.orange.opacity(0.12)
        } else if t.contains("learn today") {
            return Color.green.opacity(0.12)
        } else if t.contains("links") {
            return Color.blue.opacity(0.12)
        } else {
            return Color.secondary.opacity(0.1)
        }
    }
}
