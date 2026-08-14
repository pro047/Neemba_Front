# Launcher icon source

Drop two PNGs here, then run:

    dart run flutter_launcher_icons

## icon.png (required)
- 1024x1024, square, opaque background
- Used for iOS / web / macOS / Windows and as the Android legacy icon

## icon_foreground.png (required)
- 1024x1024, transparent background
- Android adaptive icon foreground layer
- Keep artwork inside the central ~66% (the outer ring gets masked off)

These files are inputs to icon generation only — they are not bundled
into the app, so they must NOT be listed under `flutter: assets:`.
