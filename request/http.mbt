///|
pub(all) suberror ResponseTooLarge {
  ResponseTooLarge(Int32)
}

///|
/// One HTTP exchange; controller owns redirects, cookies, retry and timing policy.
pub(all) struct HttpTransport {}

///|
pub impl @core.Transport for HttpTransport with fn send(
  self,
  request,
  max_response_bytes~,
) {
  self.exchange(request, max_response_bytes~).response
}

///|
pub impl @core.Transport for HttpTransport with fn exchange(
  self,
  request,
  max_response_bytes~,
) {
  let _ = self
  let clock : &@core.Clock = @core.SystemClock::{ }
  let started = clock.now_ms()
  let headers : @http.Headers = Map([])
  for h in request.headers {
    let key = @http.CaseInsensitiveString(h.name)
    headers[key] = if headers.get(key) is Some(previous) {
      previous +
      (if h.name.to_lower() == "cookie" { "; " } else { ", " }) +
      h.value
    } else {
      h.value
    }
  }
  // Use common headers so a caller-provided User-Agent is supported.
  let client = @http.Client(headers~)
  defer client.close()
  let body = request.body.map(s => @utf8.encode(s))
  let extra_headers : @http.Headers = Map([])
  if body is Some(bytes) {
    extra_headers[CaseInsensitiveString("Content-Length")] = bytes
      .length()
      .to_string()
  }
  let verb = match request.http_method {
    "GET" => @http.Get
    "POST" => Post
    "HEAD" => Head
    "PUT" => Put
    "PATCH" => Patch
    "DELETE" => Delete
    "OPTIONS" => Options
    "TRACE" => Trace
    _ => Extension(request.http_method)
  }
  let conn = client.request(verb, request.url, extra_headers~)
  defer conn.close()
  if body is Some(bytes) {
    conn.write(bytes)
  }
  let response = conn.end_request()
  let buffer = @buffer.Buffer()
  while conn.read() is Some(chunk) {
    if chunk.length() > max_response_bytes - buffer.length() {
      raise ResponseTooLarge(max_response_bytes)
    }
    buffer.write_bytes(chunk)
  }
  // Strict UTF-8: unsupported encodings are failures, not altered evidence.
  {
    response: { status: response.code, body: @utf8.decode(buffer.to_bytes()), },
    headers: response.headers
    .iter()
    .map(pair => ({ name: pair.0.to_string(), value: pair.1, } : @core.Header))
    .to_array(),
    cookies: response.cookies.map(c => {
      (
        {
          name: c.name,
          value: c.value,
          domain: c.domain,
          path: c.path,
          secure: c.secure,
          max_age: c.max_age,
          expires: c.expires_raw,
        } : @core.ResponseCookie)
    }),
    final_url: request.url,
    elapsed_ms: (clock.now_ms() - started).max(0),
  }
}

///|
pub extend HttpTransport with @core.Transport::{send, exchange}
