///|
/// Real SQLite connection; every request executes a SQL statement.
pub struct Database {
  connection : @sqlite3.Connection
  mut statements : Int32
}

///|
pub fn Database::new() -> Database raise {
  let connection = @sqlite3.Connection::open(":memory:")
  errdefer connection.close()
  for
    sql in [
      (
        #|CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)
      ),
      (
        #|CREATE TABLE "users_résumés" ("résumé_id" INTEGER, "na""me" TEXT)
      ),
      (
        #|INSERT INTO users (id, name) VALUES (1, 'alice'), (2, 'bob')
      ),
    ] {
    let stmt = connection.prepare(sql)
    defer stmt.finalize()
    ignore(stmt.step())
  }
  { connection, statements: 0, }
}

///|
pub fn Database::close(self : Database) -> Unit raise {
  self.connection.close()
}

///|
pub fn Database::execute(
  self : Database,
  sql : String,
  bound? : String,
) -> Int32 raise {
  self.statements += 1
  let stmt = self.connection.prepare(sql)
  defer stmt.finalize()
  if bound is Some(value) {
    stmt.bind(index=1, value)
  }
  let mut rows = 0
  while stmt.step() {
    rows += 1
  }
  rows
}

///|
pub fn Database::query(
  self : Database,
  route : String,
  value : String,
) -> @core.Response {
  if route == "/union" || route == "/safe-union" {
    return try {
      let sql = if route == "/safe-union" {
        "SELECT name FROM users WHERE id=?"
      } else {
        "SELECT name FROM users WHERE id=" + value
      }
      let s = self.connection.prepare(sql)
      defer s.finalize()
      if route == "/safe-union" {
        s.bind(index=1, value)
      }
      let values : Array[String] = []
      while s.step() {
        values.push(s.column(index=0))
      }
      { status: 200, body: values.join(" | "), }
    } catch {
      err => { status: 500, body: "SQLite error: \{Repr(err)}", }
    }
  }
  let rows = try {
    match route {
      "/numeric"
      | "/hidden"
      | "/equal-length"
      | "/json"
      | "/cookie"
      | "/header" => self.execute("SELECT id FROM users WHERE id = " + value)
      "/string" =>
        self.execute("SELECT id FROM users WHERE name = '" + value + "'")
      "/safe"
      | "/reflect"
      | "/existing-error"
      | "/dynamic"
      | "/slow"
      | "/generic-500"
      | "/headers"
      | "/large" =>
        self.execute("SELECT id FROM users WHERE id = ?", bound=value)
      _ => self.execute("SELECT 1")
    }
  } catch {
    @sqlite3.SqliteError(code=_, extended=_, msg=message) =>
      return {
        status: 500,
        body: if route == "/hidden" {
          "Internal server error"
        } else {
          "SQLite error: " + message
        },
      }
    err => return { status: 500, body: "Fixture failure: \{err}", }
  }
  { status: 200, body: "rows=\{rows}", }
}
