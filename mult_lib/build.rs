extern crate cc;

fn main() {
    pkg_config::Config::new()
        .atleast_version("1.2")
        .probe("z")
        .unwrap();    
    let src = [
        "src/c/cpulimit/cpulimit.c",
    ];
    let mut builder = cc::Build::new();
    let build = builder
        .files(src.iter())
        .include("include")
        .flag("-Wno-unused-parameter")
        .define("USE_ZLIB", None);    
    build.compile("mult");
}
