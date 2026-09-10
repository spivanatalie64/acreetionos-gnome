use std::cmp::Ordering;

#[path = "../src/vercmp.rs"]
mod vercmp_mod;
use vercmp_mod::vercmp;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let o = vercmp(&args[0], &args[1]);
    let n = match o {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    };
    println!("{}", n);
}
