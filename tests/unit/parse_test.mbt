///|
test "UTF-8 percent encoding, plus, empty values and invalid input" {
  for value in ["café", "™", "", "a+b c&=/?#", "😀", "\u{0000}"] {
    assert_eq(@parse.decode(@parse.encode(value)), value)
  }
  assert_eq(@parse.encode("café space"), "caf%C3%A9%20space")
  assert_eq(@parse.decode("a+b%2bc"), "a b+c")
  for invalid in ["%", "%0", "%GG", "%FF", "%C0%AF"] {
    try @parse.decode(invalid) catch {
      ConfigError(_) => ()
    } noraise {
      _ => fail("expected invalid encoding: \{invalid}")
    }
  }
}

///|
test "duplicate parameters preserve raw encoding and occurrence order" {
  let target = @parse.target(
    (
      #|https://example.test/a?id=1&id=2&bare&empty=&x=a+b&&z=%c3%a9#anchor
    ),
    data="id=3&id=4",
  )
  assert_eq(target.query.length(), 7)
  assert_eq(target.query[2].value, "")
  assert_eq(target.query[4].value, "a b")
  assert_eq(target.query[6].value, "é")
  let opts = { ..@core.Options::default(), data: Some("id=3&id=4"), }
  let original = @parse.request(target, opts)
  assert_eq(
    original.url,
    (
      #|https://example.test/a?id=1&id=2&bare&empty=&x=a+b&&z=%c3%a9
    ),
  )
  assert_eq(original.body, Some("id=3&id=4"))
  let changed = @parse.request(
    target,
    opts,
    replacement=(target.query[1], "é& 2"),
  )
  assert_eq(
    changed.url,
    (
      #|https://example.test/a?id=1&id=%C3%A9%26%202&bare&empty=&x=a+b&&z=%c3%a9
    ),
  )
  assert_eq(changed.body, original.body)
  let form = target.form.unwrap()
  let posted = @parse.request(target, opts, replacement=(form[1], "4'"))
  assert_eq(posted.url, original.url)
  assert_eq(posted.body, Some("id=3&id=4%27"))
  assert_eq(posted.http_method, "POST")
}

///|
test "parameter selection supports location and selects every duplicate" {
  let target = @parse.target(
    "http://localhost/?id=1&id=2&x=",
    data="id=3&name=alice",
  )
  assert_eq(@parse.selected(target, []).length(), 5)
  assert_eq(@parse.selected(target, ["id"]).length(), 3)
  let selected = @parse.selected(target, ["query:id", "name"])
  assert_eq(selected.length(), 3)
  assert_eq(selected[2].location, Form)
  try @parse.selected(target, ["missing"]) catch {
    ConfigError(_) => ()
  } noraise {
    _ => fail("unknown parameter must fail")
  }
  let colon_names = @parse.target(
    "http://localhost/?id=1&query:id=2",
    data="query:id=3",
  )
  assert_eq(@parse.selected(colon_names, ["query:id"]).length(), 1)
  assert_eq(@parse.selected(colon_names, ["query:query:id"])[0].value, "2")
  assert_eq(@parse.selected(colon_names, ["form:query:id"])[0].value, "3")
}

///|
test "URL validation and empty form still use POST" {
  for
    invalid in [
      "ftp://host/x?a=1", "http:///a?x=1", "http://user@host/?a=1", "http://host:0/?x=1",
      "http://host:65536/?x=1", "http://host/a\r\nX:1", "http://host:abc/?x=1", "http://[::1/?x=1",
    ] {
    try @parse.target(invalid) catch {
      ConfigError(_) => ()
    } noraise {
      _ => fail("expected invalid URL: \{invalid}")
    }
  }
  let target = @parse.target("http://[::1]:8080/?id=1", data="")
  let req = @parse.request(target, {
    ..@core.Options::default(),
    data: Some(""),
  })
  assert_eq(req.http_method, "POST")
  assert_eq(req.body, Some(""))
  for url in ["http://localhost?id=1", "http://localhost?id=a/b"] {
    let parsed = @parse.target(url)
    assert_eq(parsed.base, "http://localhost/")
    assert_true(
      @parse.request(parsed, @core.Options::default()).url.has_prefix(
        "http://localhost/?",
      ),
    )
  }
}

///|
test "CLI parses repeated headers, cookie, fractional timeout and technique" {
  let action = @parse.cli([
    "-u", "https://example.test/?id=1", "--data", "id=2&name=café", "-H", "X-Test: one",
    "--header=X-Test: two", "--cookie", "sid=xyz", "-p", "form:id,name", "--technique",
    "B", "--timeout", "0.025", "--format", "json", "--output", "out.json",
  ])
  guard action is Run(config) else { fail("expected configuration") }
  assert_eq(config.options.timeout_ms, 25)
  assert_eq(config.options.headers.length(), 2)
  assert_eq(config.options.techniques, [BooleanBased])
  assert_eq(config.options.cookie, Some("sid=xyz"))
  assert_eq(config.format, Json)
  assert_eq(config.output, Some("out.json"))
}

///|
test "CLI rejects invalid headers, content types, selection and flags" {
  let base = ["-u", "http://example.test/?id=1"]
  for
    extra in [
      ["--timeout", "NaN"],
      ["--timeout", "0"],
      ["--timeout", "1e99"],
      ["--format", "xml"],
      ["--technique", "S"],
      ["-p", "missing"],
      ["-H", "X: a\r\nY: b"],
      ["-H", "Host: other.test"],
      ["-H", "Content-Length: 100"],
      ["-H", "bad name: a"],
      ["--data", "id=1", "-H", "Content-Type: application/json"],
      ["--cookie", "a=1\nX: y"],
      ["--unknown"],
      ["--output"],
    ] {
    let args = base.copy()
    args.append(extra)
    try @parse.cli(args) catch {
      ConfigError(_) => ()
    } noraise {
      _ => fail("expected invalid configuration: \{Repr(extra)}")
    }
  }
  assert_eq(@parse.cli(["--help"]), Help)
}
