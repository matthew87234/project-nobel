# Project Nobel - Physics Study App

Project Nobel is an advanced physics study workstation built natively for macOS (SwiftUI) with a companion Flutter desktop architecture. Designed specifically for university physics students, it combines cognitive science learning workflows (SuperMemo-2 Spaced Repetition, Interleaving Practice, Feynman Dialogue, and 3-Phase Pre-Exam Priming) with local/cloud AI assistance and offline SQLite persistence.

---

## Download & Installation (macOS)

Download the latest pre-compiled disk image from the GitHub Releases page:

**[Download Project Nobel (.dmg)](https://github.com/matthew87234/project-nobel/releases/latest)**

1. Download `Project-Nobel-Installer.dmg`.
2. Open the downloaded `.dmg` file.
3. Drag **Project Nobel** into your **Applications** folder.
4. Launch Project Nobel from Applications or Spotlight.

> **Note on Data Persistence:** All your flashcards, problem solving statistics, lecture notes, and Feynman chat sessions are stored securely in `~/.physics_study_app/physics_study.db`. Upgrading or reinstalling the app via `.dmg` will never overwrite or erase your study data.

---

## Core Capabilities

### 1. Spaced Repetition (SuperMemo SM-2)
- **True SM-2 Scheduling**: Exponential interval growth, dynamic ease factor calibration, and repetition counters.
- **Academic Year Scoping & Exam Mode**: Practice cards across all modules in your selected academic year, or focus strictly on an individual module in Exam Mode.
- **Strict Due-Date Filtering**: Only serves cards due today, with a dedicated Study Ahead mode for extra practice.
- **Bi-directional Anki Sync**: Seamlessly synchronize flashcards with your local Anki collection via AnkiConnect.

### 2. Problem Interleaving Engine
- **Cognitive Diagnostic Feedback**: Tracks failure tiers (Setup errors, Equation formulation slips, Calculation slips, or Flawless mastery) and schedules next review dates adaptively using SM-2.
- **Step-by-Step Progressive Reveal**: Step through solutions one milestone at a time before viewing the complete mathematical derivation.
- **Batch AI Importer**: Drag and drop past exam PDFs or homework problem sheets to automatically extract questions, hints, and step-by-step solutions via OCR and local/cloud LLMs.

### 3. 3-Phase Pre-Exam Routine
- **Phase 1: Formula Priming**: Rapid-fire flashcard review of core equations and boundary conditions.
- **Phase 2: Rapid Diagramming**: Timed speed-sketching drill to practice drawing physical systems, free-body diagrams, and potential wells under exam conditions.
- **Phase 3: Self-Correction**: Compare sketches with reference diagrams, mark points for review, and record reflection notes.

### 4. Feynman Technique AI Tutor
- **Conversational Concept Scaffolding**: Explain physics principles in your own words to an AI student tutor who asks probing questions and identifies logical gaps in your derivations.
- **Local & Private AI**: Fully compatible with local Ollama models (`qwen2.5-coder`, `qwen2.5vl`, `llama3`) or cloud endpoints.

### 5. 53-Week Analytics & Learning Ratio Tracker
- **Activity Heatmap**: GitHub-style 53-week study frequency matrix tracking daily flashcards and problems solved.
- **Study Ratio Tracker**: Real-time visual balance bar ensuring an optimal balance between active problem solving and conceptual recall.

---

## Building from Source

### macOS Native (SwiftUI)

**Prerequisites:**
- macOS 14.0 or higher
- Xcode 15+ or Command Line Tools (`xcode-select --install`)
- Swift 5.9+

```bash
# Clone the repository
git clone https://github.com/matthew87234/project-nobel.git
cd project-nobel

# Build the release binary and create a standalone .dmg installer
chmod +x create_dmg.sh
./create_dmg.sh
```

The resulting disk image will be placed in the project root: `Project-Nobel-Installer.dmg`.

To build directly to your Desktop for development:
```bash
./swiftui-version/build_app.sh
```

---

### Cross-Platform Desktop (Flutter)

**Prerequisites:**
- Flutter SDK 3.x+
- Dart SDK

```bash
cd project-nobel/flutter-version
flutter pub get

# Run on macOS
flutter run -d macos

# Run on Windows
flutter run -d windows
```

---

## Project Structure

```
project-nobel/
├── swiftui-version/             # Primary native macOS application
│   ├── Sources/macOS-Native/   # SwiftUI views, managers, AI helper, SM-2 engine
│   ├── Resources/              # Application icons and asset catalogs
│   └── Package.swift           # Swift Package Manager configuration
├── flutter-version/             # Cross-platform desktop companion
├── create_dmg.sh                # Local macOS DMG packaging pipeline
└── .github/workflows/
    └── release.yml              # Automated GitHub Actions release pipeline
```

---

## License

This project is licensed under the MIT License - see the LICENSE file for details.
