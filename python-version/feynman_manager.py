import customtkinter as ctk
import tkinter as tk
from tkinter import ttk
import tkinter.messagebox as messagebox
import database

class FeynmanManagerWindow(ctk.CTkToplevel):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.title("Feynman Sandbox Manager")
        self.geometry("950x650")
        self.minsize(800, 500)
        self.transient(master)  # Keep on top of parent window
        self.lift()
        self.focus_set()
        
        self.selected_session_id = None
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
        
        self.header_label = ctk.CTkLabel(self.main_panel, text="Manage Feynman Sessions", font=("SF Pro Display", 24, "bold"))
        self.header_label.grid(row=0, column=0, sticky="nw", pady=(0, 15))
        
        # Search & Filter Frame
        self.filter_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.filter_frame.grid(row=1, column=0, sticky="ew", pady=(0, 15))
        self.filter_frame.grid_columnconfigure(0, weight=1)
        
        self.search_entry = ctk.CTkEntry(self.filter_frame, placeholder_text="Search concepts/explanations...")
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
            columns=("Module", "Concept", "Created", "Explanation"), 
            show="headings",
            style="Manager.Treeview"
        )
        self.table.grid(row=0, column=0, sticky="nsew")
        
        self.scrollbar = ttk.Scrollbar(self.table_frame, orient="vertical", command=self.table.yview)
        self.scrollbar.grid(row=0, column=1, sticky="ns")
        self.table.configure(yscrollcommand=self.scrollbar.set)
        
        # Set up table columns and headings
        self.table.heading("Module", text="Module", command=lambda: self.sort_column("Module", False))
        self.table.heading("Concept", text="Concept Title", command=lambda: self.sort_column("Concept", False))
        self.table.heading("Created", text="Date Created", command=lambda: self.sort_column("Created", False))
        self.table.heading("Explanation", text="Explanation Snippet", command=lambda: self.sort_column("Explanation", False))
        
        self.table.column("Module", width=110, minwidth=80, anchor="center", stretch=False)
        self.table.column("Concept", width=220, minwidth=150, anchor="w", stretch=False)
        self.table.column("Created", width=140, minwidth=100, anchor="center", stretch=False)
        self.table.column("Explanation", width=350, minwidth=250, anchor="w", stretch=True)
        
        # Bind events
        self.table.bind("<<TreeviewSelect>>", self.on_tree_select)
        self.table.bind("<Double-1>", lambda e: self.open_edit_dialog())
        self.table.bind("<Delete>", lambda e: self.delete_selected_session())
        self.table.bind("<BackSpace>", lambda e: self.delete_selected_session())
        
        # Actions Row below the table
        self.actions_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.actions_frame.grid(row=3, column=0, sticky="ew", pady=(15, 0))
        self.actions_frame.grid_columnconfigure(2, weight=1) # Spacer
        
        self.view_btn = ctk.CTkButton(
            self.actions_frame, 
            text="View / Edit Session...", 
            fg_color="#007AFF", 
            hover_color="#0A84FF", 
            text_color="white",
            command=self.open_edit_dialog,
            width=150
        )
        self.view_btn.grid(row=0, column=0, sticky="w", padx=(0, 10))
        
        self.delete_btn = ctk.CTkButton(
            self.actions_frame, 
            text="Delete Session", 
            fg_color="#FF3B30", 
            hover_color="#E03B2F", 
            text_color="white",
            command=self.delete_selected_session,
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
        self.load_sessions_list()

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

    def load_sessions_list(self, search_query="", module_filter="All Modules"):
        # Clear existing items
        self.table.delete(*self.table.get_children())
        
        query = """
            SELECT fs.id, fs.module_id, m.code, m.name, fs.concept, fs.explanation, fs.created_date 
            FROM feynman_sessions fs
            LEFT JOIN modules m ON fs.module_id = m.id
            WHERE 1=1
        """
        params = []
        
        if search_query:
            query += " AND (fs.concept LIKE ? OR fs.explanation LIKE ?)"
            params.extend([f"%{search_query}%", f"%{search_query}%"])
            
        if module_filter != "All Modules":
            query += " AND m.code = ?"
            params.append(module_filter)
            
        query += " ORDER BY fs.id DESC"
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute(query, params)
        rows = c.fetchall()
        conn.close()
        
        for sid, mid, mcode, mname, concept, explanation, created_date in rows:
            mcode_str = mcode if mcode else "General"
            clean_snippet = explanation.replace("\n", " ").strip()
            snippet = clean_snippet[:70] + "..." if len(clean_snippet) > 70 else clean_snippet
            if not snippet:
                snippet = "[Empty explanation]"
                
            date_str = created_date if created_date else "N/A"
            
            self.table.insert("", "end", iid=str(sid), values=(mcode_str, concept, date_str, snippet))
            
        # Re-apply selection
        if self.selected_session_id and self.table.exists(str(self.selected_session_id)):
            self.table.selection_set(str(self.selected_session_id))
            self.table.see(str(self.selected_session_id))
        else:
            self.selected_session_id = None

    def on_tree_select(self, event):
        selected = self.table.selection()
        if not selected:
            self.selected_session_id = None
            return
        self.selected_session_id = int(selected[0])

    def sort_column(self, col, reverse):
        l = [(self.table.set(k, col), k) for k in self.table.get_children("")]
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
        self.load_sessions_list(query, mod_filter)

    def on_filter_changed(self, choice):
        query = self.search_entry.get().strip()
        self.load_sessions_list(query, choice)

    def delete_session_direct(self, session_id):
        if messagebox.askyesno("Confirm Delete", "Are you sure you want to delete this Feynman session log?", parent=self):
            conn = database.get_connection()
            c = conn.cursor()
            c.execute("DELETE FROM feynman_sessions WHERE id = ?", (session_id,))
            conn.commit()
            conn.close()
            
            if self.selected_session_id == session_id:
                self.selected_session_id = None
                
            self.load_sessions_list(self.search_entry.get().strip(), self.module_filter.get())

    def delete_selected_session(self):
        if not self.selected_session_id:
            messagebox.showinfo("No Session Selected", "Please select a session from the table to delete.", parent=self)
            return
        self.delete_session_direct(self.selected_session_id)

    def open_edit_dialog(self):
        if not self.selected_session_id:
            messagebox.showinfo("No Session Selected", "Please select a session from the table to view/edit.", parent=self)
            return
            
        if hasattr(self, "edit_window") and self.edit_window and self.edit_window.winfo_exists():
            self.edit_window.focus_set()
            self.edit_window.lift()
        else:
            self.edit_window = FeynmanSessionWindow(self, self.selected_session_id)


class FeynmanSessionWindow(ctk.CTkToplevel):
    def __init__(self, master, session_id, **kwargs):
        super().__init__(master, **kwargs)
        self.manager = master
        self.session_id = session_id
        
        self.title("Feynman Sandbox Session Details")
        self.geometry("550x600")
        self.minsize(450, 480)
        self.transient(master)
        self.lift()
        self.focus_set()
        
        # Grid config
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)
        
        self.main_frame = ctk.CTkFrame(self, corner_radius=0, fg_color="transparent")
        self.main_frame.grid(row=0, column=0, sticky="nsew", padx=25, pady=25)
        self.main_frame.grid_columnconfigure(0, weight=1)
        self.main_frame.grid_rowconfigure(6, weight=1)  # Textbox gets space
        
        # Header
        self.header = ctk.CTkLabel(self.main_frame, text="Feynman Session Details", font=("SF Pro Display", 22, "bold"))
        self.header.grid(row=0, column=0, sticky="nw", pady=(0, 15))
        
        # Module Selector (optional)
        self.module_label = ctk.CTkLabel(self.main_frame, text="Module Assignment:", font=("SF Pro Display", 12, "bold"))
        self.module_label.grid(row=1, column=0, sticky="nw", pady=(0, 2))
        
        # Add a "None / General" module choice
        self.module_choices = ["None / General"] + self.manager.modules_list
        self.module_dropdown = ctk.CTkOptionMenu(self.main_frame, values=self.module_choices, width=280)
        self.module_dropdown.grid(row=2, column=0, sticky="nw", pady=(0, 15))
        
        # Concept Input
        self.concept_label = ctk.CTkLabel(self.main_frame, text="Concept Title:", font=("SF Pro Display", 12, "bold"))
        self.concept_label.grid(row=3, column=0, sticky="nw", pady=(0, 2))
        
        self.concept_entry = ctk.CTkEntry(self.main_frame, border_width=1, fg_color="transparent")
        self.concept_entry.grid(row=4, column=0, sticky="ew", pady=(0, 15))
        
        # Explanation Textbox
        self.explanation_label = ctk.CTkLabel(self.main_frame, text="Explanation / Teaching log:", font=("SF Pro Display", 12, "bold"))
        self.explanation_label.grid(row=5, column=0, sticky="nw", pady=(0, 2))
        
        self.explanation_textbox = ctk.CTkTextbox(self.main_frame, border_width=1, fg_color="transparent")
        self.explanation_textbox.grid(row=6, column=0, sticky="nsew", pady=(0, 20))
        
        # Buttons Row
        self.buttons_frame = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        self.buttons_frame.grid(row=7, column=0, sticky="ew")
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
        self.load_session_details()

    def load_session_details(self):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            SELECT fs.concept, fs.explanation, fs.module_id, m.code, m.name 
            FROM feynman_sessions fs
            LEFT JOIN modules m ON fs.module_id = m.id
            WHERE fs.id = ?
        """, (self.session_id,))
        row = c.fetchone()
        conn.close()
        
        if not row:
            self.destroy()
            return
            
        concept, explanation, mid, mcode, mname = row
        
        if mid:
            display_str = f"{mcode} - {mname}"
            if display_str in self.module_choices:
                self.module_dropdown.set(display_str)
        else:
            self.module_dropdown.set("None / General")
            
        self.concept_entry.insert(0, concept)
        self.explanation_textbox.insert("0.0", explanation)

    def save_changes(self):
        display_str = self.module_dropdown.get()
        if display_str == "None / General":
            mod_id = None
        else:
            mod_id = self.manager.modules_map.get(display_str)
            
        concept = self.concept_entry.get().strip()
        explanation = self.explanation_textbox.get("0.0", "end").strip()
        
        if not concept or not explanation:
            messagebox.showwarning("Incomplete Fields", "Concept title and explanation must not be empty.", parent=self)
            return
            
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            UPDATE feynman_sessions 
            SET module_id = ?, concept = ?, explanation = ? 
            WHERE id = ?
        """, (mod_id, concept, explanation, self.session_id))
        conn.commit()
        conn.close()
        
        # Refresh the parent table list
        self.manager.load_sessions_list(
            self.manager.search_entry.get().strip(), 
            self.manager.module_filter.get()
        )
        self.destroy()
