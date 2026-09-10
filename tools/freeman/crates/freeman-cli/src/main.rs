mod args;
mod fmt;
mod help;

use std::collections::HashSet;

use args::{parse, s as opt_s, f as opt_f, i as opt_i};
use freeman_config::{PacmanConf, PamacConf};
use freeman_core::vercmp;
use freeman_aur::{dep_name, ensure_clone, is_vcs_package, makepkg_build, packagelist, pkgname_from_filename, regenerate_srcinfo, devel_latest_version, search_by_provides};
use freeman_db::{aur_info, aur_search, Database};
use std::path::PathBuf;
use std::process::Command;


const VERSION_LINE_1: &str = "freeman-cli 11.7.5-freeman  -  libfreeman 11.7.5-freeman";
const REFUSAL: &str = "freeman: this action needs the transaction daemon, which is not wired yet; nothing was changed";

fn main() {
    unsafe {
        extern "C" {
            fn signal(sig: i32, handler: usize) -> usize;
        }
        signal(13, 0);
    }
    let argv: Vec<String> = std::env::args().collect();
    std::process::exit(run(&argv));
}

fn out(s: &str) {
    print!("{}", s);
}

fn load_freeman_conf() -> PamacConf {
    PamacConf::load("/etc/freeman.conf").unwrap_or_else(|_| PamacConf::defaults())
}

fn open_db() -> Result<Database, i32> {
    let pconf = PacmanConf::system().map_err(|e| {
        eprintln!("Error: cannot read pacman.conf: {}", e);
        1
    })?;
    Database::open(&pconf).map_err(|e| {
        eprintln!("Error: {}", e);
        1
    })
}

fn run(argv: &[String]) -> i32 {
    if argv.len() == 1 {
        out(&help::general());
        return 0;
    }
    let mut show_help = false;
    let mut version = false;
    let mut positional: Vec<String> = Vec::new();
    for a in &argv[1..] {
        match a.as_str() {
            "--help" | "-h" => show_help = true,
            "--version" | "-V" => version = true,
            _ => positional.push(a.clone()),
        }
    }
    let verb = positional.first().cloned().unwrap_or_default();
    if show_help {
        if positional.len() == 1 {
            match verb.as_str() {
                "search" => out(&help::search()),
                "info" => out(&help::info()),
                "list" => out(&help::list()),
                "clone" => out(&help::clone_()),
                "build" => out(&help::build()),
                "install" => out(&help::install()),
                "reinstall" => out(&help::reinstall()),
                "remove" => out(&help::remove()),
                "checkupdates" => out(&help::checkupdates()),
                "upgrade" | "update" => out(&help::upgrade()),
                "clean" => out(&help::clean()),
                _ => out(&help::general()),
            }
        } else {
            out(&help::general());
        }
        return 0;
    }
    if version {
        display_version();
        return 0;
    }
    let rest: Vec<String> = positional[1..].to_vec();
    match verb.as_str() {
        "search" => cmd_search(&rest),
        "info" => cmd_info(&rest),
        "list" => cmd_list(&rest),
        "checkupdates" => cmd_image_update("check", &rest),
        "clean" => cmd_clean(&rest),
        "install" => cmd_install(&rest),
        "reinstall" => {
            cmd_mutating(
                "reinstall",
                &rest,
                &["as-deps", "as-explicit"],
                &help::reinstall,
                false,
            )
        }
        "remove" => cmd_mutating("remove", &rest, &[], &help::remove, false),
        "build" => cmd_build(&rest),
        "clone" => cmd_clone(&rest),
        "update" | "upgrade" => cmd_image_update(image_action(&rest), &rest),
        _ => {
            out(&help::general());
            0
        }
    }
}

fn image_action(rest: &[String]) -> &str {
    if rest.iter().any(|arg| arg == "--check") {
        "check"
    } else if rest.iter().any(|arg| arg == "--apply") {
        "apply"
    } else {
        "stage"
    }
}

fn cmd_image_update(action: &str, rest: &[String]) -> i32 {
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") {
        out("Horizon image update\n\nUsage: freeman update [--check|--apply]\n\nThe update downloads and stages a signed Horizon system image instead of mutating the installed system with pacman.\n");
        return 0;
    }
    let script_candidates = [
        "/usr/local/bin/horizon-image-update",
        "airootfs/usr/local/bin/horizon-image-update",
        "./airootfs/usr/local/bin/horizon-image-update",
        "horizon-image-update",
    ];
    let mut status = None;
    for cand in script_candidates {
        if let Ok(st) = Command::new(cand).arg(action).status() {
            status = Some(st);
            break;
        }
    }
    match status {
        Some(st) => st.code().unwrap_or(1),
        None => {
            eprintln!("freeman: image updater unavailable (/usr/local/bin/horizon-image-update not found)");
            1
        }
    }
}

fn display_version() {
    out(VERSION_LINE_1);
    out("\n");
    out("freeman 0.1.0, a freeman-compatible package manager\n");
    out("This program is free software, you can redistribute it under the terms of the GNU GPL.\n");
}

fn err_target(name: &str) -> i32 {
    println!("Error: target not found: {}", name);
    1
}

fn cmd_search(rest: &[String]) -> i32 {
    if rest.is_empty() {
        out(&help::search());
        return 0;
    }
    let specs = [
        opt_f("installed", Some('i')),
        opt_f("repos", Some('r')),
        opt_f("aur", Some('a')),
        opt_f("no-aur", None),
        opt_f("files", Some('f')),
        opt_f("quiet", Some('q')),
        opt_f("help", Some('h')),
    ];
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::search());
            return 0;
        }
    };
    if p.flag("help") || p.rest.is_empty() || (p.flag("installed") && p.flag("repos")) {
        out(&help::search());
        return 0;
    }
    let quiet = p.flag("quiet");
    let term: String = p.rest.join(" ").to_lowercase();
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    if p.flag("files") {
        let needles: Vec<&str> = p.rest.iter().map(|s| s.as_str()).collect();
        let hits = db.search_files(&needles);
        if hits.is_empty() {
            if !quiet {
                for n in needles {
                    println!("No package owns {}", n);
                }
            }
            return 1;
        }
        let mut o = String::new();
        for (pkg, files) in hits {
            if quiet {
                o.push_str(&format!("{}\n", pkg));
            } else {
                for f in files {
                    o.push_str(&format!("{} is owned by {}\n", f, pkg));
                }
            }
        }
        out(&o);
        return 0;
    }
    let aur_on = if p.flag("no-aur") {
        false
    } else {
        p.flag("aur") || load_freeman_conf().enable_aur
    };
    let pkgs = if p.flag("installed") {
        db.search_installed(&[&term])
    } else if p.flag("repos") {
        db.search_repos(&[&term])
    } else {
        let mut v = db.search_repos(&[&term]);
        if aur_on {
            match aur_search(&term) {
                Ok(aur_pkgs) => {
                    for ap in aur_pkgs {
                        let local = db.local_pkg(&ap.name).map(|l| l.version);
                        if local.is_none() {
                            v.push(ap.to_pkg_info());
                        }
                    }
                }
                Err(e) => eprintln!("Warning: {}", e),
            }
        }
        v
    };
    let mut o = String::new();
    fmt::print_search_rows(&mut o, pkgs, &term, !p.flag("installed"), quiet);
    out(&o);
    0
}

fn merge_local(db: &Database, mut info: freeman_db::PkgInfo) -> freeman_db::PkgInfo {
    db.attach_installed(&mut info);
    info
}

fn cmd_info(rest: &[String]) -> i32 {
    if rest.is_empty() {
        out(&help::info());
        return 0;
    }
    let specs =
        [opt_f("aur", Some('a')), opt_f("no-aur", None), opt_f("help", Some('h'))];
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::info());
            return 0;
        }
    };
    if p.flag("help") || p.rest.is_empty() {
        out(&help::info());
        return 0;
    }
    let conf = load_freeman_conf();
    let aur_on = if p.flag("no-aur") {
        false
    } else {
        p.flag("aur") || conf.enable_aur
    };
    let mut status = 0;
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    let installed_names: HashSet<String> = db.installed().into_iter().map(|p| p.name).collect();
    let installed_provides: HashSet<String> = db
        .installed()
        .into_iter()
        .flat_map(|p| p.provides.into_iter())
        .map(fmt_dep_name)
        .collect();
    for target in &p.rest {
        let mut aur_pkg = None;
        if aur_on {
            match aur_info(&[target.as_str()]) {
                Ok(m) => aur_pkg = m.get(target).cloned(),
                Err(e) => eprintln!("Warning: {}", e),
            }
        }
        match aur_pkg {
            None => match db.sync_newest(target).or_else(|| db.local_pkg(target)) {
                Some(info) => {
                    let mut o = String::new();
                    fmt::info_block(
                        &mut o,
                        &info,
                        None,
                        &installed_names,
                        &installed_provides,
                    );
                    out(&o);
                }
                None => status = err_target(target),
            },
            Some(ap) => {
                let is_installed = installed_names.contains(target);
                let sync = db.sync_newest(target);
                if !is_installed {
                    if let Some(info) = sync {
                        let mut o = String::new();
                        fmt::info_block(
                            &mut o,
                            &info,
                            None,
                            &installed_names,
                            &installed_provides,
                        );
                        out(&o);
                    }
                    let mut o = String::new();
                    fmt::info_block(
                        &mut o,
                        &ap.to_pkg_info(),
                        Some(&ap),
                        &installed_names,
                        &installed_provides,
                    );
                    out(&o);
                } else if sync.is_some() {
                    let info = sync.unwrap();
                    let mut o = String::new();
                    fmt::info_block(&mut o, &info, None, &installed_names, &installed_provides);
                    out(&o);
                } else {
                    let merged = merge_local(&db, ap.to_pkg_info());
                    let mut o = String::new();
                    fmt::info_block(
                        &mut o,
                        &merged,
                        Some(&ap),
                        &installed_names,
                        &installed_provides,
                    );
                    out(&o);
                }
            }
        }
    }
    status
}


fn euid_is_root() -> bool {
    unsafe extern "C" {
        fn geteuid() -> u32;
    }
    unsafe { geteuid() == 0 }
}

fn apply_aurdest(conf: &mut PamacConf) {
    if let Some(a) = std::env::var_os("AURDEST") {
        conf.build_directory = a.to_string_lossy().into_owned();
        conf.keep_built_pkgs = true;
    }
}

fn stdin_is_tty() -> bool {
    unsafe extern "C" {
        fn isatty(fd: i32) -> i32;
    }
    unsafe { isatty(0) == 1 }
}

fn sudo_pacman(args: &[&str], no_confirm: bool) -> i32 {
    let mut full: Vec<String> = Vec::new();
    if !euid_is_root() {
        full.push("sudo".into());
        full.push("-E".into());
        if !stdin_is_tty() {
            full.push("-n".into());
        }
    }
    full.push("pacman".into());
    for a in args {
        full.push((*a).to_string());
    }
    if no_confirm {
        full.push("--noconfirm".into());
    }
    let st = std::process::Command::new(&full[0])
        .args(&full[1..])
        .status();
    match st {
        Ok(s) => s.code().unwrap_or(-1),
        Err(_) => {
            eprintln!("Error: failed to spawn pacman");
            1
        }
    }
}

fn load_targets_with_pacman(paths: &[PathBuf], as_deps: bool, as_explicit: bool, no_confirm: bool, dry_run: bool) -> i32 {
    if paths.is_empty() {
        return 0;
    }
    if dry_run {
        println!("To install:");
        for p in paths {
            println!("  {}", p.display());
        }
        return 0;
    }
    let str_paths: Vec<String> = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    let mut args: Vec<&str> = vec!["-U"];
    if as_deps && !as_explicit {
        args.push("--asdeps");
    }
    if as_explicit && !as_deps {
        args.push("--asexplicit");
    }
    args.extend(str_paths.iter().map(|s| s.as_str()));
    let rc = sudo_pacman(&args, no_confirm);
    if rc == 0 {
        println!("Transaction successfully finished.");
    }
    rc
}


fn clone_many(
    bases: &[String],
    builddir: &str,
    overwrite: bool,
    quiet: bool,
    status: &mut i32,
) -> Vec<(String, PathBuf)> {
    let mut cloned = Vec::new();
    for b in bases {
        println!("Cloning {b} build files...");
        match ensure_clone(b, std::path::Path::new(builddir), overwrite, quiet) {
            Ok(dir) => {
                if let Err(e) = regenerate_srcinfo(&dir) {
                    eprintln!("Error: {e}");
                    *status = 1;
                } else {
                    cloned.push((b.clone(), dir));
                }
            }
            Err(e) => {
                eprintln!("Error: {e}");
                *status = 1;
            }
        }
    }
    cloned
}

fn cmd_clone(rest: &[String]) -> i32 {
    let specs = [
        args::f("help", Some('h')),
        args::f("overwrite", None),
        args::f("recurse", Some('r')),
        args::s("builddir", None),
        args::f("quiet", Some('q')),
    ];
    if rest.is_empty() {
        out(&help::clone_());
        return 0;
    }
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::clone_());
            return 0;
        }
    };
    if p.flag("help") || p.rest.is_empty() {
        out(&help::clone_());
        return 0;
    }
    let mut conf = load_freeman_conf();
    apply_aurdest(&mut conf);
    let builddir = p
        .str_of("builddir")
        .map(|s| s.to_string())
        .unwrap_or_else(|| conf.build_directory.clone());
    let quiet = p.flag("quiet");
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    let targets = &p.rest;
    let infos = match aur_info(&targets.iter().map(|s| s.as_str()).collect::<Vec<_>>()) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Warning: {e}");
            return 1;
        }
    };
    let mut status = 0;
    let mut bases: Vec<String> = Vec::new();
    for t in targets {
        match infos.get(t) {
            None => status = err_target(t),
            Some(info) => {
                let b = info.packagebase.clone();
                if !bases.contains(&b) {
                    bases.push(b);
                }
            }
        }
    }
    let mut already: HashSet<String> = bases.iter().cloned().collect();
    let cloned = clone_many(&bases, &builddir, p.flag("overwrite"), quiet, &mut status);
    if p.flag("recurse") {
        let mut round: Vec<String> = Vec::new();
        for (base, dir) in &cloned {
            let _ = base;
            let Ok(text) = std::fs::read_to_string(dir.join(".SRCINFO")) else { continue };
            let Ok(si) = freeman_aur::SrcInfo::parse(&text, "x86_64") else { continue };
            for name in &si.pkgnames {
                for d in si.build_depends(name) {
                    let dn = dep_name(&d).to_string();
                    if !already.contains(&dn)
                        && !db.local_satisfies(&dn)
                        && !db.sync_satisfies(&dn)
                    {
                        already.insert(dn.clone());
                        round.push(dn);
                    }
                }
            }
        }
        while !round.is_empty() {
            let Ok(infos2) = aur_info(&round.iter().map(|s| s.as_str()).collect::<Vec<_>>()) else { break };
            let next_bases: Vec<String> = round
                .iter()
                .filter_map(|n| infos2.get(n))
                .map(|i| i.packagebase.clone())
                .filter(|b| !already.contains(b))
                .collect();
            for b in &next_bases {
                already.insert(b.clone());
            }
            if next_bases.is_empty() {
                break;
            }
            let more = clone_many(&next_bases, &builddir, p.flag("overwrite"), quiet, &mut status);
            let mut next_round: Vec<String> = Vec::new();
            for (_base, dir) in &more {
                let Ok(text) = std::fs::read_to_string(dir.join(".SRCINFO")) else { continue };
                let Ok(si) = freeman_aur::SrcInfo::parse(&text, "x86_64") else { continue };
                for name in &si.pkgnames {
                    for d in si.build_depends(name) {
                        let dn = dep_name(&d).to_string();
                        if !already.contains(&dn)
                            && !db.local_satisfies(&dn)
                            && !db.sync_satisfies(&dn)
                        {
                            already.insert(dn.clone());
                            next_round.push(dn);
                        }
                    }
                }
            }
            round = next_round;
        }
    }
    status
}

struct BuildOpts {
    keep_built: bool,
    no_confirm: bool,
    dry_run: bool,
    as_deps_targets: bool,
    as_explicit_targets: bool,
}

fn run_build_plan(
    plan: &freeman_aur::Plan,
    explicit_targets: &[String],
    builddir: &str,
    opts: &BuildOpts,
) -> i32 {
    if plan.order.is_empty() && plan.repo_deps.is_empty() {
        println!("Nothing to do.");
        return 0;
    }
    if opts.dry_run {
        if !plan.order.is_empty() {
            println!("To build:");
            for n in &plan.order {
                println!("  {} {}", n.info.name, n.info.version);
            }
        }
        if !plan.repo_deps.is_empty() {
            println!("To install (required dependencies):");
            for d in &plan.repo_deps {
                println!("  {d}");
            }
        }
        return 0;
    }
    let bd = std::path::Path::new(builddir);
    let mut built: Vec<(PathBuf, String, bool)> = Vec::new();
    for node in &plan.order {
        println!("Cloning {} build files...", node.base);
        let dir = match ensure_clone(&node.base, bd, false, false) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("Error: {e}");
                return 1;
            }
        };
        println!("Building {}...", node.info.name);
        if let Err(e) = regenerate_srcinfo(&dir) {
            eprintln!("Error: {e}");
            return 1;
        }
        match makepkg_build(&dir, opts.keep_built, &[]) {
            Ok(0) => {}
            Ok(_) => {
                eprintln!("Error: Failed to build {}", node.info.name);
                return 1;
            }
            Err(e) => {
                eprintln!("Error: {e}");
                return 1;
            }
        }
        let files = match packagelist(&dir, opts.keep_built) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("Error: {e}");
                return 1;
            }
        };
        for f in files {
            let fname = f.file_name().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if let Some(name) = pkgname_from_filename(&fname) {
                let is_dep = !explicit_targets.contains(&name);
                built.push((f, name, is_dep));
            }
        }
    }
    if !plan.repo_deps.is_empty() {
        let mut a: Vec<&str> = vec!["-S", "--needed", "--asdeps"];
        a.extend(plan.repo_deps.iter().map(|s| s.as_str()));
        let rc = sudo_pacman(&a, opts.no_confirm);
        if rc != 0 {
            return 1;
        }
    }
    let dep_files: Vec<PathBuf> = built.iter().filter(|(_, _, d)| *d).map(|(p, _, _)| p.clone()).collect();
    let exp_files: Vec<PathBuf> =
        built.iter().filter(|(_, _, d)| !*d).map(|(p, _, _)| p.clone()).collect();
    if !dep_files.is_empty() {
        let str_paths: Vec<String> =
            dep_files.iter().map(|p| p.to_string_lossy().into_owned()).collect();
        let mut a: Vec<&str> = vec!["-U", "--asdeps"];
        a.extend(str_paths.iter().map(|s| s.as_str()));
        let rc = sudo_pacman(&a, opts.no_confirm);
        if rc != 0 {
            return 1;
        }
    }
    if !exp_files.is_empty() {
        let str_paths: Vec<String> =
            exp_files.iter().map(|p| p.to_string_lossy().into_owned()).collect();
        let mut a: Vec<&str> = vec!["-U"];
        if opts.as_deps_targets {
            a.push("--asdeps");
        }
        if opts.as_explicit_targets {
            a.push("--asexplicit");
        }
        a.extend(str_paths.iter().map(|s| s.as_str()));
        let rc = sudo_pacman(&a, opts.no_confirm);
        if rc != 0 {
            return 1;
        }
    }
    if !opts.keep_built {
        for (path, _, _) in &built {
            let _ = std::fs::remove_file(path);
        }
    }
    println!("Transaction successfully finished.");
    0
}

fn root_build_warnings(conf: &PamacConf, builddir_override: Option<&str>) -> String {
    if euid_is_root() {
        println!("Warning: Building packages as dynamic user");
        println!("Warning: Setting build directory to /var/cache/freeman");
        "/var/cache/freeman".into()
    } else {
        builddir_override
            .map(|s| s.to_string())
            .unwrap_or_else(|| conf.build_directory.clone())
    }
}

fn cmd_build(rest: &[String]) -> i32 {
    let specs = [
        args::f("help", Some('h')),
        args::f("no-clone", None),
        args::f("no-confirm", None),
        args::f("keep", Some('k')),
        args::f("no-keep", None),
        args::s("builddir", None),
        args::f("dry-run", Some('d')),
    ];
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::build());
            return 0;
        }
    };
    if p.flag("help") {
        out(&help::build());
        return 0;
    }
    if p.flag("keep") && p.flag("no-keep") {
        out(&help::build());
        return 0;
    }
    let mut conf = load_freeman_conf();
    if p.flag("keep") {
        conf.keep_built_pkgs = true;
    }
    if p.flag("no-keep") {
        conf.keep_built_pkgs = false;
    }
    let builddir_override = p.str_of("builddir").map(|s| s.to_string());
    if builddir_override.is_some() && !euid_is_root() {
        conf.build_directory = builddir_override.clone().unwrap();
        conf.keep_built_pkgs = true;
    }
    apply_aurdest(&mut conf);
    let builddir = root_build_warnings(&conf, builddir_override.as_deref());

    let opts = BuildOpts {
        keep_built: conf.keep_built_pkgs,
        no_confirm: p.flag("no-confirm"),
        dry_run: p.flag("dry-run"),
        as_deps_targets: false,
        as_explicit_targets: false,
    };

    if p.rest.is_empty() {
        let cwd = std::env::current_dir().map_err(|_| 1).unwrap_or_default();
        let pkgbuild = cwd.join("PKGBUILD");
        if !pkgbuild.exists() {
            println!("No PKGBUILD file found in current directory");
            return 0;
        }
        let src = match regenerate_srcinfo(&cwd) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Error: {e}");
                return 1;
            }
        };
        let names: Vec<String> = src
            .lines()
            .filter_map(|l| l.strip_prefix("pkgname = "))
            .map(|s| s.trim().to_string())
            .collect();
        if names.is_empty() {
            eprintln!("Error: no pkgname in PKGBUILD");
            return 1;
        }
        let infos = match aur_info(&names.iter().map(|s| s.as_str()).collect::<Vec<_>>()) {
            Ok(m) => m,
            Err(_) => Default::default(),
        };
        let _ = infos;
        println!("Building local PKGBUILD from {}", cwd.display());
        match makepkg_build(&cwd, true, &[]) {
            Ok(0) => println!("Transaction successfully finished."),
            Ok(_) => {
                eprintln!("Error: build failed");
                return 1;
            }
            Err(e) => {
                eprintln!("Error: {e}");
                return 1;
            }
        }
        return 0;
    }

    if p.flag("no-clone") {
        let bd = std::path::Path::new(&builddir);
        for t in &p.rest {
            let dir = bd.join(t);
            println!("Building {}...", t);
            match makepkg_build(&dir, opts.keep_built, &[]) {
                Ok(0) => {}
                _ => {
                    eprintln!("Error: Failed to build {t}");
                    return 1;
                }
            }
        }
        println!("Transaction successfully finished.");
        return 0;
    }

    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    let infos = match aur_info(&p.rest.iter().map(|s| s.as_str()).collect::<Vec<_>>()) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Error: {e}");
            return 1;
        }
    };
    let mut resolved: Vec<String> = Vec::new();
    for t in &p.rest {
        if infos.contains_key(t) {
            resolved.push(t.clone());
            continue;
        }
        match search_by_provides(t) {
            Ok(list) if !list.is_empty() => resolved.push(list[0].name.clone()),
            _ => {
                return err_target(t);
            }
        }
    }
    let plan = match freeman_aur::resolve(&resolved, &db) {
        Ok(pl) => pl,
        Err(e) => {
            eprintln!("Error: {e}");
            return 1;
        }
    };
    run_build_plan(&plan, &resolved, &builddir, &opts)
}


fn cmd_install(rest: &[String]) -> i32 {
    let specs = [
        args::f("help", Some('h')),
        args::f("no-confirm", None),
        args::f("upgrade", None),
        args::f("no-upgrade", None),
        args::f("download-only", Some('w')),
        args::f("as-deps", None),
        args::f("as-explicit", None),
        args::s("overwrite", None),
        args::s("ignore", None),
        args::f("dry-run", Some('d')),
    ];
    if rest.is_empty() {
        out(&help::install());
        return 0;
    }
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::install());
            return 0;
        }
    };
    if p.flag("help")
        || p.rest.is_empty()
        || (p.flag("as-deps") && p.flag("as-explicit"))
        || (p.flag("upgrade") && p.flag("no-upgrade"))
    {
        out(&help::install());
        return 0;
    }
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    let mut conf = load_freeman_conf();
    apply_aurdest(&mut conf);

    let mut to_load: Vec<PathBuf> = Vec::new();
    let mut remote: Vec<String> = Vec::new();
    let mut daemon_needed: Vec<String> = Vec::new();
    let mut aur_targets: Vec<String> = Vec::new();

    for t in &p.rest {
        if t.contains(".pkg.tar") {
            if t.contains("://") {
                match t.strip_prefix("file://") {
                    Some(local) => to_load.push(PathBuf::from(local)),
                    None => remote.push(t.clone()),
                }
            } else {
                to_load.push(PathBuf::from(t));
            }
        } else if db.sync_satisfies(t) {
            daemon_needed.push(t.clone());
        } else if db.groups().iter().any(|g| g == t) {
            daemon_needed.push(t.clone());
        } else {
            let found_in_aur = match aur_info(&[t.as_str()]) {
                Ok(m) if m.contains_key(t) => true,
                Ok(_) => false,
                Err(e) => {
                    eprintln!("Warning: {e}");
                    false
                }
            };
            if found_in_aur {
                println!("Warning: {t} is only available from AUR");
                aur_targets.push(t.clone());
            } else {
                return err_target(t);
            }
        }
    }

    if !daemon_needed.is_empty() || !remote.is_empty() {
        eprintln!(
            "{}",
            "freeman: repository installs still need the transaction daemon (pending); nothing was changed"
        );
        for d in daemon_needed.iter().chain(remote.iter()) {
            eprintln!("freeman: needs daemon: {d}");
        }
        return 1;
    }

    let mut status = 0;
    if !to_load.is_empty() {
        status |= load_targets_with_pacman(
            &to_load,
            p.flag("as-deps"),
            p.flag("as-explicit"),
            p.flag("no-confirm"),
            p.flag("dry-run"),
        );
    }

    if !aur_targets.is_empty() {
        let plan = match freeman_aur::resolve(&aur_targets, &db) {
            Ok(pl) => pl,
            Err(e) => {
                eprintln!("Error: {e}");
                return 1;
            }
        };
        let opts = BuildOpts {
            keep_built: conf.keep_built_pkgs,
            no_confirm: p.flag("no-confirm"),
            dry_run: p.flag("dry-run"),
            as_deps_targets: p.flag("as-deps"),
            as_explicit_targets: p.flag("as-explicit"),
        };
        let builddir = conf.build_directory.clone();
        status |= run_build_plan(&plan, &aur_targets, &builddir, &opts);
    }

    if to_load.is_empty() && aur_targets.is_empty() {
        println!("Nothing to do.");
    }
    status
}


fn fmt_dep_name(dep: String) -> String {
    match dep.find(|c| c == '<' || c == '>' || c == '=') {
        Some(i) => dep[..i].to_string(),
        None => dep,
    }
}

fn cmd_list(rest: &[String]) -> i32 {
    let specs = [
        opt_f("installed", Some('i')),
        opt_f("explicitly-installed", Some('e')),
        opt_f("orphans", Some('o')),
        opt_f("foreign", Some('m')),
        opt_f("groups", Some('g')),
        opt_f("repos", Some('r')),
        opt_f("files", Some('f')),
        opt_f("quiet", Some('q')),
        opt_f("help", Some('h')),
    ];
    let bare = rest.is_empty();
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::list());
            return 0;
        }
    };
    if p.flag("help") {
        out(&help::list());
        return 0;
    }
    let quiet = p.flag("quiet");
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    if bare {
        let pkgs = db.installed();
        let mut o = String::new();
        fmt::print_list_rows(&mut o, &pkgs, false, quiet);
        out(&o);
        return 0;
    }
    if p.rest.len() > 1 {
        out(&help::list());
        return 0;
    }
    let mut o = String::new();
    let mut status = 0;
    if p.flag("installed") {
        if p.flag("orphans") && !(p.flag("foreign") || p.flag("groups") || p.flag("repos") || p.flag("files")) {
            let pkgs = db.orphans();
            fmt::print_list_rows(&mut o, &pkgs, false, quiet);
        } else if p.flag("foreign") || p.flag("groups") || p.flag("repos") || p.flag("files") {
            out(&help::list());
            return 0;
        } else {
            let pkgs = db.installed();
            fmt::print_list_rows(&mut o, &pkgs, false, quiet);
        }
    } else if p.flag("explicitly-installed") {
        if p.flag("orphans") || p.flag("foreign") || p.flag("groups") || p.flag("repos") || p.flag("files") {
            out(&help::list());
            return 0;
        }
        let pkgs = db.explicit();
        fmt::print_list_rows(&mut o, &pkgs, false, quiet);
    } else if p.flag("orphans") {
        if p.flag("foreign") || p.flag("groups") || p.flag("repos") || p.flag("files") {
            out(&help::list());
            return 0;
        }
        let pkgs = db.orphans();
        fmt::print_list_rows(&mut o, &pkgs, false, quiet);
    } else if p.flag("foreign") {
        if p.flag("groups") || p.flag("repos") || p.flag("files") {
            out(&help::list());
            return 0;
        }
        let pkgs = db.foreign();
        fmt::print_list_rows(&mut o, &pkgs, false, quiet);
    } else if p.flag("groups") {
        if p.flag("repos") || p.flag("files") {
            out(&help::list());
            return 0;
        }
        let names: Vec<String> = if p.rest.is_empty() { Vec::new() } else { p.rest.clone() };
        if names.is_empty() {
            for g in db.groups() {
                o.push_str(&g);
                o.push('\n');
            }
        } else {
            for name in names {
                match db.group_pkgs(&name) {
                    None => {
                        if !quiet {
                            status = err_target(&name);
                        }
                    }
                    Some(pkgs) => fmt::print_list_rows(&mut o, &pkgs, true, quiet),
                }
                o.push('\n');
            }
        }
    } else if p.flag("repos") {
        if p.flag("files") {
            out(&help::list());
            return 0;
        }
        let names: Vec<String> = if p.rest.is_empty() { Vec::new() } else { p.rest.clone() };
        if names.is_empty() {
            for r in db.repos_names() {
                o.push_str(&r);
                o.push('\n');
            }
        } else {
            for name in names {
                match db.repo_pkgs(&name) {
                    None => {
                        if !quiet {
                            status = err_target(&name);
                        }
                    }
                    Some(pkgs) => fmt::print_list_rows(&mut o, &pkgs, true, quiet),
                }
                o.push('\n');
            }
        }
    } else if p.flag("files") {
        if p.rest.is_empty() {
            out(&help::list());
            return 0;
        }
        for name in &p.rest {
            match db.files_of(name) {
                None => {
                    if !quiet {
                        status = err_target(name);
                    }
                }
                Some(files) => {
                    for f in files {
                        o.push_str(&f);
                        o.push('\n');
                    }
                    o.push('\n');
                }
            }
        }
    } else {
        println!("Error");
        out(&help::list());
        return 0;
    }
    out(&o);
    status
}

#[derive(Clone)]
struct UpdateView {
    name: String,
    current: String,
    new: String,
    repo: String,
}

fn pad(s: &str, w: usize) -> String {
    let mut r = s.to_string();
    while r.chars().count() < w {
        r.push(' ');
    }
    r
}

fn cmd_checkupdates(rest: &[String]) -> i32 {
    let specs = [
        opt_f("quiet", Some('q')),
        opt_f("aur", Some('a')),
        opt_f("no-aur", None),
        opt_f("devel", None),
        opt_f("no-devel", None),
        opt_s("builddir", None),
        opt_f("refresh-tmp-files-dbs", None),
        opt_f("download-updates", None),
        opt_f("help", Some('h')),
        opt_i("unused-int", None),
    ];
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::checkupdates());
            return 0;
        }
    };
    if p.flag("help") {
        out(&help::checkupdates());
        return 0;
    }
    if p.flag("aur") && p.flag("no-aur") {
        out(&help::checkupdates());
        return 0;
    }
    if p.flag("no-aur") && p.flag("devel") {
        out(&help::checkupdates());
        return 0;
    }
    if p.flag("devel") && p.flag("no-devel") {
        out(&help::checkupdates());
        return 0;
    }
    if p.flag("download-updates") {
        eprintln!("Error: --download-updates requires the transaction daemon (not wired yet)");
        return 1;
    }
    let conf = load_freeman_conf();
    let aur_on = if p.flag("no-aur") {
        false
    } else {
        p.flag("aur") || conf.enable_aur
    };
    let quiet = p.flag("quiet");
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    let up = db.updates();
    let mut repos: Vec<UpdateView> = up
        .repos_updates
        .iter()
        .map(|u| UpdateView {
            name: u.name.clone(),
            current: u.current.clone(),
            new: u.new.clone(),
            repo: u.repo.clone(),
        })
        .collect();
    let mut ignored: Vec<UpdateView> = up
        .ignored_updates
        .iter()
        .map(|u| UpdateView {
            name: u.name.clone(),
            current: u.current.clone(),
            new: u.new.clone(),
            repo: u.repo.clone(),
        })
        .collect();

    let mut aur_updates: Vec<UpdateView> = Vec::new();
    let mut out_of_date: Vec<(String, String)> = Vec::new();
    if aur_on {
        let foreign: Vec<_> = {
            let all = db.installed();
            all.into_iter()
                .filter(|p| p.repo.is_none() && db.sync_newest(&p.name).is_none())
                .collect()
        };
        let names: Vec<&str> = foreign.iter().map(|p| p.name.as_str()).collect();
        match aur_info(&names) {
            Ok(map) => {
                for pkg in foreign {
                    if let Some(ap) = map.get(&pkg.name) {
                        if vercmp(&pkg.version, &ap.version) == std::cmp::Ordering::Less {
                            aur_updates.push(UpdateView {
                                name: pkg.name.clone(),
                                current: pkg.version.clone(),
                                new: ap.version.clone(),
                                repo: "AUR".into(),
                            });
                        }
                        if ap.outofdate.is_some() {
                            out_of_date.push((pkg.name.clone(), pkg.version.clone()));
                        }
                    }
                }
            }
            Err(e) => eprintln!("Warning: {}", e),
        }
        if p.flag("devel") {
            let builddir = p
                .str_of("builddir")
                .map(|x| x.to_string())
                .unwrap_or_else(|| conf.build_directory.clone());
            let foreign_vcs: Vec<_> = {
                let all = db.installed();
                all.into_iter()
                    .filter(|p| p.repo.is_none())
                    .filter(|p| is_vcs_package(&p.name, &p.version))
                    .collect()
            };
            for pkg in foreign_vcs {
                let dir_ok =
                    ensure_clone(&pkg.name, std::path::Path::new(&builddir), false, true);
                let dir = match dir_ok {
                    Ok(d) => d,
                    Err(_) => continue,
                };
                if let Ok(Some(new)) = devel_latest_version(&dir) {
                    if vercmp(&pkg.version, &new) == std::cmp::Ordering::Less {
                        aur_updates.push(UpdateView {
                            name: pkg.name.clone(),
                            current: pkg.version.clone(),
                            new,
                            repo: "AUR".into(),
                        });
                    }
                }
            }
        }
    }

    let total = repos.len() + aur_updates.len();
    if total == 0 {
        if quiet {
            return 0;
        }
        println!("Your system is up to date.");
        let ignored_nb = ignored.len();
        if ignored_nb > 0 || !out_of_date.is_empty() {
            let mut nl = 0;
            let mut il = 0;
            let mut vl = 0;
            for u in ignored.iter().chain(aur_updates.iter()) {
                nl = nl.max(u.name.chars().count());
                il = il.max(u.current.chars().count());
                vl = vl.max(u.new.chars().count());
            }
            if ignored_nb > 0 {
                let label = if ignored_nb == 1 {
                    format!("{} ignored update", ignored_nb)
                } else {
                    format!("{} ignored updates", ignored_nb)
                };
                println!("\n{}:", label);
                let mut o = String::new();
                for u in &ignored {
                    o.push_str(&format!(
                        "{}  {} -> {}  {}\n",
                        pad(&u.name, nl),
                        pad(&u.current, il),
                        pad(&u.new, vl),
                        u.repo
                    ));
                }
                out(&o);
            }
            if !out_of_date.is_empty() {
                println!("\nOut of Date:");
                let mut o = String::new();
                for (name, ver) in &out_of_date {
                    o.push_str(&format!(
                        "{}  {}  AUR\n",
                        pad(name, nl.max(name.chars().count())),
                        pad(ver, vl)
                    ));
                }
                out(&o);
            }
        }
        return 0;
    }

    for u in &repos {
        if conf_ignore(&conf, &u.name) {
            ignored.push(u.clone());
        }
    }
    repos.retain(|u| !conf_ignore(&conf, &u.name));

    let mut nl = 0;
    let mut il = 0;
    let mut vl = 0;
    for u in repos.iter().chain(ignored.iter()).chain(aur_updates.iter()) {
        nl = nl.max(u.name.len());
        il = il.max(u.current.len());
        vl = vl.max(u.new.len());
    }

    if quiet {
        let mut o = String::new();
        for u in repos.iter().chain(aur_updates.iter()) {
            o.push_str(&format!("{}  {} -> {}\n", u.name, u.current, u.new));
        }
        out(&o);
        return 100;
    }

    let label = if total == 1 {
        format!("{} available update", total)
    } else {
        format!("{} available updates", total)
    };
    let mut o = String::new();
    o.push_str(&format!("{}:\n", label));
    for u in repos.iter().chain(aur_updates.iter()) {
        o.push_str(&format!(
            "{}  {} -> {}  {}\n",
            pad(&u.name, nl),
            pad(&u.current, il),
            pad(&u.new, vl),
            u.repo
        ));
    }
    let ignored_nb = ignored.len();
    if ignored_nb > 0 {
        let label = if ignored_nb == 1 {
            format!("{} ignored update", ignored_nb)
        } else {
            format!("{} ignored updates", ignored_nb)
        };
        o.push_str(&format!("\n{}:\n", label));
        for u in &ignored {
            o.push_str(&format!(
                "{}  {} -> {}  {}\n",
                pad(&u.name, nl),
                pad(&u.current, il),
                pad(&u.new, vl),
                u.repo
            ));
        }
    }
    if !out_of_date.is_empty() {
        o.push_str("\nOut of Date:\n");
        for (name, ver) in &out_of_date {
            o.push_str(&format!("{}  {}  AUR\n", pad(name, nl), pad(ver, vl)));
        }
    }
    out(&o);
    100
}

fn conf_ignore(conf: &PamacConf, _name: &str) -> bool {
    let _ = conf;
    false
}

fn cmd_clean(rest: &[String]) -> i32 {
    let specs = [
        opt_f("verbose", Some('v')),
        opt_f("build-files", Some('b')),
        opt_f("no-confirm", None),
        opt_f("uninstalled", Some('u')),
        opt_f("dry-run", Some('d')),
        opt_i("keep", Some('k')),
        opt_f("help", Some('h')),
    ];
    let p = match parse(&specs, rest) {
        Ok(p) => p,
        Err(_) => {
            out(&help::clean());
            return 0;
        }
    };
    if p.flag("help") {
        out(&help::clean());
        return 0;
    }
    if p.flag("build-files") && !p.flag("dry-run") {
        eprintln!("{}", REFUSAL);
        return 1;
    }
    if !p.flag("dry-run") && !p.flag("no-confirm") {
        eprintln!("{}", REFUSAL);
        return 1;
    }
    if !p.flag("dry-run") && p.flag("no-confirm") {
        eprintln!("{}", REFUSAL);
        return 1;
    }
    let conf = load_freeman_conf();
    let keep_n = p.int_of("keep").unwrap_or(conf.keep_num_packages).max(0) as usize;
    let pconf = match PacmanConf::system() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Error: cannot read pacman.conf: {}", e);
            return 1;
        }
    };
    let db = match open_db() {
        Ok(d) => d,
        Err(c) => return c,
    };
    let installed_names: HashSet<String> = db.installed().into_iter().map(|p| p.name).collect();

    struct Entry {
        file: String,
        size: u64,
        key: String,
    }
    let mut groups: std::collections::HashMap<String, Vec<Entry>> = Default::default();
    for dir in &pconf.cache_dirs {
        let rd = match std::fs::read_dir(dir) {
            Ok(r) => r,
            Err(_) => continue,
        };
        for e in rd.flatten() {
            let fname = e.file_name().to_string_lossy().to_string();
            if !(fname.ends_with(".tar.zst")
                || fname.ends_with(".tar.xz")
                || fname.ends_with(".tar.gz")
                || fname.ends_with(".pkg.tar"))
                || fname.ends_with(".sig")
            {
                continue;
            }
            let size = e.metadata().map(|m| m.len()).unwrap_or(0);
            if let Some((name, key)) = split_pkg_filename(&fname) {
                groups.entry(name).or_default().push(Entry { file: fname, size, key });
            }
        }
    }
    let only_uninstalled = p.flag("uninstalled");
    let mut candidates: Vec<(String, u64)> = Vec::new();
    for (name, mut entries) in groups {
        entries.sort_by(|a, b| b.key.cmp(&a.key));
        if only_uninstalled && installed_names.contains(&name) {
            continue;
        }
        for e in entries.iter().skip(keep_n) {
            candidates.push((e.file.clone(), e.size));
        }
    }
    if only_uninstalled {
        println!("Remove only the versions of uninstalled packages");
    }
    println!("Number of versions of each package to keep in the cache: {}", keep_n);
    println!();
    if candidates.is_empty() {
        println!("To delete: 0 files");
        return 0;
    }
    let total: u64 = candidates.iter().map(|(_, s)| s).sum();
    if p.flag("verbose") {
        candidates.sort_by(|a, b| a.0.cmp(&b.0));
        for (f, _) in &candidates {
            println!("{}", f);
        }
        println!();
    }
    let nfiles = candidates.len();
    let size_str = freeman_core::format_size(total);
    let files_label = if nfiles == 1 { format!("{} file", nfiles) } else { format!("{} files", nfiles) };
    println!("To delete: {}  ({})", files_label, size_str);
    0
}

fn split_pkg_filename(fname: &str) -> Option<(String, String)> {
    let stem = fname.split(".pkg.tar").next()?;
    let parts: Vec<&str> = stem.split('-').collect();
    if parts.len() < 4 {
        return None;
    }
    let rel_arch = parts[parts.len() - 2..].join("-");
    let version = parts[parts.len() - 3].to_string();
    let name = parts[..parts.len() - 3].join("-");
    Some((name, format!("{}-{}", version, rel_arch)))
}

fn cmd_mutating(
    verb: &str,
    rest: &[String],
    conflict_pair: &[&str],
    help_fn: &(dyn Fn() -> String + Send + Sync),
    allow_empty_targets: bool,
) -> i32 {
    let specs: Vec<args::Spec> = vec![
        opt_f("no-confirm", None),
        opt_f("dry-run", Some('d')),
        opt_f("download-only", Some('w')),
        opt_f("as-deps", None),
        opt_f("as-explicit", None),
        opt_f("orphans", Some('o')),
        opt_f("no-orphans", None),
        opt_f("unneeded", Some('u')),
        opt_f("cascade", Some('c')),
        opt_f("no-save", Some('n')),
        opt_f("upgrade", None),
        opt_f("no-upgrade", None),
        opt_f("force-refresh", None),
        opt_f("no-refresh", None),
        opt_f("enable-downgrade", None),
        opt_f("disable-downgrade", None),
        opt_f("aur", Some('a')),
        opt_f("no-aur", None),
        opt_f("devel", None),
        opt_f("no-devel", None),
        opt_f("overwrite", None),
        opt_f("ignore", None),
        opt_f("builddir", None),
        opt_f("keep", Some('k')),
        opt_f("no-keep", None),
        opt_f("no-clone", None),
        opt_f("recurse", Some('r')),
        opt_f("quiet", Some('q')),
        args::Spec { long: "overwrite", short: None, kind: args::Kind::Str },
        args::Spec { long: "ignore", short: None, kind: args::Kind::Str },
        args::Spec { long: "builddir", short: None, kind: args::Kind::Str },
    ]
    .into_iter()
    .chain(vec![opt_f("x-none", None)])
    .collect();
    let _ = specs;
    if conflict_pair.len() == 2 {
        let has_a = rest.contains(&format!("--{}", conflict_pair[0]));
        let has_b = rest.contains(&format!("--{}", conflict_pair[1]));
        if has_a && has_b {
            out(&help_fn());
            return 0;
        }
    }
    if rest.is_empty() && !allow_empty_targets {
        out(&help_fn());
        return 0;
    }
    if verb == "remove" && rest.is_empty() {
        out(&help_fn());
        return 0;
    }
    eprintln!("{}", REFUSAL);
    1
}
