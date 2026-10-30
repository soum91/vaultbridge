import Foundation

enum CSVImportError: LocalizedError {
    case invalidEncoding
    case malformedCSV
    case missingColumns

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The CSV is not UTF-8 text."
        case .malformedCSV: return "The CSV has an unmatched quote."
        case .missingColumns: return "A URL or site, username and password column are required."
        }
    }
}

enum CredentialCSVImporter {
    // Google/Chrome: name,url,username,password,note
    // Apple: Title,URL,Username,Password,Notes
    // Firefox: url,username,password,httpRealm,formActionOrigin,...
    static func parse(_ data: Data, source: CredentialSource, account: String) throws -> [VaultCredential] {
        guard var text = String(data: data, encoding: .utf8) else { throw CSVImportError.invalidEncoding }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = try tokenize(text)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ names: [String]) -> Int? { columns.firstIndex(where: { names.contains($0) }) }
        guard let siteIndex = column(["url", "website", "origin", "login_uri", "hostname", "site"]),
              let userIndex = column(["username", "user name", "login", "user"]),
              let passwordIndex = column(["password", "pass"]) else {
            throw CSVImportError.missingColumns
        }
        let titleIndex = column(["name", "title"])
        let noteIndex = column(["note", "notes"])

        func at(_ row: [String], _ index: Int?, trim: Bool = true) -> String {
            guard let index, row.indices.contains(index) else { return "" }
            return trim ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : row[index]
        }
        return rows.dropFirst().compactMap { row in
            let origin = at(row, siteIndex)
            // Password whitespace is significant. Never normalize a secret.
            let password = at(row, passwordIndex, trim: false)
            guard !origin.isEmpty && !password.isEmpty else { return nil }
            let title = at(row, titleIndex)
            return VaultCredential(id: UUID(), source: source, sourceAccount: account,
                                   origin: origin, title: title.isEmpty ? (URL(string: origin)?.host ?? origin) : title,
                                   username: at(row, userIndex), password: password,
                                   note: at(row, noteIndex), updatedAt: Date())
        }
    }

    // RFC 4180-style quoted field handling, including escaped quotes and newlines.
    private static func tokenize(_ input: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else { quoted.toggle() }
            } else if char == "," && !quoted {
                row.append(field)
                field = ""
            } else if (char == "\n" || char == "\r") && !quoted {
                if char == "\r" && index + 1 < characters.count && characters[index + 1] == "\n" {
                    index += 1
                }
                row.append(field)
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            } else { field.append(char) }
            index += 1
        }
        if quoted { throw CSVImportError.malformedCSV }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
