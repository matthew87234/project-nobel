# Project Nobel - Physics Study App

An advanced desktop study application for Windows & macOS designed for organizing physics lecture notes, reviewing flashcards with SuperMemo SM-2 spaced repetition, practicing physics problems with step-by-step solutions, and testing knowledge using the Feynman Technique.

## Versions Available
- **`flutter-version/`**: Modern cross-platform Flutter Desktop application targeting **Windows Desktop** & **macOS** with native `macos_ui` design system, `flutter_riverpod` state management, `sqflite_common_ffi` offline local storage, and LaTeX/Markdown rendering.
- **`swiftui-version/`**: Original native macOS SwiftUI application.

## Features
- **Responsive Dashboard**: Stats tracking, 53-week GitHub-style learning activity heatmaps, and study mode balance ratio tracker.
- **Spaced Repetition (SuperMemo SM-2)**: Interactive flashcard review mode with 3D card flip animations, recall ratings (Again, Hard, Good, Easy), and card flagging.
- **Practice Problems Engine**: Step-by-step solution breakdowns, solution hint toggles, LaTeX mathematical formula rendering, and solved counters.
- **Pre-Lecture Primers & Feynman Sandbox**: AI-assisted pre-lecture warm-up generator and post-lecture Feynman technique conceptual chat assistant.
- **Local & Cloud AI Integration**: Support for local Ollama models (`qwen2.5-coder`, `qwen2.5vl`) and cloud OpenAI-compatible endpoints.

---

## Quick Start (Flutter Desktop)

### Prerequisites
1. **Flutter SDK** (3.x or higher)
2. **Dart SDK** (included with Flutter)

### Building & Running on Windows / macOS
```bash
# Clone the repository
git clone https://github.com/matthew87234/project-nobel.git
cd project-nobel/flutter-version

# Install dependencies
flutter pub get

# Run on Desktop (Windows or macOS)
flutter run -d windows   # For Windows Desktop
# OR
flutter run -d macos     # For macOS Desktop
```
