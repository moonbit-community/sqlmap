///|
/// Bounded target workers. A per-origin lock excludes other requests during timing probes.
pub async fn scan_batch(
  templates : Array[@core.RequestTemplate],
  options : @core.Options,
  transport : &@core.Transport,
  clock~ : &@core.Clock = @core.SystemClock::{ },
  session? : &@core.SessionStore,
) -> @core.BatchReport {
  @parse.validate(options) catch {
    ConfigError(message) => {
      let reports = if templates.is_empty() {
        [configuration_error("", message)]
      } else {
        templates.map(t => {
          configuration_error(t.request.url, message, source=t.source)
        })
      }
      return { reports, complete: false, }
    }
  }
  let started = clock.now_ms()
  let locks : Map[String, @async.Mutex] = Map([])
  for t in templates {
    locks[@parse.origin(t.request.url)] = Mutex()
  }
  let tasks = templates.map(seed => {
    async fn() {
      let lock = locks[@parse.origin(seed.request.url)]
      lock.acquire()
      defer lock.release()
      let remaining = options.time_limit_ms.map(limit => {
        limit.to_int64() - (clock.now_ms() - started)
      })
      if remaining.map(n => n <= 0).unwrap_or(false) {
        return [
          configuration_error(
            seed.request.url,
            "Batch runtime limit reached before the target started",
            source=seed.source,
          ),
        ]
      }
      let opts = { ..options, time_limit_ms: remaining.map(n => n.to_int()), }
      let (targets, discovery) = discover(seed, opts, transport, clock, session)
      let reports : Array[@core.ScanReport] = []
      if discovery is Some(r) {
        reports.push(r)
      }
      for target in targets {
        let remaining = options.time_limit_ms.map(limit => {
          limit.to_int64() - (clock.now_ms() - started)
        })
        if remaining.map(n => n <= 0).unwrap_or(false) {
          reports.push(
            configuration_error(
              target.request.url,
              "Batch runtime limit reached before the target completed",
              source=target.source,
            ),
          )
          continue
        }
        reports.push(
          scan_template(
            target,
            { ..options, time_limit_ms: remaining.map(n => n.to_int()), },
            transport,
            clock~,
            session?,
          ),
        )
      }
      reports
    }
  })
  let groups = @async.all(tasks, max_concurrent=options.threads)
  let reports : Array[@core.ScanReport] = []
  for group in groups {
    reports.append(group)
  }
  { reports, complete: reports.all(r => r.complete), }
}
