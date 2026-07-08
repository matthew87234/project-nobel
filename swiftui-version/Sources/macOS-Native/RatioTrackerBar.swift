import SwiftUI

struct RatioTrackerBar: View {
    @State private var flashcardsSeconds: Int = 0
    @State private var problemsSeconds: Int = 0
    
    // Auto-refresh timer (runs every 5 seconds to match time logging)
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Flashcards: \(formatTime(flashcardsSeconds)) (\(roundedPercent(fcPercent))%)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Problems: \(formatTime(problemsSeconds)) (\(roundedPercent(100.0 - fcPercent))%)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track base
                    Capsule()
                        .fill(Color(NSColor.windowBackgroundColor))
                        .frame(height: 12)
                    
                    // Progress zones
                    HStack(spacing: 0) {
                        // 0 - 15% (Red warning)
                        Rectangle()
                            .fill(Color.red.opacity(0.7))
                            .frame(width: geo.size.width * 0.15, height: 12)
                        
                        // 15 - 25% (Green target zone)
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: geo.size.width * 0.10, height: 12)
                        
                        // 25 - 100% (Red warning)
                        Rectangle()
                            .fill(Color.red.opacity(0.7))
                            .frame(width: geo.size.width * 0.75, height: 12)
                    }
                    .clipShape(Capsule())
                    
                    // Slider Knob
                    let knobPos = min(max(CGFloat(fcPercent / 100.0) * geo.size.width, 0), geo.size.width)
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(radius: 2)
                        .offset(x: knobPos - 10, y: -4)
                }
            }
            .frame(height: 20)
            
            Text("Target Zone: 15% - 25% Flashcards (Optimal 80/20 Ratio)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
        .onAppear {
            refreshTime()
        }
        .onReceive(timer) { _ in
            refreshTime()
        }
    }
    
    func refreshTime() {
        let (fc, pb) = DatabaseManager.shared.getTodayStudyTime()
        self.flashcardsSeconds = fc
        self.problemsSeconds = pb
    }
    
    private var totalSeconds: Int {
        return flashcardsSeconds + problemsSeconds
    }
    
    private var fcPercent: Double {
        guard totalSeconds > 0 else { return 0.0 }
        return (Double(flashcardsSeconds) / Double(totalSeconds)) * 100.0
    }
    
    private func roundedPercent(_ value: Double) -> Int {
        return Int(round(value))
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        
        if h > 0 {
            return "\(h)h \(m)m \(s)s"
        } else if m > 0 {
            return "\(m)m \(s)s"
        } else {
            return "\(s)s"
        }
    }
}
