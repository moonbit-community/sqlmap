///|
fn cookie_path(url : String) -> String {
  let rest = url[if url.has_prefix("https://") { 8 } else { 7 }:].to_owned()
  let path = rest.find("/").map(i => rest[i:].to_owned()).unwrap_or("/")
  path.split("?").next().unwrap().to_owned()
}

///|
fn accept_cookies(
  ctx : @core.ScanContext,
  result : @core.Exchange,
  url : String,
) -> Unit {
  if ctx.options.drop_set_cookie {
    return
  }
  let origin = @parse.origin(url)
  let path = cookie_path(url)
  for cookie in result.cookies {
    // Host-only storage prevents a response widening credential scope.
    if cookie.domain is Some(domain) {
      let host = origin[if origin.has_prefix("https://") { 8 } else { 7 }:]
        .to_owned()
        .split(":")
        .next()
        .unwrap()
        .to_owned()
      if domain.trim_start(chars=".").to_owned().to_lower() != host {
        continue
      }
    }
    let cookie_path = cookie.path
      .filter(p => p.has_prefix("/"))
      .unwrap_or(path[:path.rev_find("/").unwrap_or(0)].to_owned())
    let cookie_path = if cookie_path.is_empty() { "/" } else { cookie_path }
    let entries = ctx.cookies.filter(c => {
      !(c.host == origin &&
      c.path == cookie_path &&
      c.cookie.name == cookie.name)
    })
    ctx.cookies.clear()
    ctx.cookies.append(entries)
    if cookie.max_age.map(age => age <= 0).unwrap_or(false) {
      continue
    }
    let expires_at = if cookie.max_age is Some(age) {
      Some(ctx.clock.now_ms() + age.min(2147483647L) * 1000)
    } else {
      cookie.expires.bind(cookie_date)
    }
    if expires_at.map(t => t <= ctx.clock.now_ms()).unwrap_or(false) {
      continue
    }
    ctx.cookies.push({ cookie, host: origin, path: cookie_path, expires_at, })
  }
}

///|
pub fn attach_cookies(
  ctx : @core.ScanContext,
  request : @core.Request,
) -> @core.Request {
  let path = cookie_path(request.url)
  let existing = request.headers
    .filter(h => h.name.to_lower() == "cookie")
    .map(h => h.value)
    .join("; ")
  let explicit_names = existing
    .split(";")
    .map(p => p.split("=").next().unwrap_or("").trim().to_owned())
    .to_array()
  let values = ctx.cookies.filter(c => {
    c.host == @parse.origin(request.url) &&
    (!c.cookie.secure || request.url.has_prefix("https://")) &&
    (
      path == c.path ||
      path.has_prefix(c.path + (if c.path.has_suffix("/") { "" } else { "/" }))
    ) &&
    c.expires_at.map(t => t > ctx.clock.now_ms()).unwrap_or(true) &&
    !explicit_names.contains(c.cookie.name)
  })
  let headers = request.headers.copy()
  if !values.is_empty() {
    headers.push({
      name: "Cookie",
      value: values.map(c => c.cookie.name + "=" + c.cookie.value).join("; "),
    })
  }
  { ..request, headers, }
}

///|
pub async fn exchange(
  ctx : @core.ScanContext,
  original : @core.Request,
  phase : String,
  parameter? : @core.Parameter,
) -> (@core.Exchange, Int32)? {
  // A strategy may try a fallback after a failed exchange. Coverage loss stops
  // the entire target, including those later requests.
  if ctx.issues.any(i => i.fatal && i.phase == "redirect-coverage") {
    return None
  }
  let mut current = original
  let started = ctx.clock.now_ms()
  let mut retried = false
  for redirects = 0; redirects <= 10; redirects = redirects + 1 {
    let mut attempt = 0
    let mut result : (@core.Exchange, Int32)? = None
    while attempt <= ctx.options.retries {
      let now = ctx.clock.now_ms()
      if now < started || now < ctx.last_request {
        ctx.clock_valid = false
      }
      let remaining = ctx.options.time_limit_ms.map(limit => {
        limit.to_int64() - (now - ctx.started)
      })
      if remaining.map(r => r <= 0).unwrap_or(false) {
        issue(
          ctx,
          "limit",
          "--time-limit reached; partial results preserved",
          parameter?,
        )
        return None
      }
      if ctx.last_request >= 0 && ctx.options.delay_ms > 0 {
        let wait = ctx.options.delay_ms.to_int64() - (now - ctx.last_request)
        if wait > 0 {
          @async.sleep(wait.to_int())
        }
      }
      ctx.last_request = ctx.clock.now_ms()
      let remaining = ctx.options.time_limit_ms.map(limit => {
        limit.to_int64() - (ctx.clock.now_ms() - ctx.started)
      })
      if remaining.map(r => r <= 0).unwrap_or(false) {
        issue(
          ctx,
          "limit",
          "--time-limit reached; partial results preserved",
          parameter?,
        )
        return None
      }
      let timeout = remaining
        .map(r => r.to_int().min(ctx.options.timeout_ms))
        .unwrap_or(ctx.options.timeout_ms)
        .max(1)
      ctx.attempted += 1
      let id = ctx.attempted
      let response = @async.with_timeout(timeout, () => {
        ctx.transport.exchange(
          attach_cookies(ctx, current),
          max_response_bytes=ctx.options.max_response_bytes,
        )
      }) catch {
        @async.TimeoutError as err => {
          ctx.failed += 1
          ctx.timed_out += 1
          if attempt < ctx.options.retries &&
            !remaining.map(r => r <= timeout.to_int64()).unwrap_or(false) {
            ctx.retried += 1
            retried = true
            attempt += 1
            issue(
              ctx,
              phase,
              "Request timed out; retry \{attempt}/\{ctx.options.retries}",
              parameter?,
              request_id=id,
              fatal=false,
            )
            continue
          }
          issue(ctx, phase, "\{(err : Error)}", parameter?, request_id=id)
          return None
        }
        // Transport is an open interface; every other failure is fatal for this request.
        err => {
          ctx.failed += 1
          issue(ctx, phase, "\{err}", parameter?, request_id=id)
          return None
        }
      }
      ctx.succeeded += 1
      result = Some((response, id))
      break
    }
    guard result is Some((response, id)) else { return None }
    accept_cookies(ctx, response, current.url)
    let location = response.headers
      .iter()
      .find_first(h => h.name.to_lower() == "location")
      .map(h => h.value)
    if !ctx.options.ignore_redirects &&
      [301, 302, 303, 307, 308].contains(response.response.status) &&
      location is Some(location) {
      guard @parse.resolve_url(current.url, location) is Some(next) else {
        issue(ctx, "redirect", "Invalid redirect URL", parameter?)
        return None
      }
      if @parse.origin(next) != @parse.origin(original.url) {
        issue(
          ctx,
          "redirect",
          "Cross-origin redirect was not followed",
          parameter?,
        )
        return None
      }
      if redirects == 10 {
        issue(ctx, "redirect", "Redirect limit of 10 exceeded", parameter?)
        return None
      }
      let get = (
          response.response.status == 303 && current.http_method != "HEAD"
        ) ||
        (
          (response.response.status == 301 || response.response.status == 302) &&
          current.http_method == "POST"
        )
      let next_request : @core.Request = {
        url: next,
        http_method: if get {
          "GET"
        } else {
          current.http_method
        },
        body: if get {
          None
        } else {
          current.body
        },
        headers: if get {
          current.headers.filter(h => h.name.to_lower() != "content-type")
        } else {
          current.headers
        },
      }
      if !check_redirect_coverage(
          ctx, original, next_request, phase, parameter, id,
        ) {
        return None
      }
      current = next_request
      continue
    }
    let end = ctx.clock.now_ms()
    ctx.last_elapsed = end - started
    ctx.last_retried = retried
    if end < started {
      ctx.clock_valid = false
    }
    return Some(
      (
        {
          ..response,
          final_url: current.url,
          elapsed_ms: ctx.last_elapsed.max(0),
        },
        id,
      ),
    )
  }
  None
}
