import Foundation

enum Schema {
    /// Each entry upgrades the schema by one version.
    private static let migrations = [version1, version2]
    static var currentVersion: Int { migrations.count }

    static func migrate(_ db: Database) throws {
        guard try userVersion(db) < currentVersion else { return }
        try db.transaction {
            let from = try userVersion(db)
            guard from < currentVersion else { return }
            for sql in migrations[from...] { try db.execute(sql) }
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

    /// A word index alongside the trigram one, for fast whole-word search.
    private static let version2 = """
    CREATE VIRTUAL TABLE notes_words USING fts5(text, content='notes', content_rowid='id', tokenize='unicode61');
    INSERT INTO notes_words(notes_words) VALUES ('rebuild');
    CREATE TRIGGER notes_words_insert AFTER INSERT ON notes BEGIN
        INSERT INTO notes_words(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER notes_words_delete AFTER DELETE ON notes BEGIN
        INSERT INTO notes_words(notes_words, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TRIGGER notes_words_update AFTER UPDATE OF text ON notes BEGIN
        INSERT INTO notes_words(notes_words, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO notes_words(rowid, text) VALUES (new.id, new.text);
    END;
    """
}
