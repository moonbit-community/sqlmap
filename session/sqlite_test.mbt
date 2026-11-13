///|
test "SQLite session versioned storage and bound keys" {
  let s = @session.SqliteSession::open(":memory:") catch {
    err => fail("open: \{Repr(err)}")
  }
  defer s.close()
  let store : &@core.SessionStore = s
  assert_eq(store.get("absent"), None)
  store.put("target:'é%", "first")
  store.put("target:'é%", "second")
  store.put("other", "kept")
  assert_eq(store.get("target:'é%"), Some("second"))
  store.remove_prefix("target:'")
  assert_eq(store.get("target:'é%"), None)
  assert_eq(store.get("other"), Some("kept"))
}

///|
async test "SQLite session reopens atomically and rejects foreign or future formats" {
  let dir = @fs.tmpdir(prefix="sqlmap-session-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/session.sqlite3"
  {
    let s = @session.SqliteSession::open(path)
    defer s.close()
    @core.SessionStore::put(s, "checkpoint", "committed")
  }
  {
    let s = @session.SqliteSession::open(path)
    defer s.close()
    assert_eq(@core.SessionStore::get(s, "checkpoint"), Some("committed"))
  }
  {
    let db = @sqlite3.Connection::open(path)
    defer db.close()
    let s = db.prepare("UPDATE sqlmap_mbt_format SET version=3")
    defer s.finalize()
    ignore(s.step())
  }
  try @session.SqliteSession::open(path) catch {
    err => assert_true(err is @core.ConfigError(_))
  } noraise {
    s => {
      s.close()
      fail("future session accepted")
    }
  }
  let path = dir + "/foreign.sqlite3"
  {
    let db = @sqlite3.Connection::open(path)
    defer db.close()
    let s = db.prepare("CREATE TABLE foreign_data(value TEXT)")
    defer s.finalize()
    ignore(s.step())
  }
  try @session.SqliteSession::open(path) catch {
    err => assert_true(err is @core.ConfigError(_))
  } noraise {
    s => {
      s.close()
      fail("foreign session accepted")
    }
  }
}
