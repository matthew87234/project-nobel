import customtkinter as ctk
import database
import random
from ratio_tracker import RatioTrackerBar

class InterleavingAddView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(2, weight=1)
        self.grid_columnconfigure(1, weight=1)
        
        self.header = ctk.CTkLabel(self, text="Add New Problem", font=("SF Pro Display", 28, "bold"))
        self.header.grid(row=0, column=0, columnspan=2, padx=30, pady=30, sticky="nw")

        self.current_mod_id = None

        ctk.CTkLabel(self, text="Problem Content:", font=("SF Pro Display", 14, "bold")).grid(row=1, column=0, padx=30, pady=10, sticky="nw")
        self.content_box = ctk.CTkTextbox(self, height=150, border_width=1, fg_color="transparent")
        self.content_box.grid(row=1, column=1, padx=10, pady=10, sticky="ew")

        ctk.CTkLabel(self, text="Solution Hint:", font=("SF Pro Display", 14, "bold")).grid(row=2, column=0, padx=30, pady=10, sticky="nw")
        self.hint_box = ctk.CTkTextbox(self, height=100, border_width=1, fg_color="transparent")
        self.hint_box.grid(row=2, column=1, padx=10, pady=10, sticky="ew")

        self.save_btn = ctk.CTkButton(self, text="Save Problem", fg_color="#E5E5EA", hover_color="#2C2C2E", text_color=("black", "white"), command=self.save_problem)
        self.save_btn.grid(row=3, column=1, padx=10, pady=20, sticky="e")
        self.save_msg = ctk.CTkLabel(self, text="", font=("SF Pro Display", 14))
        self.save_msg.grid(row=3, column=1, padx=150, pady=20, sticky="e")

    def save_problem(self):
        mod_id = self.current_mod_id
        if not mod_id:
            return
            
        content = self.content_box.get("0.0", "end").strip()
        hint = self.hint_box.get("0.0", "end").strip()

        if not content:
            return

        conn = database.get_connection()
        c = conn.cursor()
        
        # Look up if there is any topic for this module
        c.execute("SELECT id FROM topics WHERE module_id = ? LIMIT 1", (mod_id,))
        row = c.fetchone()
        if row:
            topic_id = row[0]
        else:
            # Create a default topic named "General" for this module
            c.execute("INSERT INTO topics (module_id, week, name) VALUES (?, 1, 'General')", (mod_id,))
            topic_id = c.lastrowid
            
        import datetime
        today = datetime.date.today().isoformat()
        c.execute("INSERT INTO problems (topic_id, content, solution_hint, created_date, solved_count) VALUES (?, ?, ?, ?, 0)", (topic_id, content, hint, today))
        conn.commit()
        conn.close()

        self.content_box.delete("0.0", "end")
        self.hint_box.delete("0.0", "end")
        self.save_msg.configure(text="Saved!")

    def update_active_module(self, module_id):
        self.current_mod_id = module_id


class InterleavingReviewView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(3, weight=1)
        self.grid_columnconfigure(0, weight=1)
        
        self.header = ctk.CTkLabel(self, text="Interleaved Practice", font=("SF Pro Display", 28, "bold"))
        self.header.grid(row=0, column=0, padx=30, pady=(30, 10), sticky="nw")

        # 80/20 Study Ratio Tracker Bar
        self.ratio_bar = RatioTrackerBar(self)
        self.ratio_bar.grid(row=1, column=0, padx=30, pady=(0, 20), sticky="ew")

        self.study_info = ctk.CTkLabel(self, text="Interleaving mixes your problems up so you have to identify the method.", font=("SF Pro Display", 14))
        self.study_info.grid(row=2, column=0, pady=(0, 10))

        self.next_btn = ctk.CTkButton(self, text="Get Random Problem", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=self.load_random_problem)
        self.next_btn.grid(row=3, column=0, pady=10, sticky="n")

        self.prob_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.prob_frame.grid_columnconfigure(0, weight=1)
        
        self.module_label = ctk.CTkLabel(self.prob_frame, text="", font=("SF Pro Display", 16, "bold"))
        self.module_label.grid(row=0, column=0, pady=10, padx=10, sticky="w")
        
        self.prob_content = ctk.CTkTextbox(self.prob_frame, height=200, state="disabled", fg_color="transparent", border_width=1)
        self.prob_content.grid(row=1, column=0, pady=10, padx=20, sticky="ew")
        
        self.hint_btn = ctk.CTkButton(self.prob_frame, text="Show Hint", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=self.show_hint)
        self.hint_btn.grid(row=2, column=0, pady=10, sticky="w", padx=20)

        self.solve_btn = ctk.CTkButton(self.prob_frame, text="Mark as Solved", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=self.mark_solved)
        self.solve_btn.grid(row=2, column=0, pady=10, sticky="e", padx=20)

        self.prob_hint = ctk.CTkTextbox(self.prob_frame, height=100, state="disabled", fg_color="transparent", border_width=1)
        self.current_hint = ""
        self.current_mod_id = None

    def load_random_problem(self):
        mode = "General"
        if hasattr(self.master, "master") and hasattr(self.master.master, "study_mode"):
            mode = self.master.master.study_mode

        if mode == "Exam" and (not hasattr(self, "current_mod_id") or not self.current_mod_id):
            self.study_info.configure(text="No active module selected.")
            return

        conn = database.get_connection()
        c = conn.cursor()
        
        if mode == "Exam":
            c.execute("""
                SELECT problems.id, problems.content, problems.solution_hint, modules.code, topics.name 
                FROM problems 
                JOIN topics ON problems.topic_id = topics.id 
                JOIN modules ON topics.module_id = modules.id
                WHERE modules.id = ?
            """, (self.current_mod_id,))
        else:
            # General Mode: Mix all modules
            c.execute("""
                SELECT problems.id, problems.content, problems.solution_hint, modules.code, topics.name 
                FROM problems 
                JOIN topics ON problems.topic_id = topics.id 
                JOIN modules ON topics.module_id = modules.id
            """)
            
        problems = c.fetchall()
        conn.close()

        if not problems:
            self.study_info.configure(text="No problems found! Add some first.")
            self.current_problem_id = None
            return

        prob = random.choice(problems)
        prob_id, content, hint, mcode, tname = prob
        self.current_problem_id = prob_id
        
        self.prob_frame.grid(row=3, column=0, sticky="nsew", padx=20, pady=20)
        self.next_btn.grid_remove() # Hide the initial start button
        self.module_label.configure(text=f"? Random Selection ?") # Hide the source initially
        
        self.prob_content.configure(state="normal")
        self.prob_content.delete("0.0", "end")
        self.prob_content.insert("0.0", content)
        self.prob_content.configure(state="disabled")
        
        self.current_hint = f"Module: {mcode} | Topic: {tname}\n\nHint: {hint}"
        self.prob_hint.grid_remove()
        self.hint_btn.grid(row=2, column=0, pady=10, sticky="w", padx=20)

    def show_hint(self):
        self.hint_btn.grid_remove()
        self.prob_hint.grid(row=3, column=0, pady=10, padx=20, sticky="ew")
        self.prob_hint.configure(state="normal")
        self.prob_hint.delete("0.0", "end")
        self.prob_hint.insert("0.0", self.current_hint)
        self.prob_hint.configure(state="disabled")

    def mark_solved(self):
        if hasattr(self, "current_problem_id") and self.current_problem_id:
            conn = database.get_connection()
            c = conn.cursor()
            c.execute("UPDATE problems SET solved_count = solved_count + 1 WHERE id = ?", (self.current_problem_id,))
            conn.commit()
            conn.close()
            
        database.log_activity('interleaving')
        self.load_random_problem()

    def update_active_module(self, module_id):
        self.current_mod_id = module_id
        # Reset practice state
        self.prob_frame.grid_remove()
        self.next_btn.grid(row=3, column=0, pady=10, sticky="n")
        self.study_info.configure(text="Interleaving mixes your problems up so you have to identify the method.")
