///|
pub async fn detect_errors(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
) -> Unit {
  let values = error_probes(parameter.value + ctx.options.prefix.unwrap_or("")).map(v => {
      v + ctx.options.suffix.unwrap_or("")
    },
  )
  for value in values {
    guard send(ctx, "error-probe", parameter~, value~)
      is Some((first, first_id)) else {
      return
    }
    let added = @dbms.new_errors(baseline.body, first.body)
    if added.is_empty() {
      continue
    }
    guard send(ctx, "error-confirmation", parameter~, value~)
      is Some((second, second_id)) else {
      return
    }
    if !restore(ctx, baseline, parameter) {
      return
    }
    let repeated = added.filter(s => second.body.to_lower().contains(s.marker))
    let confirmed = !repeated.is_empty() && (ctx.compare)(first, second)
    let evidence : @core.Evidence = {
      detail: if confirmed {
        "A database error absent from the baseline was reproduced in two probes, and the original request was restored"
      } else {
        "A new database error appeared, but repeated probes did not produce consistent evidence"
      },
      signature: Some(added.map(s => s.marker).join("; ")),
      observations: [
        @generic.observation(first, baseline, first_id),
        @generic.observation(second, baseline, second_id),
      ],
    }
    finding(
      ctx,
      parameter,
      ErrorBased,
      if confirmed {
        Confirmed
      } else {
        Suspected
      },
      if confirmed {
        @dbms.infer(repeated)
      } else {
        Unknown
      },
      evidence,
    )
    return
  }
}
