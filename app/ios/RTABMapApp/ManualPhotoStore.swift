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
