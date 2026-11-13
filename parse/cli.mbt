///|
fn techniques(value : String) -> Array[@core.Technique] raise @core.ConfigError {
  let value = match value.to_lower() {
    "error" => "e"
    "boolean" => "b"
    "error,boolean" | "boolean,error" => "eb"
    other => other
  }
  let result : Array[@core.Technique] = []
  for c in value {
    let kind = match c {
      'e' => @core.ErrorBased
      'b' => BooleanBased
      'u' => UnionBased
      't' => TimeBased
      _ =>
        raise ConfigError(
          "--technique supports only B, E, U and T; stacked queries and other techniques are not implemented",
        )
    }
    if !result.contains(kind) {
      result.push(kind)
    }
  }
  result
}

///|
fn integer(flag : String, value : String) -> Int32 raise @core.ConfigError {
  @string.parse_int(value) catch {
    _ => raise ConfigError("\{flag} must be an integer")
  }
}

///|
fn milliseconds(
  flag : String,
  value : String,
  zero~ : Bool = false,
) -> Int32 raise @core.ConfigError {
  let n = @string.parse_double(value) catch {
    _ => raise ConfigError("\{flag} must be a number of seconds")
  }
  if !(n >= (if zero { 0.0 } else { 0.001 }) && n <= 2147483.647) {
    raise ConfigError("\{flag} seconds are out of range")
  }
  (n * 1000.0).to_int()
}

///|
pub fn cli(args : Array[String]) -> @core.CliAction raise @core.ConfigError {
  let mut url : String? = None
  let mut input_file : String? = None
  let mut raw_file = false
  let mut options = @core.Options::default()
  let mut format = @core.Text
  let mut output = None
  let mut i = 0
  while i < args.length() {
    let raw = args[i]
    if raw == "--help" || raw == "-h" {
      return Help
    }
    let (flag, inline_value) = if raw.has_prefix("--") {
      match raw.split_once("=") {
        Some((f, v)) => (f.to_owned(), Some(v.to_owned()))
        None => (raw, None)
      }
    } else {
      (raw, None)
    }
    let switches = [
      "--force-ssl", "--drop-set-cookie", "--ignore-redirects", "--text-only", "--titles",
      "-f", "--fingerprint", "-b", "--banner", "--current-db", "--dbs", "--tables",
      "--columns", "--forms", "--batch", "--fresh-queries", "--flush-session",
    ]
    if switches.contains(flag) {
      if inline_value is Some(_) {
        raise ConfigError("\{flag} does not accept a value")
      }
      let e = options.enumeration
      let c = options.comparison
      options = match flag {
        "--force-ssl" => { ..options, force_ssl: true, }
        "--drop-set-cookie" => { ..options, drop_set_cookie: true, }
        "--ignore-redirects" => { ..options, ignore_redirects: true, }
        "--text-only" => { ..options, comparison: { ..c, text_only: true, }, }
        "--titles" => { ..options, comparison: { ..c, titles: true, }, }
        "-f" | "--fingerprint" =>
          { ..options, enumeration: { ..e, fingerprint: true, }, }
        "-b" | "--banner" => { ..options, enumeration: { ..e, banner: true, }, }
        "--current-db" =>
          { ..options, enumeration: { ..e, current_db: true, }, }
        "--dbs" => { ..options, enumeration: { ..e, dbs: true, }, }
        "--tables" => { ..options, enumeration: { ..e, tables: true, }, }
        "--columns" => { ..options, enumeration: { ..e, columns: true, }, }
        "--forms" => { ..options, forms: true, }
        "--batch" => { ..options, batch: true, }
        "--fresh-queries" => { ..options, fresh_queries: true, }
        "--flush-session" => { ..options, flush_session: true, }
        _ => options
      }
      i += 1
      continue
    }
    if ![
        "-u", "--url", "-m", "-r", "--data", "-p", "-H", "--header", "--cookie",
        "--technique", "--timeout", "--format", "--output", "-X", "--method", "--retries",
        "--delay", "--threads", "--time-limit", "--time-sec", "--dbms", "--prefix",
        "--suffix", "--union-cols", "--string", "--not-string", "--regexp", "--code",
        "-D", "-T", "-C", "--crawl", "--crawl-exclude", "--crawl-max-pages", "--output-dir",
        "-s",
      ].contains(flag) {
      raise ConfigError("Unknown or unimplemented option: \{flag}")
    }
    let value = if inline_value is Some(v) {
      v
    } else {
      i += 1
      guard args.get(i) is Some(v) else {
        raise ConfigError("Missing value for option: \{flag}")
      }
      v
    }
    let c = options.comparison
    let e = options.enumeration
    match flag {
      "-u" | "--url" | "-m" | "-r" => {
        if url is Some(_) || input_file is Some(_) {
          raise ConfigError("Specify exactly one input source: -u, -m or -r")
        }
        if flag == "-m" || flag == "-r" {
          input_file = Some(value)
          raw_file = flag == "-r"
        } else {
          url = Some(value)
        }
      }
      "--data" => options = { ..options, data: Some(value), }
      "-p" =>
        for name in value.split(",") {
          let name = name.trim().to_owned()
          if name.is_empty() {
            raise ConfigError("-p parameter names must not be empty")
          }
          options.parameters.push(name)
        }
      "-H" | "--header" => options.headers.push(header(value))
      "--cookie" => options = { ..options, cookie: Some(value), }
      "--technique" =>
        options = {
          ..options,
          techniques: techniques(value),
          explicit_techniques: true,
        }
      "--timeout" =>
        options = { ..options, timeout_ms: milliseconds(flag, value), }
      "-X" | "--method" =>
        options = { ..options, http_method: Some(value.to_upper()), }
      "--retries" => options = { ..options, retries: integer(flag, value), }
      "--threads" => options = { ..options, threads: integer(flag, value), }
      "--delay" =>
        options = { ..options, delay_ms: milliseconds(flag, value, zero=true), }
      "--time-limit" =>
        options = { ..options, time_limit_ms: Some(milliseconds(flag, value)), }
      "--time-sec" => options = { ..options, time_sec: integer(flag, value), }
      "--dbms" =>
        options = {
          ..options,
          dbms: match value.to_lower() {
            "sqlite" => SQLite
            "postgresql" | "postgres" => PostgreSQL
            "mysql" => MySQL
            "mssql" | "sql server" | "microsoft sql server" => SQLServer
            _ => raise ConfigError("Unsupported database: \{value}")
          },
        }
      "--prefix" => options = { ..options, prefix: Some(value), }
      "--suffix" => options = { ..options, suffix: Some(value), }
      "--union-cols" => {
        let (lo, hi) = match value.split_once("-") {
          Some((a, b)) =>
            (integer(flag, a.to_owned()), integer(flag, b.to_owned()))
          None => {
            let n = integer(flag, value)
            (n, n)
          }
        }
        options = { ..options, union_min: lo, union_max: hi, }
      }
      "--string" =>
        options = { ..options, comparison: { ..c, string: Some(value), }, }
      "--not-string" =>
        options = { ..options, comparison: { ..c, not_string: Some(value), }, }
      "--regexp" =>
        options = { ..options, comparison: { ..c, regexp: Some(value), }, }
      "--code" =>
        options = {
          ..options,
          comparison: { ..c, code: Some(integer(flag, value)), },
        }
      "-D" =>
        options = { ..options, enumeration: { ..e, database: Some(value), }, }
      "-T" =>
        options = { ..options, enumeration: { ..e, table: Some(value), }, }
      "-C" =>
        options = { ..options, enumeration: { ..e, column: Some(value), }, }
      "--crawl" => options = { ..options, crawl: integer(flag, value), }
      "--crawl-exclude" => options = { ..options, crawl_exclude: Some(value), }
      "--crawl-max-pages" =>
        options = { ..options, crawl_max_pages: integer(flag, value), }
      "--output-dir" => options = { ..options, output_dir: value, }
      "-s" => options = { ..options, session_file: Some(value), }
      "--format" =>
        format = match value {
          "text" => Text
          "json" => Json
          _ => raise ConfigError("--format must be text or json")
        }
      "--output" => {
        if value.is_empty() {
          raise ConfigError("--output path must not be empty")
        }
        output = Some(value)
      }
      _ => ()
    }
    i += 1
  }
  if url is None && input_file is None {
    raise ConfigError("Specify -u, -m or -r")
  }
  validate(options)
  if url is Some(url) {
    ignore(
      select_template(
        template(url, options),
        options.parameters,
        allow_empty=options.crawl > 0 || options.forms,
      ),
    )
  }
  Run({ url: url.unwrap_or(""), input_file, raw_file, options, format, output, })
}
