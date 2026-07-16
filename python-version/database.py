import sqlite3
import os
from datetime import datetime

# Store DB in user home directory so the packaged Mac App has write access
DB_DIR = os.path.expanduser("~/.physics_study_app")
os.makedirs(DB_DIR, exist_ok=True)
DB_FILE = os.path.join(DB_DIR, "physics_study.db")

def get_connection():
    return sqlite3.connect(DB_FILE)

def log_activity(activity_type):
    conn = get_connection()
    c = conn.cursor()
    c.execute("INSERT INTO activity_log (activity_type, timestamp) VALUES (?, ?)", (activity_type, datetime.now().isoformat()))
    conn.commit()
    conn.close()

def setup_database():
    conn = get_connection()
    cursor = conn.cursor()

    # Modules Table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS modules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            code TEXT UNIQUE,
            name TEXT,
            semester INTEGER,
            year INTEGER DEFAULT 1
        )
    ''')

    # Schema migration: Add year column to existing modules if missing
    try:
        cursor.execute("ALTER TABLE modules ADD COLUMN year INTEGER DEFAULT 1")
    except sqlite3.OperationalError:
        pass

    # Topics Table (Weeks)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS topics (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_id INTEGER,
            week INTEGER,
            name TEXT,
            FOREIGN KEY (module_id) REFERENCES modules(id)
        )
    ''')

    # Notes/PDFs Table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic_id INTEGER,
            file_path TEXT,
            title TEXT,
            ai_summary TEXT,
            pre_lecture_primer TEXT,
            FOREIGN KEY (topic_id) REFERENCES topics(id)
        )
    ''')
    
    # Schema migration: Add ai_summary column to existing databases if missing
    try:
        cursor.execute("ALTER TABLE notes ADD COLUMN ai_summary TEXT")
    except sqlite3.OperationalError:
        pass


    # Schema migration: Add pre_lecture_primer column to existing databases if missing
    try:
        cursor.execute("ALTER TABLE notes ADD COLUMN pre_lecture_primer TEXT")
    except sqlite3.OperationalError:
        pass

    # Schema migration: Add created_date column to existing flashcards database if missing
    try:
        cursor.execute("ALTER TABLE flashcards ADD COLUMN created_date TEXT")
        import datetime
        today = datetime.date.today().isoformat()
        cursor.execute("UPDATE flashcards SET created_date = ? WHERE created_date IS NULL", (today,))
    except sqlite3.OperationalError:
        pass

    # Flashcards Table (Spaced Repetition)
    cursor.execute('''
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
        )
    ''')

    # Problems Table (Interleaving)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS problems (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            topic_id INTEGER,
            content TEXT,
            solution_hint TEXT,
            created_date TEXT,
            solved_count INTEGER DEFAULT 0,
            FOREIGN KEY (topic_id) REFERENCES topics(id)
        )
    ''')

    # Schema migration: Add created_date and solved_count to problems if they are missing
    try:
        cursor.execute("ALTER TABLE problems ADD COLUMN created_date TEXT")
        import datetime
        today = datetime.date.today().isoformat()
        cursor.execute("UPDATE problems SET created_date = ? WHERE created_date IS NULL", (today,))
    except sqlite3.OperationalError:
        pass

    try:
        cursor.execute("ALTER TABLE problems ADD COLUMN solved_count INTEGER DEFAULT 0")
    except sqlite3.OperationalError:
        pass

    # Feynman Sessions Table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS feynman_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            module_id INTEGER,
            concept TEXT,
            explanation TEXT,
            created_date TEXT,
            FOREIGN KEY (module_id) REFERENCES modules(id)
        )
    ''')


    # Activity Log
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS activity_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            activity_type TEXT,
            timestamp TEXT
        )
    ''')

    # Daily Study Time Table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS daily_study_time (
            date TEXT PRIMARY KEY,
            flashcards_seconds INTEGER DEFAULT 0,
            problems_seconds INTEGER DEFAULT 0
        )
    ''')

    # Module Study Time Table
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS module_study_time (
            module_id INTEGER,
            date TEXT,
            flashcards_seconds INTEGER DEFAULT 0,
            problems_seconds INTEGER DEFAULT 0,
            PRIMARY KEY (module_id, date),
            FOREIGN KEY (module_id) REFERENCES modules(id)
        )
    ''')

    # Feynman Chats Table (Interactive Dialogue)
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS feynman_chats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER,
            role TEXT,
            content TEXT,
            timestamp TEXT,
            FOREIGN KEY (note_id) REFERENCES notes(id)
        )
    ''')

    # App settings table for persisting preferences like active year/module
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    ''')

    conn.commit()

    conn.close()

def get_today_study_time():
    import datetime
    today = datetime.date.today().isoformat()
    conn = get_connection()
    c = conn.cursor()
    c.execute("SELECT flashcards_seconds, problems_seconds FROM daily_study_time WHERE date = ?", (today,))
    row = c.fetchone()
    conn.close()
    if row:
        return row[0], row[1]
    return 0, 0

def add_study_time(flashcards_delta, problems_delta):
    import datetime
    today = datetime.date.today().isoformat()
    conn = get_connection()
    c = conn.cursor()
    c.execute("SELECT flashcards_seconds, problems_seconds FROM daily_study_time WHERE date = ?", (today,))
    row = c.fetchone()
    if row:
        c.execute("UPDATE daily_study_time SET flashcards_seconds = ?, problems_seconds = ? WHERE date = ?",
                  (row[0] + flashcards_delta, row[1] + problems_delta, today))
    else:
        c.execute("INSERT INTO daily_study_time (date, flashcards_seconds, problems_seconds) VALUES (?, ?, ?)",
                  (today, flashcards_delta, problems_delta))
    conn.commit()
    conn.close()

def add_module_study_time(module_id, flashcards_delta, problems_delta):
    import datetime
    today = datetime.date.today().isoformat()
    conn = get_connection()
    c = conn.cursor()
    c.execute("""
        SELECT flashcards_seconds, problems_seconds 
        FROM module_study_time 
        WHERE module_id = ? AND date = ?
    """, (module_id, today))
    row = c.fetchone()
    if row:
        c.execute("""
            UPDATE module_study_time 
            SET flashcards_seconds = ?, problems_seconds = ? 
            WHERE module_id = ? AND date = ?
        """, (row[0] + flashcards_delta, row[1] + problems_delta, module_id, today))
    else:
        c.execute("""
            INSERT INTO module_study_time (module_id, date, flashcards_seconds, problems_seconds) 
            VALUES (?, ?, ?, ?)
        """, (module_id, today, flashcards_delta, problems_delta))
    conn.commit()
    conn.close()

def get_setting(key, default=None):
    try:
        conn = get_connection()
        c = conn.cursor()
        c.execute("SELECT value FROM app_settings WHERE key = ?", (key,))
        row = c.fetchone()
        conn.close()
        return row[0] if row else default
    except sqlite3.OperationalError:
        return default

def set_setting(key, value):
    try:
        conn = get_connection()
        c = conn.cursor()
        c.execute("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)", (key, str(value) if value is not None else ""))
        conn.commit()
        conn.close()
    except sqlite3.OperationalError:
        pass

if __name__ == "__main__":
    setup_database()
    print("Database setup complete.")
