///|
/// Per-scan state, replacing implicit global configuration and knowledge.
pub(all) struct ScanContext {
  target : Target
  options : Options
  transport : &Transport
  mut attempted : Int32
  mut succeeded : Int32
  mut failed : Int32
  mut tested_parameters : Int32
  findings : Array[Finding]
  issues : Array[ScanIssue]
  mut template : RequestTemplate?
  clock : &Clock
  started : Int64
  mut last_request : Int64
  mut last_elapsed : Int64
  mut last_retried : Bool
  mut clock_valid : Bool
  mut retried : Int32
  mut timed_out : Int32
  mut compare : (Response, Response) -> Bool
  points : Array[InjectionPoint]
  enumeration : Array[EnumerationResult]
  cookies : Array[StoredCookie]
  mut restored : Bool
  mut session : &SessionStore?
  mut session_key : String
  mut baseline_key : String
  mut checkpoint_data : String?
}

///|
pub fn ScanContext::new(
  target : Target,
  options : Options,
  transport : &Transport,
  clock~ : &Clock = SystemClock::{ },
) -> ScanContext {
  {
    target,
    options,
    transport,
    attempted: 0,
    succeeded: 0,
    failed: 0,
    tested_parameters: 0,
    findings: [],
    issues: [],
    template: None,
    clock,
    started: clock.now_ms(),
    last_request: -1,
    last_elapsed: 0,
    last_retried: false,
    clock_valid: true,
    retried: 0,
    timed_out: 0,
    compare: (a, b) => a == b,
    points: [],
    enumeration: [],
    cookies: [],
    restored: false,
    session: None,
    session_key: "",
    baseline_key: "",
    checkpoint_data: None,
  }
}

///|
pub fn ScanContext::has_errors(self : ScanContext) -> Bool {
  self.issues.any(i => i.fatal)
}

///|
pub(all) struct SystemClock {}

///|
pub impl Clock for SystemClock with fn now_ms(_self) {
  @async.now()
}

///|
pub(all) struct StoredCookie {
  cookie : ResponseCookie
  host : String
  path : String
  expires_at : Int64?
}
