///|
async test "empty discovery and disabled POST forms explicitly report no injection testing" {
  for
    body in [
      "plain page",
      (
        #|<form action='/submit' method='post'><input name='id' value='1'></form>
      ),
    ] {
    for crawl in [0, 1] {
      let mock = ExchangeMock::{
        requests: [],
        handler: (_, _) => response(200, body),
      }
      let opts = {
        ..@core.Options::default(),
        techniques: [ErrorBased],
        crawl,
      }
      let batch = @controller.scan_batch(
        [@parse.template("http://a.test/empty", opts)],
        opts,
        mock,
      )
      assert_eq(batch.exit_code(), 2)
      assert_false(batch.complete)
      assert_eq(batch.reports.length(), 1)
      let report = batch.reports[0]
      assert_eq(report.verdict, Inconclusive)
      assert_eq(report.tested_parameters, 0)
      assert_true(report.findings.is_empty())
      assert_eq(report.issues.length(), 1)
      assert_eq(report.issues[0].phase, "discovery-empty")
      assert_eq(
        report.issues[0].message,
        "No testable parameters found; injection testing was not performed",
      )
      assert_eq(report.requests.attempted, crawl)
      assert_eq(mock.requests.length(), crawl)
      assert_true(
        @report.render_batch(batch, Text).contains(
          "injection testing was not performed",
        ),
      )
    }
  }
}

///|
async test "discovery reports with candidates do not make a completed batch inconclusive" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (_, _) => {
      response(
        200,
        (
          #|<form action='/submit' method='post'><input name='id' value='1'></form>
        ),
      )
    },
  }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    forms: true,
  }
  let batch = @controller.scan_batch(
    [@parse.template("http://a.test/root", opts)],
    opts,
    mock,
  )
  assert_eq(batch.exit_code(), 0)
  assert_eq(batch.reports.length(), 2)
  assert_eq(batch.reports[0].source.kind, "discovery")
  assert_eq(batch.reports[0].tested_parameters, 0)
  assert_true(batch.reports[0].issues.is_empty())
  assert_eq(batch.reports[1].source.kind, "form")
  assert_eq(batch.reports[1].tested_parameters, 1)
}

///|
async test "empty discovery in a mixed batch leaves other seeds testable" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (_, _) => response(200, "stable"),
  }
  let opts = { ..@core.Options::default(), techniques: [ErrorBased], crawl: 1, }
  let templates = ["http://a.test/empty", "http://a.test/safe?id=1"].map(u => {
    try! @parse.template(u, opts)
  })
  let batch = @controller.scan_batch(templates, opts, mock)
  assert_eq(batch.exit_code(), 2)
  assert_eq(batch.reports.length(), 3)
  assert_eq(batch.reports[0].issues[0].phase, "discovery-empty")
  assert_true(batch.reports[1].complete)
  assert_eq(batch.reports[1].tested_parameters, 0)
  assert_true(batch.reports[2].complete)
  assert_eq(batch.reports[2].tested_parameters, 1)
}

///|
async test "empty discovery does not mask a crawl failure or page limit" {
  for status in [200, 500] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (_, _) => response(status, "<a href='/next'>next</a>"),
    }
    let opts = { ..@core.Options::default(), crawl: 1, crawl_max_pages: 1, }
    let batch = @controller.scan_batch(
      [@parse.template("http://a.test/root", opts)],
      opts,
      mock,
    )
    assert_eq(batch.exit_code(), 2)
    assert_eq(batch.reports[0].issues.length(), 1)
    assert_eq(
      batch.reports[0].issues[0].phase,
      if status == 200 {
        "crawl-limit"
      } else {
        "crawl"
      },
    )
  }
}

///|
async test "redirect final page self links leave room for the second page and resume correctly" {
  let store = MemorySession::{ values: {}, }
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      if r.url.has_suffix("/root") {
        response(302, "", headers=[{ name: "Location", value: "/login#entry", }])
      } else if r.url.has_suffix("/login") {
        response(
          200,
          (
            #|<a href='/login#self'>self</a><a href='/root'>alias</a><a href='/second?id=1#part'>second</a>
          ),
        )
      } else {
        response(
          200,
          (
            #|<a href='/login'>visited</a><a href='/second?id=1'>self</a>
          ),
        )
      }
    },
  }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    crawl: 3,
    crawl_max_pages: 1,
  }
  let seed = @parse.template("http://a.test/root", opts)
  let first = @controller.scan_batch([seed], opts, mock, session=store)
  assert_eq(first.exit_code(), 2)
  assert_eq(first.reports[0].requests.attempted, 2)
  assert_eq(first.reports[0].issues[0].phase, "crawl-limit")
  let key = store.values.keys().to_array()[0]
  assert_true(key.has_prefix("crawl-v3:"))
  guard @json.parse(store.values[key])
    is {
      "visited": Array(visited),
      "final_urls": { "http://a.test/root": "http://a.test/login", .. },
      "pages": ["http://a.test/login"],
      ..
    } else {
    fail("missing final page checkpoint")
  }
  assert_true(visited.contains(Json::string("http://a.test/login")))
  let before = mock.requests.length()
  let second = @controller.scan_batch(
    [seed],
    { ..opts, crawl_max_pages: 2, },
    mock,
    session=store,
  )
  assert_eq(second.exit_code(), 0)
  assert_eq(second.reports[0].requests.attempted, 1)
  assert_eq(mock.requests[before].url, "http://a.test/second?id=1")
  assert_eq(mock.requests.filter(r => r.url.has_suffix("/login")).length(), 1)
  assert_eq(mock.requests.filter(r => r.url.has_suffix("/root")).length(), 1)
  assert_true(mock.requests.all(r => !r.url.contains("#")))
  let before = mock.requests.length()
  let resumed = @controller.scan_batch(
    [seed],
    { ..opts, crawl_max_pages: 2, },
    mock,
    session=store,
  )
  assert_eq(resumed.exit_code(), 0)
  assert_eq(resumed.reports[0].requests.attempted, 0)
  assert_eq(
    mock.requests.length() - before,
    resumed.reports[1].requests.attempted,
  )
  let fresh = @controller.scan_batch(
    [seed],
    { ..opts, crawl_max_pages: 2, flush_session: true, },
    mock,
    session=store,
  )
  assert_eq(fresh.exit_code(), 0)
  assert_eq(fresh.reports[0].requests.attempted, 3)
}

///|
async test "multiple aliases parse and count one final page while counting every HTTP request" {
  let logins : Array[Unit] = []
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      if r.url.has_suffix("/root") || r.url.has_suffix("/alias") {
        response(302, "", headers=[{ name: "Location", value: "/login", }])
      } else if r.url.has_suffix("/login") {
        logins.push(())
        response(
          200,
          if logins.length() == 1 {
            (
              #|<a href='/alias'>alias</a><a href='/login'>self</a><a href='/second?id=1'>second</a>
            )
          } else {
            (
              #|<form action='/must-not-parse' method='post'><input name='id' value='1'></form>
            )
          },
        )
      } else {
        response(200, "stable")
      }
    },
  }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    crawl: 2,
    forms: true,
    crawl_max_pages: 2,
  }
  let batch = @controller.scan_batch(
    [@parse.template("http://a.test/root", opts)],
    opts,
    mock,
  )
  assert_eq(batch.exit_code(), 0)
  assert_eq(batch.reports.length(), 2)
  assert_eq(batch.reports[0].requests.attempted, 5)
  assert_eq(batch.reports[1].target, "http://a.test/second?id=1")
  assert_true(mock.requests.all(r => !r.url.contains("must-not-parse")))
  assert_eq(
    mock.requests.length(),
    batch.reports.fold(init=0, (n, r) => n + r.requests.attempted),
  )
}

///|
async test "final URL query strings remain distinct and page dedup does not merge scan requests" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      if r.url.has_suffix("/root") {
        response(
          200,
          (
            #|<a href='/one?id=1'>one</a><a href='/two?id=1'>two</a><a href='/final?id=1#self'>self</a><a href='/final?id=2'>different query</a>
          ),
        )
      } else if r.url.contains("/one?") || r.url.contains("/two?") {
        response(302, "", headers=[
          {
            name: "Location",
            value: "/final?" + r.url.split("?").to_array()[1].to_owned(),
          },
        ])
      } else {
        response(200, "stable")
      }
    },
  }
  let store = MemorySession::{ values: {}, }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    crawl: 2,
    crawl_max_pages: 3,
  }
  let batch = @controller.scan_batch(
    [@parse.template("http://a.test/root", opts)],
    opts,
    mock,
    session=store,
  )
  assert_eq(batch.exit_code(), 0)
  assert_eq(batch.reports.length(), 5)
  assert_eq(batch.reports[0].requests.attempted, 6)
  assert_true(batch.reports[1:].iter().all(r => r.tested_parameters == 1))
  let key = store.values
    .keys()
    .find_first(k => k.has_prefix("crawl-v3:"))
    .unwrap()
  guard @json.parse(store.values[key]) is { "pages": Array(pages), .. } else {
    fail("missing pages")
  }
  assert_eq(pages.length(), 3)
  assert_true(pages.contains(Json::string("http://a.test/final?id=1")))
  assert_true(pages.contains(Json::string("http://a.test/final?id=2")))
}

///|
async test "already queued final URLs are removed before enforcing the page cap" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      if r.url.has_suffix("/root") {
        response(
          200,
          (
            #|<a href='/alias'>alias</a><a href='/final'>final</a>
          ),
        )
      } else if r.url.has_suffix("/alias") {
        response(302, "", headers=[{ name: "Location", value: "/final", }])
      } else if r.url.has_suffix("/final") {
        response(
          200,
          (
            #|<form action='/submit' method='post'><input name='id' value='1'></form>
          ),
        )
      } else {
        response(200, "stable")
      }
    },
  }
  let opts = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    crawl: 2,
    forms: true,
    crawl_max_pages: 2,
  }
  let batch = @controller.scan_batch(
    [@parse.template("http://a.test/root", opts)],
    opts,
    mock,
  )
  assert_eq(batch.exit_code(), 0)
  assert_eq(batch.reports.length(), 2)
  assert_eq(batch.reports[0].requests.attempted, 3)
  assert_eq(mock.requests.filter(r => r.url.has_suffix("/final")).length(), 1)
}

///|
async test "crawl v2 checkpoints are ignored without changing session storage" {
  let store = MemorySession::{ values: {}, }
  let mock = ExchangeMock::{
    requests: [],
    handler: (_, _) => response(200, "empty"),
  }
  let opts = { ..@core.Options::default(), crawl: 1, }
  let seed = @parse.template("http://a.test/root", opts)
  ignore(@controller.scan_batch([seed], opts, mock, session=store))
  let key = store.values.keys().to_array()[0]
  assert_true(key.has_prefix("crawl-v3:"))
  let old_key = key.replace(old="crawl-v3:", new="crawl-v2:")
  store.values.remove(key)
  store.values[old_key] = (
    #|{"queue":[],"visited":["http://a.test/root"],"targets":[]}
  )
  let before = mock.requests.length()
  let batch = @controller.scan_batch([seed], opts, mock, session=store)
  assert_eq(batch.reports[0].requests.attempted, 1)
  assert_eq(mock.requests.length(), before + 1)
  assert_true(store.values.contains(key))
  assert_true(store.values.contains(old_key))
}
