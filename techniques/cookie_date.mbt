///|
fn cookie_date(raw : String) -> Int64? {
  let parts = raw
    .split(" ")
    .filter(s => !s.is_empty())
    .map(s => s.to_owned())
    .to_array()
  if parts.length() != 6 || parts[5].to_upper() != "GMT" {
    return None
  }
  let months = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov",
    "dec",
  ]
  let month = months.search(parts[2].to_lower()).map(i => i + 1)
  guard month is Some(month) else { return None }
  let day = @string.parse_int(parts[1]) catch { _ => return None }
  let year = @string.parse_int(parts[3]) catch { _ => return None }
  let date = @time.PlainDate::of(year, month, day) catch { _ => return None }
  let hms = parts[4].split(":").to_array()
  if hms.length() != 3 {
    return None
  }
  let hour = @string.parse_int(hms[0]) catch { _ => return None }
  let minute = @string.parse_int(hms[1]) catch { _ => return None }
  let second = @string.parse_int(hms[2]) catch { _ => return None }
  if hour < 0 ||
    hour > 23 ||
    minute < 0 ||
    minute > 59 ||
    second < 0 ||
    second > 59 {
    return None
  }
  Some(
    date.to_unix_day() * 86400000 +
    ((hour * 60 + minute) * 60 + second).to_int64() * 1000,
  )
}
