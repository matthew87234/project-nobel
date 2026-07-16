import customtkinter as ctk
import database
import os
import threading
import socket
import subprocess
import time
import urllib.request
import json

ctk.set_appearance_mode("Light")  # Modes: "System" (standard), "Dark", "Light"
ctk.set_default_color_theme("blue")  # Themes: "blue" (standard), "green", "dark-blue"

class App(ctk.CTk):
    def __init__(self):
        super().__init__()

        # Ensure database tables exist before building the UI
        database.setup_database()

        # Load active year and module settings
        self.active_year = int(database.get_setting("active_year", 1))
        self.active_module_id = database.get_setting("active_module_id")
        if self.active_module_id:
            try:
                self.active_module_id = int(self.active_module_id)
            except ValueError:
                self.active_module_id = None
        else:
            self.active_module_id = None

        self.modules_map = {}

        # Start Ollama background process check/boot and model pull
        threading.Thread(target=self.ensure_ollama_running, daemon=True).start()

        # Pre-warm the LaTeX rendering module in a background thread
        import latex_renderer
        latex_renderer.prewarm_latex()

        self.title("Project Nobel")
        self.geometry("1100x700")

        # Define colors for Light and Dark modes
        self.sidebar_bg = ("#F4F4F5", "#1C1C1E") # Subtle grey for sidebar
        self.main_bg = ("#FFFFFF", "#000000")    # Clean white/black for main
        self.btn_hover = ("#E5E5EA", "#2C2C2E")  # Grey hover/selection
        self.text_clr = ("#000000", "#FFFFFF")
        self.sys_font = ("SF Pro Display", 15)
        self.sys_font_bold = ("SF Pro Display", 20, "bold")

        # Configure grid layout
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=1)

        # Create sidebar frame (borderless)
        self.sidebar_frame = ctk.CTkFrame(self, width=200, corner_radius=0, fg_color=self.sidebar_bg)
        self.sidebar_frame.grid(row=0, column=0, sticky="nsew")

        self.logo_label = ctk.CTkLabel(self.sidebar_frame, text="Project Nobel", font=self.sys_font_bold, text_color=self.text_clr, cursor="hand2")
        self.logo_label.grid(row=0, column=0, padx=20, pady=(30, 10), sticky="w")
        self.logo_label.bind("<Button-1>", lambda e: self.select_frame("Dashboard"))

        # Study Mode State
        self.study_mode = "General"

        # Mode Toggle (Slider Segmented Button)
        self.mode_toggle = ctk.CTkSegmentedButton(
            self.sidebar_frame,
            values=["General", "Exam"],
            command=self.on_mode_change,
            font=("SF Pro Display", 11, "bold")
        )
        self.mode_toggle.grid(row=1, column=0, padx=20, pady=(0, 15), sticky="ew")
        self.mode_toggle.set("General")

        # Sidebar Buttons (left-aligned, seamless)
        self.nav_buttons = {}
        
        # --- Study Section (Top) ---
        self.btn_study = self.create_nav_button("Study", self.sidebar_frame)
        self.btn_study.grid(row=2, column=0, padx=10, pady=2, sticky="ew")

        self.btn_flashcards_study = self.create_nav_button("Flashcards", self.sidebar_frame)
        self.btn_flashcards_study.grid(row=3, column=0, padx=10, pady=2, sticky="ew")

        self.btn_problems_study = self.create_nav_button("Problems", self.sidebar_frame)
        self.btn_problems_study.grid(row=4, column=0, padx=10, pady=2, sticky="ew")

        self.btn_pre_lecture = self.create_nav_button("Pre-Lecture", self.sidebar_frame)
        self.btn_pre_lecture.grid(row=5, column=0, padx=10, pady=2, sticky="ew")

        self.btn_post_lecture = self.create_nav_button("Post-Lecture", self.sidebar_frame)
        self.btn_post_lecture.grid(row=6, column=0, padx=10, pady=2, sticky="ew")

        # Spacer to push the next section to the bottom
        self.sidebar_frame.grid_rowconfigure(7, weight=1)

        # --- Add Content Section (Bottom) ---
        self.add_label = ctk.CTkLabel(self.sidebar_frame, text="ADD CONTENT", font=("SF Pro Display", 12, "bold"), text_color="gray")
        self.add_label.grid(row=8, column=0, padx=20, pady=(10, 5), sticky="w")

        self.btn_notes = self.create_nav_button("Notes & Topics", self.sidebar_frame)
        self.btn_notes.grid(row=9, column=0, padx=10, pady=2, sticky="ew")

        self.btn_flashcards_add = self.create_nav_button("Add Flashcard", self.sidebar_frame)
        self.btn_flashcards_add.grid(row=10, column=0, padx=10, pady=2, sticky="ew")

        self.btn_problems_add = self.create_nav_button("Add Problem", self.sidebar_frame)
        self.btn_problems_add.grid(row=11, column=0, padx=10, pady=(2, 10), sticky="ew")

        # --- Active Module Selector (Bottom of Sidebar) ---
        self.active_module_label = ctk.CTkLabel(self.sidebar_frame, text="ACTIVE MODULE", font=("SF Pro Display", 11, "bold"), text_color="gray")
        self.active_module_label.grid(row=12, column=0, padx=20, pady=(15, 2), sticky="w")
        
        self.sidebar_module_dropdown = ctk.CTkOptionMenu(
            self.sidebar_frame, 
            values=["No Modules Found"], 
            command=self.on_sidebar_module_select,
            font=("SF Pro Display", 11),
            dropdown_font=("SF Pro Display", 11)
        )
        self.sidebar_module_dropdown.grid(row=13, column=0, padx=10, pady=(0, 20), sticky="ew")

        # Create native macOS menu bar for Edit Settings
        import tkinter as tk
        self.menubar = tk.Menu(self)
        self.edit_menu = tk.Menu(self.menubar, tearoff=0)
        self.edit_menu.add_command(label="Light Mode", command=lambda: ctk.set_appearance_mode("Light"))
        self.edit_menu.add_command(label="Dark Mode", command=lambda: ctk.set_appearance_mode("Dark"))
        self.edit_menu.add_command(label="System Default", command=lambda: ctk.set_appearance_mode("System"))
        self.edit_menu.add_separator()
        
        # Year radio button selectors
        self.year_var = tk.IntVar(value=self.active_year)
        self.edit_menu.add_radiobutton(label="Year 1", variable=self.year_var, value=1, command=self.on_menu_year_change)
        self.edit_menu.add_radiobutton(label="Year 2", variable=self.year_var, value=2, command=self.on_menu_year_change)
        self.edit_menu.add_radiobutton(label="Year 3", variable=self.year_var, value=3, command=self.on_menu_year_change)
        self.edit_menu.add_radiobutton(label="Year 4", variable=self.year_var, value=4, command=self.on_menu_year_change)
        self.edit_menu.add_separator()
        
        self.edit_menu.add_command(label="Manage Modules...", command=self.open_module_manager)
        
        self.menubar.add_cascade(label="Edit", menu=self.edit_menu)
        
        # Native "Flashcards" menu
        self.flashcards_menu = tk.Menu(self.menubar, tearoff=0)
        self.flashcards_menu.add_command(label="Manage Flashcards...", command=self.open_flashcard_manager)
        self.flashcards_menu.add_command(label="Export to Anki...", command=self.export_anki)
        self.menubar.add_cascade(label="Flashcards", menu=self.flashcards_menu)
        
        # Native "Problems" menu
        self.problems_menu = tk.Menu(self.menubar, tearoff=0)
        self.problems_menu.add_command(label="Manage Problems...", command=self.open_problem_manager)
        self.menubar.add_cascade(label="Problems", menu=self.problems_menu)
        
        # Native "Feynman Sandbox" menu
        self.feynman_menu = tk.Menu(self.menubar, tearoff=0)
        self.feynman_menu.add_command(label="Manage Feynman Sessions...", command=self.open_feynman_manager)
        self.menubar.add_cascade(label="Feynman Sandbox", menu=self.feynman_menu)
        
        self.config(menu=self.menubar)

        # Main content area
        self.main_frame = ctk.CTkFrame(self, corner_radius=0, fg_color=self.main_bg)
        self.main_frame.grid(row=0, column=1, sticky="nsew")
        self.main_frame.grid_rowconfigure(0, weight=1)
        self.main_frame.grid_columnconfigure(0, weight=1)

        # Dictionary to store different views
        self.frames = {}
        
        self.setup_frames()
        
        # Load initial modules list for stored active year
        self.load_modules_for_active_year(default_module_id=self.active_module_id)
                    
        self.select_frame("Dashboard")

        # Start background active study time tracker (ticks every 1 minute)
        self.after(60000, self.update_study_timer)

        # Gracefully handle window close to stop Ollama
        self.protocol("WM_DELETE_WINDOW", self.on_exit)

        # Bind Cmd+Option+Up/Down for module switching
        self.bind("<Command-Alt-Down>", self.switch_to_next_module)
        self.bind("<Command-Alt-Up>", self.switch_to_previous_module)
        self.bind("<Command-Option-Down>", self.switch_to_next_module)
        self.bind("<Command-Option-Up>", self.switch_to_previous_module)

        # Bind Cmd+1 to Cmd+6 for frame navigation
        self.bind("<Command-Key-1>", lambda e: self.select_frame("Dashboard"))
        self.bind("<Command-Key-2>", lambda e: self.select_frame("Study"))
        self.bind("<Command-Key-3>", lambda e: self.select_frame("Flashcards"))
        self.bind("<Command-Key-4>", lambda e: self.select_frame("Problems"))
        self.bind("<Command-Key-5>", lambda e: self.select_frame("Pre-Lecture"))
        self.bind("<Command-Key-6>", lambda e: self.select_frame("Post-Lecture"))

        # Bind Cmd+E to toggle study mode
        self.bind("<Command-e>", self.toggle_study_mode)
        self.bind("<Command-E>", self.toggle_study_mode)

    def create_nav_button(self, name, parent):
        btn = ctk.CTkButton(parent, text=name, 
                            fg_color="transparent", 
                            text_color=self.text_clr,
                            hover_color=self.btn_hover,
                            font=self.sys_font,
                            anchor="w",
                            corner_radius=6,
                            command=lambda n=name: self.select_frame(n))
        self.nav_buttons[name] = btn
        return btn

    def setup_frames(self):
        import flashcards_ui
        import modules_ui
        import interleaving_ui
        import post_lecture_ui
        import dashboard_ui
        import study_ui
        import pre_lecture_ui
        
        self.frames["Dashboard"] = dashboard_ui.DashboardView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Study"] = study_ui.StudyView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Flashcards"] = flashcards_ui.FlashcardReviewView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Problems"] = interleaving_ui.InterleavingReviewView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Pre-Lecture"] = pre_lecture_ui.PreLectureView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Post-Lecture"] = post_lecture_ui.PostLectureView(self.main_frame, corner_radius=0, fg_color="transparent")
        
        self.frames["Notes & Topics"] = modules_ui.ModulesView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Add Flashcard"] = flashcards_ui.FlashcardAddView(self.main_frame, corner_radius=0, fg_color="transparent")
        self.frames["Add Problem"] = interleaving_ui.InterleavingAddView(self.main_frame, corner_radius=0, fg_color="transparent")

    def select_frame(self, name):
        # Check if already on this frame before updating
        is_already_on_frame = getattr(self, "current_frame_name", None) == name
        self.current_frame_name = name

        # Update button colors to show selection
        for btn_name, btn in self.nav_buttons.items():
            if btn_name == name:
                btn.configure(fg_color=self.btn_hover)
            else:
                btn.configure(fg_color="transparent")

        # Hide all frames
        for frame in self.frames.values():
            frame.grid_remove()
        
        # Show selected frame
        if name == "Dashboard":
            self.frames["Dashboard"].load_dashboard()
        elif name == "Study":
            if is_already_on_frame and hasattr(self.frames["Study"], "reset_view"):
                self.frames["Study"].reset_view()
            
        self.frames[name].grid(row=0, column=0, sticky="nsew")

    def ensure_ollama_running(self):
        # 1. Check if Ollama is running, and if not, try to start it
        running = False
        for _ in range(3): # Try checking a few times
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.5)
            try:
                s.connect(("127.0.0.1", 11434))
                s.close()
                running = True
                break
            except Exception:
                # Not running, try starting it
                app_path = "/Applications/Ollama.app"
                if os.path.exists(app_path):
                    try:
                        # -g opens in background (no focus theft, window hidden on launch if configured)
                        subprocess.Popen(["open", "-g", "-a", "Ollama"])
                    except Exception:
                        pass
                time.sleep(1.5) # Wait for it to spin up
        
        if not running:
            print("Could not start Ollama.")
            return
            
        print("Ollama is active. Checking for qwen2.5vl model...")
        
        # 2. Check if qwen2.5vl (or any model) exists. If not, auto-pull qwen2.5vl
        try:
            req = urllib.request.Request("http://localhost:11434/api/tags")
            with urllib.request.urlopen(req, timeout=3) as response:
                data = json.loads(response.read().decode('utf-8'))
                models = [m['name'] for m in data.get('models', [])]
                
            # If no models installed, pull qwen2.5vl:7b
            if not models:
                print("No local models found. Pulling qwen2.5vl:7b in background...")
                body = {"model": "qwen2.5vl:7b", "stream": False}
                pull_req = urllib.request.Request(
                    "http://localhost:11434/api/pull",
                    data=json.dumps(body).encode('utf-8'),
                    headers={'Content-Type': 'application/json'}
                )
                with urllib.request.urlopen(pull_req, timeout=600) as pull_res:
                    print("qwen2.5vl:7b model pulled successfully.")
        except Exception as e:
            print(f"Error checking/pulling model: {e}")
            
        # 3. Start background AI processor to automatically process any pending notes
        try:
            import ai_helper
            threading.Thread(target=ai_helper.start_background_processor, name="AIProcessorManager", daemon=True).start()
            print("Background AI processor manager started successfully.")
        except Exception as e:
            print(f"Error starting background AI processor manager: {e}")

    def change_appearance_mode_event(self, new_appearance_mode: str):
        ctk.set_appearance_mode(new_appearance_mode)

    def set_active_module(self, module_id, sender_view=None):
        if self.active_module_id == module_id:
            return
            
        self.active_module_id = module_id
        database.set_setting("active_module_id", module_id if module_id is not None else "")
        
        # Find display string for this module_id
        display_str = None
        for key, val in self.modules_map.items():
            if val == module_id:
                display_str = key
                break
        
        if display_str:
            # Disable command temporarily to prevent double callback
            self.sidebar_module_dropdown.configure(command=None)
            self.sidebar_module_dropdown.set(display_str)
            self.sidebar_module_dropdown.configure(command=self.on_sidebar_module_select)
        else:
            self.sidebar_module_dropdown.set("No Modules Found")
            
        # Update all view frames that are not the sender
        for name, frame in self.frames.items():
            if frame != sender_view and hasattr(frame, "update_active_module"):
                try:
                    frame.update_active_module(module_id)
                except Exception as e:
                    print(f"Error updating frame {name} with active module {module_id}: {e}")

    def on_sidebar_module_select(self, choice):
        module_id = self.modules_map.get(choice)
        if module_id:
            self.set_active_module(module_id)

    def on_exit(self):
        print("Stopping Ollama...")
        try:
            subprocess.Popen(["osascript", "-e", 'tell application "Ollama" to quit'])
        except Exception as e:
            print(f"Error stopping Ollama: {e}")
        self.destroy()

    def switch_to_next_module(self, event=None):
        if not self.modules_map:
            return
        keys = list(self.modules_map.keys())
        current_display = self.sidebar_module_dropdown.get()
        if current_display in keys:
            idx = keys.index(current_display)
            next_idx = (idx + 1) % len(keys)
            self.set_active_module(self.modules_map[keys[next_idx]])
            
    def switch_to_previous_module(self, event=None):
        if not self.modules_map:
            return
        keys = list(self.modules_map.keys())
        current_display = self.sidebar_module_dropdown.get()
        if current_display in keys:
            idx = keys.index(current_display)
            prev_idx = (idx - 1 + len(keys)) % len(keys)
            self.set_active_module(self.modules_map[keys[prev_idx]])

    def toggle_study_mode(self, event=None):
        new_mode = "Exam" if self.study_mode == "General" else "General"
        self.mode_toggle.set(new_mode)
        self.on_mode_change(new_mode)

    def on_menu_year_change(self):
        self.active_year = self.year_var.get()
        database.set_setting("active_year", self.active_year)
        self.load_modules_for_active_year()
        if getattr(self, "current_frame_name", None) == "Dashboard":
            self.frames["Dashboard"].load_dashboard()

    def open_module_manager(self):
        if hasattr(self, "module_manager_window") and self.module_manager_window and self.module_manager_window.winfo_exists():
            self.module_manager_window.lift()
            self.module_manager_window.focus_set()
        else:
            import module_manager
            self.module_manager_window = module_manager.ModuleManagerWindow(self)

    def refresh_sidebar_modules(self):
        self.load_modules_for_active_year()

    def load_modules_for_active_year(self, default_module_id=None):
        self.modules_map = {}
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT id, code, name FROM modules WHERE year = ? ORDER BY code ASC", (self.active_year,))
        rows = c.fetchall()
        conn.close()
        
        for row in rows:
            self.modules_map[f"{row[1]} - {row[2]}"] = row[0]
            
        module_values = list(self.modules_map.keys()) if self.modules_map else ["No Modules Found"]
        self.sidebar_module_dropdown.configure(values=module_values)
        
        if self.modules_map:
            # Determine target active module ID
            target_id = default_module_id if default_module_id in self.modules_map.values() else None
            if not target_id and self.active_module_id in self.modules_map.values():
                target_id = self.active_module_id
                
            if target_id:
                # Find key for target_id
                target_key = next(key for key, val in self.modules_map.items() if val == target_id)
                self.sidebar_module_dropdown.set(target_key)
                self.set_active_module(target_id)
            else:
                first_key = list(self.modules_map.keys())[0]
                self.sidebar_module_dropdown.set(first_key)
                self.set_active_module(self.modules_map[first_key])
        else:
            self.sidebar_module_dropdown.set("No Modules Found")
            self.set_active_module(None)

    def open_flashcard_manager(self):
        if hasattr(self, "flashcard_manager_window") and self.flashcard_manager_window and self.flashcard_manager_window.winfo_exists():
            self.flashcard_manager_window.lift()
            self.flashcard_manager_window.focus_set()
        else:
            import flashcard_manager
            self.flashcard_manager_window = flashcard_manager.FlashcardManagerWindow(self)

    def export_anki(self):
        import tkinter.filedialog as filedialog
        import csv
        import tkinter.messagebox as messagebox
        
        # Query all flashcards
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            SELECT m.code, f.front, f.back 
            FROM flashcards f
            JOIN modules m ON f.module_id = m.id
            ORDER BY m.code ASC, f.id DESC
        """)
        rows = c.fetchall()
        conn.close()
        
        if not rows:
            messagebox.showinfo("No Flashcards", "There are no flashcards to export.", parent=self)
            return
            
        file_path = filedialog.asksaveasfilename(
            parent=self,
            defaultextension=".csv",
            filetypes=[("CSV files", "*.csv"), ("All files", "*.*")],
            title="Export Flashcards for Anki",
            initialfile="anki_flashcards.csv"
        )
        if not file_path:
            return
            
        try:
            with open(file_path, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                for code, front, back in rows:
                    writer.writerow([front, back, code])
            messagebox.showinfo("Export Successful", f"Successfully exported {len(rows)} flashcards.", parent=self)
        except Exception as e:
            messagebox.showerror("Export Failed", f"An error occurred while exporting: {e}", parent=self)

    def open_problem_manager(self):
        if hasattr(self, "problem_manager_window") and self.problem_manager_window and self.problem_manager_window.winfo_exists():
            self.problem_manager_window.lift()
            self.problem_manager_window.focus_set()
        else:
            import problem_manager
            self.problem_manager_window = problem_manager.ProblemManagerWindow(self)

    def open_feynman_manager(self):
        if hasattr(self, "feynman_manager_window") and self.feynman_manager_window and self.feynman_manager_window.winfo_exists():
            self.feynman_manager_window.lift()
            self.feynman_manager_window.focus_set()
        else:
            import feynman_manager
            self.feynman_manager_window = feynman_manager.FeynmanManagerWindow(self)

    def update_study_timer(self):
        frame_name = getattr(self, "current_frame_name", None)
        flashcards_delta = 0
        problems_delta = 0
        
        if frame_name == "Flashcards":
            flashcards_delta = 60
        elif frame_name in ("Problems", "Post-Lecture"):
            problems_delta = 60
            
        if flashcards_delta > 0 or problems_delta > 0:
            database.add_study_time(flashcards_delta, problems_delta)
            if self.active_module_id:
                database.add_module_study_time(self.active_module_id, flashcards_delta, problems_delta)

        # Refresh ratio bar in the active view
        current_frame = self.frames.get(frame_name)
        if current_frame and hasattr(current_frame, "ratio_bar"):
            try:
                current_frame.ratio_bar.refresh_time()
            except:
                pass

        self.after(60000, self.update_study_timer)

    def on_mode_change(self, mode):
        self.study_mode = mode
        # Defer execution to let the button release event loop finish, ensuring immediate repaint
        self.after(10, lambda: self._apply_mode_change(mode))

    def _apply_mode_change(self, mode):
        # Create log dir if missing
        log_dir = os.path.expanduser("~/.physics_study_app")
        os.makedirs(log_dir, exist_ok=True)
        log_file = os.path.join(log_dir, "app_debug.log")
        
        try:
            with open(log_file, "a") as f:
                f.write(f"--- _apply_mode_change triggered --- mode={mode}, current_frame={getattr(self, 'current_frame_name', 'None')}\n")
        except:
            pass

        try:
            if mode == "Exam":
                # Hide Pre-Lecture and Post-Lecture buttons using grid_forget
                self.btn_pre_lecture.grid_forget()
                self.btn_post_lecture.grid_forget()
                # Hide ADD CONTENT section and all its buttons
                self.add_label.grid_forget()
                self.btn_notes.grid_forget()
                self.btn_flashcards_add.grid_forget()
                self.btn_problems_add.grid_forget()
                
                # Redirection: if currently viewing a hidden frame, switch to Study
                hidden_frames = ["Pre-Lecture", "Post-Lecture", "Notes & Topics", "Add Flashcard", "Add Problem"]
                if getattr(self, "current_frame_name", None) in hidden_frames:
                    self.select_frame("Study")
                try:
                    with open(log_file, "a") as f:
                        f.write("Successfully forgot exam-hidden widgets in _apply_mode_change.\n")
                except:
                    pass
            else:
                # Show Pre-Lecture and Post-Lecture buttons
                self.btn_pre_lecture.grid(row=5, column=0, padx=10, pady=2, sticky="ew")
                self.btn_post_lecture.grid(row=6, column=0, padx=10, pady=2, sticky="ew")
                # Show ADD CONTENT section and all its buttons at updated row positions
                self.add_label.grid(row=8, column=0, padx=20, pady=(10, 5), sticky="w")
                self.btn_notes.grid(row=9, column=0, padx=10, pady=2, sticky="ew")
                self.btn_flashcards_add.grid(row=10, column=0, padx=10, pady=2, sticky="ew")
                self.btn_problems_add.grid(row=11, column=0, padx=10, pady=(2, 10), sticky="ew")
                try:
                    with open(log_file, "a") as f:
                        f.write("Successfully gridded general widgets in _apply_mode_change.\n")
                except:
                    pass
        except Exception as e:
            try:
                with open(log_file, "a") as f:
                    f.write(f"Exception during widget grid updates: {e}\n")
            except:
                pass

        try:
            # Trigger reload of active reviews to adapt to new mode dataset
            current_frame = self.frames.get(getattr(self, "current_frame_name", None))
            if getattr(self, "current_frame_name", None) == "Flashcards" and hasattr(current_frame, "load_due_cards"):
                current_frame.load_due_cards()
            elif getattr(self, "current_frame_name", None) == "Problems" and hasattr(current_frame, "load_random_problem"):
                current_frame.load_random_problem()
                
            # Refresh the ratio tracker bar immediately to adapt to new target boundaries
            if current_frame and hasattr(current_frame, "ratio_bar"):
                try:
                    current_frame.ratio_bar.refresh_time()
                except:
                    pass
            try:
                with open(log_file, "a") as f:
                    f.write("Successfully refreshed active frame in _apply_mode_change.\n")
            except:
                pass
        except Exception as e:
            try:
                with open(log_file, "a") as f:
                    f.write(f"Exception during frame reload: {e}\n")
            except:
                pass

        # Force CustomTkinter canvas redraw and layout refresh
        self.sidebar_frame.configure(fg_color=self.sidebar_bg)
        if hasattr(self.sidebar_frame, "_draw"):
            self.sidebar_frame._draw()
        for child in self.sidebar_frame.winfo_children():
            if hasattr(child, "_draw"):
                child._draw()
        self.update_idletasks()
        self.update()


if __name__ == "__main__":
    app = App()
    app.mainloop()
