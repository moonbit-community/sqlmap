///|
fn form_templates(
  doc : @html.Document,
  page : String,
  options : @core.Options,
  depth : Int32,
) -> Array[@core.RequestTemplate] {
  let result = []
  for form in elements(doc, "form") {
    let action = doc.get_attribute(form, "action").unwrap_or(page)
    guard @parse.resolve_url(page, action) is Some(url) &&
      @parse.origin(url) == @parse.origin(page) else {
      continue
    }
    let verb = doc.get_attribute(form, "method").unwrap_or("get").to_upper()
    if verb != "GET" && verb != "POST" {
      continue
    }
    let enctype = doc
      .get_attribute(form, "enctype")
      .unwrap_or("application/x-www-form-urlencoded")
      .to_lower()
    if verb == "POST" && enctype != "application/x-www-form-urlencoded" {
      continue
    }
    let pairs : Array[String] = []
    fn controls(id : Int32) -> Unit {
      let tag = doc.get_tag_name(id).unwrap_or("")
      if tag == "fieldset" && doc.has_attribute(id, "disabled") {
        return
      }
      let name = doc.get_attribute(id, "name").unwrap_or("")
      if !name.is_empty() && !doc.has_attribute(id, "disabled") {
        let kind = doc.get_attribute(id, "type").unwrap_or("text").to_lower()
        if tag == "input" &&
          !["submit", "button", "reset", "image", "file"].contains(kind) &&
          (
            !["checkbox", "radio"].contains(kind) ||
            doc.has_attribute(id, "checked")
          ) {
          pairs.push(
            @parse.encode(name) +
            "=" +
            @parse.encode(
              doc
              .get_attribute(id, "value")
              .unwrap_or(
                if kind == "checkbox" || kind == "radio" {
                  "on"
                } else {
                  ""
                },
              ),
            ),
          )
        } else if tag == "textarea" {
          pairs.push(
            @parse.encode(name) + "=" + @parse.encode(doc.get_text_content(id)),
          )
        } else if tag == "select" {
          let choices = []
          nodes(doc, id, "option", choices)
          let available = choices.filter(c => !doc.has_attribute(c, "disabled"))
          let selected = available.filter(c => doc.has_attribute(c, "selected"))
          let selected = if selected.is_empty() &&
            !doc.has_attribute(id, "multiple") {
            available[:available.length().min(1)].to_owned()
          } else {
            selected
          }
          for choice in selected {
            pairs.push(
              @parse.encode(name) +
              "=" +
              @parse.encode(
                doc
                .get_attribute(choice, "value")
                .unwrap_or(doc.get_text_content(choice)),
              ),
            )
          }
        }
      }
      for child in doc.get_children(id) {
        controls(child)
      }
    }
    controls(form)
    if pairs.is_empty() {
      continue
    }
    let body = pairs.join("&")
    let url = if verb == "GET" {
      url.split("?").next().unwrap().to_owned() + "?" + body
    } else {
      url
    }
    let headers = options.headers.filter(h => {
      h.name.to_lower() != "content-type"
    })
    let opts = {
      ..options,
      http_method: Some(verb),
      data: if verb == "POST" {
        Some(body)
      } else {
        None
      },
      headers,
    }
    let t = @parse.template(url, opts, source={
      kind: "form",
      origin: page,
      depth,
    }) catch {
      _ => continue
    }
    result.push(t)
  }
  result
}
