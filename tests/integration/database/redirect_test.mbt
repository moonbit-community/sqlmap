///|
struct RedirectedMetadata {
  db : @database.Database
  requests : Array[@core.Request]
}

///|
impl @core.Transport for RedirectedMetadata with fn send(
  self,
  request,
  max_response_bytes~,
) {
  @core.Transport::exchange(self, request, max_response_bytes~).response
}

///|
impl @core.Transport for RedirectedMetadata with fn exchange(
  self,
  request,
  max_response_bytes~,
) {
  let _ = max_response_bytes
  self.requests.push(request)
  let value = @parse.target(request.url).query[0].value
  let redirects = value.contains("pragma_table_xinfo")
  {
    response: if redirects {
      { status: 302, body: "", }
    } else {
      self.db.query("/union", value)
    },
    headers: if redirects {
      [{ name: "Location", value: "/login", }]
    } else {
      []
    },
    cookies: [],
    final_url: request.url,
    elapsed_ms: 0,
  }
}

///|
async test "lost redirect coverage also stops metadata fallback requests and retains earlier findings" {
  let db = @database.Database::new()
  defer db.close()
  let transport = RedirectedMetadata::{ db, requests: [], }
  let report = @controller.scan(
    "http://fixture.test/union?id=1",
    {
      ..@core.Options::default(),
      techniques: [UnionBased],
      dbms: SQLite,
      union_max: 1,
      enumeration: {
        ..@core.EnumerationOptions::default(),
        columns: true,
        table: Some("users"),
      },
    },
    transport,
  )
  assert_eq(report.exit_code(), 2)
  assert_true(report.findings.any(f => f.verdict == Confirmed))
  assert_eq(report.tested_parameters, 1)
  assert_eq(
    report.issues.filter(i => i.phase == "redirect-coverage").length(),
    1,
  )
  assert_false(report.enumeration[0].complete)
  let last = transport.requests[transport.requests.length() - 1]
  assert_true(
    @parse.target(last.url).query[0].value.contains("pragma_table_xinfo"),
  )
  assert_eq(report.requests.attempted, transport.requests.length())
}
