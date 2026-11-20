//
//  TempFilesTests.swift
//  TranqTests
//

import Testing
import Foundation
@testable import Tranq

/// Временные файлы на пути распознавания: права только для владельца и чистка остатков.
@Suite(.serialized)
struct TempFilesTests {

    private func makeBase() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TempFilesTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func mode(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    @Test func tempFileIsOwnerOnly() {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = TempFiles.makeURL(prefix: "test", ext: "wav", in: dir)

        #expect(FileManager.default.fileExists(atPath: url.path), "файл создаётся сразу, чтобы права были до записи")
        #expect(mode(url) == 0o600)
    }

    @Test func tempFileIsOwnerOnlyUnderLooseUmask() {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }

        // umask общий на процесс: держим изменённым только на время создания файла
        let old = umask(0)
        let url = TempFiles.makeURL(prefix: "test", ext: "wav", in: dir)
        umask(old)

        #expect(mode(url) == 0o600, "права не зависят от umask")
    }

    @Test func tempDirectoryIsOwnerOnly() {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = TempFiles.makeURL(prefix: "test", ext: "wav", in: dir)

        #expect(mode(dir) == 0o700)
    }

    @Test func defaultDirectoryIsOwnerOnly() {
        #expect(mode(TempFiles.directory) == 0o700)
    }

    @Test func looserExistingDirectoryIsTightened() throws {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        #expect(mode(dir) == 0o755)

        _ = TempFiles.makeURL(prefix: "test", ext: "wav", in: dir)

        #expect(mode(dir) == 0o700)
    }

    @Test func wavWrittenThroughHelperKeepsOwnerOnly() throws {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = TempFiles.makeURL(prefix: "test", ext: "wav", in: dir)

        #expect(AudioPCM.writeWav(samples: [Float](repeating: 0.1, count: 1600), to: url))

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 0)
        #expect(mode(url) == 0o600)
    }

    @Test func restrictFixesFileReplacedByNewOne() throws {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = TempFiles.makeURL(prefix: "test", ext: "json", in: dir)
        // Внешний процесс удалил файл и создал заново с открытыми правами
        try FileManager.default.removeItem(at: url)
        try Data("x".utf8).write(to: url)
        #expect(chmod(url.path, 0o644) == 0)
        #expect(mode(url) == 0o644)

        TempFiles.restrict(url)

        #expect(mode(url) == 0o600)
    }

    @Test func createPrivateFileIsOwnerOnly() {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = TempFiles.makeURL(prefix: "test", ext: "wav", in: dir)
            .appendingPathExtension("json")

        TempFiles.createPrivateFile(at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(mode(url) == 0o600)
    }

    @Test func purgeStaleRemovesOldFiles() throws {
        let dir = makeBase()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let old = TempFiles.makeURL(prefix: "old", ext: "wav", in: dir)
        let young = TempFiles.makeURL(prefix: "young", ext: "wav", in: dir)
        let edge = TempFiles.makeURL(prefix: "edge", ext: "wav", in: dir)
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-48 * 3600)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: young.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-24 * 3600 + 60)], ofItemAtPath: edge.path)

        TempFiles.purgeStale(olderThan: 24 * 3600, in: dir, now: now)

        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: young.path), "свежие файлы не трогаем")
        #expect(fm.fileExists(atPath: edge.path), "моложе порога на минуту: остаётся")
    }
}
