///|
async test "real SQLite GET numeric and string vulnerabilities" {
  @support.with_fixture() <| fixture => {
    for path in ["/numeric?id=1", "/string?name=alice"] {
      let report = @controller.scan(
        fixture.url() + path,
        @core.Options::default(),
        @request.HttpTransport::{ },
      )
      assert_eq(report.verdict, Confirmed)
      assert_eq(report.database, SQLite)
      assert_true(
        report.findings.any(f => {
          f.technique == BooleanBased && f.verdict == Confirmed
        }),
      )
      assert_true(
        report.findings.any(f => {
          f.technique == ErrorBased && f.verdict == Confirmed
        }),
      )
      assert_eq(report.exit_code(), 1)
    }
    assert_true(fixture.db.statements >= fixture.requests)
  }
}

///|
async test "real SQLite POST form vulnerability and untouched query" {
  @support.with_fixture() <| fixture => {
    let options = {
      ..@core.Options::default(),
      data: Some("name=alice&token=%C3%A9"),
      parameters: ["form:name"],
    }
    let report = @controller.scan(
      fixture.url() + "/string?name=ignored&x=1&x=2",
      options,
      @request.HttpTransport::{ },
    )
    assert_eq(report.verdict, Confirmed)
    assert_true(
      report.findings.all(f => f.location == Form && f.parameter == "name"),
    )
    assert_true(fixture.paths.all(p => p == "/string?name=ignored&x=1&x=2"))
    assert_true(fixture.bodies.all(body => body.has_suffix("&token=%C3%A9")))
  }
}

///|
async test "bound SQLite GET and POST, reflection, old errors and ordinary 500 stay negative" {
  @support.with_fixture() <| fixture => {
    for route in ["/safe", "/reflect", "/existing-error", "/generic-500"] {
      for post in [false, true] {
        let options = if post {
          { ..@core.Options::default(), data: Some("id=1"), }
        } else {
          @core.Options::default()
        }
        let path = route + (if post { "" } else { "?id=1" })
        let report = @controller.scan(fixture.url() + path, options, @request.HttpTransport::{
        })
        assert_eq(report.verdict, NotDetected)
        assert_eq(report.exit_code(), 0)
      }
    }
  }
}

///|
async test "hidden SQLite errors still allow boolean detection with unknown database" {
  @support.with_fixture() <| fixture => {
    for route in ["/hidden", "/equal-length"] {
      let options = { ..@core.Options::default(), techniques: [BooleanBased], }
      let report = @controller.scan(fixture.url() + route + "?id=1", options, @request.HttpTransport::{
      })
      assert_eq(report.verdict, Confirmed)
      assert_eq(report.database, Unknown)
      let samples = report.findings[0].evidence.observations
      assert_eq(samples[0].normalized_length, samples[1].normalized_length)
    }
  }
}

///|
async test "unstable pages and response limit are inconclusive" {
  @support.with_fixture() <| fixture => {
    for route in ["/dynamic", "/large"] {
      let options = { ..@core.Options::default(), max_response_bytes: 1024, }
      let report = @controller.scan(fixture.url() + route + "?id=1", options, @request.HttpTransport::{
      })
      assert_eq(report.verdict, Inconclusive)
      assert_eq(report.exit_code(), 2)
      assert_eq(report.findings.length(), 0)
      assert_eq(
        report.requests.attempted,
        if route == "/large" {
          1
        } else {
          5
        },
      )
    }
  }
}

///|
async test "HTTP timeout releases request resources and next scan still works" {
  @support.with_fixture() <| fixture => {
    let report = @controller.scan(
      fixture.url() + "/slow?id=1",
      { ..@core.Options::default(), timeout_ms: 20, retries: 0, },
      @request.HttpTransport::{ },
    )
    assert_eq(report.exit_code(), 2)
    assert_eq(report.requests.failed, 1)
    assert_eq(report.requests.attempted, 1)
    @async.sleep(250)
    assert_eq(fixture.active, 0)
    let next = @controller.scan(
      fixture.url() + "/safe?id=1",
      @core.Options::default(),
      @request.HttpTransport::{ },
    )
    assert_eq(next.exit_code(), 0)
    assert_eq(fixture.active, 0)
  }
}

///|
async test "HTTP headers, repeated header values and Cookie reach the service" {
  @support.with_fixture() <| fixture => {
    let options = {
      ..@core.Options::default(),
      headers: [
        { name: "X-Test", value: "one", },
        { name: "X-Test", value: "two", },
        { name: "User-Agent", value: "sqlmap-test", },
      ],
      cookie: Some("sid=example"),
    }
    let report = @controller.scan(fixture.url() + "/headers?id=1", options, @request.HttpTransport::{
    })
    assert_eq(report.exit_code(), 0)
    assert_eq(
      fixture.last_headers.get(CaseInsensitiveString("x-test")),
      Some("one, two"),
    )
    assert_eq(
      fixture.last_headers.get(CaseInsensitiveString("user-agent")),
      Some("sqlmap-test"),
    )
    assert_eq(
      fixture.last_headers.get(CaseInsensitiveString("cookie")),
      Some("sid=example"),
    )
  }
}

///|
async test "same-origin HTTP redirect forwards the actual probe and detects the SQLite error" {
  @support.with_fixture() <| fixture => {
    let report = @controller.scan(
      fixture.url() + "/redirect?id=1",
      { ..@core.Options::default(), techniques: [ErrorBased], },
      @request.HttpTransport::{ },
    )
    assert_eq(report.exit_code(), 1)
    assert_eq(report.findings[0].verdict, Confirmed)
    assert_eq(report.database, SQLite)
    assert_true(fixture.paths.any(p => p.has_prefix("/numeric")))
    assert_eq(report.requests.attempted, fixture.requests)
  }
}

///|
async test "real HTTP SQLite UNION metadata and nested JSON Cookie header locators" {
  @support.with_fixture() <| fixture => {
    let opts = {
      ..@core.Options::default(),
      techniques: [UnionBased],
      dbms: SQLite,
      union_max: 1,
      enumeration: {
        ..@core.EnumerationOptions::default(),
        banner: true,
        columns: true,
        table: Some("users_résumés"),
      },
    }
    let union = @controller.scan(fixture.url() + "/union?id=1", opts, @request.HttpTransport::{
    })
    assert_eq(union.exit_code(), 1)
    assert_eq(union.enumeration[1].values, ["résumé_id", "na\"me"])
    for
      (path, options) in [
        (
          "/json",
          {
            ..@core.Options::default(),
            techniques: [BooleanBased],
            data: Some(
              (
                #|{"filter":{"id":1},"token":"café"}
              ),
            ),
            parameters: ["json:/filter/id"],
          },
        ),
        (
          "/cookie",
          {
            ..@core.Options::default(),
            techniques: [BooleanBased],
            cookie: Some("id=1;token=keep"),
            parameters: ["cookie:id"],
          },
        ),
        (
          "/header",
          {
            ..@core.Options::default(),
            techniques: [BooleanBased],
            headers: [{ name: "X-Id", value: "1", }],
            parameters: ["header:X-Id"],
          },
        ),
      ] {
      let r = @controller.scan(fixture.url() + path, options, @request.HttpTransport::{
      })
      assert_eq(r.exit_code(), 1)
      assert_eq(r.findings[0].verdict, Confirmed)
    }
  }
}
