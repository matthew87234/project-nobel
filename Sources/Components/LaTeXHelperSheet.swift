import SwiftUI
import AppKit

enum LaTeXDelimiterHelper {
    static func wrap(_ text: String, preferBlock: Bool = false) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.contains("$") || trimmed.contains("\\(") || trimmed.contains("\\[") {
            return trimmed
        }
        if preferBlock || trimmed.contains("\n") {
            return "$$\n" + trimmed + "\n$$"
        }
        return "$" + trimmed + "$"
    }
    
    static func readClipboardImage() -> (image: NSImage, base64: String)? {
        guard let image = NSImage(pasteboard: NSPasteboard.general),
              let optimized = AIHelper.optimizeImageForOCR(image) else {
            return nil
        }
        return (image, optimized)
    }
    
    static func isValidResult(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("Error:")
            && !trimmed.hasPrefix("No vision model")
    }
}

@MainActor
final class LaTeXHelperController: ObservableObject {
    @Published var inputText: String = ""
    @Published var resultText: String = ""
    @Published var clipboardImage: NSImage? = nil
    @Published var imageBase64: String = ""
    @Published var isTranslating: Bool = false
    
    private var activeTask: Task<Void, Never>? = nil
    private var queuedCompletion: ((String) -> Void)? = nil
    private var queuedFailure: ((_ isMissingVisionModel: Bool) -> Void)? = nil
    private var queuedPreferBlock: Bool = false
    private var queuedCopyToClipboard: Bool = false
    
    var hasPendingInputOrResult: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clipboardImage != nil
            || !imageBase64.isEmpty
            || !resultText.isEmpty
    }
    
    func reset() {
        activeTask?.cancel()
        activeTask = nil
        queuedCompletion = nil
        queuedFailure = nil
        inputText = ""
        resultText = ""
        clipboardImage = nil
        imageBase64 = ""
        isTranslating = false
    }
    
    func pasteClipboardImage() {
        guard let clip = LaTeXDelimiterHelper.readClipboardImage() else { return }
        clipboardImage = clip.image
        imageBase64 = clip.base64
        translateImage(base64: clip.base64)
    }
    
    func translateText(
        preferBlock: Bool = false,
        copyToClipboard: Bool = false,
        onComplete: ((String) -> Void)? = nil,
        onFailure: ((_ isMissingVisionModel: Bool) -> Void)? = nil
    ) {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        startTranslation(
            preferBlock: preferBlock,
            copyToClipboard: copyToClipboard,
            onComplete: onComplete,
            onFailure: onFailure
        ) {
            await AIHelper.shared.translateToLaTeX(rawEquation: query)
        }
    }
    
    func translateImage(
        base64: String? = nil,
        preferBlock: Bool = false,
        copyToClipboard: Bool = false,
        onComplete: ((String) -> Void)? = nil,
        onFailure: ((_ isMissingVisionModel: Bool) -> Void)? = nil
    ) {
        let b64 = base64 ?? imageBase64
        guard !b64.isEmpty else { return }
        startTranslation(
            preferBlock: preferBlock,
            copyToClipboard: copyToClipboard,
            onComplete: onComplete,
            onFailure: onFailure
        ) {
            await AIHelper.shared.translateImageToLaTeX(base64Image: b64)
        }
    }
    
    func commitOrQueue(
        preferBlock: Bool = false,
        copyToClipboard: Bool = true,
        onQueuedInBackground: () -> Void,
        onComplete: @escaping (String) -> Void,
        onFailure: @escaping (_ isMissingVisionModel: Bool) -> Void
    ) {
        if LaTeXDelimiterHelper.isValidResult(resultText) {
            let wrapped = LaTeXDelimiterHelper.wrap(resultText, preferBlock: preferBlock)
            if copyToClipboard {
                Self.writeToPasteboard(wrapped)
            }
            onComplete(wrapped)
            reset()
            return
        }
        
        if isTranslating {
            queuedPreferBlock = preferBlock
            queuedCopyToClipboard = copyToClipboard
            queuedCompletion = onComplete
            queuedFailure = onFailure
            onQueuedInBackground()
            return
        }
        
        let trimmedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            onQueuedInBackground()
            translateText(
                preferBlock: preferBlock,
                copyToClipboard: copyToClipboard,
                onComplete: onComplete,
                onFailure: onFailure
            )
        } else if !imageBase64.isEmpty {
            onQueuedInBackground()
            translateImage(
                base64: imageBase64,
                preferBlock: preferBlock,
                copyToClipboard: copyToClipboard,
                onComplete: onComplete,
                onFailure: onFailure
            )
        } else if let img = clipboardImage, let opt = AIHelper.optimizeImageForOCR(img) {
            imageBase64 = opt
            onQueuedInBackground()
            translateImage(
                base64: opt,
                preferBlock: preferBlock,
                copyToClipboard: copyToClipboard,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }
    }
    
    private func startTranslation(
        preferBlock: Bool,
        copyToClipboard: Bool,
        onComplete: ((String) -> Void)?,
        onFailure: ((_ isMissingVisionModel: Bool) -> Void)?,
        operation: @escaping @Sendable () async -> String?
    ) {
        activeTask?.cancel()
        isTranslating = true
        resultText = ""
        queuedPreferBlock = preferBlock
        queuedCopyToClipboard = copyToClipboard
        queuedCompletion = onComplete
        queuedFailure = onFailure
        
        activeTask = Task { @MainActor [weak self] in
            let res = await operation()
            guard let self, !Task.isCancelled else { return }
            self.isTranslating = false
            
            if let latex = res, !latex.isEmpty {
                if latex == "MODEL_NOT_FOUND" {
                    self.resultText = "No vision model found on AI server. Please configure or pull a vision model in Settings."
                    let failHandler = self.queuedFailure
                    self.clearQueuedHandlers()
                    failHandler?(true)
                } else {
                    let wrapped = LaTeXDelimiterHelper.wrap(latex, preferBlock: self.queuedPreferBlock)
                    self.resultText = wrapped
                    if self.queuedCopyToClipboard {
                        Self.writeToPasteboard(wrapped)
                    }
                    let completion = self.queuedCompletion
                    self.clearQueuedHandlers()
                    completion?(wrapped)
                }
            } else {
                self.resultText = "Error: Could not translate equation. Verify that your AI engine is connected."
                let failHandler = self.queuedFailure
                self.clearQueuedHandlers()
                failHandler?(false)
            }
        }
    }
    
    private func clearQueuedHandlers() {
        queuedCompletion = nil
        queuedFailure = nil
    }
    
    static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct LaTeXTargetAction: Identifiable {
    let id: String
    let title: String
    let pendingTitle: String
    let isProminent: Bool
    let preferBlock: Bool
    let requiresResolvedResult: Bool
    let onWillQueueInBackground: () -> Void
    let onComplete: (String) -> Void
    let onFailure: (_ isMissingVisionModel: Bool) -> Void
    
    init(
        id: String,
        title: String,
        pendingTitle: String? = nil,
        isProminent: Bool = true,
        preferBlock: Bool = false,
        requiresResolvedResult: Bool = false,
        onWillQueueInBackground: @escaping () -> Void = {},
        onComplete: @escaping (String) -> Void,
        onFailure: @escaping (_ isMissingVisionModel: Bool) -> Void = { _ in }
    ) {
        self.id = id
        self.title = title
        self.pendingTitle = pendingTitle ?? title
        self.isProminent = isProminent
        self.preferBlock = preferBlock
        self.requiresResolvedResult = requiresResolvedResult
        self.onWillQueueInBackground = onWillQueueInBackground
        self.onComplete = onComplete
        self.onFailure = onFailure
    }
}

@MainActor
struct LaTeXHelperSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var controller: LaTeXHelperController
    var title: String = "LaTeX Equation Translator"
    var subtitle: String = "Describe an equation in plain text or paste an image from your clipboard, and AI will convert it into clean LaTeX code."
    var placeholder: String = "e.g. integral from 0 to infinity of e to the minus x squared"
    var closeLabel: String = "Close"
    var showCopyButton: Bool = true
    let actions: [LaTeXTargetAction]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text(title)
                        .font(.title2)
                        .bold()
                    
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Equation Description:")
                                .bold()
                            TextField(placeholder, text: $controller.inputText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    controller.translateText()
                                }
                            
                            Button("Translate Text") {
                                controller.translateText()
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.isTranslating)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Clipboard Image Preview:")
                                .bold()
                            
                            if let img = controller.clipboardImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(height: 60)
                                    .border(Color.secondary.opacity(0.3))
                            } else {
                                VStack {
                                    Text("No Image Pasted")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                            }
                            
                            Button("Paste Image from Clipboard") {
                                controller.pasteClipboardImage()
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.isTranslating)
                        }
                    }
                    .padding(.vertical, 10)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Result LaTeX Code:")
                            .bold()
                        
                        if controller.isTranslating {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Translating equation via AI model...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            TextEditor(text: $controller.resultText)
                                .font(.system(.body, design: .monospaced))
                                .frame(height: 60)
                                .border(Color.secondary.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                    
                    if LaTeXDelimiterHelper.isValidResult(controller.resultText) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Equation Preview:")
                                .bold()
                            LaTeXView(latex: controller.resultText)
                                .frame(height: 70)
                                .background(Color(NSColor.windowBackgroundColor))
                                .cornerRadius(6)
                                .border(Color.secondary.opacity(0.15), width: 1)
                        }
                    }
                }
            }
            
            Divider()
            
            HStack {
                Button(closeLabel) {
                    isPresented = false
                    controller.reset()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                if showCopyButton {
                    Button("Copy to Clipboard") {
                        let wrapped = LaTeXDelimiterHelper.wrap(controller.resultText)
                        LaTeXHelperController.writeToPasteboard(wrapped)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!LaTeXDelimiterHelper.isValidResult(controller.resultText))
                }
                
                ForEach(actions) { action in
                    actionButton(for: action)
                }
            }
        }
        .padding(20)
        .frame(width: 580, height: 500)
    }
    
    @ViewBuilder
    private func actionButton(for action: LaTeXTargetAction) -> some View {
        let isDisabled = action.requiresResolvedResult
            ? !LaTeXDelimiterHelper.isValidResult(controller.resultText)
            : !controller.hasPendingInputOrResult
        let label = controller.isTranslating ? action.pendingTitle : action.title
        
        if action.isProminent {
            Button(label) {
                triggerAction(action)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isDisabled)
        } else {
            Button(label) {
                triggerAction(action)
            }
            .buttonStyle(.bordered)
            .disabled(isDisabled)
        }
    }
    
    private func triggerAction(_ action: LaTeXTargetAction) {
        controller.commitOrQueue(
            preferBlock: action.preferBlock,
            copyToClipboard: showCopyButton,
            onQueuedInBackground: {
                action.onWillQueueInBackground()
                isPresented = false
            },
            onComplete: { wrapped in
                action.onComplete(wrapped)
                isPresented = false
            },
            onFailure: { isMissingVision in
                action.onFailure(isMissingVision)
            }
        )
    }
}
