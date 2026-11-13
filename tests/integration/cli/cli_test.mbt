///|
#cfg(target="native")
fn cli_command() -> (String, Array[String]) {
  (
    @env.get_env_var("SQLMAP_NATIVE_BIN").unwrap_or(
      "../../_build/native/debug/build/sqlmap.exe",
    ),
    [],
  )
}

///|
#cfg(target="wasm")
fn cli_command() -> (String, Array[String]) {
  (
    "moonrun",
    [
      @env.get_env_var("SQLMAP_WASM_BIN").unwrap_or(
        "../../_build/wasm/debug/build/sqlmap.wasm",
      ),
      "--",
    ],
  )
}

///|
async fn run_cli(args : Array[String]) -> @process.ProcessResult {
  let (program, prefix) = cli_command()
  prefix.append(args)
  @process.run(program, prefix, stdout=Collect, stderr=Collect)
}

///|
async test "CLI positive negative and incomplete exit codes with clean JSON stdout" {
  @support.with_fixture() <| fixture => {
    let dir = @fs.tmpdir(prefix="sqlmap-cli-codes-")
    defer @fs.rmdir(dir, recursive=true)
    for
      (path, expected) in [
        ("/numeric?id=1", 1),
        ("/safe?id=1", 0),
        ("/dynamic?id=1", 2),
      ] {
      let result = run_cli([
        "-u",
        fixture.url() + path,
        "--format",
        "json",
        "--output-dir",
        dir,
      ])
      assert_eq(result.exit_code, expected, msg=result.stderr_text())
      let report = @json.parse(result.stdout_text())
      guard report is { "exit_code": Number(code, ..), .. } else {
        fail("missing JSON exit_code")
      }
      assert_eq(code.to_int(), expected)
      assert_true(result.stderr_text().contains("Starting scan"))
    }
  }
}

///|
async test "CLI output file contains the report and stdout stays empty" {
  @support.with_fixture() <| fixture => {
    let dir = @fs.tmpdir(prefix="sqlmap-cli-")
    defer @fs.rmdir(dir, recursive=true)
    let path = dir + "/report.json"
    let result = run_cli([
      "-u",
      fixture.url() + "/safe?id=1",
      "--format",
      "json",
      "--output",
      path,
      "--output-dir",
      dir,
    ])
    assert_eq(result.exit_code, 0, msg=result.stderr_text())
    assert_eq(result.stdout_text(), "")
    guard @json.parse(@fs.read_text(path)) is { "verdict": "not_detected", .. } else {
      fail("wrong report file")
    }
  }
}

///|
async test "CLI configuration errors use stderr and exit 2" {
  let result = run_cli(["-u", "ftp://invalid/?id=1", "--format", "json"])
  assert_eq(result.exit_code, 2)
  assert_eq(result.stdout_text(), "")
  assert_true(result.stderr_text().contains("Configuration error"))
}

///|
async test "CLI URL file mixed results and raw HTTP request file" {
  @support.with_fixture() <| fixture => {
    let dir = @fs.tmpdir(prefix="sqlmap-input-")
    defer @fs.rmdir(dir, recursive=true)
    let list = dir + "/urls.txt"
    @fs.write_text(
      list,
      (
        $|# targets
        $|\{fixture.url()}/numeric?id=1
        $|\{fixture.url()}/safe?id=1
        $|ftp://invalid/?id=1
        $|
      ),
    )
    let mixed = run_cli([
      "-m", list, "--technique", "B", "--format", "json", "--output-dir", dir,
    ])
    assert_eq(mixed.exit_code, 2)
    guard @json.parse(mixed.stdout_text())
      is {
        "schema_version": 2,
        "complete": false,
        "reports": Array(reports),
        ..
      } else {
      fail("batch report")
    }
    assert_eq(reports.length(), 3)
    assert_true(reports.any(r => r is { "exit_code": 1, .. }))
    assert_true(reports.any(r => r is { "exit_code": 0, .. }))
    let request_file = dir + "/request.http"
    let host = fixture.url()[7:].to_owned()
    @fs.write_text(
      request_file,
      (
        $|GET /numeric?id=1 HTTP/1.1
        $|Host: \{host}
        $|Connection: close
        $|Content-Length: 999
        $|
        $|
      ).replace_all(old="\n", new="\r\n"),
    )
    let raw = run_cli([
      "-r", request_file, "--technique", "B", "--format", "json", "--output-dir",
      dir,
    ])
    assert_eq(raw.exit_code, 1)
    guard @json.parse(raw.stdout_text())
      is { "reports": [{ "source": { "kind": "request_file", .. }, .. }], .. } else {
      fail("request provenance")
    }
  }
}
