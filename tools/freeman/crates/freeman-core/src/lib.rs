pub mod fmt;
pub mod vercmp;

pub use fmt::format_size;
pub use vercmp::vercmp;

pub fn term_width() -> usize {
    if let Some(width) = ioctl_width() {
        return width;
    }
    80
}

fn ioctl_width() -> Option<usize> {
    #[repr(C)]
    struct WinSize {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    }
    extern "C" {
        fn ioctl(fd: i32, request: u64, ...) -> i32;
    }
    const TIOCGWINSZ: u64 = 0x5413;
    let mut ws = WinSize { ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0 };
    let rc = unsafe { ioctl(1, TIOCGWINSZ, &mut ws as *mut WinSize) };
    if rc == 0 && ws.ws_col > 0 {
        Some(ws.ws_col as usize)
    } else {
        None
    }
}

pub fn split_string(s: &str, margin: usize, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    let available = width.saturating_sub(margin).max(10);
    if s.chars().count() <= available {
        if !s.is_empty() {
            out.push(s.to_string());
        }
        return out;
    }
    let bytes = s.as_bytes();
    let total = bytes.len();
    let mut offset = 0usize;
    let mut remain = total;
    while remain >= available {
        let window = &s[offset..offset + available];
        let cut = match window.rfind(' ') {
            Some(i) => i,
            None => available,
        };
        out.push(s[offset..offset + cut].to_string());
        offset += cut + 1;
        remain -= cut + 1;
    }
    if remain > 0 {
        out.push(s[offset..].to_string());
    }
    out
}

pub fn print_aligned(out: &mut String, left: &str, right: &str, width: usize) {
    let pad = width.saturating_sub(left.chars().count());
    out.push_str(left);
    for _ in 0..pad {
        out.push(' ');
    }
    out.push_str(right);
    out.push('\n');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrap_respects_margin_and_min_width() {
        let words = "aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp";
        let lines = split_string(words, 4, 40);
        assert!(lines.iter().all(|l| l.chars().count() <= 36 || l.len() == words.len()));
        assert!(lines.len() >= 2);
    }

    #[test]
    fn aligned_pads_to_width() {
        let mut s = String::new();
        print_aligned(&mut s, "Name", ": bash", 10);
        assert_eq!(s, "Name      : bash\n");
    }
}
