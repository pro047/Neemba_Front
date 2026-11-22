# Launcher icon source

Drop two PNGs here, then run:

    dart run flutter_launcher_icons

## icon.png (required)
- 1024x1024, square, opaque background
- Used for iOS / web / macOS / Windows and as the Android legacy icon

## icon_foreground.png (required)
- 1024x1024, transparent background
- Android adaptive icon foreground layer
- The generated `ic_launcher.xml` insets this by 16%, so the PNG covers 73.44dp of
  the 108dp canvas. The 72dp mask circle lands at radius 502px here — keep artwork
  inside that circle, not inside a smaller "central 66%" box.

## Current artwork (temporary)
A lowercase "n" monogram, `#38BDF8` on `#0F172A`. Placeholder for store submission —
replace before review. Regenerate with `swift tool/gen_icon.swift assets/icon`.

These files are inputs to icon generation only — they are not bundled
into the app, so they must NOT be listed under `flutter: assets:`.
