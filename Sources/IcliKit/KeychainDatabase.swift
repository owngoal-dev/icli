import Foundation
import SQLite3

/// Reads the protected Keychain database's index metadata without asking
/// Security.framework to decrypt an item. The caller needs filesystem access
/// to the database; this does not grant access to an item's value.
public func listKeychainDatabaseMetadata(className: String? = nil) throws -> [String: Any] {
    let tables: [(name: String, className: String, columns: String)] = [
        ("genp", "generic_password", "rowid, acct, svce, agrp, labl, cdat, mdat, pdmn, length(data)"),
        ("inet", "internet_password", "rowid, acct, agrp, labl, cdat, mdat, pdmn, length(data), srvr, ptcl, port, path"),
        ("cert", "certificate", "rowid, agrp, labl, cdat, mdat, pdmn, length(data)"),
        ("keys", "key", "rowid, agrp, labl, cdat, mdat, pdmn, length(data)"),
    ]
    let selected = tables.filter {
        className == nil || className == $0.name || className == $0.className ||
            (className == "generic" && $0.name == "genp") ||
            (className == "internet" && $0.name == "inet")
    }
    guard !selected.isEmpty else {
        throw IcliError.failed("unknown keychain database class: \(className ?? "")")
    }

    // An iOS process sees the real filesystem here, including on RootHide.
    // RootHide's /rootfs prefix is for its bootstrap shell and external tools.
    let path = "/var/Keychains/keychain-2.db"
    var database: OpaquePointer?
    let openStatus = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
    guard openStatus == SQLITE_OK, let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite status \(openStatus)"
        if let database { sqlite3_close(database) }
        throw IcliError.failed("cannot read keychain database: \(message)")
    }
    defer { sqlite3_close(database) }

    var items: [[String: Any]] = []
    var counts: [String: Int] = [:]
    for table in selected {
        // Table and column names are fixed above; no request text enters SQL.
        let sql = "SELECT \(table.columns) FROM \(table.name)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let message = String(cString: sqlite3_errmsg(database))
            if let statement { sqlite3_finalize(statement) }
            throw IcliError.failed("cannot query keychain \(table.name): \(message)")
        }
        defer { sqlite3_finalize(statement) }

        var count = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw IcliError.failed("cannot read keychain \(table.name): \(String(cString: sqlite3_errmsg(database)))")
            }
            var column: Int32 = 0
            var item: [String: Any] = [
                "class": table.className,
                "table": table.name,
                "source": "database",
                "valueEncoding": "protected",
                "protectedMetadata": true,
                "rowid": sqlite3_column_int64(statement, column),
            ]
            column += 1
            if table.name == "genp" || table.name == "inet" {
                putText("account", from: statement, at: &column, into: &item)
                if table.name == "genp" {
                    putText("service", from: statement, at: &column, into: &item)
                }
            }
            putText("group", from: statement, at: &column, into: &item)
            putText("label", from: statement, at: &column, into: &item)
            putText("createdStr", from: statement, at: &column, into: &item)
            putText("modifiedStr", from: statement, at: &column, into: &item)
            putText("protection", from: statement, at: &column, into: &item)
            if sqlite3_column_type(statement, column) != SQLITE_NULL {
                item["valueSize"] = sqlite3_column_int64(statement, column)
            }
            column += 1
            if table.name == "inet" {
                putText("server", from: statement, at: &column, into: &item)
                putText("protocol", from: statement, at: &column, into: &item)
                if sqlite3_column_type(statement, column) == SQLITE_INTEGER {
                    item["port"] = sqlite3_column_int64(statement, column)
                }
                column += 1
                putText("path", from: statement, at: &column, into: &item)
            }
            items.append(item)
            count += 1
        }
        counts[table.name] = count
    }
    return ["items": items, "count": items.count, "counts": counts, "source": "database"]
}

private func putText(
    _ key: String,
    from statement: OpaquePointer,
    at column: inout Int32,
    into item: inout [String: Any]
) {
    defer { column += 1 }
    // A BLOB in an attribute column may itself be encrypted. Never decode it
    // as UTF-8 or include its bytes in the metadata response.
    guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
          let bytes = sqlite3_column_text(statement, column) else { return }
    let length = Int(sqlite3_column_bytes(statement, column))
    let value = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
    if !value.isEmpty { item[key] = value }
}
