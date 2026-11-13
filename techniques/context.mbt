///|
pub fn issue(
  ctx : @core.ScanContext,
  phase : String,
  message : String,
  parameter? : @core.Parameter,
  request_id? : Int32,
  fatal~ : Bool = true,
) -> Unit {
  ctx.issues.push({
    fatal,
    phase,
    message,
    parameter: parameter.map(p => p.name),
    location: parameter.map(p => p.location),
    index: parameter.map(p => p.index),
    request_id,
  })
}

///|
/// Timeout wraps the complete exchange, including DNS, headers and body.
pub async fn send(
  ctx : @core.ScanContext,
  phase : String,
  parameter? : @core.Parameter,
  value? : String,
) -> (@core.Response, Int32)? {
  let replacement = match (parameter, value) {
    (Some(p), Some(value)) => Some((p, value))
    _ => None
  }
  let request = if ctx.template is Some(template) {
    @parse.render_template(template, replacement?)
  } else {
    @parse.request(ctx.target, ctx.options, replacement?)
  }
  exchange(ctx, request, phase, parameter?).map(pair => {
    (pair.0.response, pair.1)
  })
}

///|
pub async fn restore(
  ctx : @core.ScanContext,
  baseline : @core.Response,
  parameter : @core.Parameter,
) -> Bool {
  guard send(ctx, "control", parameter~) is Some((response, id)) else {
    return false
  }
  if !(ctx.compare)(baseline, response) {
    issue(
      ctx,
      "control",
      "The original request differed from the baseline after probing; page or session state changed",
      parameter~,
      request_id=id,
    )
    false
  } else {
    true
  }
}

///|
pub fn finding(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  technique : @core.Technique,
  verdict : @core.Verdict,
  database : @core.Dbms,
  evidence : @core.Evidence,
) -> Unit {
  ctx.findings.push({
    location: parameter.location,
    parameter: parameter.name,
    index: parameter.index,
    technique,
    verdict,
    database,
    evidence,
  })
}
