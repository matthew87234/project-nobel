import SwiftUI
import Combine

@MainActor
struct RatioTrackerBar: View {
    var isExamMode: Bool = false
    
    @State private var flashcardsSeconds: Int = 0
    @State private var problemsSeconds: Int = 0
    @State private var showInfoPopover: Bool = false
    
    // Auto-refresh timer (runs every 30 seconds to match time logging)
    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    
    var body: some View {
        HStack(spacing: 10) {
            // Minimalist Segmented Dual Progress Bar Track
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track Base
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 10)
                    
                    // Dual Segment Progress Bar
                    HStack(spacing: 2) {
                        if fcPercent > 0 {
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(0, (geo.size.width * CGFloat(fcPercent / 100.0)) - 1), height: 10)
                        }
                        
                        if pbPercent > 0 {
                            Capsule()
                                .fill(LinearGradient(colors: [.teal, .green], startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(0, (geo.size.width * CGFloat(pbPercent / 100.0)) - 1), height: 10)
                        }
                    }
                    .clipShape(Capsule())
                    
                    // Target Zone Band Overlay
                    // Normal Mode: Target 70% - 85% Flashcards (zoneStart: 70%, width: 15%, 80% guide line)
                    // Exam Mode: Target 70% - 85% Problems -> 15% - 30% Flashcards (zoneStart: 15%, width: 15%, 80% problem guide line)
                    let zoneStart = isExamMode ? (geo.size.width * 0.15) : (geo.size.width * 0.70)
                    let zoneWidth = geo.size.width * 0.15
                    let midOffsetInBand = ((isExamMode ? (1.0 / 3.0) : (2.0 / 3.0)) * zoneWidth) - (zoneWidth / 2.0)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.opacity(0.25))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.green.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            )
                        
                        // Subtle 80% reference guide line
                        Rectangle()
                            .fill(Color.green.opacity(0.85))
                            .frame(width: 1.5, height: 14)
                            .offset(x: midOffsetInBand)
                    }
                    .frame(width: max(0, zoneWidth), height: 16)
                    .offset(x: zoneStart, y: -3)
                }
            }
            .frame(height: 14)
            
            // Info Button with Popover Explanation
            Button(action: {
                showInfoPopover.toggle()
            }) {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .popover(isPresented: $showInfoPopover, arrowEdge: .trailing) {
                infoPopoverContent
            }
        }
        .onAppear {
            refreshTime()
        }
        .onReceive(timer) { _ in
            refreshTime()
        }
    }
    
    private var infoPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isExamMode ? "80/20 Exam Study Ratio" : "80/20 Study Balance Ratio")
                    .font(.headline)
                Spacer()
                statusBadge
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.teal)
                        .frame(width: 8, height: 8)
                    Text("Problems Time:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(formatTime(problemsSeconds)) (\(roundedPercent(pbPercent))%)")
                        .bold()
                        .foregroundColor(.teal)
                }
                .font(.subheadline)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Flashcards Time:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(formatTime(flashcardsSeconds)) (\(roundedPercent(fcPercent))%)")
                        .bold()
                        .foregroundColor(.blue)
                }
                .font(.subheadline)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(.green)
                    Text(isExamMode ? "Target Zone: 70% – 85% Problems" : "Target Zone: 70% – 85% Flashcards")
                        .font(.caption)
                        .bold()
                }
                
                Text(isExamMode ?
                    "In Exam Mode, your priority flips to active problem solving (80% Problems) paired with high-yield formula review (20% Flashcards). Land inside the green band for optimal preparation!" :
                    "The shaded green band represents your optimal balance range (80% Flashcards, 20% Problems). As long as your study ratio lands inside this zone, your learning pace is on track!"
                )
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        if totalSeconds == 0 {
            Text("No Logs Today")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundColor(.secondary)
                .cornerRadius(4)
        } else if isExamMode {
            // Target: 70% - 85% Problems
            if pbPercent >= 70.0 && pbPercent <= 85.0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                    Text("Optimal Exam Balance")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundColor(.green)
                .cornerRadius(4)
            } else if pbPercent < 70.0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Focus Problems (Aim 80%)")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .cornerRadius(4)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.caption2)
                    Text("Review Flashcards (Aim 20%)")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.15))
                .foregroundColor(.blue)
                .cornerRadius(4)
            }
        } else {
            // Target: 70% - 85% Flashcards
            if fcPercent >= 70.0 && fcPercent <= 85.0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2)
                    Text("Optimal Balance")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundColor(.green)
                .cornerRadius(4)
            } else if fcPercent > 85.0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Focus Problems")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .foregroundColor(.orange)
                .cornerRadius(4)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.caption2)
                    Text("Focus Flashcards")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.15))
                .foregroundColor(.blue)
                .cornerRadius(4)
            }
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
        guard totalSeconds > 0 else { return isExamMode ? 20.0 : 80.0 }
        return (Double(flashcardsSeconds) / Double(totalSeconds)) * 100.0
    }
    
    private var pbPercent: Double {
        return 100.0 - fcPercent
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

