use std::collections::HashMap;

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    Flag,
    Str,
    Int,
}

#[derive(Clone, Copy)]
pub struct Spec {
    pub long: &'static str,
    pub short: Option<char>,
    pub kind: Kind,
}

pub const fn f(long: &'static str, short: Option<char>) -> Spec {
    Spec { long, short, kind: Kind::Flag }
}

pub const fn s(long: &'static str, short: Option<char>) -> Spec {
    Spec { long, short, kind: Kind::Str }
}

pub const fn i(long: &'static str, short: Option<char>) -> Spec {
    Spec { long, short, kind: Kind::Int }
}

#[derive(Default, Debug)]
pub struct Parsed {
    pub flags: HashMap<String, bool>,
    pub strs: HashMap<String, String>,
    pub ints: HashMap<String, i64>,
    pub rest: Vec<String>,
}

impl Parsed {
    pub fn flag(&self, name: &str) -> bool {
        *self.flags.get(name).unwrap_or(&false)
    }
    pub fn str_of(&self, name: &str) -> Option<&str> {
        self.strs.get(name).map(|v| v.as_str())
    }
    pub fn int_of(&self, name: &str) -> Option<i64> {
        self.ints.get(name).copied()
    }
}

pub fn parse(specs: &[Spec], argv: &[String]) -> Result<Parsed, String> {
    let mut out = Parsed::default();
    let mut i = 0usize;
    while i < argv.len() {
        let arg = argv[i].clone();
        i += 1;
        if arg == "--" {
            while i < argv.len() {
                out.rest.push(argv[i].clone());
                i += 1;
            }
            break;
        }
        if let Some(body) = arg.strip_prefix("--") {
            let (name, inline_val) = match body.split_once('=') {
                Some((n, v)) => (n.to_string(), Some(v.to_string())),
                None => (body.to_string(), None),
            };
            let spec = specs
                .iter()
                .find(|s| s.long == name)
                .ok_or_else(|| format!("unknown option --{}", name))?;
            match spec.kind {
                Kind::Flag => {
                    if inline_val.is_some() {
                        return Err(format!("option --{} takes no value", spec.long));
                    }
                    out.flags.insert(spec.long.to_string(), true);
                }
                Kind::Str => {
                    let v = match inline_val {
                        Some(v) => v,
                        None => {
                            if i >= argv.len() {
                                return Err(format!("missing value for --{}", spec.long));
                            }
                            let v = argv[i].clone();
                            i += 1;
                            v
                        }
                    };
                    out.strs.insert(spec.long.to_string(), v);
                }
                Kind::Int => {
                    let v = match inline_val {
                        Some(v) => v,
                        None => {
                            if i >= argv.len() {
                                return Err(format!("missing value for --{}", spec.long));
                            }
                            let v = argv[i].clone();
                            i += 1;
                            v
                        }
                    };
                    let n: i64 = v.parse().map_err(|_| format!("cannot parse {} as integer", v))?;
                    out.ints.insert(spec.long.to_string(), n);
                }
            }
            continue;
        }
        if arg.len() > 1 && arg.starts_with('-') && !arg.starts_with("--") {
            let chars: Vec<char> = arg.chars().skip(1).collect();
            let mut ci = 0usize;
            while ci < chars.len() {
                let c = chars[ci];
                ci += 1;
                let spec = specs
                    .iter()
                    .find(|s| s.short == Some(c))
                    .ok_or_else(|| format!("unknown option -{}", c))?;
                match spec.kind {
                    Kind::Flag => {
                        out.flags.insert(spec.long.to_string(), true);
                    }
                    Kind::Str => {
                        let v: String = if ci < chars.len() {
                            chars[ci..].iter().collect()
                        } else if i < argv.len() {
                            let v = argv[i].clone();
                            i += 1;
                            v
                        } else {
                            return Err(format!("missing value for -{}", c));
                        };
                        ci = chars.len();
                        out.strs.insert(spec.long.to_string(), v);
                    }
                    Kind::Int => {
                        let v: String = if ci < chars.len() {
                            chars[ci..].iter().collect()
                        } else if i < argv.len() {
                            let v = argv[i].clone();
                            i += 1;
                            v
                        } else {
                            return Err(format!("missing value for -{}", c));
                        };
                        ci = chars.len();
                        let n: i64 =
                            v.parse().map_err(|_| format!("cannot parse {} as integer", v))?;
                        out.ints.insert(spec.long.to_string(), n);
                    }
                }
            }
            continue;
        }
        out.rest.push(arg);
    }
    Ok(out)
}
