import customtkinter as ctk
import database
import os
import threading
import re
import ai_helper

class PreLectureView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(0, weight=1)
        
        self.active_module_id = None
        self.notes_list = []
        self.generating_primer = False
        
        self.build_ui()
        self.reset_view()

    def build_ui(self):
        # Top Bar
        self.top_bar = ctk.CTkFrame(self, fg_color="transparent")
        self.top_bar.pack(fill="x", padx=20, pady=20)
        
        self.title_label = ctk.CTkLabel(self.top_bar, text="Pre-Lecture Primer", font=("SF Pro Display", 24, "bold"))
        self.title_label.pack(side="left")
        
        self.status_label = ctk.CTkLabel(self.top_bar, text="", font=("SF Pro Display", 13, "italic"), text_color="gray")
        self.status_label.pack(side="right", padx=10)
        
        # Split Pane
        self.split_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.split_frame.pack(fill="both", expand=True, padx=20, pady=(0, 20))
        
        self.split_frame.grid_rowconfigure(0, weight=1)
        self.split_frame.grid_columnconfigure(0, weight=1) # Lectures List
        self.split_frame.grid_columnconfigure(1, weight=3) # Content area
        
        # Left Pane (Lectures List)
        self.lectures_list_frame = ctk.CTkScrollableFrame(self.split_frame)
        self.lectures_list_frame.grid(row=0, column=0, sticky="nsew", padx=(0, 10))
        
        # Right Pane (Content scrollable)
        self.primer_frame = ctk.CTkFrame(self.split_frame)
        self.primer_frame.grid(row=0, column=1, sticky="nsew")
        self.primer_frame.grid_rowconfigure(0, weight=1)
        self.primer_frame.grid_columnconfigure(0, weight=1)
        
        self.primer_scroll_area = ctk.CTkScrollableFrame(self.primer_frame, fg_color="transparent")
        self.primer_scroll_area.grid(row=0, column=0, sticky="nsew", padx=10, pady=10)
        
        # Placeholder
        self.placeholder_label = ctk.CTkLabel(
            self.primer_scroll_area,
            text="Select a lecture to view the Pre-Lecture Primer",
            text_color="gray",
            font=("SF Pro Display", 14)
        )
        self.placeholder_label.pack(fill="both", expand=True, pady=40)

    def reset_view(self):
        # Clear content and show placeholder
        for widget in self.primer_scroll_area.winfo_children():
            widget.destroy()
        self.placeholder_label = ctk.CTkLabel(
            self.primer_scroll_area,
            text="Select a lecture to view the Pre-Lecture Primer",
            text_color="gray",
            font=("SF Pro Display", 14)
        )
        self.placeholder_label.pack(fill="both", expand=True, pady=40)
        self.status_label.configure(text="")
        self.generating_primer = False

    def update_active_module(self, module_id):
        self.active_module_id = module_id
        
        # Fetch module name
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT code, name FROM modules WHERE id = ?", (module_id,))
        row = c.fetchone()
        conn.close()
        
        if row:
            self.title_label.configure(text=f"{row[0]}: {row[1]}")
            
        self.load_lectures()

    def load_lectures(self):
        # Clear existing list buttons
        for widget in self.lectures_list_frame.winfo_children():
            widget.destroy()
            
        if not self.active_module_id:
            return
            
        # Get all notes/lectures for this module
        conn = database.get_connection()
        c = conn.cursor()
        c.execute('''
            SELECT n.id, n.title, n.file_path, t.week, t.name
            FROM notes n
            JOIN topics t ON n.topic_id = t.id
            WHERE t.module_id = ?
            ORDER BY t.week ASC, n.id ASC
        ''', (self.active_module_id,))
        self.notes_list = c.fetchall()
        conn.close()
        
        self.reset_view()
        
        if not self.notes_list:
            ctk.CTkLabel(self.lectures_list_frame, text="No notes uploaded.", text_color="gray").pack(pady=20)
            return
            
        # Draw buttons
        self.lecture_buttons = {}
        for idx, (n_id, title, file_path, week, week_name) in enumerate(self.notes_list):
            display_text = f"Week {idx + 1}: {title}"
            btn = ctk.CTkButton(
                self.lectures_list_frame, 
                text=display_text, 
                anchor="w", 
                fg_color="transparent", 
                text_color=("black", "white"), 
                hover_color=("#E5E5EA", "#2C2C2E"),
                command=lambda idx=idx: self.select_lecture(idx)
            )
            btn.pack(fill="x", pady=2, padx=5)
            self.lecture_buttons[idx] = btn

    def select_lecture(self, idx):
        # Stylize buttons to highlight active
        for key, btn in self.lecture_buttons.items():
            if key == idx:
                btn.configure(fg_color=("#E5E5EA", "#2C2C2E"))
            else:
                btn.configure(fg_color="transparent")
                
        # Trigger async AI primer loading
        curr_note_id = self.notes_list[idx][0]
        prev_note_id = self.notes_list[idx - 1][0] if idx > 0 else None
        
        self.placeholder_label.pack_forget()
        for widget in self.primer_scroll_area.winfo_children():
            widget.destroy()
            
        self.status_label.configure(text="⏳ Preparing AI pre-lecture primer...")
        self.generating_primer = True
        self.animate_loading()
        
        threading.Thread(
            target=self.generate_primer_async,
            args=(curr_note_id, prev_note_id),
            name=f"AI_Primer_{curr_note_id}",
            daemon=True
        ).start()

    def animate_loading(self, step=0):
        if not self.generating_primer:
            return
        # Clear/refresh wait message
        for widget in self.primer_scroll_area.winfo_children():
            widget.destroy()
            
        dots = "." * (step % 4)
        lbl = ctk.CTkLabel(
            self.primer_scroll_area, 
            text=f"Qwen is generating your Pre-Lecture Primer{dots}\n\n(Summarizing PDF slides and calculating connections...)", 
            font=("SF Pro Display", 14),
            text_color="gray",
            justify="center"
        )
        lbl.pack(pady=40)
        self.after(500, lambda: self.animate_loading(step + 1))

    def generate_primer_async(self, curr_id, prev_id):
        try:
            primer_text = ai_helper.generate_pre_lecture_primer(curr_id, prev_id)
        except Exception as e:
            print(f"Error generating pre-lecture primer: {e}")
            primer_text = None
            
        self.generating_primer = False
        self.after(0, lambda: self.finish_primer_generation(primer_text))

    def finish_primer_generation(self, primer_text):
        for widget in self.primer_scroll_area.winfo_children():
            widget.destroy()
            
        if not primer_text:
            self.status_label.configure(text="❌ Failed to generate primer.")
            ctk.CTkLabel(
                self.primer_scroll_area, 
                text="Failed to generate primer.\nMake sure Ollama is active with qwen2.5vl model.", 
                text_color="red"
            ).pack(pady=40)
            return
            
        self.status_label.configure(text="✅ Ready for lecture!")
        self.display_primer(primer_text)

    def display_primer(self, text):
        # Split text into sections using regex matching [Section Name]
        sections = re.split(r'(\[[^\]\n]+\])', text)
        
        current_header = None
        current_content = []
        
        def render_section(header, content_lines):
            content = "\n".join(content_lines).strip()
            if not content:
                return
                
            # Create Card Container
            card = ctk.CTkFrame(self.primer_scroll_area, fg_color=("#F2F2F7", "#2C2C2E"), corner_radius=12)
            card.pack(fill="x", padx=10, pady=8)
            
            # Section Header (small, uppercase, gray)
            header_name = header.replace("[", "").replace("]", "").upper()
            lbl_hdr = ctk.CTkLabel(card, text=header_name, font=("SF Pro Display", 11, "bold"), text_color="gray")
            lbl_hdr.pack(anchor="w", padx=15, pady=(12, 4))
            
            # Section Content
            lbl_body = ctk.CTkLabel(card, text=content, font=("SF Pro Display", 14), justify="left", text_color=("#000000", "#FFFFFF"))
            lbl_body.pack(anchor="w", padx=15, pady=(0, 15))
            
            # Configure auto-wrap on window resize
            def adjust_wrap(event, l=lbl_body):
                l.configure(wraplength=max(300, event.width - 30))
            card.bind("<Configure>", adjust_wrap)

        for part in sections:
            part_str = part.strip()
            if not part_str:
                continue
            if part_str.startswith("[") and part_str.endswith("]"):
                if current_header:
                    render_section(current_header, current_content)
                current_header = part_str
                current_content = []
            else:
                if current_header:
                    current_content.append(part_str)
                    
        # Render remaining section
        if current_header and current_content:
            render_section(current_header, current_content)
