///|
test "JSON nested slots change one field and preserve original notation" {
  let body =
    #| {"a":1e2, "items":["café",{"a/b":2}],"ok":true,"n":null} 
  let opts = { ..@core.Options::default(), data: Some(body), }
  let t = @parse.template("http://example.test/?q=a+b&q=%32", opts)
  let slots = @parse.select_template(t, ["json:/items/1/a~1b"])
  assert_eq(slots.length(), 1)
  let changed = @parse.render_template(t, replacement=(slots[0], "2 AND 7=7"))
  assert_eq(changed.url, t.request.url)
  assert_eq(
    changed.body,
    Some(
      (
        #| {"a":1e2, "items":["café",{"a/b":"2 AND 7=7"}],"ok":true,"n":null} 
      ),
    ),
  )
  assert_eq(@parse.render_template(t).body, Some(body))
  assert_eq(@parse.select_template(t, []).length(), 5)
}

///|
test "markers in path JSON and duplicate cookies have distinct identities" {
  let opts = {
    ..@core.Options::default(),
    data: Some(
      (
        #|{"a":"x*y*","b":3}
      ),
    ),
    cookie: Some("sid=1; sid=2"),
    headers: [{ name: "X-Token", value: "hi*", }],
  }
  let t = @parse.template("http://example.test/api/*?id=1&id=*", opts)
  let chosen = @parse.select_template(t, [])
  assert_eq(chosen.length(), 5)
  let original = @parse.render_template(t)
  assert_eq(original.url, "http://example.test/api/?id=1&id=")
  assert_eq(
    original.body,
    Some(
      (
        #|{"a":"xy","b":3}
      ),
    ),
  )
  let cookies = @parse.select_template(t, ["cookie:sid"])
  assert_eq(cookies.length(), 2)
  assert_true(cookies[0].index != cookies[1].index)
  let changed = @parse.render_template(t, replacement=(cookies[1], "second"))
  assert_eq(changed.headers[1].value, "sid=1; sid=second")
  let changed = @parse.render_template(t, replacement=(chosen[1], "\"é"))
  ignore(@json.parse(changed.body.unwrap()))
}

///|
test "raw HTTP method framing and force SSL" {
  let raw = (
    #|PATCH /a?id=1 HTTP/1.1
    #|Host: example.test:8080
    #|Content-Length: 999
    #|Connection: close
    #|Content-Type: application/json
    #|Authorization: Bearer sample
    #|
    #|{"id":2}
  ).replace_all(old="\n", new="\r\n")
  let t = @parse.raw_request(
    raw,
    { ..@core.Options::default(), force_ssl: true, },
    source="input.http",
  )
  assert_eq(t.request.http_method, "PATCH")
  assert_eq(t.request.url, "https://example.test:8080/a?id=1")
  assert_eq(t.request.headers.length(), 2)
  assert_eq(t.source.kind, "request_file")
  assert_eq(@parse.select_template(t, []).length(), 2)
  for
    invalid in [
      (
        #|GET / HTTP/2
        #|Host: example.test
        #|
        #|
      ),
      (
        #|GET / HTTP/1.1
        #|Host: a
        #|Host: b
        #|
        #|
      ),
      (
        #|POST / HTTP/1.1
        #|Host: a
        #|Transfer-Encoding: chunked
        #|
        #|0
      ),
    ] {
    try @parse.raw_request(invalid, @core.Options::default()) catch {
      ConfigError(_) => ()
    } noraise {
      _ => fail("ambiguous raw request accepted")
    }
  }
}

///|
test "advanced CLI defaults and mutually exclusive input" {
  guard @parse.cli([
      "-m", "urls.txt", "--threads", "3", "--crawl", "2", "--forms", "--union-cols",
      "2-4", "--technique", "BEUT", "--dbms", "PostgreSQL", "--tables", "-D", "café",
      "--delay", "0.025",
    ])
    is Run(c) else {
    fail("CLI")
  }
  assert_eq(c.input_file, Some("urls.txt"))
  assert_eq(c.options.timeout_ms, 30000)
  assert_eq(c.options.retries, 3)
  assert_eq(c.options.delay_ms, 25)
  assert_eq(c.options.union_max, 4)
  assert_eq(c.options.enumeration.database, Some("café"))
  for
    args in [
      ["-u", "http://a/?id=1", "-m", "file"],
      ["-m", "a", "-r", "b"],
      ["-u", "http://a/?id=1", "--threads", "0"],
      ["-u", "http://a/?id=1", "--regexp", "["],
      ["-u", "http://a/?id=1", "--columns"],
      ["-u", "http://a/?id=1", "--union-cols", "4-2"],
    ] {
    try @parse.cli(args) catch {
      ConfigError(_) => ()
    } noraise {
      _ => fail("invalid CLI accepted")
    }
  }
}

///|
test "frozen dynamic masks and explicit comparison rules" {
  let samples = [1, 2, 3, 4, 5].map(n => {
    (
      {
        status: 200,
        body: (
          $|A stable page with sufficient fixed words and meaningful body content counter=\{n} end
        ),
      } : @core.Response)
  })
  assert_true(
    @generic.comparator(samples[:3].to_owned(), @core.ComparisonRule::default())
    is None,
  )
  guard @generic.comparator(samples, @core.ComparisonRule::default())
    is Some(compare) else {
    fail("mask")
  }
  assert_true(
    compare(samples[0], {
      status: 200,
      body: (
        #|A stable page with sufficient fixed words and meaningful body content counter=99 end
      ),
    }),
  )
  assert_false(
    compare(samples[0], {
      status: 200,
      body: (
        #|A stable page with sufficient fixed words and meaningful body changed counter=99 end
      ),
    }),
  )
  for
    rule in [
      { ..@core.ComparisonRule::default(), string: Some("accepted"), },
      { ..@core.ComparisonRule::default(), not_string: Some("rejected"), },
      { ..@core.ComparisonRule::default(), regexp: Some("accept[a-z]+"), },
    ] {
    let baseline : @core.Response = { status: 200, body: "accepted", }
    guard @generic.comparator([baseline, baseline, baseline], rule)
      is Some(compare) else {
      fail("predicate")
    }
    assert_false(compare(baseline, { status: 200, body: "rejected", }))
  }
  let rule = { ..@core.ComparisonRule::default(), titles: true, }
  assert_eq(
    @generic.comparison_text(
      (
        #|<title>Hello</title><p>noise</p>
      ),
      rule,
    ),
    "Hello",
  )
  assert_eq(
    @generic.comparison_text(
      (
        #|<p>Hello</p><script>bad</script>
      ),
      { ..rule, titles: false, text_only: true, },
    ),
    "Hello",
  )
}

///|
test "explicit JSON numeric marker keeps a numeric baseline" {
  let opts = {
    ..@core.Options::default(),
    data: Some(
      (
        #|{"id":12*,"keep":1e2}
      ),
    ),
  }
  let t = @parse.template("http://a.test/", opts)
  let chosen = @parse.select_template(t, [])
  assert_eq(chosen.length(), 1)
  assert_eq(chosen[0].value, "12")
  assert_eq(
    @parse.render_template(t).body,
    Some(
      (
        #|{"id":12,"keep":1e2}
      ),
    ),
  )
  assert_eq(
    @parse.render_template(t, replacement=(chosen[0], "12 AND 7=7")).body,
    Some(
      (
        #|{"id":"12 AND 7=7","keep":1e2}
      ),
    ),
  )
}
