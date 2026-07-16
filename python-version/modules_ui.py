import customtkinter as ctk
import database
import os
import subprocess
from tkinter import filedialog
import sys
import threading
import ai_helper

class ModulesView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(2, weight=1)
        self.grid_columnconfigure(0, weight=1)
        
        self.header = ctk.CTkLabel(self, text="Notes & Topics", font=("SF Pro Display", 28, "bold"))
        self.header.grid(row=0, column=0, padx=30, pady=(30, 10), sticky="nw")

        # Top Control Bar
        self.controls_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.controls_frame.grid(row=1, column=0, padx=30, pady=10, sticky="ew")

        self.upload_btn = ctk.CTkButton(self.controls_frame, text="Link PDF File(s)", state="disabled", command=self.upload_note)
        self.upload_btn.pack(side="left", padx=(0, 10))

        self.link_folder_btn = ctk.CTkButton(self.controls_frame, text="Link Notes Folder", state="disabled", command=self.link_folder)
        self.link_folder_btn.pack(side="left")

        # Notes Listbox (Scrollable Frame)
        self.notes_frame = ctk.CTkScrollableFrame(self, label_text="Linked Notes & Lectures")
        self.notes_frame.grid(row=2, column=0, padx=30, pady=(10, 30), sticky="nsew")

        self.note_widgets = []
        self.modules = {}
        self.load_modules()
        
        # Get active module on load
        if hasattr(self.master, "master") and hasattr(self.master.master, "active_module_id"):
            self.current_mod_id = self.master.master.active_module_id
        else:
            self.current_mod_id = None

        if self.current_mod_id:
            self.upload_btn.configure(state="normal")
            self.link_folder_btn.configure(state="normal")
            self.refresh_notes()

    def load_modules(self):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT id, code, name FROM modules ORDER BY semester ASC, code ASC")
        for row in c.fetchall():
            self.modules[f"{row[1]} - {row[2]}"] = row[0]
        conn.close()

    def update_active_module(self, module_id):
        self.current_mod_id = module_id
        self.upload_btn.configure(state="normal")
        self.link_folder_btn.configure(state="normal")
        self.refresh_notes()

    def refresh_notes(self):
        for widget in self.note_widgets:
            widget.destroy()
        self.note_widgets.clear()

        if not self.current_mod_id:
            return

        conn = database.get_connection()
        c = conn.cursor()
        # Join topics and notes since each upload creates one topic and one note
        c.execute("""
            SELECT t.id, t.name, n.file_path, n.id 
            FROM topics t 
            JOIN notes n ON t.id = n.topic_id 
            WHERE t.module_id = ? 
            ORDER BY t.week ASC, t.id ASC
        """, (self.current_mod_id,))
        
        for row in c.fetchall():
            topic_id, title, path, note_id = row
            filename = os.path.basename(path)
            
            frame = ctk.CTkFrame(self.notes_frame)
            frame.pack(fill="x", pady=5, padx=5)
            
            # File Info
            lbl = ctk.CTkLabel(frame, text=filename, font=("SF Pro Display", 12, "italic"), text_color="gray")
            lbl.pack(side="left", padx=10, pady=10)
            
            # Title Editor
            title_entry = ctk.CTkEntry(frame, width=300)
            title_entry.insert(0, title)
            title_entry.pack(side="left", padx=10, pady=10, fill="x", expand=True)
            
            save_btn = ctk.CTkButton(frame, text="Save Title", width=80, fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E",
                                     command=lambda tid=topic_id, nid=note_id, ent=title_entry, sbtn=frame: self.save_title(tid, nid, ent, sbtn))
            save_btn.pack(side="left", padx=5, pady=10)
            
            open_btn = ctk.CTkButton(frame, text="Open PDF", width=80, command=lambda p=path: self.open_pdf(p))
            open_btn.pack(side="left", padx=5, pady=10)
            
            del_btn = ctk.CTkButton(frame, text="Delete", width=60, fg_color="#FF3B30", hover_color="#D70015", 
                                    command=lambda tid=topic_id, nid=note_id: self.delete_note(tid, nid))
            del_btn.pack(side="right", padx=10, pady=10)
            
            # Mac trackpad fix: explicitly bind scroll so hovering over Entry doesn't swallow the event
            def make_scroll(event):
                if sys.platform == "darwin":
                    # Pass the float delta directly to avoid truncation of small trackpad movements
                    self.notes_frame._parent_canvas.yview("scroll", -event.delta, "units")
                else:
                    self.notes_frame._parent_canvas.yview("scroll", int(-event.delta / 120), "units")
                    
            for w in [frame, title_entry, lbl, save_btn, open_btn, del_btn]:
                w.bind("<MouseWheel>", make_scroll)
            
            self.note_widgets.append(frame)
        conn.close()

    def delete_note(self, topic_id, note_id):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("DELETE FROM notes WHERE id = ?", (note_id,))
        c.execute("DELETE FROM topics WHERE id = ?", (topic_id,))
        conn.commit()
        conn.close()
        self.refresh_notes()

    def save_title(self, topic_id, note_id, entry_widget, frame):
        new_title = entry_widget.get().strip()
        if not new_title: return
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("UPDATE topics SET name = ? WHERE id = ?", (new_title, topic_id))
        c.execute("UPDATE notes SET title = ? WHERE id = ?", (new_title, note_id))
        conn.commit()
        conn.close()

        # Visual feedback
        btn = frame.winfo_children()[2]
        original_text = btn.cget("text")
        btn.configure(text="Saved!")
        self.after(1500, lambda: btn.configure(text=original_text))

    def upload_note(self):
        if not self.current_mod_id:
            return
            
        filepaths = filedialog.askopenfilenames(
            title="Select PDF Notes",
            filetypes=(("PDF Files", "*.pdf"), ("All Files", "*.*"))
        )
        
        if filepaths:
            conn = database.get_connection()
            c = conn.cursor()
            
            note_ids = []
            for filepath in filepaths:
                # Check if this file path is already linked for this module
                c.execute("""
                    SELECT n.id FROM notes n
                    JOIN topics t ON n.topic_id = t.id
                    WHERE t.module_id = ? AND n.file_path = ?
                """, (self.current_mod_id, filepath))
                if c.fetchone():
                    continue  # Already linked

                filename = os.path.basename(filepath)
                title = os.path.splitext(filename)[0]
                
                # Find max week for ordering
                c.execute("SELECT MAX(week) FROM topics WHERE module_id = ?", (self.current_mod_id,))
                res = c.fetchone()[0]
                next_week = (res or 0) + 1
                
                # Create a topic to act as the "Lecture" anchor for interleaving
                c.execute("INSERT INTO topics (module_id, week, name) VALUES (?, ?, ?)", (self.current_mod_id, next_week, title))
                topic_id = c.lastrowid
                
                # Create the note
                c.execute("INSERT INTO notes (topic_id, file_path, title) VALUES (?, ?, ?)", (topic_id, filepath, title))
                note_ids.append(c.lastrowid)
                
            conn.commit()
            conn.close()
            
            # Start background processing for all uploaded notes
            for note_id in note_ids:
                threading.Thread(target=ai_helper.process_note_sync, args=(note_id,), name=f"AI_Summary_{note_id}", daemon=True).start()
            
            self.refresh_notes()

    def link_folder(self):
        if not self.current_mod_id:
            return
            
        folderpath = filedialog.askdirectory(title="Select Folder holding Notes")
        if not folderpath:
            return
            
        # Scan folder for PDF files
        filepaths = []
        for root, dirs, files in os.walk(folderpath):
            for file in files:
                if file.lower().endswith(".pdf"):
                    filepaths.append(os.path.join(root, file))
                    
        # Sort files to maintain some order
        filepaths.sort()
        
        if filepaths:
            conn = database.get_connection()
            c = conn.cursor()
            note_ids = []
            for filepath in filepaths:
                filename = os.path.basename(filepath)
                title = os.path.splitext(filename)[0]
                
                # Check if this file path is already linked for this module
                c.execute("""
                    SELECT n.id FROM notes n
                    JOIN topics t ON n.topic_id = t.id
                    WHERE t.module_id = ? AND n.file_path = ?
                """, (self.current_mod_id, filepath))
                if c.fetchone():
                    continue  # Already linked
                
                # Find max week for ordering
                c.execute("SELECT MAX(week) FROM topics WHERE module_id = ?", (self.current_mod_id,))
                res = c.fetchone()[0]
                next_week = (res or 0) + 1
                
                # Create a topic to act as the "Lecture" anchor for interleaving
                c.execute("INSERT INTO topics (module_id, week, name) VALUES (?, ?, ?)", (self.current_mod_id, next_week, title))
                topic_id = c.lastrowid
                
                # Create the note
                c.execute("INSERT INTO notes (topic_id, file_path, title) VALUES (?, ?, ?)", (topic_id, filepath, title))
                note_ids.append(c.lastrowid)
                
            conn.commit()
            conn.close()
            
            # Start background processing for all linked notes
            for note_id in note_ids:
                threading.Thread(target=ai_helper.process_note_sync, args=(note_id,), name=f"AI_Summary_{note_id}", daemon=True).start()
                
            self.refresh_notes()

    def open_pdf(self, path):
        if os.path.exists(path):
            subprocess.Popen(['open', path])
        else:
            print(f"File not found: {path}")
