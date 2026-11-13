///|
async test "HTTP redirects stop before lost baseline inputs or rewritten probes reach the destination" {
  @support.with_fixture() <| fixture => {
    for (route, tested, requests) in [("/private", 0, 1), ("/rewrite", 1, 7)] {
      let before = fixture.requests
      let report = @controller.scan(
        fixture.url() + route + "?id=1",
        { ..@core.Options::default(), techniques: [ErrorBased], },
        @request.HttpTransport::{ },
      )
      assert_eq(report.exit_code(), 2)
      assert_eq(report.verdict, Inconclusive)
      assert_false(report.complete)
      assert_eq(report.tested_parameters, tested)
      assert_eq(report.issues[0].phase, "redirect-coverage")
      assert_eq(report.issues[0].parameter, Some("id"))
      assert_eq(report.requests.attempted, requests)
      assert_eq(fixture.requests - before, requests)
    }
    assert_false(fixture.paths.any(p => p.has_prefix("/login")))
    assert_eq(fixture.paths.filter(p => p.has_prefix("/numeric")).length(), 3)
  }
}

///|
async test "HTTP POST redirect keeps 307 and 308 bodies and refuses a 302 body loss" {
  @support.with_fixture() <| fixture => {
    for status in [302, 307, 308] {
      let before = fixture.requests
      let report = @controller.scan(
        fixture.url() + "/post-\{status}",
        {
          ..@core.Options::default(),
          techniques: [ErrorBased],
          data: Some("id=1"),
        },
        @request.HttpTransport::{ },
      )
      assert_eq(report.requests.attempted, fixture.requests - before)
      if status == 302 {
        assert_eq(report.exit_code(), 2)
        assert_eq(report.tested_parameters, 0)
        assert_eq(fixture.requests - before, 1)
        assert_eq(report.issues[0].phase, "redirect-coverage")
      } else {
        assert_eq(report.exit_code(), 1)
        assert_eq(report.findings[0].location, Form)
        for i in 0..<(report.requests.attempted / 2) {
          assert_eq(
            fixture.bodies[before + 2 * i],
            fixture.bodies[before + 2 * i + 1],
          )
        }
      }
    }
  }
}

///|
async test "HTTP crawl follows discovery redirects and counts unique final pages within the cap" {
  @support.with_fixture() <| fixture => {
    let opts = {
      ..@core.Options::default(),
      techniques: [ErrorBased],
      crawl: 3,
      crawl_max_pages: 2,
    }
    let batch = @controller.scan_batch(
      [@parse.template(fixture.url() + "/root", opts)],
      opts,
      @request.HttpTransport::{ },
    )
    assert_eq(batch.exit_code(), 0)
    assert_eq(batch.reports.length(), 2)
    assert_eq(batch.reports[0].source.kind, "discovery")
    assert_eq(batch.reports[0].requests.attempted, 3)
    assert_eq(batch.reports[0].tested_parameters, 0)
    assert_eq(batch.reports[1].target, fixture.url() + "/second?id=1")
    assert_eq(batch.reports[1].tested_parameters, 1)
    assert_eq(fixture.paths.filter(p => p == "/login").length(), 1)
    assert_eq(fixture.paths.filter(p => p == "/root").length(), 1)
    assert_eq(
      fixture.requests,
      batch.reports.fold(init=0, (n, r) => n + r.requests.attempted),
    )
  }
}
