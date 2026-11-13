///|
pub(all) struct Signature {
  marker : String
  database : @core.Dbms
}

///|
/// Compile-time registry. Match specific diagnostics, never an HTTP status.
pub fn signatures() -> Array[Signature] {
  [
    { marker: "sqlite error:", database: SQLite, },
    { marker: "sqlite_error", database: SQLite, },
    { marker: "sqlite3.operationalerror:", database: SQLite, },
    { marker: "system.data.sqlite.sqliteexception", database: SQLite, },
    {
      marker: "you have an error in your sql syntax; check the manual that corresponds to your mysql",
      database: MySQL,
    },
    { marker: "mysqli_sql_exception", database: MySQL, },
    { marker: "mysql server version for the right syntax", database: MySQL, },
    { marker: "postgresql error:", database: PostgreSQL, },
    { marker: "pg_query(): query failed:", database: PostgreSQL, },
    { marker: "psycopg2.errors.syntaxerror", database: PostgreSQL, },
    { marker: "org.postgresql.util.psqlexception", database: PostgreSQL, },
    {
      marker: "unclosed quotation mark after the character string",
      database: SQLServer,
    },
    { marker: "microsoft ole db provider for sql server", database: SQLServer, },
    { marker: "sql server error:", database: SQLServer, },
  ]
}

///|
pub fn new_errors(baseline : String, response : String) -> Array[Signature] {
  let before = baseline.to_lower()
  let after = response.to_lower()
  signatures().filter(s => {
    !before.contains(s.marker) && after.contains(s.marker)
  })
}

///|
pub fn infer(signatures : Array[Signature]) -> @core.Dbms {
  guard signatures.get(0) is Some(first) else { return Unknown }
  if signatures.all(s => s.database == first.database) {
    first.database
  } else {
    Unknown
  }
}
