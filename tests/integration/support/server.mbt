///|
pub struct Fixture {
  server : @http.Server
  db : @database.Database
  mut requests : Int32
  mut active : Int32
  mut closed : Bool
  mut last_headers : @http.Headers
  paths : Array[String]
  bodies : Array[String]
}

///|
/// Always loopback, with a kernel-assigned ephemeral port.
pub async fn Fixture::start() -> Fixture {
  let db = @database.Database::new()
  errdefer db.close()
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  {
    server,
    db,
    requests: 0,
    active: 0,
    closed: false,
    last_headers: Map([]),
    paths: [],
    bodies: [],
  }
}

///|
pub fn Fixture::url(self : Fixture) -> String {
  "http://127.0.0.1:\{self.server.addr.port()}"
}

///|
pub fn Fixture::close(self : Fixture) -> Unit raise {
  if !self.closed {
    self.closed = true
    self.server.close()
    self.db.close()
  }
}

///|
pub async fn Fixture::serve(self : Fixture) -> Unit {
  self.server.run_forever(allow_failure=true) <| ((request, conn) => {
    self.active += 1
    defer {
      self.active -= 1
    }
    self.requests += 1
    self.last_headers = request.headers
    self.paths.push(request.path)
    let body = conn.text.read_all()
    self.bodies.push(body)
    let target = @parse.target(self.url() + request.path, data=body)
    let route = request.path.split("?").next().unwrap().to_owned()
    let query = target.query
    let form = target.form.unwrap()
    // Form parameters take precedence when the request is POST.
    let parameters = if request.meth == Post { form } else { query }
    let name = if route == "/string" { "name" } else { "id" }
    let value = parameters
      .iter()
      .find_first(p => p.name == name)
      .map(p => p.value)
      .unwrap_or("1")
    let value = if route == "/json" {
      match
        (@json.parse(body) catch {
          InvalidChar(_, _)
          | InvalidEof
          | InvalidNumber(_, _)
          | InvalidIdentEscape(_)
          | DuplicateKey(_, _)
          | DepthLimitExceeded => Json::null()
        }) {
        { "filter": { "id": String(value), .. }, .. } => value
        { "filter": { "id": Number(n, ..), .. }, .. } => n.to_string()
        _ => "1"
      }
    } else if route == "/cookie" {
      request.headers
      .get(CaseInsensitiveString("Cookie"))
      .unwrap_or("")
      .split(";")
      .find_first(p => p.trim().has_prefix("id="))
      .map(p => p.trim().to_owned()[3:].to_owned())
      .unwrap_or("1")
    } else if route == "/header" {
      request.headers.get(CaseInsensitiveString("X-Id")).unwrap_or("1")
    } else {
      value
    }
    let response = self.db.query(route, value)
    if route == "/slow" {
      @async.sleep(200)
    }
    let response : @core.Response = match route {
      "/reflect" =>
        { status: response.status, body: response.body + " echo=" + value, }
      "/existing-error" =>
        { status: 200, body: "SQLite error: pre-existing banner", }
      "/dynamic" =>
        { status: 200, body: response.body + " request=\{self.requests}", }
      "/generic-500" if value != "1" =>
        { status: 500, body: "Internal server error", }
      "/headers" => { status: 200, body: "headers-ok", }
      "/large" => { status: 200, body: "x".repeat(4096), }
      "/empty" => { status: 200, body: "<p>No inputs</p>", }
      "/post-only" =>
        {
          status: 200,
          body: (
            #|<form action='/numeric' method='post'><input name='id' value='1'></form>
          ),
        }
      "/login" =>
        {
          status: 200,
          body: (
            #|<a href='/login#self'>self</a><a href='/root'>alias</a><a href='/second?id=1#part'>second</a>
          ),
        }
      "/second" => { status: 200, body: "<a href='/login'>visited</a>", }
      _ => response
    }
    let redirect = match route {
      "/redirect" => Some((302, "/numeric?" + query.map(p => p.raw).join("&")))
      "/rewrite" => Some((302, "/numeric?id=1"))
      "/private" | "/root" => Some((302, "/login#entry"))
      "/post-302" => Some((302, "/numeric"))
      "/post-307" => Some((307, "/numeric"))
      "/post-308" => Some((308, "/numeric"))
      _ => None
    }
    if redirect is Some((status, location)) {
      conn.send_response(status, "Redirect", extra_headers={
        "Location": location,
      })
    } else {
      conn.send_response(
        response.status,
        if response.status == 200 {
          "OK"
        } else {
          "Internal Server Error"
        },
      )
    }
    conn.write_string(response.body)
    conn.end_response()
  })
}

///|
pub async fn with_fixture(f : async (Fixture) -> Unit) -> Unit {
  let fixture = Fixture::start()
  defer fixture.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, () => fixture.serve())
    f(fixture)
  }
}
