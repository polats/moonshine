//
//  WhiskyWineInstaller.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import CryptoKit
import Foundation
import SemanticVersion

public class WhiskyWineInstaller {
    /// The Whisky application folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: Bundle.whiskyBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    /// Pinned Gcenx Wine Staging release and its SHA-256 (from the GitHub release asset digest)
    public static let wineDownloadURL = URL(
        string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/"
            + "11.18/wine-staging-11.18-osx64.tar.xz"
    )
    static let wineSHA256 = "b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127"
    static let wineVersion = SemanticVersion(11, 18, 0)

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    public static func install(from: URL) {
        do {
            let digest = SHA256.hash(data: try Data(contentsOf: from, options: .mappedIfSafe))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == wineSHA256 else {
                print("Wine download checksum mismatch: expected \(wineSHA256), got \(actual)")
                try? FileManager.default.removeItem(at: from)
                return
            }

            if !FileManager.default.fileExists(atPath: applicationFolder.path) {
                try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            } else {
                // Recreate it
                try FileManager.default.removeItem(at: applicationFolder)
                try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            }

            try Tar.untar(tarBall: from, toURL: applicationFolder)
            try FileManager.default.removeItem(at: from)

            // Handle Gcenx tarball structure:
            // Extracts to "Wine Staging.app/Contents/Resources/wine/{bin,lib,share}"
            // but we need "Libraries/Wine/{bin,lib,share}"
            let gcenxWineRoot = applicationFolder
                .appending(path: "Wine Staging.app")
                .appending(path: "Contents")
                .appending(path: "Resources")
                .appending(path: "wine")

            if FileManager.default.fileExists(atPath: gcenxWineRoot.path) {
                let wineDir = libraryFolder.appending(path: "Wine")
                try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: gcenxWineRoot, to: wineDir)

                // Clean up the extracted app bundle
                let gcenxAppBundle = applicationFolder.appending(path: "Wine Staging.app")
                try FileManager.default.removeItem(at: gcenxAppBundle)
            }

            // Write WhiskyWineVersion.plist so isWhiskyWineInstalled() returns true
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")
            let versionInfo = WhiskyWineVersion(version: wineVersion)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(versionInfo)
            try data.write(to: versionPlist)

            // Apply OpenGL patch to winemac.so
            applyOpenGLPatch()
        } catch {
            print("Failed to install WhiskyWine: \(error)")
        }
    }

    /// Patches winemac.so to enable OpenGL 3.2+ context creation for wined3d (D3D10/11) and SDL3 games.
    /// macdrv rejects 3.2+ contexts unless the caller sets the forward-compatible flag, which wined3d does
    /// not, so D3D11 falls back to a legacy 2.1 context and fails. The patch turns the `je` guarding that
    /// rejection into a `jmp`. The offset is specific to the pinned build, so both bytes are checked first.
    private static func applyOpenGLPatch() {
        let winemacPath = libraryFolder
            .appending(path: "Wine")
            .appending(path: "lib")
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
            .appending(path: "winemac.so")

        guard FileManager.default.fileExists(atPath: winemacPath.path) else {
            print("winemac.so not found, skipping OpenGL patch")
            return
        }

        let patchOffset: UInt64 = 0x318dd
        let original = Data([0x74, 0x1c])
        let patched = Data([0xEB, 0x1c])

        do {
            let fileHandle = try FileHandle(forUpdating: winemacPath)
            defer { try? fileHandle.close() }

            try fileHandle.seek(toOffset: patchOffset)
            let current = try fileHandle.read(upToCount: original.count) ?? Data()

            if current == patched {
                print("OpenGL patch already applied")
                return
            }
            guard current == original else {
                print("Unexpected bytes \(current.map { String(format: "%02x", $0) }) at patch offset, skipping patch")
                return
            }

            try fileHandle.seek(toOffset: patchOffset)
            try fileHandle.write(contentsOf: patched)
            try fileHandle.close()

            // Editing the binary invalidates its ad-hoc signature, so re-sign it
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--force", "--sign", "-", winemacPath.path(percentEncoded: false)]
            try codesign.run()
            codesign.waitUntilExit()
            print("OpenGL patch applied successfully")
        } catch {
            print("Failed to apply OpenGL patch: \(error)")
        }
    }

    public static func uninstall() {
        do {
            try FileManager.default.removeItem(at: libraryFolder)
        } catch {
            print("Failed to uninstall WhiskyWine: \(error)")
        }
    }

    public static func shouldUpdateWhiskyWine() async -> (Bool, SemanticVersion) {
        let versionPlistURL = "https://data.getwhisky.app/Wine/WhiskyWineVersion.plist"
        let localVersion = whiskyWineVersion()

        var remoteVersion: SemanticVersion?

        if let remoteUrl = URL(string: versionPlistURL) {
            remoteVersion = await withCheckedContinuation { continuation in
                URLSession(configuration: .ephemeral).dataTask(with: URLRequest(url: remoteUrl)) { data, _, error in
                    do {
                        if error == nil, let data = data {
                            let decoder = PropertyListDecoder()
                            let remoteInfo = try decoder.decode(WhiskyWineVersion.self, from: data)
                            let remoteVersion = remoteInfo.version

                            continuation.resume(returning: remoteVersion)
                            return
                        }
                        if let error = error {
                            print(error)
                        }
                    } catch {
                        print(error)
                    }

                    continuation.resume(returning: nil)
                }.resume()
            }
        }

        if let localVersion = localVersion, let remoteVersion = remoteVersion {
            if localVersion < remoteVersion {
                return (true, remoteVersion)
            }
        }

        return (false, SemanticVersion(0, 0, 0))
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        do {
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WhiskyWineVersion.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

struct WhiskyWineVersion: Codable {
    var version: SemanticVersion = SemanticVersion(1, 0, 0)
}
