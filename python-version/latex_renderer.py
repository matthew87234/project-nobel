import io
import threading
import re
from PIL import Image

_original_resize = Image.Image.resize

def _high_quality_resize(self, size, resample=None, box=None, reducing_gap=None):
    if resample is None or resample == Image.Resampling.NEAREST:
        resample = Image.Resampling.LANCZOS
    return _original_resize(self, size, resample=resample, box=box, reducing_gap=reducing_gap)

Image.Image.resize = _high_quality_resize

_latex_lock = threading.Lock()
_initialized = False


def auto_wrap_latex(text):
    if not text:
        return text
    if "$" in text or "\\begin{" in text:
        return text
        
    # Heuristic to check if the entire string is a pure mathematical equation
    # 1. Remove \text{...} blocks
    temp = re.sub(r'\\text\{[^{}]*\}', '', text)
    # 2. Remove LaTeX commands (e.g. \sum, \alpha)
    temp = re.sub(r'\\[a-zA-Z]+', '', temp)
    # 3. Keep only letters
    temp = re.sub(r'[^a-zA-Z\s]', '', temp)
    # 4. Count normal English words (length >= 4)
    words = temp.split()
    english_words = [w for w in words if len(w) >= 4]
    
    # If it has no normal English words, and contains LaTeX/math indicator characters,
    # wrap the entire string as a single equation
    has_math_indicators = any(c in text for c in ['\\', '_', '^', '=', '<', '>', '+', '-', '*', '/', '|'])
    if len(english_words) == 0 and has_math_indicators:
        return f"${text.strip()}$"

    # Otherwise, fallback to segment-based wrapping
    # Pattern to match LaTeX commands: e.g. \theta, \frac{1}{2}, \bar{x}, \Delta
    # and any following subscripts/superscripts
    command_pattern = r'\\[a-zA-Z]+(?:\{[^{}]*\})*(?:[\^_](?:\{[^{}]*\}|[a-zA-Z0-9_]{1,2}(?![a-zA-Z0-9_])))*'
    
    # Pattern to match simple math vars with super/subscripts: e.g. x^2, y_0, E_{max}, x_{i,j}
    math_var_pattern = r'[a-zA-Z0-9]+(?:[\^_](?:\{[^{}]*\}|[a-zA-Z0-9_]{1,2}(?![a-zA-Z0-9_])))+'
    
    combined_pattern = f'({command_pattern}|{math_var_pattern})'
    
    def replace_match(match):
        segment = match.group(0)
        return f"${segment}$"
        
    return re.sub(combined_pattern, replace_match, text)


def wrap_text_with_math(text, width=55):
    if not text:
        return text
        
    lines = text.split("\n")
    wrapped_lines = []
    
    for line in lines:
        if not line.strip():
            wrapped_lines.append("")
            continue
            
        # Detect list prefix (e.g. "- ", "* ", "1. ", or indented versions)
        match_prefix = re.match(r'^(\s*(?:-\s+|\*\s+|\d+\.\s+))', line)
        if match_prefix:
            prefix = match_prefix.group(1)
            indent = " " * len(prefix)
            line_to_wrap = line[len(prefix):]
        else:
            prefix = ""
            indent = ""
            line_to_wrap = line
            
        # Split into words, keeping math blocks intact
        pattern = r'(\$[^\$]*\$|\\begin\{[^\}]*\}[\s\S]*?\\end\{[^\}]*\}|\S+)'
        words = re.findall(pattern, line_to_wrap)
        
        current_line = []
        current_length = 0
        first_segment = True
        
        for word in words:
            word_len = len(word)
            # Adjust limit based on whether it is the first segment (which includes the prefix)
            limit = width - len(prefix) if first_segment else width - len(indent)
            
            if current_length + len(current_line) + word_len > limit and current_line:
                if first_segment:
                    wrapped_lines.append(prefix + " ".join(current_line))
                    first_segment = False
                else:
                    wrapped_lines.append(indent + " ".join(current_line))
                current_line = [word]
                current_length = word_len
            else:
                current_line.append(word)
                current_length += word_len
                
        if current_line:
            if first_segment:
                wrapped_lines.append(prefix + " ".join(current_line))
            else:
                wrapped_lines.append(indent + " ".join(current_line))
                
    return "\n".join(wrapped_lines)


def _init_matplotlib():
    global _initialized
    if _initialized:
        return
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    _initialized = True


def render_latex_to_image(latex_str, fontsize=16, dpi=300, text_color="black", wrap_width=72):
    """
    Renders a LaTeX string to a PIL Image.
    Requires matplotlib.
    """
    with _latex_lock:
        _init_matplotlib()
        import matplotlib.pyplot as plt
        from PIL import Image
        
        # 1. Auto-wrap math segments
        wrapped = auto_wrap_latex(latex_str)
        # 2. Wrap text to newlines while preserving math blocks
        final_str = wrap_text_with_math(wrapped, width=wrap_width)
        
        # Create a figure with no axes
        fig = plt.figure(figsize=(0.01, 0.01))
        try:
            fig.text(0, 0, final_str, fontsize=fontsize, color=text_color)
            
            # Save the figure to an in-memory buffer
            buf = io.BytesIO()
            # bbox_inches='tight' crops the image to the text
            # pad_inches=0.1 adds a small border
            fig.savefig(buf, format='png', transparent=True, dpi=dpi, bbox_inches='tight', pad_inches=0.05)
            buf.seek(0)
            image = Image.open(buf)
        finally:
            plt.close(fig)
            
        return image


def prewarm_latex():
    """
    Spins up a background thread to import matplotlib and run a dummy render.
    This warms up the engine so the first user-triggered render is instantaneous.
    """
    import threading
    
    def run_prewarm():
        try:
            render_latex_to_image("x")
        except Exception as e:
            print(f"LaTeX pre-warm warning: {e}")
            
    threading.Thread(target=run_prewarm, daemon=True).start()


def is_latex(text):
    r"""
    Checks if a string contains LaTeX math blocks.
    We require at least two dollar signs ($...$), or a LaTeX environment block (\begin...\end),
    or any auto-wrapped math expressions to avoid false positives on plain text.
    """
    if not text:
        return False
    if text.count("$") >= 2:
        return True
    if "\\begin{" in text and "\\end{" in text:
        return True
    wrapped = auto_wrap_latex(text)
    return wrapped.count("$") >= 2


def is_ready():
    """
    Returns True if matplotlib has been imported and initialized.
    """
    return _initialized

