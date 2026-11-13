///|
fn nodes(
  doc : @html.Document,
  id : Int32,
  tag : String,
  out : Array[Int32],
) -> Unit {
  if doc.get_tag_name(id) == Some(tag) {
    out.push(id)
  }
  for child in doc.get_children(id) {
    nodes(doc, child, tag, out)
  }
}

///|
fn elements(doc : @html.Document, tag : String) -> Array[Int32] {
  let out = []
  nodes(doc, 0, tag, out)
  out
}

///|
#derive(ToJson, FromJson)
priv struct CrawlState {
  queue : Array[(String, Int32)]
  visited : Array[String]
  final_urls : Map[String, String]
  pages : Array[String]
  targets : Array[(String, String, String?, Int32, String)]
}

///|
async fn discover(
  seed : @core.RequestTemplate,
  options : @core.Options,
  transport : &@core.Transport,
  clock : &@core.Clock,
  session : &@core.SessionStore?,
) -> (Array[@core.RequestTemplate], @core.ScanReport?) {
  if options.crawl == 0 && !options.forms {
    return ([seed], None)
  }
  let parsed = @parse.target(seed.request.url) catch {
    ConfigError(message) =>
      return ([], Some(configuration_error(seed.request.url, message)))
  }
  let ctx = @core.ScanContext::new(parsed, options, transport, clock~)
  ctx.template = Some({
    ..seed,
    source: { kind: "discovery", origin: seed.request.url, depth: 0, },
  })
  let cache_options = {
    ..options,
    time_limit_ms: None,
    fresh_queries: false,
    flush_session: false,
    session_file: None,
    output_dir: "",
    crawl_max_pages: 100,
  }
  let key = "crawl-v3:" +
    digest(seed.request.to_json().stringify()) +
    ":" +
    digest(cache_options.to_json().stringify())
  if options.flush_session && session is Some(store) {
    clear_session(
      ctx,
      store,
      "crawl-v3:" + digest(seed.request.to_json().stringify()) + ":",
      "Failed to clear crawl cache",
    )
  }
  let cached : CrawlState? = if !options.flush_session && session is Some(store) {
    read_crawl_state(store, key)
  } else {
    None
  }
  let state = cached.unwrap_or({
    queue: [(seed.request.url, 0)],
    visited: [],
    final_urls: {},
    pages: [],
    targets: [],
  })
  let found : Array[@core.RequestTemplate] = [seed]
  for (url, verb, body, depth, kind) in state.targets {
    let opts = {
      ..options,
      data: body,
      http_method: Some(verb),
      headers: if kind == "form" {
        seed.request.headers.filter(h => h.name.to_lower() != "content-type")
      } else {
        seed.request.headers
      },
      cookie: None,
    }
    let t = @parse.template(url, opts, source={
      kind,
      origin: seed.request.url,
      depth,
    }) catch {
      ConfigError(_) => continue
    }
    found.push(t)
  }
  let excluded = options.crawl_exclude.map(p => try! @string.Regex(p))
  while !state.queue.is_empty() {
    let (url, depth) = state.queue[0]
    if state.visited.contains(url) {
      ignore(state.queue.remove(0))
      continue
    }
    if state.pages.length() >= options.crawl_max_pages {
      @techniques.issue(
        ctx, "crawl-limit", "Per-seed crawl page limit reached; pending queue preserved",
      )
      break
    }
    let request = if depth == 0 {
      @parse.render_template(seed)
    } else {
      { ..@parse.render_template(seed), url, http_method: "GET", body: None, }
    }
    guard @techniques.exchange(ctx, request, "crawl") is Some((response, _)) else {
      break
    }
    ignore(state.queue.remove(0))
    state.visited.push(url)
    let page = response.final_url.split("#").next().unwrap().to_owned()
    state.final_urls[url] = page
    if !state.visited.contains(page) {
      state.visited.push(page)
    }
    let first_visit = !state.pages.contains(page)
    if first_visit {
      state.pages.push(page)
    }
    if first_visit &&
      response.response.status >= 200 &&
      response.response.status < 300 {
      let doc = @html.parse(response.response.body)
      if options.forms {
        for
          t in form_templates(
            doc,
            page,
            { ..options, headers: seed.request.headers, cookie: None, },
            depth,
          ) {
          let identity = (
            t.request.url,
            t.request.http_method,
            t.request.body,
            depth,
            "form",
          )
          if !state.targets.any(t => {
              t.0 == identity.0 && t.1 == identity.1 && t.2 == identity.2
            }) {
            state.targets.push(identity)
            found.push(t)
          }
        }
      }
      if depth < options.crawl {
        for id in elements(doc, "a") {
          guard doc.get_attribute(id, "href") is Some(href) &&
            @parse.resolve_url(page, href) is Some(next) else {
            continue
          }
          if @parse.origin(next) != @parse.origin(seed.request.url) ||
            excluded.map(re => re.execute(next) is Some(_)).unwrap_or(false) {
            continue
          }
          if !state.visited.contains(next) && !state.queue.any(p => p.0 == next) {
            state.queue.push((next, depth + 1))
          }
          let opts = {
            ..options,
            data: None,
            http_method: Some("GET"),
            headers: seed.request.headers,
            cookie: None,
          }
          let t = @parse.template(next, opts, source={
            kind: "crawl",
            origin: page,
            depth: depth + 1,
          }) catch {
            ConfigError(_) => continue
          }
          let identity = (next, "GET", None, depth + 1, "crawl")
          if !state.targets.any(t => {
              t.0 == identity.0 && t.1 == identity.1 && t.2 == identity.2
            }) {
            state.targets.push(identity)
            found.push(t)
          }
        }
      }
    }
    if response.response.status < 200 || response.response.status >= 300 {
      @techniques.issue(
        ctx,
        "crawl",
        "Crawled page returned HTTP \{response.response.status}: \{url}",
      )
    }
    if session is Some(store) {
      write_session(
        ctx,
        store,
        key,
        @json.ToJson::to_json(state).stringify(),
        "Failed to write crawl checkpoint",
      )
    }
  }
  let unique : Array[@core.RequestTemplate] = []
  for t in found {
    if t.source.kind == "crawl" &&
      !state.final_urls.contains(t.request.url) &&
      !state.pages.contains(t.request.url) {
      continue
    }
    let t = { ..t, request: @techniques.attach_cookies(ctx, t.request), }
    if !unique.any(u => u.request == t.request) {
      unique.push(t)
    }
  }
  let candidates = unique.filter(t => {
    let selected = @parse.select_template(
      t,
      options.parameters,
      allow_empty=true,
    ) catch {
      ConfigError(_) => return false
    }
    !selected.is_empty()
  })
  if candidates.is_empty() && !ctx.has_errors() {
    @techniques.issue(
      ctx, "discovery-empty", "No testable parameters found; injection testing was not performed",
    )
  }
  (candidates, Some(report(ctx)))
}

///|
fn read_crawl_state(
  store : &@core.SessionStore,
  key : String,
) -> CrawlState? raise {
  // SessionStore implementations may raise arbitrary errors; cache reads are optional.
  let raw = store.get(key) catch { _ => return None }
  raw.map(raw => @json.from_json(@json.parse(raw))) catch {
    @json.ParseError::_ | @json.JsonDecodeError::_ => None
    err => raise err
  }
}
