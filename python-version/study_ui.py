import customtkinter as ctk
import database
import os
import fitz  # PyMuPDF
from PIL import Image, ImageTk
import sys
import threading
import urllib.request
import json
import ai_helper

class StudyView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(0, weight=1)
        
        self.study_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.study_frame.grid(row=0, column=0, sticky="nsew")
        self.study_frame.grid_rowconfigure(1, weight=1)
        self.study_frame.grid_columnconfigure(0, weight=1)
        
        self.generating_notes = set()
        
        self.build_study_ui()
        self.reset_view()

    def build_study_ui(self):
        # Top Bar
        top_bar = ctk.CTkFrame(self.study_frame, fg_color="transparent")
        top_bar.grid(row=0, column=0, sticky="ew", padx=20, pady=20)
        
        self.study_module_title = ctk.CTkLabel(top_bar, text="", font=("SF Pro Display", 24, "bold"))
        self.study_module_title.pack(side="left")
        
        # Split view
        self.split_frame = ctk.CTkFrame(self.study_frame, fg_color="transparent")
        self.split_frame.grid(row=1, column=0, sticky="nsew", padx=20, pady=(0, 20))
        
        self.split_frame.grid_rowconfigure(0, weight=1)
        self.split_frame.grid_columnconfigure(0, weight=1) # Notes list
        self.split_frame.grid_columnconfigure(1, weight=3) # Right Pane
        
        # Left Pane (Notes)
        self.notes_list_frame = ctk.CTkScrollableFrame(self.split_frame)
        self.notes_list_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        
        # Right Pane
        self.pdf_frame = ctk.CTkFrame(self.split_frame)
        self.pdf_frame.grid(row=0, column=1, sticky="nsew")
        self.pdf_frame.grid_rowconfigure(0, weight=1)
        self.pdf_frame.grid_columnconfigure(0, weight=1)
        
        # Scrollable area
        self.pdf_scroll_area = ctk.CTkScrollableFrame(self.pdf_frame, fg_color="transparent")
        self.pdf_scroll_area.grid(row=0, column=0, sticky="nsew", padx=10, pady=10)
        
        # AI Summary Card (packed dynamically, initially hidden)
        self.summary_card = ctk.CTkFrame(self.pdf_scroll_area, fg_color="#F2F2F7", corner_radius=12)
        self.summary_card.grid_columnconfigure(0, weight=1)
        
        # Redo Button (top-left, small and low-contrast grey)
        self.redo_btn = ctk.CTkButton(self.summary_card, text="↻ Redo", width=45, height=20, fg_color="transparent", text_color="#8E8E93", hover_color="#E5E5EA", font=("SF Pro Display", 11), anchor="w", command=self.regenerate_summary)
        self.redo_btn.grid(row=0, column=0, padx=15, pady=(10, 5), sticky="w")
        
        self.summary_text = ctk.CTkLabel(self.summary_card, text="", font=("SF Pro Display", 13), justify="left", text_color="#3A3A3C")
        self.summary_text.grid(row=1, column=0, padx=15, pady=(0, 15), sticky="w")
        
        def adjust_wrap(event):
            self.summary_text.configure(wraplength=max(300, event.width - 30))
        self.summary_card.bind("<Configure>", adjust_wrap)
        
        # Action Frame containing View PDF Button (packed dynamically, initially hidden)
        self.action_frame = ctk.CTkFrame(self.pdf_scroll_area, fg_color="transparent")
        
        # View PDF Button
        self.view_pdf_btn = ctk.CTkButton(
            self.action_frame, 
            text="View PDF", 
            font=("SF Pro Display", 15, "bold"),
            fg_color="#007AFF", 
            text_color="white", 
            hover_color="#0056B3",
            height=45,
            width=150,
            command=self.open_fullscreen_pdf
        )
        self.view_pdf_btn.pack(side="left", pady=10)
        
        # Placeholder Label (packed initially)
        self.placeholder_label = ctk.CTkLabel(
            self.pdf_scroll_area, 
            text="Select a note to view summary", 
            text_color="gray",
            font=("SF Pro Display", 14)
        )
        self.placeholder_label.pack(fill="both", expand=True, pady=40)
        
        # Store PDF state
        self.current_pdf_path = None
        self.current_note_id = None

    def reset_view(self):
        self.summary_card.pack_forget()
        self.action_frame.pack_forget()
        self.placeholder_label.configure(text="Select a note to view summary")
        self.placeholder_label.pack(fill="both", expand=True, pady=40)
        self.current_pdf_path = None
        self.current_note_id = None

    def load_pdf(self, path, note_id):
        if not os.path.exists(path):
            self.placeholder_label.configure(text=f"PDF file not found at: {path}")
            self.placeholder_label.pack(fill="both", expand=True, pady=40)
            self.summary_card.pack_forget()
            self.action_frame.pack_forget()
            return
            
        try:
            self.current_pdf_path = path
            self.current_note_id = note_id
            
            # Hide placeholder and show panels
            self.placeholder_label.pack_forget()
            self.summary_card.pack(fill="x", padx=10, pady=(10, 5))
            self.action_frame.pack(fill="x", padx=10, pady=(5, 10))
            
            # Check database cache for summary
            cached_summary = self.get_cached_summary(note_id)
            
            if cached_summary:
                self.generating_summary = False
                self.summary_text.configure(text=cached_summary)
            else:
                # Trigger loading states
                self.generating_summary = True
                self.animate_loading()
                
                # Trigger async analysis in a background thread if not already running
                if note_id not in self.generating_notes:
                    self.generating_notes.add(note_id)
                    threading.Thread(target=self.generate_ai_async, args=(note_id,), name=f"AI_Summary_{note_id}", daemon=True).start()
            
        except Exception as e:
            self.placeholder_label.configure(text=f"Error loading Note:\n{e}")
            self.placeholder_label.pack(fill="both", expand=True, pady=40)
            self.summary_card.pack_forget()
            self.action_frame.pack_forget()

    def get_cached_summary(self, note_id):
        try:
            conn = database.get_connection()
            c = conn.cursor()
            c.execute("SELECT ai_summary FROM notes WHERE id = ?", (note_id,))
            row = c.fetchone()
            conn.close()
            if row and row[0]:
                return row[0].strip()
        except Exception as e:
            print(f"Error reading cache from db: {e}")
        return None


    def animate_loading(self, step=0):
        if not hasattr(self, "generating_summary") or not self.generating_summary:
            return
        dots = "." * (step % 4)
        self.summary_text.configure(text=f"Generating AI summary{dots}")
        self.after(500, lambda: self.animate_loading(step + 1))


    def regenerate_summary(self):
        if not hasattr(self, "current_note_id") or not self.current_note_id:
            return
            
        # Clear cache in database
        try:
            conn = database.get_connection()
            c = conn.cursor()
            c.execute("UPDATE notes SET ai_summary = NULL WHERE id = ?", (self.current_note_id,))
            conn.commit()
            conn.close()
        except Exception as e:
            print(f"Error clearing cache in db: {e}")
            
        # Re-trigger load_pdf with current path and note ID
        if self.current_pdf_path:
            self.load_pdf(self.current_pdf_path, self.current_note_id)

    def generate_ai_async(self, note_id):
        try:
            ai_helper.process_note_sync(note_id)
        except Exception as e:
            print(f"Error in generate_ai_async: {e}")
        finally:
            if note_id in self.generating_notes:
                self.generating_notes.remove(note_id)
            
            # If the note is still selected in the UI, update the views
            if hasattr(self, "current_note_id") and self.current_note_id == note_id:
                summary = self.get_cached_summary(note_id)
                self.generating_summary = False
                
                if not summary:
                    summary = "Failed to generate AI summary. Ensure Ollama is running and try again."
                    
                self.after(0, lambda: self.summary_text.configure(text=summary))

    def open_fullscreen_pdf(self, event=None):
        if self.current_pdf_path and os.path.exists(self.current_pdf_path):
            import subprocess
            subprocess.Popen(['open', self.current_pdf_path])

    def update_active_module(self, module_id):
        if not module_id:
            self.study_module_title.configure(text="No Modules Found")
            for widget in self.notes_list_frame.winfo_children():
                widget.destroy()
            self.reset_view()
            ctk.CTkLabel(self.notes_list_frame, text="Create a module first using Edit -> Manage Modules.", text_color="gray").pack(pady=20)
            return

        # We need to find the name of the module for the title
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT code, name FROM modules WHERE id = ?", (module_id,))
        row = c.fetchone()
        conn.close()
        
        if row:
            module_name = f"{row[0]}: {row[1]}"
            self.study_module_title.configure(text=module_name)
            
            # Load notes for this module
            for widget in self.notes_list_frame.winfo_children():
                widget.destroy()
                
            conn = database.get_connection()
            c = conn.cursor()
            c.execute('''
                SELECT n.id, n.title, n.file_path, t.name 
                FROM notes n
                JOIN topics t ON n.topic_id = t.id
                WHERE t.module_id = ?
            ''', (module_id,))
            notes = c.fetchall()
            conn.close()
            
            # Reset PDF preview on active module change
            self.reset_view()
            
            if not notes:
                ctk.CTkLabel(self.notes_list_frame, text="No notes uploaded.", text_color="gray").pack(pady=20)
                return
                
            for n_id, title, file_path, week_name in notes:
                btn = ctk.CTkButton(self.notes_list_frame, text=f"{title}", anchor="w", fg_color="transparent", text_color="black", hover_color="#E5E5EA",
                                    command=lambda path=file_path, nid=n_id: self.load_pdf(path, nid))
                btn.pack(fill="x", pady=2, padx=5)

