import customtkinter as ctk
import tkinter as tk
from tkinter import ttk
import tkinter.messagebox as messagebox
import database
import latex_renderer
from flashcards_ui import create_latex_image, clear_image

class ProblemManagerWindow(ctk.CTkToplevel):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.title("Problem Manager")
        self.geometry("950x650")
        self.minsize(800, 500)
        self.transient(master)  # Keep on top of parent window
        self.lift()
        self.focus_set()
        
        self.selected_problem_id = None
        self._debounce_timer_search = None
        
        # Grid config: Single full-width panel
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)
        
        # Load modules list for dropdown filters and selectors
        self.modules_map = {}
        self.modules_list = []
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT id, code, name FROM modules ORDER BY code ASC")
        for row in c.fetchall():
            display_str = f"{row[1]} - {row[2]}"
            self.modules_map[display_str] = row[0]
            self.modules_list.append(display_str)
        conn.close()
        
        # --- MAIN PANEL (List & Search & Table) ---
        self.main_panel = ctk.CTkFrame(self, corner_radius=0, fg_color="transparent")
        self.main_panel.grid(row=0, column=0, sticky="nsew", padx=20, pady=20)
        self.main_panel.grid_rowconfigure(2, weight=1)
        self.main_panel.grid_columnconfigure(0, weight=1)
        
        self.header_label = ctk.CTkLabel(self.main_panel, text="Manage Problems", font=("SF Pro Display", 24, "bold"))
        self.header_label.grid(row=0, column=0, sticky="nw", pady=(0, 15))
        
        # Search & Filter Frame
        self.filter_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.filter_frame.grid(row=1, column=0, sticky="ew", pady=(0, 15))
        self.filter_frame.grid_columnconfigure(0, weight=1)
        
        self.search_entry = ctk.CTkEntry(self.filter_frame, placeholder_text="Search problems...")
        self.search_entry.grid(row=0, column=0, sticky="ew", padx=(0, 10))
        self.search_entry.bind("<KeyRelease>", self.on_search_key)
        
        self.module_filter = ctk.CTkOptionMenu(
            self.filter_frame, 
            values=["All Modules"] + [m.split(" - ")[0] for m in self.modules_list],
            command=self.on_filter_changed,
            width=130
        )
        self.module_filter.grid(row=0, column=1, sticky="e")
        self.module_filter.set("All Modules")
        
        # Table frame and treeview table
        self.table_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.table_frame.grid(row=2, column=0, sticky="nsew")
        self.table_frame.grid_rowconfigure(0, weight=1)
        self.table_frame.grid_columnconfigure(0, weight=1)
        
        self.table = ttk.Treeview(
            self.table_frame, 
            columns=("Module", "Problem", "Created", "Times Solved"), 
            show="headings",
            style="Manager.Treeview"
        )
        self.table.grid(row=0, column=0, sticky="nsew")
        
        self.scrollbar = ttk.Scrollbar(self.table_frame, orient="vertical", command=self.table.yview)
        self.scrollbar.grid(row=0, column=1, sticky="ns")
        self.table.configure(yscrollcommand=self.scrollbar.set)
        
        # Set up table columns and headings
        self.table.heading("Module", text="Module", command=lambda: self.sort_column("Module", False))
        self.table.heading("Problem", text="Problem Preview", command=lambda: self.sort_column("Problem", False))
        self.table.heading("Created", text="Date Created", command=lambda: self.sort_column("Created", False))
        self.table.heading("Times Solved", text="Times Solved", command=lambda: self.sort_column("Times Solved", False))
        
        self.table.column("Module", width=110, minwidth=80, anchor="center", stretch=False)
        self.table.column("Problem", width=420, minwidth=250, anchor="w", stretch=True)
        self.table.column("Created", width=140, minwidth=100, anchor="center", stretch=False)
        self.table.column("Times Solved", width=120, minwidth=90, anchor="center", stretch=False)
        
        # Bind events
        self.table.bind("<<TreeviewSelect>>", self.on_tree_select)
        self.table.bind("<Double-1>", lambda e: self.open_edit_dialog())
        self.table.bind("<Delete>", lambda e: self.delete_selected_problem())
        self.table.bind("<BackSpace>", lambda e: self.delete_selected_problem())
        
        # Actions Row below the table
        self.actions_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.actions_frame.grid(row=3, column=0, sticky="ew", pady=(15, 0))
        self.actions_frame.grid_columnconfigure(2, weight=1) # Spacer
        
        self.edit_btn = ctk.CTkButton(
            self.actions_frame, 
            text="Edit Problem...", 
            fg_color="#007AFF", 
            hover_color="#0A84FF", 
            text_color="white",
            command=self.open_edit_dialog,
            width=130
        )
        self.edit_btn.grid(row=0, column=0, sticky="w", padx=(0, 10))
        
        self.delete_btn = ctk.CTkButton(
            self.actions_frame, 
            text="Delete Problem", 
            fg_color="#FF3B30", 
            hover_color="#E03B2F", 
            text_color="white",
            command=self.delete_selected_problem,
            width=130
        )
        self.delete_btn.grid(row=0, column=1, sticky="w")
        
        self.close_btn = ctk.CTkButton(
            self.actions_frame, 
            text="Close", 
            fg_color=("#E5E5EA", "#2C2C2E"), 
            hover_color=("#D1D1D6", "#3A3A3C"), 
            text_color=("black", "white"),
            command=self.destroy,
            width=100
        )
        self.close_btn.grid(row=0, column=3, sticky="e")
        
        self.update_treeview_style()
        self.load_problems_list()

    def update_treeview_style(self):
        style = ttk.Style()
        style.theme_use("default")
        
        mode = ctk.get_appearance_mode()
        if mode == "Dark":
            bg = "#1C1C1E"
            fg = "white"
            field_bg = "#1C1C1E"
            selected_bg = "#3A3A3C"
            heading_bg = "#2C2C2E"
            heading_fg = "white"
            active_heading_bg = "#3A3A3C"
            border_color = "#2C2C2E"
        else:
            bg = "#FFFFFF"
            fg = "black"
            field_bg = "#FFFFFF"
            selected_bg = "#E5E5EA"
            heading_bg = "#F4F4F5"
            heading_fg = "black"
            active_heading_bg = "#E5E5EA"
            border_color = "#E5E5EA"
            
        style.configure("Manager.Treeview", 
                        background=bg,
                        foreground=fg,
                        rowheight=32,
                        fieldbackground=field_bg,
                        bordercolor=border_color,
                        borderwidth=0,
                        font=("SF Pro Display", 13))
        style.map('Manager.Treeview', background=[('selected', selected_bg)], foreground=[('selected', fg)])
        style.configure("Manager.Treeview.Heading",
                        background=heading_bg,
                        foreground=heading_fg,
                        relief="flat",
                        font=("SF Pro Display", 13, "bold"))
        style.map("Manager.Treeview.Heading", background=[('active', active_heading_bg)])

    def _set_appearance_mode(self, mode_string):
        super()._set_appearance_mode(mode_string)
        self.update_treeview_style()

    def load_problems_list(self, search_query="", module_filter="All Modules"):
        # Clear existing items
        self.table.delete(*self.table.get_children())
        
        query = """
            SELECT p.id, t.module_id, m.code, m.name, p.content, p.solution_hint, p.created_date, p.solved_count 
            FROM problems p
            JOIN topics t ON p.topic_id = t.id
            JOIN modules m ON t.module_id = m.id
            WHERE 1=1
        """
        params = []
        
        if search_query:
            query += " AND (p.content LIKE ? OR p.solution_hint LIKE ?)"
            params.extend([f"%{search_query}%", f"%{search_query}%"])
            
        if module_filter != "All Modules":
            query += " AND m.code = ?"
            params.append(module_filter)
            
        query += " ORDER BY m.code ASC, p.id DESC"
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute(query, params)
        rows = c.fetchall()
        conn.close()
        
        for pid, mid, mcode, mname, content, hint, created_date, solved_count in rows:
            # Text preview snippet
            clean_snippet = content.replace("\n", " ").strip()
            snippet = clean_snippet[:65] + "..." if len(clean_snippet) > 65 else clean_snippet
            if not snippet:
                snippet = "[Empty Problem]"
                
            date_str = created_date if created_date else "N/A"
            solves = solved_count if solved_count is not None else 0
            
            self.table.insert("", "end", iid=str(pid), values=(mcode, snippet, date_str, solves))
            
        # Re-apply selection
        if self.selected_problem_id and self.table.exists(str(self.selected_problem_id)):
            self.table.selection_set(str(self.selected_problem_id))
            self.table.see(str(self.selected_problem_id))
        else:
            self.selected_problem_id = None

    def on_tree_select(self, event):
        selected = self.table.selection()
        if not selected:
            self.selected_problem_id = None
            return
        self.selected_problem_id = int(selected[0])

    def sort_column(self, col, reverse):
        l = [(self.table.set(k, col), k) for k in self.table.get_children("")]
        
        # Try numeric sorting for Times Solved
        if col == "Times Solved":
            try:
                l.sort(key=lambda t: int(t[0]), reverse=reverse)
            except ValueError:
                l.sort(reverse=reverse)
        else:
            l.sort(key=lambda t: t[0].lower(), reverse=reverse)
            
        for index, (val, k) in enumerate(l):
            self.table.move(k, "", index)
            
        self.table.heading(col, command=lambda: self.sort_column(col, not reverse))

    def on_search_key(self, event=None):
        if hasattr(self, "_debounce_timer_search") and self._debounce_timer_search:
            self.after_cancel(self._debounce_timer_search)
        self._debounce_timer_search = self.after(300, self.trigger_search)
        
    def trigger_search(self):
        query = self.search_entry.get().strip()
        mod_filter = self.module_filter.get()
        self.load_problems_list(query, mod_filter)

    def on_filter_changed(self, choice):
        query = self.search_entry.get().strip()
        self.load_problems_list(query, choice)

    def delete_problem_direct(self, problem_id):
        if messagebox.askyesno("Confirm Delete", "Are you sure you want to delete this problem?", parent=self):
            conn = database.get_connection()
            c = conn.cursor()
            c.execute("DELETE FROM problems WHERE id = ?", (problem_id,))
            conn.commit()
            conn.close()
            
            if self.selected_problem_id == problem_id:
                self.selected_problem_id = None
                
            self.load_problems_list(self.search_entry.get().strip(), self.module_filter.get())

    def delete_selected_problem(self):
        if not self.selected_problem_id:
            messagebox.showinfo("No Problem Selected", "Please select a problem from the table to delete.", parent=self)
            return
        self.delete_problem_direct(self.selected_problem_id)

    def open_edit_dialog(self):
        if not self.selected_problem_id:
            messagebox.showinfo("No Problem Selected", "Please select a problem from the table to edit.", parent=self)
            return
            
        if hasattr(self, "edit_window") and self.edit_window and self.edit_window.winfo_exists():
            self.edit_window.focus_set()
            self.edit_window.lift()
        else:
            self.edit_window = ProblemEditWindow(self, self.selected_problem_id)


class ProblemEditWindow(ctk.CTkToplevel):
    def __init__(self, master, problem_id, **kwargs):
        super().__init__(master, **kwargs)
        self.manager = master
        self.problem_id = problem_id
        self._debounce_timer_edit = None
        
        self.title("Edit Problem")
        self.geometry("520x680")
        self.minsize(480, 580)
        self.transient(master)
        self.lift()
        self.focus_set()
        
        # Grid config
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)
        
        self.main_frame = ctk.CTkFrame(self, corner_radius=0, fg_color="transparent")
        self.main_frame.grid(row=0, column=0, sticky="nsew", padx=25, pady=25)
        self.main_frame.grid_columnconfigure(0, weight=1)
        self.main_frame.grid_rowconfigure(8, weight=1)  # Preview spacer
        
        # Header
        self.header = ctk.CTkLabel(self.main_frame, text="Edit Problem", font=("SF Pro Display", 22, "bold"))
        self.header.grid(row=0, column=0, sticky="nw", pady=(0, 15))
        
        # Module Selection
        self.module_label = ctk.CTkLabel(self.main_frame, text="Module:", font=("SF Pro Display", 12, "bold"))
        self.module_label.grid(row=1, column=0, sticky="nw", pady=(0, 2))
        
        self.module_dropdown = ctk.CTkOptionMenu(self.main_frame, values=self.manager.modules_list, width=280)
        self.module_dropdown.grid(row=2, column=0, sticky="nw", pady=(0, 15))
        
        # Problem Content Input
        self.front_label = ctk.CTkLabel(self.main_frame, text="Problem Content:", font=("SF Pro Display", 12, "bold"))
        self.front_label.grid(row=3, column=0, sticky="nw", pady=(0, 2))
        
        self.front_textbox = ctk.CTkTextbox(self.main_frame, height=80, border_width=1, fg_color="transparent")
        self.front_textbox.grid(row=4, column=0, sticky="ew", pady=(0, 15))
        self.front_textbox.bind("<KeyRelease>", self.on_typing_front)
        
        # Solution Hint Input
        self.back_label = ctk.CTkLabel(self.main_frame, text="Solution Hint:", font=("SF Pro Display", 12, "bold"))
        self.back_label.grid(row=5, column=0, sticky="nw", pady=(0, 2))
        
        self.back_textbox = ctk.CTkTextbox(self.main_frame, height=80, border_width=1, fg_color="transparent")
        self.back_textbox.grid(row=6, column=0, sticky="ew", pady=(0, 15))
        self.back_textbox.bind("<KeyRelease>", self.on_typing_back)
        
        # Live Preview Header
        self.preview_header_frame = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        self.preview_header_frame.grid(row=7, column=0, sticky="ew", pady=(0, 5))
        self.preview_header_frame.grid_columnconfigure(0, weight=1)
        
        self.preview_title = ctk.CTkLabel(self.preview_header_frame, text="Live Preview:", font=("SF Pro Display", 12, "bold"))
        self.preview_title.grid(row=0, column=0, sticky="w")
        
        segmented_button = ctk.CTkSegmentedButton(
            self.preview_header_frame, 
            values=["Problem", "Hint"], 
            command=lambda v: self.update_edit_preview()
        )
        segmented_button.grid(row=0, column=1, sticky="e")
        self.preview_side_selector = segmented_button
        self.preview_side_selector.set("Problem")
        
        # Preview Label
        self.preview_label = ctk.CTkLabel(self.main_frame, text="Preview will render here", wraplength=420)
        self.preview_label.grid(row=8, column=0, sticky="nsew", pady=(0, 20), padx=5)
        
        # Buttons Row
        self.buttons_frame = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        self.buttons_frame.grid(row=9, column=0, sticky="ew")
        self.buttons_frame.grid_columnconfigure(0, weight=1)
        
        self.cancel_btn = ctk.CTkButton(
            self.buttons_frame, 
            text="Cancel", 
            fg_color=("#E5E5EA", "#2C2C2E"), 
            hover_color=("#D1D1D6", "#3A3A3C"), 
            text_color=("black", "white"),
            command=self.destroy,
            width=100
        )
        self.cancel_btn.grid(row=0, column=1, padx=(0, 10), sticky="e")
        
        self.save_btn = ctk.CTkButton(
            self.buttons_frame, 
            text="Save Changes", 
            fg_color="#34C759", 
            hover_color="#28CD41", 
            text_color="white",
            command=self.save_changes,
            width=120
        )
        self.save_btn.grid(row=0, column=2, sticky="e")
        
        # Load Details
        self.load_problem_details()
        
        # Bind configure event to resize components dynamically
        self.bind("<Configure>", self.on_window_configure)

    def load_problem_details(self):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            SELECT p.content, p.solution_hint, t.module_id, m.code, m.name 
            FROM problems p
            JOIN topics t ON p.topic_id = t.id
            JOIN modules m ON t.module_id = m.id
            WHERE p.id = ?
        """, (self.problem_id,))
        row = c.fetchone()
        conn.close()
        
        if not row:
            self.destroy()
            return
            
        content, hint, mid, mcode, mname = row
        
        display_str = f"{mcode} - {mname}"
        if display_str in self.manager.modules_list:
            self.module_dropdown.set(display_str)
            
        self.front_textbox.insert("0.0", content)
        self.back_textbox.insert("0.0", hint)
        self.update_edit_preview()

    def update_edit_preview(self):
        side = self.preview_side_selector.get()
        if side == "Problem":
            text = self.front_textbox.get("0.0", "end").strip()
        else:
            text = self.back_textbox.get("0.0", "end").strip()
            
        if not text:
            clear_image(self.preview_label)
            self.preview_label.configure(text=f"Preview is empty ({side} is blank).")
            return
            
        if not latex_renderer.is_latex(text):
            clear_image(self.preview_label)
            self.preview_label.configure(text=text, font=("SF Pro Display", 14))
            return
            
        if not latex_renderer.is_ready():
            clear_image(self.preview_label)
            self.preview_label.configure(text="Loading LaTeX engine...")
            return
            
        try:
            w = self.main_frame.winfo_width()
            max_w = w - 40 if w > 50 else 400
            wrap_width = max(40, min(120, int(max_w / 10.5))) if w > 50 else 72
            
            pil_img = latex_renderer.render_latex_to_image(text, fontsize=14, wrap_width=wrap_width)
            ctk_img = create_latex_image(pil_img, max_width=max_w)
            
            self.preview_label.configure(image=ctk_img, text="")
            self.preview_label.image = ctk_img
        except Exception as e:
            clear_image(self.preview_label)
            self.preview_label.configure(text=f"LaTeX Error: {e}")

    def on_typing_front(self, event=None):
        self.preview_side_selector.set("Problem")
        self.on_edit_typing()
        
    def on_typing_back(self, event=None):
        self.preview_side_selector.set("Hint")
        self.on_edit_typing()
        
    def on_edit_typing(self, event=None):
        if hasattr(self, "_debounce_timer_edit") and self._debounce_timer_edit:
            self.after_cancel(self._debounce_timer_edit)
        self._debounce_timer_edit = self.after(300, self.update_edit_preview)

    def save_changes(self):
        display_str = self.module_dropdown.get()
        mod_id = self.manager.modules_map.get(display_str)
        content = self.front_textbox.get("0.0", "end").strip()
        hint = self.back_textbox.get("0.0", "end").strip()
        
        if not content or not mod_id:
            messagebox.showwarning("Incomplete Fields", "Problem content must not be blank.", parent=self)
            return
            
        conn = database.get_connection()
        c = conn.cursor()
        
        # Get or create default topic for this module to save problem
        c.execute("SELECT id FROM topics WHERE module_id = ? LIMIT 1", (mod_id,))
        row = c.fetchone()
        if row:
            topic_id = row[0]
        else:
            c.execute("INSERT INTO topics (module_id, week, name) VALUES (?, 1, 'General')", (mod_id,))
            topic_id = c.lastrowid
            
        c.execute("""
            UPDATE problems 
            SET topic_id = ?, content = ?, solution_hint = ? 
            WHERE id = ?
        """, (topic_id, content, hint, self.problem_id))
        conn.commit()
        conn.close()
        
        # Refresh the parent table list
        self.manager.load_problems_list(
            self.manager.search_entry.get().strip(), 
            self.manager.module_filter.get()
        )
        self.destroy()

    def on_window_configure(self, event):
        tb_width = self.front_textbox.winfo_width()
        if tb_width > 50:
            self.preview_label.configure(wraplength=tb_width - 20)
            self.update_edit_preview()
