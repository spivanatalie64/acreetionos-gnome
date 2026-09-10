use freeman_core::{print_aligned, split_string};

fn block(out: &mut String, title: &str) {
    out.push_str(title);
    out.push_str("\n\n");
}

fn usage_line(out: &mut String, line: &str) {
    out.push_str(line);
    out.push_str("\n\n");
}

pub fn general() -> String {
    let mut o = String::new();
    o.push_str("Available actions:\n");
    let actions: [(&str, &str, bool); 13] = [
        ("--version", "", false),
        ("--help, -h", " [action]", false),
        ("search", " [options] <package(s)>", false),
        ("list", " [options]", false),
        ("info", " [options] <package(s)>", false),
        ("install", " [options] <package(s)>", false),
        ("reinstall", " [options] <package(s)>", false),
        ("remove", " [options] [package(s)]", false),
        ("checkupdates", " [options]", false),
        ("update,upgrade", " [--check|--apply]", false),
        ("clone", " [options] <package(s)>", false),
        ("build", " [options] [package(s)]", false),
        ("clean", " [options]", true),
    ];
    for (action, suffix, _) in actions.iter().take(12) {
        o.push_str(&format!("  freeman {:<14}{}\n", action, suffix));
    }
    o
}

fn options_block(out: &mut String, options: &[String], details: &[String]) {
    out.push_str("options:\n");
    let max_length = options.iter().map(|o| o.chars().count()).max().unwrap_or(0);
    for (opt, det) in options.iter().zip(details.iter()) {
        property(out, opt, Some(det), max_length);
    }
}

fn property(out: &mut String, prop: &str, val: Option<&str>, width: usize) {
    match val {
        None => print_aligned(out, prop, &format!(" : {}", "None"), width),
        Some(v) => {
            let cuts = split_string(v, width + 3, freeman_core::term_width());
            if let Some(first) = cuts.first() {
                print_aligned(out, prop, &format!(" : {}", first), width);
                for cont in cuts.iter().skip(1) {
                    print_aligned(out, "", cont, width + 3);
                }
            }
        }
    }
}

fn list_property(out: &mut String, prop: &str, vals: &[String], width: usize) {
    if vals.is_empty() {
        property(out, prop, Some("--"), width);
    } else {
        property(out, prop, Some(&vals.join(" ")), width);
    }
}

#[allow(dead_code)]
fn unused_helpers_guard(out: &mut String, vals: &[String], w: usize) {
    list_property(out, "", vals, w);
}

pub fn search() -> String {
    let mut o = String::new();
    block(
        &mut o,
        "Search for packages or files, multiple search terms can be specified",
    );
    usage_line(&mut o, "freeman search [options] <package(s)/file(s)>");
    options_block(
        &mut o,
        &[
            "  --installed, -i".into(),
            "  --repos, -r".into(),
            "  --aur, -a".into(),
            "  --no-aur".into(),
            "  --files, -f".into(),
            "  --quiet, -q".into(),
        ],
        &[
            "only search for installed packages".into(),
            "only search for packages in repositories".into(),
            "also search in AUR".into(),
            "do not search in AUR".into(),
            "search for packages which own the given filenames (filenames can be partial)".into(),
            "only print names".into(),
        ],
    );
    o
}

pub fn info() -> String {
    let mut o = String::new();
    block(
        &mut o,
        "Display package details, multiple packages can be specified",
    );
    usage_line(&mut o, "freeman info [options] <package(s)>");
    options_block(
        &mut o,
        &["  --aur, -a".into(), "  --no-aur".into()],
        &[
            "also search in AUR".into(),
            "do not search in AUR".into(),
        ],
    );
    o
}

pub fn list() -> String {
    let mut o = String::new();
    block(&mut o, "List packages, groups, repositories or files");
    usage_line(&mut o, "freeman list [options]");
    options_block(
        &mut o,
        &[
            "  --installed, -i".into(),
            "  --explicitly-installed, -e".into(),
            "  --orphans, -o".into(),
            "  --foreign, -m".into(),
            "  --groups, -g [group(s)]".into(),
            "  --repos, -r [repo(s)]".into(),
            "  --files, -f <package(s)>".into(),
            "  --quiet, -q".into(),
        ],
        &[
            "list installed packages".into(),
            "list explicitly installed packages".into(),
            "list packages that were installed as dependencies but are no longer required by any installed package".into(),
            "list packages that were not found in the repositories".into(),
            "list all packages that are members of the given groups, if no group is given list all groups".into(),
            "list all packages available in the given repos, if no repo is given list all repos".into(),
            "list files owned by the given packages".into(),
            "only print names".into(),
        ],
    );
    o
}

pub fn clone_() -> String {
    let mut o = String::new();
    block(&mut o, "Clone or sync packages build files from AUR");
    usage_line(&mut o, "freeman clone [options] <package(s)>");
    options_block(
        &mut o,
        &[
            "  --builddir <dir>".into(),
            "  --recurse, -r".into(),
            "  --quiet, -q".into(),
            "  --overwrite".into(),
        ],
        &[
            "build directory, if no directory is given the one specified in freeman.conf file is used".into(),
            "also clone needed dependencies".into(),
            "do not print any output".into(),
            "overwrite existing files".into(),
        ],
    );
    o
}

pub fn build() -> String {
    let mut o = String::new();
    block(&mut o, "Build packages from AUR and install them with their dependencies");
    o.push_str("If no package name is given, use the PKGBUILD file in the current directory\n");
    o.push_str("The build directory will be the parent directory, --builddir option will be ignored\n");
    o.push_str("and --no-clone option will be enforced\n\n");
    usage_line(&mut o, "freeman build [options] [package(s)]");
    options_block(
        &mut o,
        &[
            "  --builddir <dir>".into(),
            "  --keep, -k".into(),
            "  --no-keep".into(),
            "  --dry-run, -d".into(),
            "  --no-clone".into(),
            "  --no-confirm".into(),
        ],
        &[
            "build directory, if no directory is given the one specified in freeman.conf file is used".into(),
            "keep built packages in cache after installation".into(),
            "do not keep built packages in cache after installation".into(),
            "only print what would be done but do not run the transaction".into(),
            "do not clone build files from AUR, only use local files".into(),
            "bypass any and all confirmation messages".into(),
        ],
    );
    o
}

pub fn install() -> String {
    let mut o = String::new();
    block(&mut o, "Install packages from repositories, path or url");
    usage_line(&mut o, "freeman install [options] <package(s),group(s)>");
    options_block(
        &mut o,
        &[
            "  --ignore <package(s)>".into(),
            "  --overwrite <glob>".into(),
            "  --download-only, -w".into(),
            "  --dry-run, -d".into(),
            "  --as-deps".into(),
            "  --as-explicit".into(),
            "  --upgrade".into(),
            "  --no-upgrade".into(),
            "  --no-confirm".into(),
        ],
        &[
            "ignore a package upgrade, multiple packages can be specified by separating them with a comma".into(),
            "overwrite conflicting files, multiple patterns can be specified by separating them with a comma".into(),
            "download all packages but do not install/upgrade anything".into(),
            "only print what would be done but do not run the transaction".into(),
            "mark all packages installed as a dependency".into(),
            "mark all packages explicitly installed".into(),
            "check for updates".into(),
            "do not check for updates".into(),
            "bypass any and all confirmation messages".into(),
        ],
    );
    o
}

pub fn reinstall() -> String {
    let mut o = String::new();
    block(&mut o, "Reinstall packages");
    usage_line(&mut o, "freeman reinstall <package(s),group(s)>");
    options_block(
        &mut o,
        &[
            "  --overwrite <glob>".into(),
            "  --download-only, -w".into(),
            "  --as-deps".into(),
            "  --as-explicit".into(),
            "  --no-confirm".into(),
        ],
        &[
            "overwrite conflicting files, multiple patterns can be specified by separating them with a comma".into(),
            "download all packages but do not install/upgrade anything".into(),
            "mark all packages installed as a dependency".into(),
            "mark all packages explicitly installed".into(),
            "bypass any and all confirmation messages".into(),
        ],
    );
    o
}

pub fn remove() -> String {
    let mut o = String::new();
    block(&mut o, "Remove packages");
    usage_line(&mut o, "freeman remove [options] [package(s),group(s)]");
    options_block(
        &mut o,
        &[
            "  --unneeded, -u".into(),
            "  --cascade, -c".into(),
            "  --orphans, -o".into(),
            "  --no-orphans".into(),
            "  --no-save, -n".into(),
            "  --dry-run, -d".into(),
            "  --no-confirm".into(),
        ],
        &[
            "remove packages only if they are not required by any other packages".into(),
            "remove all target packages, as well as all packages that depend on one or more target packages".into(),
            "remove dependencies that are not required by other packages, if this option is used without package name remove all orphans".into(),
            "do not remove dependencies that are not required by other packages".into(),
            "ignore files backup".into(),
            "only print what would be done but do not run the transaction".into(),
            "bypass any and all confirmation messages".into(),
        ],
    );
    o
}

pub fn checkupdates() -> String {
    let mut o = String::new();
    block(&mut o, "Safely check for updates without modifiying the databases");
    o.push_str("(Exit code is 100 if updates are available)\n\n");
    usage_line(&mut o, "freeman checkupdates [options]");
    options_block(
        &mut o,
        &[
            "  --builddir <dir>".into(),
            "  --aur, -a".into(),
            "  --no-aur".into(),
            "  --quiet, -q".into(),
            "  --devel".into(),
            "  --no-devel".into(),
        ],
        &[
            "build directory (use with --devel), if no directory is given the one specified in freeman.conf file is used".into(),
            "also check updates in AUR".into(),
            "do not check updates in AUR".into(),
            "only print one line per update".into(),
            "also check development packages updates (use with --aur)".into(),
            "do not check development packages updates".into(),
        ],
    );
    o
}

pub fn upgrade() -> String {
    let mut o = String::new();
    block(&mut o, "Upgrade your system");
    usage_line(&mut o, "freeman upgrade,update [options]");
    options_block(
        &mut o,
        &[
            "  --force-refresh".into(),
            "  --no-refresh".into(),
            "  --enable-downgrade".into(),
            "  --disable-downgrade".into(),
            "  --download-only, -w".into(),
            "  --dry-run, -d".into(),
            "  --ignore <package(s)>".into(),
            "  --overwrite <glob>".into(),
            "  --no-confirm".into(),
            "  --aur, -a".into(),
            "  --no-aur".into(),
            "  --devel".into(),
            "  --no-devel".into(),
            "  --builddir <dir>".into(),
        ],
        &[
            "force the refresh of the databases".into(),
            "do not refresh the databases".into(),
            "enable package downgrades".into(),
            "disable package downgrades".into(),
            "download all packages but do not install/upgrade anything".into(),
            "only print what would be done but do not run the transaction".into(),
            "ignore a package upgrade, multiple packages can be specified by separating them with a comma".into(),
            "overwrite conflicting files, multiple patterns can be specified by separating them with a comma".into(),
            "bypass any and all confirmation messages".into(),
            "also upgrade packages installed from AUR".into(),
            "do not upgrade packages installed from AUR".into(),
            "also check development packages updates (use with --aur)".into(),
            "do not check development packages updates".into(),
            "build directory (use with --aur), if no directory is given the one specified in freeman.conf file is used".into(),
        ],
    );
    o
}

pub fn clean() -> String {
    let mut o = String::new();
    block(&mut o, "Clean packages cache or build files");
    usage_line(&mut o, "freeman clean [options]");
    options_block(
        &mut o,
        &[
            "  --keep, -k <number>".into(),
            "  --uninstalled, -u".into(),
            "  --build-files, -b".into(),
            "  --dry-run, -d".into(),
            "  --verbose, -v".into(),
            "  --no-confirm".into(),
        ],
        &[
            "specify how many versions of each package are kept in the cache directory".into(),
            "only target uninstalled packages".into(),
            "remove all build files, the build directory is the one specified in freeman.conf".into(),
            "do not remove files, only find candidate packages".into(),
            "also display all files names".into(),
            "bypass any and all confirmation messages".into(),
        ],
    );
    o
}
