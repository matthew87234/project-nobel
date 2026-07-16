import customtkinter as ctk
import tkinter as tk
import database

class RatioTrackerBar(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        kwargs.setdefault("fg_color", "transparent")
        super().__init__(master, **kwargs)
        
        self.grid_columnconfigure(1, weight=1)
        self.grid_rowconfigure(0, weight=1)
        
        # Left Label (Flashcards time & percent)
        self.left_label = ctk.CTkLabel(
            self, 
            text="Flashcards: 0m (0%)", 
            font=("SF Pro Display", 11, "bold"),
            text_color=("black", "white")
        )
        self.left_label.grid(row=0, column=0, padx=(10, 15), sticky="w")
        
        # Canvas for the red/green slider bar
        self.canvas = tk.Canvas(self, height=18, bd=0, highlightthickness=0)
        self.canvas.grid(row=0, column=1, sticky="ew", pady=5)
        self.canvas.bind("<Configure>", lambda e: self.redraw())
        
        # Right Label (Problems time & percent)
        self.right_label = ctk.CTkLabel(
            self, 
            text="Problems: 0m (0%)", 
            font=("SF Pro Display", 11, "bold"),
            text_color=("black", "white")
        )
        self.right_label.grid(row=0, column=2, padx=(15, 10), sticky="e")
        
        self.flashcards_seconds = 0
        self.problems_seconds = 0
        
        self.refresh_time()
        
    def refresh_time(self):
        self.flashcards_seconds, self.problems_seconds = database.get_today_study_time()
        self.redraw()
        
    def redraw(self):
        # Match canvas background to Light/Dark mode
        mode = ctk.get_appearance_mode()
        bg_color = "#FFFFFF" if mode == "Light" else "#000000"
        self.canvas.configure(bg=bg_color)
        
        w = self.canvas.winfo_width()
        h = self.canvas.winfo_height()
        if w < 10:
            w = 200  # Fallback width
            
        self.canvas.delete("all")
        
        # Traverse parent hierarchy to find the current study mode dynamically
        study_mode = "General"
        parent = self.master
        while parent:
            if hasattr(parent, "study_mode"):
                study_mode = parent.study_mode
                break
            if hasattr(parent, "master"):
                parent = parent.master
            else:
                break

        total = self.flashcards_seconds + self.problems_seconds
        
        # Define Left and Right metrics based on study mode
        if study_mode == "Exam":
            # Primary focus: Problems (80%), Secondary: Flashcards (20%)
            left_seconds = self.problems_seconds
            right_seconds = self.flashcards_seconds
            left_name = "Problems"
            right_name = "Flashcards"
        else:
            # Primary focus: Flashcards (80%), Secondary: Problems (20%)
            left_seconds = self.flashcards_seconds
            right_seconds = self.problems_seconds
            left_name = "Flashcards"
            right_name = "Problems"

        if total > 0:
            p_left = (left_seconds / total)
            p_right = (right_seconds / total)
        else:
            p_left = 0.0
            p_right = 0.0
            
        # Format left and right labels (only minutes shown)
        lm = left_seconds // 60
        rm = right_seconds // 60
        
        self.left_label.configure(text=f"{left_name}: {lm}m ({round(p_left*100)}%)")
        self.right_label.configure(text=f"{right_name}: {rm}m ({round(p_right*100)}%)")
        
        # In both modes, the primary focus (left label) target is 80%,
        # so the green target zone always spans 75% to 85%.
        g_start_ratio = 0.75
        g_end_ratio = 0.85

        # Draw the background track
        track_h = 8
        y_top = (h - track_h) // 2
        y_bot = y_top + track_h
        
        # Segment transition points
        r1_end = int(w * g_start_ratio)
        g_end = int(w * g_end_ratio)
        
        # 1. First Red segment
        self.canvas.create_rectangle(0, y_top, r1_end, y_bot, fill="#FF453A", outline="", width=0)
        # 2. Green target segment
        self.canvas.create_rectangle(r1_end, y_top, g_end, y_bot, fill="#30D158", outline="", width=0)
        # 3. Second Red segment
        self.canvas.create_rectangle(g_end, y_top, w, y_bot, fill="#FF453A", outline="", width=0)
        
        # Slider position (based on Left ratio)
        slider_pos = p_left if total > 0 else 0.0
        
        kx = int(w * slider_pos)
        kx = max(4, min(w - 4, kx))  # Clamp
        
        # Draw slider knob (Circle showing current ratio)
        knob_r = 6
        self.canvas.create_oval(
            kx - knob_r, h//2 - knob_r, 
            kx + knob_r, h//2 + knob_r, 
            fill="#007AFF", outline="#FFFFFF", width=2
        )
