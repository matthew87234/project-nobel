import Foundation
import SwiftUI
import AppKit

@MainActor
public class AnkiSyncEngine: ObservableObject {
    public static let shared = AnkiSyncEngine()
    
    @Published public var isSyncing: Bool = false
    @Published public var lastSyncStatus: String = ""
    @Published public var lastSyncDate: Date? = nil
    
    private let url = URL(string: "http://127.0.0.1:8765")!
    
    private init() {}
    
    public func isAnkiConnectAvailable() async -> Bool {
        let payload: [String: Any] = ["action": "version", "version": 6]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 3.0
        
        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                   json["error"] is NSNull || json["error"] == nil {
                    return true
                }
            }
        } catch {
            return false
        }
        return false
    }
    
    public func syncWithAnki(completion: ((Bool, String) -> Void)? = nil) {
        Task {
            let isAvailable = await isAnkiConnectAvailable()
            guard isAvailable else {
                DispatchQueue.main.async {
                    self.lastSyncStatus = "Desktop Anki is not running or AnkiConnect addon (2055492159) is not enabled."
                    completion?(false, self.lastSyncStatus)
                }
                return
            }
            
            DispatchQueue.main.async {
                self.isSyncing = true
                self.lastSyncStatus = "Syncing decks with Anki & AnkiWeb..."
            }
            
            let (success, message) = await performSync()
            
            DispatchQueue.main.async {
                self.isSyncing = false
                self.lastSyncStatus = message
                if success {
                    self.lastSyncDate = Date()
                }
                completion?(success, message)
            }
        }
    }
    
    public func syncWithAnkiSynchronously() {
        Task {
            let isAvailable = await self.isAnkiConnectAvailable()
            if isAvailable {
                _ = await self.performSync()
            }
        }
    }
    
    private func performSync() async -> (Bool, String) {
        let allModules = DatabaseManager.shared.getModules()
        let allCards = DatabaseManager.shared.getFlashcards()
        
        var pushedCount = 0
        var updatedCount = 0
        
        let moduleDict = Dictionary(uniqueKeysWithValues: allModules.map { ($0.id, $0) })
        
        for card in allCards {
            let moduleYear: Int
            let moduleName: String
            let moduleCode: String
            
            if let module = moduleDict[card.moduleId] {
                moduleYear = module.year
                moduleName = module.name
                moduleCode = module.code
            } else {
                moduleYear = 1
                moduleName = "General Physics"
                moduleCode = "GEN"
            }
            
            // Hierarchical deck structure separated by academic year
            let deckName = "Project Nobel::Year \(moduleYear)::\(moduleCode) - \(moduleName)"
            
            // Ensure deck exists in Anki
            _ = await sendAnkiAction(action: "createDeck", params: ["deck": deckName])
            
            let tagFilter = "nobel_id_\(card.id)"
            let query = "deck:\"\(deckName)\" tag:\(tagFilter)"
            
            if let findRes = await sendAnkiAction(action: "findNotes", params: ["query": query]),
               let noteIds = findRes["result"] as? [Int64], !noteIds.isEmpty {
                // Update note fields if card changed
                let noteId = noteIds[0]
                let updateParams: [String: Any] = [
                    "note": [
                        "id": noteId,
                        "fields": [
                            "Front": card.front,
                            "Back": card.back
                        ]
                    ]
                ]
                _ = await sendAnkiAction(action: "updateNoteFields", params: updateParams)
                updatedCount += 1
            } else {
                // Add note to Anki
                let noteParams: [String: Any] = [
                    "note": [
                        "deckName": deckName,
                        "modelName": "Basic",
                        "fields": [
                            "Front": card.front,
                            "Back": card.back
                        ],
                        "options": [
                            "allowDuplicate": false,
                            "duplicateScope": "deck"
                        ],
                        "tags": ["project_nobel", tagFilter, "year_\(moduleYear)"]
                    ]
                ]
                _ = await sendAnkiAction(action: "addNote", params: noteParams)
                pushedCount += 1
            }
        }
        
        // 2. Pull review data back from Anki to physics_study.db
        if let allNobelNotes = await sendAnkiAction(action: "findNotes", params: ["query": "tag:project_nobel"]),
           let noteIds = allNobelNotes["result"] as? [Int64], !noteIds.isEmpty {
            
            if let notesInfoRes = await sendAnkiAction(action: "notesInfo", params: ["notes": noteIds]),
               let notesList = notesInfoRes["result"] as? [[String: Any]] {
                
                for noteInfo in notesList {
                    guard let tags = noteInfo["tags"] as? [String] else { continue }
                    guard let idTag = tags.first(where: { $0.hasPrefix("nobel_id_") }) else { continue }
                    let cardIdStr = idTag.replacingOccurrences(of: "nobel_id_", with: "")
                    guard let cardId = Int(cardIdStr) else { continue }
                    
                    if let cardsArr = noteInfo["cards"] as? [Int64], let firstAnkiCardId = cardsArr.first {
                        if let cardInfoRes = await sendAnkiAction(action: "cardsInfo", params: ["cards": [firstAnkiCardId]]),
                           let cardsInfo = cardInfoRes["result"] as? [[String: Any]],
                           let cInfo = cardsInfo.first {
                            
                            let interval = cInfo["interval"] as? Int ?? 1
                            let factor = cInfo["factor"] as? Int ?? 2500
                            let reps = cInfo["reps"] as? Int ?? 0
                            let easeFactor = Double(factor) / 1000.0
                            
                            let calendar = Calendar.current
                            let nextReviewDate = calendar.date(byAdding: .day, value: max(1, interval), to: Date())!
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd"
                            let nextReviewStr = formatter.string(from: nextReviewDate)
                            
                            _ = DatabaseManager.shared.updateFlashcardReview(
                                id: cardId,
                                interval: max(1, interval),
                                easeFactor: max(1.3, easeFactor),
                                repetitions: reps,
                                nextReviewDate: nextReviewStr
                            )
                        }
                    }
                }
            }
        }
        
        // 3. Trigger AnkiWeb cloud sync
        _ = await sendAnkiAction(action: "sync", params: [:])
        
        return (true, "Successfully synced \(allCards.count) flashcards separated into Year 1-4 decks to Anki & AnkiWeb!")
    }
    
    private func sendAnkiAction(action: String, params: [String: Any]) async -> [String: Any]? {
        let payload: [String: Any] = [
            "action": action,
            "version": 6,
            "params": params
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 10.0
        
        do {
            let (respData, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                return try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
            }
        } catch {
            return nil
        }
        return nil
    }
}
