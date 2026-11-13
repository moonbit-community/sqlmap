///|
struct ExchangeMock {
  handler : (@core.Request, Int32) -> @core.Exchange
  requests : Array[@core.Request]
}

///|
fn response(
  status : Int32,
  body : String,
  url~ : String = "",
  headers~ : Array[@core.Header] = [],
  cookies~ : Array[@core.ResponseCookie] = [],
) -> @core.Exchange {
  {
    response: { status, body, },
    final_url: url,
    headers,
    cookies,
    elapsed_ms: 0,
  }
}

///|
impl @core.Transport for ExchangeMock with fn send(
  self,
  request,
  max_response_bytes~,
) {
  @core.Transport::exchange(self, request, max_response_bytes~).response
}

///|
impl @core.Transport for ExchangeMock with fn exchange(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  self.requests.push(request)
  (self.handler)(request, self.requests.length())
}

///|
async test "redirects cookies and transport-managed raw headers" {
  let cookie : @core.ResponseCookie = {
    name: "session",
    value: "abc",
    domain: None,
    path: Some("/"),
    secure: false,
    max_age: Some(100),
    expires: None,
  }
  for drop in [false, true] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (r, _) => {
        if r.url.contains("/start") {
          response(
            302,
            "",
            headers=[
              {
                name: "Location",
                value: r.url.replace(old="/start?", new="/end?"),
              },
            ],
            cookies=[cookie],
          )
        } else {
          response(200, "stable")
        }
      },
    }
    let report = @controller.scan(
      "http://a.test/start?id=1",
      {
        ..@core.Options::default(),
        techniques: [ErrorBased],
        drop_set_cookie: drop,
      },
      mock,
    )
    assert_eq(report.exit_code(), 0)
    assert_eq(
      mock.requests[1].headers.any(h => {
        h.name.to_lower() == "cookie" && h.value == "session=abc"
      }),
      !drop,
    )
    assert_true(mock.requests.all(r => r.url.has_prefix("http://a.test/")))
  }
  let cross = ExchangeMock::{
    requests: [],
    handler: (_, _) => {
      response(302, "", headers=[
        { name: "Location", value: "http://other.test/", },
      ])
    },
  }
  assert_eq(
    @controller.scan("http://a.test/?id=1", @core.Options::default(), cross).exit_code(),
    2,
  )
  assert_eq(cross.requests.length(), 1)
  let redirect_loop = ExchangeMock::{
    requests: [],
    handler: (_, _) => {
      response(302, "", headers=[{ name: "Location", value: "/?id=1", }])
    },
  }
  let report = @controller.scan(
    "http://a.test/?id=1",
    @core.Options::default(),
    redirect_loop,
  )
  assert_eq(report.requests.attempted, 11)
  assert_true(report.issues[0].message.contains("10"))
}

///|
struct RetryMock {
  mut count : Int32
  mut active : Int32
}

///|
impl @core.Transport for RetryMock with fn send(
  self,
  _request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  self.count += 1
  self.active += 1
  defer {
    self.active -= 1
  }
  if self.count == 1 {
    @async.sleep(30)
  }
  { status: 200, body: "stable", }
}

///|
async test "successful timeout retry is a warning and completes" {
  let mock = RetryMock::{ count: 0, active: 0, }
  let report = @controller.scan(
    "http://a.test/?id=1",
    { ..@core.Options::default(), techniques: [ErrorBased], timeout_ms: 5, },
    mock,
  )
  assert_eq(report.exit_code(), 0)
  assert_eq(report.requests.retried, 1)
  assert_eq(report.requests.timed_out, 1)
  assert_eq(report.requests.failed, 1)
  assert_eq(
    report.requests.attempted,
    report.requests.succeeded + report.requests.failed,
  )
  assert_false(report.issues[0].fatal)
  assert_eq(mock.active, 0)
}

///|
struct FakeClock {
  mut time : Int64
}

///|
impl @core.Clock for FakeClock with fn now_ms(self) {
  self.time
}

///|
struct TimedMock {
  clock : FakeClock
  mode : String
  mut count : Int32
}

///|
impl @core.Transport for TimedMock with fn send(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  self.count += 1
  if self.mode == "retried" && self.count == 4 {
    @async.with_timeout(1, () => @async.sleep(10))
  }
  let t = @parse.target(request.url)
  let value = t.query[0].value
  let delayed = value.contains("pg_sleep(1)")
  self.clock.time += if self.mode == "jitter" && self.count % 2 == 0 {
    700
  } else if delayed {
    1020
  } else {
    20
  }
  if self.mode == "backwards" && delayed {
    self.clock.time -= 3000
  }
  {
    status: 200,
    body: if self.mode == "reflection" {
      value
    } else {
      "row:1"
    },
  }
}

///|
async test "PostgreSQL timing independent confirmation and false-positive controls" {
  for mode in ["delay", "jitter", "backwards", "reflection", "retried"] {
    let clock = FakeClock::{ time: 10000, }
    let mock = TimedMock::{ clock, mode, count: 0, }
    let opts = {
      ..@core.Options::default(),
      techniques: [TimeBased],
      dbms: PostgreSQL,
      time_sec: 1,
    }
    let t = @parse.template("http://a.test/?id=1", opts)
    let report = @controller.scan_template(t, opts, mock, clock~)
    if mode == "delay" {
      assert_eq(report.exit_code(), 1)
      assert_eq(report.database, PostgreSQL)
      assert_eq(report.findings[0].technique, TimeBased)
    } else {
      assert_true(report.findings.is_empty())
      if mode == "backwards" || mode == "retried" {
        assert_eq(report.exit_code(), 2)
      }
      if mode == "retried" {
        assert_eq(report.requests.retried, 1)
        assert_eq(report.requests.timed_out, 1)
      }
    }
  }
  let mock = ExchangeMock::{
    requests: [],
    handler: (_, _) => response(200, "stable"),
  }
  let report = @controller.scan(
    "http://a.test/?id=1",
    {
      ..@core.Options::default(),
      techniques: [TimeBased],
      dbms: SQLite,
      explicit_techniques: true,
    },
    mock,
  )
  assert_eq(report.exit_code(), 2)
  assert_true(mock.requests.is_empty())
}

///|
struct ConcurrentMock {
  mut active : Int32
  mut max_active : Int32
  origins : Map[String, Int32]
  mut overlap : Bool
}

///|
impl @core.Transport for ConcurrentMock with fn send(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  let origin = @parse.origin(request.url)
  let active = self.origins.get(origin).unwrap_or(0)
  if active > 0 {
    self.overlap = true
  }
  self.origins[origin] = active + 1
  self.active += 1
  self.max_active = self.max_active.max(self.active)
  defer {
    self.active -= 1
    self.origins[origin] -= 1
  }
  @async.sleep(2)
  { status: 200, body: "stable", }
}

///|
async test "batch worker limit and same-origin serialization" {
  let mock = ConcurrentMock::{
    active: 0,
    max_active: 0,
    origins: Map([]),
    overlap: false,
  }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    threads: 2,
  }
  let ts = [
    "http://a.test/?id=1", "http://a.test/?id=2", "http://b.test/?id=1", "http://c.test/?id=1",
  ].map(u => try! @parse.template(u, opts))
  let batch = @controller.scan_batch(ts, opts, mock)
  assert_eq(batch.exit_code(), 0)
  assert_eq(batch.reports.length(), 4)
  assert_true(mock.max_active <= 2 && mock.max_active > 1)
  assert_false(mock.overlap)
}

///|
async test "UNION reflection negative control rejects reconstructed request text" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      let value = (try! @parse.target(r.url)).query[0].value
      response(200, value.replace(old="'||'", new=""))
    },
  }
  let report = @controller.scan(
    "http://a.test/?id=1",
    {
      ..@core.Options::default(),
      techniques: [UnionBased],
      dbms: SQLite,
      union_max: 1,
    },
    mock,
  )
  assert_eq(report.exit_code(), 0)
  assert_true(report.findings.is_empty())
}

///|
async test "runtime limit preserves reports and batch continues past a failed target" {
  let clock = FakeClock::{ time: 10000, }
  let transport = TimedMock::{ clock, mode: "delay", count: 0, }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    time_limit_ms: Some(45),
  }
  let templates = ["http://a.test/?id=1", "http://b.test/?id=1"].map(url => {
    try! @parse.template(url, opts)
  })
  let batch = @controller.scan_batch(templates, opts, transport, clock~)
  assert_eq(batch.exit_code(), 2)
  assert_eq(batch.reports.length(), 2)
  assert_true(batch.reports[0].requests.succeeded > 0)
  assert_false(batch.reports[1].complete)
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      response(if r.url.contains("a.test") { 500 } else { 200 }, "stable")
    },
  }
  let batch = @controller.scan_batch(
    templates,
    { ..opts, time_limit_ms: None, },
    mock,
  )
  assert_eq(batch.exit_code(), 2)
  assert_true(batch.reports[1].complete)
}

///|
async test "Cookie secure path and expired GMT date are enforced" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      let cookies : Array[@core.ResponseCookie] = if r.url.contains("/start") {
        [
          {
            name: "expired",
            value: "x",
            domain: None,
            path: Some("/"),
            secure: false,
            max_age: None,
            expires: Some("Sun, 06 Nov 1994 08:49:37 GMT"),
          },
          {
            name: "secure",
            value: "x",
            domain: None,
            path: Some("/"),
            secure: true,
            max_age: None,
            expires: None,
          },
          {
            name: "wrongpath",
            value: "x",
            domain: None,
            path: Some("/private"),
            secure: false,
            max_age: None,
            expires: None,
          },
          {
            name: "good",
            value: "yes",
            domain: None,
            path: Some("/"),
            secure: false,
            max_age: None,
            expires: None,
          },
        ]
      } else {
        []
      }
      if r.url.contains("/start") {
        response(
          302,
          "",
          headers=[
            {
              name: "Location",
              value: r.url.replace(old="/start?", new="/public?"),
            },
          ],
          cookies~,
        )
      } else {
        response(200, "stable")
      }
    },
  }
  let report = @controller.scan(
    "http://a.test/start?id=1",
    { ..@core.Options::default(), techniques: [ErrorBased], },
    mock,
  )
  assert_eq(report.exit_code(), 0)
  let cookies = mock.requests[1].headers
    .filter(h => h.name.to_lower() == "cookie")
    .map(h => h.value)
    .join("; ")
  assert_eq(cookies, "good=yes")
}
