///|
test "comparison normalizes whitespace but keeps equal-length content and status" {
  assert_eq(@generic.normalize(" \thello\n  world\r\n"), "hello world")
  assert_true(
    @generic.equivalent({ status: 200, body: "a  b\n", }, {
      status: 200,
      body: "a b",
    }),
  )
  assert_false(
    @generic.equivalent({ status: 200, body: "row:1", }, {
      status: 200,
      body: "row:0",
    }),
  )
  assert_false(
    @generic.equivalent({ status: 200, body: "same", }, {
      status: 500,
      body: "same",
    }),
  )
}

///|
test "specific DBMS fingerprints must be new relative to baseline" {
  for
    (body, expected) in [
      ("SQLite error: near foo: syntax error", @core.SQLite),
      (
        (
          #|You have an error in your SQL syntax; check the manual that corresponds to your MySQL
        ),
        MySQL,
      ),
      ("org.postgresql.util.PSQLException: ERROR", PostgreSQL),
      ("Unclosed quotation mark after the character string", SQLServer),
    ] {
    assert_eq(@dbms.infer(@dbms.new_errors("normal", body)), expected)
    assert_eq(@dbms.new_errors(body, body).length(), 0)
  }
  assert_eq(
    @dbms.new_errors("normal", "Internal server error 500 SQL database").length(),
    0,
  )
  assert_eq(
    @dbms.infer(@dbms.new_errors("", "SQLite error: x; PostgreSQL error: y")),
    Unknown,
  )
}

///|
test "JSON reports escape strings and encode unknown DB and exit priority" {
  let report : @core.ScanReport = {
    target: "http://localhost/?q=café\"\\\n",
    verdict: Inconclusive,
    complete: false,
    database: Unknown,
    tested_parameters: 1,
    findings: [
      {
        location: Form,
        parameter: "a\"é",
        index: 1,
        technique: BooleanBased,
        verdict: Confirmed,
        database: Unknown,
        evidence: { detail: "test\nline", signature: None, observations: [], },
      },
    ],
    enumeration: [
      {
        kind: "banner",
        database: None,
        table: None,
        values: ["3.0"],
        complete: true,
        cached: false,
        message: None,
      },
    ],
    injection_points: [
      {
        location: Form,
        index: 1,
        parameter: "a",
        database: SQLite,
        technique: UnionBased,
        prefix: "1",
        suffix: "-- ",
        union_columns: 1,
        union_position: 0,
      },
    ],
    source: { kind: "url", origin: "test", depth: 0, },
    restored: false,
    elapsed_ms: 0,
    requests: {
      attempted: 4,
      succeeded: 3,
      failed: 1,
      retried: 0,
      timed_out: 0,
    },
    issues: [
      {
        fatal: true,
        phase: "request",
        message: "timeout",
        parameter: Some("a\"é"),
        location: Some(Form),
        index: Some(1),
        request_id: Some(4),
      },
    ],
  }
  let encoded = @report.render(report, Json)
  let decoded = @json.parse(encoded)
  assert_eq(decoded, @report.json(report))
  guard decoded
    is { "verdict": "inconclusive", "database": "unknown", "exit_code": 2, .. } else {
    fail("wrong JSON fields")
  }
  guard decoded
    is {
      "issues": [
        {
          "parameter": "a\"é",
          "location": "form",
          "index": 1,
          "request_id": 4,
          ..
        },
      ],
      ..
    } else {
    fail("optional values must be scalar JSON values")
  }
  guard decoded
    is {
      "schema_version": 2,
      "elapsed_ms": Number(_),
      "enumeration": [{ "database": Null, "table": Null, "message": Null, .. }],
      "injection_points": [
        { "location": "form", "database": "SQLite", "technique": "union", .. },
      ],
      ..
    } else {
    fail("v2 scalar JSON fields")
  }
  assert_eq(report.exit_code(), 2)
  assert_eq({ ..report, complete: true, verdict: Confirmed, }.exit_code(), 1)
  assert_eq(
    { ..report, complete: true, verdict: NotDetected, findings: [], }.exit_code(),
    0,
  )
}
