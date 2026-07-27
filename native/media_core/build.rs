use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=ZIC_WEBP_LIB_DIR");
    println!("cargo:rerun-if-env-changed=ZIC_WEBP_STATIC");

    if let Ok(dir) = env::var("ZIC_WEBP_LIB_DIR") {
        println!("cargo:rustc-link-search=native={dir}");
    }
    let static_link = env::var("ZIC_WEBP_STATIC").ok().as_deref() == Some("1");
    let kind = if static_link { "static=" } else { "" };
    println!("cargo:rustc-link-lib={kind}webpdemux");
    println!("cargo:rustc-link-lib={kind}webp");
}
