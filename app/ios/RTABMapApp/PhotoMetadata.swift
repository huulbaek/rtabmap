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
