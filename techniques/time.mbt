///|
pub async fn detect_time(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
) -> Unit {
  if !dialects(ctx, parameter).contains(PostgreSQL) {
    return
  }
  if ctx.options.timeout_ms <= ctx.options.time_sec * 1000 {
    issue(
      ctx,
      "time",
      "Time detection requires --timeout to exceed --time-sec",
      parameter~,
    )
    return
  }
  // Three controls calibrate the network before trying any delay expression.
  let controls : Array[Int64] = []
  for _ in 0..<3 {
    guard send(ctx, "time-calibration", parameter~) is Some((r, _)) else {
      return
    }
    if ctx.last_retried || !ctx.clock_valid || !(ctx.compare)(baseline, r) {
      issue(
        ctx,
        "time",
        "Time calibration included retries, page changes or clock anomalies; result is inconclusive",
        parameter~,
      )
      return
    }
    controls.push(ctx.last_elapsed)
  }
  let low = controls.fold(init=controls[0], (a, b) => a.min(b))
  let high = controls.fold(init=controls[0], (a, b) => a.max(b))
  let delay = ctx.options.time_sec.to_int64() * 1000
  if high - low > delay / 4 {
    issue(
      ctx,
      "time",
      "Network latency varies too much; time detection is inconclusive",
      parameter~,
    )
    return
  }
  let mut uncertain = false
  for boundary in boundaries(ctx, parameter) {
    let observations : Array[@core.Observation] = []
    let mut valid = true
    // Alternating controls on both sides of two independently conditioned delays.
    for round in 0..<2 {
      guard send(ctx, "time-control", parameter~) is Some((before, _)) else {
        return
      }
      uncertain = uncertain || ctx.last_retried
      let before_ms = ctx.last_elapsed
      let clean = !ctx.last_retried &&
        ctx.clock_valid &&
        (ctx.compare)(baseline, before)
      let condition = if round == 0 { "7=7" } else { "9=9" }
      let payload = boundary.prefix +
        " AND (SELECT CASE WHEN " +
        condition +
        " THEN 1 ELSE 0 END FROM pg_sleep(" +
        ctx.options.time_sec.to_string() +
        "))=1 " +
        boundary.suffix
      guard send(ctx, "time-delay", parameter~, value=payload)
        is Some((slow, id)) else {
        return
      }
      uncertain = uncertain || ctx.last_retried
      if !ctx.clock_valid {
        issue(
          ctx,
          "time",
          "Clock moved backward; time detection is inconclusive",
          parameter~,
        )
        return
      }
      let elapsed = ctx.last_elapsed
      let clean = clean &&
        !ctx.last_retried &&
        ctx.clock_valid &&
        (ctx.compare)(baseline, slow)
      guard send(
          ctx,
          "time-negative-control",
          parameter~,
          value=boundary.prefix +
            " AND (SELECT 1 FROM pg_sleep(0))=1 " +
            boundary.suffix,
        )
        is Some((after, _)) else {
        return
      }
      uncertain = uncertain || ctx.last_retried
      if !ctx.clock_valid {
        issue(
          ctx,
          "time",
          "Clock moved backward; time detection is inconclusive",
          parameter~,
        )
        return
      }
      let control = before_ms.max(ctx.last_elapsed).max(high)
      if !clean ||
        ctx.last_retried ||
        !ctx.clock_valid ||
        !(ctx.compare)(baseline, after) ||
        elapsed - control < delay * 4 / 5 ||
        elapsed - control > delay * 2 ||
        ctx.last_elapsed - low > delay / 4 {
        valid = false
        break
      }
      observations.push(@generic.observation(slow, baseline, id))
    }
    if valid && restore(ctx, baseline, parameter) {
      let p = point(
        parameter,
        PostgreSQL,
        TimeBased,
        boundary.prefix,
        boundary.suffix,
      )
      ctx.points.push(p)
      finding(ctx, parameter, TimeBased, Confirmed, PostgreSQL, {
        detail: "PostgreSQL delays were independently reproduced in two interleaved control pairs; retry, timeout and clock anomaly samples were excluded",
        signature: None,
        observations,
      })
      return
    }
    if ctx.has_errors() {
      return
    }
  }
  if uncertain && !ctx.has_errors() {
    issue(
      ctx,
      "time",
      "Timing samples included retries; no independent valid timing evidence was obtained",
      parameter~,
    )
  }
}
