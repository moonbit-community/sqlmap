///|
fn check_port(port : String) -> Unit raise @core.ConfigError {
  let n = @string.parse_int(port) catch {
    _ => raise ConfigError("URL port must be an integer between 1 and 65535")
  }
  if port.is_empty() ||
    !port.iter().all(c => c.is_ascii_digit()) ||
    n < 1 ||
    n > 65535 {
    raise ConfigError("URL port must be an integer between 1 and 65535")
  }
}

///|
pub fn target(
  url : String,
  data? : String,
) -> @core.Target raise @core.ConfigError {
  let url = match url.split_once("#") {
    Some((url, _)) => url.to_owned()
    None => url
  }
  if url.iter().any(c => c.is_whitespace() || c.is_ascii_control()) {
    raise ConfigError(
      "URL must not contain unencoded whitespace or control characters",
    )
  }
  let rest = if url.has_prefix("http://") {
    url[7:].to_owned()
  } else if url.has_prefix("https://") {
    url[8:].to_owned()
  } else {
    raise ConfigError("URL must start with http:// or https://")
  }
  let authority = rest
    .split("/")
    .next()
    .unwrap()
    .split("?")
    .next()
    .unwrap()
    .to_owned()
  if authority.is_empty() ||
    authority.contains("@") ||
    authority.contains("\\") ||
    authority.contains("%") {
    raise ConfigError(
      "Invalid URL host; embedded credentials are not supported",
    )
  }
  if authority.has_prefix("[") {
    guard authority.find("]") is Some(end) else {
      raise ConfigError("IPv6 address is missing the closing bracket")
    }
    let ip = authority[1:end].to_owned()
    if !ip.contains(":") ||
      !ip.iter().all(c => c.is_ascii_hexdigit() || c == ':' || c == '.') {
      raise ConfigError("Invalid IPv6 address")
    }
    let suffix = authority[end + 1:].to_owned()
    if !suffix.is_empty() {
      guard suffix.has_prefix(":") else {
        raise ConfigError("Invalid URL host")
      }
      check_port(suffix[1:].to_owned())
    }
  } else {
    let host = match authority.split_once(":") {
      Some((host, port)) => {
        check_port(port.to_owned())
        host.to_owned()
      }
      None => authority
    }
    if host.is_empty() ||
      !host
      .iter()
      .all(c => {
        c.is_ascii_alphabetic() || c.is_ascii_digit() || c == '.' || c == '-'
      }) {
      raise ConfigError(
        "Invalid URL host; use Punycode for internationalized domain names",
      )
    }
  }
  let (base, query, has_query) = match url.split_once("?") {
    Some((base, query)) =>
      (base.to_owned(), parameters(query.to_owned(), Query), true)
    None => (url, [], false)
  }
  // core/async/http splits authority and path at '/'. Ensure a root path even
  // for URLs such as http://localhost?id=1 (including '/' inside query values).
  let scheme_length = if url.has_prefix("https://") { 8 } else { 7 }
  let base = if base.length() == scheme_length + authority.length() {
    base + "/"
  } else {
    base
  }
  { url, base, has_query, query, form: data.map(s => parameters(s, Form)), }
}

///|
pub fn selected(
  target : @core.Target,
  names : Array[String],
) -> Array[@core.Parameter] raise @core.ConfigError {
  let all = target.query.copy()
  if target.form is Some(form) {
    all.append(form)
  }
  let candidates = all.filter(p => !p.name.is_empty())
  fn matches(p : @core.Parameter, name : String) -> Bool {
    if name.has_prefix("query:") {
      p.location == Query && p.name[:] == name[6:]
    } else if name.has_prefix("form:") {
      p.location == Form && p.name[:] == name[5:]
    } else {
      name == p.name
    }
  }
  for name in names {
    if !candidates.any(p => matches(p, name)) {
      raise ConfigError("Selected parameter not found: \{name}")
    }
  }
  let selected = candidates.filter(p => {
    names.is_empty() || names.any(name => matches(p, name))
  })
  if selected.is_empty() {
    raise ConfigError("Target has no testable query or form parameters")
  }
  selected
}

///|
fn serialized(
  params : Array[@core.Parameter],
  replacement : (@core.Parameter, String)?,
) -> String {
  params
  .map(p => {
    match replacement {
      Some((selected, value)) if p.location == selected.location &&
        p.index == selected.index => {
        let name = match p.raw.split_once("=") {
          Some((name, _)) => name.to_owned()
          None => p.raw
        }
        name + "=" + encode(value)
      }
      _ => p.raw
    }
  })
  .join("&")
}

///|
/// Reconstruct the request, replacing exactly one parameter occurrence.
pub fn request(
  target : @core.Target,
  options : @core.Options,
  replacement? : (@core.Parameter, String),
) -> @core.Request {
  let headers = options.headers.copy()
  if options.cookie is Some(value) {
    headers.push({ name: "Cookie", value, })
  }
  if target.form is Some(_) &&
    !headers.any(h => h.name.to_lower() == "content-type") {
    headers.push({
      name: "Content-Type",
      value: "application/x-www-form-urlencoded",
    })
  }
  {
    http_method: if target.form is Some(_) {
      "POST"
    } else {
      "GET"
    },
    url: target.base +
    (if target.has_query {
      "?" + serialized(target.query, replacement)
    } else {
      ""
    }),
    headers,
    body: target.form.map(form => serialized(form, replacement)),
  }
}
