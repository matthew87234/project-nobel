import Foundation
import SQLite3

internal let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

struct Module: Identifiable, Hashable {
    var id: Int
    var code: String
    var name: String
    var semester: Int
    var year: Int
}

struct Topic: Identifiable, Hashable {
    var id: Int
    var moduleId: Int
    var week: Int
    var name: String
}

struct Note: Identifiable, Hashable {
    var id: Int
    var topicId: Int
    var filePath: String
    var title: String
    var aiSummary: String?
    var preLecturePrimer: String?
}

struct Flashcard: Identifiable, Hashable {
    var id: Int
    var moduleId: Int
    var front: String
    var back: String
    var nextReviewDate: String
    var interval: Int
    var easeFactor: Double
    var repetitions: Int
    var createdDate: String
}

struct Problem: Identifiable, Hashable {
    var id: Int
    var topicId: Int
    var content: String
    var solutionHint: String
    var createdDate: String
    var solvedCount: Int
    var solution: String
    var steps: String
}

struct FeynmanSession: Identifiable, Hashable {
    var id: Int
    var moduleId: Int
    var concept: String
    var explanation: String
    var createdDate: String
}

struct FeynmanChat: Identifiable, Hashable {
    var id: Int
    var noteId: Int
    var role: String
    var content: String
    var timestamp: String
}

@MainActor class DatabaseManager {
    static let shared = DatabaseManager()
    
    private var db: OpaquePointer?
    
    private init() {
        setupDatabase()
    }
    

    
    func setupDatabase() {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let appSupportDir = homeDirectory.appendingPathComponent(".physics_study_app")
        
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        
        let dbURL = appSupportDir.appendingPathComponent("physics_study.db")
        
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("Error opening database")
            return
        }
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS modules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                code TEXT UNIQUE,
                name TEXT,
                semester INTEGER,
                year INTEGER DEFAULT 1
            );
        """)
        alterTableAddColumn(table: "modules", column: "year", type: "INTEGER DEFAULT 1")
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS topics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                module_id INTEGER,
                week INTEGER,
                name TEXT,
                FOREIGN KEY (module_id) REFERENCES modules(id)
            );
        """)
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                topic_id INTEGER,
                file_path TEXT,
                title TEXT,
                ai_summary TEXT,
                pre_lecture_primer TEXT,
                FOREIGN KEY (topic_id) REFERENCES topics(id)
            );
        """)
        alterTableAddColumn(table: "notes", column: "ai_summary", type: "TEXT")
        alterTableAddColumn(table: "notes", column: "pre_lecture_primer", type: "TEXT")
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS flashcards (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                module_id INTEGER,
                front TEXT,
                back TEXT,
                next_review_date TEXT,
                interval INTEGER DEFAULT 0,
                ease_factor REAL DEFAULT 2.5,
                repetitions INTEGER DEFAULT 0,
                created_date TEXT,
                FOREIGN KEY (module_id) REFERENCES modules(id)
            );
        """)
        alterTableAddColumn(table: "flashcards", column: "created_date", type: "TEXT")
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS problems (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                topic_id INTEGER,
                content TEXT,
                solution_hint TEXT,
                created_date TEXT,
                solved_count INTEGER DEFAULT 0,
                solution TEXT,
                steps TEXT,
                FOREIGN KEY (topic_id) REFERENCES topics(id)
            );
        """)
        alterTableAddColumn(table: "problems", column: "created_date", type: "TEXT")
        alterTableAddColumn(table: "problems", column: "solved_count", type: "INTEGER DEFAULT 0")
        alterTableAddColumn(table: "problems", column: "solution", type: "TEXT")
        alterTableAddColumn(table: "problems", column: "steps", type: "TEXT")
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS feynman_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                module_id INTEGER,
                concept TEXT,
                explanation TEXT,
                created_date TEXT,
                FOREIGN KEY (module_id) REFERENCES modules(id)
            );
        """)
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS activity_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                activity_type TEXT,
                timestamp TEXT
            );
        """)
        alterTableAddColumn(table: "activity_log", column: "module_id", type: "INTEGER")
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS daily_study_time (
                date TEXT PRIMARY KEY,
                flashcards_seconds INTEGER DEFAULT 0,
                problems_seconds INTEGER DEFAULT 0
            );
        """)
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS module_study_time (
                module_id INTEGER,
                date TEXT,
                flashcards_seconds INTEGER DEFAULT 0,
                problems_seconds INTEGER DEFAULT 0,
                PRIMARY KEY (module_id, date),
                FOREIGN KEY (module_id) REFERENCES modules(id)
            );
        """)
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS feynman_chats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                note_id INTEGER,
                role TEXT,
                content TEXT,
                timestamp TEXT,
                FOREIGN KEY (note_id) REFERENCES notes(id)
            );
        """)
        
        execute(sql: """
            CREATE TABLE IF NOT EXISTS app_settings (
                key TEXT PRIMARY KEY,
                value TEXT
            );
        """)
    }
    
    func getSetting(key: String, defaultValue: String? = nil) -> String? {
        let sql = "SELECT value FROM app_settings WHERE key = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                if let valPointer = sqlite3_column_text(statement, 0) {
                    let value = String(cString: valPointer)
                    sqlite3_finalize(statement)
                    return value
                }
            }
        }
        sqlite3_finalize(statement)
        return defaultValue
    }
    
    func setSetting(key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                print("Error setting setting")
            }
        }
        sqlite3_finalize(statement)
    }
    
    @discardableResult
    func execute(sql: String, params: [Any] = []) -> Bool {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error preparing statement: \(errmsg)")
            return false
        }
        
        bindParams(statement: statement, params: params)
        
        if sqlite3_step(statement) != SQLITE_DONE {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("failure executing: \(errmsg)")
            sqlite3_finalize(statement)
            return false
        }
        
        sqlite3_finalize(statement)
        return true
    }
    
    func query(sql: String, params: [Any] = []) -> [[String: Any]] {
        var statement: OpaquePointer?
        var result: [[String: Any]] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db)!)
            print("error preparing query: \(errmsg)")
            return []
        }
        
        bindParams(statement: statement, params: params)
        
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let columnCount = sqlite3_column_count(statement)
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, i))
                let type = sqlite3_column_type(statement, i)
                switch type {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int(statement, i))
                case SQLITE_FLOAT:
                    row[name] = Double(sqlite3_column_double(statement, i))
                case SQLITE_TEXT:
                    if let textBytes = sqlite3_column_text(statement, i) {
                        row[name] = String(cString: textBytes)
                    } else {
                        row[name] = ""
                    }
                case SQLITE_NULL:
                    row[name] = nil
                default:
                    if let textBytes = sqlite3_column_text(statement, i) {
                        row[name] = String(cString: textBytes)
                    } else {
                        row[name] = nil
                    }
                }
            }
            result.append(row)
        }
        
        sqlite3_finalize(statement)
        return result
    }
    
    private func bindParams(statement: OpaquePointer?, params: [Any]) {
        for (index, val) in params.enumerated() {
            let bindIdx = Int32(index + 1)
            
            // Check for nil if the value is optional
            let mirror = Mirror(reflecting: val)
            if mirror.displayStyle == .optional {
                if mirror.children.count == 0 {
                    sqlite3_bind_null(statement, bindIdx)
                    continue
                }
            }
            
            // Unpack optional if it is present
            var unwrappedVal = val
            if mirror.displayStyle == .optional, let firstChild = mirror.children.first {
                unwrappedVal = firstChild.value
            }
            
            if let intVal = unwrappedVal as? Int {
                sqlite3_bind_int(statement, bindIdx, Int32(intVal))
            } else if let doubleVal = unwrappedVal as? Double {
                sqlite3_bind_double(statement, bindIdx, doubleVal)
            } else if let stringVal = unwrappedVal as? String {
                sqlite3_bind_text(statement, bindIdx, stringVal, -1, SQLITE_TRANSIENT)
            } else if let boolVal = unwrappedVal as? Bool {
                sqlite3_bind_int(statement, bindIdx, boolVal ? 1 : 0)
            } else {
                sqlite3_bind_text(statement, bindIdx, "\(unwrappedVal)", -1, SQLITE_TRANSIENT)
            }
        }
    }
    
    private func alterTableAddColumn(table: String, column: String, type: String) {
        let checkSQL = "PRAGMA table_info(\(table));"
        let columns = query(sql: checkSQL)
        let exists = columns.contains { row in
            if let name = row["name"] as? String {
                return name == column
            }
            return false
        }
        if !exists {
            execute(sql: "ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
        }
    }
    
    var lastInsertRowId: Int64 {
        return sqlite3_last_insert_rowid(db)
    }
    
    // MARK: - Modules queries
    
    func getModules(forYear year: Int? = nil) -> [Module] {
        let sql: String
        let params: [Any]
        if let year = year {
            sql = "SELECT id, code, name, semester, year FROM modules WHERE year = ? ORDER BY code ASC"
            params = [year]
        } else {
            sql = "SELECT id, code, name, semester, year FROM modules ORDER BY year ASC, code ASC"
            params = []
        }
        
        let rows = query(sql: sql, params: params)
        return rows.map { row in
            Module(
                id: row["id"] as? Int ?? 0,
                code: row["code"] as? String ?? "",
                name: row["name"] as? String ?? "",
                semester: row["semester"] as? Int ?? 1,
                year: row["year"] as? Int ?? 1
            )
        }
    }
    
    func addModule(code: String, name: String, semester: Int, year: Int) -> Bool {
        return execute(
            sql: "INSERT INTO modules (code, name, semester, year) VALUES (?, ?, ?, ?)",
            params: [code, name, semester, year]
        )
    }
    
    func updateModule(id: Int, code: String, name: String, semester: Int, year: Int) -> Bool {
        return execute(
            sql: "UPDATE modules SET code = ?, name = ?, semester = ?, year = ? WHERE id = ?",
            params: [code, name, semester, year, id]
        )
    }
    
    func deleteModule(id: Int) -> Bool {
        // Cascade delete manual transactions
        execute(sql: "DELETE FROM flashcards WHERE module_id = ?", params: [id])
        execute(sql: """
            DELETE FROM feynman_chats 
            WHERE note_id IN (
                SELECT n.id FROM notes n
                JOIN topics t ON n.topic_id = t.id
                WHERE t.module_id = ?
            )
        """, params: [id])
        execute(sql: """
            DELETE FROM notes 
            WHERE topic_id IN (
                SELECT id FROM topics WHERE module_id = ?
            )
        """, params: [id])
        execute(sql: "DELETE FROM topics WHERE module_id = ?", params: [id])
        execute(sql: "DELETE FROM feynman_sessions WHERE module_id = ?", params: [id])
        execute(sql: "DELETE FROM module_study_time WHERE module_id = ?", params: [id])
        return execute(sql: "DELETE FROM modules WHERE id = ?", params: [id])
    }
    
    // MARK: - Topics & Notes queries
    
    func getNotes(forModuleId moduleId: Int) -> [Note] {
        let sql = """
            SELECT n.id, n.topic_id, n.file_path, n.title, n.ai_summary, n.pre_lecture_primer
            FROM notes n
            JOIN topics t ON n.topic_id = t.id
            WHERE t.module_id = ?
            ORDER BY t.week ASC, t.id ASC
        """
        let rows = query(sql: sql, params: [moduleId])
        return rows.map { row in
            Note(
                id: row["id"] as? Int ?? 0,
                topicId: row["topic_id"] as? Int ?? 0,
                filePath: row["file_path"] as? String ?? "",
                title: row["title"] as? String ?? "",
                aiSummary: row["ai_summary"] as? String,
                preLecturePrimer: row["pre_lecture_primer"] as? String
            )
        }
    }
    
    func getTopics(forModuleId moduleId: Int) -> [Topic] {
        let sql = """
            SELECT id, module_id, week, name
            FROM topics
            WHERE module_id = ?
            ORDER BY week ASC, id ASC
        """
        let rows = query(sql: sql, params: [moduleId])
        return rows.map { row in
            Topic(
                id: row["id"] as? Int ?? 0,
                moduleId: row["module_id"] as? Int ?? 0,
                week: row["week"] as? Int ?? 0,
                name: row["name"] as? String ?? ""
            )
        }
    }
    
    func noteExists(moduleId: Int, filePath: String) -> Bool {
        let sql = """
            SELECT n.id FROM notes n
            JOIN topics t ON n.topic_id = t.id
            WHERE t.module_id = ? AND n.file_path = ?;
        """
        var statement: OpaquePointer?
        var exists = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(moduleId))
            sqlite3_bind_text(statement, 2, filePath, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                exists = true
            }
        }
        sqlite3_finalize(statement)
        return exists
    }
    
    func addTopicAndNote(moduleId: Int, week: Int, title: String, filePath: String) -> Int? {
        // Create topic
        let tSuccess = execute(
            sql: "INSERT INTO topics (module_id, week, name) VALUES (?, ?, ?)",
            params: [moduleId, week, title]
        )
        guard tSuccess else { return nil }
        let topicId = Int(lastInsertRowId)
        
        // Create note
        let nSuccess = execute(
            sql: "INSERT INTO notes (topic_id, file_path, title) VALUES (?, ?, ?)",
            params: [topicId, filePath, title]
        )
        guard nSuccess else { return nil }
        return Int(lastInsertRowId)
    }
    
    func getOrCreateTopic(moduleId: Int, week: Int, name: String) -> Int? {
        let results = query(
            sql: "SELECT id FROM topics WHERE module_id = ? AND week = ? LIMIT 1",
            params: [moduleId, week]
        )
        if let first = results.first, let id = first["id"] as? Int {
            return id
        }
        
        let success = execute(
            sql: "INSERT INTO topics (module_id, week, name) VALUES (?, ?, ?)",
            params: [moduleId, week, name]
        )
        if success {
            return Int(lastInsertRowId)
        }
        return nil
    }
    
    func updateNoteTitle(topicId: Int, noteId: Int, newTitle: String) -> Bool {
        let tSuccess = execute(sql: "UPDATE topics SET name = ? WHERE id = ?", params: [newTitle, topicId])
        let nSuccess = execute(sql: "UPDATE notes SET title = ? WHERE id = ?", params: [newTitle, noteId])
        return tSuccess && nSuccess
    }
    
    func deleteNote(topicId: Int, noteId: Int) -> Bool {
        execute(sql: "DELETE FROM feynman_chats WHERE note_id = ?", params: [noteId])
        let nSuccess = execute(sql: "DELETE FROM notes WHERE id = ?", params: [noteId])
        let tSuccess = execute(sql: "DELETE FROM topics WHERE id = ?", params: [topicId])
        return nSuccess && tSuccess
    }
    
    func updateNoteAI(noteId: Int, summary: String?, primer: String?) -> Bool {
        return execute(
            sql: "UPDATE notes SET ai_summary = ?, pre_lecture_primer = ? WHERE id = ?",
            params: [summary as Any, primer as Any, noteId]
        )
    }
    
    func getNote(id: Int) -> Note? {
        let rows = query(sql: "SELECT id, topic_id, file_path, title, ai_summary, pre_lecture_primer FROM notes WHERE id = ?", params: [id])
        guard let row = rows.first else { return nil }
        return Note(
            id: row["id"] as? Int ?? 0,
            topicId: row["topic_id"] as? Int ?? 0,
            filePath: row["file_path"] as? String ?? "",
            title: row["title"] as? String ?? "",
            aiSummary: row["ai_summary"] as? String,
            preLecturePrimer: row["pre_lecture_primer"] as? String
        )
    }
    
    func getMaxWeek(forModuleId moduleId: Int) -> Int {
        let rows = query(sql: "SELECT MAX(week) as max_week FROM topics WHERE module_id = ?", params: [moduleId])
        return rows.first?["max_week"] as? Int ?? 0
    }
    
    // MARK: - Flashcards queries
    
    func getFlashcards(forModuleId moduleId: Int? = nil) -> [Flashcard] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date FROM flashcards WHERE module_id = ?"
            params = [moduleId]
        } else {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date FROM flashcards"
            params = []
        }
        let rows = query(sql: sql, params: params)
        return rows.map { row in
            Flashcard(
                id: row["id"] as? Int ?? 0,
                moduleId: row["module_id"] as? Int ?? 0,
                front: row["front"] as? String ?? "",
                back: row["back"] as? String ?? "",
                nextReviewDate: row["next_review_date"] as? String ?? "",
                interval: row["interval"] as? Int ?? 0,
                easeFactor: row["ease_factor"] as? Double ?? 2.5,
                repetitions: row["repetitions"] as? Int ?? 0,
                createdDate: row["created_date"] as? String ?? ""
            )
        }
    }
    
    func getDueFlashcards(forModuleId moduleId: Int? = nil, today: String) -> [Flashcard] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date FROM flashcards WHERE module_id = ? AND (next_review_date <= ? OR next_review_date IS NULL OR next_review_date = '')"
            params = [moduleId, today]
        } else {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date FROM flashcards WHERE next_review_date <= ? OR next_review_date IS NULL OR next_review_date = ''"
            params = [today]
        }
        let rows = query(sql: sql, params: params)
        return rows.map { row in
            Flashcard(
                id: row["id"] as? Int ?? 0,
                moduleId: row["module_id"] as? Int ?? 0,
                front: row["front"] as? String ?? "",
                back: row["back"] as? String ?? "",
                nextReviewDate: row["next_review_date"] as? String ?? "",
                interval: row["interval"] as? Int ?? 0,
                easeFactor: row["ease_factor"] as? Double ?? 2.5,
                repetitions: row["repetitions"] as? Int ?? 0,
                createdDate: row["created_date"] as? String ?? ""
            )
        }
    }
    
    func addFlashcard(moduleId: Int, front: String, back: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        return execute(
            sql: "INSERT INTO flashcards (module_id, front, back, next_review_date, created_date) VALUES (?, ?, ?, ?, ?)",
            params: [moduleId, front, back, today, today]
        )
    }
    
    func updateFlashcardReview(id: Int, interval: Int, easeFactor: Double, repetitions: Int, nextReviewDate: String) -> Bool {
        return execute(
            sql: "UPDATE flashcards SET interval = ?, ease_factor = ?, repetitions = ?, next_review_date = ? WHERE id = ?",
            params: [interval, easeFactor, repetitions, nextReviewDate, id]
        )
    }
    
    func deleteFlashcard(id: Int) -> Bool {
        return execute(sql: "DELETE FROM flashcards WHERE id = ?", params: [id])
    }
    
    // MARK: - Problems queries
    
    func getProblems(forModuleId moduleId: Int? = nil) -> [Problem] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = """
                SELECT p.id, p.topic_id, p.content, p.solution_hint, p.created_date, p.solved_count, p.solution, p.steps
                FROM problems p
                JOIN topics t ON p.topic_id = t.id
                WHERE t.module_id = ?
            """
            params = [moduleId]
        } else {
            sql = "SELECT id, topic_id, content, solution_hint, created_date, solved_count, solution, steps FROM problems"
            params = []
        }
        let rows = query(sql: sql, params: params)
        return rows.map { row in
            Problem(
                id: row["id"] as? Int ?? 0,
                topicId: row["topic_id"] as? Int ?? 0,
                content: row["content"] as? String ?? "",
                solutionHint: row["solution_hint"] as? String ?? "",
                createdDate: row["created_date"] as? String ?? "",
                solvedCount: row["solved_count"] as? Int ?? 0,
                solution: row["solution"] as? String ?? "",
                steps: row["steps"] as? String ?? ""
            )
        }
    }
    
    func addProblem(topicId: Int, content: String, hint: String, solution: String = "", steps: String = "") -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        return execute(
            sql: "INSERT INTO problems (topic_id, content, solution_hint, created_date, solution, steps) VALUES (?, ?, ?, ?, ?, ?)",
            params: [topicId, content, hint, today, solution, steps]
        )
    }
    
    func incrementProblemSolvedCount(id: Int) -> Bool {
        return execute(sql: "UPDATE problems SET solved_count = solved_count + 1 WHERE id = ?", params: [id])
    }
    func updateProblem(id: Int, topicId: Int, content: String, hint: String, solution: String, steps: String) -> Bool {
        return execute(
            sql: "UPDATE problems SET topic_id = ?, content = ?, solution_hint = ?, solution = ?, steps = ? WHERE id = ?",
            params: [topicId, content, hint, solution, steps, id]
        )
    }
    
    func deleteProblem(id: Int) -> Bool {
        return execute(sql: "DELETE FROM problems WHERE id = ?", params: [id])
    }
    
    // MARK: - Feynman Chats & Sessions queries
    
    func getFeynmanChats(forNoteId noteId: Int) -> [FeynmanChat] {
        let rows = query(
            sql: "SELECT id, note_id, role, content, timestamp FROM feynman_chats WHERE note_id = ? ORDER BY id ASC",
            params: [noteId]
        )
        return rows.map { row in
            FeynmanChat(
                id: row["id"] as? Int ?? 0,
                noteId: row["note_id"] as? Int ?? 0,
                role: row["role"] as? String ?? "",
                content: row["content"] as? String ?? "",
                timestamp: row["timestamp"] as? String ?? ""
            )
        }
    }
    
    func addFeynmanChat(noteId: Int, role: String, content: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        
        return execute(
            sql: "INSERT INTO feynman_chats (note_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
            params: [noteId, role, content, timestamp]
        )
    }
    
    func clearFeynmanChats(forNoteId noteId: Int) -> Bool {
        return execute(sql: "DELETE FROM feynman_chats WHERE note_id = ?", params: [noteId])
    }
    
    func getFeynmanSessions(moduleId: Int?, searchQuery: String = "") -> [FeynmanSession] {
        let sql: String
        let params: [Any]
        let queryStr = "%\(searchQuery)%"
        
        if let moduleId = moduleId {
            sql = """
                SELECT id, module_id, concept, explanation, created_date 
                FROM feynman_sessions 
                WHERE module_id = ? AND (concept LIKE ? OR explanation LIKE ?) 
                ORDER BY id DESC
            """
            params = [moduleId, queryStr, queryStr]
        } else {
            sql = """
                SELECT id, module_id, concept, explanation, created_date 
                FROM feynman_sessions 
                WHERE (concept LIKE ? OR explanation LIKE ?) 
                ORDER BY id DESC
            """
            params = [queryStr, queryStr]
        }
        
        let rows = query(sql: sql, params: params)
        return rows.map { row in
            FeynmanSession(
                id: row["id"] as? Int ?? 0,
                moduleId: row["module_id"] as? Int ?? 0,
                concept: row["concept"] as? String ?? "",
                explanation: row["explanation"] as? String ?? "",
                createdDate: row["created_date"] as? String ?? ""
            )
        }
    }
    
    func addFeynmanSession(moduleId: Int?, concept: String, explanation: String) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        return execute(
            sql: "INSERT INTO feynman_sessions (module_id, concept, explanation, created_date) VALUES (?, ?, ?, ?)",
            params: [moduleId as Any, concept, explanation, today]
        )
    }
    
    func deleteFeynmanSession(id: Int) -> Bool {
        return execute(sql: "DELETE FROM feynman_sessions WHERE id = ?", params: [id])
    }
    
    func updateFeynmanSession(id: Int, moduleId: Int?, concept: String, explanation: String) -> Bool {
        return execute(
            sql: "UPDATE feynman_sessions SET module_id = ?, concept = ?, explanation = ? WHERE id = ?",
            params: [moduleId as Any, concept, explanation, id]
        )
    }
    
    // MARK: - Study Time Tracking queries
    
    func addStudyTime(flashcardsDelta: Int, problemsDelta: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        let rows = query(sql: "SELECT flashcards_seconds, problems_seconds FROM daily_study_time WHERE date = ?", params: [today])
        if let row = rows.first {
            let fc = (row["flashcards_seconds"] as? Int ?? 0) + flashcardsDelta
            let pb = (row["problems_seconds"] as? Int ?? 0) + problemsDelta
            execute(sql: "UPDATE daily_study_time SET flashcards_seconds = ?, problems_seconds = ? WHERE date = ?", params: [fc, pb, today])
        } else {
            execute(sql: "INSERT INTO daily_study_time (date, flashcards_seconds, problems_seconds) VALUES (?, ?, ?)", params: [today, flashcardsDelta, problemsDelta])
        }
    }
    
    func addModuleStudyTime(moduleId: Int, flashcardsDelta: Int, problemsDelta: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        let rows = query(sql: "SELECT flashcards_seconds, problems_seconds FROM module_study_time WHERE module_id = ? AND date = ?", params: [moduleId, today])
        if let row = rows.first {
            let fc = (row["flashcards_seconds"] as? Int ?? 0) + flashcardsDelta
            let pb = (row["problems_seconds"] as? Int ?? 0) + problemsDelta
            execute(sql: "UPDATE module_study_time SET flashcards_seconds = ?, problems_seconds = ? WHERE module_id = ? AND date = ?", params: [fc, pb, moduleId, today])
        } else {
            execute(sql: "INSERT INTO module_study_time (module_id, date, flashcards_seconds, problems_seconds) VALUES (?, ?, ?, ?)", params: [moduleId, today, flashcardsDelta, problemsDelta])
        }
    }
    
    func getTodayStudyTime() -> (flashcards: Int, problems: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        let rows = query(sql: "SELECT flashcards_seconds, problems_seconds FROM daily_study_time WHERE date = ?", params: [today])
        if let row = rows.first {
            return (row["flashcards_seconds"] as? Int ?? 0, row["problems_seconds"] as? Int ?? 0)
        }
        return (0, 0)
    }
    
    func getModuleTotalStudyTime(forModuleId moduleId: Int, timeframe: String) -> (flashcards: Int, problems: Int) {
        var sql = "SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb FROM module_study_time WHERE module_id = ?"
        var params: [Any] = [moduleId]
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        if timeframe == "Today" {
            sql += " AND date = ?"
            params.append(formatter.string(from: Date()))
        } else if timeframe == "This Week" {
            let calendar = Calendar.current
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            sql += " AND date >= ?"
            params.append(formatter.string(from: startOfWeek))
        } else if timeframe == "This Month" {
            let calendar = Calendar.current
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
            sql += " AND date >= ?"
            params.append(formatter.string(from: startOfMonth))
        }
        
        let rows = query(sql: sql, params: params)
        if let row = rows.first {
            return (row["fc"] as? Int ?? 0, row["pb"] as? Int ?? 0)
        }
        return (0, 0)
    }
    
    func getCreatedCounts(timeframe: String, moduleId: Int? = nil) -> (flashcards: Int, problems: Int) {
        var fcSQL = "SELECT COUNT(*) as cnt FROM flashcards"
        var pbSQL = "SELECT COUNT(*) as cnt FROM problems p"
        
        var conditions: [String] = []
        var fcParams: [Any] = []
        var pbParams: [Any] = []
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        if timeframe == "Today" {
            let today = formatter.string(from: Date())
            conditions.append("created_date = ?")
            fcParams.append(today)
            pbParams.append(today)
        } else if timeframe == "This Week" {
            let calendar = Calendar.current
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            let startStr = formatter.string(from: startOfWeek)
            conditions.append("created_date >= ?")
            fcParams.append(startStr)
            pbParams.append(startStr)
        } else if timeframe == "This Month" {
            let calendar = Calendar.current
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))!
            let startStr = formatter.string(from: startOfMonth)
            conditions.append("created_date >= ?")
            fcParams.append(startStr)
            pbParams.append(startStr)
        }
        
        if let modId = moduleId, modId != -1 {
            fcSQL += " WHERE module_id = ?"
            fcParams.append(modId)
            
            pbSQL = "SELECT COUNT(*) as cnt FROM problems p JOIN topics t ON p.topic_id = t.id WHERE t.module_id = ?"
            pbParams.append(modId)
            
            for cond in conditions {
                fcSQL += " AND \(cond)"
                pbSQL += " AND p.\(cond)"
            }
        } else {
            if !conditions.isEmpty {
                let condStr = conditions.joined(separator: " AND ")
                fcSQL += " WHERE \(condStr)"
                pbSQL += " WHERE \(condStr)"
            }
        }
        
        let fcRows = query(sql: fcSQL, params: fcParams)
        let pbRows = query(sql: pbSQL, params: pbParams)
        
        let fcCount = fcRows.first?["cnt"] as? Int ?? 0
        let pbCount = pbRows.first?["cnt"] as? Int ?? 0
        
        return (fcCount, pbCount)
    }
    
    // For heatmap
    func getDailyStudySecondsLastYear(moduleId: Int? = nil) -> [String: Int] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: Date())!
        let oneYearAgoStr = formatter.string(from: oneYearAgo)
        
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT date, SUM(flashcards_seconds + problems_seconds) as total FROM module_study_time WHERE module_id = ? AND date >= ? GROUP BY date"
            params = [moduleId, oneYearAgoStr]
        } else {
            sql = "SELECT date, (flashcards_seconds + problems_seconds) as total FROM daily_study_time WHERE date >= ?"
            params = [oneYearAgoStr]
        }
        
        let rows = query(sql: sql, params: params)
        var result: [String: Int] = [:]
        for row in rows {
            if let date = row["date"] as? String, let total = row["total"] as? Int {
                result[date] = total
            }
        }
        return result
    }
    
    // For Chart: Returns array of (label, flashcardVal, problemVal)
    func getCreatedBarData(timeframe: String) -> [(label: String, flashcards: Int, problems: Int)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        
        var list: [(label: String, date: String)] = []
        if timeframe == "Today" {
            // Last 7 days including today
            for i in (0..<7).reversed() {
                let date = calendar.date(byAdding: .day, value: -i, to: Date())!
                let lblFormatter = DateFormatter()
                lblFormatter.dateFormat = "E" // e.g. Mon
                list.append((lblFormatter.string(from: date), formatter.string(from: date)))
            }
        } else if timeframe == "This Week" {
            // Last 5 weeks
            for i in (0..<5).reversed() {
                if let date = calendar.date(byAdding: .weekOfYear, value: -i, to: Date()) {
                    let lblFormatter = DateFormatter()
                    lblFormatter.dateFormat = "w"
                    list.append((lblFormatter.string(from: date), formatter.string(from: date)))
                }
            }
        } else if timeframe == "This Month" {
            // Last 6 months
            for i in (0..<6).reversed() {
                if let date = calendar.date(byAdding: .month, value: -i, to: Date()) {
                    let lblFormatter = DateFormatter()
                    lblFormatter.dateFormat = "MMM"
                    list.append((lblFormatter.string(from: date), formatter.string(from: date)))
                }
            }
        } else {
            // All Time - show years or last 12 months
            for i in (0..<12).reversed() {
                if let date = calendar.date(byAdding: .month, value: -i, to: Date()) {
                    let lblFormatter = DateFormatter()
                    lblFormatter.dateFormat = "MMM"
                    list.append((lblFormatter.string(from: date), formatter.string(from: date)))
                }
            }
        }
        
        var result: [(label: String, flashcards: Int, problems: Int)] = []
        for item in list {
            // Query counts
            var fcSQL = "SELECT COUNT(*) as cnt FROM flashcards WHERE "
            var pbSQL = "SELECT COUNT(*) as cnt FROM problems WHERE "
            var params: [Any] = []
            
            if timeframe == "Today" {
                fcSQL += "created_date = ?"
                pbSQL += "created_date = ?"
                params.append(item.date)
            } else if timeframe == "This Week" {
                // Find start and end of that week
                if let dateVal = formatter.date(from: item.date) {
                    let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dateVal))!
                    let endOfWeek = calendar.date(byAdding: .day, value: 6, to: startOfWeek)!
                    fcSQL += "created_date >= ? AND created_date <= ?"
                    pbSQL += "created_date >= ? AND created_date <= ?"
                    params.append(formatter.string(from: startOfWeek))
                    params.append(formatter.string(from: endOfWeek))
                }
            } else {
                // Month grouping
                if let dateVal = formatter.date(from: item.date) {
                    let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: dateVal))!
                    let endOfMonth = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: startOfMonth)!)!
                    fcSQL += "created_date >= ? AND created_date <= ?"
                    pbSQL += "created_date >= ? AND created_date <= ?"
                    params.append(formatter.string(from: startOfMonth))
                    params.append(formatter.string(from: endOfMonth))
                }
            }
            
            let fcRows = query(sql: fcSQL, params: params)
            let pbRows = query(sql: pbSQL, params: params)
            let fcCount = fcRows.first?["cnt"] as? Int ?? 0
            let pbCount = pbRows.first?["cnt"] as? Int ?? 0
            result.append((item.label, fcCount, pbCount))
        }
        return result
    }
    
    // For Chart: Returns array of (label, flashcardTimeMinutes, problemTimeMinutes)
    func getStudyTimeBarData(timeframe: String, moduleId: Int? = nil) -> [(label: String, flashcards: Int, problems: Int)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        
        var list: [(label: String, date: String)] = []
        if timeframe == "Today" {
            // Last 7 days including today
            for i in (0..<7).reversed() {
                let date = calendar.date(byAdding: .day, value: -i, to: Date())!
                let lblFormatter = DateFormatter()
                lblFormatter.dateFormat = "E" // e.g. Mon
                list.append((lblFormatter.string(from: date), formatter.string(from: date)))
            }
        } else if timeframe == "This Week" {
            // Last 5 weeks
            for i in (0..<5).reversed() {
                if let date = calendar.date(byAdding: .weekOfYear, value: -i, to: Date()) {
                    let lblFormatter = DateFormatter()
                    lblFormatter.dateFormat = "'Wk' w"
                    list.append((lblFormatter.string(from: date), formatter.string(from: date)))
                }
            }
        } else if timeframe == "This Month" {
            // Last 6 months
            for i in (0..<6).reversed() {
                if let date = calendar.date(byAdding: .month, value: -i, to: Date()) {
                    let lblFormatter = DateFormatter()
                    lblFormatter.dateFormat = "MMM"
                    list.append((lblFormatter.string(from: date), formatter.string(from: date)))
                }
            }
        } else {
            // All Time - show last 12 months
            for i in (0..<12).reversed() {
                if let date = calendar.date(byAdding: .month, value: -i, to: Date()) {
                    let lblFormatter = DateFormatter()
                    lblFormatter.dateFormat = "MMM"
                    list.append((lblFormatter.string(from: date), formatter.string(from: date)))
                }
            }
        }
        
        var result: [(label: String, flashcards: Int, problems: Int)] = []
        for item in list {
            // Query sums of seconds and convert to minutes for a cleaner chart scale
            var sql: String
            var params: [Any] = []
            
            if let modId = moduleId, modId != -1 {
                sql = "SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb FROM module_study_time WHERE module_id = ? AND "
                params.append(modId)
            } else {
                sql = "SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb FROM daily_study_time WHERE "
            }
            
            if timeframe == "Today" {
                sql += "date = ?"
                params.append(item.date)
            } else if timeframe == "This Week" {
                if let dateVal = formatter.date(from: item.date) {
                    let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dateVal))!
                    let endOfWeek = calendar.date(byAdding: .day, value: 6, to: startOfWeek)!
                    sql += "date >= ? AND date <= ?"
                    params.append(formatter.string(from: startOfWeek))
                    params.append(formatter.string(from: endOfWeek))
                }
            } else {
                if let dateVal = formatter.date(from: item.date) {
                    let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: dateVal))!
                    let endOfMonth = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: startOfMonth)!)!
                    sql += "date >= ? AND date <= ?"
                    params.append(formatter.string(from: startOfMonth))
                    params.append(formatter.string(from: endOfMonth))
                }
            }
            
            let rows = query(sql: sql, params: params)
            let fcSeconds = rows.first?["fc"] as? Int ?? 0
            let pbSeconds = rows.first?["pb"] as? Int ?? 0
            
            // Convert to minutes for chart representation
            let fcMinutes = fcSeconds / 60
            let pbMinutes = pbSeconds / 60
            result.append((item.label, fcMinutes, pbMinutes))
        }
        return result
    }
    
    // MARK: - Activity log & Averages queries
    
    func logActivity(_ activityType: String, moduleId: Int? = nil) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        execute(
            sql: "INSERT INTO activity_log (activity_type, timestamp, module_id) VALUES (?, ?, ?)",
            params: [activityType, timestamp, moduleId ?? NSNull()]
        )
    }
    
    func getAvgSolveTimes(timeframeStartDate: String, moduleId: Int? = nil) -> (flashcardAvg: Double, problemAvg: Double) {
        let secondsRows: [[String: Any]]
        let logRows: [[String: Any]]
        
        if let modId = moduleId, modId != -1 {
            secondsRows = query(sql: """
                SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb 
                FROM module_study_time 
                WHERE module_id = ? AND date >= ?
            """, params: [modId, timeframeStartDate])
            
            logRows = query(sql: """
                SELECT activity_type, COUNT(*) as cnt 
                FROM activity_log 
                WHERE module_id = ? AND date(timestamp) >= ? 
                GROUP BY activity_type
            """, params: [modId, timeframeStartDate])
        } else {
            secondsRows = query(sql: """
                SELECT SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb 
                FROM daily_study_time 
                WHERE date >= ?
            """, params: [timeframeStartDate])
            
            logRows = query(sql: """
                SELECT activity_type, COUNT(*) as cnt 
                FROM activity_log 
                WHERE date(timestamp) >= ? 
                GROUP BY activity_type
            """, params: [timeframeStartDate])
        }
        
        let totalFcSec = secondsRows.first?["fc"] as? Int ?? 0
        let totalPbSec = secondsRows.first?["pb"] as? Int ?? 0
        
        var fcCount = 0
        var pbCount = 0
        for row in logRows {
            if let actType = row["activity_type"] as? String, let count = row["cnt"] as? Int {
                if actType == "flashcard" {
                    fcCount = count
                } else if actType == "interleaving" {
                    pbCount = count
                }
            }
        }
        
        let avgFc = fcCount > 0 ? Double(totalFcSec) / Double(fcCount) : 0.0
        let avgProb = pbCount > 0 ? Double(totalPbSec) / Double(pbCount) : 0.0
        return (avgFc, avgProb)
    }
}
