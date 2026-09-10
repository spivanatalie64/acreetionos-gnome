use std::collections::HashMap;

use freeman_db::{AurPkg, Database};

const RPC_URL: &str = "https://aur.archlinux.org/rpc/";

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .user_agent("freeman/0.1")
        .timeout(std::time::Duration::from_secs(20))
        .build()
}

pub fn search_by_provides(term: &str) -> Result<Vec<AurPkg>, String> {
    let resp = agent()
        .get(RPC_URL)
        .query("v", "5")
        .query("type", "search")
        .query("by", "provides")
        .query("arg", term)
        .call()
        .map_err(|e| format!("AUR request failed: {e}"))?;
    let json: serde_json::Value = resp.into_json().map_err(|e| e.to_string())?;
    let results = json.get("results").and_then(|r| r.as_array()).cloned().unwrap_or_default();
    let mut out: Vec<AurPkg> =
        results.iter().filter_map(freeman_db::json_to_aur_pkg).collect();
    out.sort_by(|a, b| b.numvotes.cmp(&a.numvotes).then(a.name.cmp(&b.name)));
    Ok(out)
}

pub fn dep_name(dep: &str) -> &str {
    match dep.find(|c| c == '<' || c == '>' || c == '=') {
        Some(i) => &dep[..i],
        None => dep,
    }
}

#[derive(Debug, Clone)]
pub struct BuildNode {
    pub target: String,
    pub base: String,
    pub info: AurPkg,
}

pub struct Plan {
    pub order: Vec<BuildNode>,
    pub repo_deps: Vec<String>,
}

fn build_depends_of(info: &AurPkg) -> Vec<String> {
    let mut out = info.depends.clone();
    for d in info.makedepends.iter().chain(info.checkdepends.iter()) {
        if !out.contains(d) {
            out.push(d.clone());
        }
    }
    out
}

pub fn resolve(targets: &[String], db: &Database) -> Result<Plan, String> {
    let infos: HashMap<String, AurPkg> = freeman_db::aur_info(
        &targets.iter().map(|s| s.as_str()).collect::<Vec<_>>(),
    )?;
    for t in targets {
        if !infos.contains_key(t) {
            return Err(format!("target not found in AUR: {t}"));
        }
    }

    let mut base_info: HashMap<String, AurPkg> = HashMap::new();
    let mut name_base: HashMap<String, String> = HashMap::new();
    let mut node_deps: HashMap<String, Vec<String>> = HashMap::new();
    let mut repo_deps: Vec<String> = Vec::new();
    let mut first_target: HashMap<String, String> = HashMap::new();

    for t in targets {
        if let Some(info) = infos.get(t) {
            first_target.entry(info.packagebase.clone()).or_insert_with(|| t.clone());
        }
    }

    let mut stack: Vec<String> = Vec::new();
    for (name, info) in &infos {
        if targets.contains(name) {
            name_base.insert(name.clone(), info.packagebase.clone());
            base_info
                .entry(info.packagebase.clone())
                .or_insert_with(|| info.clone());
            if !stack.contains(&info.packagebase) {
                stack.push(info.packagebase.clone());
            }
        }
    }

    while let Some(base) = stack.pop() {
        if node_deps.contains_key(&base) {
            continue;
        }
        let info = base_info.get(&base).cloned().ok_or_else(|| format!("missing info for {base}"))?;
        let mut deps_bases: Vec<String> = Vec::new();
        for d in build_depends_of(&info) {
            let dn = dep_name(&d);
            if db.local_satisfies(dn) {
                continue;
            }
            if db.sync_satisfies(dn) {
                if !repo_deps.contains(&d) {
                    repo_deps.push(d);
                }
                continue;
            }
            if let Some(b) = name_base.get(dn) {
                if *b != base && !deps_bases.contains(b) {
                    deps_bases.push(b.clone());
                }
                continue;
            }
            let fetched = freeman_db::aur_info(&[dn]).unwrap_or_default();
            let chosen = match fetched.get(dn) {
                Some(p) => p.clone(),
                None => {
                    let providers = search_by_provides(dn)?;
                    match providers.first() {
                        Some(p) => p.clone(),
                        None => return Err(format!("dependency not found: {d}")),
                    }
                }
            };
            name_base.insert(chosen.name.clone(), chosen.packagebase.clone());
            for pv in &chosen.provides {
                name_base.insert(pv.split_once('=').map(|(n, _)| n.to_string()).unwrap_or_else(|| pv.clone()), chosen.packagebase.clone());
            }
            base_info.entry(chosen.packagebase.clone()).or_insert(chosen.clone());
            if chosen.packagebase != base && !deps_bases.contains(&chosen.packagebase) {
                deps_bases.push(chosen.packagebase.clone());
            }
            if !node_deps.contains_key(&chosen.packagebase)
                && !stack.contains(&chosen.packagebase)
            {
                stack.push(chosen.packagebase.clone());
            }
        }
        node_deps.insert(base, deps_bases);
    }

    let order = kahn(&node_deps, &first_target, &base_info);
    Ok(Plan { order, repo_deps })
}

fn kahn(
    node_deps: &HashMap<String, Vec<String>>,
    _first_target: &HashMap<String, String>,
    base_info: &HashMap<String, AurPkg>,
) -> Vec<BuildNode> {
    let mut indeg: HashMap<&str, usize> = node_deps.keys().map(|k| (k.as_str(), 0)).collect();
    let mut children: HashMap<&str, Vec<&str>> = HashMap::new();
    for (base, deps) in node_deps {
        for d in deps {
            children.entry(d.as_str()).or_default().push(base.as_str());
            *indeg.get_mut(base.as_str()).unwrap() += 1;
        }
    }
    let mut ready: Vec<&str> = indeg.iter().filter(|(_, v)| **v == 0).map(|(k, _)| *k).collect();
    ready.sort_unstable();
    let mut out = Vec::new();
    while !ready.is_empty() {
        let base = ready.remove(0);
        if let Some(info) = base_info.get(base) {
            out.push(BuildNode {
                target: base.to_string(),
                base: base.to_string(),
                info: info.clone(),
            });
        }
        for c in children.get(base).into_iter().flatten() {
            let e = indeg.get_mut(c).unwrap();
            *e -= 1;
            if *e == 0 {
                let pos = ready.partition_point(|x| *x < *c);
                ready.insert(pos, c);
            }
        }
    }
    out
}
