# debhelper buildsystem for Rust crates using Cargo
#
# SPDX-FileCopyrightText: 2016  Josh Triplett <josh@joshtriplett.org>
# SPDX-FileCopyrightText: 2018  Ximin Luo <infinity0@debian.org>
# SPDX-FileCopyrightText: 2022-2023  Jonas Smedegaard <dr@jones.dk>
#
# SPDX-License-Identifier: MIT
#
# This builds Debian rust crates to be installed into a system-level
# crate registry in /usr/share/cargo/registry containing crates that
# can be used and Build-Depended upon by other Debian packages. The
# debcargo(1) tool will automatically generate Debian source packages
# that uses this buildsystem and packagers are not expected to use this
# directly which is why the documentation is poor.
#
# If you have a multi-language program such as firefox or librsvg that
# includes private Rust crates or libraries not exposed to others, you
# should instead use our cargo wrapper, in debian/dh-cargo/bin/cargo,
# which this script also uses. That file contains usage instructions.
# You then should define a Build-Depends on cargo and not dh-cargo.
# The Debian cargo package itself also uses the wrapper as part of its
# own build, which you can look at for a real usage example.
#
# Josh Triplett <josh@joshtriplett.org>
# Ximin Luo <infinity0@debian.org>

package Debian::Debhelper::Buildsystem::cargo;

use strict;
use warnings;
use Cwd;
use Debian::Debhelper::Dh_Lib;
use Dpkg::Control::Info;
use Dpkg::Deps;
use File::Spec;
use JSON::PP;
use String::ShellQuote qw( shell_quote );
use base 'Debian::Debhelper::Buildsystem';

use constant CARGO_SYSTEM_REGISTRY => '/usr/share/cargo/registry/';

sub DESCRIPTION {
    "Rust Cargo"
}

sub cargo_crates {
    my ( $root, $src, $default ) = @_;
    open(F, "cargo metadata --manifest-path $src --no-deps --format-version 1 |");
    local $/;
    my $json = JSON::PP->new;
    my $manifest = $json->decode(<F>);
    my %crates;
    for ( @{ $manifest->{packages} } ) {
        my $pkg_longstem = "$_->{name}-$_->{version}" =~ s/_/-/gr;
        my %object = (
            cratespec => "$_->{name}_$_->{version}",
            systempath => CARGO_SYSTEM_REGISTRY . "/$_->{name}-$_->{version}",
            sourcepath => File::Spec->abs2rel( $_->{manifest_path} =~ s{/Cargo\.toml$}{}r, $root ),
        );

        # resolve crate from dh-cargo cratespec
        $crates{ $object{cratespec} } = \%object;

        # resolve topmost declared crate from package stems
        $crates{$_} //= \%object
            for ( $pkg_longstem =~ /^(((([^+]+?)-[^+.-]+)?\.[^+.]+)?\.[^+]+)?$/ );

        # resolve topmost declared crate from crate name
        $crates{_default} //= \%object
            if $_->{name} eq $default;
    }
    return \%crates;
}

sub deb_host_rust_type {
    open(F, 'printf "include /usr/share/rustc/architecture.mk\n\
all:\n\
	echo \$(DEB_HOST_RUST_TYPE)\n\
" | make --no-print-directory -sf - |');
    $_ = <F>;
    chomp;
    return $_;
}

sub check_auto_buildable {
    my $this = shift;
    if (-f $this->get_sourcepath("Cargo.toml")) {
        return 1;
    }
    return 0;
}

# fork of Debian::Debhelper::Buildsystem::doit_in_sourcedir()
# needed to work on individual members of a workspace crate
sub doit_in_somedir {
    my ($this, $dir, @args) = @_;
    $this->_generic_doit_in_dir($dir, \&print_and_doit, @args);
    return 1;
}

sub new {
    my $class = shift;
    my $this = $class->SUPER::new(@_);
    $this->enforce_in_source_building();
    return $this;
}

sub pre_building_step {
    my $this = shift;
    my $step = shift;

    # Many files are coming from crates.io with incorrect timestamp
    # See https://github.com/rust-lang/crates.io/issues/3859
    complex_doit("find . ! -newermt 'jan 01, 2000' -exec touch -d@" . $ENV{SOURCE_DATE_EPOCH} . " {} +");

    $this->{cargo_command} = Cwd::abs_path("debian/dh-cargo/bin/cargo");
    $this->{cargo_home} = Cwd::abs_path("debian/cargo_home");
    $this->{host_rust_type} = deb_host_rust_type;

    my $control = Dpkg::Control::Info->new();

    my $source = $control->get_source();
    my $crate = $source->{'X-Cargo-Crate'};
    if (!$crate) {
        $crate = $source->{Source};
        $crate =~ s/^ru[sz]t-//;
        $crate =~ s/-[0-9]+(\.[0-9]+)*$//;
    }
    $this->{crates} = cargo_crates( $this->{cwd}, $this->get_sourcepath("Cargo.toml"), $crate );

    $this->{libpkg} = {};
    $this->{binpkg} = {};
    $this->{featurepkg} = [];
    my @arch_packages = getpackages('arch');
    my $cratepkg_re = qr/^libru[sz]t-(?<stem>[^+]+?(?<fullversion>-[^+.-]+(?:\.[^+.]+){2})?)(?:\+(?<feature>.+))?-dev$/;
    foreach my $package ( getpackages() ) {
        if ($package =~ /$cratepkg_re/) {
            unless ( $this->{crates}{ $+{stem} } ) {
                error("Failed to resolve crate \"$+{stem}\" in cargo metadata for library package $package.");
            }
            if ( $+{feature} ) {
                push(@{$this->{featurepkg}}, { name => $package , libcrate => $this->{crates}{ $+{stem} } });
                next;
            }
            $this->{libpkg}{$package}{name} = $package;
            my %fullnames;
            if ( $+{fullversion} ) {
                push @{ $this->{libpkg}{$package}{crates} }, $this->{crates}{ $+{stem} };
                $fullnames{ "$+{stem}$+{fullversion}" } = undef;
            }
            deps_iterate(
                deps_parse( deps_concat( $control->get_pkg_by_name($package)->{'Provides'} ), virtual => 1 ),
                sub {
                    $_[0]->{package} =~ /$cratepkg_re/;
                    if ( $+{fullversion} and not exists $fullnames{ "$+{stem}$+{fullversion}" } ) {
                        unless ( $this->{crates}{ $+{stem} } ) {
                            error("Failed to resolve crate \"$+{stem}\" in cargo metadata for virtual library package \"$package\".");
                        }
                        push @{ $this->{libpkg}{$package}{crates} }, $this->{crates}{ $+{stem} };
                        $fullnames{ "$+{stem}$+{fullversion}" } = undef;
                    }
                    1;
                },
            ) or error("Failed to parse virtual crate library packages provided by package $package.");
        } elsif ( grep {$package} @arch_packages ) {
            deps_iterate(
                # TODO: parse as crate names (not package names)
                deps_parse( deps_concat( $control->get_pkg_by_name($package)->{'X-Cargo-Crates'} ) ),
                sub {
                    my $crate = $this->{crates}{ $_[0]->{package} };
                    if ($crate) {
                        if ( exists $crate->{binpkg} ) {
                            error("Crate $crate->{cratespec} is tied to multiple packages: $crate->{binpkg}{name} and $package.");
                        }
                        push @{ $this->{binpkg}{$package}{crates} }, $crate;
                        $crate->{binpkg}{name} = $package;
                    } else {
                        error("Failed to resolve crate \"$_[0]->{package}\" in cargo metadata for binary package \"$package\".");
                    }
                    1;
                },
            ) or error("Failed to parse crates for binary package $package.");
            unless ( keys %{ $this->{binpkg} } ) {
                # fallback: use arch-specific package when name matches a crate
                my $crate = $this->{crates}{$package};
                if ($crate and not $crate->{binpkg} ) {
                    push @{ $this->{binpkg}{$package}{crates} }, $crate;
                    $crate->{binpkg}{name} = $package;
                }
            }
        }
    }
    unless ( keys %{ $this->{libpkg} } or keys %{ $this->{binpkg} } ) {
        # default: tie a single arch-specific package with topmost crate
        if ( @arch_packages eq 1 ) {
            unless ( exists $this->{crates}{_default} ) {
                error("Failed to resolve a default crate from cargo metadata.");
            }
            push @{ $this->{binpkg}{ $arch_packages[0] }{crates} }, $this->{crates}{_default};
            $this->{crates}{_default}{binpkg}{name} = $arch_packages[0];
        } else {
            error("Could not find any Cargo lib or bin packages to build.");
        }
    }
    foreach my $pkg ( values %{ $this->{libpkg} } ) {
        foreach my $crate ( @{ $pkg->{crates} } ) {
            if ( exists $crate->{libpkg} ) {
                error("Crate $crate->{cratespec} is tied to multiple packages: $crate->{libpkg}{name} and $pkg->{name}.");
            }
            $crate->{libpkg} = $pkg;
        }
    }
    foreach my $pkg (@{$this->{featurepkg}}) {
        unless ( exists $pkg->{libcrate}{libpkg} ) {
            error("Found feature package $pkg->{name} but no matching lib package.");
        }
        push @{ $pkg->{libcrate}{libpkg}{featurepkg} }, $pkg->{name};
    }

    my $parallel = $this->get_parallel();
    $this->{j} = $parallel > 0 ? ["-j$parallel"] : [];

    $ENV{'CARGO_HOME'} ||= $this->{cargo_home};
    $ENV{'DEB_HOST_RUST_TYPE'} = $this->{host_rust_type};
    $ENV{'DEB_HOST_GNU_TYPE'} = dpkg_architecture_value("DEB_HOST_GNU_TYPE");

    $this->SUPER::pre_building_step($step);
}

sub get_sources {
    my ( $this, $sourcedir ) = @_;
    opendir(my $dirhandle, $sourcedir);
    my @sources = grep { !/^(\.(\.|git.*|pc)?|debian|Cargo\.lock|COPYING.*|LICENSE.*)$/ } readdir($dirhandle);
    closedir($dirhandle);
    @sources
}

sub configure {
    my $this=shift;
    # use Cargo.lock if it exists, or debian/Cargo.lock if that also exists
    my $cargo_lock = $this->get_sourcepath('Cargo.lock');
    if ( -f $cargo_lock ) {
        restore_file_on_clean($cargo_lock);
        doit(qw(cp -f debian/Cargo.lock), $cargo_lock)
            if -f "debian/Cargo.lock";
        doit(qw(sed -i -e), '/^checksum / d', $cargo_lock);
    }
    my $registry_path = $this->_rel2rel('debian/cargo_registry', $this->get_sourcedir());
    my @rustflags = map {(
        "--remap-path-prefix",
        "$_->{cratespec}=$_->{systempath}",
    )} map { @{ $this->{libpkg}{$_}{crates} } } sort keys %{ $this->{libpkg} };
    push @rustflags, "--remap-path-prefix", "$registry_path=" . CARGO_SYSTEM_REGISTRY;
    $this->doit_in_sourcedir(
        "env", 'RUSTFLAGS=' . shell_quote(@rustflags),
        $this->{cargo_command}, "prepare-debian",
        $registry_path,
        "--link-from-system");
    if ( -d 'debian/vendorlibs' ) {
        complex_doit(
            qw(find debian/cargo_registry -lname '../vendorlibs/*' -delete));
        complex_doit(
            qw(ln --symbolic --relative --target-directory=debian/cargo_registry debian/vendorlibs/*));
    }
    $this->doit_in_sourcedir(qw(cargo update)) if -f $cargo_lock;
}

sub build {
    my $this=shift;
    # Compile the crate, if needed to build binaries.
    $this->doit_in_sourcedir($this->{cargo_command}, "build", @_)
        if ( keys %{ $this->{binpkg} } );
}

sub test {
    my $this=shift;
    # Execute unit and integration tests.
    # This also checks that the thing compiles,
    # which might fail if e.g. the package
    # requires non-rust system dependencies and the maintainer didn't provide
    # this additional information to debcargo.
    $this->doit_in_sourcedir($this->{cargo_command}, "test", @_);
    # test generating Built-Using fields
    doit("env", "CARGO_CHANNEL=debug", "/usr/share/cargo/bin/dh-cargo-built-using");
}

sub install {
    my $this=shift;
    my $destdir=shift;
    foreach my $crate ( map { @{ $_->{crates} } } sort values %{ $this->{libpkg} } ) {
        my $target = tmpdir( $crate->{libpkg}{name} ) . $crate->{systempath};
        my @sources = $this->get_sources( $crate->{sourcepath} );
        install_dir($target);
        $this->doit_in_somedir(
            $crate->{sourcepath},
            "env", "DEB_CARGO_CRATE=$crate->{cratespec}",
            "cp", "--parents",
            "-at", $this->_rel2rel($target, $crate->{sourcepath}),
            @sources);
        doit("rm", "-rf", "$target/target");
        complex_doit(
            qw(perl -MDigest::SHA=sha256_hex -0777 -nE 'say sprintf),
            'q<{"package":"%s","files":{}}>,', "sha256_hex($_)'",
            "<", "$crate->{sourcepath}/Cargo.toml",
            ">", "$target/.cargo-checksum.json");
        # prevent an ftpmaster auto-reject regarding files with old dates.
        doit("touch", "-d@" . $ENV{SOURCE_DATE_EPOCH}, "$target/Cargo.toml");
        }
    foreach my $featurepkg (@{$this->{featurepkg}}) {
        my $target = tmpdir( $featurepkg->{name} ) . "/usr/share/doc";
        install_dir($target);
        make_symlink_raw_target( $featurepkg->{libcrate}{libpkg}{name}, "$target/$featurepkg->{name}" );
    }
    foreach my $crate ( map { @{ $_->{crates} } } sort values %{ $this->{binpkg} } ) {
        # Do the install
        my $destdir = $ENV{'DESTDIR'} || tmpdir( $crate->{binpkg}{name} );
        my @path_opts = $crate->{sourcepath} ne '.' ? ('--path', $crate->{sourcepath}) : ();
        $this->doit_in_sourcedir("env", "DESTDIR=$destdir", "DEB_CARGO_CRATE=$crate->{cratespec}",
             $this->{cargo_command}, "install", @path_opts, @_);
        # generate Built-Using fields
        doit("env", "/usr/share/cargo/bin/dh-cargo-built-using", $crate->{binpkg}{name});
    }
}

sub clean {
    my $this=shift;
    doit("touch", "--no-create", "-d@" . $ENV{SOURCE_DATE_EPOCH}, ".cargo_vcs_info.json");
    $this->doit_in_sourcedir($this->{cargo_command}, "clean", @_);
    doit("rm", "-rf", "debian/cargo_registry");
}

1
