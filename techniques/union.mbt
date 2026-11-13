///|
fn union_expression(db : @core.Dbms, marker : String) -> String {
  let version = if db == SQLite {
    "sqlite_version()"
  } else {
    "current_setting('server_version')"
  }
  "CASE WHEN " +
  version +
  " IS NOT NULL THEN " +
  computed(marker) +
  " ELSE NULL END"
}

///|
pub async fn detect_union(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
) -> Unit {
  let dbs = dialects(ctx, parameter).filter(db => {
    db == SQLite || db == PostgreSQL
  })
  if dbs.is_empty() {
    return
  }
  for boundary in boundaries(ctx, parameter) {
    for columns in ctx.options.union_min..<=ctx.options.union_max {
      for position in 0..<columns {
        for db in dbs {
          let marker = "sqm" + "\{ctx.started.abs()}x\{ctx.attempted}z"
          let p = point(
            parameter,
            db,
            UnionBased,
            boundary.prefix,
            boundary.suffix,
            columns~,
            position~,
          )
          guard send(
              ctx,
              "union",
              parameter~,
              value=union_value(p, union_expression(db, marker)),
            )
            is Some((first, first_id)) else {
            return
          }
          if first.status < 200 ||
            first.status >= 300 ||
            baseline.body.contains(marker) ||
            !first.body.contains(marker) {
            continue
          }
          // A literal reflection must fail this negative control.
          guard send(
              ctx,
              "union-reflection-control",
              parameter~,
              value=boundary.prefix +
                " AND 1=1 /*" +
                marker +
                "*/ " +
                boundary.suffix,
            )
            is Some((negative, _)) else {
            return
          }
          if negative.body.contains(marker) ||
            !(ctx.compare)(baseline, negative) {
            continue
          }
          let second_marker = "sqm" + "\{ctx.started.abs()}v\{ctx.attempted}q"
          guard send(
              ctx,
              "union-confirmation",
              parameter~,
              value=union_value(p, union_expression(db, second_marker)),
            )
            is Some((second, second_id)) else {
            return
          }
          if second.status < 200 ||
            second.status >= 300 ||
            !second.body.contains(second_marker) {
            continue
          }
          if !restore(ctx, baseline, parameter) {
            return
          }
          ctx.points.push(p)
          finding(ctx, parameter, UnionBased, Confirmed, db, {
            detail: "A server-computed marker was returned during independent confirmation; literal reflection controls passed, and the original request was restored",
            signature: None,
            observations: [
              @generic.observation(first, baseline, first_id),
              @generic.observation(second, baseline, second_id),
            ],
          })
          return
        }
      }
    }
  }
}
