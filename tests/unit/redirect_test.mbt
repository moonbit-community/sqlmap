///|
async test "redirect coverage stops a baseline before missing or overwritten inputs are followed" {
  for destination in ["/login", "/end?id=2", "/end?id=1"] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (_, _) => {
        response(302, "", headers=[{ name: "Location", value: destination, }])
      },
    }
    let report = @controller.scan(
      "http://a.test/private?id=1&token=keep",
      { ..@core.Options::default(), techniques: [ErrorBased], },
      mock,
    )
    assert_eq(report.verdict, Inconclusive)
    assert_eq(report.exit_code(), 2)
    assert_false(report.complete)
    assert_eq(report.tested_parameters, 0)
    assert_eq(report.requests.attempted, 1)
    assert_eq(mock.requests.length(), 1)
    assert_true(report.findings.is_empty())
    assert_true(
      report.issues.all(i => i.phase == "redirect-coverage" && i.fatal),
    )
    assert_true(report.issues.all(i => i.message.contains(destination)))
    assert_true(report.issues.any(i => i.parameter == Some("token")))
    assert_eq(report.issues[0].request_id, Some(1))
  }
}

///|
async test "redirect coverage compares each repeated query occurrence" {
  for
    (query, next) in [
      ("id=1&id=1", "id=1"),
      ("id=1&id=2", "id=2&id=1"),
      ("id=1&id=2*", "id=2&id=1"),
    ] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (_, _) => {
        response(302, "", headers=[{ name: "Location", value: "/end?" + next, }])
      },
    }
    let report = @controller.scan(
      "http://a.test/start?" + query,
      { ..@core.Options::default(), techniques: [ErrorBased], },
      mock,
    )
    assert_eq(report.exit_code(), 2)
    assert_eq(report.tested_parameters, 0)
    assert_eq(mock.requests.length(), 1)
    assert_true(report.issues.any(i => i.parameter == Some("id")))
  }
}

///|
async test "redirect query matching accepts encoding changes unrelated order and multiple markers" {
  for query in ["id=one+two&id=%C3%A9&keep=1", "id=one&id=tw**o&keep=1"] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (r, _) => {
        if r.url.contains("/start?") {
          let ids = (try! @parse.target(r.url)).query.filter(p => p.name == "id")
          let query = ids
            .map(p => {
              "%69d=" +
              @parse.encode(p.value)
              .replace(old="%20", new="+")
              .replace(old="%E", new="%e")
            })
            .join("&")
          response(302, "", headers=[
            { name: "Location", value: "/end?extra=ok&" + query + "&keep=1", },
          ])
        } else {
          response(200, "stable")
        }
      },
    }
    let report = @controller.scan(
      "http://a.test/start?" + query,
      {
        ..@core.Options::default(),
        techniques: [ErrorBased],
        parameters: ["id"],
      },
      mock,
    )
    assert_eq(report.exit_code(), 0)
    assert_eq(report.tested_parameters, if query.contains("*") { 3 } else { 2 })
    assert_true(report.issues.is_empty())
    assert_eq(report.requests.attempted, mock.requests.length())
  }
}

///|
async test "redirect checks selected inputs on baseline and only the current input on probes" {
  for names in [["id"], ["id", "mode"]] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (r, _) => {
        if !r.url.contains("/start?") {
          return response(200, "stable")
        }
        let query = (try! @parse.target(r.url)).query
        let pairs = if query[0].value != "1" || names.length() == 1 {
          [query[0]]
        } else if query[1].value != "2" {
          [query[1]]
        } else {
          query
        }
        response(302, "", headers=[
          {
            name: "Location",
            value: "/end?" + pairs.map(p => p.raw).join("&"),
          },
        ])
      },
    }
    let report = @controller.scan(
      "http://a.test/start?id=1&mode=2",
      {
        ..@core.Options::default(),
        techniques: [ErrorBased],
        parameters: names,
      },
      mock,
    )
    assert_eq(report.exit_code(), 0)
    assert_eq(report.tested_parameters, names.length())
  }
}

///|
async test "fixed rewrite passes the baseline but stops the first changed probe" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      if r.url.contains("/start?") {
        response(302, "", headers=[{ name: "Location", value: "/end?id=1", }])
      } else {
        response(200, "stable")
      }
    },
  }
  let report = @controller.scan(
    "http://a.test/start?id=1",
    { ..@core.Options::default(), techniques: [ErrorBased], },
    mock,
  )
  assert_eq(report.exit_code(), 2)
  assert_eq(report.tested_parameters, 1)
  assert_eq(report.requests.attempted, 7)
  assert_eq(
    mock.requests.filter(r => r.url == "http://a.test/end?id=1").length(),
    3,
  )
  assert_eq(report.issues[0].phase, "redirect-coverage")
  assert_eq(report.issues[0].request_id, Some(7))
}

///|
async test "redirect coverage retains findings collected before a later parameter fails" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      let query = (try! @parse.target(r.url)).query
      if query[1].value != "2" {
        response(302, "", headers=[{ name: "Location", value: "/end?a=1&b=2", }])
      } else if query[0].value != "1" {
        response(500, "SQLite error: bad token")
      } else {
        response(200, "stable")
      }
    },
  }
  let report = @controller.scan(
    "http://a.test/start?a=1&b=2",
    { ..@core.Options::default(), techniques: [ErrorBased], },
    mock,
  )
  assert_eq(report.exit_code(), 2)
  assert_eq(report.verdict, Inconclusive)
  assert_eq(report.tested_parameters, 2)
  assert_eq(report.findings.length(), 1)
  assert_eq(report.findings[0].parameter, "a")
  assert_eq(report.findings[0].verdict, Confirmed)
  assert_eq(report.issues[0].parameter, Some("b"))
  assert_true(mock.requests.all(r => !r.url.contains("/end")))
}

///|
async test "redirect coverage is checked on every hop" {
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      response(302, "", headers=[
        {
          name: "Location",
          value: if r.url.contains("/start") {
            "/middle?id=1"
          } else {
            "/login"
          },
        },
      ])
    },
  }
  let report = @controller.scan(
    "http://a.test/start?id=1",
    @core.Options::default(),
    mock,
  )
  assert_eq(report.tested_parameters, 0)
  assert_eq(report.requests.attempted, 2)
  assert_eq(report.issues[0].phase, "redirect-coverage")
  assert_eq(report.issues[0].request_id, Some(2))
  assert_eq(mock.requests.length(), 2)
}

///|
async test "redirect method rules preserve form JSON and marked bodies or stop before dropping them" {
  for
    body in [
      "id=1",
      (
        #|{"id":1}
      ),
      "id=1*",
      (
        #|{"id":1*}
      ),
    ] {
    for verb in ["POST", "PUT", "HEAD"] {
      for status in [301, 302, 303, 307, 308] {
        let mock = ExchangeMock::{
          requests: [],
          handler: (r, _) => {
            if r.url.has_suffix("/start") {
              response(status, "", headers=[
                { name: "Location", value: "/end", },
              ])
            } else {
              response(200, "stable")
            }
          },
        }
        let report = @controller.scan(
          "http://a.test/start",
          {
            ..@core.Options::default(),
            techniques: [ErrorBased],
            data: Some(body),
            http_method: Some(verb),
          },
          mock,
        )
        let drops = (status == 303 && verb != "HEAD") ||
          ((status == 301 || status == 302) && verb == "POST")
        assert_eq(report.exit_code(), if drops { 2 } else { 0 })
        assert_eq(report.tested_parameters, if drops { 0 } else { 1 })
        if drops {
          assert_eq(mock.requests.length(), 1)
          assert_eq(report.issues[0].phase, "redirect-coverage")
        } else {
          for i in 0..<(mock.requests.length() / 2) {
            assert_eq(mock.requests[2 * i].body, mock.requests[2 * i + 1].body)
            assert_eq(mock.requests[2 * i + 1].http_method, verb)
          }
        }
      }
    }
  }
}

///|
async test "POST to GET remains allowed for a selected query and blocks a removed selected header" {
  for names in [["query:id"], ["header:Content-Type"]] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (r, _) => {
        if r.url.contains("/start?") {
          response(303, "", headers=[
            {
              name: "Location",
              value: r.url.replace(old="/start?", new="/end?"),
            },
          ])
        } else {
          response(200, "stable")
        }
      },
    }
    let report = @controller.scan(
      "http://a.test/start?id=1",
      {
        ..@core.Options::default(),
        techniques: [ErrorBased],
        data: Some("other=1"),
        parameters: names,
      },
      mock,
    )
    if names[0] == "query:id" {
      assert_eq(report.exit_code(), 0)
      assert_true(
        mock.requests
        .filter(r => r.url.contains("/end?"))
        .all(r => r.http_method == "GET" && r.body is None),
      )
    } else {
      assert_eq(report.exit_code(), 2)
      assert_eq(report.tested_parameters, 0)
      assert_eq(report.issues[0].location, Some(HeaderValue))
      assert_eq(mock.requests.length(), 1)
    }
  }
}

///|
async test "redirects retain repeated marked Cookie and header fields" {
  let options = {
    ..@core.Options::default(),
    techniques: [ErrorBased],
    headers: [
      { name: "Cookie", value: "sid=first;sid=sec**ond", },
      { name: "cookie", value: "sid=third*", },
      { name: "X-Id", value: "first", },
      { name: "x-id", value: "sec**ond", },
    ],
  }
  let mock = ExchangeMock::{
    requests: [],
    handler: (r, _) => {
      if r.url.has_suffix("/start") {
        response(302, "", headers=[{ name: "Location", value: "/end", }], cookies=[
          {
            name: "sid",
            value: "replacement",
            domain: None,
            path: Some("/"),
            secure: false,
            max_age: None,
            expires: None,
          },
        ])
      } else {
        response(200, "stable")
      }
    },
  }
  let report = @controller.scan("http://a.test/start", options, mock)
  assert_eq(report.exit_code(), 0)
  assert_eq(report.tested_parameters, 5)
  for i in 0..<(mock.requests.length() / 2) {
    assert_eq(mock.requests[2 * i].headers, mock.requests[2 * i + 1].headers)
  }
}

///|
async test "path marker coverage requires the path to remain unchanged" {
  for keep in [false, true] {
    let mock = ExchangeMock::{
      requests: [],
      handler: (r, _) => {
        if r.url.has_suffix("?step=1") {
          response(302, "", headers=[
            {
              name: "Location",
              value: if keep {
                r.url.replace(old="?step=1", new="?step=2")
              } else {
                "/login"
              },
            },
          ])
        } else {
          response(200, "stable")
        }
      },
    }
    let report = @controller.scan(
      "http://a.test/item/1*?step=1",
      { ..@core.Options::default(), techniques: [ErrorBased], },
      mock,
    )
    assert_eq(report.exit_code(), if keep { 0 } else { 2 })
    if !keep {
      assert_eq(report.tested_parameters, 0)
      assert_eq(report.issues[0].location, Some(Path))
      assert_eq(mock.requests.length(), 1)
    }
  }
}
