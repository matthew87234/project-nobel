# Project Nobel - Physics Study App

A native macOS SwiftUI application designed for organizing physics lecture notes, generating AI-based summaries and difficulties, reviewing flashcards and practice problems, and testing knowledge using the Feynman Technique. It includes dynamic global module filtering and full split-screen support.

## Features
- **Responsive Dashboard**: Track flashcard and problem stats, study times, and daily learning activity heatmaps.
- **Background AI Processing**: Automatically generates concise lecture overviews, key concepts/equations, difficulty ratings, and pre-lecture primers using local Ollama models.
- **Study Mode**: Read lecture notes side-by-side with AI summaries and difficulty analysis.
- **Flashcards & Problems**: Interactive tools to review flashcards, solve practice problems, and translate handwritten equations/images to raw LaTeX.
- **Feynman Technique Sandbox**: Write down physical concepts in your own words and let the local AI evaluate your understanding and chat with you like a physics professor.
- **Ollama Integration**: Seamlessly starts the local Ollama CLI server in the background on app start and terminates it cleanly on app close.

---

## Installation Guide

To install and run Project Nobel on your Mac, follow these steps:

### 1. Prerequisites
Ensure you have the following installed on your macOS device:

1. **Swift & Xcode Command Line Tools**:
   Install by running the following command in Terminal:
   ```bash
   xcode-select --install
   ```
2. **Ollama**:
   If not installed, install it using Homebrew:
   ```bash
   brew install ollama
   ```
   Or download the app bundle from [ollama.com](https://ollama.com).
3. **Local AI Model**:
   Pull the required physics/vision assistant model locally:
   ```bash
   ollama pull qwen2.5vl:7b
   ```

### 2. Download and Build the App
Clone the repository, build the macOS release bundle, and install it to your `/Applications` directory:

```bash
# Clone this repository
git clone https://github.com/matthew87234/project-nobel.git
cd project-nobel

# Build the release bundle
cd swiftui-version
chmod +x build_app.sh
./build_app.sh

# Deploy to /Applications folder
cd ..
chmod +x deploy_to_applications.sh
./deploy_to_applications.sh
```

### 3. Running the App
Once deployed, you can open and run **Project Nobel** directly from your **Applications** folder, Launchpad, or Spotlight Search!
> [!NOTE]
> The app will automatically launch the Ollama local model server in the background when it starts, and shut it down cleanly when you close the window.
