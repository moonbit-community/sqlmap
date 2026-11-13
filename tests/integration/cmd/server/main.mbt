///|
async fn main {
  let fixture = @support.Fixture::start()
  defer fixture.close()
  @stdio.stdout.text.write("\{fixture.url()}\n")
  fixture.serve()
}
