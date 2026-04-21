# iOS Manual Photo Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a button to the iOS RTAB-Map app that captures a still photo on demand during a scan, with automatic per-frame metadata and optional user-editable metadata, stored as JPEG + sidecar JSON under `Documents/ManualPhotos/<sessionId>/` — no changes to the rtabmap DB.

**Architecture:** One new `ManualPhotoStore` singleton owns the on-disk layout. Capture reads `ARSession.currentFrame` synchronously, snapshots its primitives, then writes JPEG + JSON on a background serial queue. A lightweight programmatic `PhotoMetadataEditor` view controller is presented after capture for optional user metadata. A `ManualPhotoGalleryViewController` exposes the session's photos. Lifecycle hooks (new scan, save/open/delete DB, export) wire the session folder to the existing tmp-DB lifecycle.

**Tech Stack:** Swift, UIKit, ARKit, CoreImage (CVPixelBuffer→JPEG), Foundation (`Codable`/`JSONEncoder`), CommonCrypto (SHA-256), CoreLocation (already integrated). No new third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-04-21-ios-manual-photo-capture-design.md`

## Testing approach

The iOS target has no XCTest target today — adding one is out of scope. Each task uses two gates:

1. **Build gate:** `xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS' -configuration Debug build-for-testing build 2>&1 | tail -40` must return exit code 0 and show `** BUILD SUCCEEDED **`.
2. **Runtime gate:** Specific manual acceptance steps per task (run on simulator or device), culminating in the full 10-scenario walkthrough from the spec's Testing section (executed in Task 16).

For pure-Swift logic (`ManualPhotoStore`, `PhotoMetadata`, `PixelBufferJPEG`), each task also includes a **one-shot Swift script** the engineer runs from the command line via `swift` to validate logic before wiring it into the app. This is a pragmatic substitute for a real test target.

## File structure

New files (under `app/ios/RTABMapApp/`):

| File | Responsibility |
|---|---|
| `ManualPhotoStore.swift` | Singleton managing `Documents/ManualPhotos/` session folders: create/delete session, resolve paths, enumerate photos, write/read sidecar JSON atomically. No UIKit deps. |
| `PhotoMetadata.swift` | `Codable` structs for `SessionJSON`, `PhotoSidecar`, and sub-structs (`CameraMeta`, `EnvMeta`, `GPSMeta`, `FileMeta`, `UserMeta`, `UserProperty`). |
| `PixelBufferJPEG.swift` | Pure helper: given `CVPixelBuffer`, orientation, and quality, return `Data` (JPEG). |
| `PhotoMetadataEditor.swift` | Programmatic `UIViewController` with thumbnail + label + note + tags + properties table. |
| `ManualPhotoGalleryViewController.swift` | Programmatic `UICollectionViewController` listing a session's photos; tap → editor. |

Modified files:

| File | Changes |
|---|---|
| `app/ios/RTABMapApp/Base.lproj/Main.storyboard` | Add PhotoButton into the right-side vertical stack. |
| `app/ios/RTABMapApp/ViewController.swift` | New outlet, `takePhotoAction`, visibility in `updateState`, lifecycle hooks in `newScan` / `saveDatabase` / `openDatabase` / `databaseDeleted`, menu item, export-zip hook. |
| `app/ios/Settings.bundle/Mapping.plist` | Three new `PreferenceSpecifiers`. |
| `app/ios/RTABMapApp.xcodeproj/project.pbxproj` | Register the five new Swift files in the `RTABMapApp` target. |

---

### Task 1: PhotoMetadata model types

**Files:**
- Create: `app/ios/RTABMapApp/PhotoMetadata.swift`

- [ ] **Step 1: Write the file**

Content of `app/ios/RTABMapApp/PhotoMetadata.swift`:

```swift
//
//  PhotoMetadata.swift
//  RTABMapApp
//
//  Codable models for the manual-photo sidecar JSON schema.
//  See docs/superpowers/specs/2026-04-21-ios-manual-photo-capture-design.md
//

import Foundation

struct SessionJSON: Codable {
    var sessionId: String
    var createdAt: Date
    var dbFilename: String?
    var appVersion: String
    var schemaVersion: Int
}

struct CameraMeta: Codable {
    // 4x4 row-major, indexed [row][col]. Values are Float.
    var transform: [[Float]]
    struct Intrinsics: Codable {
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
    }
    var intrinsics: Intrinsics
    struct ImageSize: Codable {
        var width: Int
        var height: Int
    }
    var imageSize: ImageSize
    var orientation: String       // "portrait" | "portraitUpsideDown" | "landscapeLeft" | "landscapeRight" | "unknown"
    var trackingState: String     // "normal" | "limitedInitializing" | "limitedRelocalizing" | "limitedExcessiveMotion" | "limitedInsufficientFeatures" | "notAvailable"
}

struct EnvMeta: Codable {
    var ambientIntensity: Double?
}

struct GPSMeta: Codable {
    var lat: Double
    var lon: Double
    var alt: Double?
    var hAcc: Double?
    var vAcc: Double?
}

struct FileMeta: Codable {
    var name: String
    var bytes: Int
    var sha256: String
}

struct UserProperty: Codable {
    var key: String
    var value: String
    var unit: String?
}

struct UserMeta: Codable {
    var label: String
    var note: String
    var tags: [String]
    var properties: [UserProperty]

    static let empty = UserMeta(label: "", note: "", tags: [], properties: [])
}

struct PhotoSidecar: Codable {
    var id: String                 // UUID (matches filename short-id)
    var sessionId: String
    var capturedAt: Date           // wall-clock
    var arkitTimestamp: Double     // frame.timestamp
    var camera: CameraMeta
    var env: EnvMeta?
    var gps: GPSMeta?
    var file: FileMeta
    var user: UserMeta
    var schemaVersion: Int
}

enum PhotoMetadataCodec {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```

- [ ] **Step 2: Validate the Codable round-trip via a one-shot swift script**

Run (from the repo root):

```bash
cat > /tmp/validate_metadata.swift <<'SWIFT'
import Foundation
$(cat app/ios/RTABMapApp/PhotoMetadata.swift | sed -n '/^struct SessionJSON/,$p')

let s = PhotoSidecar(
    id: "abc",
    sessionId: "sess1",
    capturedAt: Date(timeIntervalSince1970: 1700000000),
    arkitTimestamp: 12.345,
    camera: CameraMeta(
        transform: [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
        intrinsics: .init(fx: 1440, fy: 1440, cx: 960, cy: 720),
        imageSize: .init(width: 1920, height: 1440),
        orientation: "portrait",
        trackingState: "normal"
    ),
    env: EnvMeta(ambientIntensity: 712.4),
    gps: nil,
    file: FileMeta(name: "a.jpg", bytes: 100, sha256: "deadbeef"),
    user: .empty,
    schemaVersion: 1
)
let data = try PhotoMetadataCodec.encoder().encode(s)
let back = try PhotoMetadataCodec.decoder().decode(PhotoSidecar.self, from: data)
assert(back.id == s.id && back.file.name == s.file.name && back.camera.intrinsics.fx == 1440)
print("OK \(data.count) bytes")
SWIFT
swift /tmp/validate_metadata.swift
```

Expected output: `OK <N> bytes` where N is a positive integer. Exit code 0.

- [ ] **Step 3: Commit**

```bash
git add app/ios/RTABMapApp/PhotoMetadata.swift
git commit -m "ios: add PhotoMetadata Codable models for manual photo sidecar JSON"
```

---

### Task 2: PixelBufferJPEG helper

**Files:**
- Create: `app/ios/RTABMapApp/PixelBufferJPEG.swift`

- [ ] **Step 1: Write the file**

Content of `app/ios/RTABMapApp/PixelBufferJPEG.swift`:

```swift
//
//  PixelBufferJPEG.swift
//  RTABMapApp
//
//  Convert ARKit's CVPixelBuffer (YCbCr bi-planar, 420f) to a JPEG Data blob.
//

import CoreImage
import ImageIO
import UIKit

enum PixelBufferJPEGError: Error {
    case encodingFailed
}

enum PixelBufferJPEG {

    /// Returns JPEG data rotated into display orientation.
    /// - Parameters:
    ///   - pixelBuffer: ARKit frame.capturedImage, retained by caller.
    ///   - interfaceOrientation: UI orientation at capture time.
    ///   - quality: 0.0 ... 1.0 (0.85 recommended).
    static func jpeg(
        from pixelBuffer: CVPixelBuffer,
        interfaceOrientation: UIInterfaceOrientation,
        quality: CGFloat
    ) throws -> Data {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = ci.oriented(cgImagePropertyOrientation(for: interfaceOrientation))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let data = ctx.jpegRepresentation(
            of: oriented,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else {
            throw PixelBufferJPEGError.encodingFailed
        }
        return data
    }

    /// ARKit captures in sensor orientation (landscape-right natural). Map to display orientation.
    private static func cgImagePropertyOrientation(
        for orientation: UIInterfaceOrientation
    ) -> CGImagePropertyOrientation {
        switch orientation {
        case .portrait:            return .right
        case .portraitUpsideDown:  return .left
        case .landscapeLeft:       return .down    // home button on right
        case .landscapeRight:      return .up      // home button on left (natural)
        case .unknown:             return .right
        @unknown default:          return .right
        }
    }
}
```

(Apple's SDK already provides `CIImage.oriented(_:CGImagePropertyOrientation)`, so no extension is needed.)

- [ ] **Step 2: Build the app**

Run:

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS' -configuration Debug build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. The new file is not yet registered in the project.pbxproj, so it will NOT be compiled — that's fine for this step; we'll register it in Task 4. If build fails for an unrelated reason, investigate.

- [ ] **Step 3: Commit**

```bash
git add app/ios/RTABMapApp/PixelBufferJPEG.swift
git commit -m "ios: add PixelBufferJPEG helper (CVPixelBuffer -> JPEG Data)"
```

---

### Task 3: ManualPhotoStore — file-system lifecycle

**Files:**
- Create: `app/ios/RTABMapApp/ManualPhotoStore.swift`

- [ ] **Step 1: Write the file**

Content of `app/ios/RTABMapApp/ManualPhotoStore.swift`:

```swift
//
//  ManualPhotoStore.swift
//  RTABMapApp
//
//  Owns the Documents/ManualPhotos/<sessionId>/ layout:
//    session.json
//    <filename>.jpg
//    <filename>.json
//

import Foundation
import CommonCrypto

final class ManualPhotoStore {

    static let shared = ManualPhotoStore()

    private let rootFolderName = "ManualPhotos"
    private let sessionFileName = "session.json"
    private let schemaVersion = 1

    private let fm = FileManager.default
    private let writeQueue = DispatchQueue(label: "rtabmap.manualPhoto.write")

    /// Current session id. `nil` until `startNewSession` or `attachSession` is called.
    private(set) var currentSessionId: String?

    // MARK: - Paths

    private var rootURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(rootFolderName, isDirectory: true)
    }

    private func sessionURL(_ sessionId: String) -> URL {
        rootURL.appendingPathComponent(sessionId, isDirectory: true)
    }

    func currentSessionURL() -> URL? {
        guard let id = currentSessionId else { return nil }
        return sessionURL(id)
    }

    private func ensureDir(_ url: URL) throws {
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Session lifecycle

    /// Delete the tmp session folder matching `dbFilename`, then mint a new session folder.
    /// Call this from `newScan()` when the rtabmap tmp DB is wiped.
    @discardableResult
    func startNewSession(dbFilename: String?, appVersion: String) throws -> String {
        try ensureDir(rootURL)

        // Delete any prior folders that point at the same tmp dbFilename (keeps Documents/ tidy).
        if let dbFilename = dbFilename {
            for folder in try existingSessionFolders() {
                if let s = try? readSessionJSON(at: folder), s.dbFilename == dbFilename {
                    try? fm.removeItem(at: folder)
                }
            }
        }

        let id = UUID().uuidString
        let url = sessionURL(id)
        try ensureDir(url)

        let session = SessionJSON(
            sessionId: id,
            createdAt: Date(),
            dbFilename: dbFilename,
            appVersion: appVersion,
            schemaVersion: schemaVersion
        )
        try writeSessionJSON(session, at: url)
        currentSessionId = id
        return id
    }

    /// Re-attach to an existing session folder for a saved DB.
    /// Returns the sessionId if found, else nil.
    @discardableResult
    func attachSession(for dbFilename: String) -> String? {
        guard let folders = try? existingSessionFolders() else { return nil }
        for folder in folders {
            if let s = try? readSessionJSON(at: folder), s.dbFilename == dbFilename {
                currentSessionId = s.sessionId
                return s.sessionId
            }
        }
        currentSessionId = nil
        return nil
    }

    /// When a tmp DB is saved as a new name, update the session.json to point at the new filename.
    func recordSavedDB(filename: String) throws {
        guard let url = currentSessionURL() else { return }
        var s = try readSessionJSON(at: url)
        s.dbFilename = filename
        try writeSessionJSON(s, at: url)
    }

    /// Clear the current session pointer without deleting files (e.g. after opening a saved DB).
    func detach() {
        currentSessionId = nil
    }

    /// Delete the session folder for the given dbFilename (if any).
    func deleteSession(for dbFilename: String) {
        guard let folders = try? existingSessionFolders() else { return }
        for folder in folders {
            if let s = try? readSessionJSON(at: folder), s.dbFilename == dbFilename {
                try? fm.removeItem(at: folder)
                if currentSessionId == s.sessionId { currentSessionId = nil }
            }
        }
    }

    // MARK: - Photo write

    struct WriteResult {
        let jpegURL: URL
        let jsonURL: URL
        let sidecar: PhotoSidecar
    }

    /// Synchronous on an arbitrary queue. Callers should dispatch off the main thread.
    func writePhoto(jpeg: Data, sidecarBuilder: (_ id: String, _ filename: String, _ bytes: Int, _ sha: String) -> PhotoSidecar) throws -> WriteResult {
        guard let sessionId = currentSessionId else {
            throw NSError(domain: "ManualPhotoStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "No active session"])
        }
        let folder = sessionURL(sessionId)
        try ensureDir(folder)

        let shortId = String(UUID().uuidString.prefix(8)).lowercased()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
        df.timeZone = TimeZone(identifier: "UTC")
        let stamp = df.string(from: Date())

        let base = "\(stamp)_\(shortId)"
        let jpegURL = folder.appendingPathComponent("\(base).jpg")
        let jsonURL = folder.appendingPathComponent("\(base).json")

        let sha = sha256Hex(data: jpeg)
        let sidecar = sidecarBuilder(shortId, "\(base).jpg", jpeg.count, sha)
        let jsonData = try PhotoMetadataCodec.encoder().encode(sidecar)

        try atomicWrite(data: jpeg, to: jpegURL)
        try atomicWrite(data: jsonData, to: jsonURL)

        return WriteResult(jpegURL: jpegURL, jsonURL: jsonURL, sidecar: sidecar)
    }

    /// Overwrite the sidecar JSON for an already-saved photo (used by the metadata editor).
    func updateSidecar(_ updated: PhotoSidecar, for jpegURL: URL) throws {
        let jsonURL = jpegURL.deletingPathExtension().appendingPathExtension("json")
        let jsonData = try PhotoMetadataCodec.encoder().encode(updated)
        try atomicWrite(data: jsonData, to: jsonURL)
    }

    func deletePhoto(jpegURL: URL) {
        let jsonURL = jpegURL.deletingPathExtension().appendingPathExtension("json")
        try? fm.removeItem(at: jpegURL)
        try? fm.removeItem(at: jsonURL)
    }

    // MARK: - Read

    struct PhotoEntry {
        let jpegURL: URL
        let sidecar: PhotoSidecar
    }

    /// All photos in the given session folder, newest first.
    func photos(in sessionId: String) -> [PhotoEntry] {
        let url = sessionURL(sessionId)
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        let jpegs = items
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        return jpegs.compactMap { j in
            let sidecarURL = j.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: sidecarURL),
                  let s = try? PhotoMetadataCodec.decoder().decode(PhotoSidecar.self, from: data) else {
                return nil
            }
            return PhotoEntry(jpegURL: j, sidecar: s)
        }
    }

    func currentPhotos() -> [PhotoEntry] {
        guard let id = currentSessionId else { return [] }
        return photos(in: id)
    }

    func currentPhotoCount() -> Int {
        currentPhotos().count
    }

    // MARK: - Helpers

    private func existingSessionFolders() throws -> [URL] {
        guard fm.fileExists(atPath: rootURL.path) else { return [] }
        return try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func readSessionJSON(at folder: URL) throws -> SessionJSON {
        let url = folder.appendingPathComponent(sessionFileName)
        let data = try Data(contentsOf: url)
        return try PhotoMetadataCodec.decoder().decode(SessionJSON.self, from: data)
    }

    private func writeSessionJSON(_ s: SessionJSON, at folder: URL) throws {
        let url = folder.appendingPathComponent(sessionFileName)
        let data = try PhotoMetadataCodec.encoder().encode(s)
        try atomicWrite(data: data, to: url)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.moveItem(at: tmp, to: url)
    }

    private func sha256Hex(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 2: Validate the store lifecycle via a one-shot swift script**

Run (from the repo root). This creates a sandboxed temporary `$HOME` so `FileManager.default.urls(for: .documentDirectory)` resolves into a throwaway directory and does **not** touch your real `~/Documents`:

```bash
SANDBOX=$(mktemp -d)
mkdir -p "$SANDBOX/Documents"
cat > "$SANDBOX/validate_store.swift" <<'SWIFT'
import Foundation
import CommonCrypto

// --- PhotoMetadata.swift (inlined) ---
SWIFT
awk '/^struct SessionJSON/,0' app/ios/RTABMapApp/PhotoMetadata.swift >> "$SANDBOX/validate_store.swift"
echo >> "$SANDBOX/validate_store.swift"
echo "// --- ManualPhotoStore.swift (inlined) ---" >> "$SANDBOX/validate_store.swift"
awk '/^final class ManualPhotoStore/,0' app/ios/RTABMapApp/ManualPhotoStore.swift >> "$SANDBOX/validate_store.swift"
cat >> "$SANDBOX/validate_store.swift" <<'SWIFT'

let store = ManualPhotoStore.shared
let id1 = try store.startNewSession(dbFilename: "rtabmap.tmp.db", appVersion: "test")
assert(store.currentSessionId == id1)
let dummyJPEG = Data(repeating: 0xff, count: 128)
let result = try store.writePhoto(jpeg: dummyJPEG) { shortId, filename, bytes, sha in
    PhotoSidecar(
        id: shortId, sessionId: id1,
        capturedAt: Date(), arkitTimestamp: 1.0,
        camera: CameraMeta(
            transform: [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
            intrinsics: .init(fx: 1, fy: 1, cx: 0, cy: 0),
            imageSize: .init(width: 1, height: 1),
            orientation: "portrait", trackingState: "normal"),
        env: nil, gps: nil,
        file: FileMeta(name: filename, bytes: bytes, sha256: sha),
        user: .empty, schemaVersion: 1)
}
assert(FileManager.default.fileExists(atPath: result.jpegURL.path))
assert(FileManager.default.fileExists(atPath: result.jsonURL.path))
assert(store.currentPhotoCount() == 1)

try store.recordSavedDB(filename: "foo.db")
store.deleteSession(for: "foo.db")
assert(store.currentSessionId == nil)
print("OK")
SWIFT
HOME="$SANDBOX" swift "$SANDBOX/validate_store.swift"
rm -rf "$SANDBOX"
```

Expected output: `OK`. Exit code 0. If it fails, check the `ManualPhotoStore` implementation.

- [ ] **Step 3: Commit**

```bash
git add app/ios/RTABMapApp/ManualPhotoStore.swift
git commit -m "ios: add ManualPhotoStore for session folder + photo persistence"
```

---

### Task 4: Register new Swift files in the Xcode project

**Files:**
- Modify: `app/ios/RTABMapApp.xcodeproj/project.pbxproj`

The pbxproj is sensitive; the safest path is to use `xcodeproj` via Ruby or edit Xcode manually. Since the engineer running this plan has Xcode (required for any iOS build), use Xcode's UI.

- [ ] **Step 1: Add the three new Swift files to the RTABMapApp target**

Open `app/ios/RTABMapApp.xcodeproj` in Xcode. In the left Navigator, right-click the yellow `RTABMapApp` group → **Add Files to "RTABMapApp"…** → multi-select:

- `PhotoMetadata.swift`
- `PixelBufferJPEG.swift`
- `ManualPhotoStore.swift`

Ensure:
- **Destination:** uncheck "Copy items if needed" (they are already in place).
- **Added folders:** "Create groups".
- **Add to targets:** check ☑ `RTABMapApp`.

Click **Add**.

- [ ] **Step 2: Build the app to verify compilation**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`.

If a compile error references missing types, one of the three files didn't get target membership — re-check in Xcode's File Inspector (right panel, "Target Membership" checkbox for `RTABMapApp`).

- [ ] **Step 3: Commit**

```bash
git add app/ios/RTABMapApp.xcodeproj/project.pbxproj
git commit -m "ios: register PhotoMetadata, PixelBufferJPEG, ManualPhotoStore in Xcode target"
```

---

### Task 5: Add PhotoButton to storyboard and outlet

**Files:**
- Modify: `app/ios/RTABMapApp/Base.lproj/Main.storyboard`
- Modify: `app/ios/RTABMapApp/ViewController.swift:110-124`

- [ ] **Step 1: Add the button in Xcode Interface Builder**

Open `Main.storyboard` in Xcode. In the document outline, find the vertical `Stack View` with id `kPv-DO-hpd` (it already contains `StopButton`, `RecordButton`, `AddMeasureButton`, `RemoveMeasureButton`).

1. Drag a new **Button** into this stack between `RecordButton` and `AddMeasureButton`.
2. Set its **User Label** (Identity Inspector) to `PhotoButton`.
3. Attributes Inspector:
   - **Type:** System
   - **Style:** Default
   - **Image:** (background image) — `camera.circle`, SF Symbol
   - **Tint:** White
   - **Image Edge Insets:** zero
4. Size Inspector: add width=60 and height=60 constraints (matching peer buttons).

Save the storyboard.

- [ ] **Step 2: Add the outlet in ViewController.swift**

Edit `app/ios/RTABMapApp/ViewController.swift` and add (keep the exact indentation — these lines sit between the existing `@IBOutlet weak var recordButton` at line 111 and the other outlets):

Find:

```swift
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var menuButton: UIButton!
```

Replace with:

```swift
    @IBOutlet weak var recordButton: UIButton!
    @IBOutlet weak var photoButton: UIButton!
    @IBOutlet weak var menuButton: UIButton!
```

- [ ] **Step 3: Connect the outlet in Xcode**

In Xcode, with `Main.storyboard` open:
1. Select the ViewController scene (`zah-iI-EPt`) in the document outline.
2. Open the Connections Inspector (right panel, arrow icon).
3. Drag from the `photoButton` outlet (under "Outlets") to the new PhotoButton in the canvas.

- [ ] **Step 4: Add the stub action handler**

Edit `app/ios/RTABMapApp/ViewController.swift` near the existing `@IBAction func recordAction(_ sender: UIButton)` at line 2527:

Find:

```swift
    @IBAction func recordAction(_ sender: UIButton) {
        rtabmap?.setPausedMapping(paused: false);
        lowMemoryWarningShown = false
        updateState(state: .STATE_MAPPING)
    }
```

Add immediately after its closing brace:

```swift
    @IBAction func takePhotoAction(_ sender: UIButton) {
        // Implemented in Task 7.
        showToast(message: "Photo capture (stub)", seconds: 1)
    }
```

- [ ] **Step 5: Connect the action in Xcode**

In `Main.storyboard`, right-click the PhotoButton → drag the "Touch Up Inside" event onto the ViewController, select `takePhotoAction:`.

- [ ] **Step 6: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Smoke-run on simulator**

Run the app on the iPhone 15 simulator. Start a new scan. The PhotoButton should appear in the right-side stack. Tapping it should show the "Photo capture (stub)" toast.

- [ ] **Step 8: Commit**

```bash
git add app/ios/RTABMapApp/Base.lproj/Main.storyboard app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: add PhotoButton to scanning toolbar with stub action"
```

---

### Task 6: Visibility rules for PhotoButton in updateState

**Files:**
- Modify: `app/ios/RTABMapApp/ViewController.swift:699-833` (the `switch mState` inside `updateState`)

The PhotoButton must be visible only in `STATE_CAMERA` and `STATE_MAPPING`, and must respect the HUD auto-hide logic during mapping (same `!mHudVisible` pattern as `recordButton`).

- [ ] **Step 1: Update each case**

In `app/ios/RTABMapApp/ViewController.swift`, inside the `switch mState` block of `updateState(state:)` (starts at line 699), add one line per case controlling `photoButton.isHidden`:

Find (inside `case .STATE_CAMERA:`):

```swift
            recordButton.isHidden = false
            stopButton.isHidden = true
```

Replace with:

```swift
            recordButton.isHidden = false
            photoButton.isHidden = false
            stopButton.isHidden = true
```

Find (inside `case .STATE_MAPPING:`):

```swift
            recordButton.isHidden = true
            stopButton.isHidden = false
```

Replace with:

```swift
            recordButton.isHidden = true
            photoButton.isHidden = !mHudVisible
            stopButton.isHidden = false
```

Find (inside `case .STATE_PROCESSING, .STATE_VISUALIZING_WHILE_LOADING, …:`):

```swift
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
```

Replace with:

```swift
            recordButton.isHidden = true
            photoButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
```

Find (inside `case .STATE_VISUALIZING:`):

```swift
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = !mHudVisible
```

Replace with:

```swift
            recordButton.isHidden = true
            photoButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = !mHudVisible
```

Find (inside `default: // IDLE // WELCOME`):

```swift
            recordButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
```

Replace with:

```swift
            recordButton.isHidden = true
            photoButton.isHidden = true
            stopButton.isHidden = true
            closeVisualizationButton.isHidden = true
```

- [ ] **Step 2: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-run**

Run on simulator. Verify the PhotoButton appears in STATE_CAMERA (before tapping Record) and STATE_MAPPING (after tapping Record), and disappears in Welcome / Visualizing states.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: show PhotoButton only during camera and mapping states"
```

---

### Task 7: Implement takePhotoAction — capture and persist

**Files:**
- Modify: `app/ios/RTABMapApp/ViewController.swift` (the `takePhotoAction` stub from Task 5, around line 2532)

- [ ] **Step 1: Replace the stub with the full capture flow**

In `app/ios/RTABMapApp/ViewController.swift`, find:

```swift
    @IBAction func takePhotoAction(_ sender: UIButton) {
        // Implemented in Task 7.
        showToast(message: "Photo capture (stub)", seconds: 1)
    }
```

Replace with:

```swift
    @IBAction func takePhotoAction(_ sender: UIButton) {
        guard let frame = session.currentFrame else {
            showToast(message: "No frame available", seconds: 1)
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        capture(frame: frame)
    }

    private func capture(frame: ARFrame) {
        // Snapshot primitives synchronously before the ARFrame goes stale.
        let arkitTs = frame.timestamp
        let wallClock = Date()
        let t = frame.camera.transform
        let transformRows: [[Float]] = [
            [t[0,0], t[0,1], t[0,2], t[0,3]],
            [t[1,0], t[1,1], t[1,2], t[1,3]],
            [t[2,0], t[2,1], t[2,2], t[2,3]],
            [t[3,0], t[3,1], t[3,2], t[3,3]],
        ]
        let intr = frame.camera.intrinsics
        let imageSize = frame.camera.imageResolution
        let lightAmbient = frame.lightEstimate?.ambientIntensity.map(Double.init)
        let trackingState = trackingStateString(frame.camera.trackingState)
        let orientation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation ?? .portrait
        let orientationStr = orientationString(orientation)

        let includeGPS = UserDefaults.standard.object(forKey: "PhotoIncludeGPS") as? Bool ?? true
        let gps: GPSMeta? = {
            guard includeGPS, let loc = mLastKnownLocation else { return nil }
            return GPSMeta(
                lat: loc.coordinate.latitude,
                lon: loc.coordinate.longitude,
                alt: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                hAcc: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil,
                vAcc: loc.verticalAccuracy >= 0 ? loc.verticalAccuracy : nil
            )
        }()

        let jpegQualityRaw = UserDefaults.standard.object(forKey: "PhotoJPEGQuality") as? Double ?? 0.85
        let jpegQuality = CGFloat(max(0.5, min(1.0, jpegQualityRaw)))

        // Retain the pixel buffer for use on the background queue.
        let pb = frame.capturedImage
        let retained = Unmanaged.passRetained(pb)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { retained.release() }
            let buffer = retained.takeUnretainedValue()
            do {
                let jpeg = try PixelBufferJPEG.jpeg(from: buffer, interfaceOrientation: orientation, quality: jpegQuality)

                // Ensure a session exists (auto-start if the user hasn't triggered newScan yet).
                if ManualPhotoStore.shared.currentSessionId == nil {
                    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                    _ = try ManualPhotoStore.shared.startNewSession(dbFilename: self.RTABMAP_TMP_DB, appVersion: appVersion)
                }

                let sessionId = ManualPhotoStore.shared.currentSessionId ?? ""
                let result = try ManualPhotoStore.shared.writePhoto(jpeg: jpeg) { shortId, filename, bytes, sha in
                    PhotoSidecar(
                        id: shortId,
                        sessionId: sessionId,
                        capturedAt: wallClock,
                        arkitTimestamp: arkitTs,
                        camera: CameraMeta(
                            transform: transformRows,
                            intrinsics: .init(fx: intr[0,0], fy: intr[1,1], cx: intr[2,0], cy: intr[2,1]),
                            imageSize: .init(width: Int(imageSize.width), height: Int(imageSize.height)),
                            orientation: orientationStr,
                            trackingState: trackingState
                        ),
                        env: EnvMeta(ambientIntensity: lightAmbient),
                        gps: gps,
                        file: FileMeta(name: filename, bytes: bytes, sha256: sha),
                        user: .empty,
                        schemaVersion: 1
                    )
                }
                DispatchQueue.main.async {
                    self.showToast(message: "Photo saved", seconds: 1)
                    self.presentPhotoEditor(for: result) // Implemented in Task 9; safe no-op until then.
                }
            } catch {
                DispatchQueue.main.async {
                    self.showToast(message: "Failed to save photo: \(error.localizedDescription)", seconds: 3)
                }
            }
        }
    }

    private func trackingStateString(_ s: ARCamera.TrackingState) -> String {
        switch s {
        case .normal: return "normal"
        case .notAvailable: return "notAvailable"
        case .limited(.initializing): return "limitedInitializing"
        case .limited(.relocalizing): return "limitedRelocalizing"
        case .limited(.excessiveMotion): return "limitedExcessiveMotion"
        case .limited(.insufficientFeatures): return "limitedInsufficientFeatures"
        @unknown default: return "unknown"
        }
    }

    private func orientationString(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private func presentPhotoEditor(for result: ManualPhotoStore.WriteResult) {
        // Wired up in Task 9. No-op for now.
    }
```

- [ ] **Step 2: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

If the build complains that `intrinsics[2,0]` / `intrinsics[2,1]` are wrong, note ARKit's `intrinsics` is a `simd_float3x3` indexed as `[col, row]`. The fields `fx=[0][0]`, `fy=[1][1]`, `cx=[2][0]`, `cy=[2][1]` match the existing odometry call site at `RTABMap.swift:358-361` — preserve that exact indexing.

- [ ] **Step 3: Smoke-run on a real device (simulator has no ARKit)**

Deploy to a device that supports ARKit. Start a new scan → tap PhotoButton. Expected:
- Haptic tap.
- Toast: "Photo saved".
- A new `.jpg` + `.json` pair under `Documents/ManualPhotos/<uuid>/` (inspect via Xcode → Window → Devices and Simulators → the device → your app → Download Container). Also a `session.json`.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: implement manual photo capture from ARSession.currentFrame"
```

---

### Task 8: PhotoMetadataEditor view controller

**Files:**
- Create: `app/ios/RTABMapApp/PhotoMetadataEditor.swift`

- [ ] **Step 1: Write the file**

Content of `app/ios/RTABMapApp/PhotoMetadataEditor.swift`:

```swift
//
//  PhotoMetadataEditor.swift
//  RTABMapApp
//
//  Programmatic modal for editing a PhotoSidecar's user metadata.
//

import UIKit

protocol PhotoMetadataEditorDelegate: AnyObject {
    func editor(_ editor: PhotoMetadataEditor, didSave sidecar: PhotoSidecar, at jpegURL: URL)
    func editor(_ editor: PhotoMetadataEditor, didDelete jpegURL: URL)
}

final class PhotoMetadataEditor: UIViewController, UITableViewDataSource, UITableViewDelegate {

    weak var delegate: PhotoMetadataEditorDelegate?

    private let jpegURL: URL
    private var sidecar: PhotoSidecar

    private let thumbnailView = UIImageView()
    private let labelField = UITextField()
    private let noteView = UITextView()
    private let tagsField = UITextField()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private static let suggestedKeys = [
        "dimensions.length_mm", "dimensions.width_mm", "dimensions.height_mm",
        "condition",
        "origin.building", "origin.year",
        "material",
        "contamination.pfas", "contamination.asbestos",
        "certification"
    ]

    init(jpegURL: URL, sidecar: PhotoSidecar) {
        self.jpegURL = jpegURL
        self.sidecar = sidecar
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Delete", style: .plain, target: self, action: #selector(deleteTapped))
        navigationItem.leftBarButtonItem?.tintColor = .systemRed
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        navigationItem.title = "Photo metadata"

        thumbnailView.contentMode = .scaleAspectFit
        thumbnailView.clipsToBounds = true
        thumbnailView.image = UIImage(contentsOfFile: jpegURL.path)

        labelField.placeholder = "Label (optional)"
        labelField.borderStyle = .roundedRect
        labelField.text = sidecar.user.label

        noteView.layer.borderColor = UIColor.separator.cgColor
        noteView.layer.borderWidth = 1
        noteView.layer.cornerRadius = 6
        noteView.font = .preferredFont(forTextStyle: .body)
        noteView.text = sidecar.user.note

        tagsField.placeholder = "Tags (comma-separated)"
        tagsField.borderStyle = .roundedRect
        tagsField.text = sidecar.user.tags.joined(separator: ", ")

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "prop")

        let stack = UIStackView(arrangedSubviews: [thumbnailView, labelField, noteView, tagsField, tableView])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            thumbnailView.heightAnchor.constraint(equalToConstant: 200),
            noteView.heightAnchor.constraint(equalToConstant: 80),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        sidecar.user.label = labelField.text ?? ""
        sidecar.user.note = noteView.text ?? ""
        sidecar.user.tags = (tagsField.text ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try ManualPhotoStore.shared.updateSidecar(sidecar, for: jpegURL)
            delegate?.editor(self, didSave: sidecar, at: jpegURL)
            dismiss(animated: true)
        } catch {
            let alert = UIAlertController(title: "Save failed", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(.init(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(title: "Delete photo?", message: nil, preferredStyle: .alert)
        alert.addAction(.init(title: "Cancel", style: .cancel))
        alert.addAction(.init(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            ManualPhotoStore.shared.deletePhoto(jpegURL: self.jpegURL)
            self.delegate?.editor(self, didDelete: self.jpegURL)
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? { "Properties" }

    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int {
        sidecar.user.properties.count + 1 // +1 for the "Add property" row
    }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "prop", for: ip)
        cell.accessoryType = .none
        cell.selectionStyle = .default
        if ip.row < sidecar.user.properties.count {
            let p = sidecar.user.properties[ip.row]
            let unit = p.unit.map { " \($0)" } ?? ""
            cell.textLabel?.text = "\(p.key): \(p.value)\(unit)"
            cell.textLabel?.textColor = .label
        } else {
            cell.textLabel?.text = "+ Add property"
            cell.textLabel?.textColor = .systemBlue
        }
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        if ip.row < sidecar.user.properties.count {
            editProperty(at: ip.row)
        } else {
            addProperty()
        }
    }

    func tableView(_ tv: UITableView, canEditRowAt ip: IndexPath) -> Bool {
        ip.row < sidecar.user.properties.count
    }

    func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt ip: IndexPath) {
        guard editingStyle == .delete, ip.row < sidecar.user.properties.count else { return }
        sidecar.user.properties.remove(at: ip.row)
        tv.deleteRows(at: [ip], with: .automatic)
    }

    // MARK: - Property editing

    private func addProperty() {
        presentPropertyEditor(existing: nil) { [weak self] new in
            guard let self = self, let new = new else { return }
            self.sidecar.user.properties.append(new)
            self.tableView.reloadData()
        }
    }

    private func editProperty(at index: Int) {
        let current = sidecar.user.properties[index]
        presentPropertyEditor(existing: current) { [weak self] updated in
            guard let self = self, let updated = updated else { return }
            self.sidecar.user.properties[index] = updated
            self.tableView.reloadData()
        }
    }

    private func presentPropertyEditor(existing: UserProperty?, completion: @escaping (UserProperty?) -> Void) {
        let alert = UIAlertController(title: existing == nil ? "Add property" : "Edit property", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "key (e.g. dimensions.length_mm)"; $0.text = existing?.key }
        alert.addTextField { $0.placeholder = "value";                             $0.text = existing?.value }
        alert.addTextField { $0.placeholder = "unit (optional)";                   $0.text = existing?.unit }

        let suggestAction = UIAlertAction(title: "Suggested key…", style: .default) { [weak alert] _ in
            let menu = UIAlertController(title: "Suggested keys", message: nil, preferredStyle: .actionSheet)
            for k in Self.suggestedKeys {
                menu.addAction(.init(title: k, style: .default) { _ in
                    alert?.textFields?[0].text = k
                })
            }
            menu.addAction(.init(title: "Cancel", style: .cancel))
            self.present(menu, animated: true)
        }
        alert.addAction(suggestAction)
        alert.addAction(.init(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(.init(title: existing == nil ? "Add" : "Save", style: .default) { _ in
            let key = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""
            let value = alert.textFields?[1].text ?? ""
            let unit = alert.textFields?[2].text?.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { completion(nil); return }
            completion(UserProperty(key: key, value: value, unit: (unit?.isEmpty ?? true) ? nil : unit))
        })
        present(alert, animated: true)
    }
}
```

- [ ] **Step 2: Register the file in the Xcode target**

In Xcode: right-click `RTABMapApp` group → Add Files to "RTABMapApp"… → `PhotoMetadataEditor.swift` → ensure target membership for `RTABMapApp` is checked.

- [ ] **Step 3: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/PhotoMetadataEditor.swift app/ios/RTABMapApp.xcodeproj/project.pbxproj
git commit -m "ios: add PhotoMetadataEditor view controller for per-photo user metadata"
```

---

### Task 9: Wire editor presentation after capture

**Files:**
- Modify: `app/ios/RTABMapApp/ViewController.swift` (the `presentPhotoEditor(for:)` placeholder from Task 7)

- [ ] **Step 1: Replace the placeholder**

In `ViewController.swift`, find:

```swift
    private func presentPhotoEditor(for result: ManualPhotoStore.WriteResult) {
        // Wired up in Task 9. No-op for now.
    }
```

Replace with:

```swift
    private func presentPhotoEditor(for result: ManualPhotoStore.WriteResult) {
        let editor = PhotoMetadataEditor(jpegURL: result.jpegURL, sidecar: result.sidecar)
        editor.delegate = self
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }
```

- [ ] **Step 2: Conform ViewController to PhotoMetadataEditorDelegate**

At the very bottom of `ViewController.swift`, after the final `extension UserDefaults` block, add:

```swift
extension ViewController: PhotoMetadataEditorDelegate {
    func editor(_ editor: PhotoMetadataEditor, didSave sidecar: PhotoSidecar, at jpegURL: URL) {
        // No-op; the gallery (Task 10) will refresh on next appearance.
    }
    func editor(_ editor: PhotoMetadataEditor, didDelete jpegURL: URL) {
        // No-op; the gallery refresh covers this too.
    }
}
```

- [ ] **Step 3: Build and run on device**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

Deploy to device, start a scan, tap PhotoButton. Expected: editor sheet appears; set a label + note + a "condition" property → Done → toast and sheet dismisses. Re-tap → capture another → dismiss without Done → previous photo's metadata is still saved.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: present PhotoMetadataEditor after manual photo capture"
```

---

### Task 10: ManualPhotoGalleryViewController

**Files:**
- Create: `app/ios/RTABMapApp/ManualPhotoGalleryViewController.swift`

- [ ] **Step 1: Write the file**

Content of `app/ios/RTABMapApp/ManualPhotoGalleryViewController.swift`:

```swift
//
//  ManualPhotoGalleryViewController.swift
//  RTABMapApp
//
//  Grid of photos in the current ManualPhotoStore session.
//

import UIKit

final class ManualPhotoGalleryViewController: UICollectionViewController, PhotoMetadataEditorDelegate {

    private var entries: [ManualPhotoStore.PhotoEntry] = []
    private let thumbCache = NSCache<NSURL, UIImage>()

    init() {
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 100, height: 100)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        super.init(collectionViewLayout: layout)
        title = "Manual Photos"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.register(ThumbCell.self, forCellWithReuseIdentifier: "thumb")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        entries = ManualPhotoStore.shared.currentPhotos()
        title = "Manual Photos (\(entries.count))"
        collectionView.reloadData()
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    // MARK: - CollectionView

    override func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        entries.count
    }

    override func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: "thumb", for: ip) as! ThumbCell
        let entry = entries[ip.item]
        let key = entry.jpegURL as NSURL
        if let cached = thumbCache.object(forKey: key) {
            cell.imageView.image = cached
        } else {
            cell.imageView.image = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let full = UIImage(contentsOfFile: entry.jpegURL.path) {
                    let thumb = Self.downsample(full, to: CGSize(width: 200, height: 200))
                    self.thumbCache.setObject(thumb, forKey: key)
                    DispatchQueue.main.async {
                        if cv.indexPath(for: cell) == ip { cell.imageView.image = thumb }
                    }
                }
            }
        }
        return cell
    }

    override func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        let entry = entries[ip.item]
        let editor = PhotoMetadataEditor(jpegURL: entry.jpegURL, sidecar: entry.sidecar)
        editor.delegate = self
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    // MARK: - Editor delegate

    func editor(_ editor: PhotoMetadataEditor, didSave sidecar: PhotoSidecar, at jpegURL: URL) { reload() }
    func editor(_ editor: PhotoMetadataEditor, didDelete jpegURL: URL) {
        thumbCache.removeObject(forKey: jpegURL as NSURL)
        reload()
    }

    // MARK: - Helpers

    private static func downsample(_ image: UIImage, to target: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private final class ThumbCell: UICollectionViewCell {
        let imageView = UIImageView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .secondarySystemBackground
            imageView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
                imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }
    }
}
```

- [ ] **Step 2: Register in Xcode target**

Add `ManualPhotoGalleryViewController.swift` to the `RTABMapApp` target (Add Files in Xcode, target membership ☑).

- [ ] **Step 3: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/ManualPhotoGalleryViewController.swift app/ios/RTABMapApp.xcodeproj/project.pbxproj
git commit -m "ios: add ManualPhotoGalleryViewController"
```

---

### Task 11: Hook the gallery into the app's hamburger menu

**Files:**
- Modify: `app/ios/RTABMapApp/ViewController.swift` — the File submenu assembly inside `updateState(state:)`, around lines 950–981.

The menu is assembled every time `updateState(state:)` runs. The `fileMenuChildren: [UIMenuElement]` array is built piece by piece, then wrapped as `let fileMenu = UIMenu(title: "File", options: .displayInline, children: fileMenuChildren)` at line 984, and the final assembly is `menuButton.menu = UIMenu(title: "", children: [fileMenu, settingsMenu])` at line 1046. We add a "Manual Photos (N)" item to `fileMenuChildren`, just before `advancedMenu` is appended.

- [ ] **Step 1: Add the menu item**

In `ViewController.swift`, find (around line 981):

```swift
        fileMenuChildren.append(advancedMenu)
        
        // File menu
        let fileMenu = UIMenu(title: "File", options: .displayInline, children: fileMenuChildren)
```

Replace with:

```swift
        let photoCount = ManualPhotoStore.shared.currentPhotoCount()
        fileMenuChildren.append(UIAction(
            title: "Manual Photos (\(photoCount))",
            image: UIImage(systemName: "photo.on.rectangle"),
            handler: { [weak self] _ in
                guard let self = self else { return }
                let gallery = ManualPhotoGalleryViewController()
                let nav = UINavigationController(rootViewController: gallery)
                nav.modalPresentationStyle = .formSheet
                self.present(nav, animated: true)
            }
        ))
        fileMenuChildren.append(advancedMenu)
        
        // File menu
        let fileMenu = UIMenu(title: "File", options: .displayInline, children: fileMenuChildren)
```

- [ ] **Step 2: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-run**

On device: start a scan → capture 2 photos → open hamburger menu → see "Manual Photos (2)" under the File group → tap → gallery shows thumbnails. Tap a thumbnail → editor; change a field → Done → gallery updates.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: add Manual Photos gallery entry to main menu"
```

---

### Task 12: Lifecycle hooks — newScan, save, open, delete

**Files:**
- Modify: `app/ios/RTABMapApp/ViewController.swift`

The ManualPhotoStore must follow the rtabmap DB lifecycle.

- [ ] **Step 1: Start a new photo session in `newScan`**

In `ViewController.swift`, find the end of `newScan(dataRecordingMode:)` — specifically the `else` branch at line 1744 onward that opens a fresh tmp DB:

```swift
            self.rtabmap!.openDatabase(databasePath: tmpDatabase.path, databaseInMemory: inMemory, optimize: false, clearDatabase: true)
```

Immediately after that line, add:

```swift
            do {
                let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                _ = try ManualPhotoStore.shared.startNewSession(dbFilename: self.RTABMAP_TMP_DB, appVersion: appVersion)
            } catch {
                print("ManualPhotoStore.startNewSession failed: \(error)")
            }
```

Also, in the recovery path (the "Ignore" branch that calls `FileManager.default.removeItem(at: tmpDatabase)` at line 1650), add right after the `removeItem`:

```swift
                    ManualPhotoStore.shared.deleteSession(for: self.RTABMAP_TMP_DB)
```

- [ ] **Step 2: Record the saved filename in `saveDatabase`**

In `saveDatabase(fileName:)`, find (around line 1870):

```swift
                let tmpDatabase = self.getDocumentDirectory().appendingPathComponent(self.RTABMAP_TMP_DB)
                try FileManager.default.removeItem(at: tmpDatabase)
```

Add immediately before the `try FileManager.default.removeItem(at: tmpDatabase)`:

```swift
                try? ManualPhotoStore.shared.recordSavedDB(filename: fileName)
```

- [ ] **Step 3: Attach the session when opening a saved DB**

In `openDatabase(fileUrl:)` at the top (around line 2180), after `openedDatabasePath = fileUrl`:

```swift
        let _ = ManualPhotoStore.shared.attachSession(for: fileUrl.lastPathComponent)
```

If `attachSession` returns `nil`, that's fine — it just means no manual photos exist for this DB, and the gallery will show 0.

- [ ] **Step 4: Delete the session folder when the DB is deleted**

In `databaseDeleted(databaseURL:)` (around line 2732), right after `try FileManager.default.removeItem(at: databaseURL)`:

```swift
            ManualPhotoStore.shared.deleteSession(for: databaseURL.lastPathComponent)
```

- [ ] **Step 5: Detach on `newScanAction` welcome / close visualization**

No code change required — `startNewSession` in `newScan` already overrides the current session pointer.

- [ ] **Step 6: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Smoke-run — full lifecycle**

On device:
1. New scan → capture 1 photo.
2. Stop → Save as `test1` → gallery still shows 1 photo.
3. Library → open `test1.db` → gallery shows 1 photo.
4. New scan → capture 1 photo → gallery shows 1 (only the new one).
5. Library → open `test1.db` → gallery again shows the original 1 photo.
6. Library → delete `test1.db` → gallery shows 0.

- [ ] **Step 8: Commit**

```bash
git add app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: wire ManualPhotoStore into scan/save/open/delete lifecycle"
```

---

### Task 13: Include photo folder in export zip

**Files:**
- Modify: `app/ios/RTABMapApp/ViewController.swift` — inside `writeExportedFiles(fileName:)` (around line 2395 where zipping happens)

- [ ] **Step 1: Add photos to the export staging dir**

In `writeExportedFiles`, find (around line 2397):

```swift
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
                        if(!fileURLs.isEmpty)
                        {
                            if(isLAZ)
```

Replace with:

```swift
                        // Copy manual photos into the export dir if enabled and not LAZ export.
                        let includePhotos = UserDefaults.standard.object(forKey: "PhotoIncludeInExport") as? Bool ?? true
                        if includePhotos, let photosFolder = ManualPhotoStore.shared.currentSessionURL(),
                           FileManager.default.fileExists(atPath: photosFolder.path) {
                            let destination = exportDir.appendingPathComponent("manual_photos")
                            do {
                                try FileManager.default.copyItem(at: photosFolder, to: destination)
                                print("Copied manual photos folder into export staging")
                            } catch {
                                print("Failed to copy manual photos into export: \(error)")
                            }
                        }

                        let fileURLs = try FileManager.default.contentsOfDirectory(at: exportDir, includingPropertiesForKeys: nil)
                        if(!fileURLs.isEmpty)
                        {
                            if(isLAZ)
```

Note: the `isLAZ` branch handles the single-file LAZ export case and bypasses zipping; manual photos are only bundled in the zip path (which matches "Export OBJ/PLY" flows). The LAZ path intentionally remains photo-free — LAZ is a single point-cloud file, not an archive.

- [ ] **Step 2: Build**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-run**

On device: scan → take 2 photos → stop → Export OBJ → unzip the resulting `.zip` (via Files app or Airdrop to Mac). Expected: `manual_photos/<sessionId>/` with session.json + jpg/json pairs.

- [ ] **Step 4: Commit**

```bash
git add app/ios/RTABMapApp/ViewController.swift
git commit -m "ios: include manual photos folder in export zip when enabled"
```

---

### Task 14: Settings bundle entries

**Files:**
- Modify: `app/ios/Settings.bundle/Mapping.plist`

- [ ] **Step 1: Add three new PreferenceSpecifiers**

Open `app/ios/Settings.bundle/Mapping.plist` in Xcode (or as plaintext XML). Locate the closing `</array></dict></plist>` at the bottom. Insert, before the closing `</array>`:

```xml
		<dict>
			<key>Type</key>
			<string>PSGroupSpecifier</string>
			<key>Title</key>
			<string>Manual Photos</string>
			<key>FooterText</key>
			<string>Manual photos are saved alongside the database. Taps of the camera button during a scan capture a still with pose, intrinsics, and optional GPS.</string>
		</dict>
		<dict>
			<key>Type</key>
			<string>PSSliderSpecifier</string>
			<key>Key</key>
			<string>PhotoJPEGQuality</string>
			<key>Title</key>
			<string>Photo JPEG Quality</string>
			<key>DefaultValue</key>
			<real>0.85</real>
			<key>MinimumValue</key>
			<real>0.5</real>
			<key>MaximumValue</key>
			<real>1.0</real>
		</dict>
		<dict>
			<key>Type</key>
			<string>PSToggleSwitchSpecifier</string>
			<key>Key</key>
			<string>PhotoIncludeGPS</string>
			<key>Title</key>
			<string>Include GPS in Photo Metadata</string>
			<key>DefaultValue</key>
			<true/>
		</dict>
		<dict>
			<key>Type</key>
			<string>PSToggleSwitchSpecifier</string>
			<key>Key</key>
			<string>PhotoIncludeInExport</string>
			<key>Title</key>
			<string>Include Photos in Export Zip</string>
			<key>DefaultValue</key>
			<true/>
		</dict>
```

- [ ] **Step 2: Verify plist parses**

```bash
plutil -lint /Users/ttt/projects/rtabmap/app/ios/Settings.bundle/Mapping.plist
```

Expected: `Mapping.plist: OK`.

- [ ] **Step 3: Build and smoke**

```bash
cd /Users/ttt/projects/rtabmap
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp -destination 'generic/platform=iOS Simulator,name=iPhone 15' -configuration Debug build 2>&1 | tail -30
```

Expected: `** BUILD SUCCEEDED **`. Then: run app → iOS Settings → RTAB-Map → Mapping → scroll to "Manual Photos" → see slider + two toggles. Change the quality slider to 0.5 and take a photo → verify file size is smaller.

- [ ] **Step 4: Commit**

```bash
git add app/ios/Settings.bundle/Mapping.plist
git commit -m "ios: add Manual Photos settings (JPEG quality, include GPS, include in export)"
```

---

### Task 15: Error-path sanity checks

**Files:** none — verification-only.

- [ ] **Step 1: Exercise the error paths on device**

Run each of these manually on device and confirm the behavior:

1. **No active frame:** Open app, reach Welcome state (no `ARSession.currentFrame`). The button is hidden per Task 6, so this path is not user-reachable — noted for code review.
2. **Disk-full simulation:** Fill device storage (or truncate sandbox) → tap PhotoButton → toast "Failed to save photo: ...". App does not crash.
3. **GPS disabled:** Toggle "Include GPS in Photo Metadata" off → capture → inspect sidecar → no `gps` key.
4. **Tracking limited:** Cover the camera until tracking state becomes `limited(.insufficientFeatures)` → capture → sidecar's `camera.trackingState` is `"limitedInsufficientFeatures"`.
5. **Orientation:** Lock rotation off. Capture in portrait, landscape left, landscape right. Each saved JPEG previews right-side-up in the gallery.

If any of these reveal a bug, fix it before proceeding.

- [ ] **Step 2: No commit** unless a bug is fixed — in which case, commit that fix with a clear message.

---

### Task 16: Full acceptance walkthrough

**Files:** none — verification-only. Executes all 10 scenarios from the spec.

- [ ] **Step 1: Fresh-install acceptance**

Delete the app from device. Re-install. Run through each of the 10 spec scenarios:

1. Fresh install → new scan → Record → tap PhotoButton → `.jpg` + `.json` pair under `Documents/ManualPhotos/<uuid>/`.
2. Set label, note, one tag, two properties → Done → re-open from gallery → persisted.
3. Stop → Save DB as `test1` → Library → open `test1.db` → gallery lists the photos; editor still works.
4. New scan → first session's photos are not visible in the new session's gallery.
5. Delete a photo from gallery → `.jpg` and `.json` both gone.
6. Export with `PhotoIncludeInExport=YES` → zip contains `manual_photos/<files>`.
7. Export with `PhotoIncludeInExport=NO` → zip omits the folder.
8. Disable Include GPS → capture → sidecar has no `gps` field.
9. Rotate to landscape → capture → preview and saved JPEG are right-side-up.
10. Capture while tracking is `limited(.relocalizing)` → photo still saves; sidecar records `trackingState: "limitedRelocalizing"`.

Any failing scenario means a bug — fix, commit, and re-run.

- [ ] **Step 2: Final commit if any fixes were needed**

```bash
git status
git commit -am "ios: manual photo capture — acceptance fixes"   # only if there were fixes
```

- [ ] **Step 3: Confirm clean tree**

```bash
git -C /Users/ttt/projects/rtabmap status
git -C /Users/ttt/projects/rtabmap log --oneline -20
```

Expected: clean working tree; last ~13 commits on master match Tasks 1–15.
