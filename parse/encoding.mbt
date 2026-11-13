///|
fn hex(c : Byte) -> Int32? {
  let n = c.to_int()
  if n >= 48 && n <= 57 {
    Some(n - 48)
  } else if n >= 65 && n <= 70 {
    Some(n - 55)
  } else if n >= 97 && n <= 102 {
    Some(n - 87)
  } else {
    None
  }
}

///|
pub fn decode(value : String) -> String raise @core.ConfigError {
  let bytes = @utf8.encode(value)
  let out = @buffer.Buffer()
  for i = 0; i < bytes.length(); {
    match bytes[i] {
      b'+' => {
        out.write_byte(b' ')
        continue i + 1
      }
      b'%' => {
        guard i + 2 < bytes.length() else {
          raise ConfigError("Incomplete percent encoding")
        }
        guard hex(bytes[i + 1]) is Some(a) && hex(bytes[i + 2]) is Some(b) else {
          raise ConfigError("Invalid percent encoding")
        }
        out.write_byte((a * 16 + b).to_byte())
        continue i + 3
      }
      c => {
        out.write_byte(c)
        continue i + 1
      }
    }
  }
  @utf8.decode(out.to_bytes()) catch {
    _ => raise ConfigError("Parameter is not valid UTF-8")
  }
}

///|
pub fn encode(value : String) -> String {
  let out = StringBuilder()
  for c in @utf8.encode(value) {
    let n = c.to_int()
    if (n >= 65 && n <= 90) ||
      (n >= 97 && n <= 122) ||
      (n >= 48 && n <= 57) ||
      c == b'-' ||
      c == b'_' ||
      c == b'.' ||
      c == b'~' {
      out.write_char(n.to_char().unwrap())
    } else {
      out.write_char('%')
      out.write_char("0123456789ABCDEF"[n / 16].to_int().to_char().unwrap())
      out.write_char("0123456789ABCDEF"[n % 16].to_int().to_char().unwrap())
    }
  }
  out.to_string()
}

///|
pub fn parameters(
  raw : String,
  location : @core.Location,
) -> Array[@core.Parameter] raise @core.ConfigError {
  if raw.is_empty() {
    return []
  }
  let result : Array[@core.Parameter] = []
  for segment in raw.split("&") {
    let (name, value) = match segment.split_once("=") {
      Some((name, value)) => (name.to_owned(), value.to_owned())
      None => (segment.to_owned(), "")
    }
    result.push({
      location,
      index: result.length(),
      name: decode(name),
      value: decode(value),
      raw: segment.to_owned(),
    })
  }
  result
}
