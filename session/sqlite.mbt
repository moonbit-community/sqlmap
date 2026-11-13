///|
pub struct SqliteSession {
  connection : @sqlite3.Connection
}

///|
fn execute(db : @sqlite3.Connection, sql : String) -> Unit raise {
  let statement = db.prepare(sql)
  defer statement.finalize()
  ignore(statement.step())
}

///|
/// Independent format; reject foreign databases and future versions.
pub fn SqliteSession::open(path : String) -> SqliteSession raise {
  let connection = @sqlite3.Connection::open(path)
  errdefer connection.close()
  let tables = connection.prepare(
    "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name",
  )
  let names : Array[String] = []
  while tables.step() {
    names.push(tables.column(index=0))
  }
  tables.finalize()
  if !names.is_empty() && names != ["sqlmap_mbt_format", "sqlmap_session_v2"] {
    raise @core.ConfigError(
      "Session file is not in sqlmap.mbt v2 format; Python sqlmap sessions are incompatible",
    )
  }
  if !names.is_empty() {
    let version = connection.prepare("SELECT version FROM sqlmap_mbt_format")
    defer version.finalize()
    if !version.step() {
      raise @core.ConfigError("Session format version is missing")
    }
    let v : Int64 = version.column(index=0)
    if v != 2 || version.step() {
      raise @core.ConfigError("Unsupported session format version")
    }
  }
  execute(connection, "BEGIN IMMEDIATE")
  {
    errdefer (execute(connection, "ROLLBACK") catch { _ => () })
    execute(
      connection, "CREATE TABLE IF NOT EXISTS sqlmap_mbt_format (version INTEGER NOT NULL)",
    )
    if names.is_empty() {
      execute(connection, "INSERT INTO sqlmap_mbt_format VALUES (2)")
    }
    execute(
      connection, "CREATE TABLE IF NOT EXISTS sqlmap_session_v2 (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    )
    execute(connection, "COMMIT")
  }
  { connection, }
}

///|
pub fn SqliteSession::close(self : SqliteSession) -> Unit raise {
  self.connection.close()
}

///|
pub impl @core.SessionStore for SqliteSession with fn get(self, key) {
  let s = self.connection.prepare(
    "SELECT value FROM sqlmap_session_v2 WHERE key=?",
  )
  defer s.finalize()
  s.bind(index=1, key)
  if s.step() {
    Some(s.column(index=0))
  } else {
    None
  }
}

///|
pub impl @core.SessionStore for SqliteSession with fn put(self, key, value) {
  execute(self.connection, "BEGIN IMMEDIATE")
  errdefer (execute(self.connection, "ROLLBACK") catch { _ => () })
  let s = self.connection.prepare(
    "INSERT INTO sqlmap_session_v2(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
  )
  defer s.finalize()
  s.bind(index=1, key)
  s.bind(index=2, value)
  ignore(s.step())
  execute(self.connection, "COMMIT")
}

///|
pub impl @core.SessionStore for SqliteSession with fn remove_prefix(
  self,
  prefix,
) {
  let s = self.connection.prepare(
    "DELETE FROM sqlmap_session_v2 WHERE substr(key,1,length(?))=?",
  )
  defer s.finalize()
  s.bind(index=1, prefix)
  s.bind(index=2, prefix)
  ignore(s.step())
}
