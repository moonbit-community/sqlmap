///|
async test "CLI empty discovery and disabled POST forms produce incomplete JSON and text" {
  @support.with_fixture() <| fixture => {
    let dir = @fs.tmpdir(prefix="sqlmap-empty-")
    defer @fs.rmdir(dir, recursive=true)
    for path in ["/empty", "/post-only"] {
      let before = fixture.requests
      let result = run_cli([
        "-u",
        fixture.url() + path,
        "--crawl",
        "1",
        "--technique",
        "E",
        "--format",
        "json",
        "--output-dir",
        dir,
      ])
      assert_eq(result.exit_code, 2)
      guard @json.parse(result.stdout_text())
        is {
          "schema_version": 2,
          "complete": false,
          "exit_code": 2,
          "reports": [
            {
              "verdict": "inconclusive",
              "complete": false,
              "tested_parameters": 0,
              "issues": [
                {
                  "phase": "discovery-empty",
                  "message": "No testable parameters found; injection testing was not performed",
                  ..
                },
              ],
              "requests": { "attempted": 1, "succeeded": 1, .. },
              ..
            },
          ],
          ..
        } else {
        fail("expected explicit empty discovery report")
      }
      assert_eq(fixture.requests - before, 1)
    }
    let text = run_cli([
      "-u",
      fixture.url() + "/empty",
      "--forms",
      "--output-dir",
      dir,
    ])
    assert_eq(text.exit_code, 2)
    assert_true(
      text
      .stdout_text()
      .contains(
        "No testable parameters found; injection testing was not performed",
      ),
    )
    assert_true(text.stdout_text().contains("Verdict: inconclusive"))
  }
}

///|
async test "CLI mixed discovery batch continues scanning targets with parameters" {
  @support.with_fixture() <| fixture => {
    let dir = @fs.tmpdir(prefix="sqlmap-mixed-discovery-")
    defer @fs.rmdir(dir, recursive=true)
    let path = dir + "/urls.txt"
    @fs.write_text(
      path,
      (
        $|\{fixture.url()}/empty
        $|\{fixture.url()}/safe?id=1
        $|
      ),
    )
    let result = run_cli([
      "-m", path, "--crawl", "1", "--technique", "E", "--format", "json", "--output-dir",
      dir,
    ])
    assert_eq(result.exit_code, 2)
    guard @json.parse(result.stdout_text())
      is {
        "complete": false,
        "reports": [
          { "issues": [{ "phase": "discovery-empty", .. }], .. },
          { "complete": true, "tested_parameters": 0, .. },
          { "complete": true, "tested_parameters": 1, "exit_code": 0, .. },
        ],
        "requests": { "attempted": Number(attempted, ..), .. },
        ..
      } else {
      fail("expected mixed discovery and completed scan")
    }
    assert_eq(attempted.to_int(), fixture.requests)
  }
}

///|
async test "CLI lost redirect coverage has exit 2 and preserves accurate tested counts" {
  @support.with_fixture() <| fixture => {
    let dir = @fs.tmpdir(prefix="sqlmap-redirect-coverage-")
    defer @fs.rmdir(dir, recursive=true)
    for
      (path, expected_tested, expected_requests) in [
        ("/private?id=1", 0, 1),
        ("/rewrite?id=1", 1, 7),
      ] {
      let before = fixture.requests
      let result = run_cli([
        "-u",
        fixture.url() + path,
        "--technique",
        "E",
        "--format",
        "json",
        "--output-dir",
        dir,
      ])
      assert_eq(result.exit_code, 2)
      guard @json.parse(result.stdout_text())
        is {
          "schema_version": 2,
          "complete": false,
          "verdict": "inconclusive",
          "tested_parameters": Number(tested, ..),
          "requests": { "attempted": Number(attempted, ..), .. },
          "issues": [
            {
              "phase": "redirect-coverage",
              "parameter": "id",
              "location": "query",
              ..
            },
          ],
          ..
        } else {
        fail("expected redirect coverage issue")
      }
      assert_eq(tested.to_int(), expected_tested)
      assert_eq(attempted.to_int(), expected_requests)
      assert_eq(fixture.requests - before, expected_requests)
    }
  }
}
