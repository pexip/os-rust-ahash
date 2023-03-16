# dh-cargo fork

This is a fork of the debhelper script [dh-cargo],
based on git commit e07347b
(included with version 30 released 2022-11-25),
with these functional changes:

  * support workspace (i.e. multi-crate project),
    * resolve crate name and version from Cargo.toml,
      using X-Cargo-Crates hint or library package name only as key
    * support debhelper option --sourcedirectory
    * support debhelper option --no-package
    * validate package names against Cargo.toml entries,
      failing early (not after test) on crate vs. package mismatch
    * generate cargo-checksum during install
    * pass cargo --remap-path-prefix option sets in RUSTFLAGS
  * allow overriding CARGO_HOME
  * use regex (not strings) for matching files to omit from install
  * omit installing crate metadata in binary library packages:
    * omit any .git* files or directories
    * omit license files
    * omit debian/patches
    (see bug#880689)
  * use debian/Cargo.lock or Cargo.lock (in that order),
    if Cargo.lock exists
  * use crates below debian/vendorlibs when available
  * use dh_auto_build
    (not confusingly only dh_auto_test)

Also included is a slight fork of related [cargo] wrapper script,
based on git commit e4072cb
(included with version 0.63.1-1 released 2022-11-16),
with these functional changes:

  * support --remap-path-prefix option sets in RUSTFLAGS
    by omitting that (not fail) when DEB_CARGO_CRATE is not set
  * support documented shorter CARGO_HOME path
  * support cargo option --path
  * fix only inject path for "cargo install" when not passed as option
  * support DEB_BUILD_OPTIONS=terse
  * enable optimization flags by default also for tests,
    and support DEB_BUILD_OPTIONS=noopt

[dh-cargo]: <https://salsa.debian.org/rust-team/dh-cargo/-/blob/master/cargo.pm>

[cargo]: <https://salsa.debian.org/rust-team/cargo/-/blob/debian/sid/debian/bin/cargo>


## Usage

In your source package,
copy directory `dh-cargo` to `debian/dh-cargo`
and edit `debian/rules` to something like this:

```
#!/usr/bin/make -f

# use local fork of dh-cargo and cargo wrapper
PATH := $(CURDIR)/debian/dh-cargo/bin:$(PATH)
PERL5LIB = $(CURDIR)/debian/dh-cargo/lib
export PATH PERL5LIB

%:
	dh $@ --buildsystem cargo
```


 -- Jonas Smedegaard <dr@jones.dk>  Wed, 25 Jan 2023 16:45:34 +0100
