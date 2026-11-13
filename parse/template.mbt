///|
fn add_pairs(
  raw : String,
  location : @core.Location,
  part : @core.RequestPart,
  offset : Int32,
  slots : Array[@core.ParameterSlot],
  separator~ : String = "&",
) -> Unit raise @core.ConfigError {
  let mut at = offset
  for index, piece in raw.split(separator).to_array() {
    let piece = piece.to_owned()
    let (key, value, start) = match piece.split_once("=") {
      Some((k, v)) => (k.to_owned(), v.to_owned(), at + k.length() + 1)
      None => (piece, "", at + piece.length())
    }
    let name = if location == Cookie {
      key.trim().to_owned()
    } else {
      decode(key)
    }
    if !name.is_empty() {
      slots.push({
        parameter: {
          location,
          index: if location == Cookie {
            slots.filter(s => s.parameter.location == Cookie).length()
          } else {
            index
          },
          name,
          value: if location == Cookie {
            value
          } else {
            decode(value)
          },
          raw: piece,
        },
        part,
        start,
        end: at + piece.length(),
        encoding: if location == Cookie {
          RawValue
        } else {
          PercentEncoded
        },
        marked: false,
      })
    }
    at += piece.length() + separator.length()
  }
}

///|
pub fn template(
  url : String,
  options : @core.Options,
  source? : @core.TargetSource,
) -> @core.RequestTemplate raise @core.ConfigError {
  validate(options)
  let url = if options.force_ssl && url.has_prefix("http://") {
    "https://" + url[7:].to_owned()
  } else {
    url
  }
  let target = target(url)
  let headers = options.headers.copy()
  if options.cookie is Some(value) {
    headers.push({ name: "Cookie", value, })
  }
  let json_body = headers.any(h => {
      h.name.to_lower() == "content-type" &&
      (
        h.value.to_lower().contains("application/json") ||
        h.value.to_lower().contains("+json")
      )
    }) ||
    options.data
    .map(s => s.trim_start().has_prefix("{") || s.trim_start().has_prefix("["))
    .unwrap_or(false)
  if options.data is Some(_) &&
    !headers.any(h => h.name.to_lower() == "content-type") {
    headers.push({
      name: "Content-Type",
      value: if json_body {
        "application/json"
      } else {
        "application/x-www-form-urlencoded"
      },
    })
  }
  let request : @core.Request = {
    http_method: options.http_method.unwrap_or(
      if options.data is Some(_) {
        "POST"
      } else {
        "GET"
      },
    ),
    url: target.base +
    (if target.has_query {
      "?" + target.query.map(p => p.raw).join("&")
    } else {
      ""
    }),
    headers,
    body: options.data,
  }
  let slots : Array[@core.ParameterSlot] = []
  if request.url.find("?") is Some(at) {
    add_pairs(request.url[at + 1:].to_owned(), Query, UrlPart, at + 1, slots)
  }
  if options.data is Some(body) {
    if json_body {
      json_slots(body, slots)
    } else {
      add_pairs(body, Form, BodyPart, 0, slots)
    }
  }
  for index, h in headers {
    if h.name.to_lower() == "cookie" {
      add_pairs(h.value, Cookie, HeaderPart(index), 0, slots, separator=";")
    } else {
      slots.push({
        parameter: {
          location: HeaderValue,
          index,
          name: h.name,
          value: h.value,
          raw: h.value,
        },
        part: HeaderPart(index),
        start: 0,
        end: h.value.length(),
        encoding: RawValue,
        marked: false,
      })
    }
  }
  // Markers are separate occurrences; the baseline removes them all, and a probe fills exactly one.
  let expanded : Array[@core.ParameterSlot] = []
  for slot in slots {
    let raw = part_value(request, slot.part)
    if slot.encoding == JsonNumber && slot.parameter.raw.contains("*") {
      expanded.push({
        ..slot,
        marked: true,
        parameter: { ..slot.parameter, index: 1000000 + expanded.length(), },
      })
      continue
    }
    let mut markers = 0
    for pos = slot.start; pos < slot.end; pos = pos + 1 {
      if raw[pos] == '*' &&
        !(slot.parameter.location == HeaderValue &&
        slot.parameter.name.to_lower() == "accept") {
        expanded.push({
          ..slot,
          start: pos,
          end: pos + 1,
          marked: true,
          encoding: if slot.encoding == JsonString {
            JsonFragment
          } else {
            slot.encoding
          },
          parameter: {
            ..slot.parameter,
            index: 1000000 + expanded.length(),
            value: "",
          },
        })
        markers += 1
      }
    }
    if markers == 0 {
      expanded.push(slot)
    }
  }
  let path_end = request.url.find("?").unwrap_or(request.url.length())
  for pos in 0..<path_end {
    if request.url[pos] == '*' {
      expanded.push({
        parameter: {
          location: Path,
          index: pos,
          name: "*",
          value: "",
          raw: "*",
        },
        part: UrlPart,
        start: pos,
        end: pos + 1,
        encoding: PercentEncoded,
        marked: true,
      })
    }
  }
  {
    request,
    slots: expanded,
    source: source.unwrap_or({ kind: "url", origin: target.url, depth: 0, }),
  }
}

///|
pub fn part_value(request : @core.Request, part : @core.RequestPart) -> String {
  match part {
    UrlPart => request.url
    BodyPart => request.body.unwrap_or("")
    HeaderPart(i) => request.headers[i].value
  }
}

///|
fn location_prefix(location : @core.Location) -> String {
  match location {
    Query => "query:"
    Form => "form:"
    JsonBody => "json:"
    Cookie => "cookie:"
    HeaderValue => "header:"
    Path => "path:"
  }
}

///|
pub fn select_template(
  template : @core.RequestTemplate,
  names : Array[String],
  allow_empty~ : Bool = false,
) -> Array[@core.Parameter] raise @core.ConfigError {
  fn matches(p : @core.Parameter, name : String) -> Bool {
    if ["query:", "form:", "json:", "cookie:", "header:", "path:"].any(prefix => {
        name.has_prefix(prefix)
      }) {
      let full = location_prefix(p.location) + p.name
      if p.location == HeaderValue {
        full.to_lower() == name.to_lower()
      } else {
        full == name
      }
    } else if p.location == HeaderValue {
      p.name.to_lower() == name.to_lower()
    } else {
      p.name == name
    }
  }
  for name in names {
    if !template.slots.any(s => matches(s.parameter, name)) {
      raise ConfigError("Selected parameter not found: \{name}")
    }
  }
  let marked = template.slots.any(s => s.marked)
  let selected = template.slots
    .filter(s => {
      if !names.is_empty() {
        names.any(n => matches(s.parameter, n))
      } else if marked {
        s.marked
      } else {
        s.parameter.location == Query ||
        s.parameter.location == Form ||
        s.parameter.location == JsonBody
      }
    })
    .map(s => s.parameter)
  if selected.is_empty() && !allow_empty {
    raise ConfigError("Target has no testable parameters")
  }
  selected
}

///|
pub fn render_template(
  template : @core.RequestTemplate,
  replacement? : (@core.Parameter, String),
) -> @core.Request {
  fn render(part : @core.RequestPart) -> String {
    let original = part_value(template.request, part)
    let slots = template.slots.filter(s => s.part == part)
    slots.sort_by((a, b) => a.start.compare(b.start))
    let out = StringBuilder()
    let mut cursor = 0
    for slot in slots {
      let value = match replacement {
        Some((p, value)) if p.location == slot.parameter.location &&
          p.index == slot.parameter.index => Some(value)
        _ => if slot.marked { Some("") } else { None }
      }
      if value is Some(value) {
        out.write_string(original[cursor:slot.start].to_owned())
        let numeric_baseline = slot.marked &&
          slot.encoding == JsonNumber &&
          !replacement
          .map(pair => {
            pair.0.location == slot.parameter.location &&
            pair.0.index == slot.parameter.index
          })
          .unwrap_or(false)
        let encoded = if numeric_baseline {
          slot.parameter.value
        } else {
          match slot.encoding {
            PercentEncoded => encode(value)
            JsonString | JsonNumber => @json.Json::string(value).stringify()
            JsonFragment => {
              let quoted = @json.Json::string(value).stringify()
              quoted[1:quoted.length() - 1].to_owned()
            }
            RawValue => value
          }
        }
        // A bare URL/form key needs an equals sign when assigned a value.
        if !slot.marked &&
          slot.start == slot.end &&
          !slot.parameter.raw.contains("=") &&
          (slot.parameter.location == Query || slot.parameter.location == Form) {
          out.write_string("=")
        }
        out.write_string(encoded)
        cursor = slot.end
      }
    }
    out.write_string(original[cursor:].to_owned())
    out.to_string()
  }
  {
    http_method: template.request.http_method,
    url: render(UrlPart),
    body: template.request.body.map(_ => render(BodyPart)),
    headers: template.request.headers.mapi((i, h) => {
      ..h,
      value: render(HeaderPart(i)),
    }),
  }
}
