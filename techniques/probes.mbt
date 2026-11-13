///|
priv struct BooleanProbe {
  context : String
  true_first : String
  false_first : String
  true_second : String
  false_second : String
}

///|
fn boolean_probes(value : String) -> Array[BooleanProbe] {
  [
    {
      context: "numeric",
      true_first: value + " AND 7=7",
      false_first: value + " AND 7=8",
      true_second: value + " AND 9=9",
      false_second: value + " AND 9=10",
    },
    {
      context: "single-quoted",
      true_first: value + "' AND '7'='7",
      false_first: value + "' AND '7'='8",
      true_second: value + "' AND '9'='9",
      false_second: value + "' AND '9'='10",
    },
  ]
}

///|
fn error_probes(value : String) -> Array[String] {
  [value + "'", value + "\""]
}
