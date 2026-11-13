///|
fn report(ctx : @core.ScanContext) -> @core.ScanReport {
  let complete = !ctx.has_errors()
  let verdict = if !complete {
    @core.Inconclusive
  } else if ctx.findings.any(f => f.verdict == Confirmed) {
    Confirmed
  } else if !ctx.findings.is_empty() {
    Suspected
  } else {
    NotDetected
  }
  let databases = ctx.findings
    .filter(f => f.verdict == Confirmed && f.database != Unknown)
    .map(f => f.database)
  let database = match databases.get(0) {
    Some(first) if databases.all(db => db == first) => first
    _ => Unknown
  }
  {
    target: ctx.target.url,
    verdict,
    complete,
    database,
    tested_parameters: ctx.tested_parameters,
    findings: ctx.findings,
    issues: ctx.issues,
    requests: {
      attempted: ctx.attempted,
      succeeded: ctx.succeeded,
      failed: ctx.failed,
      retried: ctx.retried,
      timed_out: ctx.timed_out,
    },
    enumeration: ctx.enumeration,
    injection_points: ctx.points,
    source: ctx.template
    .map(t => t.source)
    .unwrap_or({ kind: "url", origin: ctx.target.url, depth: 0, }),
    restored: ctx.restored,
    elapsed_ms: (ctx.clock.now_ms() - ctx.started).max(0),
  }
}

///|
pub fn configuration_error(
  target : String,
  message : String,
  source? : @core.TargetSource,
) -> @core.ScanReport {
  {
    target,
    verdict: Inconclusive,
    complete: false,
    database: Unknown,
    tested_parameters: 0,
    findings: [],
    issues: [
      {
        fatal: true,
        phase: "configuration",
        message,
        parameter: None,
        location: None,
        index: None,
        request_id: None,
      },
    ],
    requests: {
      attempted: 0,
      succeeded: 0,
      failed: 0,
      retried: 0,
      timed_out: 0,
    },
    enumeration: [],
    injection_points: [],
    source: source.unwrap_or({ kind: "url", origin: target, depth: 0, }),
    restored: false,
    elapsed_ms: 0,
  }
}

///|
/// Compatibility entry point. Session persistence is opt-in for library callers.
pub async fn scan(
  target : String,
  options : @core.Options,
  transport : &@core.Transport,
) -> @core.ScanReport {
  let template = @parse.template(target, options) catch {
    ConfigError(message) => return configuration_error(target, message)
  }
  scan_template(template, options, transport)
}

///|
/// Each control and confirmation sequence runs serially. Clock and session are injectable.
pub async fn scan_template(
  template : @core.RequestTemplate,
  options : @core.Options,
  transport : &@core.Transport,
  clock~ : &@core.Clock = @core.SystemClock::{ },
  session? : &@core.SessionStore,
) -> @core.ScanReport {
  let selected = (fn() raise @core.ConfigError {
    @parse.validate(options)
    @parse.select_template(template, options.parameters, allow_empty=true)
  })() catch {
    ConfigError(message) =>
      return configuration_error(
        template.request.url,
        message,
        source=template.source,
      )
  }
  if options.explicit_techniques && options.dbms != Unknown {
    for kind in options.techniques {
      if !@core.capabilities(options.dbms).techniques.contains(kind) {
        return configuration_error(
          template.request.url,
          "The selected database does not support the explicitly requested technique: \{Repr(kind)}",
          source=template.source,
        )
      }
    }
  }
  let parsed = @parse.target(template.request.url) catch {
    ConfigError(message) =>
      return configuration_error(template.request.url, message)
  }
  let ctx = @core.ScanContext::new(parsed, options, transport, clock~)
  ctx.template = Some(template)
  if selected.is_empty() {
    @techniques.issue(
      ctx, "discovery-empty", "No testable parameters found; injection testing was not performed",
    )
    return report(ctx)
  }
  ctx.session = session
  initialize_session(ctx)
  let samples : Array[@core.Response] = []
  for _ in 0..<3 {
    guard @techniques.send(ctx, "baseline") is Some((r, _)) else {
      return report(ctx)
    }
    samples.push(r)
  }
  if @generic.comparator(samples, options.comparison) is None {
    for _ in 0..<2 {
      guard @techniques.send(ctx, "baseline") is Some((r, _)) else {
        return report(ctx)
      }
      samples.push(r)
    }
  }
  guard @generic.comparator(samples, options.comparison) is Some(compare) else {
    @techniques.issue(
      ctx, "baseline", "Baseline has insufficient stable content or does not meet comparison rules; result is inconclusive",
    )
    return report(ctx)
  }
  ctx.compare = compare
  let baseline = samples[0]
  if (baseline.status < 200 || baseline.status >= 300) &&
    options.comparison.code is None {
    @techniques.issue(
      ctx,
      "baseline",
      "Baseline HTTP status is \{baseline.status}; provide an accessible page or use --code",
    )
    return report(ctx)
  }
  let credentials = ctx.cookies
    .map(c => c.host + ":" + c.path + ":" + c.cookie.name + "=" + c.cookie.value)
    .join("\u{0000}")
  ctx.session_key += ":credentials:" + digest(credentials)
  if session is Some(store) {
    ctx.checkpoint_data = read_session(
      ctx,
      store,
      ctx.session_key + ":checkpoint",
    )
  }
  ctx.baseline_key = digest(
    @generic.comparison_text(baseline.body, options.comparison) +
    "\{baseline.status}",
  )
  for parameter in selected {
    ctx.tested_parameters += 1
    let resumed = resume_parameter(ctx, parameter, baseline)
    if ctx.has_errors() {
      checkpoint(ctx)
      return report(ctx)
    }
    for (kind, detect) in @techniques.registered() {
      if options.techniques.contains(kind) &&
        !(resumed &&
        ctx.findings.any(f => {
          f.location == parameter.location &&
          f.index == parameter.index &&
          f.technique == kind &&
          f.verdict == Confirmed
        })) {
        if options.explicit_techniques {
          let known = ctx.findings
            .iter()
            .find_first(f => {
              f.location == parameter.location &&
              f.index == parameter.index &&
              f.verdict == Confirmed &&
              f.database != Unknown
            })
            .map(f => f.database)
          if known is Some(db) &&
            !@core.capabilities(db).techniques.contains(kind) {
            @techniques.issue(
              ctx,
              "capability",
              "The confirmed database does not support the explicitly requested technique: \{Repr(kind)}",
              parameter~,
            )
            return report(ctx)
          }
        }
        detect(ctx, parameter, baseline)
        if ctx.has_errors() {
          checkpoint(ctx)
          return report(ctx)
        }
      }
    }
    if !@techniques.restore(ctx, baseline, parameter) {
      checkpoint(ctx)
      return report(ctx)
    }
    checkpoint(ctx)
  }
  @techniques.enumerate_metadata(ctx, baseline)
  if options.enumeration.requested() && !ctx.has_errors() {
    ignore(@techniques.restore(ctx, baseline, selected[0]))
  }
  checkpoint(ctx)
  report(ctx)
}
