///|
fn read_enumeration_cache(
  store : &@core.SessionStore,
  key : String,
) -> @core.EnumerationResult? raise {
  // SessionStore implementations may raise arbitrary errors; cache reads are optional.
  let raw = store.get(key) catch { _ => return None }
  raw.map(raw => @json.from_json(@json.parse(raw))) catch {
    @json.ParseError::_ | @json.JsonDecodeError::_ => None
    err => raise err
  }
}

///|
fn write_enumeration_cache(
  ctx : @core.ScanContext,
  store : &@core.SessionStore,
  key : String,
  value : @core.EnumerationResult,
  message : String,
) -> Unit {
  // Storage failures are nonfatal, including errors from custom implementations.
  store.put(key, value.to_json().stringify()) catch {
    err => issue(ctx, "session", "\{message}: \{err}", fatal=false)
  }
}
