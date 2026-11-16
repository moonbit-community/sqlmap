///|
/// The async tests share a schema, so serialize setup, use, and teardown.
let postgres_fixture_lock : @async.Mutex = Mutex()

///|
struct PgFixture {
  client : @pg.Client
  server : @http.Server
  lock : @async.Mutex
}

///|
fn PgFixture::url(self : PgFixture) -> String {
  "http://127.0.0.1:\{self.server.addr.port()}"
}

///|
async fn PgFixture::query(
  self : PgFixture,
  path : String,
  value : String,
) -> @core.Response {
  self.lock.acquire()
  defer self.lock.release()
  let string_query = path == "/string"
  let boolean_only = path == "/boolean" || path == "/hidden"
  let safe = path == "/safe" || path == "/reflect"
  let select = if boolean_only { "id" } else { "name" }
  let sql = "SELECT " +
    select +
    " FROM sqlmap_v02.users WHERE " +
    (if string_query {
      "name='" + value + "'"
    } else if safe {
      "id::text=$1"
    } else {
      "id=" + value
    })
  let sql = if path == "/parenthesis" {
    "SELECT name FROM sqlmap_v02.users WHERE (id=" + value + ")"
  } else {
    sql
  }
  try {
    let stream = if safe {
      self.client.query(sql, params=[value])
    } else {
      self.client.query(sql)
    }
    defer @async.protect_from_cancel(() => ignore(stream.finish()))
    let values : Array[String] = []
    let mut row_count = 0
    while stream.next() is Some(row) {
      if boolean_only {
        row_count += 1
      } else {
        values.push(row.get_text(0).unwrap_or(""))
      }
    }
    {
      status: 200,
      body: if boolean_only {
        "rows=\{row_count}"
      } else if path == "/reflect" {
        "echo=" + value
      } else {
        values.join(" | ")
      },
    }
  } catch {
    @pg.ClientError::Database(_) as err =>
      {
        status: 500,
        body: if path == "/hidden" {
          "Internal server error"
        } else {
          "PostgreSQL error: \{(err : Error)}"
        },
      }
    err => raise err
  }
}

///|
async fn PgFixture::serve(self : PgFixture) -> Unit {
  self.server.run_forever(allow_failure=true) <| ((request, conn) => {
    let raw = conn.text.read_all()
    let target = @parse.target(self.url() + request.path, data=raw)
    let params = if request.meth == Post {
      target.form.unwrap()
    } else {
      target.query
    }
    let value = params.get(0).map(p => p.value).unwrap_or("1")
    let path = request.path.split("?").next().unwrap().to_owned()
    let response = self.query(path, value)
    conn.send_response(
      response.status,
      if response.status == 200 {
        "OK"
      } else {
        "Error"
      },
    )
    conn.write_string(response.body)
    conn.end_response()
  })
}

///|
async fn with_postgres(f : async (PgFixture) -> Unit) -> Unit {
  postgres_fixture_lock.acquire()
  defer postgres_fixture_lock.release()
  let host = @env.get_env_var("POSTGRES_HOST").unwrap_or("127.0.0.1")
  let port = @env.get_env_var("POSTGRES_PORT")
    .map(p => @string.parse_int(p))
    .unwrap_or(5432)
  let user = @env.get_env_var("POSTGRES_USER").unwrap_or("sqlmap")
  let database = @env.get_env_var("POSTGRES_DB").unwrap_or("sqlmap")
  let password = @env.get_env_var("POSTGRES_PASSWORD").unwrap_or("sqlmap")
  let config = @pg.Config(
    host,
    port~,
    user~,
    database~,
    password~,
    ssl_mode=Disable,
    application_name="sqlmap-mbt-integration",
    options="-c search_path=sqlmap_v02",
    connect_timeout_ms=3000,
  )
  let (client, executor) = @pg.Client::create(config)
  defer client.abort()
  @pgasync.with_task_group() <| group => {
    group.spawn_bg(no_wait=true, allow_failure=true, () => executor.run())
    defer client.abort()
    client.ready()
    client.batch_execute(
      (
        #|DROP SCHEMA IF EXISTS sqlmap_v02 CASCADE; CREATE SCHEMA sqlmap_v02; CREATE TABLE sqlmap_v02.users(id int PRIMARY KEY,name text); INSERT INTO sqlmap_v02.users VALUES (1,'alice'),(2,'bob'); CREATE TABLE sqlmap_v02."users_résumés"("résumé_id" int,"na""me" text)
      ),
    )
    defer @async.protect_from_cancel(() => {
      client.batch_execute("DROP SCHEMA sqlmap_v02 CASCADE")
    })
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    let fixture = PgFixture::{ client, server, lock: Mutex(), }
    @async.with_task_group() <| http_group => {
      http_group.spawn_bg(no_wait=true, () => fixture.serve())
      f(fixture)
    }
  }
}
