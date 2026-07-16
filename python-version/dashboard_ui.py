import customtkinter as ctk
import database
import datetime
import tkinter as tk
import threading
import re

def get_timeframe_start_date(timeframe):
    today = datetime.date.today()
    if timeframe == "Today":
        return today.isoformat()
    elif timeframe == "This Week":
        return (today - datetime.timedelta(days=7)).isoformat()
    elif timeframe == "This Month":
        return (today - datetime.timedelta(days=30)).isoformat()
    else: # All Time
        return "1970-01-01"

def get_avg_solve_times(timeframe_start_date):
    conn = database.get_connection()
    c = conn.cursor()
    
    # 1. Get total seconds spent
    c.execute("""
        SELECT SUM(flashcards_seconds), SUM(problems_seconds) 
        FROM daily_study_time 
        WHERE date >= ?
    """, (timeframe_start_date,))
    row = c.fetchone()
    total_fc_sec = row[0] if row and row[0] is not None else 0
    total_prob_sec = row[1] if row and row[1] is not None else 0
    
    # 2. Get total review events from activity_log
    c.execute("""
        SELECT activity_type, COUNT(*) 
        FROM activity_log 
        WHERE date(timestamp) >= ? 
        GROUP BY activity_type
    """, (timeframe_start_date,))
    log_rows = c.fetchall()
    conn.close()
    
    fc_count = 0
    prob_count = 0
    for act_type, count in log_rows:
        if act_type == 'flashcard':
            fc_count = count
        elif act_type == 'interleaving':
            prob_count = count
            
    avg_fc = total_fc_sec / fc_count if fc_count > 0 else 0
    avg_prob = total_prob_sec / prob_count if prob_count > 0 else 0
    
    return avg_fc, avg_prob

def get_created_counts_grouped(timeframe):
    today = datetime.date.today()
    conn = database.get_connection()
    c = conn.cursor()
    
    labels = []
    fc_vals = []
    prob_vals = []
    
    if timeframe == "Today":
        labels = ["Today"]
        c.execute("SELECT COUNT(*) FROM flashcards WHERE created_date = ?", (today.isoformat(),))
        fc_vals = [c.fetchone()[0]]
        c.execute("SELECT COUNT(*) FROM problems WHERE created_date = ?", (today.isoformat(),))
        prob_vals = [c.fetchone()[0]]
        
    elif timeframe == "This Week":
        days = [today - datetime.timedelta(days=i) for i in range(6, -1, -1)]
        labels = [d.strftime("%a") for d in days]
        for d in days:
            c.execute("SELECT COUNT(*) FROM flashcards WHERE created_date = ?", (d.isoformat(),))
            fc_vals.append(c.fetchone()[0])
            c.execute("SELECT COUNT(*) FROM problems WHERE created_date = ?", (d.isoformat(),))
            prob_vals.append(c.fetchone()[0])
            
    elif timeframe == "This Month":
        labels = ["Wk 4 (Old)", "Wk 3", "Wk 2", "Wk 1 (New)"]
        ranges = [
            (today - datetime.timedelta(days=30), today - datetime.timedelta(days=22)),
            (today - datetime.timedelta(days=21), today - datetime.timedelta(days=15)),
            (today - datetime.timedelta(days=14), today - datetime.timedelta(days=8)),
            (today - datetime.timedelta(days=7), today)
        ]
        for start, end in ranges:
            c.execute("SELECT COUNT(*) FROM flashcards WHERE created_date BETWEEN ? AND ?", (start.isoformat(), end.isoformat()))
            fc_vals.append(c.fetchone()[0])
            c.execute("SELECT COUNT(*) FROM problems WHERE created_date BETWEEN ? AND ?", (start.isoformat(), end.isoformat()))
            prob_vals.append(c.fetchone()[0])
            
    else: # All Time
        months = []
        curr_year = today.year
        curr_month = today.month
        for _ in range(6):
            months.append(f"{curr_year:04d}-{curr_month:02d}")
            curr_month -= 1
            if curr_month == 0:
                curr_month = 12
                curr_year -= 1
        months.reverse()
            
        labels = [datetime.datetime.strptime(m, "%Y-%m").strftime("%b") for m in months]
        for m in months:
            c.execute("SELECT COUNT(*) FROM flashcards WHERE created_date LIKE ?", (f"{m}%",))
            fc_vals.append(c.fetchone()[0])
            c.execute("SELECT COUNT(*) FROM problems WHERE created_date LIKE ?", (f"{m}%",))
            prob_vals.append(c.fetchone()[0])
            
    conn.close()
    return labels, fc_vals, prob_vals

def get_ai_task_stats():
    import os
    conn = database.get_connection()
    c = conn.cursor()
    c.execute("SELECT id, file_path, ai_summary, pre_lecture_primer FROM notes")
    rows = c.fetchall()
    conn.close()
    
    total_notes = 0
    sum_done = 0
    primer_done = 0
    
    import ai_helper
    for row in rows:
        n_id, file_path, ai_summary, pre_lecture_primer = row
        if n_id in ai_helper.failed_note_ids:
            continue
        if not file_path:
            continue
            
        total_notes += 1
        if ai_summary and ai_summary.strip():
            sum_done += 1
        if pre_lecture_primer and pre_lecture_primer.strip():
            primer_done += 1
            
    if total_notes == 0:
        return 100, 0, 0, []
        
    total_tasks = total_notes * 2
    completed_tasks = sum_done + primer_done
    percentage = int((completed_tasks / total_tasks) * 100) if total_tasks > 0 else 100
    
    # Check active thread pools
    active_ai_threads = [t for t in threading.enumerate() if t.name.startswith("AI_Summary_") or t.name.startswith("AI_Primer_")]
    running_jobs = []
    for t in active_ai_threads:
        parts = t.name.split("_")
        if len(parts) >= 3:
            job_type = parts[1]
            note_id = parts[2]
            running_jobs.append(f"{job_type} (Note ID {note_id})")
            
    return percentage, completed_tasks, total_tasks, running_jobs

class DashboardView(ctk.CTkScrollableFrame):
    def __init__(self, master, **kwargs):
        kwargs.setdefault("fg_color", "transparent")
        super().__init__(master, **kwargs)
        
        # Grid settings
        self.grid_columnconfigure(0, weight=1)
        
        # Header + Timeframe Row
        self.header_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.header_frame.pack(fill="x", padx=30, pady=(30, 15))
        
        self.header_label = ctk.CTkLabel(self.header_frame, text="Dashboard", font=("SF Pro Display", 28, "bold"))
        self.header_label.pack(side="left")
        
        self.timeframe_dropdown = ctk.CTkOptionMenu(
            self.header_frame,
            values=["Today", "This Week", "This Month", "All Time"],
            command=lambda val: self.load_dashboard(),
            font=("SF Pro Display", 12, "bold"),
            width=120
        )
        self.timeframe_dropdown.pack(side="right")
        self.timeframe_dropdown.set("This Week")
        
        # 1. Metrics Row (4 Cards)
        self.metrics_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.metrics_frame.pack(fill="x", padx=30, pady=10)
        self.metrics_frame.grid_columnconfigure((0, 1, 2, 3), weight=1, uniform="equal")
        
        # Card colors
        card_bg = ("#F2F2F7", "#1C1C1E")
        
        # Card 1: Flashcards Created
        self.card_fc_created = self.create_metric_card(self.metrics_frame, "FLASHCARDS CREATED", "0", 0, card_bg)
        self.lbl_fc_created = self.card_fc_created._value_lbl
        
        # Card 2: Problems Created
        self.card_prob_created = self.create_metric_card(self.metrics_frame, "PROBLEMS CREATED", "0", 1, card_bg)
        self.lbl_prob_created = self.card_prob_created._value_lbl
        
        # Card 3: Avg Flashcard Time
        self.card_fc_avg = self.create_metric_card(self.metrics_frame, "AVG FLASHCARD TIME", "0s", 2, card_bg)
        self.lbl_fc_avg = self.card_fc_avg._value_lbl
        
        # Card 4: Avg Problem Time
        self.card_prob_avg = self.create_metric_card(self.metrics_frame, "AVG PROBLEM TIME", "0s", 3, card_bg)
        self.lbl_prob_avg = self.card_prob_avg._value_lbl
        
        # 2. Charts Row (Created vs. Time Spent)
        self.charts_container = ctk.CTkFrame(self, fg_color="transparent")
        self.charts_container.pack(fill="x", padx=30, pady=15)
        self.charts_container.grid_columnconfigure((0, 1), weight=1, uniform="equal")
        
        # Chart 1 Card (Left)
        self.created_chart_card = ctk.CTkFrame(self.charts_container, fg_color=card_bg, corner_radius=12)
        self.created_chart_card.grid(row=0, column=0, padx=(0, 10), sticky="nsew")
        
        lbl_created_title = ctk.CTkLabel(self.created_chart_card, text="FLASHCARDS & PROBLEMS CREATED", font=("SF Pro Display", 11, "bold"), text_color="gray")
        lbl_created_title.pack(anchor="w", padx=20, pady=(15, 5))
        
        self.created_canvas = tk.Canvas(self.created_chart_card, bg="#FFFFFF", highlightthickness=0, height=220)
        self.created_canvas.pack(fill="both", expand=True, padx=20, pady=(5, 15))
        
        # Chart 2 Card (Right)
        self.time_chart_card = ctk.CTkFrame(self.charts_container, fg_color=card_bg, corner_radius=12)
        self.time_chart_card.grid(row=0, column=1, padx=(10, 0), sticky="nsew")
        
        lbl_time_title = ctk.CTkLabel(self.time_chart_card, text="STUDY TIME DISTRIBUTION & RATIO", font=("SF Pro Display", 11, "bold"), text_color="gray")
        lbl_time_title.pack(anchor="w", padx=20, pady=(15, 5))
        
        # Split Right card into canvas (left half) and stats (right half)
        self.time_split_frame = ctk.CTkFrame(self.time_chart_card, fg_color="transparent")
        self.time_split_frame.pack(fill="both", expand=True, padx=20, pady=(5, 15))
        self.time_split_frame.grid_columnconfigure(0, weight=1)
        self.time_split_frame.grid_columnconfigure(1, weight=1)
        
        self.time_canvas = tk.Canvas(self.time_split_frame, bg="#FFFFFF", highlightthickness=0, height=220)
        self.time_canvas.grid(row=0, column=0, sticky="nsew")
        
        self.time_stats_frame = ctk.CTkFrame(self.time_split_frame, fg_color="transparent")
        self.time_stats_frame.grid(row=0, column=1, padx=(15, 0), sticky="nsew")
        
        self.lbl_total_fc_time = ctk.CTkLabel(self.time_stats_frame, text="Flashcard Time: 0s", font=("SF Pro Display", 13, "bold"), text_color="#FF9500", anchor="w")
        self.lbl_total_fc_time.pack(fill="x", pady=(20, 5))
        
        self.lbl_total_prob_time = ctk.CTkLabel(self.time_stats_frame, text="Problem Time: 0s", font=("SF Pro Display", 13, "bold"), text_color="#34C759", anchor="w")
        self.lbl_total_prob_time.pack(fill="x", pady=5)
        
        self.lbl_time_ratio = ctk.CTkLabel(self.time_stats_frame, text="Ratio: 0% / 0%", font=("SF Pro Display", 14, "bold"), anchor="w")
        self.lbl_time_ratio.pack(fill="x", pady=15)
        
        # 3. Study Heatmap Row
        self.heatmap_card = ctk.CTkFrame(self, fg_color=card_bg, corner_radius=12)
        self.heatmap_card.pack(fill="x", padx=30, pady=15)
        
        self.heatmap_header = ctk.CTkFrame(self.heatmap_card, fg_color="transparent")
        self.heatmap_header.pack(fill="x", padx=20, pady=(15, 10))
        
        self.lbl_heatmap_title = ctk.CTkLabel(self.heatmap_header, text="DAILY STUDY ACTIVITY HEATMAP", font=("SF Pro Display", 11, "bold"), text_color="gray")
        self.lbl_heatmap_title.pack(side="left")
        
        # Load modules for the heatmap dropdown filter
        self.heatmap_modules_map = {"All Modules": None}
        self.heatmap_modules_list = ["All Modules"]
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT id, code, name FROM modules ORDER BY code ASC")
        for row in c.fetchall():
            display_str = f"{row[1]} - {row[2]}"
            self.heatmap_modules_map[display_str] = row[0]
            self.heatmap_modules_list.append(display_str)
        conn.close()
        
        self.heatmap_dropdown = ctk.CTkOptionMenu(
            self.heatmap_header,
            values=self.heatmap_modules_list,
            command=lambda val: self.load_heatmap_data(),
            font=("SF Pro Display", 11),
            width=180
        )
        self.heatmap_dropdown.pack(side="right")
        self.heatmap_dropdown.set("All Modules")
        
        # Heatmap Canvas
        self.heatmap_canvas = tk.Canvas(self.heatmap_card, bg="#FFFFFF", highlightthickness=0, height=130)
        self.heatmap_canvas.pack(fill="x", padx=20, pady=(5, 15))
        self.heatmap_canvas.bind("<Configure>", lambda e: self.render_heatmap())
        
        # 4. Module Activity Table Row
        self.module_table_card = ctk.CTkFrame(self, fg_color=card_bg, corner_radius=12)
        self.module_table_card.pack(fill="x", padx=30, pady=15)
        
        self.table_header_frame = ctk.CTkFrame(self.module_table_card, fg_color="transparent")
        self.table_header_frame.pack(fill="x", padx=20, pady=(15, 5))
        
        self.lbl_table_title = ctk.CTkLabel(self.table_header_frame, text="MODULE STUDY ACTIVITY", font=("SF Pro Display", 11, "bold"), text_color="gray")
        self.lbl_table_title.pack(side="left")
        
        # Determine default semester filter based on current month
        import datetime
        month = datetime.date.today().month
        if month in [9, 10, 11, 12, 1]:
            default_sem = "Semester 1"
        elif month in [2, 3, 4, 5, 6]:
            default_sem = "Semester 2"
        else:
            default_sem = "Both Semesters"
            
        self.semester_dropdown = ctk.CTkOptionMenu(
            self.table_header_frame,
            values=["Semester 1", "Semester 2", "Both Semesters"],
            command=lambda val: self.load_module_table(),
            font=("SF Pro Display", 11),
            width=140
        )
        self.semester_dropdown.pack(side="right")
        self.semester_dropdown.set(default_sem)
        
        # Table container
        self.table_container = ctk.CTkFrame(self.module_table_card, fg_color="transparent")
        self.table_container.pack(fill="x", padx=20, pady=(5, 15))

        # 5. Local AI Task Progress Row
        self.ai_card = ctk.CTkFrame(self, fg_color=card_bg, corner_radius=12)
        self.ai_card.pack(fill="x", padx=30, pady=(15, 30))
        
        self.ai_card_header = ctk.CTkFrame(self.ai_card, fg_color="transparent")
        self.ai_card_header.pack(fill="x", padx=20, pady=(15, 10))
        
        self.lbl_ai_title = ctk.CTkLabel(self.ai_card_header, text="LOCAL AI TASK TRACKER (QWEN)", font=("SF Pro Display", 11, "bold"), text_color="gray")
        self.lbl_ai_title.pack(side="left")
        
        self.ai_status_badge = ctk.CTkLabel(
            self.ai_card_header, 
            text="IDLE", 
            font=("SF Pro Display", 10, "bold"), 
            text_color="white", 
            fg_color="#34C759", 
            corner_radius=4,
            padx=6,
            pady=2
        )
        self.ai_status_badge.pack(side="right")
        
        self.ai_progress_frame = ctk.CTkFrame(self.ai_card, fg_color="transparent")
        self.ai_progress_frame.pack(fill="x", padx=20, pady=(5, 10))
        
        self.ai_progress_bar = ctk.CTkProgressBar(self.ai_progress_frame, height=12)
        self.ai_progress_bar.pack(fill="x", side="left", expand=True, padx=(0, 20))
        self.ai_progress_bar.set(0.0)
        
        self.ai_percentage_label = ctk.CTkLabel(self.ai_progress_frame, text="0% complete", font=("SF Pro Display", 13, "bold"))
        self.ai_percentage_label.pack(side="right")
        
        self.ai_footer_frame = ctk.CTkFrame(self.ai_card, fg_color="transparent")
        self.ai_footer_frame.pack(fill="x", padx=20, pady=(0, 15))
        
        self.ai_jobs_label = ctk.CTkLabel(self.ai_footer_frame, text="All local notes are fully summarized and primed.", font=("SF Pro Display", 12), text_color="#3A3A3C", anchor="w")
        self.ai_jobs_label.pack(side="left", fill="x", expand=True)
        
        self.ai_stats_label = ctk.CTkLabel(self.ai_footer_frame, text="0 / 0 tasks processed", font=("SF Pro Display", 12), text_color="gray", anchor="e")
        self.ai_stats_label.pack(side="right")
        
        # Initialize chart data storage and bindings
        self.created_chart_data = ([], [], [])
        self.time_chart_data = (0, 0)
        self.created_canvas.bind("<Configure>", lambda e: self.render_created_chart())
        self.time_canvas.bind("<Configure>", lambda e: self.render_time_chart())
        
        # Init first data load
        self.load_dashboard()
        
        # Start AI Task Progress poll
        self.start_ai_tracker_loop()

    def create_metric_card(self, parent, title, initial_val, col, bg_color):
        card = ctk.CTkFrame(parent, fg_color=bg_color, corner_radius=12)
        card.grid(row=0, column=col, padx=8 if col in (1, 2) else (0, 8) if col == 0 else (8, 0), sticky="nsew")
        
        lbl_title = ctk.CTkLabel(card, text=title, font=("SF Pro Display", 10, "bold"), text_color="gray")
        lbl_title.pack(anchor="w", padx=15, pady=(15, 2))
        
        lbl_value = ctk.CTkLabel(card, text=initial_val, font=("SF Pro Display", 28, "bold"))
        lbl_value.pack(anchor="w", padx=15, pady=(0, 15))
        
        card._value_lbl = lbl_value
        return card

    def load_dashboard(self):
        timeframe = self.timeframe_dropdown.get()
        start_date = get_timeframe_start_date(timeframe)
        
        # 1. Query created items
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("SELECT COUNT(*) FROM flashcards WHERE created_date >= ?", (start_date,))
        fc_created = c.fetchone()[0]
        c.execute("SELECT COUNT(*) FROM problems WHERE created_date >= ?", (start_date,))
        prob_created = c.fetchone()[0]
        conn.close()
        
        # 2. Query average solve times
        avg_fc, avg_prob = get_avg_solve_times(start_date)
        
        def format_time(seconds):
            if seconds <= 0:
                return "0s"
            if seconds < 60:
                return f"{int(seconds)}s"
            minutes = int(seconds // 60)
            sec = int(seconds % 60)
            if minutes > 0:
                return f"{minutes}m {sec}s"
            return f"{sec}s"
            
        fc_avg_str = format_time(avg_fc)
        prob_avg_str = format_time(avg_prob)
        
        # Update metrics cards
        self.lbl_fc_created.configure(text=str(fc_created))
        self.lbl_prob_created.configure(text=str(prob_created))
        self.lbl_fc_avg.configure(text=fc_avg_str)
        self.lbl_prob_avg.configure(text=prob_avg_str)
        
        # 3. Render Chart 1 (Created items)
        labels_created, fc_created_vals, prob_created_vals = get_created_counts_grouped(timeframe)
        self.draw_created_chart(labels_created, fc_created_vals, prob_created_vals)
        
        # 4. Render Chart 2 (Time spent & Donut)
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("""
            SELECT SUM(flashcards_seconds), SUM(problems_seconds) 
            FROM daily_study_time 
            WHERE date >= ?
        """, (start_date,))
        row = c.fetchone()
        conn.close()
        
        total_fc_sec = row[0] if row and row[0] is not None else 0
        total_prob_sec = row[1] if row and row[1] is not None else 0
        
        # Update stats text
        self.lbl_total_fc_time.configure(text=f"Flashcard Time: {format_time(total_fc_sec)}")
        self.lbl_total_prob_time.configure(text=f"Problem Time: {format_time(total_prob_sec)}")
        
        total_sec = total_fc_sec + total_prob_sec
        if total_sec > 0:
            fc_pct = round((total_fc_sec / total_sec) * 100)
            prob_pct = 100 - fc_pct
            self.lbl_time_ratio.configure(text=f"Ratio: {fc_pct}% FC / {prob_pct}% Problems")
        else:
            self.lbl_time_ratio.configure(text="Ratio: No study time logged")
            
        self.draw_time_chart(total_fc_sec, total_prob_sec)
        
        # Reload heatmap and module table
        if hasattr(self, "heatmap_canvas"):
            self.load_heatmap_data()
            self.load_module_table()

    def draw_created_chart(self, labels, fc_values, int_values):
        self.created_chart_data = (labels, fc_values, int_values)
        self.render_created_chart()

    def render_created_chart(self):
        self.created_canvas.delete("all")
        
        # Background color selection
        bg_color = self._apply_appearance_mode(("#F2F2F7", "#2C2C2E"))
        self.created_canvas.configure(bg=bg_color)
        
        # Label text colors
        text_color = self._apply_appearance_mode(("black", "white"))
        grid_color = self._apply_appearance_mode(("#E5E5EA", "#3A3A3C"))
        
        w = self.created_canvas.winfo_width()
        h = self.created_canvas.winfo_height()
        
        if w < 50 or h < 50:
            return
            
        labels, fc_values, int_values = self.created_chart_data
        if not labels:
            return
            
        margin_x = 35
        margin_y = 35
        margin_bottom = 25
        
        chart_w = w - 2 * margin_x
        chart_h = h - margin_y - margin_bottom
        
        if chart_w <= 0 or chart_h <= 0:
            return

        max_val = max(max(fc_values), max(int_values)) if fc_values and int_values else 0
        if max_val == 0:
            max_val = 1
            
        # Draw legend
        self.created_canvas.create_rectangle(w - 180, 10, w - 168, 22, fill="#FF9500", outline="")
        self.created_canvas.create_text(w - 163, 16, text="Flashcards", anchor="w", font=("SF Pro Display", 10), fill=text_color)
        
        self.created_canvas.create_rectangle(w - 90, 10, w - 78, 22, fill="#34C759", outline="")
        self.created_canvas.create_text(w - 73, 16, text="Problems", anchor="w", font=("SF Pro Display", 10), fill=text_color)
        
        # Horizontal grids
        num_lines = 4
        for i in range(num_lines + 1):
            y = margin_y + (chart_h / num_lines) * i
            self.created_canvas.create_line(margin_x, y, w - margin_x, y, fill=grid_color, dash=(4, 4))
            val = max_val - (max_val / num_lines) * i
            self.created_canvas.create_text(margin_x - 10, y, text=f"{int(val)}", anchor="e", fill="gray", font=("SF Pro Display", 9))

        # Draw double bars
        num_intervals = len(labels)
        interval_width = chart_w / num_intervals
        bar_width = min(interval_width * 0.25, 20)
        
        for i, label in enumerate(labels):
            x_center = margin_x + i * interval_width + interval_width / 2
            
            # Flashcard bar (Orange)
            fc_val = fc_values[i] if i < len(fc_values) else 0
            fc_h = (fc_val / max_val) * chart_h
            fc_y = margin_y + chart_h - fc_h
            if fc_h > 0:
                self.created_canvas.create_rectangle(x_center - bar_width, fc_y, x_center, margin_y + chart_h, fill="#FF9500", outline="")
            
            # Problem bar (Green)
            prob_val = int_values[i] if i < len(int_values) else 0
            prob_h = (prob_val / max_val) * chart_h
            prob_y = margin_y + chart_h - prob_h
            if prob_h > 0:
                self.created_canvas.create_rectangle(x_center, prob_y, x_center + bar_width, margin_y + chart_h, fill="#34C759", outline="")
            
            # Label
            self.created_canvas.create_text(x_center, margin_y + chart_h + 12, text=label, fill="gray", font=("SF Pro Display", 9))

    def draw_time_chart(self, fc_seconds, prob_seconds):
        self.time_chart_data = (fc_seconds, prob_seconds)
        self.render_time_chart()

    def render_time_chart(self):
        self.time_canvas.delete("all")
        
        bg_color = self._apply_appearance_mode(("#F2F2F7", "#2C2C2E"))
        self.time_canvas.configure(bg=bg_color)
        
        text_color = self._apply_appearance_mode(("black", "white"))
        
        w = self.time_canvas.winfo_width()
        h = self.time_canvas.winfo_height()
        
        if w < 50 or h < 50:
            return
            
        fc_seconds, prob_seconds = self.time_chart_data
        
        # Center of donut chart
        cx, cy = w / 2, h / 2
        r = min(w, h) * 0.38
        inner_r = r * 0.58
        
        total = fc_seconds + prob_seconds
        
        if total == 0:
            # Draw empty grey donut
            self.time_canvas.create_oval(cx - r, cy - r, cx + r, cy + r, fill="#D1D1D6", outline="")
            self.time_canvas.create_oval(cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r, fill=bg_color, outline="")
            self.time_canvas.create_text(cx, cy, text="No Data", fill="gray", font=("SF Pro Display", 11, "bold"))
            return
            
        fc_ratio = fc_seconds / total
        fc_angle = fc_ratio * 360
        prob_angle = 360 - fc_angle
        
        # Draw arcs (Tkinter arc start is in degrees, counter-clockwise from X-axis)
        # Orange for Flashcards, Green for Problems
        if fc_angle > 0:
            self.time_canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=90, extent=fc_angle, fill="#FF9500", outline="")
        if prob_angle > 0:
            self.time_canvas.create_arc(cx - r, cy - r, cx + r, cy + r, start=90 + fc_angle, extent=prob_angle, fill="#34C759", outline="")
            
        # Inner circle (donut hole)
        self.time_canvas.create_oval(cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r, fill=bg_color, outline="")
        
        # Print ratio representation (rounded to nearest percent, e.g. "20:80") in center
        fc_pct = round(fc_ratio * 100)
        prob_pct = 100 - fc_pct
        self.time_canvas.create_text(cx, cy, text=f"{fc_pct}:{prob_pct}", fill=text_color, font=("SF Pro Display", 12, "bold"))

    def start_ai_tracker_loop(self):
        self.update_ai_tracker()

    def update_ai_tracker(self):
        try:
            percentage, completed, total, running_jobs = get_ai_task_stats()
            
            # Set progress bar
            self.ai_progress_bar.set(percentage / 100.0)
            
            # Update labels
            self.ai_percentage_label.configure(text=f"{percentage}% complete")
            self.ai_stats_label.configure(text=f"{completed} / {total} tasks processed")
            
            # Update status badge
            if running_jobs:
                self.ai_status_badge.configure(text="ACTIVE", fg_color="#FF9500")
                jobs_text = "Processing: " + ", ".join(running_jobs)
                if len(jobs_text) > 85:
                    jobs_text = jobs_text[:82] + "..."
                self.ai_jobs_label.configure(text=jobs_text)
            else:
                self.ai_status_badge.configure(text="IDLE", fg_color="#34C759")
                self.ai_jobs_label.configure(text="All local notes are fully summarized and primed.")
        except Exception as e:
            print(f"Error in dashboard AI tracker update: {e}")
            
        # Poll again in 1.5 seconds
        self.after(1500, self.update_ai_tracker)

    def load_heatmap_data(self):
        today = datetime.date.today()
        # Look back 52 weeks (364 days), and align to Monday
        start_date = today - datetime.timedelta(days=364)
        start_date = start_date - datetime.timedelta(days=start_date.weekday())
        
        choice = self.heatmap_dropdown.get()
        module_id = self.heatmap_modules_map.get(choice)
        
        conn = database.get_connection()
        c = conn.cursor()
        if module_id is None:
            c.execute("""
                SELECT date, SUM(flashcards_seconds + problems_seconds) 
                FROM module_study_time 
                WHERE date >= ? 
                GROUP BY date
            """, (start_date.isoformat(),))
        else:
            c.execute("""
                SELECT date, SUM(flashcards_seconds + problems_seconds) 
                FROM module_study_time 
                WHERE module_id = ? AND date >= ?
                GROUP BY date
            """, (module_id, start_date.isoformat()))
        rows = c.fetchall()
        conn.close()
        
        self.heatmap_data = {row[0]: row[1] for row in rows}
        self.render_heatmap()

    def render_heatmap(self):
        if not hasattr(self, "heatmap_canvas"):
            return
        self.heatmap_canvas.delete("all")
        
        bg_color = self._apply_appearance_mode(("#F2F2F7", "#2C2C2E"))
        self.heatmap_canvas.configure(bg=bg_color)
        
        w = self.heatmap_canvas.winfo_width()
        h = self.heatmap_canvas.winfo_height()
        
        if w < 50 or h < 50:
            return
            
        today = datetime.date.today()
        start_date = today - datetime.timedelta(days=364)
        start_date = start_date - datetime.timedelta(days=start_date.weekday())
        
        margin_left = 45
        margin_top = 25
        square_size = 10
        spacing = 2
        
        # Day labels (Mon, Wed, Fri)
        day_labels = {0: "Mon", 2: "Wed", 4: "Fri"}
        for row_idx, label in day_labels.items():
            y = margin_top + row_idx * (square_size + spacing) + square_size / 2
            self.heatmap_canvas.create_text(margin_left - 8, y, text=label, anchor="e", fill="gray", font=("SF Pro Display", 9))
            
        # Draw cells
        current_date = start_date
        while current_date <= today:
            delta_days = (current_date - start_date).days
            col = delta_days // 7
            row_idx = delta_days % 7
            
            date_str = current_date.isoformat()
            seconds = self.heatmap_data.get(date_str, 0)
            
            # Select color based on seconds studied
            if seconds == 0:
                color = self._apply_appearance_mode(("#E5E5EA", "#2C2C2E"))
            elif seconds <= 1800:
                color = self._apply_appearance_mode(("#B3D7FF", "#1F3E5A"))
            elif seconds <= 3600:
                color = self._apply_appearance_mode(("#66B2FF", "#2B5E8C"))
            elif seconds <= 7200:
                color = self._apply_appearance_mode(("#007AFF", "#3B82F6"))
            else:
                color = self._apply_appearance_mode(("#0056B3", "#1E40AF"))
                
            x = margin_left + col * (square_size + spacing)
            y = margin_top + row_idx * (square_size + spacing)
            
            self.heatmap_canvas.create_rectangle(x, y, x + square_size, y + square_size, fill=color, outline="")
            current_date += datetime.timedelta(days=1)
            
        # Month labels
        last_month = None
        for col in range(53):
            d = start_date + datetime.timedelta(days=col * 7)
            month_name = d.strftime("%b")
            if month_name != last_month:
                x = margin_left + col * (square_size + spacing)
                self.heatmap_canvas.create_text(x, margin_top - 8, text=month_name, anchor="w", fill="gray", font=("SF Pro Display", 9))
                last_month = month_name
                
        # Draw legend at bottom right
        legend_x = margin_left + 53 * (square_size + spacing) - 150
        legend_y = margin_top + 7 * (square_size + spacing) + 8
        
        self.heatmap_canvas.create_text(legend_x - 8, legend_y + square_size/2, text="Less", anchor="e", fill="gray", font=("SF Pro Display", 9))
        
        legend_colors = [
            self._apply_appearance_mode(("#E5E5EA", "#2C2C2E")),
            self._apply_appearance_mode(("#B3D7FF", "#1F3E5A")),
            self._apply_appearance_mode(("#66B2FF", "#2B5E8C")),
            self._apply_appearance_mode(("#007AFF", "#3B82F6")),
            self._apply_appearance_mode(("#0056B3", "#1E40AF"))
        ]
        for idx, color in enumerate(legend_colors):
            x = legend_x + idx * (square_size + spacing + 2)
            self.heatmap_canvas.create_rectangle(x, legend_y, x + square_size, legend_y + square_size, fill=color, outline="")
            
        self.heatmap_canvas.create_text(legend_x + 5 * (square_size + spacing + 2) + 8, legend_y + square_size/2, text="More", anchor="w", fill="gray", font=("SF Pro Display", 9))

    def load_module_table(self):
        if not hasattr(self, "table_container"):
            return
            
        for widget in self.table_container.winfo_children():
            widget.destroy()
            
        timeframe = self.timeframe_dropdown.get()
        start_date = get_timeframe_start_date(timeframe)
        
        # Get active year from main App class
        active_year = 1
        if hasattr(self.master, "master") and hasattr(self.master.master, "active_year"):
            active_year = self.master.master.active_year
            
        sem_filter = self.semester_dropdown.get()
        
        conn = database.get_connection()
        c = conn.cursor()
        
        query_sql = """
            SELECT m.code, m.name, COALESCE(SUM(ms.flashcards_seconds + ms.problems_seconds), 0) as total_seconds
            FROM modules m
            LEFT JOIN module_study_time ms ON m.id = ms.module_id AND ms.date >= ?
            WHERE m.year = ?
        """
        params = [start_date, active_year]
        
        if sem_filter == "Semester 1":
            query_sql += " AND m.semester = 1"
        elif sem_filter == "Semester 2":
            query_sql += " AND m.semester = 2"
            
        query_sql += """
            GROUP BY m.id
            ORDER BY total_seconds DESC, m.code ASC
        """
        
        c.execute(query_sql, params)
        rows = c.fetchall()
        conn.close()
        
        # Render Table Header
        header_row = ctk.CTkFrame(self.table_container, fg_color="transparent")
        header_row.pack(fill="x", pady=(0, 5))
        
        lbl_code = ctk.CTkLabel(header_row, text="MODULE CODE", font=("SF Pro Display", 11, "bold"), text_color="gray", width=120, anchor="w")
        lbl_code.pack(side="left", padx=10)
        
        lbl_name = ctk.CTkLabel(header_row, text="MODULE NAME", font=("SF Pro Display", 11, "bold"), text_color="gray", anchor="w")
        lbl_name.pack(side="left", fill="x", expand=True, padx=10)
        
        lbl_time = ctk.CTkLabel(header_row, text="STUDY TIME", font=("SF Pro Display", 11, "bold"), text_color="gray", width=120, anchor="e")
        lbl_time.pack(side="right", padx=10)
        
        # Separator line
        sep = ctk.CTkFrame(self.table_container, height=1, fg_color=("#E5E5EA", "#2C2C2E"))
        sep.pack(fill="x", pady=2)
        
        if not rows or all(r[2] == 0 for r in rows):
            lbl_empty = ctk.CTkLabel(self.table_container, text="No study activity logged for any modules in this timeframe.", font=("SF Pro Display", 13), text_color="gray")
            lbl_empty.pack(pady=15)
            return
            
        def format_duration(seconds):
            if seconds <= 0:
                return "0m"
            hours = int(seconds // 3600)
            minutes = int((seconds % 3600) // 60)
            if hours > 0:
                return f"{hours}h {minutes}m"
            return f"{minutes}m"
            
        # Render Module Rows
        for code, name, total_sec in rows:
            if total_sec == 0:
                continue
            row_frame = ctk.CTkFrame(self.table_container, fg_color="transparent", height=35)
            row_frame.pack(fill="x", pady=2)
            
            lbl_c = ctk.CTkLabel(row_frame, text=code, font=("SF Pro Display", 13, "bold"), width=120, anchor="w")
            lbl_c.pack(side="left", padx=10)
            
            lbl_n = ctk.CTkLabel(row_frame, text=name, font=("SF Pro Display", 13), anchor="w")
            lbl_n.pack(side="left", fill="x", expand=True, padx=10)
            
            lbl_t = ctk.CTkLabel(row_frame, text=format_duration(total_sec), font=("SF Pro Display", 13, "bold"), text_color="#007AFF", width=120, anchor="e")
            lbl_t.pack(side="right", padx=10)
            
            # Draw thin bottom border
            item_sep = ctk.CTkFrame(self.table_container, height=1, fg_color=("#E5E5EA", "#2C2C2E"))
            item_sep.pack(fill="x", pady=1)
