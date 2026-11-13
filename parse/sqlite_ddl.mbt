///|
/// Parse column names from sqlite_schema DDL when table-valued PRAGMAs are unavailable.
/// Honor SQL quotes, comments and nested expressions; reject incomplete input.
pub fn sqlite_columns(sql : String) -> Array[String]? {
  let sql = sql.iter().to_array()
  let pieces : Array[String] = []
  let current = StringBuilder()
  let mut depth = 0
  let mut quote : Char = '\u{0000}'
  let mut i = 0
  let mut opened = false
  while i < sql.length() {
    let c = sql[i]
    if quote != '\u{0000}' {
      if depth > 0 {
        current.write_char(c.to_int().unsafe_to_char())
      }
      if c == quote {
        if i + 1 < sql.length() && sql[i + 1] == quote {
          if depth > 0 {
            current.write_char(c.to_int().unsafe_to_char())
          }
          i += 1
        } else {
          quote = '\u{0000}'
        }
      }
    } else if i + 1 < sql.length() && c == '-' && sql[i + 1] == '-' {
      while i < sql.length() && sql[i] != '\n' {
        i += 1
      }
      current.write_char(' ')
      continue
    } else if i + 1 < sql.length() && c == '/' && sql[i + 1] == '*' {
      i += 2
      while i + 1 < sql.length() && !(sql[i] == '*' && sql[i + 1] == '/') {
        i += 1
      }
      if i + 1 == sql.length() {
        return None
      }
      i += 2
      current.write_char(' ')
      continue
    } else if c == '\'' || c == '"' || c == '`' || c == '[' {
      quote = if c == '[' { ']' } else { c }
      if depth > 0 {
        current.write_char(c.to_int().unsafe_to_char())
      }
    } else if c == '(' {
      depth += 1
      if opened {
        current.write_char('(')
      } else {
        opened = true
      }
    } else if c == ')' {
      depth -= 1
      if depth == 0 {
        pieces.push(current.to_string())
        break
      }
      current.write_char(')')
    } else if depth == 1 && c == ',' {
      pieces.push(current.to_string())
      current.reset()
    } else if depth > 0 {
      current.write_char(c.to_int().unsafe_to_char())
    }
    i += 1
  }
  if !opened || depth != 0 || quote != '\u{0000}' {
    return None
  }
  let names : Array[String] = []
  for piece in pieces {
    let p = piece.trim().to_owned()
    if p.is_empty() {
      return None
    }
    if p[0] == '"' || p[0] == '\'' || p[0] == '`' || p[0] == '[' {
      let chars = p.iter().to_array()
      let closing = if chars[0] == '[' { ']' } else { chars[0] }
      let name = StringBuilder()
      let mut at = 1
      while at < chars.length() {
        if chars[at] == closing {
          if at + 1 < chars.length() && chars[at + 1] == closing {
            name.write_char(closing.to_int().unsafe_to_char())
            at += 2
            continue
          }
          break
        }
        name.write_char(chars[at].to_int().unsafe_to_char())
        at += 1
      }
      names.push(name.to_string())
    } else {
      let end = p
        .find_by(c => c.is_whitespace() || c == '(')
        .unwrap_or(p.length())
      let name = p[:end].to_owned()
      if !["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"].contains(
          name.to_upper(),
        ) {
        names.push(name)
      }
    }
  }
  Some(names)
}
