///|
/// Collapse Unicode whitespace; preserve all other content and its order.
pub fn normalize(body : String) -> String {
  let out = StringBuilder()
  let mut pending_space = false
  let mut started = false
  for c in body {
    if c.is_whitespace() {
      pending_space = started
    } else {
      if pending_space {
        out.write_char(' ')
      }
      out.write_char(c)
      started = true
      pending_space = false
    }
  }
  out.to_string()
}

///|
pub fn equivalent(a : @core.Response, b : @core.Response) -> Bool {
  a.status == b.status && normalize(a.body) == normalize(b.body)
}

///|
pub fn observation(
  response : @core.Response,
  baseline : @core.Response,
  request_id : Int32,
) -> @core.Observation {
  {
    request_id,
    status: response.status,
    normalized_length: normalize(response.body).length(),
    matches_baseline: equivalent(response, baseline),
  }
}
