///|
fn successful(ctx : @core.ScanContext, response : @core.Response) -> Bool {
  ctx.options.comparison.code is Some(_) ||
  (response.status >= 200 && response.status < 300)
}

///|
pub async fn detect_boolean(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
) -> Unit {
  let probes = if ctx.options.prefix is None && ctx.options.suffix is None {
    boolean_probes(parameter.value)
  } else {
    []
  }
  for b in boundaries(ctx, parameter) {
    probes.push({
      context: b.prefix,
      true_first: b.prefix + " AND 7=7 " + b.suffix,
      false_first: b.prefix + " AND 7=8 " + b.suffix,
      true_second: b.prefix + " AND 9=9 " + b.suffix,
      false_second: b.prefix + " AND 9=10 " + b.suffix,
    })
  }
  for probe in probes {
    guard send(ctx, "boolean-true", parameter~, value=probe.true_first)
      is Some((t1, t1_id)) else {
      return
    }
    // Reflected payloads and input validation normally fail this check.
    if !(ctx.compare)(baseline, t1) {
      continue
    }
    guard send(ctx, "boolean-false", parameter~, value=probe.false_first)
      is Some((f1, f1_id)) else {
      return
    }
    if !successful(ctx, f1) || (ctx.compare)(baseline, f1) {
      continue
    }
    // Reverse the order for the independent confirmation pair.
    guard send(
        ctx,
        "boolean-false-confirmation",
        parameter~,
        value=probe.false_second,
      )
      is Some((f2, f2_id)) else {
      return
    }
    guard send(
        ctx,
        "boolean-true-confirmation",
        parameter~,
        value=probe.true_second,
      )
      is Some((t2, t2_id)) else {
      return
    }
    if !restore(ctx, baseline, parameter) {
      return
    }
    let confirmed = (ctx.compare)(baseline, t2) &&
      successful(ctx, f2) &&
      (ctx.compare)(f1, f2)
    let context = if probe.context == "numeric" ||
      probe.context == "single-quoted" {
      probe.context
    } else {
      "parenthesized or custom context"
    }
    let evidence : @core.Evidence = {
      detail: if confirmed {
        "\{context}: both true conditions matched the baseline, false conditions produced the same difference, and the original request was restored"
      } else {
        "\{context}: the first pair differed, but the second pair did not confirm the result"
      },
      signature: None,
      observations: [
        @generic.observation(t1, baseline, t1_id),
        @generic.observation(f1, baseline, f1_id),
        @generic.observation(f2, baseline, f2_id),
        @generic.observation(t2, baseline, t2_id),
      ],
    }
    let mut database = @core.Unknown
    if confirmed {
      let prefix = if probe.context == "single-quoted" {
        parameter.value + "' AND "
      } else if probe.context == "numeric" {
        parameter.value + " AND "
      } else {
        probe.context + " AND "
      }
      let suffix = if probe.context == "single-quoted" {
        " AND 'x'='x"
      } else if probe.context == "numeric" {
        ""
      } else {
        " " + ctx.options.suffix.unwrap_or("-- ")
      }
      let p = point(parameter, Unknown, BooleanBased, prefix, suffix)
      let p = if ctx.options.enumeration.requested() ||
        ctx.options.dbms != Unknown {
        fingerprint_point(ctx, parameter, baseline, p)
      } else {
        p
      }
      database = p.database
      ctx.points.push(p)
    }
    finding(
      ctx,
      parameter,
      BooleanBased,
      if confirmed {
        Confirmed
      } else {
        Suspected
      },
      database,
      evidence,
    )
    return
  }
}
