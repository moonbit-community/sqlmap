///|
pub fn verdict_name(value : @core.Verdict) -> String {
  match value {
    Confirmed => "confirmed"
    Suspected => "suspected"
    NotDetected => "not_detected"
    Inconclusive => "inconclusive"
  }
}

///|
pub fn dbms_name(value : @core.Dbms) -> String {
  match value {
    Unknown => "unknown"
    SQLite => "SQLite"
    MySQL => "MySQL"
    PostgreSQL => "PostgreSQL"
    SQLServer => "SQL Server"
  }
}

///|
fn location_name(value : @core.Location) -> String {
  match value {
    Query => "query"
    Form => "form"
    JsonBody => "json"
    Cookie => "cookie"
    HeaderValue => "header"
    Path => "path"
  }
}

///|
fn technique_name(value : @core.Technique) -> String {
  match value {
    ErrorBased => "error"
    BooleanBased => "boolean"
    UnionBased => "union"
    TimeBased => "time"
  }
}

///|
fn[T : ToJson] nullable(value : T?) -> Json {
  if value is Some(value) {
    value.to_json()
  } else {
    Json::null()
  }
}

///|
/// Stable machine-readable schema, independent of derived enum serialization.
pub fn json(report : @core.ScanReport) -> Json {
  let findings : Array[Json] = report.findings.map(f => {
    "location": location_name(f.location),
    "parameter": f.parameter,
    "index": f.index,
    "technique": technique_name(f.technique),
    "verdict": verdict_name(f.verdict),
    "database": dbms_name(f.database),
    "evidence": {
      "detail": f.evidence.detail,
      "signature": nullable(f.evidence.signature),
      "observations": f.evidence.observations,
    },
  })
  let issues : Array[Json] = report.issues.map(issue => {
    "fatal": issue.fatal,
    "phase": issue.phase,
    "message": issue.message,
    "parameter": nullable(issue.parameter),
    "location": nullable(issue.location.map(location_name)),
    "index": nullable(issue.index),
    "request_id": nullable(issue.request_id),
  })
  {
    "schema_version": 2,
    "target": report.target,
    "verdict": verdict_name(report.verdict),
    "complete": report.complete,
    "database": dbms_name(report.database),
    "tested_parameters": report.tested_parameters,
    "findings": findings,
    "requests": report.requests,
    "issues": issues,
    "exit_code": report.exit_code(),
    "enumeration": report.enumeration.map(e => {
      (
        {
          "kind": e.kind,
          "database": nullable(e.database),
          "table": nullable(e.table),
          "values": e.values,
          "complete": e.complete,
          "cached": e.cached,
          "message": nullable(e.message),
        } : Json)
    }),
    "injection_points": report.injection_points.map(p => {
      (
        {
          "location": location_name(p.location),
          "index": p.index,
          "parameter": p.parameter,
          "database": dbms_name(p.database),
          "technique": technique_name(p.technique),
          "prefix": p.prefix,
          "suffix": p.suffix,
          "union_columns": p.union_columns,
          "union_position": p.union_position,
        } : Json)
    }),
    "source": report.source,
    "restored": report.restored,
    "elapsed_ms": report.elapsed_ms.to_double(),
  }
}

///|
fn text_verdict(value : @core.Verdict) -> String {
  match value {
    Confirmed => "confirmed"
    Suspected => "suspected"
    NotDetected => "not detected"
    Inconclusive => "inconclusive"
  }
}

///|
pub fn text(report : @core.ScanReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "Target: \{report.target}\nVerdict: \{text_verdict(report.verdict)}\nDatabase: \{dbms_name(report.database)}\n",
  )
  out.write_string(
    "Parameters: \{report.tested_parameters}; requests: \{report.requests.attempted} (succeeded \{report.requests.succeeded}, failed \{report.requests.failed})\n",
  )
  for finding in report.findings {
    out.write_string(
      "[\{text_verdict(finding.verdict)}] \{location_name(finding.location)}:\{finding.parameter}[\{finding.index}] / \{technique_name(finding.technique)} / \{dbms_name(finding.database)}\n",
    )
    out.write_string("  \{finding.evidence.detail}\n")
    if finding.evidence.signature is Some(signature) {
      out.write_string("  Error signature: \{signature}\n")
    }
    for observation in finding.evidence.observations {
      out.write_string(
        "  Request #\{observation.request_id}: HTTP \{observation.status}, normalized length \{observation.normalized_length}, matches baseline \{observation.matches_baseline}\n",
      )
    }
  }
  for entry in report.enumeration {
    out.write_string(
      "Metadata [\{entry.kind}]: \{entry.values.join(", ")} (complete \{entry.complete}, cached \{entry.cached})\n",
    )
    if entry.message is Some(message) {
      out.write_string("  \{message}\n")
    }
  }
  for issue in report.issues {
    out.write_string("Issue [\{issue.phase}]: \{issue.message}\n")
  }
  out.to_string()
}

///|
pub fn render(report : @core.ScanReport, format : @core.Format) -> String {
  match format {
    Text => text(report)
    Json => json(report).stringify() + "\n"
  }
}

///|
pub fn render_batch(
  report : @core.BatchReport,
  format : @core.Format,
) -> String {
  let requests = report.reports.fold(
    init=@core.RequestStats::{
      attempted: 0,
      succeeded: 0,
      failed: 0,
      retried: 0,
      timed_out: 0,
    },
    (s, r) => {
      (
        {
          attempted: s.attempted + r.requests.attempted,
          succeeded: s.succeeded + r.requests.succeeded,
          failed: s.failed + r.requests.failed,
          retried: s.retried + r.requests.retried,
          timed_out: s.timed_out + r.requests.timed_out,
        } : @core.RequestStats)
    },
  )
  match format {
    Json =>
      (
        {
          "schema_version": 2,
          "complete": report.complete,
          "exit_code": report.exit_code(),
          "requests": requests,
          "target_count": report.reports
          .filter(r => r.source.kind != "discovery")
          .length(),
          "reports": report.reports.map(json),
        } : Json).stringify() +
      "\n"
    Text =>
      report.reports.map(text).join("\n") +
      "Batch complete: \{report.complete}; target reports: \{report.reports.length()}\n"
  }
}
