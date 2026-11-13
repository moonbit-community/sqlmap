///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) struct Observation {
  request_id : Int32
  status : Int32
  normalized_length : Int32
  matches_baseline : Bool
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) struct Evidence {
  detail : String
  signature : String?
  observations : Array[Observation]
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) struct Finding {
  location : Location
  parameter : String
  index : Int32
  technique : Technique
  verdict : Verdict
  database : Dbms
  evidence : Evidence
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct ScanIssue {
  fatal : Bool
  phase : String
  message : String
  parameter : String?
  location : Location?
  index : Int32?
  request_id : Int32?
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct RequestStats {
  attempted : Int32
  succeeded : Int32
  failed : Int32
  retried : Int32
  timed_out : Int32
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct ScanReport {
  target : String
  verdict : Verdict
  complete : Bool
  database : Dbms
  tested_parameters : Int32
  findings : Array[Finding]
  issues : Array[ScanIssue]
  requests : RequestStats
  enumeration : Array[EnumerationResult]
  injection_points : Array[InjectionPoint]
  source : TargetSource
  restored : Bool
  elapsed_ms : Int64
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct BatchReport {
  reports : Array[ScanReport]
  complete : Bool
}

///|
pub fn BatchReport::exit_code(self : BatchReport) -> Int32 {
  if !self.complete || self.reports.any(r => r.exit_code() == 2) {
    2
  } else if self.reports.any(r => r.exit_code() == 1) {
    1
  } else {
    0
  }
}

///|
/// Incomplete scans always take precedence over positive findings.
pub fn ScanReport::exit_code(self : ScanReport) -> Int32 {
  if !self.complete || self.verdict == Inconclusive {
    2
  } else if self.findings.any(f => {
      f.verdict == Confirmed || f.verdict == Suspected
    }) {
    1
  } else {
    0
  }
}
