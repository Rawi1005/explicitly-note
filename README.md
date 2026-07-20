# ExplicitlyNote

A default SwiftUI app template targeting **iPad only**.

## Requirements

- macOS with Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

```sh
xcodegen generate
open ExplicitlyNote.xcodeproj
```

Then select an iPad simulator (e.g. "iPad Pro 13-inch") as the run destination and press Run.

## Project structure

```
project.yml                          # XcodeGen spec — generates the .xcodeproj
ExplicitlyNote/
  ExplicitlyNoteApp.swift            # App entry point
  ContentView.swift                  # Root view (NavigationSplitView, iPad-optimized)
  Assets.xcassets/                   # App icon, accent color
  Preview Content/                   # SwiftUI preview-only assets
```

## iPad-specific configuration

- `TARGETED_DEVICE_FAMILY = 2` restricts the app to iPad (no iPhone build target).
- `ContentView` uses `NavigationSplitView`, the standard two/three-column layout for iPad's larger screen.
- All four interface orientations are supported on iPad.

## Regenerating the Xcode project

The `.xcodeproj` is generated from `project.yml` and is not committed. Re-run `xcodegen generate` any time you add files or change build settings in `project.yml`.
