//! A layer over the `alpm` library to aid with common tasks.

use alpm::{Alpm, Package, PackageReason};

/// The default "root" filepath as required by `alpm`.
pub const DEFAULT_ROOT: &str = "/";

/// The default filepath of the pacman/libalpm database.
pub const DEFAULT_DB: &str = "/var/lib/pacman/";

#[derive(Debug)]
pub enum Error {
    Alpm(alpm::Error),
}

/// All orphaned packages.
///
/// An orphan is a package that was installed as a dependency, but whose parent
/// package is no longer installed.
pub fn orphans(alpm: &Alpm) -> Vec<Package> {
    alpm.localdb()
        .pkgs()
        .iter()
        .filter(|p| {
            p.reason() == PackageReason::Depend
                && p.required_by().is_empty()
                && p.optional_for().is_empty()
        })
        .collect()
}
