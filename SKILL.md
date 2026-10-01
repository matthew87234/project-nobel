---
name: physics-study-app
description: Master technical architecture, learning pedagogy, database schemas, feature specifications, and build/deploy workflows for Project Nobel (Physics Study App).
---

# Project Nobel (Physics Study App) — Comprehensive AI Engineering & Pedagogy Guide

## 1. Project Overview & Vision
**Project Nobel** is a native macOS physics study & interleaving application built with SwiftUI, SQLite3, local and Tailscale remote AI models (Ollama Qwen2.5-Coder / Qwen2.5-VL / DeepSeek), and Anki bidirectional synchronization.

The application is engineered around cognitive science principles for STEM learning:
- **Interleaving**: Mixing different physics topics/modules during study to improve neural discrimination.
- **Spaced Repetition (SM-2)**: Algorithmically scheduling flashcards and physics problems based on difficulty and retention intervals.
- **Step-Level Diagnostic Error Tracking**: Tracking *where* in a physics solution a student made an error (Step 1 Setup vs Step 2 Formulation vs Step 3+ Slips) to dynamically adapt review intervals.
- **Pre-Exam Warmup Routine**: A 2-hour pre-exam warmup timeline designed to prime working memory without inducing cognitive fatigue.
- **Formula-First Summaries & Pre-Lecture Primers**: High-density, minimal LaTeX summaries connecting previous lectures into upcoming topics.

---

## 2. Technical Stack & Dual-Environment Architecture

### A. Core Stack
- **Language & Framework**: Swift 5.10+, SwiftUI, Swift Charts, macOS Native SPM target.
- **Workspace Location**: `/Users/matthewt/Projects/PhysicsStudyApp/swiftui-version`
- **Compiler Compatibility**: Must compile with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk` or `swift-tools-version: 5.9`.

### B. Dual Database & Execution Environments
1. **Production App (`/Applications/Project Nobel.app`)**:
   - Official release environment.
   - Clean UI with zero test/sandbox indicators.
   - Primary Database: `~/.physics_study_app/physics_study.db`.
2. **Desktop Sandbox App (`/Users/matthewt/Desktop/Project Nobel.app`)**:
   - Active development & testing sandbox.
   - Displays amber top banner: `● TEST PROGRAM • Desktop Sandbox Environment`.
   - Sandbox Database: `~/.physics_study_app/physics_study_desktop.db`.
   - **One-Way Sync**: Running `./swiftui-version/build_app.sh` automatically copies `physics_study.db` $\to$ `physics_study_desktop.db` without altering production data.

---

## 3. Core Source Files (`swiftui-version/Sources/macOS-Native/`)

- `App.swift`: Main app lifecycle, navigation split view, top test banner, host migrations, background processor trigger.
- `AIDevicePickerView.swift`: Interactive Tailscale node discovery, live latency probing, installed model selection modal.
- `AIHelper.swift`: Background AI processing engine, Tailscale dynamic network discovery, thinking tag cleanup, multi-pass queue manager.
- `AnkiSyncEngine.swift`: Bidirectional sync engine connecting flashcards to Anki Desktop API.
- `DashboardView.swift`: Main dashboard, 53-week study activity heatmap, donut study distribution chart, metric cards.
- `DatabaseManager.swift`: Database connection, schema migrations, models (`Module`, `Topic`, `Note`, `Flashcard`, `Problem`), CRUD queries.
- `FeynmanManagerView.swift`: AI Feynman Technique interactive tutor.
- `FlashcardsView.swift`: Spaced repetition flashcard centre, SM-2 engine, interactive chart popups (`MetricCardView`), flag queue (`is_flagged`).
- `LaTeXView.swift`: Native WebKit / MathJax rendering engine for crisp mathematical equations.
- `ModuleManagerView.swift`: Manage Modules modal (CRUD, semester, year, Exam Date & Time inputting).
- `ModulesView.swift`: Module syllabus, lecture note viewer, OCR batch importer, PDF note manager.
- `PostLectureView.swift`: Post-lecture formula summaries and key equations.
- `PreExamRoutineView.swift`: 3-phase 2-hour pre-exam warmup timeline (Definition priming, Setup strategy, Cheat sheet & mental reset).
- `PreLectureView.swift`: Pre-lecture primers connecting preceding topics into upcoming lectures.
- `ProblemsView.swift`: Physics problem practice centre, interactive diagnostic error charts, step error marking (`StepRowPracticeView`), flag queue (`is_flagged`), step-severity tracking (`last_failed_step`, `severity_level`).
- `RatioTrackerBar.swift`: Visual study time balance indicator showing Flashcards vs Problems study ratio.
- `SettingsView.swift`: Settings modal, AI provider configuration, Tailscale scan trigger, database maintenance.
- `StudyView.swift`: Interleaved study guide and active practice session manager.
- `ViewExtensions.swift`: Shared styling helpers, visual modifiers, and color extensions.

---

## 4. AI Engine & Tailscale Architecture (`AIHelper.swift`)

### A. Dynamic Tailscale Network Discovery (Zero Hardcoded IPs)
- **Automatic Peer Discovery**: Queries Tailscale status/CLI (`tailscale status --json`) across standard binary locations (`/usr/local/bin/tailscale`, `/opt/homebrew/bin/tailscale`, `/Applications/Tailscale.app/Contents/MacOS/Tailscale`) to discover online Tailscale peers (`100.x.y.z`) and hostnames dynamically without hardcoding IP addresses.
- **Concurrent Node Probing**: Probes candidate peers concurrently on port 11434 (`/api/tags`) with a 2-second timeout to detect active Ollama instances, measure response latency, and fetch live installed models.
- **Device Selection Modal (`AIDevicePickerView.swift`)**:
  - Automatically prompts the user on first launch (or when selecting Tailscale without a configured host) with an interactive discovery sheet.
  - Lists all reachable Ollama compute nodes with live latency, online status badges, and installed model pills.
  - Allows selecting preferred General Models and Vision Models directly from the node's live model tags, plus manual host entry and connection probing.
  - Stored dynamically in `@AppStorage("tailscale_host")` and model preferences.

### B. Multi-Pass Background Queue Pipeline
Background jobs run sequentially with wake-lock assertions (`idleSystemSleepDisabled`):
1. **Pass 1 (Missing Summaries)**: Prioritizes unanalyzed notes across all modules first (`processNoteSync`). Extracts text, auto-generates formula-first summaries, descriptive titles, and pre-lecture primers.
2. **Pass 2 (Generic Titles)**: Renames default titles (`isDefaultTitle`) using `generateDescriptiveTitle` with regex stripping for `<think>.*?</think>` tags.
3. **Pass 3 (Missing Primers)**: Synthesizes `generatePreLecturePrimer` linking preceding lectures into upcoming lectures.

### C. Power-Saver Interlock
- Power-saving mode automatically disengages whenever pending jobs exist in the queue.
- Only powers down local Ollama when the queue is 100% idle and provider is local (`idleTime > 300s`). Remote Tailscale jobs run uninterrupted.

---

## 5. Core Features & UI Standards

### A. Top-Left Exam Date Badge (`App.swift`)
- **Location**: Top-left toolbar item (`ToolbarItem(placement: .navigation)`), positioned directly above the **Dashboard** detail header text.
- **Format**: Clean toolbar item with secondary calendar icon + 3-letter month date string (e.g. `1 Sep 2026`).
- **Hover Tooltip**: Displays the countdown (`Exam Date for [Code]: X days remaining (1 Sep 2026)`).
- **Inputting**: Managed in the **Manage Modules** window (`ModuleManagerView.swift`) via `Toggle("Set Exam Date & Time")` and `DatePicker`.

### B. Problems Centre & Step-Level Diagnostic Error Marking (`ProblemsView.swift`)
- **Step-Error Button**: Warning triangle button (`Image(systemName: isErrorStep ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")`) in `StepRowPracticeView`.
- **Severity Levels (`DatabaseManager.swift`)**:
  - **Level 1 (Critical)**: Error in Step 1 (Conceptual Setup / Free-Body Diagram). Review due in 1 day.
  - **Level 2 (High)**: Error in Step 2 (Equation Formulation / Vector Setup). Review due in 2 days.
  - **Level 3 (Medium)**: Error in Step 3+ (Algebraic / Arithmetic Slips). Review due in 4 days.
  - **Level 4 (Flawless)**: 0 Errors (Clean Solve). Review due in 7 days.
- **Interactive Metric Cards**: `MetricCardView` components triggering modal Swift Charts (`ProblemDueProjectionChartView`, `ProblemSeverityChartView`, `ProblemTopicChartView`, `ProblemFlaggedChartView`).

### C. Flashcards Centre & Anki Sync (`FlashcardsView.swift`)
- **SM-2 Spaced Repetition**: Updates `next_review_date`, `interval`, `ease_factor`, `repetitions`.
- **Flag Queue (`is_flagged`)**: Dedicated **strictly for marking cards that need correction, verification, or editing** (e.g. typos, LaTeX fixes). Flag status does NOT indicate topic importance or exam priority.
- **Preset Counts**: Selector for practice queue size (5, 10, 15, Custom).

---

## 6. Pre-Exam Warmup Routine Strategy (Cognitive Science across STEM / Math)

The final 2 hours before any technical or mathematical exam follow a 3-phase warmup pipeline designed to prime working memory without mental burnout:

```
T-120 mins                    T-80 mins                   T-40 mins             T-0 (Exam Start)
    │                             │                           │                       │
    ├────────── PHASE 1 ──────────┼───────── PHASE 2 ─────────┼─────── PHASE 3 ───────┤
    │  Definition & Theorem       │   High-Yield Setup/Proof  │    Core Identity      │
    │         Priming             │         Strategy          │   Dump & Mental Reset │
```

1. **Phase 1: Definition & Theorem Priming (T-120m to T-80m)**: Rapid 25-card review of core definitions, canonical formulas/identities, applicability conditions, and notation conventions.
   - **Prioritization Algorithm**: Cards are selected using SM-2 retention metrics and AI semantic classification (`ORDER BY ease_factor ASC, interval ASC LIMIT 25`).
   - **Strict Exclusion Rules**: Flagged cards (`is_flagged == false`), trivial cards (<8 chars), and multi-step derivations are excluded.
2. **Phase 2: High-Yield Setup & Proof Strategy Warmup (T-80m to T-40m)**: Reviewing **Step 1 & Step 2** (Problem Classification, Initial Substitution, Free-Body Diagram, or Proof Outline) of previously solved problems—skipping tedious calculations.
   - **Sampling Algorithm**: Queries `getTopics(forModuleId:)` and evenly samples 1–2 high-severity, non-flagged problems per lecture/week (8–12 problems total).
   - **Pin to Phase 3**: Allows pinning tricky formulas and setups directly to the Phase 3 cheat sheet.
3. **Phase 3: Prepared Notes, Pinned Problems & Mental Reset (T-40m to T-0m)**:
   - **Sub-Tab 1: Prepared Notes Editor & 1-Page Cheat Sheet**: Pre-exam notes editor supporting LaTeX math, Markdown, snippet buttons, and live preview.
   - **Sub-Tab 2: Pinned Problems**: Dedicated review of problems pinned during Phase 2.
   - **Sub-Tab 3: Mental Reset**: 15-minute countdown timer, animated 4-4-4-4 box breathing pacer (Inhale 4s $\to$ Hold 4s $\to$ Exhale 4s $\to$ Hold 4s), and pre-flight exam checklist.

---

## 7. Build, Packaging & Deployment Commands

Always run build commands from the repository root:

```bash
# 1. Build Desktop Testing App (Sandbox DB with test banner)
./swiftui-version/build_app.sh

# 2. Build Release Binary & Professional DMG Installer (Clean Production)
./create_dmg.sh

# 3. Deploy to Applications (Optional manual deployment)
./deploy_to_applications.sh
```

### DMG Packaging Workflow Details (`create_dmg.sh` & `dmgbuild_settings.py`)
- Compiles release binary via SPM.
- Stages `.app` bundle with Info.plist, icon assets, and ATS exception config.
- Codesigns with ad-hoc identity (`codesign --force --deep --sign -`) and strips quarantine xattrs.
- Synthesizes clean 600x380 retina DMG background with `generate_dmg_background.swift`.
- Runs Python `dmgbuild` to construct `Project-Nobel-Installer.dmg`.

---

## 8. Critical Coding & Design Constraints
- **Strict No Emojis Rule**: Absolutely zero emojis anywhere in the UI or AI generation prompts. Use SF Symbols for icons.
- **Swift Compiler Timeout Prevention**: Complex inline closures with multiple nested `HStack`/`VStack` inside `ForEach` can cause compiler timeouts. Always extract complex row items into standalone `View` structs.
- **File Links**: Always output file links as `[filename](file:///path/to/file)` with correct markdown formatting.
- **Dual-App Separation**: Keep Desktop sandbox testing (`physics_study_desktop.db`) strictly isolated from production (`physics_study.db`).
- **Empirical Diagnostics**: Inspect actual compiler and runtime logs (`batch_importer_run.log`, system logs) before diagnosing issues.
