import customtkinter as ctk
import tkinter as tk
import time
import threading
import datetime
import database
import ai_helper

class PostLectureView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(2, weight=1)
        self.grid_columnconfigure(0, weight=1)
        
        self.current_module_id = None
        self.current_note_id = None
        self.notes_list = []
        self.notes_map = {}
        self.chat_history = []
        
        # Timer state
        self.timer_running = False
        self.time_left = 300
        
        # --- HEADER ROW ---
        self.header_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.header_frame.grid(row=0, column=0, padx=30, pady=(30, 10), sticky="ew")
        
        self.header_label = ctk.CTkLabel(self.header_frame, text="Post-Lecture Study Center", font=("SF Pro Display", 28, "bold"))
        self.header_label.pack(side="left")
        
        # --- CONTROLS ROW ---
        self.controls_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.controls_frame.grid(row=1, column=0, padx=30, pady=10, sticky="ew")
        
        # Dropdowns
        ctk.CTkLabel(self.controls_frame, text="Lecture:", font=("SF Pro Display", 13, "bold")).pack(side="left", padx=(0, 5))
        
        self.note_dropdown = ctk.CTkOptionMenu(
            self.controls_frame,
            values=["No Lectures Found"],
            command=self.on_note_select,
            font=("SF Pro Display", 11),
            width=260
        )
        self.note_dropdown.pack(side="left", padx=(0, 20))
        
        # Segmented Button Mode Selector
        self.mode_selector = ctk.CTkSegmentedButton(
            self.controls_frame,
            values=["Summary Sandbox", "Dialogue Partner"],
            command=self.on_mode_change,
            font=("SF Pro Display", 12, "bold")
        )
        self.mode_selector.pack(side="right")
        self.mode_selector.set("Summary Sandbox")
        
        # --- PANELS CONTAINER ---
        self.panels_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.panels_frame.grid(row=2, column=0, sticky="nsew", padx=30, pady=(10, 30))
        self.panels_frame.grid_rowconfigure(0, weight=1)
        self.panels_frame.grid_columnconfigure(0, weight=1)
        
        # 1. Summary Sandbox View
        self.sandbox_frame = ctk.CTkFrame(self.panels_frame, fg_color="transparent")
        self.setup_sandbox_ui()
        
        # 2. Dialogue Partner View
        self.dialogue_frame = ctk.CTkFrame(self.panels_frame, fg_color="transparent")
        self.setup_dialogue_ui()
        
        # Load initial frame state
        self.on_mode_change("Summary Sandbox")
        
    def setup_sandbox_ui(self):
        self.sandbox_frame.grid_rowconfigure(1, weight=1)
        self.sandbox_frame.grid_columnconfigure(0, weight=1)
        self.sandbox_frame.grid_columnconfigure(1, weight=1)
        
        # Left: Explanation editor
        left_editor = ctk.CTkFrame(self.sandbox_frame, fg_color="transparent")
        left_editor.grid(row=0, column=0, rowspan=2, sticky="nsew", padx=(0, 15))
        left_editor.grid_rowconfigure(2, weight=1)
        left_editor.grid_columnconfigure(0, weight=1)
        
        ctk.CTkLabel(left_editor, text="EXPLAIN IT IN SIMPLE TERMS", font=("SF Pro Display", 11, "bold"), text_color="gray").grid(row=0, column=0, sticky="nw", pady=(0, 10))
        
        # Timer Bar
        timer_bar = ctk.CTkFrame(left_editor, fg_color="transparent")
        timer_bar.grid(row=1, column=0, sticky="ew", pady=(0, 10))
        
        self.timer_btn = ctk.CTkButton(timer_bar, text="Start 5 Min Timer", fg_color=("#E5E5EA", "#2C2C2E"), text_color=("black", "white"), hover_color=("#D1D1D6", "#3A3A3C"), command=self.toggle_timer, width=130)
        self.timer_btn.pack(side="left")
        
        self.timer_label = ctk.CTkLabel(timer_bar, text="05:00", font=("SF Pro Display", 18, "bold"), text_color="gray")
        self.timer_label.pack(side="left", padx=15)
        
        self.sandbox_textbox = ctk.CTkTextbox(left_editor, font=("SF Pro Display", 14), border_width=1, fg_color="transparent")
        self.sandbox_textbox.grid(row=2, column=0, sticky="nsew", pady=(0, 15))
        
        self.submit_btn = ctk.CTkButton(
            left_editor,
            text="Submit for AI Rating",
            fg_color="#007AFF",
            hover_color="#0A84FF",
            text_color="white",
            command=self.submit_summary_rating,
            font=("SF Pro Display", 13, "bold"),
            height=36
        )
        self.submit_btn.grid(row=3, column=0, sticky="ew")
        
        # Right: Feedback panel
        right_feedback = ctk.CTkFrame(self.sandbox_frame, fg_color="transparent")
        right_feedback.grid(row=0, column=1, rowspan=2, sticky="nsew", padx=(15, 0))
        right_feedback.grid_rowconfigure(1, weight=1)
        right_feedback.grid_columnconfigure(0, weight=1)
        
        ctk.CTkLabel(right_feedback, text="AI EVALUATION FEEDBACK", font=("SF Pro Display", 11, "bold"), text_color="gray").grid(row=0, column=0, sticky="nw", pady=(0, 10))
        
        self.feedback_textbox = ctk.CTkTextbox(right_feedback, font=("SF Pro Display", 13), border_width=1, fg_color="transparent")
        self.feedback_textbox.grid(row=1, column=0, sticky="nsew")
        self.feedback_textbox.insert("0.0", "Your summary rating and concepts assessment will appear here after submission.")
        self.feedback_textbox.configure(state="disabled")

    def setup_dialogue_ui(self):
        self.dialogue_frame.grid_rowconfigure(0, weight=1)
        self.dialogue_frame.grid_columnconfigure(0, weight=1)
        
        # Main vertical flow
        chat_container = ctk.CTkFrame(self.dialogue_frame, fg_color="transparent")
        chat_container.grid(row=0, column=0, sticky="nsew")
        chat_container.grid_rowconfigure(1, weight=1)
        chat_container.grid_columnconfigure(0, weight=1)
        
        # Header/Reset bar
        header_bar = ctk.CTkFrame(chat_container, fg_color="transparent")
        header_bar.grid(row=0, column=0, sticky="ew", pady=(0, 5))
        
        ctk.CTkLabel(header_bar, text="CONCEPT DIALOGUE PARTNER (STUDENT)", font=("SF Pro Display", 11, "bold"), text_color="gray").pack(side="left")
        
        self.reset_chat_btn = ctk.CTkButton(
            header_bar,
            text="Reset Conversation",
            fg_color="#FF3B30",
            hover_color="#E03B2F",
            text_color="white",
            command=self.reset_dialogue,
            width=130,
            font=("SF Pro Display", 11)
        )
        self.reset_chat_btn.pack(side="right")
        
        # Scrollable Chat Log
        self.chat_log = ctk.CTkScrollableFrame(chat_container, fg_color=("#F2F2F7", "#1C1C1E"), corner_radius=8)
        self.chat_log.grid(row=1, column=0, sticky="nsew", pady=5)
        
        # Entry Bar
        entry_bar = ctk.CTkFrame(chat_container, fg_color="transparent")
        entry_bar.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        
        self.chat_entry = ctk.CTkEntry(entry_bar, placeholder_text="Explain the concepts or answer the student's questions...", font=("SF Pro Display", 13))
        self.chat_entry.pack(side="left", fill="x", expand=True, padx=(0, 10))
        self.chat_entry.bind("<Return>", lambda e: self.send_chat_message())
        self.chat_entry.bind("<Command-Return>", lambda e: self.send_chat_message())
        
        self.send_btn = ctk.CTkButton(
            entry_bar,
            text="Send",
            fg_color="#007AFF",
            hover_color="#0A84FF",
            text_color="white",
            command=self.send_chat_message,
            width=80,
            font=("SF Pro Display", 13, "bold")
        )
        self.send_btn.pack(side="right")

    def on_mode_change(self, mode):
        if mode == "Summary Sandbox":
            self.dialogue_frame.grid_remove()
            self.sandbox_frame.grid(row=0, column=0, sticky="nsew")
        else:
            self.sandbox_frame.grid_remove()
            self.dialogue_frame.grid(row=0, column=0, sticky="nsew")
            self.refresh_chat_display()

    def update_active_module(self, module_id):
        self.current_module_id = module_id
        self.load_notes_list()

    def load_notes_list(self):
        if not self.current_module_id:
            return
            
        self.notes_map = {}
        self.notes_list = []
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            SELECT n.id, n.title, t.week 
            FROM notes n
            JOIN topics t ON n.topic_id = t.id
            WHERE t.module_id = ?
            ORDER BY t.week ASC, n.id ASC
        """, (self.current_module_id,))
        rows = c.fetchall()
        conn.close()
        
        for idx, (nid, title, week) in enumerate(rows):
            display_str = f"Wk {idx + 1} - {title}"
            self.notes_map[display_str] = nid
            self.notes_list.append(display_str)
            
        if self.notes_list:
            self.note_dropdown.configure(values=self.notes_list)
            self.note_dropdown.set(self.notes_list[0])
            self.on_note_select(self.notes_list[0])
        else:
            self.note_dropdown.configure(values=["No Lectures Found"])
            self.note_dropdown.set("No Lectures Found")
            self.current_note_id = None

    def on_note_select(self, choice):
        self.current_note_id = self.notes_map.get(choice)
        # Load conversation history for the selected note if we are in Dialogue Partner view
        if self.current_note_id:
            self.load_dialogue_history()
            if self.mode_selector.get() == "Dialogue Partner":
                self.refresh_chat_display()

    # --- SUMMARY SANDBOX LOGIC ---
    
    def toggle_timer(self):
        if self.timer_running:
            # Stop timer
            self.timer_running = False
            self.timer_btn.configure(text="Start 5 Min Timer")
            self.timer_label.configure(text_color="gray")
        else:
            if not self.current_note_id:
                return
            # Start timer
            self.time_left = 300
            self.timer_running = True
            self.timer_btn.configure(text="Stop Timer")
            self.timer_label.configure(text_color="red")
            self.sandbox_textbox.delete("0.0", "end")
            
            threading.Thread(target=self._run_timer_loop, daemon=True).start()

    def _run_timer_loop(self):
        while self.time_left > 0 and self.timer_running:
            mins, secs = divmod(self.time_left, 60)
            self.timer_label.configure(text=f"{mins:02d}:{secs:02d}")
            time.sleep(1)
            self.time_left -= 1
            
        if self.time_left <= 0:
            self.timer_label.configure(text="00:00", text_color="gray")
            self.timer_running = False
            self.timer_btn.configure(text="Start 5 Min Timer")
            # Automatically trigger rating when timer expires
            self.submit_summary_rating()

    def submit_summary_rating(self):
        if not self.current_note_id:
            return
            
        summary_text = self.sandbox_textbox.get("0.0", "end").strip()
        if not summary_text:
            return
            
        self.submit_btn.configure(state="disabled", text="Evaluating summary...")
        self.feedback_textbox.configure(state="normal")
        self.feedback_textbox.delete("0.0", "end")
        self.feedback_textbox.insert("0.0", "Analyzing your explanation against lecture concepts. Please wait...")
        self.feedback_textbox.configure(state="disabled")
        
        threading.Thread(target=self._eval_summary_worker, args=(summary_text,), daemon=True).start()

    def _eval_summary_worker(self, summary_text):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT title, ai_summary FROM notes WHERE id = ?", (self.current_note_id,))
        row = c.fetchone()
        conn.close()
        
        if not row:
            self.submit_btn.configure(state="normal", text="Submit for AI Rating")
            return
            
        title, ai_summary = row
        if not ai_summary:
            ai_summary = "No reference summary available. Evaluate general correctness."
            
        # Call Ollama
        response = ai_helper.evaluate_feynman_summary(summary_text, title, ai_summary)
        
        if response:
            self.feedback_textbox.configure(state="normal")
            self.feedback_textbox.delete("0.0", "end")
            self.feedback_textbox.insert("0.0", response)
            self.feedback_textbox.configure(state="disabled")
            
            # Log this as an activity
            database.log_activity('feynman')
        else:
            self.feedback_textbox.configure(state="normal")
            self.feedback_textbox.delete("0.0", "end")
            self.feedback_textbox.insert("0.0", "Error: AI evaluation failed or timed out. Please try again.")
            self.feedback_textbox.configure(state="disabled")
            
        self.submit_btn.configure(state="normal", text="Submit for AI Rating")

    # --- DIALOGUE PARTNER LOGIC ---

    def load_dialogue_history(self):
        if not self.current_note_id:
            self.chat_history = []
            return
            
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT role, content FROM feynman_chats WHERE note_id = ? ORDER BY id ASC", (self.current_note_id,))
        rows = c.fetchall()
        conn.close()
        
        self.chat_history = [{'role': r, 'content': cnt} for r, cnt in rows]
        
        # If empty, initialize welcoming message from student
        if not self.chat_history:
            placeholder = "Hey! Give me a second to look over the summary and ask you a question..."
            self.chat_history.append({'role': 'assistant', 'content': placeholder})
            self.save_dialogue_msg('assistant', placeholder)
            threading.Thread(target=self._generate_welcome_question, daemon=True).start()

    def _generate_welcome_question(self):
        note_id = self.current_note_id
        if not note_id:
            return
            
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT title, ai_summary FROM notes WHERE id = ?", (note_id,))
        row = c.fetchone()
        conn.close()
        
        if not row:
            return
            
        title, ai_summary = row
        if not ai_summary:
            ai_summary = "No reference summary available."
            
        question = ai_helper.generate_feynman_starting_question(title, ai_summary)
        if not question:
            question = "Hey! What is the main physical concept introduced in this lecture?"
            
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("UPDATE feynman_chats SET content = ? WHERE note_id = ? AND content LIKE 'Hey! Give me a second%'", (question, note_id))
        conn.commit()
        conn.close()
        
        if self.current_note_id == note_id:
            for msg in self.chat_history:
                if msg['role'] == 'assistant' and msg['content'].startswith("Hey! Give me a second"):
                    msg['content'] = question
                    break
            self.refresh_chat_display()

    def save_dialogue_msg(self, role, content):
        if not self.current_note_id:
            return
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            INSERT INTO feynman_chats (note_id, role, content, timestamp) 
            VALUES (?, ?, ?, ?)
        """, (self.current_note_id, role, content, datetime.datetime.now().isoformat()))
        conn.commit()
        conn.close()

    def reset_dialogue(self):
        if not self.current_note_id:
            return
            
        if tk.messagebox.askyesno("Reset Conversation", "Are you sure you want to reset the dialogue history for this note?", parent=self):
            conn = database.get_connection()
            c = conn.cursor()
            c.execute("DELETE FROM feynman_chats WHERE note_id = ?", (self.current_note_id,))
            conn.commit()
            conn.close()
            
            self.load_dialogue_history()
            self.refresh_chat_display()

    def refresh_chat_display(self):
        # Clear chat log frame
        for widget in self.chat_log.winfo_children():
            widget.destroy()
            
        # Draw messages
        for msg in self.chat_history:
            role = msg['role']
            content = msg['content']
            
            # Message container
            msg_frame = ctk.CTkFrame(self.chat_log, fg_color="transparent")
            
            # Select bubble design
            if role == 'user':
                bubble_color = "#007AFF"
                text_color = "white"
                anchor_side = "e"
                align_padding = (60, 5) # Indent on left side
            else:
                bubble_color = self._apply_appearance_mode(("#E5E5EA", "#2C2C2E"))
                text_color = self._apply_appearance_mode(("black", "white"))
                anchor_side = "w"
                align_padding = (5, 60) # Indent on right side
                
            msg_frame.pack(fill="x", anchor=anchor_side, padx=10, pady=5)
            
            # Bubble frame
            bubble = ctk.CTkFrame(msg_frame, fg_color=bubble_color, corner_radius=12)
            bubble.pack(side="right" if role == "user" else "left", padx=5)
            
            # Label
            lbl = ctk.CTkLabel(bubble, text=content, text_color=text_color, font=("SF Pro Display", 13), wraplength=480, justify="left", anchor="w")
            lbl.pack(padx=12, pady=8)
            
        # Scroll to bottom
        self.chat_log._parent_canvas.yview_moveto(1.0)

    def send_chat_message(self):
        if not self.current_note_id:
            return
            
        text = self.chat_entry.get().strip()
        if not text:
            return
            
        self.chat_entry.delete(0, 'end')
        
        # Append and save user message
        self.chat_history.append({'role': 'user', 'content': text})
        self.save_dialogue_msg('user', text)
        self.refresh_chat_display()
        
        # Log study session activity
        database.log_activity('feynman')
        
        # Disable input while waiting for student
        self.chat_entry.configure(state="disabled")
        self.send_btn.configure(state="disabled", text="Typing...")
        
        # Run AI response generation in background
        threading.Thread(target=self._generate_student_reply, daemon=True).start()

    def _generate_student_reply(self):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT title, ai_summary FROM notes WHERE id = ?", (self.current_note_id,))
        row = c.fetchone()
        conn.close()
        
        if not row:
            self.chat_entry.configure(state="normal")
            self.send_btn.configure(state="normal", text="Send")
            return
            
        title, ai_summary = row
        if not ai_summary:
            ai_summary = "No reference summary available."
            
        # Call Ollama
        reply = ai_helper.get_feynman_dialogue_response(title, ai_summary, self.chat_history)
        
        if reply:
            self.chat_history.append({'role': 'assistant', 'content': reply})
            self.save_dialogue_msg('assistant', reply)
            self.refresh_chat_display()
        else:
            error_msg = "Sorry, I had a hard time understanding that concept. Could you explain it again?"
            self.chat_history.append({'role': 'assistant', 'content': error_msg})
            self.save_dialogue_msg('assistant', error_msg)
            self.refresh_chat_display()
            
        self.chat_entry.configure(state="normal")
        self.send_btn.configure(state="normal", text="Send")
        self.chat_entry.focus_set()
