# Layered app icon

The active icon is `apps/ios/HealthMCP/AppIcon.icon`, an Icon Composer package with two independently editable components:

- **Background:** the document's native navy background fill, defined in `icon.json`.
- **Spark:** the mint pulse mark in `Assets/Spark.svg`, with a transparent canvas and an outlined vector path. Its shape, position, stroke outline and colors preserve the original icon artwork.

The foreground uses Liquid Glass with modest translucency and a natural shadow. A white foreground specialization lets the system apply the user's tint. Default, dark, tinted and clear appearances were exported with Apple's `ictool` and visually checked.

## Editing and integration

Open the `.icon` package in Icon Composer to edit the background and foreground separately. The background uses the built-in fill rather than an opaque image layered over it, so the system can supply its clear/dark treatment. `ASSETCATALOG_COMPILER_APPICON_NAME` remains `AppIcon`.

`project.yml` explicitly treats `.icon` packages as files; XcodeGen adds the package as a single `wrapper.icon` resource. Xcode compiles the vector/group data into `Assets.car` and generates compatibility images for older iOS versions. The old `Assets.xcassets/AppIcon.appiconset` remains as historical artwork; the matching `.icon` takes precedence in current Xcode and supplies the generated compatibility images. [Apple's integration and compatibility documentation](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

Regenerate the foreground outline from the original geometry:

```sh
swift scripts/generate-icon-layer.swift apps/ios/HealthMCP/AppIcon.icon/Assets/Spark.svg
xcodegen generate --spec apps/ios/project.yml
```

Apple's renderer is bundled at `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`. Use an absolute input path. Exported previews are in `artifacts/icon-2026-09-10/`.

## Validation — September 10, 2026

- Xcode 26.3 Release simulator build succeeded, with no warnings reported by the final XcodeBuildMCP build.
- Compiled asset inspection found `AppIcon_Assets/Spark` as a vector, the icon group/stack, and default/dark/tintable phone images. The system `assetutil` cannot decode every new icon-stack rendition; the compiler and Icon Composer renderer are the format checks.
- Installed on iPhone 17 Pro Max / iOS 26.3 and visually checked in App Library.
- Installed and launched successfully on iPhone SE (3rd generation) / iOS 18.1.
- Exported and visually checked Default, Dark, TintedDark and ClearLight with Apple's Icon Composer renderer.
- Confirmed `MinimumOSVersion = 18.0` and `UIDeviceFamily = [1]` in the final built app.

The build check exposed XcodeGen's target-level `1,2` default overriding the project's intended iPhone-only setting. The app target now sets `TARGETED_DEVICE_FAMILY = 1` explicitly in both Debug and Release. Build 13 advertised `[1,2]`; build 14 contains the correction and the layered icon.

## App Store Connect upload — September 10, 2026

Version **1.0.0 (14)** was archived, exported, uploaded and processed successfully. Apple reports `VALID` and `APP_STORE_ELIGIBLE`. Build 14 is attached to the existing version 1.0.0 draft, which remains `PREPARE_FOR_SUBMISSION` with manual release and no review submission.

The signed IPA was checked for `UIDeviceFamily = [1]`, minimum iOS 18.0, the compiled Spark vector/group, production push and HealthKit entitlements, and its bundled private client. Archive and IPA signature verification passed. The icon's existing iOS 26.3 and iOS 18.1 runtime checks remain the visual/compatibility evidence; native and backend test suites were not rerun for this icon and build-number update.

Upload and staging results: [build 14 evidence](evidence/appstore-build-14-2026-09-10.json). The later [September 10 submission](appstore-submission-2026-09-10.md) finalized App Privacy, Free pricing and the No medical-device declaration. Build 14 is now Waiting for Review, with manual release after approval.

Machine-readable results: [icon validation](evidence/app-icon-2026-09-10.json).
