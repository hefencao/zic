use std::env;

fn main() {
    println!("cargo:rerun-if-env-changed=ZIC_WEBP_LIB_DIR");
    println!("cargo:rerun-if-env-changed=ZIC_WEBP_STATIC");
    println!("cargo:rerun-if-env-changed=ZIC_WEBP_EXTRA_LIBS");
    println!("cargo:rerun-if-env-changed=ZIC_WEBP_SYSTEM_LIBS");

    if let Ok(dir) = env::var("ZIC_WEBP_LIB_DIR") {
        println!("cargo:rustc-link-search=native={dir}");
    }
    let static_link = env::var("ZIC_WEBP_STATIC").ok().as_deref() == Some("1");
    let kind = if static_link { "static=" } else { "" };
    println!("cargo:rustc-link-lib={kind}webpdemux");
    println!("cargo:rustc-link-lib={kind}webp");
    if let Ok(extra) = env::var("ZIC_WEBP_EXTRA_LIBS") {
        for lib in extra
            .split(',')
            .map(str::trim)
            .filter(|lib| !lib.is_empty())
        {
            println!("cargo:rustc-link-lib={kind}{lib}");
        }
    }
    if let Ok(system) = env::var("ZIC_WEBP_SYSTEM_LIBS") {
        for lib in system
            .split(',')
            .map(str::trim)
            .filter(|lib| !lib.is_empty())
        {
            println!("cargo:rustc-link-lib={lib}");
        }
    }
}
