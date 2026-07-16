import customtkinter as ctk
import tkinter as tk
from tkinter import ttk
import tkinter.messagebox as messagebox
import database

class ModuleManagerWindow(ctk.CTkToplevel):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.title("Module Manager")
        self.geometry("780x500")
        self.minsize(700, 400)
        self.transient(master)
        self.lift()
        self.focus_set()
        
        self.selected_module_id = None
        
        # Grid layout
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)
        
        self.main_panel = ctk.CTkFrame(self, corner_radius=0, fg_color="transparent")
        self.main_panel.grid(row=0, column=0, sticky="nsew", padx=20, pady=20)
        self.main_panel.grid_rowconfigure(2, weight=1)
        self.main_panel.grid_columnconfigure(0, weight=1)
        
        self.header = ctk.CTkLabel(self.main_panel, text="Manage Modules", font=("SF Pro Display", 24, "bold"))
        self.header.grid(row=0, column=0, sticky="nw", pady=(0, 15))
        
        # Search & Filter Frame
        self.filter_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.filter_frame.grid(row=1, column=0, sticky="ew", pady=(0, 15))
        self.filter_frame.grid_columnconfigure(0, weight=1)
        
        ctk.CTkLabel(self.filter_frame, text="Filter by Year:", font=("SF Pro Display", 12, "bold")).grid(row=0, column=1, sticky="e", padx=(0, 5))
        
        self.year_filter = ctk.CTkOptionMenu(
            self.filter_frame,
            values=["All Years", "Year 1", "Year 2", "Year 3", "Year 4"],
            command=self.on_filter_changed,
            width=130
        )
        self.year_filter.grid(row=0, column=2, sticky="e")
        self.year_filter.set("All Years")
        
        # Table frame and treeview table
        self.table_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.table_frame.grid(row=2, column=0, sticky="nsew")
        self.table_frame.grid_rowconfigure(0, weight=1)
        self.table_frame.grid_columnconfigure(0, weight=1)
        
        self.table = ttk.Treeview(
            self.table_frame,
            columns=("Code", "Name", "Semester", "Year"),
            show="headings",
            style="Manager.Treeview"
        )
        self.table.grid(row=0, column=0, sticky="nsew")
        
        self.scrollbar = ttk.Scrollbar(self.table_frame, orient="vertical", command=self.table.yview)
        self.scrollbar.grid(row=0, column=1, sticky="ns")
        self.table.configure(yscrollcommand=self.scrollbar.set)
        
        self.table.heading("Code", text="Module Code", command=lambda: self.sort_column("Code", False))
        self.table.heading("Name", text="Module Name", command=lambda: self.sort_column("Name", False))
        self.table.heading("Semester", text="Semester", command=lambda: self.sort_column("Semester", False))
        self.table.heading("Year", text="Year", command=lambda: self.sort_column("Year", False))
        
        self.table.column("Code", width=120, minwidth=90, anchor="center", stretch=False)
        self.table.column("Name", width=350, minwidth=200, anchor="w", stretch=True)
        self.table.column("Semester", width=100, minwidth=80, anchor="center", stretch=False)
        self.table.column("Year", width=100, minwidth=80, anchor="center", stretch=False)
        
        self.table.bind("<<TreeviewSelect>>", self.on_tree_select)
        self.table.bind("<Double-1>", lambda e: self.open_edit_dialog())
        
        # Actions Row
        self.actions_frame = ctk.CTkFrame(self.main_panel, fg_color="transparent")
        self.actions_frame.grid(row=3, column=0, sticky="ew", pady=(15, 0))
        self.actions_frame.grid_columnconfigure(3, weight=1) # Spacer
        
        self.add_btn = ctk.CTkButton(
            self.actions_frame,
            text="Add Module...",
            fg_color="#34C759",
            hover_color="#28CD41",
            text_color="white",
            command=self.open_add_dialog,
            width=120
        )
        self.add_btn.grid(row=0, column=0, sticky="w", padx=(0, 10))
        
        self.edit_btn = ctk.CTkButton(
            self.actions_frame,
            text="Edit Module...",
            fg_color="#007AFF",
            hover_color="#0A84FF",
            text_color="white",
            command=self.open_edit_dialog,
            width=120
        )
        self.edit_btn.grid(row=0, column=1, sticky="w", padx=(0, 10))
        
        self.delete_btn = ctk.CTkButton(
            self.actions_frame,
            text="Delete Module",
            fg_color="#FF3B30",
            hover_color="#E03B2F",
            text_color="white",
            command=self.delete_selected_module,
            width=120
        )
        self.delete_btn.grid(row=0, column=2, sticky="w")
        
        self.close_btn = ctk.CTkButton(
            self.actions_frame,
            text="Close",
            fg_color=("#E5E5EA", "#2C2C2E"),
            hover_color=("#D1D1D6", "#3A3A3C"),
            text_color=("black", "white"),
            command=self.destroy,
            width=100
        )
        self.close_btn.grid(row=0, column=4, sticky="e")
        
        self.update_treeview_style()
        self.load_modules_list()
        
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

    def load_modules_list(self, year_filter="All Years"):
        self.table.delete(*self.table.get_children())
        
        query = "SELECT id, code, name, semester, year FROM modules WHERE 1=1"
        params = []
        
        if year_filter != "All Years":
            year_val = int(year_filter.split(" ")[1])
            query += " AND year = ?"
            params.append(year_val)
            
        query += " ORDER BY year ASC, code ASC"
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute(query, params)
        rows = c.fetchall()
        conn.close()
        
        for mid, code, name, semester, year in rows:
            self.table.insert("", "end", iid=str(mid), values=(code, name, f"Semester {semester}", f"Year {year}"))
            
        if self.selected_module_id and self.table.exists(str(self.selected_module_id)):
            self.table.selection_set(str(self.selected_module_id))
            self.table.see(str(self.selected_module_id))
        else:
            self.selected_module_id = None

    def on_tree_select(self, event):
        selected = self.table.selection()
        if not selected:
            self.selected_module_id = None
            return
        self.selected_module_id = int(selected[0])

    def sort_column(self, col, reverse):
        l = [(self.table.set(k, col), k) for k in self.table.get_children("")]
        
        if col in ("Semester", "Year"):
            try:
                l.sort(key=lambda t: int(t[0].split(" ")[1]), reverse=reverse)
            except:
                l.sort(reverse=reverse)
        else:
            l.sort(key=lambda t: t[0].lower(), reverse=reverse)
            
        for index, (val, k) in enumerate(l):
            self.table.move(k, "", index)
            
        self.table.heading(col, command=lambda: self.sort_column(col, not reverse))

    def on_filter_changed(self, choice):
        self.load_modules_list(choice)

    def open_add_dialog(self):
        if hasattr(self, "edit_window") and self.edit_window and self.edit_window.winfo_exists():
            self.edit_window.focus_set()
            self.edit_window.lift()
        else:
            self.edit_window = ModuleEditWindow(self, None)

    def open_edit_dialog(self):
        if not self.selected_module_id:
            messagebox.showinfo("No Module Selected", "Please select a module from the table to edit.", parent=self)
            return
            
        if hasattr(self, "edit_window") and self.edit_window and self.edit_window.winfo_exists():
            self.edit_window.focus_set()
            self.edit_window.lift()
        else:
            self.edit_window = ModuleEditWindow(self, self.selected_module_id)

    def delete_selected_module(self):
        if not self.selected_module_id:
            messagebox.showinfo("No Module Selected", "Please select a module from the table to delete.", parent=self)
            return
            
        if messagebox.askyesno(
            "Confirm Delete",
            "Deleting this module will delete all its topics, notes, flashcards, problems, study logs, and feynman chats. This action cannot be undone.\n\nAre you sure you want to delete it?",
            parent=self
        ):
            mid = self.selected_module_id
            
            conn = database.get_connection()
            c = conn.cursor()
            
            # Cascade deletions manually
            c.execute("DELETE FROM flashcards WHERE module_id = ?", (mid,))
            c.execute("""
                DELETE FROM feynman_chats 
                WHERE note_id IN (
                    SELECT n.id FROM notes n
                    JOIN topics t ON n.topic_id = t.id
                    WHERE t.module_id = ?
                )
            """, (mid,))
            c.execute("""
                DELETE FROM notes 
                WHERE topic_id IN (
                    SELECT id FROM topics WHERE module_id = ?
                )
            """, (mid,))
            c.execute("DELETE FROM topics WHERE module_id = ?", (mid,))
            c.execute("DELETE FROM feynman_sessions WHERE module_id = ?", (mid,))
            c.execute("DELETE FROM module_study_time WHERE module_id = ?", (mid,))
            c.execute("DELETE FROM modules WHERE id = ?", (mid,))
            
            conn.commit()
            conn.close()
            
            self.selected_module_id = None
            self.load_modules_list(self.year_filter.get())
            self.master.refresh_sidebar_modules()


class ModuleEditWindow(ctk.CTkToplevel):
    def __init__(self, master, module_id=None, **kwargs):
        super().__init__(master, **kwargs)
        self.manager = master
        self.module_id = module_id
        
        self.title("Edit Module" if module_id else "Add New Module")
        self.geometry("450x380")
        self.resizable(False, False)
        self.transient(master)
        self.lift()
        self.focus_set()
        
        # Grid layout
        self.grid_columnconfigure(0, weight=1)
        
        self.main_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.main_frame.pack(fill="both", expand=True, padx=25, pady=25)
        self.main_frame.grid_columnconfigure(1, weight=1)
        
        ctk.CTkLabel(self.main_frame, text="Module Code:", font=("SF Pro Display", 13, "bold")).grid(row=0, column=0, sticky="w", pady=8)
        self.code_entry = ctk.CTkEntry(self.main_frame, placeholder_text="e.g. 6CCP3380")
        self.code_entry.grid(row=0, column=1, sticky="ew", pady=8)
        
        ctk.CTkLabel(self.main_frame, text="Module Name:", font=("SF Pro Display", 13, "bold")).grid(row=1, column=0, sticky="w", pady=8)
        self.name_entry = ctk.CTkEntry(self.main_frame, placeholder_text="e.g. Optics")
        self.name_entry.grid(row=1, column=1, sticky="ew", pady=8)
        
        ctk.CTkLabel(self.main_frame, text="Semester:", font=("SF Pro Display", 13, "bold")).grid(row=2, column=0, sticky="w", pady=8)
        self.sem_dropdown = ctk.CTkOptionMenu(self.main_frame, values=["Semester 1", "Semester 2"])
        self.sem_dropdown.grid(row=2, column=1, sticky="w", pady=8)
        self.sem_dropdown.set("Semester 1")
        
        ctk.CTkLabel(self.main_frame, text="Year:", font=("SF Pro Display", 13, "bold")).grid(row=3, column=0, sticky="w", pady=8)
        self.year_dropdown = ctk.CTkOptionMenu(self.main_frame, values=["Year 1", "Year 2", "Year 3", "Year 4"])
        self.year_dropdown.grid(row=3, column=1, sticky="w", pady=8)
        
        # Default the year selector in Module edit window to match manager filter or default Year 1
        mgr_year = self.manager.year_filter.get()
        if mgr_year != "All Years":
            self.year_dropdown.set(mgr_year)
        else:
            self.year_dropdown.set("Year 1")
            
        # Button bar
        btn_bar = ctk.CTkFrame(self.main_frame, fg_color="transparent")
        btn_bar.grid(row=4, column=0, columnspan=2, sticky="ew", pady=(25, 0))
        
        self.cancel_btn = ctk.CTkButton(
            btn_bar,
            text="Cancel",
            fg_color=("#E5E5EA", "#2C2C2E"),
            hover_color=("#D1D1D6", "#3A3A3C"),
            text_color=("black", "white"),
            command=self.destroy,
            width=90
        )
        self.cancel_btn.pack(side="right")
        
        self.save_btn = ctk.CTkButton(
            btn_bar,
            text="Save Module",
            fg_color="#34C759",
            hover_color="#28CD41",
            text_color="white",
            command=self.save_module,
            width=110
        )
        self.save_btn.pack(side="right", padx=(0, 10))
        
        if self.module_id:
            self.load_module_details()
            
    def load_module_details(self):
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT code, name, semester, year FROM modules WHERE id = ?", (self.module_id,))
        row = c.fetchone()
        conn.close()
        
        if row:
            code, name, semester, year = row
            self.code_entry.insert(0, code)
            # Disable changing module code when editing to prevent primary key issues if code was referenced,
            # or just leave it editable. Standard is fine, but code is UNIQUE, so SQLite handles duplicates safely.
            self.name_entry.insert(0, name)
            self.sem_dropdown.set(f"Semester {semester}")
            self.year_dropdown.set(f"Year {year}")

    def save_module(self):
        code = self.code_entry.get().strip()
        name = self.name_entry.get().strip()
        sem_val = int(self.sem_dropdown.get().split(" ")[1])
        year_val = int(self.year_dropdown.get().split(" ")[1])
        
        if not code or not name:
            messagebox.showwarning("Incomplete Fields", "Please specify both the module code and name.", parent=self)
            return
            
        conn = database.get_connection()
        c = conn.cursor()
        
        try:
            if self.module_id:
                c.execute("""
                    UPDATE modules 
                    SET code = ?, name = ?, semester = ?, year = ? 
                    WHERE id = ?
                """, (code, name, sem_val, year_val, self.module_id))
            else:
                c.execute("""
                    INSERT INTO modules (code, name, semester, year) 
                    VALUES (?, ?, ?, ?)
                """, (code, name, sem_val, year_val))
            conn.commit()
        except sqlite3.IntegrityError:
            messagebox.showerror("Duplicate Code", f"A module with code '{code}' already exists.", parent=self)
            conn.close()
            return
            
        conn.close()
        
        self.manager.load_modules_list(self.manager.year_filter.get())
        self.manager.master.refresh_sidebar_modules()
        self.destroy()
