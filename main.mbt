///|
let help : String =
  #|Usage: sqlmap (-u URL | -m URL_FILE | -r HTTP_REQUEST_FILE) [options]
  #|  --data DATA           Form or JSON request body; defaults to POST
  #|  -X, --method METHOD   HTTP method; --force-ssl forces HTTPS
  #|  -p NAMES              Parameter names; optional query:/form:/json:/cookie:/header: prefix
  #|  -H, --header K:V      Repeatable request header; --cookie COOKIE
  #|  --technique BEUT      B boolean, E error, U UNION, T PostgreSQL time detection
  #|  --dbms DB             Database dialect hint; --prefix/--suffix context
  #|  --union-cols 1-10     UNION column range; --time-sec 5 detection delay in seconds
  #|  --string/--not-string/--regexp TEXT; --code STATUS; --text-only; --titles
  #|  --timeout 30          Seconds per request; --retries 3 timeout retries
  #|  --threads 1           Batch workers (1-10); targets on the same origin run serially
  #|  --delay 0             Seconds between requests; --time-limit SECONDS runtime limit
  #|  --drop-set-cookie     Ignore response cookies; --ignore-redirects disables redirects
  #|  -f/--fingerprint; -b/--banner; --current-db; --dbs; --tables; --columns
  #|  -D SCHEMA -T TABLE -C COLUMNS Metadata filters; SQLite/PostgreSQL only
  #|  --crawl DEPTH         Same-origin breadth-first crawl; --crawl-exclude REGEXP
  #|  --forms               Test forms; --crawl-max-pages 100 unique final pages per seed
  #|  --output-dir DIR      Defaults to .sqlmap-output; -s FILE overrides the session path
  #|  --fresh-queries       Bypass enumeration cache; --flush-session clears target cache
  #|  --batch               Use default choices (this implementation has no prompts)
  #|  --format text|json    Defaults to text; --output PATH writes the report to a file
  #|  -h, --help            Show help
  #|Exit codes: 0 complete with no findings; 1 findings; 2 configuration error or incomplete task (takes priority).
  #|

///|
async fn run() -> Int32 {
  let action = @parse.cli(@env.args()[1:].to_owned())
  guard action is Run(config) else {
    @stdio.stdout.text.write(help)
    return 0
  }
  let options = config.options
  let templates : Array[@core.RequestTemplate] = []
  let errors : Array[@core.ScanReport] = []
  if config.input_file is Some(path) {
    let content = @fs.read_text(path)
    if config.raw_file {
      templates.push(@parse.raw_request(content, options, source=path))
    } else {
      for index, line in content.split("\n").to_array() {
        let url = line.trim().to_owned()
        if url.is_empty() || url.has_prefix("#") {
          continue
        }
        let source : @core.TargetSource = {
          kind: "url_file",
          origin: path + ":\{index + 1}",
          depth: 0,
        }
        let t = @parse.template(url, options, source~) catch {
          ConfigError(message) => {
            errors.push(@controller.configuration_error(url, message, source~))
            continue
          }
        }
        templates.push(t)
      }
      if templates.is_empty() && errors.is_empty() {
        raise @core.ConfigError("URL file contains no targets")
      }
    }
  } else {
    templates.push(@parse.template(config.url, options))
  }
  let path = if options.session_file is Some(path) {
    path
  } else {
    @fs.mkdir(
      options.output_dir,
      recursive=true,
      allow_exist=true,
      permission=0o700,
    )
    options.output_dir + "/session.sqlite3"
  }
  let session = @session.SqliteSession::open(path)
  defer session.close()
  @stdio.stderr.text.write(
    "Starting scan: \{templates.length()} seeds, up to \{options.threads} target tasks\n",
  )
  let scanned = @controller.scan_batch(
    templates,
    options,
    @request.HttpTransport::{ },
    session~,
  )
  let reports = errors.copy()
  reports.append(scanned.reports)
  let batch : @core.BatchReport = {
    reports,
    complete: reports.all(r => r.complete),
  }
  let output = if config.input_file is None &&
    options.crawl == 0 &&
    !options.forms &&
    reports.length() == 1 {
    @report.render(reports[0], config.format)
  } else {
    @report.render_batch(batch, config.format)
  }
  if config.output is Some(path) {
    @fs.write_text(path, output)
  } else {
    @stdio.stdout.text.write(output)
  }
  batch.exit_code()
}

///|
async fn write_failure(message : String) -> Int32 {
  @stdio.stderr.text.write(message + "\n") catch {
    @os_error.OsError::_ => ()
    err => raise err
  }
  2
}

///|
async fn main {
  let code = run() catch {
    @core.ConfigError(message) =>
      write_failure("Configuration error: \{message}")
    // The CLI boundary converts all remaining execution failures to exit code 2.
    err => write_failure("Execution failed: \{err}")
  }
  @env.exit(code)
}
