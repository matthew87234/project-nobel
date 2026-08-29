import Foundation
import SQLite3

internal let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

struct Module: Identifiable, Hashable {
    var id: Int
    var code: String
    var name: String
    var semester: Int
    var year: Int
    var testDate: String = ""
    
    var testDateFormattedDateOnly: String {
        guard !testDate.isEmpty else { return "No Exam Set" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parsedDate = formatter.date(from: testDate)
        if parsedDate == nil {
            let fallbackFormatter = DateFormatter()
            fallbackFormatter.dateFormat = "yyyy-MM-dd"
            parsedDate = fallbackFormatter.date(from: testDate)
        }
        if let date = parsedDate {
            let outFormatter = DateFormatter()
            outFormatter.dateFormat = "d MMM yyyy"
            return outFormatter.string(from: date)
        }
        return testDate
    }
    
    var daysRemaining: Int? {
        guard !testDate.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var parsedDate = formatter.date(from: testDate)
        if parsedDate == nil {
            let fallbackFormatter = DateFormatter()
            fallbackFormatter.dateFormat = "yyyy-MM-dd"
            parsedDate = fallbackFormatter.date(from: testDate)
        }
        guard let examDate = parsedDate else { return nil }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfExam = calendar.startOfDay(for: examDate)
        let components = calendar.dateComponents([.day], from: startOfToday, to: startOfExam)
        return components.day
    }
    
    var daysRemainingFormatted: String {
        guard let days = daysRemaining else { return "" }
        if days > 1 {
            return "\(days) days remaining"
        } else if days == 1 {
            return "1 day remaining"
        } else if days == 0 {
            return "Exam is today"
        } else {
            return "\(abs(days)) days ago"
        }
    }
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
    var isFlagged: Bool = false
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
    var isFlagged: Bool = false
    var lastReviewedDate: String = ""
    var nextReviewDate: String = ""
    var lastFailedStep: Int = 0
    var severityLevel: Int = 4
    var interval: Int = 0
    var easeFactor: Double = 2.5
    var repetitions: Int = 0
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
        
        let isDesktopApp = Bundle.main.bundlePath.contains("/Desktop") || ProcessInfo.processInfo.arguments.contains("--desktop-db")
        let dbFilename = isDesktopApp ? "physics_study_desktop.db" : "physics_study.db"
        let dbURL = appSupportDir.appendingPathComponent(dbFilename)
        
        if isDesktopApp && !fileManager.fileExists(atPath: dbURL.path) {
            let prodURL = appSupportDir.appendingPathComponent("physics_study.db")
            if fileManager.fileExists(atPath: prodURL.path) {
                try? fileManager.copyItem(at: prodURL, to: dbURL)
            }
        }
        
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
        alterTableAddColumn(table: "modules", column: "test_date", type: "TEXT")
        
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
                is_flagged INTEGER DEFAULT 0,
                FOREIGN KEY (module_id) REFERENCES modules(id)
            );
        """)
        alterTableAddColumn(table: "flashcards", column: "created_date", type: "TEXT")
        alterTableAddColumn(table: "flashcards", column: "is_flagged", type: "INTEGER DEFAULT 0")
        
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
        alterTableAddColumn(table: "problems", column: "is_flagged", type: "INTEGER DEFAULT 0")
        alterTableAddColumn(table: "problems", column: "last_reviewed_date", type: "TEXT")
        alterTableAddColumn(table: "problems", column: "next_review_date", type: "TEXT")
        alterTableAddColumn(table: "problems", column: "last_failed_step", type: "INTEGER DEFAULT 0")
        alterTableAddColumn(table: "problems", column: "severity_level", type: "INTEGER DEFAULT 4")
        alterTableAddColumn(table: "problems", column: "interval", type: "INTEGER DEFAULT 0")
        alterTableAddColumn(table: "problems", column: "ease_factor", type: "REAL DEFAULT 2.5")
        alterTableAddColumn(table: "problems", column: "repetitions", type: "INTEGER DEFAULT 0")
        
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
            sql = "SELECT id, code, name, semester, year, test_date FROM modules WHERE year = ? ORDER BY code ASC"
            params = [year]
        } else {
            sql = "SELECT id, code, name, semester, year, test_date FROM modules ORDER BY year ASC, code ASC"
            params = []
        }
        
        let rows = query(sql: sql, params: params)
        return rows.map { row in
            Module(
                id: row["id"] as? Int ?? 0,
                code: row["code"] as? String ?? "",
                name: row["name"] as? String ?? "",
                semester: row["semester"] as? Int ?? 1,
                year: row["year"] as? Int ?? 1,
                testDate: row["test_date"] as? String ?? ""
            )
        }
    }
    
    func addModule(code: String, name: String, semester: Int, year: Int, testDate: String = "") -> Bool {
        return execute(
            sql: "INSERT INTO modules (code, name, semester, year, test_date) VALUES (?, ?, ?, ?, ?)",
            params: [code, name, semester, year, testDate]
        )
    }
    
    func updateModule(id: Int, code: String, name: String, semester: Int, year: Int, testDate: String = "") -> Bool {
        return execute(
            sql: "UPDATE modules SET code = ?, name = ?, semester = ?, year = ?, test_date = ? WHERE id = ?",
            params: [code, name, semester, year, testDate, id]
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
    
    func getNotes(forModuleId moduleId: Int? = nil) -> [Note] {
        var sql = """
            SELECT n.id, n.topic_id, n.file_path, n.title, n.ai_summary, n.pre_lecture_primer
            FROM notes n
            JOIN topics t ON n.topic_id = t.id
        """
        var params: [Any] = []
        if let modId = moduleId {
            sql += " WHERE t.module_id = ?"
            params.append(modId)
        }
        sql += " ORDER BY t.week ASC, t.id ASC"
        
        let rows = query(sql: sql, params: params)
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
    
    func updateNoteOrder(notesInOrder: [Note]) -> Bool {
        var success = true
        for (index, note) in notesInOrder.enumerated() {
            let newWeek = index + 1
            let ok = execute(sql: "UPDATE topics SET week = ? WHERE id = ?", params: [newWeek, note.topicId])
            if !ok { success = false }
        }
        return success
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
    
    func clearPreLecturePrimer(noteId: Int) -> Bool {
        return execute(sql: "UPDATE notes SET pre_lecture_primer = NULL WHERE id = ?", params: [noteId])
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
    
    func getFlashcards(forYear: Int? = nil, forModuleId moduleId: Int? = nil) -> [Flashcard] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date, is_flagged FROM flashcards WHERE module_id = ?"
            params = [moduleId]
        } else if let year = forYear {
            sql = """
                SELECT f.id, f.module_id, f.front, f.back, f.next_review_date, f.interval, f.ease_factor, f.repetitions, f.created_date, f.is_flagged
                FROM flashcards f
                JOIN modules m ON f.module_id = m.id
                WHERE m.year = ?
            """
            params = [year]
        } else {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date, is_flagged FROM flashcards"
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
                createdDate: row["created_date"] as? String ?? "",
                isFlagged: (row["is_flagged"] as? Int ?? 0) == 1
            )
        }
    }
    
    func getDueFlashcards(forYear: Int? = nil, forModuleId moduleId: Int? = nil, today: String) -> [Flashcard] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date, is_flagged FROM flashcards WHERE module_id = ? AND (next_review_date <= ? OR next_review_date IS NULL OR next_review_date = '')"
            params = [moduleId, today]
        } else if let year = forYear {
            sql = """
                SELECT f.id, f.module_id, f.front, f.back, f.next_review_date, f.interval, f.ease_factor, f.repetitions, f.created_date, f.is_flagged
                FROM flashcards f
                JOIN modules m ON f.module_id = m.id
                WHERE m.year = ? AND (f.next_review_date <= ? OR f.next_review_date IS NULL OR f.next_review_date = '')
            """
            params = [year, today]
        } else {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date, is_flagged FROM flashcards WHERE next_review_date <= ? OR next_review_date IS NULL OR next_review_date = ''"
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
                createdDate: row["created_date"] as? String ?? "",
                isFlagged: (row["is_flagged"] as? Int ?? 0) == 1
            )
        }
    }
    
    func getFlaggedFlashcards(forYear: Int? = nil, forModuleId moduleId: Int? = nil) -> [Flashcard] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date, is_flagged FROM flashcards WHERE module_id = ? AND is_flagged = 1"
            params = [moduleId]
        } else if let year = forYear {
            sql = """
                SELECT f.id, f.module_id, f.front, f.back, f.next_review_date, f.interval, f.ease_factor, f.repetitions, f.created_date, f.is_flagged
                FROM flashcards f
                JOIN modules m ON f.module_id = m.id
                WHERE m.year = ? AND f.is_flagged = 1
            """
            params = [year]
        } else {
            sql = "SELECT id, module_id, front, back, next_review_date, interval, ease_factor, repetitions, created_date, is_flagged FROM flashcards WHERE is_flagged = 1"
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
                createdDate: row["created_date"] as? String ?? "",
                isFlagged: (row["is_flagged"] as? Int ?? 0) == 1
            )
        }
    }
    
    func setFlashcardFlag(id: Int, isFlagged: Bool) -> Bool {
        return execute(sql: "UPDATE flashcards SET is_flagged = ? WHERE id = ?", params: [isFlagged ? 1 : 0, id])
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
    
    func updateFlashcard(id: Int, front: String, back: String) -> Bool {
        return execute(
            sql: "UPDATE flashcards SET front = ?, back = ? WHERE id = ?",
            params: [front, back, id]
        )
    }
    
    func deleteFlashcard(id: Int) -> Bool {
        return execute(sql: "DELETE FROM flashcards WHERE id = ?", params: [id])
    }
    
    // MARK: - Problems queries
    
    func getProblems(forYear: Int? = nil, forModuleId moduleId: Int? = nil) -> [Problem] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = """
                SELECT p.id, p.topic_id, p.content, p.solution_hint, p.created_date, p.solved_count, p.solution, p.steps, p.is_flagged, p.last_reviewed_date, p.next_review_date, p.last_failed_step, p.severity_level, p.interval, p.ease_factor, p.repetitions
                FROM problems p
                JOIN topics t ON p.topic_id = t.id
                WHERE t.module_id = ?
            """
            params = [moduleId]
        } else if let year = forYear {
            sql = """
                SELECT p.id, p.topic_id, p.content, p.solution_hint, p.created_date, p.solved_count, p.solution, p.steps, p.is_flagged, p.last_reviewed_date, p.next_review_date, p.last_failed_step, p.severity_level, p.interval, p.ease_factor, p.repetitions
                FROM problems p
                JOIN topics t ON p.topic_id = t.id
                JOIN modules m ON t.module_id = m.id
                WHERE m.year = ?
            """
            params = [year]
        } else {
            sql = "SELECT id, topic_id, content, solution_hint, created_date, solved_count, solution, steps, is_flagged, last_reviewed_date, next_review_date, last_failed_step, severity_level, interval, ease_factor, repetitions FROM problems"
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
                steps: row["steps"] as? String ?? "",
                isFlagged: (row["is_flagged"] as? Int ?? 0) == 1,
                lastReviewedDate: row["last_reviewed_date"] as? String ?? "",
                nextReviewDate: row["next_review_date"] as? String ?? "",
                lastFailedStep: row["last_failed_step"] as? Int ?? 0,
                severityLevel: row["severity_level"] as? Int ?? 4,
                interval: row["interval"] as? Int ?? 0,
                easeFactor: row["ease_factor"] as? Double ?? 2.5,
                repetitions: row["repetitions"] as? Int ?? 0
            )
        }
    }
    
    func getDueProblems(forYear: Int? = nil, forModuleId moduleId: Int? = nil, today: String) -> [Problem] {
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = """
                SELECT p.id, p.topic_id, p.content, p.solution_hint, p.created_date, p.solved_count, p.solution, p.steps, p.is_flagged, p.last_reviewed_date, p.next_review_date, p.last_failed_step, p.severity_level, p.interval, p.ease_factor, p.repetitions
                FROM problems p
                JOIN topics t ON p.topic_id = t.id
                WHERE t.module_id = ? AND (p.next_review_date <= ? OR p.next_review_date IS NULL OR p.next_review_date = '')
            """
            params = [moduleId, today]
        } else if let year = forYear {
            sql = """
                SELECT p.id, p.topic_id, p.content, p.solution_hint, p.created_date, p.solved_count, p.solution, p.steps, p.is_flagged, p.last_reviewed_date, p.next_review_date, p.last_failed_step, p.severity_level, p.interval, p.ease_factor, p.repetitions
                FROM problems p
                JOIN topics t ON p.topic_id = t.id
                JOIN modules m ON t.module_id = m.id
                WHERE m.year = ? AND (p.next_review_date <= ? OR p.next_review_date IS NULL OR p.next_review_date = '')
            """
            params = [year, today]
        } else {
            sql = "SELECT id, topic_id, content, solution_hint, created_date, solved_count, solution, steps, is_flagged, last_reviewed_date, next_review_date, last_failed_step, severity_level, interval, ease_factor, repetitions FROM problems WHERE next_review_date <= ? OR next_review_date IS NULL OR next_review_date = ''"
            params = [today]
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
                steps: row["steps"] as? String ?? "",
                isFlagged: (row["is_flagged"] as? Int ?? 0) == 1,
                lastReviewedDate: row["last_reviewed_date"] as? String ?? "",
                nextReviewDate: row["next_review_date"] as? String ?? "",
                lastFailedStep: row["last_failed_step"] as? Int ?? 0,
                severityLevel: row["severity_level"] as? Int ?? 4,
                interval: row["interval"] as? Int ?? 0,
                easeFactor: row["ease_factor"] as? Double ?? 2.5,
                repetitions: row["repetitions"] as? Int ?? 0
            )
        }
    }
    
    func getProblem(id: Int) -> Problem? {
        let rows = query(
            sql: "SELECT id, topic_id, content, solution_hint, created_date, solved_count, solution, steps, is_flagged, last_reviewed_date, next_review_date, last_failed_step, severity_level, interval, ease_factor, repetitions FROM problems WHERE id = ?",
            params: [id]
        )
        guard let row = rows.first else { return nil }
        return Problem(
            id: row["id"] as? Int ?? 0,
            topicId: row["topic_id"] as? Int ?? 0,
            content: row["content"] as? String ?? "",
            solutionHint: row["solution_hint"] as? String ?? "",
            createdDate: row["created_date"] as? String ?? "",
            solvedCount: row["solved_count"] as? Int ?? 0,
            solution: row["solution"] as? String ?? "",
            steps: row["steps"] as? String ?? "",
            isFlagged: (row["is_flagged"] as? Int ?? 0) == 1,
            lastReviewedDate: row["last_reviewed_date"] as? String ?? "",
            nextReviewDate: row["next_review_date"] as? String ?? "",
            lastFailedStep: row["last_failed_step"] as? Int ?? 0,
            severityLevel: row["severity_level"] as? Int ?? 4,
            interval: row["interval"] as? Int ?? 0,
            easeFactor: row["ease_factor"] as? Double ?? 2.5,
            repetitions: row["repetitions"] as? Int ?? 0
        )
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
    
    func setProblemFlagged(id: Int, isFlagged: Bool) -> Bool {
        return execute(sql: "UPDATE problems SET is_flagged = ? WHERE id = ?", params: [isFlagged ? 1 : 0, id])
    }
    
    func recordProblemPracticeResult(id: Int, failedStep: Int, totalSteps: Int) -> Bool {
        let currentProb = getProblem(id: id)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayDate = Date()
        let todayStr = formatter.string(from: todayDate)
        
        let quality: Int
        let severity: Int
        
        if failedStep == 1 {
            quality = 1 // Again (Critical Setup Error)
            severity = 1
        } else if failedStep == 2 {
            quality = 2 // Hard (Formulation Error)
            severity = 2
        } else if failedStep >= 3 {
            quality = 3 // Good (Calculation / Algebra Slip)
            severity = 3
        } else {
            quality = 4 // Easy / Flawless
            severity = 4
        }
        
        // SM-2 Spaced Repetition Algorithm for Problems
        var reps = currentProb?.repetitions ?? 0
        var ease = currentProb?.easeFactor ?? 2.5
        let currentInterval = currentProb?.interval ?? 0
        let nextInterval: Int
        
        if quality >= 3 {
            reps += 1
            if reps == 1 {
                nextInterval = (quality == 4) ? 3 : 1
            } else if reps == 2 {
                nextInterval = (quality == 4) ? 7 : 4
            } else {
                let multiplier = (quality == 4) ? (ease * 1.3) : ease
                nextInterval = max(reps + 2, Int(Double(max(currentInterval, 1)) * multiplier))
            }
        } else {
            reps = 0
            nextInterval = (quality == 2) ? 2 : 1
        }
        
        // Adjust Ease Factor using SuperMemo-2 formula (minimum 1.3)
        ease = ease + (0.1 - (5.0 - Double(quality)) * (0.08 + (5.0 - Double(quality)) * 0.02))
        if ease < 1.3 {
            ease = 1.3
        }
        
        let nextDate = Calendar.current.date(byAdding: .day, value: nextInterval, to: todayDate) ?? todayDate
        let nextStr = formatter.string(from: nextDate)
        
        return execute(
            sql: """
                UPDATE problems
                SET solved_count = solved_count + 1,
                    last_reviewed_date = ?,
                    next_review_date = ?,
                    last_failed_step = ?,
                    severity_level = ?,
                    interval = ?,
                    ease_factor = ?,
                    repetitions = ?
                WHERE id = ?
            """,
            params: [todayStr, nextStr, failedStep, severity, nextInterval, ease, reps, id]
        )
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
            let fc = max(0, (row["flashcards_seconds"] as? Int ?? 0) + flashcardsDelta)
            let pb = max(0, (row["problems_seconds"] as? Int ?? 0) + problemsDelta)
            execute(sql: "UPDATE daily_study_time SET flashcards_seconds = ?, problems_seconds = ? WHERE date = ?", params: [fc, pb, today])
        } else {
            execute(sql: "INSERT INTO daily_study_time (date, flashcards_seconds, problems_seconds) VALUES (?, ?, ?)", params: [today, max(0, flashcardsDelta), max(0, problemsDelta)])
        }
    }
    
    func addModuleStudyTime(moduleId: Int, flashcardsDelta: Int, problemsDelta: Int) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        let rows = query(sql: "SELECT flashcards_seconds, problems_seconds FROM module_study_time WHERE module_id = ? AND date = ?", params: [moduleId, today])
        if let row = rows.first {
            let fc = max(0, (row["flashcards_seconds"] as? Int ?? 0) + flashcardsDelta)
            let pb = max(0, (row["problems_seconds"] as? Int ?? 0) + problemsDelta)
            execute(sql: "UPDATE module_study_time SET flashcards_seconds = ?, problems_seconds = ? WHERE module_id = ? AND date = ?", params: [fc, pb, moduleId, today])
        } else {
            execute(sql: "INSERT INTO module_study_time (module_id, date, flashcards_seconds, problems_seconds) VALUES (?, ?, ?, ?)", params: [moduleId, today, max(0, flashcardsDelta), max(0, problemsDelta)])
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
    struct DailyStudyBreakdown {
        let date: String
        let flashcardsSeconds: Int
        let problemsSeconds: Int
        var totalSeconds: Int { flashcardsSeconds + problemsSeconds }
    }
    
    func getDailyStudyBreakdownLastYear(moduleId: Int? = nil) -> [String: DailyStudyBreakdown] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let oneYearAgo = calendar.date(byAdding: .year, value: -1, to: Date())!
        let oneYearAgoStr = formatter.string(from: oneYearAgo)
        
        let sql: String
        let params: [Any]
        if let moduleId = moduleId {
            sql = "SELECT date, SUM(flashcards_seconds) as fc, SUM(problems_seconds) as pb FROM module_study_time WHERE module_id = ? AND date >= ? GROUP BY date"
            params = [moduleId, oneYearAgoStr]
        } else {
            sql = "SELECT date, flashcards_seconds as fc, problems_seconds as pb FROM daily_study_time WHERE date >= ?"
            params = [oneYearAgoStr]
        }
        
        let rows = query(sql: sql, params: params)
        var result: [String: DailyStudyBreakdown] = [:]
        for row in rows {
            if let date = row["date"] as? String {
                let fc = row["fc"] as? Int ?? 0
                let pb = row["pb"] as? Int ?? 0
                result[date] = DailyStudyBreakdown(date: date, flashcardsSeconds: fc, problemsSeconds: pb)
            }
        }
        return result
    }
    
    func getDailyStudySecondsLastYear(moduleId: Int? = nil) -> [String: Int] {
        let breakdown = getDailyStudyBreakdownLastYear(moduleId: moduleId)
        var result: [String: Int] = [:]
        for (k, v) in breakdown {
            result[k] = v.totalSeconds
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
    
    // MARK: - Flashcard Graph Popups Queries
    
    func getDueProjection(moduleId: Int?) -> [(dayLabel: String, dateString: String, count: Int)] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        
        let lblFormatter = DateFormatter()
        lblFormatter.dateFormat = "E (d/M)"
        
        var result: [(dayLabel: String, dateString: String, count: Int)] = []
        let today = Date()
        let todayStr = formatter.string(from: today)
        
        for i in 0..<7 {
            let targetDate = calendar.date(byAdding: .day, value: i, to: today)!
            let dateStr = formatter.string(from: targetDate)
            let dayLabel = (i == 0) ? "Today" : ((i == 1) ? "Tomorrow" : lblFormatter.string(from: targetDate))
            
            let sql: String
            let params: [Any]
            
            if i == 0 {
                // Today includes overdue cards
                if let modId = moduleId, modId != -1 {
                    sql = "SELECT COUNT(*) as cnt FROM flashcards WHERE module_id = ? AND (next_review_date <= ? OR next_review_date IS NULL OR next_review_date = '')"
                    params = [modId, todayStr]
                } else {
                    sql = "SELECT COUNT(*) as cnt FROM flashcards WHERE (next_review_date <= ? OR next_review_date IS NULL OR next_review_date = '')"
                    params = [todayStr]
                }
            } else {
                if let modId = moduleId, modId != -1 {
                    sql = "SELECT COUNT(*) as cnt FROM flashcards WHERE module_id = ? AND next_review_date = ?"
                    params = [modId, dateStr]
                } else {
                    sql = "SELECT COUNT(*) as cnt FROM flashcards WHERE next_review_date = ?"
                    params = [dateStr]
                }
            }
            
            let rows = query(sql: sql, params: params)
            let count = rows.first?["cnt"] as? Int ?? 0
            result.append((dayLabel, dateStr, count))
        }
        return result
    }
    
    func getCumulativeCardsCreated(moduleId: Int?) -> [(dateLabel: String, count: Int)] {
        let sql: String
        let params: [Any]
        if let modId = moduleId, modId != -1 {
            sql = "SELECT created_date, COUNT(*) as cnt FROM flashcards WHERE module_id = ? AND created_date IS NOT NULL AND created_date != '' GROUP BY created_date ORDER BY created_date ASC"
            params = [modId]
        } else {
            sql = "SELECT created_date, COUNT(*) as cnt FROM flashcards WHERE created_date IS NOT NULL AND created_date != '' GROUP BY created_date ORDER BY created_date ASC"
            params = []
        }
        
        let rows = query(sql: sql, params: params)
        var result: [(dateLabel: String, count: Int)] = []
        var runningTotal = 0
        
        let inFormatter = DateFormatter()
        inFormatter.dateFormat = "yyyy-MM-dd"
        let outFormatter = DateFormatter()
        outFormatter.dateFormat = "d MMM"
        
        for row in rows {
            if let dateStr = row["created_date"] as? String, let cnt = row["cnt"] as? Int {
                runningTotal += cnt
                let formattedLabel: String
                if let d = inFormatter.date(from: dateStr) {
                    formattedLabel = outFormatter.string(from: d)
                } else {
                    formattedLabel = dateStr
                }
                result.append((formattedLabel, runningTotal))
            }
        }
        
        if result.isEmpty {
            let todayLabel = outFormatter.string(from: Date())
            let total = getFlashcards(forModuleId: moduleId).count
            result.append((todayLabel, total))
        }
        
        return result
    }
    
    func getWeeklyTimeDistribution(moduleId: Int?) -> [(rangeLabel: String, count: Int)] {
        let calendar = Calendar.current
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: Date())!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: sevenDaysAgo)
        
        let (avgSec, _) = getAvgSolveTimes(timeframeStartDate: dateStr, moduleId: moduleId)
        
        let sql: String
        let params: [Any]
        if let modId = moduleId, modId != -1 {
            sql = "SELECT COUNT(*) as cnt FROM activity_log WHERE activity_type = 'flashcard' AND module_id = ? AND date(timestamp) >= ?"
            params = [modId, dateStr]
        } else {
            sql = "SELECT COUNT(*) as cnt FROM activity_log WHERE activity_type = 'flashcard' AND date(timestamp) >= ?"
            params = [dateStr]
        }
        let rows = query(sql: sql, params: params)
        let totalCount = rows.first?["cnt"] as? Int ?? 0
        
        var bins: [(rangeLabel: String, count: Int)] = []
        if totalCount == 0 {
            bins = [
                ("<5s", 0), ("5-10s", 0), ("10-15s", 0), ("15-20s", 0),
                ("20-30s", 0), ("30-45s", 0), ("45-60s", 0), (">60s", 0)
            ]
        } else {
            let c = totalCount
            if avgSec < 10 {
                bins = [
                    ("<5s", Int(Double(c) * 0.35)),
                    ("5-10s", Int(Double(c) * 0.40)),
                    ("10-15s", Int(Double(c) * 0.15)),
                    ("15-20s", Int(Double(c) * 0.06)),
                    ("20-30s", Int(Double(c) * 0.03)),
                    ("30-45s", Int(Double(c) * 0.01)),
                    ("45-60s", 0),
                    (">60s", 0)
                ]
            } else if avgSec < 25 {
                bins = [
                    ("<5s", Int(Double(c) * 0.10)),
                    ("5-10s", Int(Double(c) * 0.20)),
                    ("10-15s", Int(Double(c) * 0.30)),
                    ("15-20s", Int(Double(c) * 0.20)),
                    ("20-30s", Int(Double(c) * 0.12)),
                    ("30-45s", Int(Double(c) * 0.05)),
                    ("45-60s", Int(Double(c) * 0.02)),
                    (">60s", Int(Double(c) * 0.01))
                ]
            } else {
                bins = [
                    ("<5s", Int(Double(c) * 0.05)),
                    ("5-10s", Int(Double(c) * 0.10)),
                    ("10-15s", Int(Double(c) * 0.15)),
                    ("15-20s", Int(Double(c) * 0.20)),
                    ("20-30s", Int(Double(c) * 0.25)),
                    ("30-45s", Int(Double(c) * 0.15)),
                    ("45-60s", Int(Double(c) * 0.07)),
                    (">60s", Int(Double(c) * 0.03))
                ]
            }
        }
        return bins
    }
}
