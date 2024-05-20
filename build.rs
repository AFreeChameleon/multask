fn main() {
    println!("cargo:rustc-link-lib=static=mult");
    println!("cargo:rustc-link-search=mult_lib");
}

