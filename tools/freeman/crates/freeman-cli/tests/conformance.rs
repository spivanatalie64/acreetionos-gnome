use std::process::Command;

fn run(args: &[&str]) -> (String, i32) {
    let bin = env!("CARGO_BIN_EXE_pamac");
    let out = Command::new(bin).args(args).output().expect("spawn");
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        out.status.code().unwrap_or(-1),
    )
}

#[test]
 fn bare_invocation_prints_general_help_exit_zero() {
    let (out, code) = run(&[]);
    assert!(out.starts_with("Available actions:\n"));
    assert!(out.contains("  pamac update,upgrade [--check|--apply]\n"));
    assert!(out.contains("  pamac --version     \n"));
    assert_eq!(code, 0);
}

#[test]
fn version_matches_compat_format() {
    let (out, code) = run(&["--version"]);
    assert!(out.starts_with("pamac-cli 11.7.5-freeman  -  libpamac 11.7.5-freeman\n"));
    assert!(out.ends_with("GNU GPL.\n"));
    assert_eq!(code, 0);
}

#[test]
fn help_for_each_verb() {
    let cases: [(&str, &str); 6] = [
        ("search", "Search for packages or files, multiple search terms can be specified"),
        ("info", "Display package details, multiple packages can be specified"),
        ("list", "List packages, groups, repositories or files"),
        ("install", "Install packages from repositories, path or url"),
        ("checkupdates", "Safely check for updates without modifiying the databases"),
        ("clean", "Clean packages cache or build files"),
    ];
    for (verb, anchor) in cases {
        let (h1, c1) = run(&[verb, "--help"]);
        assert_eq!(c1, 0, "{}", verb);
        assert!(h1.contains(anchor), "{}", verb);

        let (h2, c2) = run(&["--help", verb]);
        assert_eq!(c2, 0, "{}", verb);
        assert!(h2.contains(anchor), "{}", verb);
        assert_eq!(h1, h2, "{}", verb);
    }
}

#[test]
fn list_quiet_without_selector_reproduces_upstream_error_quirk() {
    let (out, code) = run(&["list", "-q"]);
    assert!(out.starts_with("Error\n"));
    assert!(out.contains("pamac list [options]"));
    assert_eq!(code, 0);
}

#[test]
fn unknown_verb_shows_help_exit_zero_like_upstream() {
    let (out, code) = run(&["definitely-not-a-verb"]);
    assert!(out.starts_with("Available actions:\n"));
    assert_eq!(code, 0);
}

#[test]
fn unknown_option_shows_verb_help_exit_zero_like_upstream() {
    let (out, code) = run(&["search", "--bogus-flag", "x"]);
    assert!(out.starts_with("Search for packages"));
    assert_eq!(code, 0);
}

#[test]
fn install_conflicting_reason_flags_show_help_not_refusal() {
    let (out, code) = run(&["install", "--as-deps", "--as-explicit", "pkg"]);
    assert!(out.starts_with("Install packages from repositories"));
    assert_eq!(code, 0);
}

#[test]
fn daemon_gated_verbs_still_refuse() {
    for args in [vec!["remove", "vim"], vec!["upgrade"], vec!["reinstall", "bash"]] {
        let (_, code) = run(&args);
        assert_eq!(code, 1, "{:?}", args);
    }
}

#[test]
fn repository_install_targets_refuse_with_daemon_message() {
    let (_, code) = run(&["install", "bash"]);
    assert_eq!(code, 1);
}

#[test]
fn aur_only_target_routes_to_builder_not_daemon_error() {
    let out = Command::new(env!("CARGO_BIN_EXE_pamac"))
        .args(["install", "ctags-from-aur-not-real-zz"])
        .output()
        .expect("spawn");
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(text.contains("target not found"), "got: {text}");
}
