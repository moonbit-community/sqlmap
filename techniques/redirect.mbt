///|
// Count complete pairs before a slot, so multiple markers in the same value
// still identify the same occurrence of a repeated name.
fn pair_occurrence(
  prefix : String,
  name : String,
  separator : String,
  encoded~ : Bool,
) -> Int32 raise @core.ConfigError {
  let parts = prefix.split(separator).to_array()
  let mut occurrence = 0
  for i in 0..<(parts.length() - 1) {
    let key = parts[i].split("=").next().unwrap().to_owned()
    let key = if encoded { @parse.decode(key) } else { key.trim().to_owned() }
    if key == name {
      occurrence += 1
    }
  }
  occurrence
}

///|
fn cookie_values(request : @core.Request, name : String) -> Array[String] {
  let values = []
  for h in request.headers {
    if h.name.to_lower() == "cookie" {
      for part in h.value.split(";") {
        let (key, value) = part.split_once("=").unwrap_or((part, ""))
        if key.trim() == name {
          values.push(value.to_owned())
        }
      }
    }
  }
  values
}

///|
fn redirect_preserves(
  ctx : @core.ScanContext,
  original : @core.Request,
  next : @core.Request,
  parameter : @core.Parameter,
) -> Bool raise @core.ConfigError {
  let slot = ctx.template.bind(t => {
    t.slots
    .iter()
    .find_first(s => {
      s.parameter.location == parameter.location &&
      s.parameter.index == parameter.index
    })
  })
  match parameter.location {
    Query => {
      let before = @parse.target(original.url).query
      let after = @parse.target(next.url).query
      let occurrence = match (ctx.template, slot) {
        (Some(t), Some(s)) => {
          guard t.request.url.find("?") is Some(start) else { return false }
          pair_occurrence(
            t.request.url[start + 1:s.start].to_owned(),
            parameter.name,
            "&",
            encoded=true,
          )
        }
        _ =>
          before
          .filter(p => p.name == parameter.name && p.index < parameter.index)
          .length()
      }
      let expected = before
        .filter(p => p.name == parameter.name)
        .get(occurrence)
      let actual = after.filter(p => p.name == parameter.name).get(occurrence)
      expected is Some(expected) &&
      actual is Some(actual) &&
      expected.value == actual.value
    }
    Form | JsonBody =>
      original.http_method == next.http_method &&
      original.body is Some(_) &&
      original.body == next.body
    Path => cookie_path(original.url) == cookie_path(next.url)
    HeaderValue => {
      let index = match slot {
        Some({ part: HeaderPart(i), .. }) => i
        _ => parameter.index
      }
      guard original.headers.get(index) is Some(expected) else { return false }
      let name = parameter.name.to_lower()
      let occurrence = original.headers[:index]
        .iter()
        .filter(h => h.name.to_lower() == name)
        .count()
      let actual = next.headers
        .filter(h => h.name.to_lower() == name)
        .get(occurrence)
      expected.name.to_lower() == name &&
      actual.map(h => h.value) == Some(expected.value)
    }
    Cookie => {
      guard ctx.template is Some(t) &&
        slot is Some({ part: HeaderPart(index), start, .. }) else {
        return false
      }
      let preceding = {
        ..t.request,
        headers: t.request.headers[:index].to_owned(),
      }
      let occurrence = cookie_values(preceding, parameter.name).length() +
        pair_occurrence(
          t.request.headers[index].value[:start].to_owned(),
          parameter.name,
          ";",
          encoded=false,
        )
      let expected = cookie_values(original, parameter.name).get(occurrence)
      expected is Some(_) &&
      cookie_values(next, parameter.name).get(occurrence) == expected
    }
  }
}

///|
fn check_redirect_coverage(
  ctx : @core.ScanContext,
  original : @core.Request,
  next : @core.Request,
  phase : String,
  parameter : @core.Parameter?,
  request_id : Int32,
) -> Bool {
  if phase == "crawl" {
    return true
  }
  let selected = try {
    if parameter is Some(p) {
      [p]
    } else if ctx.template is Some(t) {
      @parse.select_template(t, ctx.options.parameters, allow_empty=true)
    } else {
      @parse.selected(ctx.target, ctx.options.parameters)
    }
  } catch {
    ConfigError(message) => {
      issue(ctx, "redirect-coverage", message, request_id~)
      return false
    }
  }
  let mut preserved = true
  for p in selected {
    if !(redirect_preserves(ctx, original, next, p) catch { _ => false }) {
      issue(
        ctx,
        "redirect-coverage",
        "Tested input \{Repr(p.location)}:\{p.name}[\{p.index}] was lost or overwritten during redirect to \{next.url}; target stopped with an inconclusive result",
        parameter=p,
        request_id~,
      )
      preserved = false
    }
  }
  preserved
}
