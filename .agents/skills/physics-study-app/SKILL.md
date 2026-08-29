---
name: physics-study-app
description: Master technical architecture, learning pedagogy, database schemas, feature specifications, and build/deploy workflows for Project Nobel (Physics Study App).
---

# Project Nobel (Physics Study App) — Comprehensive AI Engineering & Pedagogy Guide

## 1. Project Overview & Vision
**Project Nobel** is a native macOS physics study & interleaving application built with SwiftUI, SQLite3, local & cloud AI models (Ollama Qwen2.5-Coder / Qwen2.5-VL / Tailscale remote AI), and Anki bidirectional synchronization.

The application is engineered around cognitive science principles for STEM learning:
- **Interleaving**: Mixing different physics topics/modules during study to improve neural discrimination.
- **Spaced Repetition (SM-2)**: Algorithmically scheduling flashcards and physics problems based on difficulty.
- **Step-Level Diagnostic Error Tracking**: Tracking *where* in a physics solution a student made an error (Step 1 Setup vs Step 2 Formulation vs Step 3+ Slips) to dynamically adapt review intervals.
- **Pre-Exam Warmup Routine**: A 2-hour pre-exam warmup timeline designed to prime working memory without inducing cognitive fatigue.

---

## 2. Technical Stack & File Architecture
- **Language & Framework**: Swift 5.10+, SwiftUI, Swift Charts, macOS Native SPM target.
- **Workspace Location**: `/Users/matthewt/Projects/PhysicsStudyApp/swiftui-version`
- **Database**: SQLite3 (`DatabaseManager.swift`).
- **Core Source Files (`Sources/macOS-Native/`)**:
  - `App.swift`: Main app lifecycle, toolbar navigation, module selector, window management.
  - `DatabaseManager.swift`: Database connection, schema migrations, models (`Module`, `Topic`, `Note`, `Flashcard`, `Problem`), CRUD queries.
  - `DashboardView.swift`: Main dashboard, 53-week study activity heatmap, donut study distribution chart, metric statistics cards.
  - `StudyView.swift`: Interleaved study guide and active practice session manager.
  - `FlashcardsView.swift`: Spaced repetition flashcard centre, SM-2 engine, interactive chart popups (`MetricCardView`), flag queue (`is_flagged`).
  - `ProblemsView.swift`: Physics problem practice centre, interactive diagnostic error charts, step error marking (`StepRowPracticeView`), flag queue (`is_flagged`), step-severity tracking (`last_failed_step`, `severity_level`).
  - `PreLectureView.swift` & `PostLectureView.swift`: Pre-lecture primers and post-lecture summaries.
  - `FeynmanManagerView.swift`: AI Feynman Technique interactive tutor.
  - `ModuleManagerView.swift`: Manage Modules modal (CRUD, semester, year, **Exam Date & Time** inputting).
  - `AIHelper.swift`: Background AI processing engine (Ollama CLI, Tailscale remote fallback, prompt generators).
  - `AnkiSyncEngine.swift`: Bidirectional sync engine connecting flashcards to Anki Desktop API.

---

## 3. Core Features & UI Standards

### A. Top-Left Exam Date Badge (`App.swift`)
- **Location**: Top-left toolbar item (`ToolbarItem(placement: .navigation)`), positioned directly above the **Dashboard** detail header text.
- **Format**: Clean toolbar item with secondary calendar icon + 3-letter month date string (`📅 1 Sep 2026`).
- **Hover Tooltip**: Displays the countdown (`Exam Date for [Code]: X days remaining (1 Sep 2026)`).
- **Data Source**: `testDateFormattedDateOnly` and `daysRemainingFormatted` properties on `Module` struct (derived from `modules.test_date`).
- **Inputting**: Managed in the **Manage Modules** window (`ModuleManagerView.swift`) via a `Toggle("Set Exam Date & Time")` and a `DatePicker`.

### B. Problems Centre & Step-Level Diagnostic Error Marking (`ProblemsView.swift`)
- **Step-Error Button**: Uses `Image(systemName: isErrorStep ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")` warning triangle button inside `StepRowPracticeView`.
- **Severity Levels (`DatabaseManager.swift`)**:
  - **Level 1 (Critical)**: Error in Step 1 (Conceptual Setup / Free-Body Diagram). Review due in 1 day.
  - **Level 2 (High)**: Error in Step 2 (Equation Formulation / Vector Setup). Review due in 2 days.
  - **Level 3 (Medium)**: Error in Step 3+ (Algebraic / Arithmetic Slips). Review due in 4 days.
  - **Level 4 (Flawless)**: 0 Errors (Clean Solve). Review due in 7 days.
- **Interactive Metric Cards**: `MetricCardView` components on statistics cards (`Due Interleaving`, `Flagged Problems`, `Mastery Rate`, `Total Problems`) triggering modal Swift Charts (`ProblemDueProjectionChartView`, `ProblemSeverityChartView`, `ProblemTopicChartView`, `ProblemFlaggedChartView`).

### C. Flashcards Centre & Anki Sync (`FlashcardsView.swift`)
- **SM-2 Spaced Repetition**: Updates `next_review_date`, `interval`, `ease_factor`, `repetitions`.
- **Flag Queue (`is_flagged`)**: Dedicated **strictly for marking cards that need correction, verification, or editing** (e.g. typos, LaTeX fixes). Flag status does NOT indicate topic importance or exam priority.
- **Preset Counts**: Selector for practice queue size (5, 10, 15, Custom).

---

## 4. Pre-Exam Warmup Routine Strategy (Cognitive Science across STEM / Math)

The final 2 hours before any technical or mathematical exam (Physics, Pure/Applied Mathematics, Computer Science, Engineering) follow a 3-phase warmup pipeline designed to prime working memory without mental burnout:

```
T-120 mins                    T-80 mins                   T-40 mins             T-0 (Exam Start)
    │                             │                           │                       │
    ├────────── PHASE 1 ──────────┼───────── PHASE 2 ─────────┼─────── PHASE 3 ───────┤
    │  Definition & Theorem       │   High-Yield Setup/Proof  │    Core Identity      │
    │         Priming             │         Strategy          │   Dump & Mental Reset │
```

1. **Phase 1: Definition & Theorem Priming (T-120m to T-80m)**: Rapid 25-card review of core definitions, canonical formulas/identities, applicability conditions, and notation conventions.
   - **Prioritization Algorithm**: Cards are selected using SM-2 retention metrics and AI semantic classification (`ORDER BY ease_factor ASC, interval ASC LIMIT 25`).
   - **Strict Exclusion Rules**:
     - *No Flagged Cards (`is_flagged == false`)*: Cards flagged for correction or editing are strictly excluded from pre-exam decks.
     - *No Trivial / Very Basic Cards*: Elementary unit definitions, single-word recall, or basic high-school facts are filtered out.
     - *No Multi-Step Derivations*: Long algebraic calculations are excluded to preserve working memory.
   - **General STEM Taxonomy**:
     - *Primary Definitions & Theorems*: Theorem hypotheses, key identities, foundational definitions.
     - *Applicability & Existence Prerequisites*: Theorem validity conditions (e.g. diagonalizability criteria, convergence test constraints).
     - *Boundary / Extreme Cases*: Asymptotic limits ($x \to \infty, 0$), empty set / zero-vector cases, boundary conditions.
     - *Notation & Sign Traps*: Common orientation, ordering, or sign convention pitfalls.
2. **Phase 2: High-Yield Setup & Proof Strategy Warmup (T-80m to T-40m)**: Reviewing **Step 1 & Step 2** (Problem Classification, Initial Substitution, Free-Body Diagram, or Proof Outline) of previously solved problems—skipping tedious numerical/algebraic calculations or long matrix arithmetic to warm up setup intuition rapidly without fatigue.
   - **Sampling Algorithm**: Queries `getTopics(forModuleId:)` and evenly samples 1–2 high-severity, non-flagged problems per lecture/week (8–12 problems total).
   - **Interactive Strategy Cards**:
     - *Step 1 (Blue)*: Problem Classification & Governing Principle.
     - *Step 2 (Green)*: Coordinate System & Initial Boundary Setup.
   - **Pin to Phase 3**: Allows pinning tricky formulas and setups directly to the Phase 3 cheat sheet.
3. **Phase 3: Prepared Notes, Pinned Problems & Mental Reset (T-40m to T-0m)**:
   - **Sub-Tab 1: Prepared Notes Editor & 1-Page Cheat Sheet**: Pre-exam notes editor supporting LaTeX math, Markdown, quick snippet buttons (`\frac`, `\int`, `\nabla \times`, `\sum`, `pmatrix`), and live math preview.
   - **Sub-Tab 2: Pinned Problems**: Dedicated review of problems and initial equations pinned during Phase 2.
   - **Sub-Tab 3: Mental Reset**: 15-minute dedicated countdown timer, animated 4-4-4-4 box breathing pacer (Inhale 4s $\to$ Hold 4s $\to$ Exhale 4s $\to$ Hold 4s), and pre-flight exam checklist.
   - **Generation Trigger & 3-Choice Redo Alert**: Clicking Redo AI provides choices: *Redo AI Selection*, *Change / Edit Notes*, or *Cancel*, navigating straight to the Phase 3 editor with previously saved notes pre-filled.

---

## 5. Build, Packaging & Deployment Commands

Always run build commands from the root Swift package directory:
```bash
cd /Users/matthewt/Projects/PhysicsStudyApp/swiftui-version

# 1. Compile release binary
swift build -c release

# 2. Package into Project Nobel.app bundle
./build_app.sh

# 3. Deploy to /Applications and Desktop
/Users/matthewt/Projects/PhysicsStudyApp/deploy_to_applications.sh
cp -R "/Applications/Project Nobel.app" "/Users/matthewt/Desktop/Project Nobel.app"
```

---

## 6. Coding & Swift Guidelines
- **Swift Compiler Timeout Prevention**: Complex inline closures with multiple nested `HStack`/`VStack` inside `ForEach` can cause compiler timeouts (`error: the compiler is unable to type-check this expression in reasonable time`). Always extract complex row items into standalone `View` structs (e.g. `StepRowPracticeView`).
- **File Links**: Always output file links as `[filename](file:///path/to/file)` with correct markdown formatting.
- **Empirical Log Diagnostics**: Never guess the root cause of an error without fetching and inspecting the exact compiler/runtime log.
