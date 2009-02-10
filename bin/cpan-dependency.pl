use strict;
use FindBin;
use lib File::Spec->catdir($FindBin::Bin, '..', 'lib');
use CPANPLUS::Backend;
use Getopt::Long;
use CPAN::Rpmize;
use Data::Dumper;

sub die_usage {
}

my %options;
GetOptions(\%options, "conf=s", "test", "save=s", "load=s", "file=s", "release=s") or die_usage();

my $rpmize = CPAN::Rpmize->new();
$rpmize->test = 1 if($options{'test'});
$rpmize->release = $options{'release'} if($options{'release'});
$rpmize->set_conf($options{'conf'}) if($options{'conf'});

my $pkgname = shift;
die_usage() if($pkgname && $options{'file'});
die if $options{'file'} and $pkgname;
if($pkgname){
    $rpmize->walk_tree($pkgname);
} elsif($options{'file'}) {
    open(FILE, "<$options{'file'}");

    while(<FILE>){
	next if($_ =~ /(^package )|(^__END__$)|(^\=)|(^\#)/);
	chomp;
	$rpmize->walk_tree($_);
    }
} else {
    die;
}

print Data::Dumper::Dumper($rpmize->{modules});
$rpmize->puts;
