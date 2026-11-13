///|
test "SQLite executes numeric and string probes and bound queries stay safe" {
  let db = @database.Database::new()
  defer db.close()
  assert_eq(db.query("/numeric", "1").body, "rows=1")
  assert_eq(db.query("/numeric", "1 AND 7=7").body, "rows=1")
  assert_eq(db.query("/numeric", "1 AND 7=8").body, "rows=0")
  assert_eq(db.query("/string", "alice' AND '9'='9").body, "rows=1")
  assert_eq(db.query("/string", "alice' AND '9'='10").body, "rows=0")
  assert_eq(db.query("/safe", "1 AND 7=7").body, "rows=0")
  assert_eq(db.query("/safe", "1'").status, 200)
  assert_eq(db.query("/numeric", "1'").status, 500)
  assert_true(db.query("/numeric", "1'").body.has_prefix("SQLite error:"))
  assert_eq(db.query("/hidden", "1'").body, "Internal server error")
  // Failed statements do not poison the connection or leave it uncloseable.
  assert_eq(db.query("/numeric", "1").body, "rows=1")
}

///|
struct DatabaseTransport {
  db : @database.Database
}

///|
impl @core.Transport for DatabaseTransport with fn send(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  let data = request.body
  let target = @parse.target(request.url, data?)
  let route = if target.base.has_suffix("/union") {
    "/union"
  } else if target.base.has_suffix("/safe-union") {
    "/safe-union"
  } else if target.base.has_suffix("/string") {
    "/string"
  } else if target.base.has_suffix("/safe") {
    "/safe"
  } else if target.base.has_suffix("/hidden") {
    "/hidden"
  } else {
    "/numeric"
  }
  let parameters = if request.http_method == "POST" {
    target.form.unwrap()
  } else {
    target.query
  }
  self.db.query(route, parameters[0].value)
}

///|
async test "scan through real SQLite without sockets on both backends" {
  let db = @database.Database::new()
  defer db.close()
  let transport = DatabaseTransport::{ db, }
  for
    (path, options, verdict, database) in [
      ("/numeric?id=1", @core.Options::default(), @core.Confirmed, @core.SQLite),
      ("/string?name=alice", @core.Options::default(), Confirmed, SQLite),
      (
        "/string",
        { ..@core.Options::default(), data: Some("name=alice"), },
        Confirmed,
        SQLite,
      ),
      ("/safe?id=1", @core.Options::default(), NotDetected, Unknown),
      (
        "/safe",
        { ..@core.Options::default(), data: Some("id=1"), },
        NotDetected,
        Unknown,
      ),
      ("/hidden?id=1", @core.Options::default(), Confirmed, Unknown),
    ] {
    let report = @controller.scan(
      "http://fixture.test" + path,
      options,
      transport,
    )
    assert_eq(report.verdict, verdict)
    assert_eq(report.database, database)
    assert_true(report.complete)
    assert_eq(report.requests.failed, 0)
  }
}

///|
async test "real SQLite UNION and boolean metadata enumeration with Unicode identifiers" {
  let db = @database.Database::new()
  defer db.close()
  for
    (route, kind) in [("/union", @core.UnionBased), ("/numeric", BooleanBased)] {
    let options = {
      ..@core.Options::default(),
      techniques: [kind],
      dbms: SQLite,
      union_min: 1,
      union_max: 1,
      enumeration: {
        ..@core.EnumerationOptions::default(),
        fingerprint: true,
        banner: true,
        tables: true,
        columns: true,
        table: Some("users_résumés"),
      },
    }
    let report = @controller.scan(
      "http://fixture.test" + route + "?id=1",
      options,
      DatabaseTransport::{ db, },
    )
    assert_true(report.complete, msg=@report.text(report))
    assert_eq(report.database, SQLite)
    assert_true(report.injection_points.any(p => p.technique == kind))
    assert_eq(report.enumeration[0].values, ["SQLite"])
    assert_true(report.enumeration[1].values[0].contains("3."))
    assert_eq(report.enumeration[2].values, ["users", "users_résumés"])
    assert_eq(report.enumeration[3].values, ["résumé_id", "na\"me"])
  }
}

///|
async test "SQLite unsupported metadata and safe binding are explicit" {
  let db = @database.Database::new()
  defer db.close()
  let options = {
    ..@core.Options::default(),
    techniques: [UnionBased],
    dbms: SQLite,
    union_max: 1,
    enumeration: {
      ..@core.EnumerationOptions::default(),
      current_db: true,
      dbs: true,
    },
  }
  let report = @controller.scan("http://fixture.test/union?id=1", options, DatabaseTransport::{
    db,
  })
  assert_eq(report.exit_code(), 2)
  assert_eq(report.enumeration.length(), 2)
  assert_true(
    report.enumeration.all(e => {
      !e.complete && e.message.unwrap().contains("not supported")
    }),
  )
  let safe = @controller.scan(
    "http://fixture.test/safe-union?id=1",
    { ..options, enumeration: @core.EnumerationOptions::default(), },
    DatabaseTransport::{ db, },
  )
  assert_eq(safe.exit_code(), 0)
}

///|
test "SQLite fixture returns computed UNION text" {
  let db = @database.Database::new()
  defer db.close()
  assert_eq(
    db.query(
      "/union",
      (
        #|1 AND 1=0 UNION ALL SELECT CASE WHEN sqlite_version() IS NOT NULL THEN ('sqm123'||'x4z') ELSE NULL END -- 
      ),
    ).body,
    "sqm123x4z",
  )
}

///|
async test "SQLite enumeration cache fresh queries and revalidated injection points" {
  let db = @database.Database::new()
  defer db.close()
  let session = @session.SqliteSession::open(":memory:")
  defer session.close()
  let opts = {
    ..@core.Options::default(),
    techniques: [UnionBased],
    dbms: SQLite,
    union_max: 1,
    enumeration: {
      ..@core.EnumerationOptions::default(),
      banner: true,
      tables: true,
    },
  }
  let t = @parse.template("http://fixture.test/union?id=1", opts)
  let first = @controller.scan_template(
    t,
    opts,
    DatabaseTransport::{ db, },
    session~,
  )
  assert_true(first.complete)
  assert_false(first.enumeration[0].cached)
  let second = @controller.scan_template(
    t,
    opts,
    DatabaseTransport::{ db, },
    session~,
  )
  assert_true(second.complete)
  assert_true(second.restored)
  assert_true(second.enumeration.all(e => e.cached))
  assert_true(second.requests.attempted > 3)
  assert_true(second.requests.attempted < first.requests.attempted)
  let fresh = @controller.scan_template(
    t,
    { ..opts, fresh_queries: true, },
    DatabaseTransport::{ db, },
    session~,
  )
  assert_true(fresh.restored)
  assert_true(fresh.enumeration.all(e => !e.cached))
  let flushed = @controller.scan_template(
    t,
    { ..opts, flush_session: true, },
    DatabaseTransport::{ db, },
    session~,
  )
  assert_false(flushed.restored)
  assert_true(flushed.enumeration.all(e => !e.cached))
}

///|
async test "SQLite empty metadata and quoted table filter are read-only" {
  let db = @database.Database::new()
  defer db.close()
  let opts = {
    ..@core.Options::default(),
    techniques: [BooleanBased],
    dbms: SQLite,
    enumeration: {
      ..@core.EnumerationOptions::default(),
      columns: true,
      table: Some("missing' OR 1=1 --"),
    },
  }
  let r = @controller.scan("http://fixture.test/numeric?id=1", opts, DatabaseTransport::{
    db,
  })
  assert_eq(r.exit_code(), 1)
  assert_true(r.enumeration[0].values.is_empty())
  assert_eq(db.query("/numeric", "1").body, "rows=1")
}

///|
suberror InterruptedMetadata

///|
struct InterruptedTransport {
  db : @database.Database
  mut interrupt : Bool
}

///|
impl @core.Transport for InterruptedTransport with fn send(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  let target = @parse.target(request.url)
  let value = target.query[0].value
  if self.interrupt && value.contains("OFFSET 1") {
    self.interrupt = false
    raise InterruptedMetadata
  }
  self.db.query("/union", value)
}

///|
async test "SQLite metadata checkpoints continue after an interrupted row" {
  let db = @database.Database::new()
  defer db.close()
  let session = @session.SqliteSession::open(":memory:")
  defer session.close()
  let transport = InterruptedTransport::{ db, interrupt: true, }
  let opts = {
    ..@core.Options::default(),
    techniques: [UnionBased],
    dbms: SQLite,
    union_max: 1,
    enumeration: { ..@core.EnumerationOptions::default(), tables: true, },
  }
  let template = @parse.template("http://fixture.test/union?id=1", opts)
  let partial = @controller.scan_template(template, opts, transport, session~)
  assert_eq(partial.exit_code(), 2)
  assert_eq(partial.enumeration[0].values, ["users"])
  assert_false(partial.enumeration[0].complete)
  let resumed = @controller.scan_template(template, opts, transport, session~)
  assert_true(resumed.restored)
  assert_eq(resumed.exit_code(), 1)
  assert_eq(resumed.enumeration[0].values, ["users", "users_résumés"])
}
