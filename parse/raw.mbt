///|
/// One HTTP/1.x request. Reject ambiguous framing and discard transport-managed headers.
pub fn raw_request(
  raw : String,
  options : @core.Options,
  source? : String,
) -> @core.RequestTemplate raise @core.ConfigError {
  let (head, body) = match raw.split_once("\r\n\r\n") {
    Some((a, b)) => (a.to_owned(), Some(b.to_owned()))
    None =>
      match raw.split_once("\n\n") {
        Some((a, b)) => (a.to_owned(), Some(b.to_owned()))
        None => (raw, None)
      }
  }
  let lines = head.split("\n").map(s => s.trim_end().to_owned()).to_array()
  guard lines.get(0) is Some(first) else {
    raise ConfigError("Request file is empty")
  }
  let fields = first.split(" ").to_array()
  guard fields.length() == 3 &&
    (fields[2] == "HTTP/1.0" || fields[2] == "HTTP/1.1") else {
    raise ConfigError("Request line must be METHOD PATH HTTP/1.x")
  }
  let mut host : String? = None
  let headers = []
  for line in lines[1:] {
    if line.has_prefix(" ") || line.has_prefix("\t") {
      raise ConfigError("Folded request headers are not supported")
    }
    guard line.split_once(":") is Some((name, value)) else {
      raise ConfigError("Invalid request header")
    }
    let key = name.to_owned().to_lower()
    if key == "host" {
      if host is Some(_) {
        raise ConfigError("Duplicate Host header")
      }
      host = Some(value.trim().to_owned())
    } else if key == "transfer-encoding" {
      raise ConfigError(
        "Provide a decoded body for raw requests; Transfer-Encoding is not supported",
      )
    } else if ![
        "content-length", "connection", "proxy-connection", "keep-alive", "te", "trailer",
        "upgrade",
      ].contains(key) {
      headers.push(header(line))
    }
  }
  let path = fields[1].to_owned()
  let url = if path.has_prefix("http://") || path.has_prefix("https://") {
    path
  } else {
    guard host is Some(host) && path.has_prefix("/") else {
      raise ConfigError("Relative request paths require a Host header")
    }
    (if options.force_ssl { "https://" } else { "http://" }) + host + path
  }
  headers.append(options.headers)
  template(
    url,
    {
      ..options,
      http_method: Some(options.http_method.unwrap_or(fields[0].to_owned())),
      data: if options.data is Some(_) {
        options.data
      } else {
        body
      },
      headers,
    },
    source={
      kind: "request_file",
      origin: source.unwrap_or("request"),
      depth: 0,
    },
  )
}

///|
pub fn origin(url : String) -> String {
  let scheme = if url.has_prefix("https://") { "https://" } else { "http://" }
  let host = url[scheme.length():]
    .split("/")
    .next()
    .unwrap_or("")
    .to_owned()
    .split("?")
    .next()
    .unwrap_or("")
    .to_owned()
    .to_lower()
  let default_port = if scheme == "https://" { ":443" } else { ":80" }
  scheme +
  (if host.has_suffix(default_port) {
    host[:host.length() - default_port.length()].to_owned()
  } else {
    host
  })
}

///|
pub fn resolve_url(base : String, reference : String) -> String? {
  let reference = reference.split("#").next().unwrap_or("").to_owned()
  let root = origin(base)
  let candidate = if reference.has_prefix("http://") ||
    reference.has_prefix("https://") {
    reference
  } else if reference.has_prefix("//") {
    (if base.has_prefix("https://") { "https:" } else { "http:" }) + reference
  } else if reference.contains(":") &&
    !reference.has_prefix("/") &&
    !reference.has_prefix("?") {
    return None
  } else if reference.is_empty() {
    base.split("#").next().unwrap().to_owned()
  } else if reference.has_prefix("/") {
    root + reference
  } else if reference.has_prefix("?") {
    base.split("?").next().unwrap().to_owned() + reference
  } else {
    let path = base.split("?").next().unwrap().to_owned()
    let end = path.rev_find("/").unwrap_or(path.length())
    path[:end + 1].to_owned() + reference
  }
  let parsed = target(candidate) catch { _ => return None }
  let root = origin(parsed.base)
  let rest = parsed.base[if parsed.base.has_prefix("https://") {
    8
  } else {
    7
  }:].to_owned()
  let path = rest.find("/").map(i => rest[i:].to_owned()).unwrap_or("/")
  let segments : Array[String] = []
  for segment in path.split("/") {
    if segment == ".." {
      ignore(segments.pop())
    } else if segment != "." && !segment.is_empty() {
      segments.push(segment.to_owned())
    }
  }
  Some(
    root +
    "/" +
    segments.join("/") +
    (if path.has_suffix("/") && !segments.is_empty() { "/" } else { "" }) +
    (if parsed.has_query {
      "?" + parsed.query.map(p => p.raw).join("&")
    } else {
      ""
    }),
  )
}
