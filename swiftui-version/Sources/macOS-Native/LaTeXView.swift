import SwiftUI
import WebKit

public func isLaTeX(_ text: String) -> Bool {
    let lower = text.lowercased()
    if text.contains("$") { return true }
    if text.contains("\\") { return true }
    if text.contains("{") && text.contains("}") { return true }
    if text.contains("_") || text.contains("^") { return true }
    if lower.contains("begin{") && lower.contains("end{") { return true }
    return false
}

public func sanitizeLaTeX(_ rawText: String) -> String {
    var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "" }
    
    // 1. Auto-balance unclosed curly braces '{' and '}'
    var openBraces = 0
    var closeBraces = 0
    for char in text {
        if char == "{" { openBraces += 1 }
        else if char == "}" { closeBraces += 1 }
    }
    if openBraces > closeBraces {
        text.append(String(repeating: "}", count: openBraces - closeBraces))
    }
    
    // 2. Fix unescaped % and & outside math environments
    text = text.replacingOccurrences(of: " % ", with: " \\% ")
    if !text.contains("\\begin") && !text.contains("\\matrix") {
        text = text.replacingOccurrences(of: " & ", with: " \\& ")
    }
    
    // 3. Auto-wrap orphan LaTeX commands in $ math delimiters if missing
    if !text.contains("$") && !text.contains("\\(") && !text.contains("\\[") {
        let latexKeywords = ["\\times", "\\frac", "\\mathbf", "\\le", "\\ge", "\\in", "\\to", "\\cdot", "\\int", "\\sum", "\\infty", "\\varepsilon", "\\partial", "\\sqrt"]
        if latexKeywords.contains(where: { text.contains($0) }) {
            text = "$$ " + text + " $$"
        }
    }
    
    // 4. Fix common AI math typos
    text = text.replacingOccurrences(of: "\\subgroup", with: "\\le")
    text = text.replacingOccurrences(of: "\\\\", with: "\\")
    
    return text
}

public struct LaTeXView: NSViewRepresentable {
    public let latex: String
    
    public init(latex: String) {
        self.latex = latex
    }
    
    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        return webView
    }
    
    public func updateNSView(_ nsView: WKWebView, context: Context) {
        let sanitized = sanitizeLaTeX(latex)
        let formattedLatex: String
        if sanitized.isEmpty {
            formattedLatex = ""
        } else if sanitized.contains("$") || sanitized.contains("\\(") || sanitized.contains("\\[") {
            formattedLatex = sanitized
        } else if sanitized.contains("\n") {
            formattedLatex = "$$\n" + sanitized + "\n$$"
        } else {
            formattedLatex = "$" + sanitized + "$"
        }
        
        let escapedLatex = formattedLatex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/contrib/auto-render.min.js"></script>
            <style>
                html, body {
                    margin: 0;
                    padding: 4px 6px;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    background-color: transparent;
                    color: currentColor;
                    box-sizing: border-box;
                    text-align: left;
                    overflow-x: auto !important;
                    overflow-y: visible !important;
                    cursor: default !important;
                    user-select: none !important;
                    -webkit-user-select: none !important;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #FFFFFF; }
                }
                @media (prefers-color-scheme: light) {
                    body { color: #000000; }
                }
                .math-content {
                    font-size: 13.5px;
                    line-height: 1.6;
                    max-width: 100%;
                    word-wrap: break-word;
                    white-space: pre-wrap;
                    text-align: left;
                    overflow: visible !important;
                }
                .katex-display {
                    margin: 0.35em 0 !important;
                    padding: 0.25em 0 !important;
                    text-align: center !important;
                    overflow-x: auto !important;
                    overflow-y: visible !important;
                }
                .katex-display > .katex {
                    text-align: center !important;
                    white-space: normal !important;
                }
                .katex {
                    font-size: 1.15em !important;
                    line-height: 1.4 !important;
                }
            </style>
        </head>
        <body>
            <div class="math-content" id="math-render"></div>
            <script>
                function doRender() {
                    try {
                        let rawText = `\(escapedLatex)`.trim();
                        let container = document.getElementById("math-render");
                        if (!container) return;
                        
                        container.textContent = rawText;
                        
                        if (typeof renderMathInElement === 'function') {
                            renderMathInElement(container, {
                                delimiters: [
                                    {left: "$$", right: "$$", display: true},
                                    {left: "$", right: "$", display: false},
                                    {left: "\\\\(", right: "\\\\)", display: false},
                                    {left: "\\\\[", right: "\\\\]", display: true}
                                ],
                                throwOnError: false,
                                errorColor: "currentColor"
                            });
                        } else {
                            setTimeout(doRender, 100);
                        }
                    } catch (e) {
                        let container = document.getElementById("math-render");
                        if (container) container.innerText = e.message;
                    }
                }
                
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', doRender);
                } else {
                    doRender();
                }
            </script>
        </body>
        </html>
        """
        nsView.loadHTMLString(html, baseURL: nil)
    }
}
