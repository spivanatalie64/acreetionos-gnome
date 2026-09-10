use std::collections::HashMap;

#[derive(Debug, Clone, Default)]
pub struct SrcInfo {
    pub pkgbase: String,
    pub pkgver: String,
    pub pkgrel: String,
    pub epoch: String,
    pub pkgnames: Vec<String>,
    pub per_pkg: HashMap<String, PkgEntry>,
    pub base_section: BaseSection,
}

#[derive(Debug, Clone, Default)]
pub struct PkgEntry {
    pub name: String,
    pub depends: Vec<String>,
    pub provides: Vec<String>,
    pub conflicts: Vec<String>,
    pub replaces: Vec<String>,
    pub optdepends: Vec<String>,
    pub makedepends_from_base: Vec<String>,
    pub checkdepends_from_base: Vec<String>,
}

impl SrcInfo {
    pub fn full_version(&self) -> String {
        let mut v = String::new();
        if !self.epoch.is_empty() && self.epoch != "0" {
            v.push_str(&self.epoch);
            v.push(':');
        }
        v.push_str(&self.pkgver);
        if !self.pkgrel.is_empty() {
            v.push('-');
            v.push_str(&self.pkgrel);
        }
        v
    }

    pub fn entry(&self, pkgname: &str) -> PkgEntry {
        let mut e = self.per_pkg.get(pkgname).cloned().unwrap_or_default();
        e.name = pkgname.to_string();
        let b = &self.base_section;
        if e.depends.is_empty() {
            e.depends = b.depends.clone();
        }
        if e.provides.is_empty() {
            e.provides = b.provides.clone();
        }
        if e.conflicts.is_empty() {
            e.conflicts = b.conflicts.clone();
        }
        if e.replaces.is_empty() {
            e.replaces = b.replaces.clone();
        }
        e.makedepends_from_base = b.makedepends.clone();
        e.checkdepends_from_base = b.checkdepends.clone();
        e
    }

    pub fn parse(text: &str, arch: &str) -> Result<Self, String> {
        let mut si = SrcInfo::default();
        let mut current_base = BaseSection::default();
        let mut pkgs: Vec<PkgEntry> = Vec::new();
        let mut cur: Option<PkgEntry> = None;
        for raw in text.lines() {
            let line = raw.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if line == "pkgbase" || line.starts_with("pkgname = ") {
                if let Some(e) = cur.take() {
                    pkgs.push(e);
                }
            }
            if line.starts_with("pkgname = ") {
                cur = Some(PkgEntry { name: value_of(line), ..Default::default() });
                continue;
            }
            match cur.as_mut() {
                None => apply_base(line, &mut current_base, &mut si, arch)?,
                Some(e) => apply_pkg(line, e, arch),
            }
        }
        if let Some(e) = cur.take() {
            pkgs.push(e);
        }
        si.pkgnames = pkgs.iter().map(|p| p.name.clone()).collect();
        si.base_section = current_base;
        for mut p in pkgs {
            p.makedepends_from_base = si.base_section.makedepends.clone();
            p.checkdepends_from_base = si.base_section.checkdepends.clone();
            si.per_pkg.insert(p.name.clone(), p);
        }
        Ok(si)
    }

    pub fn build_depends(&self, pkgname: &str) -> Vec<String> {
        let e = self.entry(pkgname);
        let mut out = e.depends.clone();
        for d in e.makedepends_from_base.iter().chain(e.checkdepends_from_base.iter()) {
            if !out.contains(d) {
                out.push(d.clone());
            }
        }
        out
    }

    pub fn any_pkgname(&self, target: &str) -> bool {
        self.pkgnames.iter().any(|n| n == target)
    }
}

#[derive(Default, Clone, Debug)]
pub struct BaseSection {
    depends: Vec<String>,
    provides: Vec<String>,
    conflicts: Vec<String>,
    replaces: Vec<String>,
    optdepends: Vec<String>,
    makedepends: Vec<String>,
    checkdepends: Vec<String>,
}

impl BaseSection {
    fn push_list(&mut self, key: &str, arch: &str, val: String) {
        let base_key = strip_arch(key);
        let arch_ok = key == &format!("{base_key}_{arch}") || key == format!("{base_key}_any");
        let plain = key == base_key;
        if !(plain || arch_ok) {
            return;
        }
        match base_key.as_str() {
            "depends" => self.depends.push(val),
            "provides" => self.provides.push(val),
            "conflicts" => self.conflicts.push(val),
            "replaces" => self.replaces.push(val),
            "optdepends" => self.optdepends.push(val),
            _ => {}
        }
    }
}

fn value_of(line: &str) -> String {
    line.split_once(" = ").map(|(_, v)| v.to_string()).unwrap_or_default()
}

fn key_and_flag(line: &str) -> (String, bool) {
    match line.split_once(" = ") {
        Some((k, _)) => (k.to_string(), true),
        None => (line.trim_start().to_string(), false),
    }
}

fn apply_base(
    line: &str,
    base: &mut BaseSection,
    si: &mut SrcInfo,
    arch: &str,
) -> Result<(), String> {
    let (key, has_val) = key_and_flag(line);
    if !has_val {
        return Ok(());
    }
    let base_key = strip_arch(&key);
    match base_key.as_str() {
        "pkgbase" => si.pkgbase = value_of(line),
        "pkgver" => si.pkgver = value_of(line),
        "pkgrel" => si.pkgrel = value_of(line),
        "epoch" => si.epoch = value_of(line),
        "makedepends" => base.makedepends.push(value_of(line)),
        "checkdepends" => base.checkdepends.push(value_of(line)),
        "depends" | "provides" | "conflicts" | "replaces" | "optdepends" => {
            base.push_list(&key, arch, value_of(line))
        }
        _ => {}
    }
    Ok(())
}

fn apply_pkg(line: &str, e: &mut PkgEntry, arch: &str) {
    let (key, has_val) = key_and_flag(line);
    if !has_val {
        return;
    }
    let val = value_of(line);
    match strip_arch(&key).as_str() {
        "depends" => {
            if key == "depends" || key == format!("depends_{arch}") || key == "depends_any" {
                e.depends.push(val)
            }
        }
        "provides" => {
            if key == "provides" || key == format!("provides_{arch}") || key == "provides_any" {
                e.provides.push(val)
            }
        }
        "conflicts" => e.conflicts.push(val),
        "replaces" => e.replaces.push(val),
        "optdepends" => {
            if key == "optdepends" || key == format!("optdepends_{arch}") {
                e.optdepends.push(val)
            }
        }
        "makedepends" => {}
        "checkdepends" => {}
        _ => {}
    }
}

fn strip_arch(key: &str) -> String {
    for a in ["x86_64", "aarch64", "armv7h", "i686", "pentium4", "any"] {
        let suffix = format!("_{a}");
        if let Some(k) = key.strip_suffix(&suffix) {
            return k.to_string();
        }
    }
    key.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = "\
pkgbase = yay-bin
pkgver = 12.4.2
pkgrel = 1
epoch = 2
pkgdesc = Yet another yogurt
arch = x86_64
makedepends = go
checkdepends = git
conflicts = yay
provides = yay

pkgname = yay-bin
depends = pacman>=6.1
depends_x86_64 = glibc
optdepends = sudo: elevated privileges
provides = yay=12.4.2

pkgname = yay-debug
";

    #[test]
    fn parses_base_and_inherits() {
        let si = SrcInfo::parse(FIXTURE, "x86_64").unwrap();
        assert_eq!(si.pkgbase, "yay-bin");
        assert_eq!(si.epoch, "2");
        assert_eq!(si.full_version(), "2:12.4.2-1");
        assert_eq!(si.pkgnames, vec!["yay-bin", "yay-debug"]);
        let e = si.entry("yay-bin");
        assert!(e.depends.contains(&"pacman>=6.1".to_string()));
        assert!(e.depends.contains(&"glibc".to_string()));
        let dbg = si.entry("yay-debug");
        assert!(dbg.depends.is_empty(), "arch-specific depends must not leak");
        assert_eq!(dbg.provides, vec!["yay"], "base provides inherited");
    }

    #[test]
    fn build_depends_merge_make_check() {
        let si = SrcInfo::parse(FIXTURE, "x86_64").unwrap();
        let bd = si.build_depends("yay-bin");
        assert!(bd.contains(&"go".to_string()));
        assert!(bd.contains(&"git".to_string()));
    }
}
