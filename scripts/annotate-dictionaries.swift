#!/usr/bin/env swift
// Проставляет `commonIn` в наборах словаря: языки, где написание записи в нижнем регистре
// является словарным словом по NSSpellChecker.
//
// Запуск из корня репозитория:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/annotate-dictionaries.swift Tranq/Dictionaries
//
// Файлы перезаписываются с сортировкой ключей и отступом 2.
import AppKit

func isCommonWord(_ word: String, language: String) -> Bool {
    let checker = NSSpellChecker.shared
    guard !word.isEmpty,
          let code = checker.availableLanguages.first(where: { $0.hasPrefix(language) }) else { return false }
    let range = checker.checkSpelling(
        of: word.lowercased(), startingAt: 0, language: code, wrap: false,
        inSpellDocumentWithTag: 0, wordCount: nil
    )
    return range.location == NSNotFound
}

/// Языки, в которых написание вообще может быть словарным: кириллица только для ru, латиница только для en.
/// Написания с цифрами и символами словарными не бывают.
func candidateLanguages(for spelling: String) -> [String] {
    let letters = spelling.filter { !$0.isWhitespace }
    guard !letters.isEmpty, letters.allSatisfy(\.isLetter) else { return [] }
    if letters.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) } }) { return ["ru"] }
    if letters.allSatisfy(\.isASCII) { return ["en"] }
    return []
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Использование: annotate-dictionaries.swift <папка с наборами>\n".utf8))
    exit(2)
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !files.isEmpty else {
    FileHandle.standardError.write(Data("В \(directory.path) нет файлов json\n".utf8))
    exit(1)
}

for url in files {
    do {
        let data = try Data(contentsOf: url)
        guard var pack = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = pack["entries"] as? [[String: Any]] else {
            throw NSError(domain: "annotate", code: 1, userInfo: [NSLocalizedDescriptionKey: "нет поля entries"])
        }
        var changed = 0
        pack["entries"] = entries.map { entry -> [String: Any] in
            var entry = entry
            let spelling = (entry["spelling"] as? String) ?? ""
            let common = candidateLanguages(for: spelling).filter { isCommonWord(spelling, language: $0) }
            if (entry["commonIn"] as? [String]) != common { changed += 1 }
            entry["commonIn"] = common
            return entry
        }
        var out = try JSONSerialization.data(
            withJSONObject: pack, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        out.append(Data("\n".utf8))
        try out.write(to: url, options: .atomic)
        print("\(url.lastPathComponent): записей \(entries.count), изменено \(changed)")
    } catch {
        FileHandle.standardError.write(Data("\(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
