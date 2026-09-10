use std::collections::HashMap;

use crate::model::AurPkg;

const RPC_URL: &str = "https://aur.archlinux.org/rpc/";

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .user_agent("freeman/0.1")
        .timeout(std::time::Duration::from_secs(15))
        .build()
}

fn parse_results(body: ureq::Response) -> Result<Vec<AurPkg>, String> {
    let json: serde_json::Value = body.into_json().map_err(|e| e.to_string())?;
    let t = json.get("type").and_then(|t| t.as_str());
    if t != Some("multiinfo") && t != Some("search") {
        if json.get("resultcount").and_then(|c| c.as_u64()) == Some(0) {
            return Ok(Vec::new());
        }
        return Err("unexpected AUR response type".to_string());
    }
    let results = match json.get("results") {
        Some(serde_json::Value::Array(a)) => a,
        _ => return Err("malformed AUR response".into()),
    };
    Ok(results.iter().filter_map(json_to_aur_pkg).collect())
}

pub fn json_to_aur_pkg(v: &serde_json::Value) -> Option<AurPkg> {
    let get_str = |k: &str| v.get(k).and_then(|x| x.as_str()).map(String::from);
    let get_i64 = |k: &str| v.get(k).and_then(|x| x.as_i64());
    let get_arr = |k: &str| -> Vec<String> {
        v.get(k)
            .and_then(|x| x.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    };
    Some(AurPkg {
        name: get_str("Name")?,
        version: get_str("Version")?,
        desc: get_str("Description"),
        packagebase: get_str("PackageBase")?,
        url: get_str("URL"),
        maintainer: get_str("Maintainer"),
        numvotes: get_i64("NumVotes").unwrap_or(0),
            outofdate: get_i64("OutOfDate"),
            first_submitted: get_i64("FirstSubmitted"),
            last_modified: get_i64("LastModified"),
        depends: get_arr("Depends"),
        makedepends: get_arr("MakeDepends"),
        checkdepends: get_arr("CheckDepends"),
        optdepends: get_arr("OptDepends"),
        provides: get_arr("Provides"),
        replaces: get_arr("Replaces"),
        conflicts: get_arr("Conflicts"),
        license: get_arr("License"),
    })
}

pub fn aur_search(term: &str) -> Result<Vec<AurPkg>, String> {
    let resp = agent()
        .get(RPC_URL)
        .query("v", "5")
        .query("type", "search")
        .query("by", "name-desc")
        .query("arg", term)
        .call()
        .map_err(|e| format!("AUR request failed: {e}"))?;
    let mut pkgs = parse_results(resp)?;
    pkgs.sort_by(|a, b| b.numvotes.cmp(&a.numvotes).then(a.name.cmp(&b.name)));
    Ok(pkgs)
}

pub fn aur_info(names: &[&str]) -> Result<HashMap<String, AurPkg>, String> {
    let mut out = HashMap::new();
    if names.is_empty() {
        return Ok(out);
    }
    let mut req = agent().get(RPC_URL).query("v", "5").query("type", "info");
    for n in names {
        req = req.query("arg[]", n);
    }
    let resp = req.call().map_err(|e| format!("AUR request failed: {e}"))?;
    for pkg in parse_results(resp)? {
        out.insert(pkg.name.clone(), pkg);
    }
    Ok(out)
}
