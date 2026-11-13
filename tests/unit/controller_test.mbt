///|
suberror MockFailure

///|
struct Mock {
  handler : (String, Int32) -> @core.Response raise MockFailure
  requests : Array[@core.Request]
  delay_ms : Int32
  mut active : Int32
}

///|
fn mock(
  handler : (String, Int32) -> @core.Response raise MockFailure,
  delay_ms~ : Int32 = 0,
) -> Mock {
  { handler, requests: [], delay_ms, active: 0, }
}

///|
impl @core.Transport for Mock with fn send(self, request, max_response_bytes~) {
  let _ = max_response_bytes
  self.requests.push(request)
  self.active += 1
  defer {
    self.active -= 1
  }
  if self.delay_ms > 0 {
    @async.sleep(self.delay_ms)
  }
  let data = request.body
  let target = @parse.target(request.url, data?)
  let value = target.query[0].value
  (self.handler)(value, self.requests.length())
}

///|
async test "boolean confirmation detects equal-length changed content" {
  let transport = mock((value, _) => {
    status: 200,
    body: if value.contains("7=8") || value.contains("9=10") {
      "row:0"
    } else {
      "row:1"
    },
  })
  let report = @controller.scan(
    "http://example.test/?id=1",
    { ..@core.Options::default(), techniques: [BooleanBased], },
    transport,
  )
  assert_eq(report.verdict, Confirmed)
  assert_eq(report.database, Unknown)
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].evidence.observations.length(), 4)
  assert_eq(report.requests.attempted, 9)
  assert_eq(report.exit_code(), 1)
}

///|
async test "error finding requires new repeatable database diagnostic" {
  let transport = mock((value, _) => {
    if value.contains("'") {
      { status: 500, body: "SQLite error: unrecognized token", }
    } else {
      { status: 200, body: "row:1", }
    }
  })
  let report = @controller.scan(
    "http://example.test/?id=1",
    { ..@core.Options::default(), techniques: [ErrorBased], },
    transport,
  )
  assert_eq(report.verdict, Confirmed)
  assert_eq(report.database, SQLite)
  assert_eq(report.requests.attempted, 7)
  assert_eq(report.findings[0].evidence.signature, Some("sqlite error:"))
}

///|
async test "safe, reflected, existing error and generic 500 are negative" {
  let handlers : Array[(String, Int32) -> @core.Response] = [
    fn(_value, _n) { { status: 200, body: "safe", } },
    fn(value, _n) { { status: 200, body: "echo: " + value, } },
    fn(_value, _n) { { status: 200, body: "SQLite error: pre-existing", } },
    fn(value, _n) {
      if value == "1" {
        { status: 200, body: "row:1", }
      } else {
        { status: 500, body: "Internal server error", }
      }
    },
  ]
  for handler in handlers {
    let transport = mock((value, n) => handler(value, n))
    let report = @controller.scan(
      "http://example.test/?id=1",
      @core.Options::default(),
      transport,
    )
    assert_eq(report.verdict, NotDetected)
    assert_eq(report.findings.length(), 0)
    assert_eq(report.exit_code(), 0)
  }
}

///|
async test "dynamic baseline and non-success baseline are inconclusive" {
  let handlers : Array[(String, Int32) -> @core.Response] = [
    fn(_value, n) { { status: 200, body: "counter=\{n}", } },
    fn(_value, _n) { { status: 500, body: "failure", } },
    fn(_value, _n) { { status: 302, body: "redirect", } },
  ]
  for handler in handlers {
    let report = @controller.scan(
      "http://example.test/?id=1",
      @core.Options::default(),
      mock((value, n) => handler(value, n)),
    )
    assert_eq(report.verdict, Inconclusive)
    assert_eq(
      report.requests.attempted,
      if report.issues[0].message.contains("stable content") {
        5
      } else {
        3
      },
    )
    assert_eq(report.tested_parameters, 0)
    assert_eq(report.exit_code(), 2)
  }
}

///|
async test "failed confirmation is suspected and restoration drift incomplete" {
  let inconsistent = mock((value, _) => {
    status: 200,
    body: if value.contains("7=8") {
      "row:0"
    } else {
      "row:1"
    },
  })
  let report = @controller.scan(
    "http://example.test/?id=1",
    { ..@core.Options::default(), techniques: [BooleanBased], },
    inconsistent,
  )
  assert_eq(report.verdict, Suspected)
  let drifting = mock((value, n) => {
    status: 200,
    body: if n >= 8 {
      "changed"
    } else if value.contains("7=8") || value.contains("9=10") {
      "row:0"
    } else {
      "row:1"
    },
  })
  let report = @controller.scan(
    "http://example.test/?id=1",
    { ..@core.Options::default(), techniques: [BooleanBased], },
    drifting,
  )
  assert_eq(report.verdict, Inconclusive)
  assert_eq(report.findings.length(), 0)
}

///|
async test "transport failure stops scanning without automatic retry" {
  let transport = mock((_value, n) => {
    if n > 3 {
      raise MockFailure
    }
    { status: 200, body: "row:1", }
  })
  let report = @controller.scan(
    "http://example.test/?id=1",
    @core.Options::default(),
    transport,
  )
  assert_eq(report.exit_code(), 2)
  assert_eq(report.requests.attempted, 4)
  assert_eq(report.requests.failed, 1)
  assert_eq(report.requests.succeeded, 3)
  assert_eq(transport.active, 0)
}

///|
async test "timeout cancels transport and runs resource cleanup" {
  let transport = mock(
    (_value, _n) => { status: 200, body: "row:1", },
    delay_ms=100,
  )
  let report = @controller.scan(
    "http://example.test/?id=1",
    { ..@core.Options::default(), timeout_ms: 5, retries: 0, },
    transport,
  )
  assert_eq(report.exit_code(), 2)
  assert_eq(report.requests.failed, 1)
  assert_eq(report.requests.attempted, 1)
  assert_eq(transport.active, 0)
}

///|
async test "invalid library configuration sends no request" {
  let transport = mock((_value, _n) => { status: 200, body: "unused", })
  for
    (url, opts) in [
      ("bad", @core.Options::default()),
      (
        "http://example.test/?id=1",
        { ..@core.Options::default(), timeout_ms: 0, },
      ),
      (
        "http://example.test/?id=1",
        { ..@core.Options::default(), parameters: ["absent"], },
      ),
    ] {
    let report = @controller.scan(url, opts, transport)
    assert_eq(report.exit_code(), 2)
    assert_eq(report.issues[0].phase, "configuration")
  }
  assert_eq(transport.requests.length(), 0)
}

///|
async test "every duplicate occurrence is scanned with exactly one value changed" {
  let transport = mock((_value, _n) => { status: 200, body: "safe", })
  let options = {
    ..@core.Options::default(),
    data: Some("id=3&token=%C3%A9"),
    parameters: ["id"],
  }
  let url = "http://example.test/?id=1&id=2&empty="
  let original = @parse.target(url, data=options.data.unwrap())
  let report = @controller.scan(url, options, transport)
  assert_eq(report.tested_parameters, 3)
  assert_eq(report.exit_code(), 0)
  assert_eq(report.requests.attempted, transport.requests.length())
  for request in transport.requests {
    let data = request.body
    let current = @parse.target(request.url, data?)
    let mut changes = 0
    for i, parameter in current.query {
      assert_eq(parameter.name, original.query[i].name)
      if parameter.value != original.query[i].value {
        changes += 1
      }
    }
    for i, parameter in current.form.unwrap() {
      assert_eq(parameter.name, original.form.unwrap()[i].name)
      if parameter.value != original.form.unwrap()[i].value {
        changes += 1
      }
    }
    assert_true(changes <= 1)
    assert_true(request.body.unwrap().has_suffix("&token=%C3%A9"))
  }
}

///|
async test "failure after a confirmed finding retains evidence but exits 2" {
  let transport = mock((value, n) => {
    if n >= 8 {
      raise MockFailure
    }
    if value.contains("'") {
      { status: 500, body: "SQLite error: bad token", }
    } else {
      { status: 200, body: "row:1", }
    }
  })
  let report = @controller.scan(
    "http://example.test/?id=1&id=2",
    { ..@core.Options::default(), techniques: [ErrorBased], },
    transport,
  )
  assert_eq(report.verdict, Inconclusive)
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].verdict, Confirmed)
  assert_eq(report.issues[0].index, Some(1))
  assert_eq(report.exit_code(), 2)
}
