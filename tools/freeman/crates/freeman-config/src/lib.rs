use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PamacConf {
    pub remove_unrequired_deps: bool,
    pub refresh_period: i64,
    pub no_update_hide_icon: bool,
    pub enable_downgrade: bool,
    pub simple_install: bool,
    pub enable_aur: bool,
    pub keep_built_pkgs: bool,
    pub check_aur_updates: bool,
    pub check_aur_vcs_updates: bool,
    pub build_directory: String,
    pub keep_num_packages: i64,
    pub only_rm_uninstalled: bool,
    pub download_updates: bool,
    pub offline_upgrade: bool,
    pub max_parallel_downloads: i64,
}

impl PamacConf {
    pub fn defaults() -> Self {
        Self {
            refresh_period: 6,
            build_directory: "/var/tmp".into(),
            keep_num_packages: 3,
            max_parallel_downloads: 4,
            ..Default::default()
        }
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self, std::io::Error> {
        let text = std::fs::read_to_string(path)?;
        Ok(Self::parse(&text))
    }

    pub fn parse(text: &str) -> Self {
        let mut conf = Self::defaults();
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (key, value) = if let Some((k, v)) = line.split_once('=') {
                (k.trim().to_string(), Some(v.trim().to_string()))
            } else {
                (line.to_string(), None)
            };
            match key.as_str() {
                "RemoveUnrequiredDeps" => conf.remove_unrequired_deps = true,
                "RefreshPeriod" => set_i64(&mut conf.refresh_period, &value),
                "NoUpdateHideIcon" => conf.no_update_hide_icon = true,
                "EnableDowngrade" => conf.enable_downgrade = true,
                "SimpleInstall" => conf.simple_install = true,
                "EnableAUR" => conf.enable_aur = true,
                "KeepBuiltPkgs" => conf.keep_built_pkgs = true,
                "CheckAURUpdates" => conf.check_aur_updates = true,
                "CheckAURVCSUpdates" => conf.check_aur_vcs_updates = true,
                "BuildDirectory" => {
                    if let Some(v) = value {
                        conf.build_directory = v;
                    }
                }
                "KeepNumPackages" => set_i64(&mut conf.keep_num_packages, &value),
                "OnlyRmUninstalled" => conf.only_rm_uninstalled = true,
                "DownloadUpdates" => conf.download_updates = true,
                "OfflineUpgrade" => conf.offline_upgrade = true,
                "MaxParallelDownloads" => set_i64(&mut conf.max_parallel_downloads, &value),
                _ => {}
            }
        }
        conf
    }
}

fn set_i64(target: &mut i64, value: &Option<String>) {
    if let Some(v) = value {
        if let Ok(n) = v.parse() {
            *target = n;
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RepoConf {
    pub name: String,
    pub servers: Vec<String>,
    pub sig_level: Vec<String>,
    pub usage: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PacmanConf {
    pub root_dir: String,
    pub db_path: String,
    pub cache_dirs: Vec<String>,
    pub hook_dirs: Vec<String>,
    pub log_file: String,
    pub hold_pkgs: Vec<String>,
    pub ignore_pkgs: Vec<String>,
    pub ignore_groups: Vec<String>,
    pub architecture: Vec<String>,
    pub parallel_downloads: i64,
    pub download_timeout: i64,
    pub repos: Vec<RepoConf>,
    pub options_raw: BTreeMap<String, Vec<String>>,
}

impl PacmanConf {
    pub fn defaults() -> Self {
        Self {
            root_dir: "/".into(),
            db_path: "/var/lib/pacman/".into(),
            cache_dirs: vec!["/var/cache/pacman/pkg/".into()],
            hook_dirs: vec!["/etc/pacman.d/hooks".into(), "/usr/share/libalpm/hooks/".into()],
            log_file: "/var/log/pacman.log".into(),
            architecture: vec![std::env::consts::ARCH.into()],
            parallel_downloads: 1,
            download_timeout: 30,
            ..Default::default()
        }
    }

    pub fn system() -> Result<Self, std::io::Error> {
        Self::load("/etc/pacman.conf")
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self, std::io::Error> {
        let text = std::fs::read_to_string(path)?;
        Ok(Self::parse(&text))
    }

    pub fn parse(text: &str) -> Self {
        let mut conf = Self::defaults();
        let mut current: Option<String> = None;
        for raw in text.lines() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(name) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
                if name != "options" {
                    conf.repos.push(RepoConf {
                        name: name.to_string(),
                        ..Default::default()
                    });
                    current = Some(name.to_string());
                } else {
                    current = None;
                }
                continue;
            }
            let Some((k, v)) = line.split_once('=') else { continue };
            let key = k.trim().to_string();
            let val = v.trim();
            match (&current, key.as_str()) {
                (None, "RootDir") => conf.root_dir = val.to_string(),
                (None, "DBPath") => conf.db_path = val.to_string(),
                (None, "CacheDir") => extend_split(&mut conf.cache_dirs, val),
                (None, "HookDir") => extend_split(&mut conf.hook_dirs, val),
                (None, "LogFile") => conf.log_file = val.to_string(),
                (None, "HoldPkg") => extend_split(&mut conf.hold_pkgs, val),
                (None, "IgnorePkg") => extend_split(&mut conf.ignore_pkgs, val),
                (None, "IgnoreGroup") => extend_split(&mut conf.ignore_groups, val),
                (None, "Architecture") => extend_split(&mut conf.architecture, val),
                (None, "ParallelDownloads") => parse_into(val, &mut conf.parallel_downloads),
                (None, "DownloadTimeout") => parse_into(val, &mut conf.download_timeout),
                (Some(_), _) => {}
                _ => {}
            }
            match current.as_deref() {
                Some(repo_name) => {
                    let repo = conf.repos.iter_mut().find(|r| r.name == repo_name).unwrap();
                    match key.as_str() {
                        "Server" => repo.servers.push(val.to_string()),
                        "SigLevel" => extend_split(&mut repo.sig_level, val),
                        "Usage" => extend_split(&mut repo.usage, val),
                        _ => {}
                    }
                }
                None => {
                    conf.options_raw.entry(key).or_default().push(val.to_string());
                }
            }
        }
        conf.repos.retain(|r| !r.servers.is_empty());
        conf
    }
}

fn extend_split(dst: &mut Vec<String>, val: &str) {
    dst.extend(val.split_whitespace().map(str::to_string));
}

fn parse_into(val: &str, dst: &mut i64) {
    if let Ok(n) = val.parse() {
        *dst = n;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pamac_defaults_when_missing_keys() {
        let c = PamacConf::parse("#EnableAUR\n");
        assert_eq!(c.refresh_period, 6);
        assert_eq!(c.build_directory, "/var/tmp");
        assert_eq!(c.keep_num_packages, 3);
        assert_eq!(c.max_parallel_downloads, 4);
        assert!(!c.enable_aur);
    }

    #[test]
    fn pamac_flags_and_values() {
        let text = "RemoveUnrequiredDeps\nRefreshPeriod = 12\nEnableAUR\nBuildDirectory = /home/x/build\nMaxParallelDownloads = 8\n";
        let c = PamacConf::parse(text);
        assert!(c.remove_unrequired_deps);
        assert_eq!(c.refresh_period, 12);
        assert!(c.enable_aur);
        assert_eq!(c.build_directory, "/home/x/build");
        assert_eq!(c.max_parallel_downloads, 8);
    }

    #[test]
    fn pacman_repos_and_ignores() {
        let text = "[options]\nHoldPkg = pacman glibc\nIgnorePkg = linux   firefox\nParallelDownloads = 5\n\n[core]\nServer = https://mirror.example/$repo/os/$arch\nSigLevel = Required DatabaseOptional\n\n[extra]\nServer = https://mirror.example/$repo/os/$arch\n";
        let c = PacmanConf::parse(text);
        assert_eq!(c.hold_pkgs, vec!["pacman", "glibc"]);
        assert_eq!(c.ignore_pkgs, vec!["linux", "firefox"]);
        assert_eq!(c.parallel_downloads, 5);
        assert_eq!(c.repos.len(), 2);
        assert_eq!(c.repos[0].name, "core");
        assert_eq!(c.repos[0].servers.len(), 1);
        assert_eq!(c.repos[1].name, "extra");
    }
}
