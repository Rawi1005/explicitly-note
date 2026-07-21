# SmartNotes

A small, Goodnotes-inspired note-taking app for typed notes with smart word definitions — built for researchers and students who hit unfamiliar words while writing. Select a word, define it with [DictionaryAPI.dev](https://dictionaryapi.dev), and **insert the definition right into your note** or save it to a vocabulary list.

- Swift · SwiftUI · MVVM · SwiftData · iOS 17+ · no third-party libraries
- iPhone + iPad (NavigationSplitView on iPad), light/dark mode, Dynamic Type

## Features

- **Notes library** — searchable, sortable (last modified / created / title) cards with previews, folders label, swipe-to-delete
- **Rich text editor** — UITextView wrapped for SwiftUI; bold, italic, underline, heading, bullets; auto-save
- **Define selected word** — custom edit-menu actions (Define / Explain with AI / Add to Vocabulary) plus a toolbar lookup button
- **Definition sheet** — phonetics, audio pronunciation, meanings by part of speech (3 shown, expandable), examples, synonyms/antonyms
- **📖 Insert into Note** — drops the definition into the note as a styled annotation right where you were reading
- **Vocabulary list** — saved words with definitions, duplicate-safe, searchable
- **7-day definition cache** (SwiftData) — instant repeat lookups; expired cache still shown as offline fallback
- **Explain with AI (placeholder)** — level + subject pickers behind an `AIExplanationService` protocol, mock implementation for now

## Opening the project after `git clone`

> **Important:** there is **no `SmartNotes.xcodeproj` in the repo.** This project is
> described by `project.yml` and the `.xcodeproj` is *generated* by
> [XcodeGen](https://github.com/yonaskolb/XcodeGen). This is normal for XcodeGen
> projects — the generated file is intentionally git-ignored so it never causes
> merge conflicts. You generate it once after cloning.

You need a Mac with **Xcode 15 or newer** (from the Mac App Store) and Xcode's
command-line tools.

**1. Clone the repo and enter it**

```sh
git clone https://github.com/Rawi1005/explicitly-note.git
cd explicitly-note
```

**2. Install XcodeGen** (one time — it's a tiny tool that reads `project.yml`)

```sh
# If you have Homebrew (https://brew.sh):
brew install xcodegen
```

**3. Generate the Xcode project**

```sh
xcodegen generate
```

This creates `SmartNotes.xcodeproj` in the current folder.

**4. Open it in Xcode**

```sh
open SmartNotes.xcodeproj
```

(or double-click `SmartNotes.xcodeproj` in Finder.)

**5. Run the app**

- At the top of Xcode, pick the **`SmartNotes`** scheme and an **iPhone 15** or
  **iPad Pro** simulator (any iOS 17+ simulator).
- Press **⌘R** (or the ▶ button) to build and run.
- Press **⌘U** to run the unit tests (`SmartNotesTests`).

No signing setup is needed to run in the **simulator**. To run on a *physical*
device, select your device, then in **Signing & Capabilities** choose your
Apple ID team and let Xcode assign a bundle identifier.

### Whenever you add or rename files

Re-run `xcodegen generate` after pulling changes that add new source files, so
the `.xcodeproj` picks them up. (You never edit the `.xcodeproj` by hand — change
`project.yml` instead.)

### Rebuilding the full offline dictionary

Keep the downloaded Open English WordNet SQLite file under `Dictionaries/`,
then convert it into the compact database bundled by the app:

```sh
python3 Tools/build_dictionary.py \
  --oewn-sqlite Dictionaries/oewn-plus-2026-sqlite-3.0.1.sqlite
```

The source download is left untouched and ignored by Git; the generated app
database is written to `SmartNotes/Resources/dictionary.sqlite`.

### Troubleshooting

| Symptom | Fix |
| --- | --- |
| `xcodegen: command not found` | XcodeGen isn't installed — run `brew install xcodegen` (step 2). |
| `open` says the project doesn't exist | You skipped `xcodegen generate` (step 3). |
| Buttons/app don't run at all | Make sure you pressed **⌘R** with a simulator selected — the app has to be *running* for anything to be interactive. |
| Build fails on `import SwiftData` | Your Xcode is older than 15 / SDK older than iOS 17. Update Xcode. |

No extra capabilities or Info.plist entries are required — the Info.plist is
generated from the build settings in `project.yml`, and the dictionary API is
plain HTTPS.

## Structure

```
project.yml            # XcodeGen spec (app + unit test targets)
SmartNotes/
  SmartNotesApp.swift  # Entry point + TabView (Notes / Vocabulary / Settings)
  Models/              # SwiftData models + DictionaryAPI Codable models
  Services/            # Networking, caching, vocabulary, audio, AI protocol
  ViewModels/          # MVVM view models (@Observable, @MainActor)
  Views/               # Notes, Dictionary, Vocabulary, AI, Settings
  PreviewSupport/      # Sample data so previews work offline
SmartNotesTests/       # Decoding, networking (URLProtocol mock), cache, vocab tests
```

## Privacy

Dictionary lookups send **only the selected word** — never the note. The future AI integration is designed the same way: selected text, one or two context sentences, subject, and level only. Plug a real provider in by implementing `AIExplanationService` and swapping it for `MockAIExplanationService`.
