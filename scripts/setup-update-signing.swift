#!/usr/bin/env swift
// Ed25519 keys for Sparkle archives and feeds. This does not change code signing.
import CryptoKit
import Foundation
import Darwin

enum SetupError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let text): return text } }
}

func writeNewFile(_ data: Data, to path: URL, mode: mode_t) throws {
    let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw SetupError.message("Cannot create signing file safely: \(path.lastPathComponent)") }
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
        var written = 0
        while written < bytes.count {
            let count = write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SetupError.message("Could not write signing file.") }
            written += count
        }
    }
    guard fsync(descriptor) == 0 else { throw SetupError.message("Could not sync signing file.") }
}

func checkedData(at path: URL, privateFile: Bool) throws -> Data {
    let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SetupError.message("Cannot open signing file safely: \(path.lastPathComponent)") }
    defer { close(descriptor) }
    var details = stat()
    guard fstat(descriptor, &details) == 0,
          details.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
          details.st_uid == getuid(), details.st_size > 0, details.st_size <= 128 else {
        throw SetupError.message("Signing files must be small regular files owned by this user.")
    }
    if privateFile && details.st_mode & mode_t(0o077) != 0 {
        throw SetupError.message("Private update key must have permissions 0600; refusing to use a shared key file.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    return try handle.readToEnd() ?? Data()
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let checkOnly = args.contains("--check")
    let remaining = args.filter { $0 != "--check" }
    let directory: URL
    if remaining.isEmpty {
        directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GigaFlow/UpdateSigning", isDirectory: true)
    } else if remaining.count == 2 && remaining[0] == "--directory" && remaining[1].hasPrefix("/") {
        directory = URL(fileURLWithPath: remaining[1], isDirectory: true)
    } else {
        throw SetupError.message("Usage: setup-update-signing.swift [--check] [--directory /absolute/path]")
    }
    let manager = FileManager.default
    let privatePath = directory.appendingPathComponent("private-key.base64")
    let publicPath = directory.appendingPathComponent("public-key.base64")
    if !manager.fileExists(atPath: directory.path) {
        guard !checkOnly else { throw SetupError.message("Update signing identity is missing; run setup once before building a release.") }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }
    var directoryInfo = stat()
    guard lstat(directory.path, &directoryInfo) == 0,
          directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), directoryInfo.st_uid == getuid() else {
        throw SetupError.message("UpdateSigning must be a real directory owned by this user.")
    }
    guard directoryInfo.st_mode & mode_t(0o077) == 0 else {
        throw SetupError.message("UpdateSigning directory must have permissions 0700.")
    }
    let key: Curve25519.Signing.PrivateKey
    if manager.fileExists(atPath: privatePath.path) {
        let data = try checkedData(at: privatePath, privateFile: true)
        guard let encoded = String(data: data, encoding: .utf8),
              let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else {
            throw SetupError.message("Existing private update key is invalid; it has not been replaced.")
        }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    } else {
        guard !checkOnly && !manager.fileExists(atPath: publicPath.path) else {
            throw SetupError.message("Private update key is missing. Restore it from backup; a replacement would break existing clients.")
        }
        key = Curve25519.Signing.PrivateKey()
        try writeNewFile(Data((key.rawRepresentation.base64EncodedString() + "\n").utf8),
                         to: privatePath, mode: 0o600)
    }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    if manager.fileExists(atPath: publicPath.path) {
        let stored = try checkedData(at: publicPath, privateFile: false)
        guard String(data: stored, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == publicKey else {
            throw SetupError.message("Stored public update key does not match its private key; neither file was replaced.")
        }
    } else {
        guard !checkOnly else { throw SetupError.message("Public update key file is missing; run setup to restore it from the existing private key.") }
        try writeNewFile(Data((publicKey + "\n").utf8), to: publicPath, mode: 0o644)
    }
    // Only public material is ever printed, including on repeat invocation.
    print(publicKey)
} catch {
    fputs("Update signing setup: \(error)\n", stderr)
    exit(1)
}
