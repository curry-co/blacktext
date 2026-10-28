import Foundation

enum Schema {
    static let currentVersion = 1

    static func migrate(_ db: Database) throws {
        guard try userVersion(db) < currentVersion else { return }
        try db.transaction {
            guard try userVersion(db) < currentVersion else { return }
            try db.execute(version1)
            try db.execute("PRAGMA user_version = \(currentVersion)")
        }
    }

    private static func userVersion(_ db: Database) throws -> Int {
        let statement = try db.prepare("PRAGMA user_version")
        defer { statement.reset() }
        return try statement.step() ? statement.int(0) : 0
    }

    private static let version1 = """
    CREATE TABLE notes (
        id INTEGER PRIMARY KEY,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        word_count INTEGER NOT NULL DEFAULT 0,
        version_count INTEGER NOT NULL DEFAULT 0,
        deleted_at REAL
    );
    CREATE INDEX notes_live ON notes(updated_at DESC, id DESC) WHERE deleted_at IS NULL;
    CREATE INDEX notes_deleted ON notes(deleted_at DESC) WHERE deleted_at IS NOT NULL;

    CREATE TABLE versions (
        id INTEGER PRIMARY KEY,
        note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        word_count INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'user',
        compressed INTEGER NOT NULL DEFAULT 0,
        body BLOB NOT NULL
    );
    CREATE INDEX versions_by_note ON versions(note_id, created_at DESC, id DESC);

    CREATE VIRTUAL TABLE notes_fts USING fts5(text, content='notes', content_rowid='id', tokenize='trigram');
    CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TRIGGER notes_fts_update AFTER UPDATE OF text ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO notes_fts(rowid, text) VALUES (new.id, new.text);
    END;

    CREATE TABLE state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE inbox (
        id INTEGER PRIMARY KEY,
        created_at REAL NOT NULL,
        kind TEXT NOT NULL,
        note_id INTEGER,
        payload TEXT NOT NULL,
        source TEXT NOT NULL,
        result TEXT,
        done_at REAL
    );
    CREATE INDEX inbox_pending ON inbox(id) WHERE done_at IS NULL;
    """
}
