package CPAN::Rpmize;
use strict;
use Carp;
use CPANPLUS::Backend;
use File::Temp qw(tempdir);
use CPANPLUS;
use RPM::Specfile;
use YAML qw(LoadFile);
use Data::Dumper;

## This code is based on cpanflute2.

sub new {
    my $self = {};
    $self->{conf} = {};
    $self->{release} = '1.rpmize';
    $self->{modules} = {};
    $self->{backend} = new CPANPLUS::Backend;
    $self->{pkg_name_cache} = {};
    $self->{pkg_name_prefix} = {};
    bless $self;

    return $self;
}

sub set_conf {
    my $self = shift;
    my $filename = shift;
    $self->{conf} = LoadFile($filename);
}

sub conf : lvalue {
    my $self = shift;
    $self->{conf};
}

sub get_dependency {
    my $self = shift;
    my $name = shift;

    my $cpan = $self->{backend};
    my $dist = $cpan->parse_module(module => $name);
    return unless $dist;
    my ($archive, $where, $deps);
    eval {
        $archive = $dist->fetch(force => 1) or next;
        $where   = $dist->extract(force => 1) or next;
    };

    $archive =~ /([^\/]+)\-([^-]+)\.t(ar\.)?gz$/;
    my $name = $1;
    my $ver = $2;
    #my $release = $self->{release};
    #$self->{pkg_name_prefix}->{$name} = "perl-$name-$ver-$release";
    $self->{pkg_name_prefix}->{$name} = "perl-$name-$ver";

    if(-f File::Spec->catfile($where, 'META.yml')) {
        eval {
            $deps = LoadFile(File::Spec->catfile($where, 'META.yml'));
        }
    }
    if($self->{conf}->{$name} && $self->{conf}->{$name}->{requires}){
        foreach my $req (keys %{$self->{conf}->{$name}->{requires}}){
            $deps->{requires}->{$req} = '0';
        }
    }
    if($self->{conf}->{$name} && $self->{conf}->{$name}->{build_requires}){
        foreach my $req (keys %{$self->{conf}->{$name}->{build_requires}}){
            $deps->{build_requires}->{$req} = '0';
        }
    }
    foreach my $req (keys %{$deps->{recommends}}){
        $deps->{requires}->{$req} = '0';
    }
    #print Data::Dumper::Dumper($deps);

    return $deps;
}

sub walk_tree {
    my $self = shift;
    my $name = shift;
    return if($self->{conf}->{$name} && $self->{conf}->{$name}->{build_skip} > 0);
    my $pkg_name = $self->get_pkg_name($name);
    #print "name: $name, pkg_name: $pkg_name\n";
    return if($name eq 'perl' || $pkg_name eq 'perl' || $pkg_name eq '');
    return if($self->{modules}->{$name} && $self->{modules}->{$name}->{processed});
    return if($self->{conf}->{$pkg_name} && $self->{conf}->{$pkg_name}->{build_skip} > 0);
    $self->{modules}->{$name} = {requires => {}, used_by => {}} if(!defined $self->{modules}->{$name});
    my $node = $self->{modules}->{$name};
    $node->{processed} = 1;

    #print "name: $name, hyname: $hyname\n";
    #print Data::Dumper::Dumper($self->{tree}->{$hyname});
    my $deps = $self->get_dependency($name);

    for my $key (keys %{$deps->{requires}}){
        #print "requires: $key from $name\n";
        $node->{requires}->{$key} = $deps->{requires}->{$key};
        $self->walk_tree($key);
    }
    for my $key (keys %{$deps->{build_requires}}){
        #print "build_requires: $key from $name\n";
        $node->{requires}->{$key} = $deps->{build_requires}->{$key};
        next if($self->{conf}->{$name} && $self->{conf}->{$name}->{build_skip} > 0);
        my $key_pkg_name = $self->get_pkg_name($key);
        next if($key_pkg_name eq 'perl' || ($self->{conf}->{$key_pkg_name} && $self->{conf}->{$key_pkg_name}->{build_skip} > 0));
        $node->{requires_real}->{$key_pkg_name} = 1;
        $self->{modules}->{$key} = {requires => {}, used_by => {}} if(!defined $self->{modules}->{$key});
        my $key_node = $self->{modules}->{$key};
        $key_node->{used_by}->{$name} = 1;
        $self->walk_tree($key);
    }
}

sub puts {
    my $self = shift;

    my $count = 1;
    while($count > 0){
        $count = 0;
        foreach my $key (keys %{$self->{modules}}){
            my $node = $self->{modules}->{$key};
            my $key_pkg_name = $self->get_pkg_name($key);
            my @num = keys %{$node->{requires_real}};
            #print "   $key requires ".@num." mods\n";
            if(@num == 0){
                my $delete_count = 0;
                foreach my $used (keys %{$node->{used_by}}){
                    my @num = keys %{$self->{modules}->{$used}->{requires_real}};
                    delete $self->{modules}->{$used}->{requires_real}->{$key_pkg_name};
                    my @num2 = keys %{$self->{modules}->{$used}->{requires_real}};
                    #print "   $used requires ".@num."->".@num2." mods\n";
                    $delete_count++;
                }
                print "build checking $key".($delete_count > 0 ? ' then install':'')."\n";
                $count ++;
                delete $self->{modules}->{$key};
                $self->build($key);
                $self->install($key) if($delete_count > 0);
            }
        }
        #print "$count mods are built\n";
    }
    foreach my $key (keys %{$self->{modules}}){
        print "force building $key\n";
        #print Data::Dumper::Dumper($self->{modules}->{$key}->{requires_real});
        $self->build($key);
    }
}

sub get_pkg_name {
    my $self = shift;
    my $name = shift;
    return $self->{pkg_name_cache}->{$name} if($self->{pkg_name_cache}->{$name});
    if($name eq 'perl'){
        $self->{pkg_name_cache}->{$name} = $name;
    } else {
        my $cpan = $self->{backend};
        croak "fatal: Can't create CPANPLUS::Backend object"
            unless defined $self->{backend};
        my $dist = $cpan->parse_module(module => $name);
        $self->{pkg_name_cache}->{$name} = $dist ? $dist->package_name : $name;
    }
    return $self->{pkg_name_cache}->{$name};
}

sub build {
    my $self = shift;
    my $name = shift;
    return if($name eq 'perl' || ($self->{conf}->{$name} && $self->{conf}->{$name}->{build_skip} > 0));

    my $pkg_name = $self->get_pkg_name($name);
    my $build_opt = $self->check_build($pkg_name);
    #print "build_opt of $name: $build_opt\n";
    unless ($build_opt) {
        print "build skip $pkg_name\n";
        return;
    }

    my $filter = [];
    if($self->{conf}->{$pkg_name}){
        push @$filter, keys %{$self->{conf}->{$pkg_name}->{filter_requires}};
    }

    my $cpan = $self->{backend};
    croak "fatal: Can't create CPANPLUS::Backend object"
      unless defined $self->{backend};
    #if($self->{conf}->{$pkg_name}->{version}){
    #    $pkg_name .= '-' . $self->{conf}->{$pkg_name}->{version};
    #}
    #my $dist = $cpan->parse_module(module => $name);
    #print "before: parse_module\n";
    my $dist = $cpan->parse_module(module => $name);
    #print "after: parse_module\n";
    return unless $dist;
    my $dist_name = $dist->package_name;

    print "  >> skip: is a bundle\n" and
        next if $dist->is_bundle;

    printf(" => %s(%s) %s by %s (%s)\n", $dist_name, $name,
           $dist->package_version, $dist->author->cpanid, $dist->author->author);

    my $archive = '';
    my $where = '';

    # fetch and extract the distribution
    eval {
        $archive = $dist->fetch(force => 1) or next;
        #$where   = $dist->extract(force => 1) or next;
    };
    print("  >> CPANPLUS error: $@\n") and return if $@;

    return unless($archive);

    $archive =~ /([^\/]+)\-([^-]+)\.t(ar\.)?gz$/;
    my $name = $1;
    my $ver = $2;
    #my $release = '8';
    #$self->{pkg_name_prefix}->{$name} = "perl-$name-$ver-$release";
    $self->{pkg_name_prefix}->{$name} = "perl-$name-$ver";
    my $build_arch = get_default_build_arch();
    #my $tarball_top_dir = "$name-%{version}";
    my $opts = "--just-spec --noperlreqs --installdirs='vendor' --release " . $self->{release};
    #if($self->{conf}->{$pkg_name} && $self->{conf}->{$pkg_name}->{requires}){
    #    foreach my $pkg (keys %{$self->{conf}->{$pkg_name}->{requires}}){
    #        $opts .= " --requires=$pkg";
    #    }
    #}
    #print "cpanflute2 $opts $archive\n";
    #my $spec = `./cpanflute2 $opts $archive`;
    my $spec = `cpanflute2 $opts $archive`;
    $spec =~ s/^Requires: perl\(perl\).*$//m;
    $spec =~ s/^make pure_install PERL_INSTALL_ROOT=\$RPM_BUILD_ROOT$/make pure_install PERL_INSTALL_ROOT=\$RPM_BUILD_ROOT\nif [ -d \$RPM_BUILD_ROOT\$RPM_BUILD_ROOT ]; then mv \$RPM_BUILD_ROOT\$RPM_BUILD_ROOT\/* \$RPM_BUILD_ROOT; fi/m;
    open FH, ">perl-$name.spec";
    print FH $spec;
    close FH;

    my $tmpdir = tempdir(CLEANUP => 1, DIR => '/tmp');
    my $outdir = "./";
    if(@$filter){
	print "filter is injected\n";
        for my $mod (@{$filter}){
            $spec =~ s/^Requires: perl\($mod\).+$//m;
            $spec =~ s/^BuildRequires: perl\($mod\).+$//m;
        }
        $spec = "Source2: filter_macro\n".'%define __perl_requires %{SOURCE2}'."\n".$spec;

        open FH, ">$tmpdir/filter_macro"
            or die "Can't create $tmpdir/filter_macros: $!";
        print FH qq{#!/bin/sh

/usr/lib/rpm/perl.req \$\* |\\
    sed };
        for my $mod (@{$filter}){
            print FH "-e '/perl($mod)/d' ";
        }
        print FH "\n";
        close FH;
        system ("chmod 755 $tmpdir/filter_macro");
    }

    open FH, ">$tmpdir/perl-$name.spec"
        or die "Can't create $tmpdir/perl-$name.spec: $!";
    print FH $spec;
    close FH;

    open FH, ">$tmpdir/macros"
        or die "Can't create $tmpdir/macros: $!";

    system("cp $archive $tmpdir/$name-$ver.tar.gz");
    system("cp $archive $tmpdir/$name-$ver.tgz");

    print FH qq{
%_topdir         $tmpdir
%_builddir       %{_topdir}
%_rpmdir         $outdir
%_sourcedir      %{_topdir}
%_specdir        %{_topdir}
%_srcrpmdir      $outdir
%_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm
};

    close FH;

    open FH, ">$tmpdir/rpmrc"
        or die "Can't create $tmpdir/rpmrc: $!";

    my $macrofiles = qx(rpm --showrc | grep ^macrofiles | cut -f2- -d:);
    chomp $macrofiles;

    print FH qq{
include: /usr/lib/rpm/rpmrc
macrofiles: $macrofiles:$tmpdir/macros
};
    close FH;

    # Build the build command
    my @cmd;
    push @cmd, 'env';
    push @cmd, 'PERL_MM_USE_DEFAULT=1';
    push @cmd, 'rpmbuild';
    push @cmd, '--rcfile', "$tmpdir/rpmrc";
    push @cmd, "-b${build_opt}";
    push @cmd, '--rmsource';
    push @cmd, '--rmspec';
    push @cmd, '--clean',  "$tmpdir/perl-$name.spec";
    #push @cmd, "--sign" if $options{sign};

    #print "printing spec...\n";
    #print `cat "$tmpdir/perl-$name.spec"`;
    # perform the build, die on error
    print join(' ',@cmd)."\n";
    my $retval = system (@cmd);
    $retval = $? >> 8;
    if ($retval != 0) {
        die "RPM building failed!\n";
    }

    # clean up macros file
    unlink "$tmpdir/rpmrc", "$tmpdir/macros";

    # if we did a build all, lets move the rpms into our current
    # directory
    #my $bin_rpm = "./perl-${name}-${ver}-${release}.${build_arch}.rpm";

    #exit(0);

}

sub check_build {
    my $self = shift;
    my $name = shift;

    my $prefix = $self->{pkg_name_prefix}->{$name}."-".$self->{release};
    $prefix =~ s/\+/\\\+/;
    my ($bin_pkg, $src_pkg);
    opendir DH, '.';
    my @filelist = readdir DH;
    closedir DH;
    #print "^$prefix\.+\.rpm$ \n";
    foreach (@filelist){
        if($_ =~ /^$prefix.*\.rpm$/ && $_ !~ /src.rpm$/){
            $bin_pkg = 1;
        } elsif($_ =~ /^$prefix\..*src\.rpm$/){
            $src_pkg = 1;
        }
    }
    return $bin_pkg ? ($src_pkg ? '' : 's') : ($src_pkg ? 'b' : 'a');
}

sub check_install {
    my $self = shift;
    my $name = shift;

    my @cmd;
    push @cmd, 'rpm';
    push @cmd, '-q';
    push @cmd, "perl-".$name;
    my $cmd = join(' ',@cmd);
    print "$cmd\n";
    my $ret = `$cmd`;
    print "$name is ".($ret =~ /not installed/ ? 'not ' : '')."installed\n";
    return $ret =~ /not installed/ ? 0 : 1;
}

sub install {
    my $self = shift;
    my $name = shift;
    my $pkg_name = $self->get_pkg_name($name);
    if($self->check_install($pkg_name)){
        print "install skip $pkg_name\n";
        return;
    }

    my $prefix = $self->{pkg_name_prefix}->{$pkg_name}."-".$self->{release};
    $prefix =~ s/\+/\\\+/;
    my $rpm_name;
    opendir DH, '.';
    my @filelist = readdir DH;
    closedir DH;
    foreach (@filelist){
        if($_ =~ /^$prefix.*\.rpm$/ && $_ !~ /src.rpm$/){
            $rpm_name = $_;
        }
    }

    my @cmd;
    push @cmd, 'sudo';
    push @cmd, 'rpm';
    push @cmd, '-Uvh';
    push @cmd, $rpm_name;
    print join(' ',@cmd)."\n";
    my $retval = system (@cmd);

}

sub colon2hyphen {
    my $name = shift;
    $name =~ s/::/\-/g;
    return $name;
}

sub hyphen2colon {
    my $name = shift;
    unless($name =~ /libwww-perl|MIME-tools/){
	$name =~ s/\-/::/g;
    }
    return $name;
}

sub get_default_build_arch {
  my $build_arch = qx(rpm --eval %{_build_arch});
  chomp $build_arch;

  return $build_arch;
}

1;
