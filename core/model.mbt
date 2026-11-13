///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) enum Location {
  Query
  Form
  JsonBody
  Cookie
  HeaderValue
  Path
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) enum Technique {
  ErrorBased
  BooleanBased
  UnionBased
  TimeBased
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) enum Dbms {
  Unknown
  SQLite
  MySQL
  PostgreSQL
  SQLServer
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) enum Verdict {
  Confirmed
  Suspected
  NotDetected
  Inconclusive
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct Header {
  name : String
  value : String
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct Parameter {
  location : Location
  index : Int32
  name : String
  value : String
  // Preserve every untouched segment byte-for-byte, including bare keys.
  raw : String
}

///|
#derive(Debug, Eq)
pub(all) struct Target {
  url : String
  base : String
  has_query : Bool
  query : Array[Parameter]
  form : Array[Parameter]?
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct Options {
  data : String?
  parameters : Array[String]
  headers : Array[Header]
  cookie : String?
  techniques : Array[Technique]
  timeout_ms : Int32
  max_response_bytes : Int32
  http_method : String?
  force_ssl : Bool
  retries : Int32
  delay_ms : Int32
  threads : Int32
  time_limit_ms : Int32?
  time_sec : Int32
  drop_set_cookie : Bool
  ignore_redirects : Bool
  dbms : Dbms
  prefix : String?
  suffix : String?
  explicit_techniques : Bool
  union_min : Int32
  union_max : Int32
  comparison : ComparisonRule
  enumeration : EnumerationOptions
  crawl : Int32
  crawl_exclude : String?
  crawl_max_pages : Int32
  forms : Bool
  batch : Bool
  output_dir : String
  session_file : String?
  fresh_queries : Bool
  flush_session : Bool
}

///|
/// Sequential requests; dialect-specific advanced probes are selected by evidence.
pub fn Options::default() -> Options {
  {
    data: None,
    parameters: [],
    headers: [],
    cookie: None,
    techniques: [ErrorBased, BooleanBased, UnionBased, TimeBased],
    timeout_ms: 30000,
    max_response_bytes: 2 * 1024 * 1024,
    http_method: None,
    force_ssl: false,
    retries: 3,
    delay_ms: 0,
    threads: 1,
    time_limit_ms: None,
    time_sec: 5,
    drop_set_cookie: false,
    ignore_redirects: false,
    dbms: Unknown,
    prefix: None,
    suffix: None,
    explicit_techniques: false,
    union_min: 1,
    union_max: 10,
    comparison: ComparisonRule::default(),
    enumeration: EnumerationOptions::default(),
    crawl: 0,
    crawl_exclude: None,
    crawl_max_pages: 100,
    forms: false,
    batch: false,
    output_dir: ".sqlmap-output",
    session_file: None,
    fresh_queries: false,
    flush_session: false,
  }
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct Request {
  http_method : String
  url : String
  headers : Array[Header]
  body : String?
}

///|
#derive(Debug, Eq)
pub(all) struct Response {
  status : Int32
  body : String
}

///|
/// The caller owns the transport. Each send must release per-request resources
/// on success, failure and cancellation. The controller enforces the timeout.
pub(open) trait Transport {
  async fn send(Self, Request, max_response_bytes~ : Int32) -> Response
  async fn exchange(Self, Request, max_response_bytes~ : Int32) -> Exchange = _
}

///|
impl Transport with fn exchange(self, request, max_response_bytes~) {
  let started = Clock::now_ms(SystemClock::{ })
  let response = self.send(request, max_response_bytes~)
  {
    response,
    headers: [],
    cookies: [],
    final_url: request.url,
    elapsed_ms: (Clock::now_ms(SystemClock::{ }) - started).max(0),
  }
}

///|
#derive(Debug)
pub(all) suberror ConfigError {
  ConfigError(String)
}
