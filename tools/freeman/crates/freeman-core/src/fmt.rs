const UNITS: [&str; 7] = ["bytes", "kB", "MB", "GB", "TB", "PB", "EB"];

pub fn format_size(size: u64) -> String {
    if size < 1000 {
        return format!("{} bytes", size);
    }
    let mut scaled = size as f64;
    let mut unit = 0usize;
    while scaled >= 1000.0 && unit < UNITS.len() - 1 {
        scaled /= 1000.0;
        unit += 1;
    }
    let text = if scaled >= 100.0 {
        format!("{:.1}", scaled)
    } else {
        format!("{:.1}", scaled)
    };
    format!("{} {}", text, UNITS[unit])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn glib_style_sizes() {
        assert_eq!(format_size(512), "512 bytes");
        assert_eq!(format_size(1536), "1.5 kB");
        assert_eq!(format_size(1500000), "1.5 MB");
        assert_eq!(format_size(123456789), "123.5 MB");
    }
}
