fn main() {
    println!("cargo:rustc-link-lib=mult");
    println!("cargo:rustc-link-search=mult_lib");
}

