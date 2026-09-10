use std::cmp::Ordering;

#[inline]
fn is_sep(c: u8) -> bool {
    c == b'.' || c == b'-' || c == b'_'
}

pub fn vercmp(a: &str, b: &str) -> Ordering {
    let ea = a.split_once(':');
    let eb = b.split_once(':');
    if ea.is_some() || eb.is_some() {
        let epoch_a = ea.map(|(e, _)| e).unwrap_or("0");
        let epoch_b = eb.map(|(e, _)| e).unwrap_or("0");
        let o = core(epoch_a.as_bytes(), epoch_b.as_bytes());
        if o != Ordering::Equal {
            return o;
        }
    }
    let body_a = ea.map(|(_, r)| r).unwrap_or(a);
    let body_b = eb.map(|(_, r)| r).unwrap_or(b);
    let (main_a, rel_a) = split_rel(body_a);
    let (main_b, rel_b) = split_rel(body_b);
    let o = core(main_a.as_bytes(), main_b.as_bytes());
    if o != Ordering::Equal {
        return o;
    }
    match (rel_a, rel_b) {
        (Some(r1), Some(r2)) => core(r1.as_bytes(), r2.as_bytes()),
        _ => Ordering::Equal,
    }
}

fn split_rel(s: &str) -> (&str, Option<&str>) {
    match s.rfind('-') {
        Some(i) => (&s[..i], Some(&s[i + 1..])),
        None => (s, None),
    }
}

fn core(a: &[u8], b: &[u8]) -> Ordering {
    let (x, y) = (a, b);
    let (mut i, mut j) = (0usize, 0usize);
    loop {
        while i < x.len() && j < y.len() && !x[i].is_ascii_digit() && !y[j].is_ascii_digit() {
            let sx = is_sep(x[i]);
            let sy = is_sep(y[j]);
            if sx || sy {
                if !(sx && sy) {
                    return if sx { Ordering::Greater } else { Ordering::Less };
                }
            } else if x[i] != y[j] {
                return x[i].cmp(&y[j]);
            }
            i += 1;
            j += 1;
        }
        let x_end = i >= x.len();
        let y_end = j >= y.len();
        if x_end && y_end {
            return Ordering::Equal;
        }
        if x_end {
            return if y[j].is_ascii_alphabetic() {
                Ordering::Greater
            } else {
                Ordering::Less
            };
        }
        if y_end {
            return if x[i].is_ascii_alphabetic() {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
        while i < x.len() && x[i] == b'0' {
            i += 1;
        }
        while j < y.len() && y[j] == b'0' {
            j += 1;
        }
        let s1 = i;
        while i < x.len() && x[i].is_ascii_digit() {
            i += 1;
        }
        let s2 = j;
        while j < y.len() && y[j].is_ascii_digit() {
            j += 1;
        }
        let len_cmp = (i - s1).cmp(&(j - s2));
        if len_cmp != Ordering::Equal {
            return len_cmp;
        }
        let seg = x[s1..i].cmp(&y[s2..j]);
        if seg != Ordering::Equal {
            return seg;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::vercmp;
    use std::cmp::Ordering::*;

    use std::cmp::Ordering;

    fn t(a: &str, b: &str, expected: Ordering) {
        assert_eq!(vercmp(a, b), expected, "{a} ? {b}");
        assert_eq!(
            vercmp(b, a),
            match expected {
                Less => Greater,
                Greater => Less,
                Equal => Equal,
            },
            "symmetry {a} ? {b}"
        );
    }

    #[test]
    fn oracle_pairs_from_libalpm_c_probe() {
        t("1.0", "1.0", Equal);
        t("1.0", "1.1", Less);
        t("1.0rc1", "1.0", Less);
        t("1.0a", "1.0", Less);
        t("4.9.1", "4.9", Greater);
        t("1:0", "0.99", Greater);
        t("1.0.0", "1.0", Greater);
        t("0.5.3+dev-r2", "0.5.3", Greater);
        t("6.9.12.arch1-1", "6.9.11.arch1-1", Greater);
        t("20240808-1", "20240710-1", Greater);
        t("1.0_2", "1.0.2", Equal);
        t("2.0", "10.0", Less);
        t("abc", "abd", Less);
        t("3.3.1", "3.3", Greater);
        t("5.19.13.arch2-1", "5.19.12.arch2-1", Greater);
        t("01", "1", Equal);
        t("1.4rc5-19", "1.4.0-2", Less);
        t("2k4-5", "2.3.3-1", Less);
        t("1.1.45-2", "1-2", Greater);
        t("1", "1-2", Equal);
        t("1.0-2", "1.0-10", Less);
        t("1.0-2", "1.0-1", Greater);
        t("1-beta", "1", Equal);
        t("1-a-b", "1-a-c", Less);
        t("1.2", "1.2-0", Equal);
        t("1.0-x", "1.0-y", Less);
        t("1:x", "1:y", Less);
        t("1:0", "0.99", Greater);
    }
}
