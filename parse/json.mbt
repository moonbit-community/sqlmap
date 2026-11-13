///|
priv struct JsonScanner {
  input : String
  mut pos : Int32
  slots : Array[@core.ParameterSlot]
}

///|
fn JsonScanner::space(self : JsonScanner) -> Unit {
  while self.pos < self.input.length() &&
        (
          self.input[self.pos] == ' ' ||
          self.input[self.pos] == '\t' ||
          self.input[self.pos] == '\n' ||
          self.input[self.pos] == '\r'
        ) {
    self.pos += 1
  }
}

///|
fn JsonScanner::quoted(self : JsonScanner) -> String {
  let start = self.pos
  self.pos += 1
  while self.pos < self.input.length() {
    if self.input[self.pos] == '\\' {
      self.pos += 2
    } else if self.input[self.pos] == '"' {
      self.pos += 1
      break
    } else {
      self.pos += 1
    }
  }
  self.input[start:self.pos].to_owned()
}

///|
fn JsonScanner::value(self : JsonScanner, path : String) -> Unit {
  self.space()
  let start = self.pos
  match self.input[self.pos] {
    '{' => {
      self.pos += 1
      self.space()
      while self.input[self.pos] != '}' {
        let key = match (try! @json.parse(self.quoted())) {
          String(s) => s
          _ => ""
        }
        self.space()
        self.pos += 1
        self.value(
          path + "/" + key.replace(old="~", new="~0").replace(old="/", new="~1"),
        )
        self.space()
        if self.input[self.pos] != ',' {
          break
        }
        self.pos += 1
        self.space()
      }
      self.pos += 1
    }
    '[' => {
      self.pos += 1
      self.space()
      let mut index = 0
      while self.input[self.pos] != ']' {
        self.value(path + "/\{index}")
        index += 1
        self.space()
        if self.input[self.pos] != ',' {
          break
        }
        self.pos += 1
        self.space()
      }
      self.pos += 1
    }
    _ => {
      let string = self.input[self.pos] == '"'
      if string {
        ignore(self.quoted())
      } else {
        while self.pos < self.input.length() &&
              !([',', ']', '}', ' ', '\t', '\r', '\n'] : Array[UInt16]).contains(
                self.input[self.pos],
              ) {
          self.pos += 1
        }
      }
      let raw = self.input[start:self.pos].to_owned()
      let value = match
        (try! @json.parse(
          if string {
            raw
          } else {
            raw.replace(old="*", new="")
          },
        )) {
        String(s) => s
        Number(_) => raw.replace(old="*", new="")
        _ => return
      }
      self.slots.push({
        parameter: {
          location: JsonBody,
          index: self.slots
          .filter(s => s.parameter.location == JsonBody)
          .length(),
          name: path,
          value,
          raw,
        },
        part: BodyPart,
        start,
        end: self.pos,
        encoding: if string {
          JsonString
        } else {
          JsonNumber
        },
        marked: false,
      })
    }
  }
}

///|
fn json_slots(
  body : String,
  slots : Array[@core.ParameterSlot],
) -> Unit raise @core.ConfigError {
  ignore(
    @json.parse(strip_number_markers(body)) catch {
      _ => raise ConfigError("Invalid JSON request body")
    },
  )
  let scanner = JsonScanner::{ input: body, pos: 0, slots, }
  scanner.value("")
}

///|
fn strip_number_markers(body : String) -> String {
  let out = StringBuilder()
  let mut quoted = false
  let mut escaped = false
  for c in body {
    if quoted {
      out.write_char(c)
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        quoted = false
      }
    } else if c == '"' {
      quoted = true
      out.write_char(c)
    } else if c != '*' {
      out.write_char(c)
    }
  }
  out.to_string()
}
