import Foundation

extension AIHelper {
    // MARK: - Tailscale & Network Discovery
    
    func scanTailscaleNetwork() async -> [DiscoveredAIHost] {
        await MainActor.run {
            self.isScanningTailscale = true
        }
        defer {
            Task { @MainActor in
                self.isScanningTailscale = false
            }
        }
        
        var candidateTargets: [(name: String, ipOrHost: String, port: Int)] = []
        
        // 1. Current configured host
        let currentTailHost = UserDefaults.standard.string(forKey: "tailscale_host") ?? ""
        if !currentTailHost.isEmpty, let url = URL(string: currentTailHost), let host = url.host {
            candidateTargets.append((name: "Current Host", ipOrHost: host, port: url.port ?? 11434))
        }
        
        // 2. Discover peers from Tailscale CLI / status
        let cliPeers = await discoverTailscalePeersFromCLI()
        for peer in cliPeers {
            if !candidateTargets.contains(where: { $0.ipOrHost == peer.ip }) {
                candidateTargets.append((name: peer.name, ipOrHost: peer.ip, port: 11434))
            }
        }
        
        // 3. Local machine option
        if !candidateTargets.contains(where: { $0.ipOrHost == "127.0.0.1" || $0.ipOrHost == "localhost" }) {
            candidateTargets.append((name: "Local Machine", ipOrHost: "127.0.0.1", port: 11434))
        }
        
        // 4. Concurrently probe each candidate
        var discovered: [DiscoveredAIHost] = []
        await withTaskGroup(of: DiscoveredAIHost?.self) { group in
            for target in candidateTargets {
                group.addTask {
                    await self.probeHost(name: target.name, ipOrHost: target.ipOrHost, port: target.port)
                }
            }
            
            for await result in group {
                if let host = result {
                    discovered.append(host)
                }
            }
        }
        
        let sorted = discovered.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            return a.responseTimeMs < b.responseTimeMs
        }
        
        await MainActor.run {
            self.discoveredHosts = sorted
        }
        
        return sorted
    }
    
    func probeHost(name: String, ipOrHost: String, port: Int = 11434) async -> DiscoveredAIHost? {
        let scheme = ipOrHost.hasPrefix("http://") || ipOrHost.hasPrefix("https://") ? "" : "http://"
        let hostURLString = "\(scheme)\(ipOrHost):\(port)"
        guard let baseURL = URL(string: hostURLString) else { return nil }
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 2.0
        
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let tags = try? JSONDecoder().decode(TagsResponse.self, from: data) else { return nil }
            
            let allModels = tags.models.map { $0.name }
            let visionKeywords = ["vl", "vision", "llava", "minicpm", "moondream", "gemma3", "pixtral"]
            let visionModels = allModels.filter { name in
                let lower = name.lowercased()
                return visionKeywords.contains { lower.contains($0) }
            }
            let generalModels = allModels.filter { name in
                let lower = name.lowercased()
                return !visionKeywords.contains { lower.contains($0) }
            }
            
            let displayName = (name.isEmpty || name == "Current Host") ? ipOrHost : name
            return DiscoveredAIHost(
                name: displayName,
                ip: ipOrHost,
                port: port,
                hostURL: hostURLString,
                models: allModels,
                generalModels: generalModels,
                visionModels: visionModels,
                isOnline: true,
                responseTimeMs: duration
            )
        } catch {
            return nil
        }
    }
    
    nonisolated func discoverTailscalePeersFromCLI() async -> [(name: String, ip: String)] {
        // Never launch Tailscale.app automatically. Only query the CLI if Tailscale daemon is already running.
        let checkProc = Process()
        checkProc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        checkProc.arguments = ["-i", "tailscale"]
        checkProc.standardOutput = Pipe()
        checkProc.standardError = Pipe()
        do {
            try checkProc.run()
            checkProc.waitUntilExit()
            if checkProc.terminationStatus != 0 {
                return []
            }
        } catch {
            return []
        }
        
        // Do NOT include /Applications/Tailscale.app/Contents/MacOS/Tailscale (uppercase), which launches the GUI app.
        let possiblePaths = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/bin/tailscale"
        ]
        
        var peers: [(name: String, ip: String)] = []
        
        for path in possiblePaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            
            do {
                try process.run()
                let deadline = Date().addingTimeInterval(1.5)
                while process.isRunning && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    process.terminate()
                    break
                }
                let data = try? pipe.fileHandleForReading.readToEnd()
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let selfObj = json["Self"] as? [String: Any],
                       let hostName = selfObj["HostName"] as? String,
                       let ips = selfObj["TailscaleIPs"] as? [String],
                       let v4 = ips.first(where: { $0.contains(".") }) {
                        peers.append((name: "\(hostName) (This Device)", ip: v4))
                    }
                    
                    if let peerDict = json["Peer"] as? [String: [String: Any]] {
                        for (_, info) in peerDict {
                            let hostName = (info["HostName"] as? String) ?? "Tailscale Peer"
                            if let ips = info["TailscaleIPs"] as? [String],
                               let v4 = ips.first(where: { $0.contains(".") }) {
                                peers.append((name: hostName, ip: v4))
                            }
                        }
                    }
                }
                // Stop after the first valid CLI binary even if peers is empty
                break
            } catch {
                break
            }
        }
        
        return peers
    }

    // MARK: - Remote/Cloud Auto-Reconnect (Max 3 Retries, Never Auto-Launches Tailscale)
    
    func probeRemoteTargetOnce() async -> Bool {
        if isLocalOnlyMode {
            return await isOllamaRunning()
        }
        let remoteProv = UserDefaults.standard.string(forKey: "remote_provider") ?? "tailscale"
        let aiProv = UserDefaults.standard.string(forKey: "ai_provider") ?? "local"
        let targetProv = (aiProv == "local") ? remoteProv : aiProv
        
        if targetProv == "tailscale" || targetProv == "local" {
            // Direct HTTP probe to configured Tailscale/remote host ONLY — never launches Tailscale
            var currentTailHost = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if currentTailHost.isEmpty {
                currentTailHost = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            guard !currentTailHost.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: currentTailHost, defaultHost: "") else {
                return false
            }
            let tagsUrl = baseURL.appendingPathComponent("api/tags")
            var req = URLRequest(url: tagsUrl)
            req.timeoutInterval = 3.0
            do {
                let (data, resp) = try await probeSession.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    self.logToFile("[AI Helper LOG] Probe received non-HTTP response for \(tagsUrl.absoluteString)")
                    return false
                }
                guard http.statusCode == 200 else {
                    self.logToFile("[AI Helper LOG] Probe returned HTTP \(http.statusCode) for \(tagsUrl.absoluteString)")
                    return false
                }
                let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
                if tags.models.isEmpty {
                    self.logToFile("[AI Helper LOG] Probe succeeded for \(tagsUrl.absoluteString) but no models are installed")
                    return false
                }
                return true
            } catch {
                self.logToFile("[AI Helper LOG] Probe failed for \(tagsUrl.absoluteString): \(error.localizedDescription)")
                return false
            }
        } else {
            // Cloud provider check
            let cloudKey = KeychainHelper.get(account: "cloud_api_key").trimmingCharacters(in: .whitespacesAndNewlines)
            if ["anthropic", "gemini", "openai", "groq"].contains(targetProv) {
                return !cloudKey.isEmpty
            }
            return await isOllamaRunning()
        }
    }
    
    @discardableResult
    func attemptAutoReconnect(manualRetry: Bool = false) async -> Bool {
        if isLocalOnlyMode {
            let running = await isOllamaRunning()
            if !running {
                await ensureLocalOllamaRunning()
            }
            let nowRunning = await isOllamaRunning()
            await MainActor.run {
                self.isAIDisconnected = !nowRunning
                self.disconnectionMessage = nowRunning ? "" : "Local Ollama Offline"
                self.isAutoReconnecting = false
                self.autoReconnectAttempts = 0
                self.autoReconnectExhausted = !nowRunning
            }
            return nowRunning
        }
        
        if !manualRetry && self.autoReconnectExhausted {
            return false
        }
        guard !self.isRunningReconnectLoop else { return false }
        
        self.isRunningReconnectLoop = true
        if manualRetry {
            self.autoReconnectExhausted = false
            self.autoReconnectAttempts = 0
        }
        defer {
            self.isRunningReconnectLoop = false
            self.isAutoReconnecting = false
        }
        
        for attempt in 1...self.maxAutoReconnectAttempts {
            if self.isLocalOnlyMode {
                await MainActor.run {
                    self.isAIDisconnected = false
                    self.disconnectionMessage = ""
                    self.isAutoReconnecting = false
                    self.autoReconnectAttempts = 0
                    self.autoReconnectExhausted = false
                }
                return true
            }
            
            await MainActor.run {
                self.isAIDisconnected = true
                self.isRemoteOnline = false
                self.remoteStatusMessage = "Reconnecting (\(attempt)/\(self.maxAutoReconnectAttempts))"
                self.isAutoReconnecting = true
                self.autoReconnectAttempts = attempt
                self.disconnectionMessage = "\(self.remoteEngineName) Disconnected"
            }
            self.logToFile("[AI Helper LOG] Reconnect attempt \(attempt)/\(self.maxAutoReconnectAttempts) to \(self.remoteEngineName)...")
            
            let connected = await self.probeRemoteTargetOnce()
            if connected {
                await MainActor.run {
                    self.isAIDisconnected = false
                    self.isRemoteOnline = true
                    self.remoteStatusMessage = "Connected"
                    self.disconnectionMessage = ""
                    self.isAutoReconnecting = false
                    self.autoReconnectAttempts = 0
                    self.autoReconnectExhausted = false
                    self.lastTailscaleTimeoutTime = nil
                }
                self.logToFile("[AI Helper LOG] Reconnected to \(self.remoteEngineName) on attempt \(attempt)/\(self.maxAutoReconnectAttempts).")
                return true
            }
            
            if attempt < self.maxAutoReconnectAttempts {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
        
        // All 3 retries exhausted — stop automatic reconnection until user manually presses Retry
        await MainActor.run {
            self.isAIDisconnected = true
            self.isRemoteOnline = false
            self.remoteStatusMessage = "Not Connected"
            self.isAutoReconnecting = false
            self.autoReconnectExhausted = true
            self.disconnectionMessage = "\(self.remoteEngineName) Disconnected"
        }
        self.logToFile("[AI Helper LOG] \(self.remoteEngineName) unreachable after \(self.maxAutoReconnectAttempts) attempts. Automatic retries stopped until manual retry.")
        return false
    }
    
    func startAutoReconnectMonitor() {
        Task {
            print("[AI Helper] Remote/Cloud connection monitor running (max \(self.maxAutoReconnectAttempts) retries on drop).")
            while true {
                do {
                    if self.isLocalOnlyMode {
                        if self.isAIDisconnected && !self.disconnectionMessage.contains("Local") {
                            self.isAIDisconnected = false
                            self.disconnectionMessage = ""
                            self.autoReconnectAttempts = 0
                            self.autoReconnectExhausted = false
                        }
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                    
                    // If 3 retries have already failed, stop trying automatically until the user presses Retry
                    if self.autoReconnectExhausted || self.isRunningReconnectLoop || self.isRetryingConnection {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    
                    let online = await self.probeRemoteTargetOnce()
                    if online {
                        self.isRemoteOnline = true
                        self.remoteStatusMessage = "Connected"
                        if self.isAIDisconnected {
                            self.isAIDisconnected = false
                            self.disconnectionMessage = ""
                            self.autoReconnectAttempts = 0
                            self.autoReconnectExhausted = false
                        }
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    } else {
                        self.isRemoteOnline = false
                        self.remoteStatusMessage = "Not Connected"
                        self.isAIDisconnected = true
                        self.disconnectionMessage = "\(self.remoteEngineName) Disconnected"
                        self.logToFile("[AI Helper LOG] Connection monitor detected \(self.remoteEngineName) offline. Starting \(self.maxAutoReconnectAttempts)-attempt auto-reconnect...")
                        _ = await self.attemptAutoReconnect(manualRetry: false)
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
    }
    
    func probeTailscaleHost() async -> Bool {
        var host = UserDefaults.standard.string(forKey: "tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty {
            host = UserDefaults.standard.string(forKey: "vision_tailscale_host")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !host.isEmpty, let baseURL = AIHelper.normalizedOllamaURL(from: host, defaultHost: "") else {
            return false
        }
        let url = baseURL.appendingPathComponent("api/version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        do {
            let (_, response) = try await probeSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            return false
        } catch {
            return false
        }
    }
    
    func startEngineStatusMonitor() {
        // Consolidated into startAutoReconnectMonitor so we never poll after 3 failed retries.
    }
}
