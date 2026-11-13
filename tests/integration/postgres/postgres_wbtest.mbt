///|
async test "PostgreSQL real HTTP UNION and boolean metadata" {
  with_postgres() <| fixture => {
    for
      (route, kind) in [
        ("/union", @core.UnionBased),
        ("/boolean", BooleanBased),
      ] {
      let opts = {
        ..@core.Options::default(),
        techniques: [kind],
        dbms: PostgreSQL,
        union_min: 1,
        union_max: 1,
        enumeration: {
          ..@core.EnumerationOptions::default(),
          banner: true,
          current_db: true,
          dbs: true,
          tables: true,
          columns: true,
          database: Some("sqlmap_v02"),
          table: Some("users_résumés"),
        },
      }
      let report = @controller.scan(fixture.url() + route + "?id=1", opts, @request.HttpTransport::{
      })
      assert_true(report.complete, msg=@report.text(report))
      assert_eq(report.database, PostgreSQL)
      assert_true(report.enumeration[0].values[0].contains("PostgreSQL"))
      assert_eq(report.enumeration[1].values, ["sqlmap_v02"])
      assert_true(report.enumeration[2].values.contains("sqlmap_v02"))
      assert_eq(report.enumeration[3].values, ["users", "users_résumés"])
      assert_eq(report.enumeration[4].values, ["résumé_id", "na\"me"])
    }
    let empty_opts = {
      ..@core.Options::default(),
      techniques: [UnionBased],
      dbms: PostgreSQL,
      union_max: 1,
      enumeration: {
        ..@core.EnumerationOptions::default(),
        tables: true,
        database: Some("missing' OR 1=1 --"),
      },
    }
    let empty = @controller.scan(fixture.url() + "/union?id=1", empty_opts, @request.HttpTransport::{
    })
    assert_true(empty.complete, msg=@report.text(empty))
    assert_eq(empty.enumeration[0].values, [])
  }
}

///|
async test "PostgreSQL real delay and safe query negatives" {
  with_postgres() <| fixture => {
    let opts = {
      ..@core.Options::default(),
      techniques: [TimeBased],
      dbms: PostgreSQL,
      time_sec: 1,
    }
    let positive = @controller.scan(fixture.url() + "/union?id=1", opts, @request.HttpTransport::{
    })
    assert_eq(positive.exit_code(), 1)
    assert_eq(positive.findings[0].technique, TimeBased)
    for path in ["/safe?id=1", "/reflect?id=1"] {
      let safe = @controller.scan(
        fixture.url() + path,
        {
          ..opts,
          techniques: [BooleanBased, ErrorBased, UnionBased],
          union_max: 1,
        },
        @request.HttpTransport::{ },
      )
      assert_eq(safe.exit_code(), 0, msg=@report.text(safe))
    }
    let hidden = @controller.scan(
      fixture.url() + "/hidden?id=1",
      { ..opts, techniques: [BooleanBased], },
      @request.HttpTransport::{ },
    )
    assert_eq(hidden.exit_code(), 1)
  }
}
