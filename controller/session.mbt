///|
pub fn digest(value : String) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(value)))
}

///|
#derive(ToJson, FromJson)
priv struct Checkpoint {
  baseline : String
  findings : Array[@core.Finding]
}

///|
fn initialize_session(ctx : @core.ScanContext) -> Unit {
  let request = ctx.template
    .map(t => @parse.render_template(t))
    .unwrap_or(@parse.request(ctx.target, ctx.options))
  // Hash the entire request, including credential values. Persist no request/header text.
  let target_key = "v2:" + digest(request.to_json().stringify()) + ":"
  let config = {
    ..ctx.options,
    output_dir: "",
    session_file: None,
    fresh_queries: false,
    flush_session: false,
    batch: false,
    time_limit_ms: None,
  }
  ctx.session_key = target_key +
    digest(config.to_json().stringify() + ":plugins-0.2.0")
  if ctx.session is Some(store) {
    if ctx.options.flush_session {
      clear_session(ctx, store, target_key, "Failed to clear cache")
    }
  }
}

///|
async fn resume_parameter(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
) -> Bool {
  if ctx.session is None {
    return false
  }
  let cached : Checkpoint? = (fn() raise {
    ctx.checkpoint_data.map(raw => @json.from_json(@json.parse(raw)))
  })() catch {
    @json.ParseError::_ | @json.JsonDecodeError::_ as err => {
      @techniques.issue(
        ctx,
        "session",
        "Failed to read session: \{err}",
        fatal=false,
      )
      None
    }
    err => raise err
  }
  guard cached is Some(cached) && cached.baseline == ctx.baseline_key else {
    return false
  }
  let findings = cached.findings.filter(f => {
    f.location == parameter.location &&
    f.index == parameter.index &&
    f.verdict == Confirmed
  })
  if findings.is_empty() {
    return false
  }
  let before = ctx.findings.length()
  let before_points = ctx.points.length()
  for (kind, detect) in @techniques.registered() {
    if ctx.options.techniques.contains(kind) &&
      findings.any(f => f.technique == kind) {
      detect(ctx, parameter, baseline)
      if ctx.has_errors() {
        return false
      }
    }
  }
  let restored = ctx.findings.length() > before &&
    findings.all(f => {
      ctx.findings[before:]
      .iter()
      .any(new => {
        new.technique == f.technique &&
        new.verdict == Confirmed &&
        new.database == f.database
      })
    })
  if restored {
    ctx.restored = true
  } else {
    while ctx.findings.length() > before {
      ignore(ctx.findings.pop())
    }
    while ctx.points.length() > before_points {
      ignore(ctx.points.pop())
    }
  }
  restored
}

///|
fn checkpoint(ctx : @core.ScanContext) -> Unit {
  if ctx.session is Some(store) {
    let state : Checkpoint = {
      baseline: ctx.baseline_key,
      findings: ctx.findings,
    }
    write_session(
      ctx,
      store,
      ctx.session_key + ":checkpoint",
      @json.ToJson::to_json(state).stringify(),
      "Failed to write checkpoint",
    )
  }
}

///|
// SessionStore is an open interface. Storage failures are nonfatal and become report issues.
fn read_session(
  ctx : @core.ScanContext,
  store : &@core.SessionStore,
  key : String,
) -> String? {
  store.get(key) catch {
    err => {
      @techniques.issue(
        ctx,
        "session",
        "Failed to read session: \{err}",
        fatal=false,
      )
      None
    }
  }
}

///|
fn write_session(
  ctx : @core.ScanContext,
  store : &@core.SessionStore,
  key : String,
  value : String,
  message : String,
) -> Unit {
  store.put(key, value) catch {
    err => @techniques.issue(ctx, "session", "\{message}: \{err}", fatal=false)
  }
}

///|
fn clear_session(
  ctx : @core.ScanContext,
  store : &@core.SessionStore,
  prefix : String,
  message : String,
) -> Unit {
  store.remove_prefix(prefix) catch {
    err => @techniques.issue(ctx, "session", "\{message}: \{err}", fatal=false)
  }
}
