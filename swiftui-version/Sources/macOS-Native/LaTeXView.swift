import SwiftUI
import WebKit

public enum AILatexPlaceholder {
    public static let token = "[AI: Generating LaTeX...]"
    
    public static func hasPlaceholder(_ text: String) -> Bool {
        return text.contains("[AI: Generating LaTeX...]") || text.contains("Generating LaTeX...")
    }
    
    public static func cleanText(_ text: String) -> String {
        let patterns = [
            "\\$\\s*\\\\text\\{\\s*\\[AI:\\s*Generating LaTeX\\.\\.\\.\\]\\s*\\}*\\s*\\$*",
            "\\$\\s*\\[AI:\\s*Generating LaTeX\\.\\.\\.\\]\\s*\\$",
            "\\[AI:\\s*Generating LaTeX\\.\\.\\.\\]",
            "Generating LaTeX\\.\\.\\."
        ]
        var result = text
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: result.utf16.count)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    public static func replaceOrAppend(in text: inout String, with latex: String) {
        let patterns = [
            "\\$\\s*\\\\text\\{\\s*\\[AI:\\s*Generating LaTeX\\.\\.\\.\\]\\s*\\}*\\s*\\$*",
            "\\$\\s*\\[AI:\\s*Generating LaTeX\\.\\.\\.\\]\\s*\\$",
            "\\[AI:\\s*Generating LaTeX\\.\\.\\.\\]",
            "Generating LaTeX\\.\\.\\."
        ]
        var replaced = false
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(location: 0, length: text.utf16.count)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: latex)
                    replaced = true
                    break
                }
            }
        }
        if !replaced {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                text = latex
            } else {
                text = trimmed + "\n" + latex
            }
        }
    }
}

public struct TypingIndicatorBubble: View {
    public init() {}
    
    public var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    // Continuous sinusoidal wave bounce: 3 dots fluidly glide up and down
                    let phase = (time * 4.5) - (Double(index) * 0.6)
                    let yOffset = sin(phase) * 4.5
                    
                    Circle()
                        .fill(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 7, height: 7)
                        .offset(y: yOffset)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.85))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
    }
}

public struct AILaTeXGeneratingView: View {
    public init(title: String = "") {}
    
    public var body: some View {
        HStack {
            Spacer()
            TypingIndicatorBubble()
            Spacer()
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

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

public struct LaTeXView: View {
    public let latex: String
    @State private var dynamicHeight: CGFloat
    
    public init(latex: String) {
        self.latex = latex
        self._dynamicHeight = State(initialValue: LaTeXView.estimateInitialHeight(latex))
    }
    
    public var body: some View {
        _LaTeXWebViewRepresentable(latex: latex, dynamicHeight: $dynamicHeight)
            .frame(height: max(16, dynamicHeight))
            .onChange(of: latex) { _, newLatex in
                self.dynamicHeight = LaTeXView.estimateInitialHeight(newLatex)
            }
    }
    
    public static func estimateInitialHeight(_ raw: String) -> CGFloat {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("$$") || text.contains("\\[") {
            let newlineCount = text.components(separatedBy: "\\\\").count - 1
            if newlineCount > 0 {
                return CGFloat(max(34, 30 + newlineCount * 24))
            }
            let fracCount = text.components(separatedBy: "\\frac").count - 1 + text.components(separatedBy: "\\dfrac").count - 1
            return fracCount > 0 ? 42 : 30
        }
        let lines = max(1, (text.count + 55) / 60)
        return CGFloat(lines * 19 + 4)
    }
}

struct _LaTeXWebViewRepresentable: NSViewRepresentable {
    let latex: String
    @Binding var dynamicHeight: CGFloat
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: _LaTeXWebViewRepresentable
        var lastRenderedLatex: String? = nil
        var isReady: Bool = false
        var queuedLatex: String? = nil
        
        init(_ parent: _LaTeXWebViewRepresentable) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "heightHandler", let heightNum = message.body as? NSNumber {
                let h = CGFloat(heightNum.doubleValue)
                if h > 0 {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        if abs(self.parent.dynamicHeight - h) >= 1.0 {
                            self.parent.dynamicHeight = h
                        }
                    }
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            if let pending = queuedLatex {
                queuedLatex = nil
                renderMath(pending, in: webView)
            }
        }
        
        func renderMath(_ formattedText: String, in webView: WKWebView) {
            guard formattedText != lastRenderedLatex else { return }
            lastRenderedLatex = formattedText
            
            if !isReady {
                queuedLatex = formattedText
                return
            }
            
            if let data = try? JSONSerialization.data(withJSONObject: [formattedText], options: []),
               let jsonArr = String(data: data, encoding: .utf8) {
                let js = "if (window.renderNewMath) { window.renderNewMath(\(jsonArr)[0]); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.add(context.coordinator, name: "heightHandler")
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        
        let formatted = formatLatex(latex)
        context.coordinator.queuedLatex = formatted
        
        let html = generateHTML(initialText: formatted)
        webView.loadHTMLString(html, baseURL: nil)
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let formatted = formatLatex(latex)
        context.coordinator.renderMath(formatted, in: nsView)
    }
    
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "heightHandler")
    }
    
    private func formatLatex(_ raw: String) -> String {
        let sanitized = sanitizeLaTeX(raw)
        if sanitized.isEmpty {
            return ""
        } else if sanitized.contains("$") || sanitized.contains("\\(") || sanitized.contains("\\[") {
            return sanitized
        } else if sanitized.contains("\n") {
            return "$$\n" + sanitized + "\n$$"
        } else {
            return "$" + sanitized + "$"
        }
    }
    
    private func generateHTML(initialText: String) -> String {
        let escapedInitial = initialText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/contrib/auto-render.min.js"></script>
            <style>
                ::-webkit-scrollbar {
                    display: none !important;
                    width: 0 !important;
                    height: 0 !important;
                }
                html, body {
                    margin: 0;
                    padding: 0;
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                    background-color: transparent;
                    color: currentColor;
                    box-sizing: border-box;
                    text-align: left;
                    overflow-x: hidden;
                    overflow-y: hidden;
                    cursor: default !important;
                    user-select: text !important;
                    -webkit-user-select: text !important;
                }
                @media (prefers-color-scheme: dark) {
                    body { color: #FFFFFF; }
                }
                @media (prefers-color-scheme: light) {
                    body { color: #000000; }
                }
                .math-content {
                    display: flow-root;
                    font-size: 13.5px;
                    line-height: 1.4;
                    max-width: 100%;
                    word-wrap: break-word;
                    white-space: pre-wrap;
                    text-align: left;
                    padding: 1px 2px;
                    box-sizing: border-box;
                }
                .katex-display {
                    display: block !important;
                    margin: 0.15em auto !important;
                    padding: 0 !important;
                    text-align: center !important;
                }
                .katex-display > .katex {
                    display: inline-block !important;
                    text-align: center !important;
                    white-space: normal !important;
                }
                .katex-display > .katex > .katex-html {
                    text-align: center !important;
                }
                .katex {
                    font-size: 1.1em !important;
                    line-height: 1.25 !important;
                }
            </style>
        </head>
        <body>
            <div class="math-content" id="math-render"></div>
            <script>
                function reportHeight() {
                    try {
                        let container = document.getElementById("math-render");
                        if (container) {
                            let rect = container.getBoundingClientRect();
                            let finalH = Math.ceil(rect.height + 2);
                            if (finalH > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.heightHandler) {
                                window.webkit.messageHandlers.heightHandler.postMessage(finalH);
                            }
                        }
                    } catch (err) {}
                }

                window.renderNewMath = function(rawText) {
                    try {
                        let container = document.getElementById("math-render");
                        if (!container) return;
                        let trimmed = (rawText || '').trim();
                        container.textContent = trimmed;
                        
                        let isOnlyMath = (trimmed.startsWith('$$') && trimmed.endsWith('$$')) ||
                                         (trimmed.startsWith('\\[') && trimmed.endsWith('\\]')) ||
                                         (trimmed.startsWith('$') && trimmed.endsWith('$') && !trimmed.includes('. '));
                        if (isOnlyMath) {
                            container.style.textAlign = 'center';
                        } else {
                            container.style.textAlign = 'left';
                        }
                        
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
                            setTimeout(reportHeight, 10);
                        } else {
                            setTimeout(function() { window.renderNewMath(rawText); }, 50);
                        }
                    } catch (e) {
                        let container = document.getElementById("math-render");
                        if (container) container.innerText = e.message;
                    }
                };
                
                document.addEventListener('DOMContentLoaded', function() {
                    window.renderNewMath(`\(escapedInitial)`);
                    setTimeout(reportHeight, 30);
                });

                if (window.ResizeObserver) {
                    let ro = new ResizeObserver(() => {
                        reportHeight();
                    });
                    let container = document.getElementById("math-render");
                    if (container) ro.observe(container);
                }
            </script>
        </body>
        </html>
        """
    }
}
