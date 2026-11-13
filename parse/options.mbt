///|
pub fn header(raw : String) -> @core.Header raise @core.ConfigError {
  guard raw.split_once(":") is Some((name, value)) else {
    raise ConfigError("Request headers must use the Name: value format")
  }
  let result : @core.Header = {
    name: name.to_owned(),
    value: value.trim().to_owned(),
  }
  validate_header(result)
  result
}

///|
fn validate_header(header : @core.Header) -> Unit raise @core.ConfigError {
  if header.name.is_empty() ||
    !header.name
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      "!#$%&'*+-.^_`|~".contains_char(c)
    }) {
    raise ConfigError("Invalid request header name")
  }
  if header.value.iter().any(c => c.is_ascii_control() && c != '\t') {
    raise ConfigError(
      "Request header values must not contain control characters",
    )
  }
  if [
      "host", "content-length", "transfer-encoding", "content-encoding", "connection",
    ].contains(header.name.to_lower()) {
    raise ConfigError("Header is managed by the HTTP client: \{header.name}")
  }
}

///|
pub fn validate(options : @core.Options) -> Unit raise @core.ConfigError {
  if options.timeout_ms <= 0 {
    raise ConfigError("Timeout must be greater than zero")
  }
  if options.max_response_bytes <= 0 {
    raise ConfigError("Response size limit must be greater than zero")
  }
  if options.techniques.is_empty() {
    raise ConfigError("Enable at least one detection technique")
  }
  if options.retries < 0 || options.retries > 100 {
    raise ConfigError("--retries must be between 0 and 100")
  }
  if options.threads < 1 || options.threads > 10 {
    raise ConfigError("--threads must be between 1 and 10")
  }
  if options.delay_ms < 0 ||
    options.time_limit_ms.map(n => n <= 0).unwrap_or(false) {
    raise ConfigError("Invalid request delay or runtime limit")
  }
  if options.time_sec < 1 || options.time_sec > 60 {
    raise ConfigError("--time-sec must be between 1 and 60 seconds")
  }
  if options.union_min < 1 ||
    options.union_max < options.union_min ||
    options.union_max > 100 {
    raise ConfigError(
      "--union-cols must be between 1 and 100, with the lower bound no greater than the upper bound",
    )
  }
  if options.crawl < 0 || options.crawl_max_pages < 1 {
    raise ConfigError(
      "Crawl depth must not be negative and the page limit must be greater than zero",
    )
  }
  if options.output_dir.is_empty() ||
    options.session_file.map(s => s.is_empty()).unwrap_or(false) {
    raise ConfigError("Session path must not be empty")
  }
  if options.http_method is Some(verb) &&
    (
      verb.is_empty() ||
      !verb.iter().all(c => c.is_ascii_alphabetic() || c == '-')
    ) {
    raise ConfigError("Invalid HTTP method")
  }
  if options.comparison.code is Some(code) && (code < 100 || code > 599) {
    raise ConfigError("--code must be between 100 and 599")
  }
  for pattern in [options.comparison.regexp, options.crawl_exclude] {
    if pattern is Some(pattern) {
      ignore(
        @string.Regex(pattern) catch {
          _ => raise ConfigError("Invalid regular expression")
        },
      )
    }
  }
  if options.enumeration.columns && options.enumeration.table is None {
    raise ConfigError("--columns requires a table specified with -T")
  }
  for h in options.headers {
    validate_header(h)
  }
  if options.cookie is Some(cookie) {
    validate_header({ name: "Cookie", value: cookie, })
  }
}
