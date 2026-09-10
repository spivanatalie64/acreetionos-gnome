use std::time::{Duration, UNIX_EPOCH};

use freeman_core::{format_size, print_aligned, split_string};
use freeman_db::{AurPkg, PkgInfo};

pub fn relevance_cmp(a: &PkgInfo, b: &PkgInfo, search: &str) -> std::cmp::Ordering {
    let rank = |p: &PkgInfo| -> u8 {
        if p.name == search {
            0
        } else if p.name.starts_with(&format!("{}-", search)) {
            1
        } else if p.name.starts_with(search) {
            2
        } else if p.name.contains(search) {
            3
        } else {
            4
        }
    };
    let (ra, rb) = (rank(a), rank(b));
    if ra != rb {
        return ra.cmp(&rb);
    }
    let ia = a.is_installed();
    let ib = b.is_installed();
    if ia != ib {
        return ib.cmp(&ia);
    }
    a.name.to_lowercase().cmp(&b.name.to_lowercase())
}

pub fn print_search_rows(
    out: &mut String,
    mut pkgs: Vec<PkgInfo>,
    search: &str,
    print_installed: bool,
    quiet: bool,
) {
    pkgs.sort_by(|a, b| relevance_cmp(a, b, search));
    let width = freeman_core::term_width();
    if quiet {
        for p in &pkgs {
            out.push_str(&p.name);
            out.push('\n');
        }
        return;
    }
    let installed_label = "[Installed]";
    let installed_width = installed_label.chars().count() + 1;
    for p in pkgs.iter().rev() {
        let name = &p.name;
        let version = &p.version;
        let repo = p.repo.clone().unwrap_or_default();
        let mut available = width.saturating_sub(name.len() + version.len() + 4);
        let mut row = String::new();
        row.push_str(name);
        row.push_str("  ");
        row.push_str(version);
        row.push(' ');
        let is_inst = print_installed && p.installed.is_some();
        if is_inst {
            available = available.saturating_sub(installed_width);
            row.push_str(installed_label);
            row.push(' ');
        }
        row.push(' ');
        let diff = available.saturating_sub(repo.len());
        for _ in 0..diff {
            row.push(' ');
        }
        row.push_str(&repo);
        row.push('\n');
        out.push_str(&row);
        let desc = p.desc.clone().unwrap_or_default();
        let cuts = split_string(&desc, 4, width.saturating_sub(4));
        for cut in cuts {
            print_aligned(out, "", &cut, 4);
        }
    }
}

pub fn print_list_rows(out: &mut String, pkgs: &[PkgInfo], print_installed: bool, quiet: bool) {
    if quiet {
        for p in pkgs {
            out.push_str(&p.name);
            out.push('\n');
        }
        return;
    }
    let mut name_len = 0;
    let mut version_len = 0;
    let mut repo_len = 0;
    for p in pkgs {
        name_len = name_len.max(p.name.len());
        version_len = version_len.max(p.version.len());
        repo_len = repo_len.max(p.repo.as_deref().map(|r| r.len()).unwrap_or(0));
    }
    let installed_label = "[Installed]";
    let installed_width = installed_label.chars().count() + 1;
    for p in pkgs {
        let mut row = String::new();
        row.push_str(&p.name);
        let diff = if print_installed && p.installed.is_none() {
            (name_len + installed_width).saturating_sub(p.name.len())
        } else {
            name_len.saturating_sub(p.name.len())
        };
        for _ in 0..diff {
            row.push(' ');
        }
        if print_installed && p.installed.is_some() {
            row.push_str(installed_label);
            row.push(' ');
        }
        let repo = p.repo.clone().unwrap_or_default();
        let size = if p.isize == 0 { String::new() } else { format_size(p.isize as u64) };
        row.push_str(&format!(
            "{:<vw$}  {:<rw$}  {}\n",
            p.version,
            repo,
            size,
            vw = version_len,
            rw = repo_len
        ));
        out.push_str(&row);
    }
}

const LABELS: [&str; 29] = [
    "Name",
    "Version",
    "Description",
    "URL",
    "Licenses",
    "Repository",
    "Installed Size",
    "Groups",
    "Depends On",
    "Optional Dependencies",
    "Make Dependencies",
    "Check Dependencies",
    "Required By",
    "Optional For",
    "Provides",
    "Replaces",
    "Conflicts With",
    "Packager",
    "Build Date",
    "Install Date",
    "Install Reason",
    "Validated By",
    "Backup files",
    "Package Base",
    "Maintainer",
    "First Submitted",
    "Last Modified",
    "Votes",
    "Out of Date",
];

fn property(out: &mut String, prop: &str, val: Option<&str>, width: usize) {
    match val {
        None => print_aligned(out, prop, " : None", width),
        Some(v) => {
            let cuts = split_string(v, width + 3, freeman_core::term_width());
            match cuts.first() {
                Some(first) => {
                    print_aligned(out, prop, &format!(" : {}", first), width);
                    for cont in cuts.iter().skip(1) {
                        print_aligned(out, "", cont, width + 3);
                    }
                }
                None => print_aligned(out, prop, " : ", width),
            }
        }
    }
}

fn property_list(out: &mut String, prop: &str, vals: &[String], width: usize) {
    if vals.is_empty() {
        property(out, prop, Some("--"), width);
    } else {
        property(out, prop, Some(&vals.join(" ")), width);
    }
}

fn format_date(ts: i64) -> String {
    let t = UNIX_EPOCH + Duration::from_secs(ts.max(0) as u64);
    match humantime_format(t) {
        Some(s) => s,
        None => "Unknown".into(),
    }
}

fn humantime_format(t: std::time::SystemTime) -> Option<String> {
    let secs = t.duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    let days = secs.div_euclid(86400);
    let rem = secs.rem_euclid(86400);
    let (y, m, d) = civil_from_days(days);
    let (wd,) = weekday(days);
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    const DAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    let hour = rem / 3600;
    let min = (rem % 3600) / 60;
    let sec = rem % 60;
    Some(format!(
        "{} {} {:2} {:02}:{:02}:{:02} {}",
        DAYS[wd],
        MONTHS[(m - 1) as usize],
        d,
        hour,
        min,
        sec,
        y
    ))
}

fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn weekday(days: i64) -> (usize,) {
    ((days.rem_euclid(7)) as usize,)
}

#[allow(clippy::too_many_arguments)]
pub fn info_block(
    out: &mut String,
    pkg: &PkgInfo,
    aur: Option<&AurPkg>,
    installed_names: &std::collections::HashSet<String>,
    installed_provides: &std::collections::HashSet<String>,
) {
    let max_length = LABELS.iter().map(|l| l.chars().count()).max().unwrap_or(0);
    let inst = pkg.installed.clone();

    property(out, LABELS[0], Some(&pkg.name), max_length);
    if let Some(a) = aur {
        if a.packagebase != pkg.name {
            property(out, LABELS[23], Some(&a.packagebase), max_length);
        }
    }
    property(
        out,
        LABELS[1],
        Some(inst.as_deref().unwrap_or(&pkg.version)),
        max_length,
    );
    property(out, LABELS[2], pkg.desc.as_deref(), max_length);
    property(out, LABELS[3], pkg.url.as_deref(), max_length);
    if !pkg.licenses.is_empty() {
        property(out, LABELS[4], Some(&pkg.licenses.join(" ")), max_length);
    } else {
        property(out, LABELS[4], Some("Unknown"), max_length);
    }
    property(out, LABELS[5], pkg.repo.as_deref(), max_length);
    if pkg.isize != 0 && pkg.is_installed() {
        property(out, LABELS[6], Some(&format_size(pkg.isize as u64)), max_length);
    }
    property_list(out, LABELS[7], &pkg.groups, max_length);
    property_list(out, LABELS[8], &pkg.depends, max_length);
    if !pkg.optdepends.is_empty() {
        let mut first = true;
        for od in &pkg.optdepends {
            let depname = dep_name(od);
            let satisfied = installed_names.contains(depname) || installed_provides.contains(depname);
            let text = if satisfied {
                format!("{} [Installed]", od)
            } else {
                od.clone()
            };
            if first {
                print_aligned(out, LABELS[9], &format!(" : {}", text), max_length);
                first = false;
            } else {
                print_aligned(out, "", &text, max_length + 3);
            }
        }
    } else {
        property(out, LABELS[9], Some("--"), max_length);
    }
    if aur.is_some() {
        property_list(out, LABELS[10], &pkg.makedepends, max_length);
        property_list(out, LABELS[11], &pkg.checkdepends, max_length);
    }
    if pkg.is_installed() {
        property_list(out, LABELS[12], &pkg.requiredby, max_length);
        property_list(out, LABELS[13], &pkg.optionalfor, max_length);
    }
    property_list(out, LABELS[14], &pkg.provides, max_length);
    property_list(out, LABELS[15], &pkg.replaces, max_length);
    property_list(out, LABELS[16], &pkg.conflicts, max_length);
    if pkg.is_installed() || aur.is_none() {
        property(out, LABELS[17], pkg.packager.as_deref().or(Some("Unknown")), max_length);
    }
    if let Some(a) = aur {
        property(out, LABELS[24], a.maintainer.as_deref(), max_length);
        property(
            out,
            LABELS[25],
            a.first_submitted.map(format_date).as_deref().or(Some("Unknown")),
            max_length,
        );
        property(
            out,
            LABELS[26],
            a.last_modified.map(format_date).as_deref().or(Some("Unknown")),
            max_length,
        );
        property(out, LABELS[27], Some(&a.numvotes.to_string()), max_length);
        property(
            out,
            LABELS[28],
            a.outofdate.map(format_date).as_deref().or(Some("--")),
            max_length,
        );
    }
    if pkg.is_installed() || aur.is_none() {
        property(
            out,
            LABELS[18],
            pkg.build_date.map(format_date).as_deref().or(Some("Unknown")),
            max_length,
        );
    }
    if pkg.is_installed() {
        property(
            out,
            LABELS[19],
            pkg.install_date.map(format_date).as_deref().or(Some("Unknown")),
            max_length,
        );
        let reason = match pkg.explicit {
            Some(true) => Some("Explicitly installed"),
            Some(false) => Some("Installed as a dependency for another package"),
            None => None,
        };
        property(out, LABELS[20], reason.or(Some("Unknown")), max_length);
    }
    if pkg.is_installed() || aur.is_none() {
        if !pkg.validations.is_empty() {
            property(out, LABELS[21], Some(&pkg.validations.join("  ")), max_length);
        } else {
            property(out, LABELS[21], Some("Unknown"), max_length);
        }
    }
    if pkg.is_installed() {
        property_list(out, LABELS[22], &pkg.backups, max_length);
    }
    out.push('\n');
}

fn dep_name(dep: &str) -> &str {
    match dep.find(|c| c == '<' || c == '>' || c == '=' || c == ' ') {
        Some(i) => &dep[..i],
        None => dep,
    }
}
