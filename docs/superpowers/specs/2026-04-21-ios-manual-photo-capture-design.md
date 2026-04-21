# iOS Manual Photo Capture — Design

**Status:** Draft — awaiting user review
**Date:** 2026-04-21
**Scope:** `app/ios/RTABMapApp/` (iOS standalone app only). No changes to `corelib`, `guilib`, or the rtabmap DB schema.

## Goal

During a scan in the iOS RTAB-Map app, let the user manually capture discretionary still photos for later review, with automatic per-frame metadata (pose, intrinsics, timestamp, GPS, orientation, light estimate) and optional user metadata (label, note, tags, key/value properties). Photos are stored separately from the rtabmap SLAM database to keep concerns isolated and to avoid touching the cross-platform DB format.

The feature is a parallel observation stream — it does **not** inject frames into the SLAM graph.

## Non-goals

- Feeding manual photos back into the SLAM graph as additional keyframes.
- Server / cloud sync.
- Editing photos after their session folder is archived inside an exported `.zip`.
- Hard-enforced "materialepas" (Danish building-materials passport) schema validation. The data model is structured enough to be upgraded later; enforcement is explicitly deferred.
- A properties picker driven by the Teknologisk `dataordbog` (data dictionary). Deferred.

## Approach chosen

**Sidecar JSON, filesystem-backed, per-session folder.** Photos and their metadata live under `Documents/ManualPhotos/<sessionId>/`, independent of the rtabmap `.db`. Alternatives considered:

1. **(Chosen) Sidecar JSON.** Zero changes to corelib; trivially exportable; fastest to ship; human-inspectable during development; clean upgrade path to a sidecar SQLite with materialepas-style tables if/when needed.
2. **Sidecar SQLite per session.** Adopt a subset of the ReUseX `project_db` schema (`projects` / `property_definitions` / `material_passports` / `passport_property_values`). More structure, more code, locks us into a richer schema before its value is proven.
3. **Extra tables in the rtabmap DB.** Cheapest on file bookkeeping but requires C++ changes in `corelib/src/DBDriverSqlite3.cpp`, a schema migration, and couples an iOS-only UX feature to the canonical cross-platform map format that `rtabmap-databaseViewer` and friends would also need to understand. Rejected.

## UI

### New button

Add one button to the existing right-side vertical `UIStackView` (`kPv-DO-hpd`) in `app/ios/RTABMapApp/Base.lproj/Main.storyboard`:

- **PhotoButton** — SF Symbol `camera.circle`, white tint, 60×60, placed between RecordButton (`7Lv-u6-mGh`) and AddMeasureButton (`lFB-Lm-zFS`).
- Connected to `@IBAction func takePhotoAction(_ sender: UIButton)` in `ViewController.swift`.
- `@IBOutlet weak var photoButton: UIButton!` alongside the existing outlets around `ViewController.swift:110–124`.

### Visibility rules

In `updateState(state:)` (`ViewController.swift:677`), set `photoButton.isHidden` following the same `!mHudVisible` pattern used by peer buttons:

- `STATE_CAMERA` — shown (user may want a reference shot before recording).
- `STATE_MAPPING` — shown (primary use case).
- All other states — hidden.

Disabled (`isEnabled = false`) when `session.currentFrame == nil` at button-setup time is not necessary; the action handler will toast "No frame available" if it races.

## Capture flow

On tap (`takePhotoAction`), on the main thread:

1. Read `session.currentFrame` (the existing `ARSession` property at `ViewController.swift:21`). If `nil`: toast "No frame available" and return.
2. **Snapshot primitives synchronously off the `ARFrame`** before any async work, because `ARFrame` is only valid briefly:
   - `frame.timestamp` (ARKit monotonic clock)
   - Wall-clock `Date()` captured at the same moment.
   - `frame.camera.transform` (4×4) — copied into a `[[Float]]`.
   - `frame.camera.intrinsics` → `fx, fy, cx, cy`.
   - `frame.camera.imageResolution` (`CGSize`).
   - `frame.camera.trackingState` → normalized string.
   - `frame.lightEstimate?.ambientIntensity`.
   - Current `UIInterfaceOrientation` (via `UIApplication.shared.windows.first?.windowScene?.interfaceOrientation`, matching the existing odometry call site at `ViewController.swift:1201`).
   - `mLastKnownLocation` (if `PhotoIncludeGPS` is on and a fix exists).
3. **Capture the pixel buffer** by `CVPixelBufferRetain`ing `frame.capturedImage` for use on the background queue.
4. Dispatch to a dedicated serial `DispatchQueue(label: "rtabmap.manualPhoto")`:
   a. Convert `CVPixelBuffer` (YCbCr bi-planar full-range, format `420f`) → JPEG. Use `CIImage(cvPixelBuffer:)`, orient with the matching `CGImagePropertyOrientation` for the captured interface orientation, then `CIContext.jpegRepresentation(of:colorSpace:options:)` with quality from `UserDefaults` (`PhotoJPEGQuality`, default 0.85).
   b. Compute a filename: `yyyy-MM-dd'T'HH-mm-ss.SSS_<8-char-UUID>.jpg` (ISO-like but filename-safe).
   c. Compute `sha256(jpeg)` (CommonCrypto).
   d. Serialize sidecar JSON (schema below) and write both atomically (write to `.tmp`, `rename`).
   e. `CVPixelBufferRelease`.
   f. Hop back to main and show the metadata editor sheet (see [Metadata editor](#metadata-editor)).
5. Fire `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` at the moment of tap, and a brief toast "Photo saved" via the existing `showToast(message:seconds:)` on completion.

If the file write fails: toast "Failed to save photo: <error>", log via existing `print(...)` pattern, do not crash.

The odometry pipeline (`RTABMap.postOdometryEvent`) is untouched. Manual-photo capture does not contend with it — it reads `session.currentFrame` on demand, separate from the `session(_:didUpdate:)` callback.

## Storage layout

```
Documents/
  ManualPhotos/
    <sessionId>/                    # UUID string, one per mapping session
      session.json                  # session-level metadata (see below)
      2026-04-21T14-22-07-123_a1b2c3d4.jpg
      2026-04-21T14-22-07-123_a1b2c3d4.json
      ...
```

### `session.json`

```json
{
  "sessionId": "3F2E...",
  "createdAt": "2026-04-21T14:20:00.000Z",
  "dbFilename": "rtabmap.tmp.db",     // or the saved name when persisted
  "appVersion": "0.21.x",
  "schemaVersion": 1
}
```

### Per-photo sidecar JSON

```json
{
  "id": "a1b2c3d4...",
  "sessionId": "3F2E...",
  "capturedAt": "2026-04-21T14:22:07.123Z",
  "arkitTimestamp": 1234567.89,
  "camera": {
    "transform":  [[r00, r01, r02, tx],
                   [r10, r11, r12, ty],
                   [r20, r21, r22, tz],
                   [0,   0,   0,   1 ]],
    "intrinsics": { "fx": 1440.2, "fy": 1440.2, "cx": 960.0, "cy": 720.0 },
    "imageSize":  { "width": 1920, "height": 1440 },
    "orientation": "portrait",
    "trackingState": "normal"
  },
  "env": { "ambientIntensity": 712.4 },
  "gps":   { "lat": 55.676, "lon": 12.568, "alt": 10.2, "hAcc": 5.0, "vAcc": 3.0 },
  "file":  { "name": "2026-04-21T14-22-07-123_a1b2c3d4.jpg", "bytes": 384219, "sha256": "..." },
  "user": {
    "label": "",
    "note": "",
    "tags": [],
    "properties": []
  },
  "schemaVersion": 1
}
```

All keys except `id`, `sessionId`, `capturedAt`, `camera`, `file`, `schemaVersion` are optional. `gps` is omitted entirely when no fix is available or the setting is off. `user` is always present (may be all empty on first write).

The `user.properties` array uses: `{ "key": "dimensions.length_mm", "value": "2400", "unit": "mm" }`. Free-text v1; nothing is enforced against a dictionary.

## Lifecycle integration

The iOS app already distinguishes a "tmp" session (`rtabmap.tmp.db`) from saved sessions. Manual-photo sessions mirror that:

| Existing hook | Added behavior |
|---|---|
| `newScanAction` at `ViewController.swift:2533` | Delete the previous tmp session folder (matching the existing `rtabmap.tmp.db` wipe behavior), then mint a new `sessionId` (UUID) and create `Documents/ManualPhotos/<sessionId>/` with `session.json`. |
| Save-DB flow (the existing rename of `rtabmap.tmp.db` → `<name>.db`) | Update `session.json` with the saved `dbFilename`. The folder name stays as `<sessionId>` — folder-name ergonomics are deferred (see Open questions). |
| DB open from Library | If a `session.json` in any `ManualPhotos/*/` references this `dbFilename`, treat that folder as the "current session". Otherwise, a new empty session is created on first photo capture after open. |
| Export `.zip` bundler around `ViewController.swift:2402` | When `PhotoIncludeInExport` is on and the current session folder is non-empty, add the folder to the zip under `manual_photos/`. |
| DB delete | On delete, also delete the matching session folder. Confirm in the same alert. |

A singleton `ManualPhotoStore` (new Swift file, `app/ios/RTABMapApp/ManualPhotoStore.swift`) owns the folder lifecycle. `ViewController` holds a reference and calls into it from the above hooks. This keeps `ViewController` from growing further (it is already 2764 lines).

## Metadata editor

A small `UIViewController` presented modally via `.formSheet`, **built programmatically** (no new storyboard scene — keeps the diff tight and the file focused). New file: `app/ios/RTABMapApp/PhotoMetadataEditor.swift`.

Contents (top-to-bottom):

- Thumbnail preview (square, max 256pt side).
- **Label** — single-line `UITextField`, placeholder "Label (optional)".
- **Note** — multiline `UITextView`, placeholder "Note…".
- **Tags** — simple chip field: a scroll view of existing tags + a text field; tags are comma-split on entry.
- **Properties** — a `UITableView` of `{key, value, unit}` rows with swipe-to-delete. A "+ Add property" row at the bottom. A "Suggested" menu button (`UIMenu`) seeds keys with materialepas-domain categories:
  - `dimensions.length_mm`, `dimensions.width_mm`, `dimensions.height_mm`
  - `condition` (free text)
  - `origin.building`, `origin.year`
  - `material`
  - `contamination.pfas`, `contamination.asbestos`
  - `certification`
  These are *suggestions only*; the user can type any key.
- **Done** button (navigation bar right) — persists edits to the sidecar JSON.
- **Delete photo** (navigation bar left, destructive) — deletes jpg + json with confirmation.

Dismissing the sheet without tapping Done keeps the photo with automatic metadata only (the file already exists from the capture step). Re-opening the photo from the gallery re-presents the same editor.

## Gallery (v1)

From the existing hamburger menu (`menuButton`, wired around `ViewController.swift:1047`), add a menu item "Manual Photos (N)" where N is the current session's count. Pushes a `UICollectionViewController` (new file `ManualPhotoGalleryViewController.swift`):

- Grid of thumbnails (`UIImage` lazily loaded and cached).
- Tap → full-screen preview + the same `PhotoMetadataEditor`.
- Long-press → multi-select + delete.

Supporting read-only view from saved DBs: selecting a saved DB from the Library reloads the corresponding session folder (as defined by the lifecycle table); the gallery then shows that session's photos.

## Settings

New entries appended to `app/ios/Settings.bundle/Mapping.plist`:

- **PhotoJPEGQuality** — `PSSliderSpecifier`, 0.5 … 1.0, default 0.85.
- **PhotoIncludeGPS** — `PSToggleSwitchSpecifier`, default `YES`. Respects the existing location-permission flow; if permission is denied the toggle has no effect.
- **PhotoIncludeInExport** — `PSToggleSwitchSpecifier`, default `YES`.

Read in Swift via `UserDefaults.standard.float(forKey: "PhotoJPEGQuality")` etc., with guards for unset/default values (matching the pattern used at e.g. `ViewController.swift:855` for `ExportPointCloudFormat`).

## Permissions

No new system permissions are needed:

- Camera access is already granted to the app via `NSCameraUsageDescription` (ARKit).
- Location access is only used if already granted for the existing GPS-in-DB feature (`CLLocationManager` at `ViewController.swift:22`).
- Photos are written to the app's sandboxed `Documents/`, not Photo Library — no `NSPhotoLibraryUsageDescription` change required.

## Error handling

- Missing `session.currentFrame` → toast, no-op.
- JPEG conversion failure (non-420f pixel format) → toast "Unsupported frame format", log, no-op.
- Disk write failure (out of space, permission) → toast with `error.localizedDescription`, partial files cleaned up.
- Malformed sidecar JSON on read → skip that photo in the gallery with a console log; do not crash the gallery load.

## Files touched / added

Added:

- `app/ios/RTABMapApp/ManualPhotoStore.swift`
- `app/ios/RTABMapApp/PhotoMetadataEditor.swift`
- `app/ios/RTABMapApp/ManualPhotoGalleryViewController.swift`

Modified:

- `app/ios/RTABMapApp/ViewController.swift` — add outlet, action, visibility rules in `updateState`, lifecycle calls in `newScanAction` / DB-save / DB-open / DB-delete, menu item, export-zip hook.
- `app/ios/RTABMapApp/Base.lproj/Main.storyboard` — add PhotoButton to the right-side vertical stack.
- `app/ios/Settings.bundle/Mapping.plist` — three new settings entries (titles inline; no `Root.strings` edits needed since `Root.strings` pairs with `Root.plist`).
- `app/ios/RTABMapApp.xcodeproj/project.pbxproj` — register the three new Swift files in the target.

No changes to: `corelib/`, `guilib/`, `utilite/`, `tools/`, `NativeWrapper.cpp`, `NativeWrapper.hpp`, `RTABMap.swift`.

## Testing

No unit-test harness exists in the iOS target today. Manual acceptance:

1. Fresh install → new scan → Record → tap PhotoButton → verify a `.jpg` + `.json` pair under `Documents/ManualPhotos/<uuid>/`.
2. Metadata editor: set label, note, tag, and two properties → Done → re-open from gallery → values persisted.
3. Stop mapping → Save DB as `test1` → Library → open `test1.db` → gallery lists the photos; editor still works.
4. New scan → first session's photos are not visible in the new session's gallery.
5. Delete a photo from gallery → `.jpg` and `.json` both gone.
6. Export with `PhotoIncludeInExport=YES` → resulting `.zip` contains `manual_photos/<files>`.
7. Export with `PhotoIncludeInExport=NO` → zip does not contain the folder.
8. Disable location, capture → sidecar has no `gps` field.
9. Rotate device to landscape, capture → preview and saved JPEG are right-side-up.
10. Capture while tracking is `limited(.relocalizing)` → photo still saves; sidecar records `trackingState: "limitedRelocalizing"`.

## Open questions (defer to implementation)

- Exact thumbnail-cache eviction policy (LRU size) — not critical for v1.
- Whether to rename session folders on save to `<dbBasename>-<sessionId>` for human readability — v1 keeps `<sessionId>`-only; revisit if users ask.
- Whether to include a "burst mode" (tap-and-hold) — not in v1.

## Schema versioning

Both `session.json` and per-photo JSON include `schemaVersion: 1`. On read, unknown versions are logged and the file is loaded best-effort (ignore fields we don't know; pass through fields we do know). Migrations are handled by the next bump adding explicit transforms.
