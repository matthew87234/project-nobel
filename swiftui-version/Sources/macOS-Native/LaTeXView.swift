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
    private let title: String
    
    public init(title: String = "Generating LaTeX...") {
        self.title = title
    }
    
    public var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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

public struct AILaTeXGeneratingView: View {
    private let title: String
    
    public init(title: String = "Generating LaTeX...") {
        self.title = title.isEmpty ? "Generating LaTeX..." : title
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(height: 44)
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
    if lower.contains("tabular") || lower.contains("array") { return true }
    return false
}

public func convertTabularToArray(_ rawText: String) -> String {
    guard rawText.contains("\\begin{tabular}") else { return rawText }
    
    let pattern = #"(?s)\\begin\{tabular\}\s*(\{[^}]+\})(.*?)\\end\{tabular\}"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return rawText }
    
    let nsStr = rawText as NSString
    let matches = regex.matches(in: rawText, options: [], range: NSRange(location: 0, length: nsStr.length))
    var result = rawText
    
    for match in matches.reversed() {
        let colSpec = nsStr.substring(with: match.range(at: 1))
        let body = nsStr.substring(with: match.range(at: 2))
        
        let lines = body.components(separatedBy: "\\\\")
        var convertedLines = [String]()
        
        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            var prefix = ""
            if trimmed.hasPrefix("\\hline") {
                prefix = "\\hline "
                trimmed = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if trimmed.isEmpty {
                convertedLines.append(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
                continue
            }
            
            let cells = trimmed.components(separatedBy: "&")
            var newCells = [String]()
            for cell in cells {
                var c = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                if c.hasPrefix("$") && c.hasSuffix("$") && c.count >= 2 {
                    c = String(c.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !c.isEmpty && !c.hasPrefix("\\text") && !c.hasPrefix("\\mathbf") {
                    let hasLetters = c.rangeOfCharacter(from: .letters) != nil
                    let isMath = c.contains("\\") || c.contains("^") || c.contains("_") || c.contains("{") || c.contains("}")
                    if hasLetters && !isMath {
                        c = "\\text{\(c)}"
                    }
                }
                newCells.append(c)
            }
            convertedLines.append(prefix + newCells.joined(separator: " & "))
        }
        
        let newBody = convertedLines.joined(separator: " \\\\\n")
        let replacement = "\n$$\n\\begin{array}\(colSpec)\n\(newBody)\n\\end{array}\n$$\n"
        result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
    }
    
    return result
}

public func sanitizeLaTeX(_ rawText: String) -> String {
    var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return "" }
    
    // 1. Strip markdown bold **text** -> text, lingering asterisks, and code block fences (``` or ```latex)
    text = text.replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?m)^```[a-zA-Z0-9_-]*\s*$"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: "```", with: "")
    text = text.replacingOccurrences(of: "'''", with: "")
    
    // 2. Clean \url{...} commands and unsupported TikZ drawing environments (unsupported by KaTeX)
    text = text.replacingOccurrences(of: #"\\url\{([^}]+)\}"#, with: "$1", options: .regularExpression)
    if text.contains("tikzpicture") {
        text = text.replacingOccurrences(of: #"(?s)\\begin\{array\}\{[^}]*\}\s*\\begin\{tikzpicture\}.*?\\end\{tikzpicture\}\s*\\end\{array\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)\\begin\{tikzpicture\}.*?\\end\{tikzpicture\}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)\$\$\s*\$\$"#, with: "", options: .regularExpression)
    }
    
    // 3. Convert LaTeX \begin{tabular} to KaTeX-compatible \begin{array}
    text = convertTabularToArray(text)
    
    // 4. Auto-balance unclosed curly braces '{' and '}'
    var openBraces = 0
    var closeBraces = 0
    for char in text {
        if char == "{" { openBraces += 1 }
        else if char == "}" { closeBraces += 1 }
    }
    if openBraces > closeBraces {
        text.append(String(repeating: "}", count: openBraces - closeBraces))
    }
    
    // 5. Fix unescaped % and & outside math environments
    text = text.replacingOccurrences(of: " % ", with: " \\% ")
    if !text.contains("\\begin") && !text.contains("\\matrix") && !text.contains("\\array") {
        text = text.replacingOccurrences(of: " & ", with: " \\& ")
    }
    
    // 6. Auto-convert align environments to aligned for KaTeX compatibility
    text = text.replacingOccurrences(of: #"\begin\{align\*?\}"#, with: #"\begin{aligned}"#, options: .regularExpression)
    text = text.replacingOccurrences(of: #"\end\{align\*?\}"#, with: #"\end{aligned}"#, options: .regularExpression)

    // 7. Wrap orphan math environments (aligned, pmatrix, matrix, array, etc.) ONLY if not already inside $$ or $
    let mathEnvs = ["aligned", "matrix", "pmatrix", "bmatrix", "cases", "gather", "array"]
    for env in mathEnvs {
        let pattern = #"(?s)\\begin\{"# + env + #"\}.*?\\end\{"# + env + #"\}"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsStr = text as NSString
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let prefix = nsStr.substring(to: match.range.location)
                let doubleDollarCount = prefix.components(separatedBy: "$$").count - 1
                let isInsideDoubleDollar = (doubleDollarCount % 2) == 1
                
                let withoutDouble = prefix.replacingOccurrences(of: "$$", with: "")
                let singleDollarCount = withoutDouble.components(separatedBy: "$").count - 1
                let isInsideSingleDollar = (singleDollarCount % 2) == 1
                
                if !isInsideDoubleDollar && !isInsideSingleDollar {
                    let block = nsStr.substring(with: match.range)
                    text = (text as NSString).replacingCharacters(in: match.range, with: "\n$$\n" + block + "\n$$\n")
                }
            }
        }
    }
    
    // 8. Fix common AI math typos
    text = text.replacingOccurrences(of: "\\subgroup", with: "\\le")
    // Only fix double backslashes before command letters (e.g. \\frac -> \frac), NEVER strip LaTeX line breaks (\\)
    text = text.replacingOccurrences(of: #"\\\\([a-zA-Z])"#, with: #"\$1"#, options: .regularExpression)
    
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
    
    private class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?
        init(_ delegate: WKScriptMessageHandler) {
            self.delegate = delegate
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "heightHandler")
        
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
        }
        // Only wrap in display math if it contains math commands and is NOT a sentence of English words
        let hasMathCommand = sanitized.contains("\\")
        let hasEnglishWords = sanitized.contains(" ") && (
            sanitized.localizedCaseInsensitiveContains(" the ") ||
            sanitized.localizedCaseInsensitiveContains(" is ") ||
            sanitized.localizedCaseInsensitiveContains(" we ") ||
            sanitized.localizedCaseInsensitiveContains(" of ") ||
            sanitized.localizedCaseInsensitiveContains(" to ") ||
            sanitized.localizedCaseInsensitiveContains(" that ")
        )
        if hasMathCommand && !hasEnglishWords {
            return "$$\n" + sanitized + "\n$$"
        }
        return sanitized
    }
    
    private func generateHTML(initialText: String) -> String {
        let jsonData = (try? JSONSerialization.data(withJSONObject: [initialText], options: [])) ?? Data()
        let safeJsonArray = String(data: jsonData, encoding: .utf8) ?? "[\"\"]"
        
        let bundle = Bundle.main
        let localCSS = bundle.url(forResource: "katex.min", withExtension: "css")?.absoluteString
        let localJS = bundle.url(forResource: "katex.min", withExtension: "js")?.absoluteString
        let localAutoRender = bundle.url(forResource: "auto-render.min", withExtension: "js")?.absoluteString
        
        let cssURL = localCSS ?? "https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.css"
        let jsURL = localJS ?? "https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/katex.min.js"
        let autoRenderURL = localAutoRender ?? "https://cdn.jsdelivr.net/npm/katex@0.16.8/dist/contrib/auto-render.min.js"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link rel="stylesheet" href="\(cssURL)">
            <script src="\(jsURL)"></script>
            <script src="\(autoRenderURL)"></script>
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
                                    {left: "\\\\[", right: "\\\\]", display: true},
                                    {left: "\\\\begin{equation}", right: "\\\\end{equation}", display: true},
                                    {left: "\\\\begin{align}", right: "\\\\end{align}", display: true},
                                    {left: "\\\\begin{align*}", right: "\\\\end{align*}", display: true},
                                    {left: "\\\\begin{aligned}", right: "\\\\end{aligned}", display: true},
                                    {left: "\\\\begin{gather}", right: "\\\\end{gather}", display: true},
                                    {left: "\\\\begin{pmatrix}", right: "\\\\end{pmatrix}", display: true},
                                    {left: "\\\\begin{bmatrix}", right: "\\\\end{bmatrix}", display: true},
                                    {left: "\\\\begin{matrix}", right: "\\\\end{matrix}", display: true},
                                    {left: "\\\\begin{cases}", right: "\\\\end{cases}", display: true}
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
                    let initialData = \(safeJsonArray);
                    window.renderNewMath(initialData[0] || '');
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
