///|
#derive(Debug, Eq, ToJson)
pub(all) struct ComparisonRule {
  string : String?
  not_string : String?
  regexp : String?
  code : Int32?
  text_only : Bool
  titles : Bool
}

///|
pub fn ComparisonRule::default() -> ComparisonRule {
  {
    string: None,
    not_string: None,
    regexp: None,
    code: None,
    text_only: false,
    titles: false,
  }
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct EnumerationOptions {
  fingerprint : Bool
  banner : Bool
  current_db : Bool
  dbs : Bool
  tables : Bool
  columns : Bool
  database : String?
  table : String?
  column : String?
}

///|
pub fn EnumerationOptions::default() -> EnumerationOptions {
  {
    fingerprint: false,
    banner: false,
    current_db: false,
    dbs: false,
    tables: false,
    columns: false,
    database: None,
    table: None,
    column: None,
  }
}

///|
pub fn EnumerationOptions::requested(self : EnumerationOptions) -> Bool {
  self.fingerprint ||
  self.banner ||
  self.current_db ||
  self.dbs ||
  self.tables ||
  self.columns
}

///|
#derive(Debug, Eq, ToJson)
pub(all) enum RequestPart {
  UrlPart
  BodyPart
  HeaderPart(Int32)
}

///|
#derive(Debug, Eq, ToJson)
pub(all) enum ValueEncoding {
  PercentEncoded
  JsonString
  JsonNumber
  JsonFragment
  RawValue
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct ParameterSlot {
  parameter : Parameter
  part : RequestPart
  start : Int32
  end : Int32
  encoding : ValueEncoding
  marked : Bool
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct TargetSource {
  kind : String
  origin : String
  depth : Int32
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct RequestTemplate {
  request : Request
  slots : Array[ParameterSlot]
  source : TargetSource
}

///|
#derive(Debug, Eq)
pub(all) struct ResponseCookie {
  name : String
  value : String
  domain : String?
  path : String?
  secure : Bool
  max_age : Int64?
  expires : String?
}

///|
#derive(Debug, Eq)
pub(all) struct Exchange {
  response : Response
  headers : Array[Header]
  cookies : Array[ResponseCookie]
  final_url : String
  elapsed_ms : Int64
}

///|
pub(open) trait Clock {
  fn now_ms(Self) -> Int64
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) struct InjectionPoint {
  location : Location
  index : Int32
  parameter : String
  database : Dbms
  technique : Technique
  prefix : String
  suffix : String
  union_columns : Int32
  union_position : Int32
}

///|
#derive(Debug, Eq, ToJson, FromJson)
pub(all) struct EnumerationResult {
  kind : String
  database : String?
  table : String?
  values : Array[String]
  complete : Bool
  cached : Bool
  message : String?
}

///|
#derive(Debug, Eq, ToJson)
pub(all) struct DatabaseCapabilities {
  database : Dbms
  techniques : Array[Technique]
  metadata : Array[String]
}

///|
pub fn capabilities(db : Dbms) -> DatabaseCapabilities {
  match db {
    SQLite =>
      {
        database: db,
        techniques: [BooleanBased, ErrorBased, UnionBased],
        metadata: ["banner", "tables", "columns"],
      }
    PostgreSQL =>
      {
        database: db,
        techniques: [BooleanBased, ErrorBased, UnionBased, TimeBased],
        metadata: ["banner", "current_db", "dbs", "tables", "columns"],
      }
    _ => { database: db, techniques: [BooleanBased, ErrorBased], metadata: [], }
  }
}

///|
pub(open) trait SessionStore {
  fn get(Self, String) -> String? raise
  fn put(Self, String, String) -> Unit raise
  fn remove_prefix(Self, String) -> Unit raise
}
