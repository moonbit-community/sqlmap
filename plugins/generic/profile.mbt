///|
fn visible(doc : @html.Document, node : Int32, titles : Bool) -> String {
  let tag = doc.get_tag_name(node).unwrap_or("")
  if ["script", "style", "template"].contains(tag) {
    return ""
  }
  if titles && tag == "title" {
    return doc.get_text_content(node)
  }
  match doc.get_node(node) {
    Some(TextNode(text)) => if titles { "" } else { text }
    _ => doc.get_children(node).map(id => visible(doc, id, titles)).join(" ")
  }
}

///|
pub fn comparison_text(body : String, rule : @core.ComparisonRule) -> String {
  normalize(
    if rule.text_only || rule.titles {
      visible(@html.parse(body), 0, rule.titles)
    } else {
      body
    },
  )
}

///|
/// Learn only from original responses. Token positions and the predicate are frozen before any probes.
pub fn comparator(
  samples : Array[@core.Response],
  rule : @core.ComparisonRule,
) -> ((@core.Response, @core.Response) -> Bool)? {
  guard samples.length() >= 3 else { return None }
  let regex = if rule.regexp is Some(pattern) {
    Some(@string.Regex(pattern) catch { _ => return None })
  } else {
    None
  }
  let explicit = rule.string is Some(_) ||
    rule.not_string is Some(_) ||
    regex is Some(_) ||
    rule.code is Some(_)
  fn predicate(r : @core.Response) -> Bool {
    let body = comparison_text(r.body, rule)
    rule.string.map(s => body.contains(s)).unwrap_or(true) &&
    rule.not_string.map(s => !body.contains(s)).unwrap_or(true) &&
    regex.map(re => re.execute(body) is Some(_)).unwrap_or(true) &&
    rule.code.map(code => r.status == code).unwrap_or(true)
  }
  if explicit {
    if !samples.all(predicate) {
      return None
    }
    return Some((a, b) => predicate(a) == predicate(b))
  }
  if !samples.all(r => r.status == samples[0].status) {
    return None
  }
  let texts = samples.map(r => comparison_text(r.body, rule))
  if texts.all(t => t == texts[0]) {
    return Some((a, b) => {
      a.status == b.status &&
      comparison_text(a.body, rule) == comparison_text(b.body, rule)
    })
  }
  guard samples.length() >= 5 else { return None }
  let tokens = texts.map(t => t.split(" ").map(s => s.to_owned()).to_array())
  let count = tokens[0].length()
  if !tokens.all(t => t.length() == count) {
    return None
  }
  let dynamic : Array[Int32] = []
  let mut stable_length = 0
  for i in 0..<count {
    if tokens.all(t => t[i] == tokens[0][i]) {
      stable_length += tokens[0][i].length()
    } else {
      dynamic.push(i)
    }
  }
  if stable_length < 32 ||
    stable_length * 100 < texts[0].length() * 60 ||
    dynamic.length() * 4 > count {
    return None
  }
  fn masked(r : @core.Response) -> String? {
    let words = comparison_text(r.body, rule)
      .split(" ")
      .map(s => s.to_owned())
      .to_array()
    if words.length() != count {
      return None
    }
    for i in dynamic {
      words[i] = ""
    }
    Some(words.join(" "))
  }
  Some((a, b) => {
    a.status == b.status && masked(a) is Some(value) && masked(b) == Some(value)
  })
}
