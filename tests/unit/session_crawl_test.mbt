///|
struct MemorySession {
  values : Map[String, String]
}

///|
impl @core.SessionStore for MemorySession with fn get(self, key) {
  self.values.get(key)
}

///|
impl @core.SessionStore for MemorySession with fn put(self, key, value) {
  self.values[key] = value
}

///|
impl @core.SessionStore for MemorySession with fn remove_prefix(self, prefix) {
  for key in self.values.keys().to_array() {
    if key.has_prefix(prefix) {
      self.values.remove(key)
    }
  }
}

///|
struct FailingSession {
  mut reads : Int32
  mut writes : Int32
  mut clears : Int32
}

///|
impl @core.SessionStore for FailingSession with fn get(self, key) {
  let _ = key
  self.reads += 1
  raise MockFailure
}

///|
impl @core.SessionStore for FailingSession with fn put(self, key, value) {
  let _ = (key, value)
  self.writes += 1
  raise MockFailure
}

///|
impl @core.SessionStore for FailingSession with fn remove_prefix(self, prefix) {
  let _ = prefix
  self.clears += 1
  raise MockFailure
}

///|
async test "custom session failures stay nonfatal during crawling and scanning" {
  let store = FailingSession::{ reads: 0, writes: 0, clears: 0, }
  let mock = ExchangeMock::{
    requests: [],
    handler: (_, _) => response(200, "<a href='/child?id=2'>child</a>"),
  }
  for flush_session in [false, true] {
    let opts = {
      ..@core.Options::default(),
      techniques: [ErrorBased],
      crawl: 1,
      flush_session,
    }
    let seed = @parse.template("http://a.test/?id=1", opts)
    let batch = @controller.scan_batch([seed], opts, mock, session=store)
    assert_eq(batch.exit_code(), 0)
    assert_true(batch.reports.all(r => r.issues.all(i => !i.fatal)))
    assert_true(batch.reports.any(r => r.issues.any(i => i.phase == "session")))
  }
  assert_true(store.reads > 0 && store.writes > 0 && store.clears > 0)
}

///|
async test "invalid JSON and incompatible session records are ignored" {
  let store = MemorySession::{ values: Map([]), }
  let opts = { ..@core.Options::default(), techniques: [ErrorBased], crawl: 1, }
  let seed = @parse.template("http://a.test/?id=1", opts)
  let mock = ExchangeMock::{
    requests: [],
    handler: (_, _) => response(200, "<a href='/child?id=2'>child</a>"),
  }
  assert_eq(
    @controller.scan_batch([seed], opts, mock, session=store).exit_code(),
    0,
  )
  assert_false(store.values.is_empty())
  for invalid in ["{", "{}"] {
    for key in store.values.keys().to_array() {
      store.values[key] = invalid
    }
    let batch = @controller.scan_batch([seed], opts, mock, session=store)
    assert_eq(batch.exit_code(), 0)
    assert_true(batch.reports.all(r => !r.restored))
    assert_true(
      batch.reports.any(r => r.issues.any(i => i.phase == "session" && !i.fatal)),
    )
  }
}

///|
async test "session revalidates evidence and invalidates request credentials and config" {
  let store = MemorySession::{ values: Map([]), }
  let opts = {
    ..@core.Options::default(),
    techniques: [BooleanBased],
    headers: [{ name: "Authorization", value: "Bearer secret-value", }],
  }
  let template = @parse.template("http://a.test/?id=1", opts)
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      let value = (try! @parse.target(r.url)).query[0].value
      response(
        200,
        if value.contains("7=8") || value.contains("9=10") {
          "row:0"
        } else {
          "row:1"
        },
      )
    },
  }
  let first = @controller.scan_template(template, opts, mock, session=store)
  assert_eq(first.exit_code(), 1)
  assert_false(first.restored)
  let second = @controller.scan_template(template, opts, mock, session=store)
  assert_true(second.restored)
  assert_eq(second.findings.length(), 1)
  assert_true(
    store.values
    .iter()
    .all(pair => {
      !pair.0.contains("secret-value") && !pair.1.contains("secret-value")
    }),
  )
  let changed = { ..opts, cookie: Some("session=other"), }
  assert_false(
    @controller.scan_template(
      @parse.template("http://a.test/?id=1", changed),
      changed,
      mock,
      session=store,
    ).restored,
  )
  let safe = ExchangeMock::{
    requests: [],
    handler: (_, _) => response(200, "row:1"),
  }
  let report = @controller.scan_template(template, opts, safe, session=store)
  assert_false(report.restored)
  assert_eq(report.exit_code(), 0)
  assert_false(
    @controller.scan_template(
      template,
      { ..opts, flush_session: true, },
      mock,
      session=store,
    ).restored,
  )
}

///|
async test "crawl BFS loops same-origin forms cap and resume" {
  let store = MemorySession::{ values: Map([]), }
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      let path = r.url.split("?").next().unwrap().to_owned()
      response(
        200,
        if path.has_suffix("/root") {
          (
            #|<a href='sub/../a?id=1#fragment'>one</a><a href='/a?id=1#other'>duplicate</a><a href='http://other.test/?id=1'>external</a><form action='/form' method='post'><input name='q' value='café'><input name='off' disabled><input name='checkbox' type='checkbox'><select name='s'><option value='first'>A</option></select></form>
          )
        } else if path.has_suffix("/a") {
          (
            #|<a href='/root'>loop</a><a href='/b?id=2'>two</a>
          )
        } else {
          "stable"
        },
      )
    },
  }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    crawl: 3,
    forms: true,
    crawl_max_pages: 1,
  }
  let seed = @parse.template("http://a.test/root", opts)
  let first = @controller.scan_batch([seed], opts, mock, session=store)
  assert_eq(first.exit_code(), 2)
  assert_true(first.reports.any(r => r.source.kind == "form"))
  assert_true(mock.requests.all(r => !r.url.contains("other.test")))
  assert_true(mock.requests.any(r => r.body == Some("q=caf%C3%A9&s=first")))
  let before = mock.requests.length()
  let second = @controller.scan_batch(
    [seed],
    { ..opts, crawl_max_pages: 10, },
    mock,
    session=store,
  )
  assert_true(second.reports.any(r => r.target.contains("/a?id=1")))
  assert_true(mock.requests[before].url.contains("/a?id=1"))
  assert_false(mock.requests[before:].iter().any(r => r.url.contains("#")))
}

///|
test "SQLite column DDL honors constraints quotes comments and nested commas" {
  assert_eq(
    @parse.sqlite_columns(
      (
        #|CREATE TABLE "x"("résumé_id" int, `a``b` text DEFAULT ('a,b'), [c] numeric(10,2), d TEXT /*,comment*/, CONSTRAINT pk PRIMARY KEY("résumé_id"), CHECK(d!=''))
      ),
    ),
    Some(["résumé_id", "a`b", "c", "d"]),
  )
  assert_eq(
    @parse.sqlite_columns(
      (
        #|CREATE TABLE x("😀" TEXT, /*here*/ normal INT)
      ),
    ),
    Some(["😀", "normal"]),
  )
  assert_eq(@parse.sqlite_columns("CREATE TABLE x(a TEXT"), None)
}

///|
suberror InterruptedScan

///|
struct InterruptedEvidence {
  mut interrupt : Bool
}

///|
impl @core.Transport for InterruptedEvidence with fn send(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  let value = (try! @parse.target(request.url)).query[0].value
  if self.interrupt && value.contains("AND 7=7") {
    self.interrupt = false
    raise InterruptedScan
  }
  if value.contains("'") {
    { status: 500, body: "SQLite error: bad token", }
  } else {
    {
      status: 200,
      body: if value.contains("7=8") || value.contains("9=10") {
        "row:0"
      } else {
        "row:1"
      },
    }
  }
}

///|
async test "resuming an error finding still runs unfinished boolean detection" {
  let store = MemorySession::{ values: Map([]), }
  let transport = InterruptedEvidence::{ interrupt: true, }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased, BooleanBased],
  }
  let template = @parse.template("http://a.test/?id=1", opts)
  let interrupted = @controller.scan_template(
    template,
    opts,
    transport,
    session=store,
  )
  assert_eq(interrupted.exit_code(), 2)
  assert_eq(interrupted.findings.length(), 1)
  let resumed = @controller.scan_template(
    template,
    opts,
    transport,
    session=store,
  )
  assert_eq(resumed.exit_code(), 1)
  assert_true(resumed.restored)
  assert_true(
    resumed.findings.any(f => {
      f.technique == BooleanBased && f.verdict == Confirmed
    }),
  )
}
