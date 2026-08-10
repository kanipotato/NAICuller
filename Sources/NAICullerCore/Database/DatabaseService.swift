import Foundation
import SQLite3

// SQLITE_TRANSIENTはCマクロなのでSwiftからは自前定義する必要がある
// （sqlite3_bind_text/blobにコピーさせるための定数。-1を渡すのと等価）。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLiteアクセスの薄いラッパー。GRDB/SQLite.swiftのような外部依存は追加せず、
/// システム標準のlibsqlite3（`import SQLite3`）を直接叩く（詳細設計・技術スタック指定）。
///
/// SQLite3の1コネクションはスレッドセーフではない前提のため、すべてのアクセスを
/// 内部の直列DispatchQueueに通す。書き込み（スキャン・タグ付け）とUIからの読み取りが
/// 同時に発生してもクラッシュ・データ競合しないようにするための最小限の防御線。
///
/// クエリは全てプレースホルダ（bind変数）で組み立てる。配布予定はなくSQLインジェクションの
/// 実害は想定していないが、将来DBを直接いじられて壊れたと言われても困らないための予防的な制御
/// （詳細設計 2章の指示通り）。
public final class DatabaseService {
    /// bind変数に渡せる値の型。
    public enum Value: Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)

        static func from(_ int: Int?) -> Value {
            int.map { .integer(Int64($0)) } ?? .null
        }
        static func from(_ string: String?) -> Value {
            string.map { .text($0) } ?? .null
        }
    }

    public struct DatabaseError: Error, CustomStringConvertible, Sendable {
        public let message: String
        public var description: String { message }
    }

    /// 1行分の結果を取り出すためのアクセサ。クロージャに渡され、列インデックスで値を読む。
    public struct Row {
        let statement: OpaquePointer

        public func int64(_ index: Int32) -> Int64 {
            sqlite3_column_int64(statement, index)
        }
        public func int(_ index: Int32) -> Int {
            Int(sqlite3_column_int64(statement, index))
        }
        public func double(_ index: Int32) -> Double {
            sqlite3_column_double(statement, index)
        }
        public func string(_ index: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        }
        public func isNull(_ index: Int32) -> Bool {
            sqlite3_column_type(statement, index) == SQLITE_NULL
        }
        public func optionalInt(_ index: Int32) -> Int? {
            isNull(index) ? nil : int(index)
        }
        public func optionalString(_ index: Int32) -> String? {
            isNull(index) ? nil : string(index)
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.kanipotato.NAICuller.DatabaseService")
    /// `queue`上で実行中かどうかをスレッドローカルに判定するためのキー。
    /// `transaction(_:)`がBEGIN〜COMMITを1回の`sync`で囲えるようにする
    /// （レビュー指摘：BEGIN/body/COMMITを別々の`queue.sync`に分けると、bodyの実行中に
    /// 他スレッドの呼び出しが割り込んでトランザクションの原子性が崩れうる。かといって
    /// `queue.sync`をネストすると同一スレッドからの再入でデッドロックするため、
    /// 「既にqueue上にいるなら素通しする」再入可能な同期ヘルパーにしている）。
    private let queueKey = DispatchSpecificKey<Void>()
    public let path: String

    /// - Parameter path: DBファイルパス。テストでは`":memory:"`を渡してオンメモリDBにできる。
    public init(path: String) throws {
        self.path = path
        queue.setSpecific(key: queueKey, value: ())
        var handle: OpaquePointer?
        // SQLITE_OPEN_FULLMUTEX: 内部で直列queueに通してはいるが、sqlite3側の
        // スレッドセーフモードも保険として有効にしておく。
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close(handle)
            throw DatabaseError(message: "DBを開けなかったよ: \(message)")
        }
        self.db = handle
        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    /// `queue.sync`の再入可能版。既に`queue`上で実行中のスレッドから呼ばれた場合は
    /// 素通しで直接実行し（デッドロック回避）、それ以外は通常通り`queue.sync`で直列化する。
    private func sync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try block()
        }
        return try queue.sync(execute: block)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - マイグレーション

    /// `PRAGMA user_version`でスキーマバージョンを管理する。
    /// v1: roots/images/tags/image_tagsの初期スキーマ作成＋固定タグ（お気に入り/削除対象）投入。
    private func migrate() throws {
        let currentVersion = try userVersion()
        if currentVersion < 1 {
            try createSchemaV1()
            try setUserVersion(1)
        }
    }

    private func userVersion() throws -> Int {
        var result = 0
        try sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
                throw lastError("PRAGMA user_version の準備に失敗")
            }
            if sqlite3_step(statement) == SQLITE_ROW {
                result = Int(sqlite3_column_int64(statement, 0))
            }
        }
        return result
    }

    private func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    private func createSchemaV1() throws {
        try execute("""
        CREATE TABLE roots (
          id INTEGER PRIMARY KEY,
          path TEXT NOT NULL UNIQUE,
          added_at TEXT NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE images (
          id INTEGER PRIMARY KEY,
          root_id INTEGER NOT NULL REFERENCES roots(id) ON DELETE CASCADE,
          path TEXT NOT NULL UNIQUE,
          mtime REAL NOT NULL,
          file_size INTEGER NOT NULL,
          width INTEGER,
          height INTEGER,
          prompt_cache TEXT,
          last_scanned_at TEXT NOT NULL
        );
        """)
        try execute("CREATE INDEX idx_images_root ON images(root_id);")
        try execute("""
        CREATE TABLE tags (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL UNIQUE,
          is_system INTEGER NOT NULL DEFAULT 0,
          key_binding TEXT UNIQUE
        );
        """)
        try execute("""
        CREATE TABLE image_tags (
          image_id INTEGER NOT NULL REFERENCES images(id) ON DELETE CASCADE,
          tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
          tagged_at TEXT NOT NULL,
          PRIMARY KEY (image_id, tag_id)
        );
        """)
        try execute("CREATE INDEX idx_image_tags_tag ON image_tags(tag_id);")

        // 固定タグ（お気に入り=F、削除対象=G）を初期投入する。
        // key_bindingにUNIQUE制約があるため、同じキーへの二重割当はDBレベルでも弾かれる。
        try run(
            "INSERT INTO tags (name, is_system, key_binding) VALUES (?, 1, ?);",
            [.text(Tag.SystemTagName.favorite), .text("F")]
        )
        try run(
            "INSERT INTO tags (name, is_system, key_binding) VALUES (?, 1, ?);",
            [.text(Tag.SystemTagName.deletionMark), .text("G")]
        )
    }

    // MARK: - 低レベルアクセス（bind変数必須）

    /// パラメータなしのDDL/PRAGMA用。複数のSQL文をセミコロン区切りでまとめて実行できる
    /// （CREATE TABLE文をそのまま貼れるように sqlite3_exec を使用）。
    public func execute(_ sql: String) throws {
        try sync {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                throw lastError("SQL実行に失敗: \(sql.prefix(80))")
            }
        }
    }

    /// bind変数付きのINSERT/UPDATE/DELETEを実行する。
    @discardableResult
    public func run(_ sql: String, _ bindings: [Value] = []) throws -> Int64 {
        try sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError("prepare失敗: \(sql)")
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement!)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw lastError("実行失敗: \(sql)")
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// SELECT用。`mapRow`で各行を任意の型へ変換する。
    public func query<T>(_ sql: String, _ bindings: [Value] = [], _ mapRow: (Row) -> T) throws -> [T] {
        try sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw lastError("prepare失敗: \(sql)")
            }
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement!)
            var results: [T] = []
            while true {
                let stepResult = sqlite3_step(statement)
                if stepResult == SQLITE_ROW {
                    results.append(mapRow(Row(statement: statement!)))
                } else if stepResult == SQLITE_DONE {
                    break
                } else {
                    throw lastError("step失敗: \(sql)")
                }
            }
            return results
        }
    }

    /// トランザクションでまとめて実行する（孤児レコード一括削除など複数書き込みの原子性確保用）。
    ///
    /// BEGIN・`body`・COMMIT/ROLLBACKを1回の`sync`呼び出しの中で行う（レビュー指摘の修正）。
    /// 以前はBEGINとCOMMITがそれぞれ別の`queue.sync`だったため、bodyの実行中（＝queueを
    /// 一時的に手放している間）に他スレッドの呼び出しが割り込める隙間があった。
    /// `body`内で呼ばれる`execute`/`run`/`query`は同じスレッドから`sync`ヘルパーを再入するが、
    /// 既にqueue上にいるため素通しになりデッドロックしない。
    public func transaction(_ body: () throws -> Void) throws {
        try sync {
            if sqlite3_exec(db, "BEGIN;", nil, nil, nil) != SQLITE_OK {
                throw lastError("BEGINに失敗")
            }
            do {
                try body()
                if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                    throw lastError("COMMITに失敗")
                }
            } catch {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                throw error
            }
        }
    }

    private func bind(_ bindings: [Value], to statement: OpaquePointer) throws {
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .integer(let v):
                result = sqlite3_bind_int64(statement, position, v)
            case .real(let v):
                result = sqlite3_bind_double(statement, position, v)
            case .text(let v):
                result = sqlite3_bind_text(statement, position, v, -1, SQLITE_TRANSIENT)
            }
            guard result == SQLITE_OK else {
                throw lastError("bind失敗 (index: \(index))")
            }
        }
    }

    private func lastError(_ context: String) -> DatabaseError {
        let message = String(cString: sqlite3_errmsg(db))
        return DatabaseError(message: "\(context): \(message)")
    }
}
