use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const AUR_URL: &str = "https://aur.archlinux.org";

fn dyn_prefix(cwd: &Path) -> Vec<String> {
    if unsafe { libc_euid() } == 0 {
        vec![
            "systemd-run".into(),
            "--service-type=oneshot".into(),
            "--pipe".into(),
            "--wait".into(),
            "--pty".into(),
            "--property=DynamicUser=yes".into(),
            "--property=CacheDirectory=pamac".into(),
            format!("--property=WorkingDirectory={}", cwd.display()),
        ]
    } else {
        Vec::new()
    }
}

unsafe fn libc_euid() -> u32 {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() }
}

pub fn run(cmdline: &[String], cwd: &Path, quiet: bool) -> Result<i32, String> {
    let mut full = dyn_prefix(cwd);
    full.extend_from_slice(cmdline);
    let (prog, args) = full.split_first().ok_or("empty command")?;
    let mut c = Command::new(prog);
    c.args(args).current_dir(cwd);
    if quiet {
        use std::process::Stdio;
        c.stdout(Stdio::null()).stderr(Stdio::null());
    }
    let st = c.status().map_err(|e| e.to_string())?;
    Ok(st.code().unwrap_or(-1))
}

fn capture(cmdline: &[String], cwd: &Path) -> Result<(i32, String), String> {
    let mut full = dyn_prefix(cwd);
    full.extend_from_slice(cmdline);
    let (prog, args) = full.split_first().ok_or("empty command")?;
    let out = Command::new(prog)
        .args(args)
        .current_dir(cwd)
        .output()
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    Ok((out.status.code().unwrap_or(-1), text))
}

pub fn clone_url(base: &str) -> String {
    format!("{AUR_URL}/{base}.git")
}

pub fn ensure_clone(
    base: &str,
    builddir: &Path,
    overwrite: bool,
    quiet: bool,
) -> Result<PathBuf, String> {
    let _ = std::fs::create_dir_all(builddir);
    let pkgdir = builddir.join(base);
    let url = clone_url(base);
    if pkgdir.exists() && overwrite {
        std::fs::remove_dir_all(&pkgdir).map_err(|e| e.to_string())?;
    }
    if pkgdir.exists() {
        let st = run(&["git".into(), "fetch".into(), "-q".into()], &pkgdir, quiet)?;
        if st != 0 {
            return Err(format!("git fetch failed for {base}"));
        }
        let st = run(
            &[
                "git".into(),
                "reset".into(),
                "--hard".into(),
                "-q".into(),
                "origin/master".into(),
            ],
            &pkgdir,
            quiet,
        )?;
        if st != 0 {
            return Err(format!("git reset failed for {base}"));
        }
    } else {
        let st = run(
            &[
                "git".into(),
                "clone".into(),
                "-q".into(),
                "--depth=1".into(),
                url,
                pkgdir.to_string_lossy().into_owned(),
            ],
            builddir,
            quiet,
        )?;
        if st != 0 {
            return Err(format!("git clone failed for {base}"));
        }
    }
    Ok(pkgdir)
}

pub fn regenerate_srcinfo(dir: &Path) -> Result<String, String> {
    let (status, text) = capture(
        &["makepkg".into(), "--printsrcinfo".into()],
        dir,
    )?;
    if status != 0 {
        return Err(format!("makepkg --printsrcinfo failed in {}", dir.display()));
    }
    let path = dir.join(".SRCINFO");
    let mut f = std::fs::File::create(&path).map_err(|e| e.to_string())?;
    f.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
    Ok(text)
}

pub fn load_or_generate_srcinfo(dir: &Path) -> Result<String, String> {
    regenerate_srcinfo(dir)
}

pub fn makepkg_build(dir: &Path, keep_built: bool, extra_args: &[&str]) -> Result<i32, String> {
    let prog = first_of(&dyn_prefix(dir));
    let mut c = Command::new(prog);
    apply_dyn(&mut c, dir);
    c.arg("makepkg");
    if extra_args.is_empty() {
        c.args(["-cCf", "--nocheck"]);
    } else {
        for a in extra_args {
            c.arg(a);
        }
    }
    if !keep_built {
        c.env("PKGDEST", dir);
        c.env("PKGEXT", ".pkg.tar");
    }
    let st = c.current_dir(dir).status().map_err(|e| e.to_string())?;
    Ok(st.code().unwrap_or(-1))
}

fn first_of(v: &[String]) -> String {
    v.first().cloned().unwrap_or_else(|| "makepkg".to_string())
}

fn apply_dyn(c: &mut Command, dir: &Path) {
    let pre = dyn_prefix(dir);
    if !pre.is_empty() {
        c.args(&pre[1..]);
    }
}

pub fn devel_latest_version(dir: &Path) -> Result<Option<String>, String> {
    let st = run(
        &[
            "makepkg".into(),
            "--nobuild".into(),
            "--noprepare".into(),
            "--nodeps".into(),
            "--skipinteg".into(),
        ],
        dir,
        true,
    )?;
    if st != 0 {
        return Ok(None);
    }
    let text = regenerate_srcinfo(dir)?;
    let (mut epoch, mut pkgver, mut pkgrel) = (String::new(), String::new(), String::new());
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("epoch = ") { epoch = v.trim().into(); }
        else if let Some(v) = line.strip_prefix("pkgver = ") { pkgver = v.trim().into(); }
        else if let Some(v) = line.strip_prefix("pkgrel = ") { pkgrel = v.trim().into(); }
    }
    if pkgver.is_empty() { return Ok(None); }
    let mut v = String::new();
    if !epoch.is_empty() && epoch != "0" { v.push_str(&epoch); v.push(':'); }
    v.push_str(&pkgver);
    if !pkgrel.is_empty() { v.push('-'); v.push_str(&pkgrel); }
    Ok(Some(v))
}

pub fn packagelist(dir: &Path, keep_built: bool) -> Result<Vec<PathBuf>, String> {
    let prog = first_of(&dyn_prefix(dir));
    let mut c = Command::new(prog);
    apply_dyn(&mut c, dir);
    if !keep_built {
        c.env("PKGDEST", dir);
        c.env("PKGEXT", ".pkg.tar");
    }
    let out = c
        .args(["makepkg", "--packagelist"])
        .current_dir(dir)
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err("makepkg --packagelist failed".into());
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(PathBuf::from)
        .collect())
}

pub fn pkgname_from_filename(fname: &str) -> Option<String> {
    let fname = std::path::Path::new(fname)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| fname.to_string());
    let stem = match fname.find(".pkg.tar") {
        Some(i) => &fname[..i],
        None => return None,
    };
    let bytes = stem.as_bytes();
    let mut dashes = 0;
    let mut idx = bytes.len();
    while idx > 0 {
        if bytes[idx - 1] == b'-' {
            dashes += 1;
            if dashes == 3 {
                return Some(stem[..idx - 1].to_string());
            }
        }
        idx -= 1;
    }
    None
}

pub fn is_vcs_package(name: &str, version: &str) -> bool {
    let lower = name.to_lowercase();
    for suf in ["-git", "-svn", "-hg", "-bzr", "-darcs"] {
        if lower.ends_with(suf) {
            return true;
        }
    }
    version.contains(".r") && version.contains(".g")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_pkgname_from_pkg_files() {
        assert_eq!(
            pkgname_from_filename("yay-bin-12.4.2-1-x86_64.pkg.tar"),
            Some("yay-bin".into())
        );
        assert_eq!(
            pkgname_from_filename("/tmp/x/python-nodeenv-1.9.1-4-any.pkg.tar.zst"),
            Some("python-nodeenv".into())
        );
        assert_eq!(pkgname_from_filename("garbage.txt"), None);
    }

    #[test]
    fn vcs_heuristics() {
        assert!(is_vcs_package("linux-mainline-git", "6.10.rc2.g123"));
        assert!(is_vcs_package("foo-svn", "1.0-2"));
        assert!(!is_vcs_package("firefox", "129.0-1"));
    }
}
