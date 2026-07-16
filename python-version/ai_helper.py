import urllib.request
import json
import os
import fitz  # PyMuPDF
import database
import threading

active_user_requests_count = 0
active_user_requests_lock = threading.Lock()

def start_user_request():
    global active_user_requests_count
    with active_user_requests_lock:
        active_user_requests_count += 1

def end_user_request():
    global active_user_requests_count
    with active_user_requests_lock:
        active_user_requests_count = max(0, active_user_requests_count - 1)


def get_ollama_model():
    """Checks local models running in Ollama. Defaults to qwen2.5-coder:7b."""
    model_name = "qwen2.5-coder:7b"
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=2) as response:
            data = json.loads(response.read().decode('utf-8'))
            models = data.get('models', [])
            
            # 1. Try to find qwen2.5-coder:7b or general qwen2.5-coder
            for m in models:
                name = m['name']
                if "qwen2.5-coder:7b" in name.lower():
                    return name
            for m in models:
                name = m['name']
                if "qwen2.5-coder" in name.lower():
                    return name
            
            # 2. Try to find qwen2.5:7b or standard text qwen2.5 (excluding vision)
            for m in models:
                name = m['name']
                if ("qwen2.5:7b" in name.lower() or "qwen2.5" in name.lower()) and "vl" not in name.lower():
                    return name
            
            # 3. Fallback to qwen2.5vl:7b
            for m in models:
                name = m['name']
                if "qwen2.5vl:7b" in name.lower() or "qwen2.5-vl:7b" in name.lower():
                    return name
            for m in models:
                name = m['name']
                if "qwen2.5vl" in name.lower() or "qwen2.5-vl" in name.lower():
                    return name
                    
            if models:
                # Fallback to first available model
                model_name = models[0]['name']
    except Exception as e:
        print(f"[AI Helper] Warning: Could not connect to Ollama to list models ({e}). Defaulting to qwen2.5-coder:7b.")
    return model_name

def extract_text_from_pdf(pdf_path, max_pages=15):
    """Extracts text from the first few pages of a PDF."""
    try:
        if not os.path.exists(pdf_path):
            print(f"[AI Helper] PDF path does not exist: {pdf_path}")
            return ""
        doc = fitz.open(pdf_path)
        pdf_text = ""
        num_pages = min(len(doc), max_pages)
        for i in range(num_pages):
            page_text = doc[i].get_text()
            if page_text:
                pdf_text += page_text + "\n"
        doc.close()
        return pdf_text.strip()
    except Exception as e:
        print(f"[AI Helper] Error extracting text from PDF ({pdf_path}): {e}")
        return ""

failed_note_times = {}

def is_note_failed(note_id):
    import time
    if note_id in failed_note_times:
        return time.time() - failed_note_times[note_id] < 300
    return False

def has_repetitive_glitch(text):
    if not text:
        return False
    import re
    # Match 5 or more identical characters in a row, excluding spaces, dashes, asterisks, equals, dots, underscores, and newlines
    pattern = r"([^ \-\*=\._\n\r])\1{4,}"
    return re.search(pattern, text) is not None

def call_ollama(prompt, model_name):
    """Calls Ollama generate API synchronously with retries on repetitive glitch."""
    body = {
        "model": model_name,
        "prompt": prompt,
        "stream": False
    }
    max_retries = 2
    for attempt in range(1, max_retries + 1):
        try:
            req = urllib.request.Request(
                "http://localhost:11434/api/generate",
                data=json.dumps(body).encode('utf-8'),
                headers={'Content-Type': 'application/json'}
            )
            with urllib.request.urlopen(req, timeout=180) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                res_text = res_data.get('response', '').strip()
                if has_repetitive_glitch(res_text):
                    print(f"[AI Helper] Repetitive glitch detected in Ollama response (attempt {attempt}/{max_retries}): '{res_text}'")
                    continue
                return res_text
        except Exception as e:
            print(f"[AI Helper] Error communicating with local Ollama: {e}")
            return None
    return None

def generate_summary(pdf_text, model_name):
    """Generates the structured AI summary for the physics notes."""
    prompt = (
        f"You are a helpful physics academic assistant. Summarize the following physics lecture notes. "
        f"Start directly with the overview paragraph. Do NOT include any introductory or concluding conversational filler (e.g., 'Here is the summary:', 'Sure!', or 'Let me know if you need more help'). "
        f"Your output MUST follow this exact structure:\n\n"
        f"[Overview Paragraph]\n"
        f"A single short paragraph (2-3 sentences) summarizing the core topic of the lecture, the fundamental physical concepts introduced, and how it connects to the broader subject.\n\n"
        f"[Key Concepts & Equations]\n"
        f"A list of 3-5 bullet points using the dash '-' symbol, listing key concepts and equations using the format '- [Concept Name]: [Formula/Details]'.\n\n"
        f"Here is an example of the exact format required:\n"
        f"This lecture introduces the principles of electrostatics, focusing on Coulomb's law and the concept of electric field strength. It explains how charge distributions produce force fields in space and defines the mathematical foundation for calculating electric field vectors. This forms the basis for understanding more advanced electromagnetic phenomena.\n\n"
        f"- Coulomb's Law: F = k * (q1 * q2) / r^2\n"
        f"- Electric Field Strength: E = F / q\n"
        f"- Superposition Principle for multiple charges\n"
        f"- Electric Field Lines and their properties\n\n"
        f"Now, summarize the following lecture notes using the exact format shown above:\n\n"
        f"Lecture notes:\n{pdf_text}"
    )
    
    summary_res = call_ollama(prompt, model_name)
    if summary_res:
        # Clean up conversational preambles
        lines = summary_res.split('\n')
        if lines:
            first_line = lines[0].strip().lower()
            if first_line.endswith(':') and any(first_line.startswith(x) for x in ["here is", "here's", "sure", "based on", "the following", "this is", "the summary"]):
                summary_res = '\n'.join(lines[1:]).strip()
        return summary_res
    return None


def process_note_sync(note_id):
    """Synchronously extracts text, calls Ollama to generate AI summary and difficulty rating, and updates the database."""
    print(f"[AI Helper] Beginning background analysis for Note ID: {note_id}")
    
    conn = database.get_connection()
    c = conn.cursor()
    
    # 1. Fetch note details
    c.execute("""
        SELECT n.file_path, n.title
        FROM notes n
        WHERE n.id = ?
    """, (note_id,))
    row = c.fetchone()
    conn.close()
    
    if not row:
        print(f"[AI Helper] Note ID {note_id} not found in database.")
        return
        
    file_path, title = row
    
    # 2. Extract PDF text
    pdf_text = extract_text_from_pdf(file_path)
    if not pdf_text:
        # Fallback if text extraction yields nothing (e.g. scanned PDF)
        pdf_text = f"Physics lecture note titled: {title}"
    else:
        # Truncate text to avoid context length issues (limit to first ~4000 characters)
        pdf_text = pdf_text[:4000]
        
    # Get model name
    model_name = get_ollama_model()
    
    # 5. Generate AI Summary
    summary = generate_summary(pdf_text, model_name)
    
    # 6. Update database
    conn = database.get_connection()
    c = conn.cursor()
    if summary:
        c.execute("UPDATE notes SET ai_summary = ? WHERE id = ?", (summary, note_id))
        print(f"[AI Helper] Successfully updated summary for Note ID {note_id}")
    else:
        print(f"[AI Helper] Failed to generate summary for Note ID {note_id}")
        import time
        failed_note_times[note_id] = time.time()
    conn.commit()
    conn.close()
    
    print(f"[AI Helper] Completed analysis for Note ID: {note_id}")

def clean_latex_output(text):
    """Clean up markdown code blocks and LaTeX delimiters from the model response."""
    if not text:
        return text
    text = text.strip()
    
    # 1. Clean up markdown code blocks (e.g. ```latex ... ```)
    if text.startswith("```"):
        lines = text.split("\n")
        if len(lines) >= 3 and lines[0].startswith("```") and lines[-1].startswith("```"):
            text = "\n".join(lines[1:-1]).strip()
            
    # 2. Clean up common delimiters: $$, $, \[, \], \(, \)
    if text.startswith("$$") and text.endswith("$$"):
        text = text[2:-2].strip()
    elif text.startswith("$") and text.endswith("$"):
        text = text[1:-1].strip()
    elif text.startswith("\\[") and text.endswith("\\]"):
        text = text[2:-2].strip()
    elif text.startswith("\\(") and text.endswith("\\)"):
        text = text[2:-2].strip()
        
    return text

def translate_to_latex(raw_equation):
    """Calls local Ollama model to translate a plain-text equation description into valid LaTeX code (no delimiters)."""
    start_user_request()
    try:
        model_name = get_ollama_model()
        prompt = (
            f"You are a mathematical LaTeX translator. Translate the following plain-text equation description or expression into clean, valid raw LaTeX code.\n"
            f"Do NOT include any delimiters (do NOT wrap in $ or $$ or \\[ or \\]). Do NOT include any conversational filler, explanation, or notes. Return only the raw LaTeX code itself.\n\n"
            f"Example input: integral from a to b of x squared dx\n"
            f"Example output: \\int_{a}^{b} x^2 \\, dx\n\n"
            f"Example input: schrodinger equation\n"
            f"Example output: i\\hbar\\frac{{\\partial}}{{\\partial t}}\\text{{\\Psi}}(\\mathbf{{r}},t) = \\hat{{H}}\\text{{\\Psi}}(\\mathbf{{r}},t)\n\n"
            f"Now, translate this equation:\n"
            f"{raw_equation}"
        )
        result = call_ollama(prompt, model_name)
        if result:
            return clean_latex_output(result)
        return None
    finally:
        end_user_request()

def get_ollama_vision_model():
    """Finds an installed vision/multimodal model in Ollama. Returns name or None."""
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=2) as response:
            data = json.loads(response.read().decode('utf-8'))
            models = data.get('models', [])
            
            # 1. Prioritize explicit Qwen VL (Vision Language) models
            for m in models:
                name = m['name'].lower()
                if "qwen" in name and ("vl" in name or "vision" in name):
                    return m['name']
                    
            # 2. Fallback to other VL models
            for m in models:
                name = m['name'].lower()
                if any(x in name for x in ["vl", "vision", "llava", "minicpm", "moondream"]):
                    return m['name']
                    
            # 3. Last fallback (excluding known coder/text models)
            for kw in ["qwen", "llava", "minicpm", "moondream"]:
                for m in models:
                    name = m['name'].lower()
                    if kw in name and "coder" not in name and "text" not in name:
                        return m['name']
    except Exception as e:
        print(f"[AI Helper] Warning: Error checking for vision model: {e}")
    return None

def pull_ollama_model(model_name):
    """Triggers an Ollama API call to pull a model in the background."""
    body = {"model": model_name, "stream": False}
    try:
        req = urllib.request.Request(
            "http://localhost:11434/api/pull",
            data=json.dumps(body).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        with urllib.request.urlopen(req, timeout=600) as response:
            res_data = json.loads(response.read().decode('utf-8'))
            print(f"[AI Helper] Successfully pulled model {model_name}: {res_data}")
            return True
    except Exception as e:
        print(f"[AI Helper] Error pulling model {model_name}: {e}")
        return False

def translate_image_to_latex(image_base64):
    """Calls Ollama multimodal API to translate a base64-encoded image of an equation into clean LaTeX (no delimiters)."""
    vision_model = get_ollama_vision_model()
    if not vision_model:
        return "MODEL_NOT_FOUND"
        
    prompt = (
        "Transcribe the mathematical equation or expression in this image into valid LaTeX format. "
        "Do NOT wrap the equation in any delimiters like $ or $$ or \\[ or \\]. "
        "Return ONLY the raw LaTeX code itself. Do NOT include any conversational text, explanations, intro, or outro."
    )
    
    body = {
        "model": vision_model,
        "prompt": prompt,
        "images": [image_base64],
        "stream": False
    }
    
    try:
        req = urllib.request.Request(
            "http://localhost:11434/api/generate",
            data=json.dumps(body).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        with urllib.request.urlopen(req, timeout=90) as response:
            res_data = json.loads(response.read().decode('utf-8'))
            resp = res_data.get('response', '').strip()
            return clean_latex_output(resp)
    except Exception as e:
        print(f"[AI Helper] Error calling Ollama vision API: {e}")
        return None

def ensure_note_summarized(note_id):
    """Ensures that the lecture note has an AI summary in the database."""
    if is_note_failed(note_id):
        return
    conn = database.get_connection()
    c = conn.cursor()
    c.execute("SELECT ai_summary FROM notes WHERE id = ?", (note_id,))
    row = c.fetchone()
    conn.close()
    if not row or not row[0] or "Unable to generate summary" in row[0]:
        print(f"[AI Helper] Summarizing note ID {note_id} for pre-lecture prep...")
        process_note_sync(note_id)

def generate_pre_lecture_primer(current_note_id, prev_note_id=None):
    """Generates the Pre-Lecture Primer from Qwen for the selected lecture, caching the result."""
    # Check cache first
    conn = database.get_connection()
    c = conn.cursor()
    c.execute("SELECT pre_lecture_primer FROM notes WHERE id = ?", (current_note_id,))
    row = c.fetchone()
    conn.close()
    if row and row[0]:
        print(f"[AI Helper] Returning cached Pre-Lecture Primer for Note ID {current_note_id}")
        return row[0].strip()

    # Ensure current note is summarized
    ensure_note_summarized(current_note_id)
    
    # Get current note info
    conn = database.get_connection()
    c = conn.cursor()
    c.execute("SELECT title, ai_summary FROM notes WHERE id = ?", (current_note_id,))
    curr_row = c.fetchone()
    
    # Get previous note info if available
    prev_row = None
    if prev_note_id:
        ensure_note_summarized(prev_note_id)
        c.execute("SELECT title, ai_summary FROM notes WHERE id = ?", (prev_note_id,))
        prev_row = c.fetchone()
    conn.close()
    
    if not curr_row:
        return "Could not retrieve current lecture details."
        
    curr_title, curr_summary = curr_row
    model_name = get_ollama_model()
    
    if prev_row:
        prev_title, prev_summary = prev_row
        prompt = (
            f"You are a helpful physics academic assistant. Create a 'Pre-Lecture Primer' for my upcoming lecture.\n\n"
            f"Current Lecture: '{curr_title}'\n"
            f"Previous Lecture: '{prev_title}'\n\n"
            f"Here is what was covered in the previous lecture:\n{prev_summary}\n\n"
            f"Here is the content/summary of the current lecture:\n{curr_summary}\n\n"
            f"Please generate a response with the following exact structure, starting directly with the headers. Do NOT include any conversational intro or outro filler.\n\n"
            f"[What Happened in the Last Lecture]\n"
            f"A concise, 1-2 sentence summary of the key concepts from the last lecture.\n\n"
            f"[How it Links into This Lecture]\n"
            f"A 1-2 sentence explanation of how the concepts from the last lecture connect or lead into the topics of this upcoming lecture.\n\n"
            f"[What You Will Learn Today]\n"
            f"A brief, high-level overview (2-3 sentences) giving a clear understanding of what will be learned today.\n\n"
            f"[Three Open Questions for the Lecture]\n"
            f"A list of 3 thought-provoking, open-ended questions about this lecture's topic that I should try to solve during class. Format as:\n"
            f"- 1. [First Question]\n"
            f"- 2. [Second Question]\n"
            f"- 3. [Third Question]"
        )
    else:
        prompt = (
            f"You are a helpful physics academic assistant. Create a 'Pre-Lecture Primer' for my upcoming lecture.\n\n"
            f"This is the first lecture of the module: '{curr_title}'\n"
            f"Here is the content/summary of the current lecture:\n{curr_summary}\n\n"
            f"Please generate a response with the following exact structure, starting directly with the headers. Do NOT include any conversational intro or outro filler.\n\n"
            f"[What You Will Learn Today]\n"
            f"A brief, high-level overview (2-3 sentences) giving a clear understanding of what will be learned today.\n\n"
            f"[Three Open Questions for the Lecture]\n"
            f"A list of 3 thought-provoking, open-ended questions about this lecture's topic that I should try to solve during class. Format as:\n"
            f"- 1. [First Question]\n"
            f"- 2. [Second Question]\n"
            f"- 3. [Third Question]"
        )
        
    primer_res = call_ollama(prompt, model_name)
    if not primer_res:
        import time
        failed_note_times[current_note_id] = time.time()
        return "Unable to generate pre-lecture primer. Please verify Ollama is running."
    
    final_primer = primer_res
    
    conn = database.get_connection()
    c = conn.cursor()
    c.execute("UPDATE notes SET pre_lecture_primer = ? WHERE id = ?", (final_primer, current_note_id))
    conn.commit()
    conn.close()
    return final_primer

def get_next_pending_job():
    """Returns the next background analysis job that needs to run."""
    import threading
    conn = database.get_connection()
    c = conn.cursor()
    
    # Get all notes grouped by module and ordered by week and ID
    # to accurately determine prev_note_id for primers
    try:
        c.execute("""
            SELECT n.id, n.topic_id, n.ai_summary, n.pre_lecture_primer, t.module_id
            FROM notes n
            JOIN topics t ON n.topic_id = t.id
            ORDER BY t.module_id, t.week ASC, n.id ASC
        """)
        notes = c.fetchall()
    except Exception as e:
        print(f"[AI Helper] Error querying notes for background processor: {e}")
        notes = []
    finally:
        conn.close()
    
    # Group notes by module_id
    modules_notes = {}
    for note in notes:
        n_id, topic_id, ai_summary, pre_lecture_primer, module_id = note
        modules_notes.setdefault(module_id, []).append(note)
        
    # Get list of currently running thread names to avoid duplicates
    running_names = {t.name for t in threading.enumerate()}
    
    for module_id, m_notes in modules_notes.items():
        for idx, note in enumerate(m_notes):
            n_id, topic_id, ai_summary, pre_lecture_primer, _ = note
            
            # Check if summary is missing or contains error message, and not blacklisted
            if (not ai_summary or "Unable to generate summary" in ai_summary) and not is_note_failed(n_id):
                thread_name = f"AI_Summary_{n_id}"
                if thread_name not in running_names:
                    return {
                        "type": "summary",
                        "note_id": n_id,
                        "thread_name": thread_name,
                        "func": lambda nid=n_id: process_note_sync(nid)
                    }
                    
            # Check if primer is missing or contains error message, and not blacklisted
            if (not pre_lecture_primer or "Unable to generate pre-lecture primer" in pre_lecture_primer) and not is_note_failed(n_id):
                # Find previous note in the ordered list
                prev_note_id = m_notes[idx - 1][0] if idx > 0 else None
                thread_name = f"AI_Primer_{n_id}"
                if thread_name not in running_names:
                    return {
                        "type": "primer",
                        "note_id": n_id,
                        "thread_name": thread_name,
                        "func": lambda nid=n_id, pid=prev_note_id: generate_pre_lecture_primer(nid, pid)
                    }
                    
    return None

def is_ollama_running():
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        with urllib.request.urlopen(req, timeout=1.0) as response:
            return True
    except Exception:
        return False

def start_background_processor():
    """Starts a long-running background thread that processes pending note summaries, difficulty ratings, and pre-lecture primers sequentially."""
    import time
    import threading
    print("[AI Helper] Background processor manager started.")
    while True:
        try:
            if active_user_requests_count > 0:
                time.sleep(1)
                continue
                
            if is_ollama_running():
                job = get_next_pending_job()
                if job:
                    t = threading.Thread(
                        target=job["func"],
                        name=job["thread_name"],
                        daemon=True
                    )
                    print(f"[AI Helper] Background processor launching job: {job['thread_name']}")
                    t.start()
                    t.join()  # Wait for this specific job to complete before checking next
                    time.sleep(3)  # Cooldown between jobs to give system breathing room
                else:
                    time.sleep(5)
            else:
                # Ollama is offline, wait 1s before checking again
                time.sleep(1)
        except Exception as e:
            print(f"[AI Helper] Error in background processor loop: {e}")
            time.sleep(5)

def evaluate_feynman_summary(explanation, note_title, ai_summary):
    start_user_request()
    try:
        model_name = get_ollama_model()
        prompt = (
            f"You are a physics professor. The user is using the Feynman technique to explain a lecture note they just studied.\n"
            f"Lecture Note Title: {note_title}\n"
            f"Reference Summary (overview and key concepts): \n{ai_summary}\n\n"
            f"The user's explanation:\n{explanation}\n\n"
            f"Assess the user's explanation. Grade it out of 10 (integer rating) based on accuracy, completeness, and clarity. "
            f"List any important concepts, terms, or equations from the reference summary that the user left out or explained poorly.\n\n"
            f"Your response MUST follow this exact structure:\n"
            f"Rating: [X]/10\n"
            f"Feedback: [1-2 sentences of general encouragement/feedback]\n"
            f"Concepts Left Out:\n"
            f"- [Concept/Equation 1]: [brief note why it is important]\n"
            f"- [Concept/Equation 2]: [brief note why it is important]\n\n"
            f"Do NOT include any conversational introduction or outro. Start directly with 'Rating:'."
        )
        return call_ollama(prompt, model_name)
    finally:
        end_user_request()

def get_feynman_dialogue_response(note_title, ai_summary, chat_history):
    start_user_request()
    try:
        model_name = get_ollama_model()
        history_str = ""
        for msg in chat_history[-6:]:
            role_label = "Student" if msg['role'] == 'assistant' else "User"
            history_str += f"{role_label}: {msg['content']}\n"
            
        prompt = (
            f"You are a curious, slightly confused physics student who is trying to understand a lecture topic from the user. "
            f"The lecture note is: '{note_title}'.\n"
            f"Here is the reference summary of the topic: \n{ai_summary}\n\n"
            f"You want to learn this topic from the user using the Feynman technique. Ask probing, conceptual questions "
            f"or point out potential logical gaps in their explanations. Be friendly, polite, but analytically rigorous (like a good student trying to really learn it). "
            f"Keep your responses relatively brief (1-3 sentences) so it feels like a natural conversation. "
            f"Do NOT use sparkles emoji ('✨') anywhere in your response.\n\n"
            f"Conversation History:\n{history_str}"
            f"Student:"
        )
        return call_ollama(prompt, model_name)
    finally:
        end_user_request()

def generate_feynman_starting_question(note_title, ai_summary):
    start_user_request()
    try:
        model_name = get_ollama_model()
        prompt = (
            f"You are a curious physics student. The user just studied a lecture notes topic: '{note_title}'.\n"
            f"Here is the reference summary of the topic: \n{ai_summary}\n\n"
            f"Ask the user one specific, conceptual question to test their understanding of this topic. "
            f"Do NOT ask them to explain the entire topic or summarize it. Instead, ask about a specific mechanism, "
            f"implication, equation, or physical scenario related to the topic. "
            f"Keep your question brief and sound like a student speaking (1-2 sentences). Do NOT use sparkles emoji ('✨').\n\n"
            f"Student Question:"
        )
        return call_ollama(prompt, model_name)
    finally:
        end_user_request()
