#[derive(Debug, Clone)]
pub struct PkgInfo {
    pub name: String,
    pub version: String,
    pub installed: Option<String>,
    pub desc: Option<String>,
    pub url: Option<String>,
    pub repo: Option<String>,
    pub licenses: Vec<String>,
    pub groups: Vec<String>,
    pub depends: Vec<String>,
    pub optdepends: Vec<String>,
    pub makedepends: Vec<String>,
    pub checkdepends: Vec<String>,
    pub requiredby: Vec<String>,
    pub optionalfor: Vec<String>,
    pub provides: Vec<String>,
    pub replaces: Vec<String>,
    pub conflicts: Vec<String>,
    pub packager: Option<String>,
    pub arch: Option<String>,
    pub build_date: Option<i64>,
    pub install_date: Option<i64>,
    pub explicit: Option<bool>,
    pub isize: i64,
    pub validations: Vec<String>,
    pub backups: Vec<String>,
}

impl PkgInfo {
    pub fn is_installed(&self) -> bool {
        self.installed.is_some()
    }
}

#[derive(Debug, Clone)]
pub struct AurPkg {
    pub name: String,
    pub version: String,
    pub desc: Option<String>,
    pub packagebase: String,
    pub url: Option<String>,
    pub maintainer: Option<String>,
    pub numvotes: i64,
    pub outofdate: Option<i64>,
    pub first_submitted: Option<i64>,
    pub last_modified: Option<i64>,
    pub depends: Vec<String>,
    pub makedepends: Vec<String>,
    pub checkdepends: Vec<String>,
    pub optdepends: Vec<String>,
    pub provides: Vec<String>,
    pub replaces: Vec<String>,
    pub conflicts: Vec<String>,
    pub license: Vec<String>,
}

impl AurPkg {
    pub fn to_pkg_info(&self) -> PkgInfo {
        PkgInfo {
            name: self.name.clone(),
            version: self.version.clone(),
            installed: None,
            desc: self.desc.clone(),
            url: self.url.clone(),
            repo: Some("AUR".into()),
            licenses: self.license.clone(),
            groups: Vec::new(),
            depends: self.depends.clone(),
            optdepends: self.optdepends.clone(),
            makedepends: self.makedepends.clone(),
            checkdepends: self.checkdepends.clone(),
            requiredby: Vec::new(),
            optionalfor: Vec::new(),
            provides: self.provides.clone(),
            replaces: self.replaces.clone(),
            conflicts: self.conflicts.clone(),
            packager: None,
            arch: None,
            build_date: None,
            install_date: None,
            explicit: None,
            isize: 0,
            validations: Vec::new(),
            backups: Vec::new(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Update {
    pub name: String,
    pub current: String,
    pub new: String,
    pub repo: String,
}

#[derive(Debug, Default)]
pub struct Updates {
    pub repos_updates: Vec<Update>,
    pub ignored_updates: Vec<Update>,
}
