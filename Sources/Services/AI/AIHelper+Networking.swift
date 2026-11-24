import Foundation

extension AIHelper {
    // MARK: - API communication helpers
    
    nonisolated func isVisionModelName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream", "pixtral", "gemma3"]
        return visionKeywords.contains { lower.contains($0) }
    }

    func fetchAvailableOllamaModels(host: String? = nil, forceLocal: Bool = false) async -> [String] {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        let targetHost: String
        if let h = host, !h.isEmpty {
            targetHost = h
        } else {
            if provider == "tailscale" {
                let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                targetHost = !tHost.isEmpty ? tHost : vHost
            } else {
                targetHost = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
        }
        
        guard !targetHost.isEmpty else { return [] }
        guard let baseURL = AIHelper.normalizedOllamaURL(from: targetHost, defaultHost: "") else { return [] }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.map { $0.name }.sorted()
        } catch {
            print("[AI Helper] Could not fetch available models from \(url.absoluteString): \(error)")
            return []
        }
    }

    func getOllamaModel(forProvider provider: String? = nil, forceLocal: Bool = false) async -> String {
        let effProvider = forceLocal ? "local" : (provider ?? UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
        if effProvider != "local" && effProvider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "cloud_model_name") ?? "gpt-4o-mini"
            return cloudModel
        }
        
        let preferredKey = effProvider == "tailscale" ? "tailscale_model_general" : "local_model_general"
        let preferred = UserDefaults.standard.string(forKey: preferredKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let installed = await fetchAvailableOllamaModels(forceLocal: effProvider == "local")
        if !installed.isEmpty {
            if !preferred.isEmpty && installed.contains(preferred) {
                return preferred
            }
            if !preferred.isEmpty, let match = installed.first(where: { $0.lowercased().contains(preferred.lowercased()) }) {
                return match
            }
            if let nonVision = installed.first(where: { !self.isVisionModelName($0) }) {
                UserDefaults.standard.set(nonVision, forKey: preferredKey)
                return nonVision
            }
            if let firstModel = installed.first {
                UserDefaults.standard.set(firstModel, forKey: preferredKey)
                return firstModel
            }
        }
        
        return preferred
    }
    
    func getOllamaVisionModel(forceLocal: Bool = false) async -> String? {
        let provider = forceLocal ? "local" : (UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local"))
        if provider != "local" && provider != "tailscale" {
            let cloudModel = UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o"
            return cloudModel
        }
        let preferredKey = provider == "tailscale" ? "vision_tailscale_model" : "local_model_vision"
        let preferred = UserDefaults.standard.string(forKey: preferredKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        let host: String
        if provider == "tailscale" {
            let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            host = !vHost.isEmpty ? vHost : tHost
        } else {
            host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        }
        
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "") else {
            return !preferred.isEmpty ? preferred : nil
        }
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.0
        
        do {
            let (data, _) = try await session.data(for: request)
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let availableNames = tags.models.map { $0.name }
            
            if !preferred.isEmpty, availableNames.contains(preferred) {
                return preferred
            }
            if !preferred.isEmpty, let match = availableNames.first(where: { $0.lowercased() == preferred.lowercased() }) {
                return match
            }
            
            for m in tags.models {
                if isVisionModelName(m.name) {
                    UserDefaults.standard.set(m.name, forKey: preferredKey)
                    return m.name
                }
            }
            
            if let first = availableNames.first {
                UserDefaults.standard.set(first, forKey: preferredKey)
                return first
            }
        } catch {
            print("[AI Helper] Warning: Error checking for vision model: \(error)")
        }
        
        return !preferred.isEmpty ? preferred : nil
    }
    
    func hasRepetitiveGlitch(_ text: String) -> Bool {
        // 1. Match 6 or more identical non-numeric, non-delimiter characters in a row
        let pattern = "([^ \\-\\*=\\._\\n\\r0-9#~|+])\\1{5,}"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(location: 0, length: text.utf16.count)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        // 2. Detect LLM line-repetition loops (any non-trivial line repeated >= 4 times)
        var lineCounts: [String: Int] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 12, trimmed != "$$", trimmed != "\\hline" else { continue }
            let count = (lineCounts[trimmed] ?? 0) + 1
            if count >= 4 {
                return true
            }
            lineCounts[trimmed] = count
        }
        return false
    }
    
    // MARK: - Fast Network Pre-Flight & Local Fallback
    
    public func isTailscaleReachable() async -> Bool {
        let host = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "") else { return false }
        let tagsUrl = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: tagsUrl)
        req.timeoutInterval = 2.5
        if let (data, resp) = try? await session.data(for: req),
           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
           let tags = try? JSONDecoder().decode(TagsResponse.self, from: data),
           !tags.models.isEmpty {
            return true
        }
        return false
    }
    
    func fallbackToLocalOllama(
        prompt: String,
        images: [String]? = nil,
        timeout: TimeInterval,
        options: OllamaOptions? = nil,
        overrideThink: Bool? = nil
    ) async -> String? {
        await ensureLocalOllamaRunning()
        let localHost = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
        guard let localBaseURL = AIHelper.normalizedOllamaURL(from: localHost, defaultHost: "http://localhost:11434") else { return nil }
        let tagsUrl = localBaseURL.appendingPathComponent("api/tags")
        var checkReq = URLRequest(url: tagsUrl)
        checkReq.timeoutInterval = 2.0
        
        let hasModels: Bool
        if let (data, resp) = try? await session.data(for: checkReq),
           let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200,
           let tags = try? JSONDecoder().decode(TagsResponse.self, from: data),
           !tags.models.isEmpty {
            hasModels = true
        } else {
            hasModels = false
        }
        
        guard hasModels else {
            self.logToFile("[AI Helper LOG] Local Ollama fallback unavailable (no models or server offline).")
            return nil
        }
        
        let fallbackModel: String
        if images != nil && !(images?.isEmpty ?? true) {
            fallbackModel = await getOllamaVisionModel(forceLocal: true) ?? ""
        } else {
            fallbackModel = await getOllamaModel(forceLocal: true)
        }
        guard !fallbackModel.isEmpty else {
            self.logToFile("[AI Helper LOG] Fallback to Local Ollama failed: no local model available.")
            return nil
        }
        self.logToFile("[AI Helper LOG] Seamlessly falling back to Local Ollama with model '\(fallbackModel)'...")
        let hasImgs = images != nil && !(images?.isEmpty ?? true)
        self.updateActiveTaskProvider(provider: "local", isVision: hasImgs, forceLocal: true)
        if let localResult = await callAPIOnce(prompt: prompt, model: fallbackModel, images: images, timeout: timeout, provider: "local", options: options, overrideThink: overrideThink) {
            if !hasRepetitiveGlitch(localResult) {
                return localResult
            }
        }
        return nil
    }

    enum RemoteWaitResolution {
        case remoteRestored
        case fallbackToLocal
        case cancelled
    }

    func waitForRemoteOrLocalFallback(taskDescription: String) async -> RemoteWaitResolution {
        await MainActor.run {
            self.isWaitingForRemoteConnection = true
            self.waitingTaskDescription = taskDescription
            self.pendingLocalFallbackOverride = false
            self.cancelWaitingRemoteFlag = false
            self.isRemoteOnline = false
            self.isAIDisconnected = true
            self.disconnectionMessage = "\(self.remoteEngineName) Disconnected"
            self.remoteTaskStatus = "Paused (waiting for \(self.remoteEngineName))"
        }
        defer {
            Task { @MainActor in
                self.isWaitingForRemoteConnection = false
                self.waitingTaskDescription = ""
            }
        }

        if !self.autoReconnectExhausted && !self.isRunningReconnectLoop {
            Task {
                _ = await self.attemptAutoReconnect(manualRetry: false)
            }
        }

        while !Task.isCancelled {
            if self.cancelWaitingRemoteFlag {
                await MainActor.run {
                    self.cancelWaitingRemoteFlag = false
                }
                return .cancelled
            }
            if self.isLocalOnlyMode || self.shouldFallbackToLocalWhenRemoteOffline || self.pendingLocalFallbackOverride {
                await MainActor.run {
                    self.pendingLocalFallbackOverride = false
                }
                return .fallbackToLocal
            }
            if self.isRemoteOnline && !self.isAIDisconnected {
                await MainActor.run {
                    self.lastTailscaleTimeoutTime = nil
                }
                self.logToFile("[AI Helper LOG] \(self.remoteEngineName) restored — resuming paused task.")
                return .remoteRestored
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return .cancelled
    }

    func callOllama(
        prompt: String,
        model: String,
        images: [String]? = nil,
        timeout: TimeInterval = 300.0,
        forceLocal: Bool = false,
        overrideProvider: String? = nil,
        options: OllamaOptions? = nil,
        overrideThink: Bool? = nil
    ) async -> String? {
        let hasImages = images != nil && !(images?.isEmpty ?? true)
        let isWasBusy = self.isAIBusy
        
        let effectiveProvider: String
        if forceLocal || isLocalOnlyMode {
            effectiveProvider = "local"
        } else if let ov = overrideProvider, !ov.isEmpty {
            effectiveProvider = ov
        } else if hasImages {
            let preset = UserDefaults.standard.string(forKey: "ai_compute_preset") ?? "hybrid_twotier"
            if preset == "hybrid_twotier" {
                effectiveProvider = "local"
            } else {
                effectiveProvider = UserDefaults.standard.string(forKey: "vision_provider") ?? (UserDefaults.standard.string(forKey: "ai_provider") ?? "local")
            }
        } else {
            effectiveProvider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        }
        
        let taskDesc: String
        if effectiveProvider == "tailscale" {
            taskDesc = hasImages ? "Processing Tailscale Vision Request..." : "Processing Tailscale AI Request..."
        } else if effectiveProvider == "local" {
            taskDesc = hasImages ? "Processing Local Vision Request..." : "Processing Local AI Request..."
        } else {
            let pName = self.providerInfo(for: effectiveProvider, isVision: hasImages).name
            taskDesc = hasImages ? "Processing \(pName) Vision Request..." : "Processing \(pName) Request..."
        }
        
        if !isWasBusy {
            startAITask(
                description: taskDesc,
                isVision: hasImages,
                forceLocal: effectiveProvider == "local",
                provider: effectiveProvider
            )
        } else {
            updateActiveTaskProvider(
                provider: effectiveProvider,
                isVision: hasImages,
                forceLocal: effectiveProvider == "local"
            )
        }
        defer {
            if !isWasBusy {
                finishAITask(force: true)
            }
        }
        
        let targetModel: String
        let effectiveImages: [String]? = images
        
        if effectiveProvider == "tailscale" {
            let prefModel = hasImages ?
                (UserDefaults.standard.string(forKey: "vision_tailscale_model") ?? "") :
                (UserDefaults.standard.string(forKey: "tailscale_model_general") ?? "")
            let resolvedPref = !prefModel.isEmpty ? prefModel : (hasImages ? (await getOllamaVisionModel() ?? "") : (await getOllamaModel()))
            targetModel = model.isEmpty ? resolvedPref : model
            self.logToFile("[AI Helper LOG] \(hasImages ? "Vision" : "Text") request using Tailscale model (\(effectiveProvider)): \(targetModel)")
        } else if effectiveProvider == "local" {
            await ensureLocalOllamaRunning()
            let prefModel = hasImages ?
                (UserDefaults.standard.string(forKey: "local_model_vision") ?? "") :
                (UserDefaults.standard.string(forKey: "local_model_general") ?? "")
            let resolvedPref = !prefModel.isEmpty ? prefModel : (hasImages ? (await getOllamaVisionModel(forceLocal: true) ?? "") : (await getOllamaModel(forceLocal: true)))
            targetModel = model.isEmpty ? resolvedPref : model
            self.logToFile("[AI Helper LOG] \(hasImages ? "Vision" : "Text") request using local model: \(targetModel)")
        } else {
            let prefModel = hasImages ?
                (UserDefaults.standard.string(forKey: "vision_model_name") ?? "gpt-4o") :
                (UserDefaults.standard.string(forKey: "cloud_model_name") ?? "glm-5.2:cloud")
            targetModel = model.isEmpty ? prefModel : model
            self.logToFile("[AI Helper LOG] \(hasImages ? "Vision" : "Text") request using cloud model (\(effectiveProvider)): \(targetModel)")
        }
        
        // Pre-flight & execution loop for Tailscale (Wait for Connection vs Fallback to Local)
        if effectiveProvider == "tailscale" && !forceLocal {
            var glitchRetries = 0
            while !Task.isCancelled {
                let isReachableNow = (!self.autoReconnectExhausted && !self.isTailscaleInCooldown) ? await isTailscaleReachable() : false
                let tailscaleUnavailable = self.autoReconnectExhausted || self.isTailscaleInCooldown || !isReachableNow
                if tailscaleUnavailable {
                    if self.shouldFallbackToLocalWhenRemoteOffline {
                        if self.autoReconnectExhausted {
                            self.logToFile("[AI Helper LOG] Tailscale auto-reconnect exhausted (\(self.maxAutoReconnectAttempts) attempts). Bypassing remote call and falling back to Local Ollama until manual retry.")
                        } else if self.isTailscaleInCooldown {
                            self.logToFile("[AI Helper LOG] Tailscale in cooldown after recent timeout (\(self.tailscaleCooldownRemainingSeconds)s remaining). Bypassing remote call and falling back to Local Ollama immediately.")
                        } else {
                            self.logToFile("[AI Helper LOG] Fast pre-flight probe: Tailscale host unreachable. Triggering \(self.maxAutoReconnectAttempts)-attempt auto-reconnect and falling back to Local Ollama.")
                            if !self.isRunningReconnectLoop {
                                Task {
                                    _ = await self.attemptAutoReconnect(manualRetry: false)
                                }
                            }
                        }
                        if let fallbackResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                            return fallbackResult
                        }
                        break
                    } else {
                        self.logToFile("[AI Helper LOG] Tailscale unreachable — pausing task until connection is restored (or user selects local fallback).")
                        let resolution = await waitForRemoteOrLocalFallback(taskDescription: taskDesc)
                        switch resolution {
                        case .remoteRestored:
                            self.updateActiveTaskProvider(provider: "tailscale", isVision: hasImages, forceLocal: false, description: taskDesc)
                            continue
                        case .fallbackToLocal:
                            if let fallbackResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                                return fallbackResult
                            }
                            return nil
                        case .cancelled:
                            return nil
                        }
                    }
                }

                self.logToFile("[AI Helper LOG] callOllama (\(effectiveProvider)) attempt \(glitchRetries + 1) for model: \(targetModel)")
                let perAttemptTimeout = min(timeout, 90.0)
                if let result = await callAPIOnce(prompt: prompt, model: targetModel, images: effectiveImages, timeout: perAttemptTimeout, provider: effectiveProvider, options: options, overrideThink: overrideThink) {
                    if hasRepetitiveGlitch(result) {
                        glitchRetries += 1
                        self.logToFile("[AI Helper LOG] Repetitive glitch detected on tailscale (retry \(glitchRetries)/2): '\(result.prefix(100))...'")
                        if glitchRetries < 2 {
                            continue
                        }
                        if self.shouldFallbackToLocalWhenRemoteOffline {
                            if let localResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                                return localResult
                            }
                        }
                        return nil
                    }
                    self.lastTailscaleTimeoutTime = nil
                    await MainActor.run {
                        self.isRemoteOnline = true
                        self.remoteStatusMessage = "Connected"
                        if self.isAIDisconnected {
                            self.isAIDisconnected = false
                            self.disconnectionMessage = ""
                            self.autoReconnectAttempts = 0
                            self.autoReconnectExhausted = false
                        }
                    }
                    return result
                } else {
                    self.logToFile("[AI Helper LOG] callAPIOnce returned nil for tailscale")
                    self.lastTailscaleTimeoutTime = Date()
                    if self.shouldFallbackToLocalWhenRemoteOffline {
                        self.logToFile("[AI Helper LOG] Tailscale request failed or timed out. Triggering \(self.maxAutoReconnectAttempts)-attempt auto-reconnect and falling back to Local Ollama...")
                        if !self.autoReconnectExhausted && !self.isRunningReconnectLoop {
                            Task {
                                _ = await self.attemptAutoReconnect(manualRetry: false)
                            }
                        }
                        if let localResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                            return localResult
                        }
                        break
                    } else {
                        self.logToFile("[AI Helper LOG] Tailscale request failed or timed out — pausing task until connection is restored (or user selects local fallback).")
                        let resolution = await waitForRemoteOrLocalFallback(taskDescription: taskDesc)
                        switch resolution {
                        case .remoteRestored:
                            self.lastTailscaleTimeoutTime = nil
                            self.updateActiveTaskProvider(provider: "tailscale", isVision: hasImages, forceLocal: false, description: taskDesc)
                            continue
                        case .fallbackToLocal:
                            if let localResult = await fallbackToLocalOllama(prompt: prompt, images: effectiveImages, timeout: timeout, options: options, overrideThink: overrideThink) {
                                return localResult
                            }
                            return nil
                        case .cancelled:
                            return nil
                        }
                    }
                }
            }
            if Task.isCancelled {
                return nil
            }
        } else {
            let maxRetries = 3
            for attempt in 1...maxRetries {
                self.logToFile("[AI Helper LOG] callOllama (\(effectiveProvider)) attempt \(attempt)/\(maxRetries) for model: \(targetModel)")
                if let result = await callAPIOnce(prompt: prompt, model: targetModel, images: effectiveImages, timeout: timeout, provider: effectiveProvider, options: options, overrideThink: overrideThink) {
                    if hasRepetitiveGlitch(result) {
                        self.logToFile("[AI Helper LOG] Repetitive glitch detected (attempt \(attempt)/\(maxRetries)): '\(result.prefix(100))...'")
                        continue
                    }
                    await MainActor.run {
                        if effectiveProvider != "local" {
                            self.isRemoteOnline = true
                            self.remoteStatusMessage = "Connected"
                        }
                        if self.isAIDisconnected {
                            self.isAIDisconnected = false
                            self.disconnectionMessage = ""
                            self.autoReconnectAttempts = 0
                            self.autoReconnectExhausted = false
                        }
                    }
                    return result
                } else {
                    self.logToFile("[AI Helper LOG] callAPIOnce returned nil (attempt \(attempt)/\(maxRetries))")
                    if effectiveProvider != "local" {
                        self.logToFile("[AI Helper LOG] Cloud provider (\(effectiveProvider)) request failed or timed out; triggering \(self.maxAutoReconnectAttempts)-attempt auto-reconnect.")
                        if !self.autoReconnectExhausted && !self.isRunningReconnectLoop {
                            Task {
                                _ = await self.attemptAutoReconnect(manualRetry: false)
                            }
                        }
                        break
                    } else if attempt < maxRetries {
                        let online = await self.isOllamaRunning()
                        if !online {
                            self.logToFile("[AI Helper LOG] AI host unreachable on attempt \(attempt), stopping retries.")
                            break
                        }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
        
        await MainActor.run {
            self.isAIDisconnected = true
            if effectiveProvider == "tailscale" {
                self.disconnectionMessage = "Tailscale Disconnected"
            } else if effectiveProvider == "local" {
                self.disconnectionMessage = "Ollama Server Offline"
            } else {
                let name = self.providerInfo(for: effectiveProvider).name
                self.disconnectionMessage = "\(name) Disconnected"
            }
            self.isAIBusy = false
            self.isProcessing = false
            self.activeProcessingNoteIds.removeAll()
            self.finishAITask(force: true)
        }
        return nil
    }
    
    func callAPIOnce(prompt: String, model: String, images: [String]? = nil, timeout: TimeInterval, provider: String, options: OllamaOptions? = nil, overrideThink: Bool? = nil) async -> String? {
        if provider == "local" || provider == "tailscale" {
            let host: String
            if provider == "tailscale" {
                if images != nil {
                    let vHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let tHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    host = !vHost.isEmpty ? vHost : tHost
                } else {
                    host = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
                }
            } else {
                host = UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434"
            }
            guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "http://localhost:11434") else {
                self.logToFile("[AI Helper LOG] No valid host configured for \(provider).")
                return nil
            }
            let url = baseURL.appendingPathComponent("api/generate")
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            
            let isVision = (provider == "cloud_vision") || (images != nil && !(images?.isEmpty ?? true))
            let defaultThinking: Bool
            if provider == "local" {
                if isVision {
                    defaultThinking = UserDefaults.standard.bool(forKey: "local_vision_thinking_enabled")
                } else {
                    defaultThinking = UserDefaults.standard.object(forKey: "local_text_thinking_enabled") != nil
                        ? UserDefaults.standard.bool(forKey: "local_text_thinking_enabled")
                        : UserDefaults.standard.bool(forKey: "ai_text_thinking_enabled")
                }
            } else {
                if isVision {
                    defaultThinking = UserDefaults.standard.bool(forKey: "remote_vision_thinking_enabled")
                } else {
                    defaultThinking = UserDefaults.standard.object(forKey: "remote_text_thinking_enabled") != nil
                        ? UserDefaults.standard.bool(forKey: "remote_text_thinking_enabled")
                        : UserDefaults.standard.bool(forKey: "ai_text_thinking_enabled")
                }
            }
            let requestedThink = overrideThink ?? defaultThinking
            let thinkingEnabled = requestedThink && isModelThinkingCapable(model)
            
            self.logToFile("[AI Helper LOG] Calling \(provider) Ollama (\(model), \(isVision ? "vision" : "text"), think: \(thinkingEnabled), streaming: true)...")
            let body = GenerateRequest(model: model, prompt: prompt, stream: true, images: images, options: options, think: thinkingEnabled)
            do {
                request.httpBody = try JSONEncoder().encode(body)
                let (asyncBytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    self.logToFile("[AI Helper LOG] Non-HTTP response from \(provider) Ollama")
                    return nil
                }
                if httpResponse.statusCode != 200 {
                    self.logToFile("[AI Helper LOG] HTTP \(httpResponse.statusCode) from \(provider) Ollama (\(url.absoluteString))")
                    return nil
                }
                
                var accumulatedResponse = ""
                var chunkCount = 0
                var isDone = false
                
                for try await line in asyncBytes.lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedLine.isEmpty else { continue }
                    
                    guard let lineData = trimmedLine.data(using: .utf8),
                          let chunk = try? JSONDecoder().decode(GenerateResponse.self, from: lineData) else {
                        continue
                    }
                    
                    if let err = chunk.error, !err.isEmpty {
                        self.logToFile("[AI Helper LOG] \(provider) streaming chunk error: \(err)")
                        return nil
                    }
                    
                    if let resp = chunk.response {
                        accumulatedResponse += resp
                        chunkCount += 1
                    }
                    if let th = chunk.thinking, !th.isEmpty {
                        chunkCount += 1
                    }
                    
                    if chunkCount % 4 == 0 {
                        await MainActor.run {
                            self.batchTokensGenerated += 4
                            self.lastStreamingActivityDate = Date()
                        }
                    }
                    
                    if chunk.done == true {
                        isDone = true
                        break
                    }
                }
                
                await MainActor.run {
                    self.lastStreamingActivityDate = Date()
                }
                
                var cleanText = accumulatedResponse.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                cleanText = cleanText.replacingOccurrences(of: #"(?i)\[/?think\]"#, with: "", options: .regularExpression)
                let trimmed = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty && !isDone {
                    self.logToFile("[AI Helper LOG] \(provider) stream ended without completing.")
                    return nil
                }
                return trimmed
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with \(provider) Ollama (\(url.absoluteString)): \(error.localizedDescription)")
                return nil
            }
        } else {
            let isVisionTask = (provider == "cloud_vision") || (images != nil && !(images?.isEmpty ?? true))
            
            var baseUrl = ""
            var apiKey = ""
            
            if isVisionTask {
                let vBase = UserDefaults.standard.string(forKey: "vision_api_base_url")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let vKey = KeychainHelper.get(account: "vision_api_key").trimmingCharacters(in: .whitespacesAndNewlines)
                if !vBase.isEmpty {
                    baseUrl = vBase
                    apiKey = vKey
                }
            }
            
            if baseUrl.isEmpty {
                baseUrl = UserDefaults.standard.string(forKey: "cloud_api_base_url")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                apiKey = KeychainHelper.get(account: "cloud_api_key")
            }
            
            let cleanBase = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let isAnthropic = cleanBase.contains("anthropic.com") || provider == "anthropic" || model.lowercased().contains("claude")
            let isGemini = cleanBase.contains("generativelanguage.googleapis.com") || provider == "gemini" || model.lowercased().contains("gemini")
            
            let endpoint: String
            if isAnthropic {
                if cleanBase.isEmpty {
                    endpoint = "https://api.anthropic.com/v1/messages"
                } else if cleanBase.hasSuffix("/messages") {
                    endpoint = cleanBase
                } else if cleanBase.hasSuffix("/v1") {
                    endpoint = "\(cleanBase)/messages"
                } else {
                    endpoint = "\(cleanBase)/v1/messages"
                }
            } else if isGemini {
                if cleanBase.contains("/openai") {
                    if cleanBase.hasSuffix("/chat/completions") {
                        endpoint = cleanBase
                    } else {
                        endpoint = "\(cleanBase)/chat/completions"
                    }
                } else {
                    endpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
                }
            } else {
                if cleanBase.isEmpty {
                    endpoint = "https://api.openai.com/v1/chat/completions"
                } else if cleanBase.hasSuffix("/chat/completions") {
                    endpoint = cleanBase
                } else if cleanBase.hasSuffix("/v1") {
                    endpoint = "\(cleanBase)/chat/completions"
                } else {
                    endpoint = "\(cleanBase)/v1/chat/completions"
                }
            }
            
            guard let url = URL(string: endpoint) else {
                self.logToFile("[AI Helper LOG] Invalid API Base URL configured: '\(baseUrl)' (resolved endpoint: '\(endpoint)')")
                return nil
            }
            let publicCloudProviders: Set<String> = ["anthropic", "gemini", "openai", "groq", "cloud"]
            if publicCloudProviders.contains(provider) && url.scheme?.lowercased() != "https" {
                self.logToFile("[AI Helper LOG] Refusing non-HTTPS URL for cloud provider \(provider): \(endpoint)")
                return nil
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = timeout
            
            if isAnthropic {
                if !apiKey.isEmpty {
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                }
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                if !apiKey.isEmpty {
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                }
            }
            
            do {
                let maxOutTokens = options?.num_predict ?? 8192
                if isAnthropic {
                    var contentBlocks: [[String: Any]] = []
                    
                    if let images = images {
                        for imgBase64 in images {
                            var cleanBase64 = imgBase64
                            if let commaIdx = cleanBase64.firstIndex(of: ",") {
                                cleanBase64 = String(cleanBase64[cleanBase64.index(after: commaIdx)...])
                            }
                            cleanBase64 = cleanBase64.trimmingCharacters(in: .whitespacesAndNewlines)
                            let mediaType = cleanBase64.hasPrefix("/9j/") ? "image/jpeg" : "image/png"
                            contentBlocks.append([
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": cleanBase64
                                ]
                            ])
                        }
                    }
                    
                    contentBlocks.append([
                        "type": "text",
                        "text": prompt
                    ])
                    
                    let anthropicBody: [String: Any] = [
                        "model": model,
                        "max_tokens": maxOutTokens,
                        "messages": [
                            [
                                "role": "user",
                                "content": contentBlocks
                            ]
                        ]
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: anthropicBody, options: [])
                } else {
                    var messagesContent: [[String: Any]] = []
                    messagesContent.append([
                        "type": "text",
                        "text": prompt
                    ])
                    
                    if let images = images {
                        for imgBase64 in images {
                            var cleanBase64 = imgBase64
                            if let commaIdx = cleanBase64.firstIndex(of: ",") {
                                cleanBase64 = String(cleanBase64[cleanBase64.index(after: commaIdx)...])
                            }
                            cleanBase64 = cleanBase64.trimmingCharacters(in: .whitespacesAndNewlines)
                            let mediaType = cleanBase64.hasPrefix("/9j/") ? "image/jpeg" : "image/png"
                            messagesContent.append([
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:\(mediaType);base64,\(cleanBase64)"
                                ]
                            ])
                        }
                    }
                    
                    var bodyDict: [String: Any] = [
                        "model": model,
                        "max_tokens": maxOutTokens,
                        "messages": [
                            [
                                "role": "user",
                                "content": images != nil ? messagesContent as Any : prompt as Any
                            ]
                        ],
                        "stream": false
                    ]
                    if let temp = options?.temperature {
                        bodyDict["temperature"] = temp
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
                }
                
                let (data, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    let errBody = String(data: data, encoding: .utf8) ?? ""
                    self.logToFile("[AI Helper LOG] HTTP \(httpResponse.statusCode) from \(provider) (\(url.absoluteString)): \(errBody)")
                    return nil
                }
                
                if let responseJSON = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    if isAnthropic {
                        if let contentArray = responseJSON["content"] as? [[String: Any]] {
                            let textParts = contentArray.compactMap { block -> String? in
                                if (block["type"] as? String) == "text" {
                                    return block["text"] as? String
                                }
                                return nil
                            }
                            let combined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                            if !combined.isEmpty {
                                return combined
                            }
                        } else if let errorDict = responseJSON["error"] as? [String: Any],
                                   let msg = errorDict["message"] as? String {
                            self.logToFile("[AI Helper LOG] Anthropic error message: \(msg)")
                            return nil
                        }
                    } else {
                        if let choices = responseJSON["choices"] as? [[String: Any]],
                           let firstChoice = choices.first,
                           let message = firstChoice["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            return content.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let errorDict = responseJSON["error"] as? [String: Any],
                                  let msg = errorDict["message"] as? String {
                            self.logToFile("[AI Helper LOG] Cloud API error message: \(msg)")
                            return nil
                        }
                    }
                }
                
                let rawString = String(data: data, encoding: .utf8) ?? "Unable to decode string"
                self.logToFile("[AI Helper LOG] Unexpected \(provider) response structure: \(rawString)")
                return nil
            } catch {
                self.logToFile("[AI Helper LOG] Error communicating with \(provider) API (\(url)): \(error.localizedDescription)")
                return nil
            }
        }
    }
    
    func pullOllamaModel(modelName: String) async -> Bool {
        let provider = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let host = provider == "tailscale" ? (UserDefaults.standard.string(forKey: "tailscale_host") ?? "") : (UserDefaults.standard.string(forKey: "local_host") ?? "http://localhost:11434")
        guard !host.isEmpty, let bURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: provider == "tailscale" ? "" : "http://localhost:11434") else { return false }
        let url = bURL.appendingPathComponent("api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600.0
        
        let body = PullRequest(model: modelName, stream: false)
        do {
            let encoder = JSONEncoder()
            request.httpBody = try encoder.encode(body)
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("[AI Helper] Successfully pulled model \(modelName)")
                return true
            }
        } catch {
            print("[AI Helper] Error pulling model \(modelName): \(error)")
        }
        return false
    }
}
