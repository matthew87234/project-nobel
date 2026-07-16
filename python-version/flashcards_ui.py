import customtkinter as ctk
from PIL import Image
import database
import latex_renderer
import datetime
from ratio_tracker import RatioTrackerBar
import ai_helper


def create_latex_image(pil_img, max_width=None):
    scale = 3.0 # Scale factor to make previews crisp and smaller
    display_width = pil_img.width / scale
    display_height = pil_img.height / scale
    
    if max_width and display_width > max_width:
        reduction_factor = max_width / display_width
        display_width = max_width
        display_height = display_height * reduction_factor
        
    return ctk.CTkImage(light_image=pil_img, dark_image=pil_img, size=(display_width, display_height))

def clear_image(label):
    label.configure(image=None)
    if hasattr(label, "_label") and label._label:
        try:
            label._label.configure(image="")
        except:
            pass

class FlashcardAddView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(2, weight=1)
        self.grid_columnconfigure(1, weight=1)
        
        self._debounce_timer_front = None
        self._debounce_timer_back = None
        self._last_active_side = "Front"

        self.header = ctk.CTkLabel(self, text="Add New Flashcard", font=("SF Pro Display", 28, "bold"))
        self.header.grid(row=0, column=0, columnspan=2, padx=30, pady=30, sticky="nw")
        
        self.current_mod_id = None

        ctk.CTkLabel(self, text="Front:", font=("SF Pro Display", 14, "bold")).grid(row=1, column=0, padx=30, pady=10, sticky="nw")
        self.front_textbox = ctk.CTkTextbox(self, height=100, border_width=1, fg_color="transparent")
        self.front_textbox.grid(row=1, column=1, padx=10, pady=10, sticky="ew")
        self.front_textbox.bind("<KeyRelease>", self.on_typing_front)

        ctk.CTkLabel(self, text="Back:", font=("SF Pro Display", 14, "bold")).grid(row=2, column=0, padx=30, pady=10, sticky="nw")
        self.back_textbox = ctk.CTkTextbox(self, height=100, border_width=1, fg_color="transparent")
        self.back_textbox.grid(row=2, column=1, padx=10, pady=10, sticky="ew")
        self.back_textbox.bind("<KeyRelease>", self.on_typing_back)

        self.preview_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.preview_frame.grid(row=3, column=1, padx=10, pady=10, sticky="w")
        
        self.preview_front_btn = ctk.CTkButton(self.preview_frame, text="Preview Front", width=120, command=self.preview_front)
        self.preview_front_btn.pack(side="left", padx=(0, 10))
        
        self.preview_back_btn = ctk.CTkButton(self.preview_frame, text="Preview Back", width=120, command=self.preview_back)
        self.preview_back_btn.pack(side="left")

        # AI LaTeX Helper Button
        self.ai_latex_btn = ctk.CTkButton(
            self.preview_frame, 
            text="AI LaTeX Helper", 
            width=140, 
            fg_color="#34C759", 
            hover_color="#248A3D",
            text_color="white",
            command=self.open_ai_latex_translator
        )
        self.ai_latex_btn.pack(side="left", padx=(20, 0))

        self.preview_image_label = ctk.CTkLabel(self, text="Preview will appear here", wraplength=780)
        self.preview_image_label.grid(row=4, column=1, padx=10, pady=10, sticky="w")

        self.save_btn = ctk.CTkButton(self, text="Save Card", fg_color="#E5E5EA", hover_color="#2C2C2E", text_color=("black", "white"), command=self.save_card)
        self.save_btn.grid(row=5, column=1, padx=10, pady=20, sticky="e")

        self.bind("<Configure>", self.on_configure)

    def preview_front(self):
        self._last_active_side = "Front"
        text = self.front_textbox.get("0.0", "end").strip()
        self.render_preview(text, "Front")
        
    def preview_back(self):
        self._last_active_side = "Back"
        text = self.back_textbox.get("0.0", "end").strip()
        self.render_preview(text, "Back")

    def render_preview(self, text, side):
        if not text:
            clear_image(self.preview_image_label)
            self.preview_image_label.configure(text=f"Cannot preview: {side} is empty.")
            return
            
        if not latex_renderer.is_latex(text):
            clear_image(self.preview_image_label)
            self.preview_image_label.configure(text=text, font=("SF Pro Display", 14))
            return
        
        if not latex_renderer.is_ready():
            clear_image(self.preview_image_label)
            self.preview_image_label.configure(text="Loading LaTeX engine...")
            import threading
            threading.Thread(target=self.render_live_preview_async, args=(text, side), daemon=True).start()
            return
            
        try:
            tb_width = self.front_textbox.winfo_width()
            max_w = tb_width - 20 if tb_width > 50 else 750
            wrap_width = max(40, min(120, int(tb_width / 10.5))) if tb_width > 50 else 72
            pil_img = latex_renderer.render_latex_to_image(text, fontsize=14, wrap_width=wrap_width)
            ctk_img = create_latex_image(pil_img, max_width=max_w)
            self.preview_image_label.configure(image=ctk_img, text="")
            self.preview_image_label.image = ctk_img
        except Exception as e:
            clear_image(self.preview_image_label)
            self.preview_image_label.configure(text=f"LaTeX Error ({side}): {e}")

    def on_typing_front(self, event=None):
        if hasattr(self, "_debounce_timer_front") and self._debounce_timer_front:
            self.after_cancel(self._debounce_timer_front)
        self._debounce_timer_front = self.after(300, self.trigger_live_preview_front)
        
    def trigger_live_preview_front(self):
        self._last_active_side = "Front"
        text = self.front_textbox.get("0.0", "end").strip()
        import threading
        threading.Thread(target=self.render_live_preview_async, args=(text, "Front"), daemon=True).start()
        
    def on_typing_back(self, event=None):
        if hasattr(self, "_debounce_timer_back") and self._debounce_timer_back:
            self.after_cancel(self._debounce_timer_back)
        self._debounce_timer_back = self.after(300, self.trigger_live_preview_back)
        
    def trigger_live_preview_back(self):
        self._last_active_side = "Back"
        text = self.back_textbox.get("0.0", "end").strip()
        import threading
        threading.Thread(target=self.render_live_preview_async, args=(text, "Back"), daemon=True).start()
        
    def render_live_preview_async(self, text, side):
        if side != self._last_active_side:
            return
            
        if not text:
            def clear_empty():
                clear_image(self.preview_image_label)
                self.preview_image_label.configure(text=f"Preview will appear here ({side} is empty)")
            self.after(0, clear_empty)
            return
            
        if not latex_renderer.is_latex(text):
            def show_plain():
                clear_image(self.preview_image_label)
                self.preview_image_label.configure(text=text, font=("SF Pro Display", 14))
            self.after(0, show_plain)
            return
            
        if not latex_renderer.is_ready():
            def show_loading():
                clear_image(self.preview_image_label)
                self.preview_image_label.configure(text="Loading LaTeX engine...")
            self.after(0, show_loading)
            
        try:
            tb_width = self.front_textbox.winfo_width()
            max_w = tb_width - 20 if tb_width > 50 else 750
            wrap_width = max(40, min(120, int(tb_width / 10.5))) if tb_width > 50 else 72
            pil_img = latex_renderer.render_latex_to_image(text, fontsize=14, wrap_width=wrap_width)
            ctk_img = create_latex_image(pil_img, max_width=max_w)
            
            def update_ui(img=ctk_img, s=side):
                if s == self._last_active_side:
                    self.preview_image_label.configure(image=img, text="")
                    self.preview_image_label.image = img
            self.after(0, update_ui)
            
        except Exception as e:
            def show_error(err=str(e), s=side):
                if s == self._last_active_side:
                    clear_image(self.preview_image_label)
                    self.preview_image_label.configure(text=f"LaTeX Error: {err}")
            self.after(0, show_error)

    def on_configure(self, event):
        tb_width = self.front_textbox.winfo_width()
        if tb_width > 50:
            self.preview_image_label.configure(wraplength=tb_width - 20)

    def save_card(self):
        mod_id = self.current_mod_id
        front = self.front_textbox.get("0.0", "end").strip()
        back = self.back_textbox.get("0.0", "end").strip()

        if not front or not back or not mod_id:
            return

        conn = database.get_connection()
        c = conn.cursor()
        today = datetime.date.today().isoformat()
        c.execute("INSERT INTO flashcards (module_id, front, back, next_review_date, created_date) VALUES (?, ?, ?, ?, ?)",
                  (mod_id, front, back, today, today))
        conn.commit()
        conn.close()

        self.front_textbox.delete("0.0", "end")
        self.back_textbox.delete("0.0", "end")
        clear_image(self.preview_image_label)
        self.preview_image_label.configure(text="Saved!")

    def update_active_module(self, module_id):
        self.current_mod_id = module_id

    def open_ai_latex_translator(self):
        if hasattr(self, "translator_window") and self.translator_window and self.translator_window.winfo_exists():
            self.translator_window.lift()
            self.translator_window.focus_set()
        else:
            self.translator_window = AILatexTranslatorWindow(self)


class FlashcardReviewView(ctk.CTkFrame):
    def __init__(self, master, **kwargs):
        super().__init__(master, **kwargs)
        
        self.grid_rowconfigure(2, weight=1)
        self.grid_columnconfigure(0, weight=1)
        
        self.header = ctk.CTkLabel(self, text="Flashcard Review", font=("SF Pro Display", 28, "bold"))
        self.header.grid(row=0, column=0, padx=30, pady=(30, 10), sticky="nw")

        # 80/20 Study Ratio Tracker Bar
        self.ratio_bar = RatioTrackerBar(self)
        self.ratio_bar.grid(row=1, column=0, padx=30, pady=(0, 20), sticky="ew")

        # Container for pre-review view (status and start button)
        self.pre_review_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.pre_review_frame.grid(row=2, column=0, sticky="nsew", padx=30, pady=10)
        self.pre_review_frame.grid_columnconfigure(0, weight=1)
        self.pre_review_frame.grid_rowconfigure(0, weight=1)
        self.pre_review_frame.grid_rowconfigure(1, weight=1)

        self.review_status_label = ctk.CTkLabel(self.pre_review_frame, text="Click Start to review cards due today.", font=("SF Pro Display", 16))
        self.review_status_label.grid(row=0, column=0, pady=(50, 5))

        self.start_btn = ctk.CTkButton(self.pre_review_frame, text="Start Review", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=self.load_due_cards)
        self.start_btn.grid(row=1, column=0, pady=10, sticky="n")

        
        self.card_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.card_label = ctk.CTkLabel(self.card_frame, text="", font=("SF Pro Display", 24), wraplength=780)
        
        self.bind("<Configure>", self.on_configure)
        
        self.controls_frame = ctk.CTkFrame(self.card_frame, fg_color="transparent")
        self.show_answer_btn = ctk.CTkButton(self.controls_frame, text="Show Answer", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=self.show_answer)
        self.rate_easy_btn = ctk.CTkButton(self.controls_frame, text="Easy", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=lambda: self.rate_card("easy"))
        self.rate_good_btn = ctk.CTkButton(self.controls_frame, text="Good", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=lambda: self.rate_card("good"))
        self.rate_hard_btn = ctk.CTkButton(self.controls_frame, text="Hard", fg_color="#E5E5EA", text_color=("black", "white"), hover_color="#2C2C2E", command=lambda: self.rate_card("hard"))

        self.due_cards = []
        self.current_card = None
        self.current_mod_id = None

        # Bind keyboard shortcuts for card review
        self.bind_all("<space>", self.handle_space)
        self.bind_all("<Key-1>", lambda e: self.handle_rate_key(e, "hard"))
        self.bind_all("<Key-2>", lambda e: self.handle_rate_key(e, "good"))
        self.bind_all("<Key-3>", lambda e: self.handle_rate_key(e, "easy"))

    def load_due_cards(self):
        mode = "General"
        if hasattr(self.master, "master") and hasattr(self.master.master, "study_mode"):
            mode = self.master.master.study_mode

        if mode == "Exam" and (not hasattr(self, "current_mod_id") or not self.current_mod_id):
            self.review_status_label.configure(text="No active module selected.")
            return

        today = datetime.date.today().isoformat()
        conn = database.get_connection()
        c = conn.cursor()
        
        if mode == "Exam":
            c.execute("""
                SELECT id, front, back, interval, ease_factor, repetitions 
                FROM flashcards 
                WHERE module_id = ? AND next_review_date <= ?
            """, (self.current_mod_id, today))
        else:
            # General Mode: Mix all modules
            c.execute("""
                SELECT id, front, back, interval, ease_factor, repetitions 
                FROM flashcards 
                WHERE next_review_date <= ?
            """, (today,))
            
        self.due_cards = c.fetchall()
        conn.close()

        if not self.due_cards:
            self.review_status_label.configure(text="No cards due today! Great job.")
            return

        self.pre_review_frame.grid_remove()
        self.review_status_label.configure(text=f"{len(self.due_cards)} cards due.")
        self.card_frame.grid(row=2, column=0, sticky="nsew", padx=40, pady=20)
        self.card_label.grid(row=0, column=0, pady=40, padx=20)
        self.card_frame.grid_columnconfigure(0, weight=1)
        
        self.show_next_card()

    def show_next_card(self):
        if not self.due_cards:
            self.card_frame.grid_remove()
            self.pre_review_frame.grid(row=2, column=0, sticky="nsew", padx=30, pady=10)
            self.review_status_label.configure(text="Review complete for today!")
            return

        self.current_card = self.due_cards.pop(0)
        card_id, front, back, interval, ease, reps = self.current_card
        
        self.controls_frame.grid(row=1, column=0, pady=20)
        self.show_answer_btn.grid(row=0, column=0, padx=10)
        self.rate_easy_btn.grid_remove()
        self.rate_good_btn.grid_remove()
        self.rate_hard_btn.grid_remove()

        if latex_renderer.is_latex(front):
            w = self.winfo_width()
            max_w = w - 120 if w > 100 else 780
            wrap_width = max(40, min(120, int(max_w / 10.5))) if w > 100 else 72
            if not latex_renderer.is_ready():
                clear_image(self.card_label)
                self.card_label.configure(text="Loading LaTeX engine...")
                def load_async(ww=wrap_width, mw=max_w):
                    try:
                        pil_img = latex_renderer.render_latex_to_image(front, wrap_width=ww)
                        ctk_img = create_latex_image(pil_img, max_width=mw)
                        self.after(0, lambda: self.card_label.configure(image=ctk_img, text="") or setattr(self.card_label, "image", ctk_img))
                    except:
                        def show_fallback():
                            clear_image(self.card_label)
                            self.card_label.configure(text=front)
                        self.after(0, show_fallback)
                import threading
                threading.Thread(target=load_async, daemon=True).start()
            else:
                try:
                    pil_img = latex_renderer.render_latex_to_image(front, wrap_width=wrap_width)
                    ctk_img = create_latex_image(pil_img, max_width=max_w)
                    self.card_label.configure(image=ctk_img, text="")
                    self.card_label.image = ctk_img
                except:
                    clear_image(self.card_label)
                    self.card_label.configure(text=front)
        else:
            clear_image(self.card_label)
            self.card_label.configure(text=front)

    def show_answer(self):
        if not self.current_card: return
        card_id, front, back, interval, ease, reps = self.current_card
        
        if latex_renderer.is_latex(back):
            w = self.winfo_width()
            max_w = w - 120 if w > 100 else 780
            wrap_width = max(40, min(120, int(max_w / 10.5))) if w > 100 else 72
            if not latex_renderer.is_ready():
                clear_image(self.card_label)
                self.card_label.configure(text="Loading LaTeX engine...")
                def load_async(ww=wrap_width, mw=max_w):
                    try:
                        pil_img = latex_renderer.render_latex_to_image(back, wrap_width=ww)
                        ctk_img = create_latex_image(pil_img, max_width=mw)
                        self.after(0, lambda: self.card_label.configure(image=ctk_img, text="") or setattr(self.card_label, "image", ctk_img))
                    except:
                        def show_fallback():
                            clear_image(self.card_label)
                            self.card_label.configure(text=back)
                        self.after(0, show_fallback)
                import threading
                threading.Thread(target=load_async, daemon=True).start()
            else:
                try:
                    pil_img = latex_renderer.render_latex_to_image(back, wrap_width=wrap_width)
                    ctk_img = create_latex_image(pil_img, max_width=max_w)
                    self.card_label.configure(image=ctk_img, text="")
                    self.card_label.image = ctk_img
                except:
                    clear_image(self.card_label)
                    self.card_label.configure(text=back)
        else:
            clear_image(self.card_label)
            self.card_label.configure(text=back)
            
        self.show_answer_btn.grid_remove()
        self.rate_easy_btn.grid(row=0, column=0, padx=5)
        self.rate_good_btn.grid(row=0, column=1, padx=5)
        self.rate_hard_btn.grid(row=0, column=2, padx=5)

    def rate_card(self, rating):
        card_id = self.current_card[0]
        next_date = (datetime.date.today() + datetime.timedelta(days=1)).isoformat()
        
        conn = database.get_connection()
        c = conn.cursor()
        c.execute("UPDATE flashcards SET next_review_date = ? WHERE id = ?", (next_date, card_id))
        conn.commit()
        conn.close()

        database.log_activity('flashcard')
        self.show_next_card()

    def update_active_module(self, module_id):
        self.current_mod_id = module_id
        # Reset review UI state
        self.due_cards = []
        self.current_card = None
        self.card_frame.grid_remove()
        self.pre_review_frame.grid(row=2, column=0, sticky="nsew", padx=30, pady=10)
        self.review_status_label.configure(text="Click Start to review cards due today.")

    def on_configure(self, event):
        w = self.winfo_width()
        if w > 100:
            self.card_label.configure(wraplength=w - 120)

    def handle_space(self, event):
        if not self.winfo_ismapped():
            return
        if self._is_typing():
            return
        if self.show_answer_btn.winfo_ismapped():
            self.show_answer()
            
    def handle_rate_key(self, event, rating):
        if not self.winfo_ismapped():
            return
        if self._is_typing():
            return
        if self.rate_hard_btn.winfo_ismapped():
            self.rate_card(rating)

    def _is_typing(self):
        focus = self.focus_get()
        if not focus:
            return False
        class_name = focus.__class__.__name__
        if "entry" in class_name.lower() or "text" in class_name.lower():
            return True
        return False


class AILatexTranslatorWindow(ctk.CTkToplevel):
    def __init__(self, parent):
        super().__init__(parent)
        self.parent = parent
        self.title("AI LaTeX Translator")
        self.geometry("600x580")
        self.resizable(False, False)
        
        # Make modal
        self.transient(parent)
        self.grab_set()
        
        self.grid_columnconfigure(0, weight=1)
        
        self.pasted_image = None
        self.pasted_image_base64 = None
        
        # 1. Header
        self.header = ctk.CTkLabel(self, text="AI LaTeX Translator", font=("SF Pro Display", 18, "bold"))
        self.header.grid(row=0, column=0, padx=20, pady=(20, 5), sticky="w")
        
        self.desc = ctk.CTkLabel(
            self, 
            text="Take a screenshot of an equation to your clipboard (Cmd+Ctrl+Shift+4 on Mac) and paste it, or describe it in plain English.", 
            font=("SF Pro Display", 12), 
            text_color="gray", 
            justify="left",
            wraplength=560
        )
        self.desc.grid(row=1, column=0, padx=20, pady=(0, 15), sticky="w")
        
        # 2. Image Paste Section
        self.image_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.image_frame.grid(row=2, column=0, padx=20, pady=(0, 5), sticky="ew")
        
        self.paste_btn = ctk.CTkButton(
            self.image_frame, 
            text="📋 Paste Image from Clipboard", 
            command=self.paste_image,
            fg_color="#007AFF",
            hover_color="#0056B3",
            text_color="white"
        )
        self.paste_btn.pack(side="left", padx=(0, 15))
        
        self.clear_img_btn = ctk.CTkButton(
            self.image_frame,
            text="Clear Image",
            width=90,
            fg_color="transparent",
            hover_color=("#E5E5EA", "#2C2C2E"),
            text_color="gray",
            command=self.clear_image_data
        )
        # Hidden initially
        
        self.image_preview_label = ctk.CTkLabel(
            self, 
            text="No image pasted yet.", 
            font=("SF Pro Display", 11, "italic"),
            text_color="gray"
        )
        self.image_preview_label.grid(row=3, column=0, padx=20, pady=(0, 15), sticky="w")
        
        # 3. Input Textbox (Or describe it in text)
        self.input_label = ctk.CTkLabel(self, text="Or describe it in text:", font=("SF Pro Display", 12, "bold"))
        self.input_label.grid(row=4, column=0, padx=20, pady=(0, 5), sticky="w")
        
        self.input_textbox = ctk.CTkTextbox(self, height=50, border_width=1, fg_color="transparent")
        self.input_textbox.grid(row=5, column=0, padx=20, pady=(0, 10), sticky="ew")
        
        # 4. Translate Action & Status
        self.btn_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.btn_frame.grid(row=6, column=0, padx=20, pady=5, sticky="ew")
        
        self.translate_btn = ctk.CTkButton(
            self.btn_frame, 
            text="Translate with AI", 
            command=self.start_translation, 
            fg_color="#34C759", 
            hover_color="#248A3D", 
            text_color="white"
        )
        self.translate_btn.pack(side="left", padx=(0, 15))
        
        self.status_label = ctk.CTkLabel(self.btn_frame, text="", font=("SF Pro Display", 12))
        self.status_label.pack(side="left")
        
        # 5. Result Textbox
        self.output_label = ctk.CTkLabel(self, text="Generated LaTeX code:", font=("SF Pro Display", 12, "bold"))
        self.output_label.grid(row=7, column=0, padx=20, pady=(15, 5), sticky="w")
        
        self.output_textbox = ctk.CTkTextbox(self, height=60, border_width=1, fg_color="transparent")
        self.output_textbox.grid(row=8, column=0, padx=20, pady=(0, 15), sticky="ew")
        
        # 6. Insert / Copy Actions
        self.actions_frame = ctk.CTkFrame(self, fg_color="transparent")
        self.actions_frame.grid(row=9, column=0, padx=20, pady=(0, 20), sticky="ew")
        
        self.copy_btn = ctk.CTkButton(self.actions_frame, text="Copy Code", width=100, command=self.copy_code, state="disabled")
        self.copy_btn.pack(side="left", padx=(0, 10))
        
        self.insert_front_btn = ctk.CTkButton(self.actions_frame, text="Insert to Front", width=120, command=self.insert_front, state="disabled")
        self.insert_front_btn.pack(side="left", padx=(0, 10))
        
        self.insert_back_btn = ctk.CTkButton(self.actions_frame, text="Insert to Back", width=120, command=self.insert_back, state="disabled")
        self.insert_back_btn.pack(side="left", padx=(0, 10))
        
        self.close_btn = ctk.CTkButton(self.actions_frame, text="Close", width=80, fg_color="#FF453A", hover_color="#D12C20", text_color="white", command=self.destroy)
        self.close_btn.pack(side="right")
        
    def paste_image(self):
        from PIL import Image, ImageGrab
        try:
            img = ImageGrab.grabclipboard()
            if img is not None:
                # Check if it is a PIL image
                if hasattr(img, "size"):
                    # Remove transparency if present, using solid white background
                    if img.mode in ('RGBA', 'LA') or (img.mode == 'P' and 'transparency' in img.info):
                        bg = Image.new('RGB', img.size, (255, 255, 255))
                        img_rgba = img.convert('RGBA')
                        bg.paste(img_rgba, mask=img_rgba.split()[3])
                        img_to_use = bg
                    else:
                        img_to_use = img.convert('RGB')
                        
                    self.pasted_image = img_to_use
                    
                    # Show preview
                    # Resize for display
                    max_w, max_h = 560, 100
                    w, h = img_to_use.size
                    scale = min(max_w / w, max_h / h, 1.0)
                    disp_w, disp_h = int(w * scale), int(h * scale)
                    
                    self.ctk_img = ctk.CTkImage(light_image=img_to_use, dark_image=img_to_use, size=(disp_w, disp_h))
                    self.image_preview_label.configure(image=self.ctk_img, text="")
                    self.clear_img_btn.pack(side="left")
                    self.status_label.configure(text="📋 Image pasted from clipboard!")
                    
                    # Convert to base64 for Ollama
                    import base64
                    import io
                    buffered = io.BytesIO()
                    img_to_use.save(buffered, format="JPEG") # Save as JPEG to enforce RGB/no alpha
                    img_bytes = buffered.getvalue()
                    self.pasted_image_base64 = base64.b64encode(img_bytes).decode('utf-8')
                else:
                    self.status_label.configure(text="⚠️ Clipboard item is not an image.")
            else:
                self.status_label.configure(text="⚠️ Clipboard is empty or contains no image.")
        except Exception as e:
            self.status_label.configure(text=f"⚠️ Error pasting image: {e}")
            
    def clear_image_data(self):
        self.pasted_image = None
        self.pasted_image_base64 = None
        self.image_preview_label.configure(image=None, text="No image pasted yet.")
        self.clear_img_btn.pack_forget()
        self.status_label.configure(text="Cleared image.")
        
    def start_translation(self):
        text = self.input_textbox.get("0.0", "end").strip()
        
        if not self.pasted_image_base64 and not text:
            self.status_label.configure(text="⚠️ Please paste an image or type a description first.")
            return
            
        self.status_label.configure(text="⏳ Translating with local AI...")
        self.translate_btn.configure(state="disabled")
        
        import threading
        if self.pasted_image_base64:
            # Check vision model first
            import ai_helper
            vision_model = ai_helper.get_ollama_vision_model()
            if not vision_model:
                # Need to download fallback vision model
                self.status_label.configure(text="⏳ Downloading vision model 'qwen2.5vl' (~4.7GB)...")
                threading.Thread(target=self.run_download_and_translate_async, daemon=True).start()
            else:
                threading.Thread(target=self.run_image_translation_async, daemon=True).start()
        else:
            threading.Thread(target=self.run_text_translation_async, args=(text,), daemon=True).start()
            
    def run_download_and_translate_async(self):
        import ai_helper
        success = ai_helper.pull_ollama_model("qwen2.5vl")
        if success:
            self.after(10, lambda: self.status_label.configure(text="⏳ Translating image..."))
            self.run_image_translation_async()
        else:
            self.after(10, lambda: self.finish_translation(None))
            
    def run_image_translation_async(self):
        import ai_helper
        latex_code = ai_helper.translate_image_to_latex(self.pasted_image_base64)
        self.after(10, lambda: self.finish_translation(latex_code))
        
    def run_text_translation_async(self, text):
        import ai_helper
        latex_code = ai_helper.translate_to_latex(text)
        self.after(10, lambda: self.finish_translation(latex_code))
        
    def finish_translation(self, result):
        self.translate_btn.configure(state="normal")
        if result == "MODEL_NOT_FOUND":
            self.status_label.configure(text="❌ Error: Vision model not found.")
        elif result:
            self.status_label.configure(text="✅ Translation complete!")
            self.output_textbox.delete("0.0", "end")
            self.output_textbox.insert("0.0", result)
            
            # Enable actions
            self.copy_btn.configure(state="normal")
            self.insert_front_btn.configure(state="normal")
            self.insert_back_btn.configure(state="normal")
        else:
            self.status_label.configure(text="❌ Translation failed. Check Ollama running.")
            
    def copy_code(self):
        code = self.output_textbox.get("0.0", "end").strip()
        if code:
            self.clipboard_clear()
            self.clipboard_append(code)
            self.status_label.configure(text="📋 Copied to clipboard!")
            
    def insert_front(self):
        code = self.output_textbox.get("0.0", "end").strip()
        if code:
            self.parent.front_textbox.insert("insert", code)
            self.status_label.configure(text="📥 Inserted into Front!")
            
    def insert_back(self):
        code = self.output_textbox.get("0.0", "end").strip()
        if code:
            self.parent.back_textbox.insert("insert", code)
            self.status_label.configure(text="📥 Inserted into Back!")

