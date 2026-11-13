///|
/// Extend this registry to add a strategy at compile time.
pub fn registered() -> Array[
  (
    @core.Technique,
    async (@core.ScanContext, @core.Parameter, @core.Response) -> Unit,
  ),
] {
  [
    (ErrorBased, detect_errors),
    (BooleanBased, detect_boolean),
    (UnionBased, detect_union),
    (TimeBased, detect_time),
  ]
}
