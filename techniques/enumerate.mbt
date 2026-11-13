///|
pub async fn enumerate_metadata(
  ctx : @core.ScanContext,
  baseline : @core.Response,
) -> Unit {
  let e = ctx.options.enumeration
  if !e.requested() {
    return
  }
  let usable = ctx.points.filter(p => {
    (p.technique == UnionBased || p.technique == BooleanBased) &&
    (p.database == SQLite || p.database == PostgreSQL)
  })
  let kinds = [
    ("fingerprint", e.fingerprint),
    ("banner", e.banner),
    ("current_db", e.current_db),
    ("dbs", e.dbs),
    ("tables", e.tables),
    ("columns", e.columns),
  ]
  guard usable.get(0) is Some(first) else {
    for (kind, wanted) in kinds {
      if wanted {
        ctx.enumeration.push(
          result(
            ctx,
            kind,
            [],
            false,
            Some(
              "A confirmed SQLite/PostgreSQL UNION or boolean injection point is required; time channels are not used for enumeration",
            ),
          ),
        )
      }
    }
    issue(
      ctx, "enumeration", "No confirmed injection point is available for metadata enumeration",
    )
    return
  }
  let points = usable.filter(p => {
    p.location == first.location &&
    p.index == first.index &&
    p.database == first.database
  })
  points.sort_by((a, b) => {
    (if a.technique == UnionBased { 0 } else { 1 }).compare(
      if b.technique == UnionBased {
        0
      } else {
        1
      },
    )
  })
  guard ctx.template is Some(template) &&
    template.slots
    .iter()
    .find_first(s => {
      s.parameter.location == first.location && s.parameter.index == first.index
    })
    is Some(slot) else {
    return
  }
  let parameter = slot.parameter
  let db = first.database
  for (kind, wanted) in kinds {
    if !wanted {
      continue
    }
    let cache_key = ctx.session_key + ":enum:" + kind + ":" + ctx.baseline_key
    if !ctx.options.fresh_queries && ctx.session is Some(store) {
      let cached = read_enumeration_cache(store, cache_key)
      if cached is Some(cached) && cached.complete {
        ctx.enumeration.push({ ..cached, cached: true, })
        continue
      }
    }
    let r = if kind == "fingerprint" {
      result(
        ctx,
        kind,
        [if db == SQLite { "SQLite" } else { "PostgreSQL" }],
        true,
        None,
      )
    } else if db == SQLite &&
      e.database is Some(_) &&
      (kind == "tables" || kind == "columns") {
      result(
        ctx,
        kind,
        [],
        false,
        Some(
          "SQLite metadata enumeration with -D is not supported; omit the schema option",
        ),
      )
    } else if db == SQLite && (kind == "dbs" || kind == "current_db") {
      result(
        ctx,
        kind,
        [],
        false,
        Some(
          "Database listing and current database enumeration are not supported for SQLite",
        ),
      )
    } else if kind == "banner" || kind == "current_db" {
      let query = if kind == "current_db" {
        "SELECT current_schema()"
      } else if db == SQLite {
        "SELECT sqlite_version()"
      } else {
        "SELECT version()"
      }
      if read_metadata(ctx, parameter, baseline, points, query) is Some(value) {
        result(ctx, kind, [value], true, None)
      } else {
        result(ctx, kind, [], false, Some("Failed to read metadata scalar"))
      }
    } else if kind == "dbs" {
      collect(
        ctx, parameter, baseline, points, kind, "schema_name", "FROM information_schema.schemata",
        "schema_name",
      )
    } else if kind == "tables" {
      if db == SQLite {
        collect(
          ctx, parameter, baseline, points, kind, "name", "FROM sqlite_schema WHERE type='table' AND name NOT GLOB 'sqlite_*'",
          "name",
        )
      } else {
        collect(
          ctx,
          parameter,
          baseline,
          points,
          kind,
          "table_name",
          "FROM information_schema.tables WHERE table_schema=" +
          e.database.map(literal).unwrap_or("current_schema()"),
          "table_name",
        )
      }
    } else {
      let table = e.table.unwrap_or("")
      if db == SQLite {
        let exists = read_metadata(
          ctx,
          parameter,
          baseline,
          points,
          "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name=" +
          literal(table),
        )
        if exists == Some("0") {
          result(ctx, kind, [], true, None)
        } else {
          let columns = collect(
            ctx,
            parameter,
            baseline,
            points,
            kind,
            "name",
            "FROM pragma_table_xinfo(" + literal(table) + ")",
            "cid",
          )
          if columns.complete {
            columns
          } else if read_metadata(
              ctx,
              parameter,
              baseline,
              points,
              "SELECT sql FROM sqlite_schema WHERE type='table' AND name=" +
              literal(table),
            ).bind(@parse.sqlite_columns)
            is Some(names) {
            result(ctx, kind, names, true, None)
          } else {
            result(
              ctx,
              kind,
              [],
              false,
              Some("Could not read or parse table column definitions"),
            )
          }
        }
      } else {
        collect(
          ctx,
          parameter,
          baseline,
          points,
          kind,
          "column_name",
          "FROM information_schema.columns WHERE table_schema=" +
          e.database.map(literal).unwrap_or("current_schema()") +
          " AND table_name=" +
          literal(table),
          "ordinal_position",
        )
      }
    }
    let r = if kind == "columns" && e.column is Some(names) {
      let names = names.split(",").map(s => s.trim().to_owned()).to_array()
      { ..r, values: r.values.filter(v => names.contains(v)), }
    } else {
      r
    }
    ctx.enumeration.push(r)
    if !r.complete {
      issue(
        ctx,
        "enumeration",
        r.message.unwrap_or("Enumeration is incomplete"),
      )
    }
    if ctx.session is Some(store) {
      write_enumeration_cache(
        ctx, store, cache_key, r, "Failed to write enumeration cache",
      )
    }
    if ctx.has_errors() && kind != "dbs" && kind != "current_db" {
      return
    }
  }
}
