mod aur;
mod model;

pub use aur::{aur_info, aur_search, json_to_aur_pkg};
pub use model::{AurPkg, PkgInfo, Update, Updates};

use std::collections::HashSet;

use alpm::{Alpm, PackageReason, SigLevel};
use freeman_config::PacmanConf;

fn dep_string(d: &alpm::Dep) -> String {
    let mut s = d.name().to_string();
    if let Some(v) = d.version() {
        let op = match d.depmod() {
            alpm::DepMod::Eq => "=",
            alpm::DepMod::Ge => ">=",
            alpm::DepMod::Le => "<=",
            alpm::DepMod::Gt => ">",
            alpm::DepMod::Lt => "<",
            alpm::DepMod::Any => "",
        };
        s.push_str(op);
        s.push_str(v.as_str());
    }
    s
}

fn validation_names(bits: u32) -> Vec<String> {
    if bits == 0 {
        return vec!["Unknown".to_string()];
    }
    const NONE: u32 = 0x08;
    const MD5: u32 = 0x01;
    const SHA256: u32 = 0x02;
    const SIG: u32 = 0x04;
    if bits & NONE != 0 {
        return vec!["None".to_string()];
    }
    let mut out = Vec::new();
    if bits & MD5 != 0 {
        out.push("MD5 Sum".to_string());
    }
    if bits & SHA256 != 0 {
        out.push("SHA-256 Sum".to_string());
    }
    if bits & SIG != 0 {
        out.push("Signature".to_string());
    }
    out
}

fn conv(p: &alpm::Package) -> PkgInfo {
    let dbname = p.db().map(|db| db.name().to_string());
    let is_local = dbname.as_deref() == Some("local");
    let installed = if is_local { Some(p.version().to_string()) } else { None };
    PkgInfo {
        name: p.name().to_string(),
        version: p.version().to_string(),
        installed,
        desc: p.desc().map(String::from),
        url: p.url().map(String::from),
        repo: if is_local { None } else { dbname },
        licenses: p.licenses().into_iter().map(String::from).collect(),
        groups: p.groups().into_iter().map(String::from).collect(),
        depends: p.depends().into_iter().map(dep_string).collect(),
        optdepends: p.optdepends().into_iter().map(dep_string).collect(),
        makedepends: p.makedepends().into_iter().map(dep_string).collect(),
        checkdepends: p.checkdepends().into_iter().map(dep_string).collect(),
        requiredby: p.required_by().into_iter().collect(),
        optionalfor: p.optional_for().into_iter().collect(),
        provides: p.provides().into_iter().map(dep_string).collect(),
        replaces: p.replaces().into_iter().map(dep_string).collect(),
        conflicts: p.conflicts().into_iter().map(dep_string).collect(),
        packager: p.packager().map(String::from),
        arch: p.arch().map(String::from),
        build_date: Some(p.build_date()),
        install_date: p.install_date(),
        explicit: if is_local {
            Some(p.reason() == PackageReason::Explicit)
        } else {
            None
        },
        isize: p.isize(),
        validations: validation_names(p.validation().bits()),
        backups: p
            .backup()
            .into_iter()
            .map(|b| format!("/{}", b.name()))
            .collect(),
    }
}

pub struct Database {
    h: Alpm,
    ignore_pkgs: HashSet<String>,
}

impl Database {
    pub fn open(pconf: &PacmanConf) -> Result<Self, String> {
        let h = Alpm::new(pconf.root_dir.as_str(), pconf.db_path.as_str())
            .map_err(|e| format!("alpm init: {e}"))?;
        for repo in &pconf.repos {
            h.register_syncdb(repo.name.as_str(), SigLevel::NONE)
                .map_err(|e| format!("register db {}: {e}", repo.name))?;
        }
        Ok(Database {
            h,
            ignore_pkgs: pconf.ignore_pkgs.iter().cloned().collect(),
        })
    }

    pub fn local_satisfies(&self, name: &str) -> bool {
        self.h.localdb().pkgs().into_iter().any(|p| {
            p.name() == name || p.provides().into_iter().any(|pv| pv.name() == name)
        })
    }

    pub fn sync_satisfies(&self, name: &str) -> bool {
        self.h.syncdbs().into_iter().any(|db| {
            db.pkgs().into_iter().any(|p| {
                p.name() == name
                    || p.provides().into_iter().any(|pv| pv.name() == name)
            })
        })
    }

    pub fn local_pkg(&self, name: &str) -> Option<PkgInfo> {
        self.h.localdb().pkg(name).ok().map(|p| conv(&p))
    }

    pub fn attach_installed(&self, info: &mut PkgInfo) {
        if let Some(local) = self.local_pkg(&info.name) {
            info.installed = Some(local.version);
            info.install_date = local.install_date;
            info.explicit = local.explicit;
            info.isize = local.isize;
            info.requiredby = local.requiredby;
            info.optionalfor = local.optionalfor;
            info.backups = local.backups;
            info.validations = local.validations;
        }
    }

    pub fn installed(&self) -> Vec<PkgInfo> {
        let mut v: Vec<PkgInfo> =
            self.h.localdb().pkgs().into_iter().map(|p| conv(&p)).collect();
        v.sort_by(|a, b| a.name.cmp(&b.name));
        v
    }

    pub fn explicit(&self) -> Vec<PkgInfo> {
        self.installed()
            .into_iter()
            .filter(|p| p.explicit == Some(true))
            .collect()
    }

    pub fn orphans(&self) -> Vec<PkgInfo> {
        self.installed()
            .into_iter()
            .filter(|p| p.explicit == Some(false) && p.requiredby.is_empty())
            .collect()
    }

    pub fn foreign(&self) -> Vec<PkgInfo> {
        self.installed()
            .into_iter()
            .filter(|p| self.sync_newest(&p.name).is_none())
            .collect()
    }

    pub fn sync_newest(&self, name: &str) -> Option<PkgInfo> {
        let mut best: Option<(String, PkgInfo)> = None;
        for db in self.h.syncdbs().into_iter() {
            if let Ok(p) = db.pkg(name) {
                let ver = p.version().to_string();
                match &best {
                    Some((v, _)) => {
                        if freeman_core::vercmp(&ver, v) == std::cmp::Ordering::Greater {
                            best = Some((ver, conv(&p)));
                        }
                    }
                    None => best = Some((ver, conv(&p))),
                }
            }
        }
        best.map(|(_, mut info)| {
            self.attach_installed(&mut info);
            info
        })
    }

    pub fn groups(&self) -> Vec<String> {
        let mut set: HashSet<String> = HashSet::new();
        for db in self.h.syncdbs().into_iter() {
            if let Ok(gs) = db.groups() {
                for g in gs {
                    set.insert(g.name().to_string());
                }
            }
        }
        let mut v: Vec<String> = set.into_iter().collect();
        v.sort();
        v
    }

    pub fn group_pkgs(&self, group: &str) -> Option<Vec<PkgInfo>> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut found_any = false;
        let mut out = Vec::new();
        for db in self.h.syncdbs().into_iter() {
            if let Ok(g) = db.group(group) {
                found_any = true;
                for p in g.packages() {
                    if seen.insert(p.name().to_string()) {
                        let mut info = conv(&p);
                        self.attach_installed(&mut info);
                        out.push(info);
                    }
                }
            }
        }
        if found_any {
            out.sort_by(|a, b| a.name.cmp(&b.name));
            Some(out)
        } else {
            None
        }
    }

    pub fn repos_names(&self) -> Vec<String> {
        self.h.syncdbs().into_iter().map(|d| d.name().to_string()).collect()
    }

    pub fn repo_pkgs(&self, repo: &str) -> Option<Vec<PkgInfo>> {
        for db in self.h.syncdbs().into_iter() {
            if db.name() == repo {
                let mut out: Vec<PkgInfo> = db.pkgs().into_iter().map(|p| conv(&p)).collect();
                out.sort_by(|a, b| a.name.cmp(&b.name));
                return Some(out);
            }
        }
        None
    }

    pub fn search_repos(&self, terms: &[&str]) -> Vec<PkgInfo> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut out = Vec::new();
        for db in self.h.syncdbs().into_iter() {
            if let Ok(list) = db.search(terms.iter().copied()) {
                for p in list {
                    if seen.insert(p.name().to_string()) {
                        let mut info = conv(&p);
                        self.attach_installed(&mut info);
                        out.push(info);
                    }
                }
            }
        }
        out
    }

    pub fn search_installed(&self, terms: &[&str]) -> Vec<PkgInfo> {
        match self.h.localdb().search(terms.iter().copied()) {
            Ok(list) => {
                let mut v: Vec<PkgInfo> = list.into_iter().map(|p| conv(&p)).collect();
                v.sort_by(|a, b| a.name.cmp(&b.name));
                v
            }
            Err(_) => Vec::new(),
        }
    }

    pub fn updates(&self) -> Updates {
        let mut up = Updates::default();
        for local in self.installed() {
            let bucket = if self.ignore_pkgs.contains(&local.name) {
                &mut up.ignored_updates
            } else {
                &mut up.repos_updates
            };
            if let Some(newest) = self.sync_newest(&local.name) {
                if freeman_core::vercmp(&local.version, &newest.version)
                    == std::cmp::Ordering::Less
                {
                    bucket.push(Update {
                        name: local.name,
                        current: local.version,
                        new: newest.version,
                        repo: newest.repo.unwrap_or_default(),
                    });
                }
            }
        }
        up.repos_updates.sort_by(|a, b| {
            freeman_core::vercmp(&b.new, &a.new).then_with(|| a.name.cmp(&b.name))
        });
        up
    }

    pub fn files_of(&self, name: &str) -> Option<Vec<String>> {
        let pkg = self.h.localdb().pkg(name).ok()?;
        Some(
            pkg.files()
                .files()
                .iter()
                .map(|f| String::from_utf8_lossy(f.name()).into_owned())
                .collect(),
        )
    }

    pub fn search_files(&self, needles: &[&str]) -> Vec<(String, Vec<String>)> {
        let mut out: Vec<(String, Vec<String>)> = Vec::new();
        for local in self.h.localdb().pkgs() {
            let mut hits = Vec::new();
            for f in local.files().files() {
                let path = String::from_utf8_lossy(f.name());
                if needles.iter().any(|n| path.contains(n)) {
                    hits.push(path.to_string());
                }
            }
            if !hits.is_empty() {
                out.push((local.name().to_string(), hits));
            }
        }
        out
    }
}
