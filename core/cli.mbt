///|
#derive(Debug, Eq)
pub(all) enum Format {
  Text
  Json
}

///|
#derive(Debug, Eq)
pub(all) struct CliConfig {
  url : String
  input_file : String?
  raw_file : Bool
  options : Options
  format : Format
  output : String?
}

///|
#derive(Debug, Eq)
pub(all) enum CliAction {
  Help
  Run(CliConfig)
}
