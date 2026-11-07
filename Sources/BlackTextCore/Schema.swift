import Foundation

enum Schema {
    /// Each entry upgrades the schema by one version.
    private static let migrations = [version1, version2, version3]
    static var currentVersion: Int { migrations.count }

    /// Upgrades to `target` (the latest by default; tests stop earlier to check an upgrade).
    static func migrate(_ db: Database, to target: Int = currentVersion) throws {
        guard try userVersion(db) < target else { return }
        try db.transaction {
            let from = try userVersion(db)
            guard from < target else { return }
            for sql in migrations[from..<target] { try db.execute(sql) }
            try db.execute("PRAGMA user_version = \(target)")
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

    /// iCloud sync. Notes and versions get a global `uid` (the integer ids stay local), and triggers
    /// record every change in `sync_outbox`, so edits from the app, the CLI and agents all get sent,
    /// even when they happen while the app isn't running.
    private static let version3 = """
    ALTER TABLE notes ADD COLUMN uid TEXT;
    ALTER TABLE versions ADD COLUMN uid TEXT;
    UPDATE notes SET uid = lower(hex(randomblob(16)));
    UPDATE versions SET uid = lower(hex(randomblob(16)));
    CREATE UNIQUE INDEX notes_uid ON notes(uid);
    CREATE UNIQUE INDEX versions_uid ON versions(uid);

    -- What still has to be sent: one row per record, replaced by its newest change.
    CREATE TABLE sync_outbox (
        id INTEGER PRIMARY KEY,
        kind TEXT NOT NULL,
        uid TEXT NOT NULL,
        deleted INTEGER NOT NULL DEFAULT 0,
        UNIQUE (kind, uid) ON CONFLICT REPLACE
    );
    INSERT INTO sync_outbox (kind, uid) SELECT 'note', uid FROM notes;
    INSERT INTO sync_outbox (kind, uid) SELECT 'version', uid FROM versions;

    CREATE TRIGGER notes_sync_insert AFTER INSERT ON notes BEGIN
        UPDATE notes SET uid = lower(hex(randomblob(16))) WHERE id = new.id AND uid IS NULL;
        INSERT INTO sync_outbox (kind, uid) SELECT 'note', uid FROM notes WHERE id = new.id;
    END;
    CREATE TRIGGER notes_sync_update AFTER UPDATE OF text, created_at, updated_at, deleted_at ON notes BEGIN
        INSERT INTO sync_outbox (kind, uid) VALUES ('note', new.uid);
    END;
    CREATE TRIGGER notes_sync_delete AFTER DELETE ON notes BEGIN
        INSERT INTO sync_outbox (kind, uid, deleted) VALUES ('note', old.uid, 1);
    END;
    CREATE TRIGGER versions_sync_insert AFTER INSERT ON versions BEGIN
        UPDATE versions SET uid = lower(hex(randomblob(16))) WHERE id = new.id AND uid IS NULL;
        INSERT INTO sync_outbox (kind, uid) SELECT 'version', uid FROM versions WHERE id = new.id;
    END;

    -- CloudKit's bookkeeping for each note record (its change tag), so the next save is accepted.
    CREATE TABLE sync_records (
        uid TEXT PRIMARY KEY,
        system_fields BLOB NOT NULL
    ) WITHOUT ROWID;

    -- Versions that arrived before their note did.
    CREATE TABLE sync_orphans (
        uid TEXT PRIMARY KEY,
        note_uid TEXT NOT NULL,
        created_at REAL NOT NULL,
        word_count INTEGER NOT NULL,
        source TEXT NOT NULL,
        compressed INTEGER NOT NULL,
        body BLOB NOT NULL
    );
    CREATE INDEX sync_orphans_by_note ON sync_orphans(note_uid);
    """
}
