#!/bin/sh
#! -*-perl-*-
eval 'exec perl -x -wS $0 ${1+"$@"}'
  if 0;

use strict;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use strict;
use warnings;

use Data::Dumper;
use Perl::Tidy 20090616;
use MediaWords::Util::Paths;

# Perl::Tidy doesn't test syntax in all cases, so this subroutine does it in a
# way similar to Test::Strict
sub _test_syntax($)
{
    my $files = shift;

    foreach my $file ( @{ $files } )
    {

        unless ( -f $file and -r $file )
        {
            die "File $file not found or not readable";
        }

        # Set the environment to compile the script or module
        my $inc = join( ' -I ', map { qq{"$_"} } @INC ) || '';
        if ( $inc )
        {
            $inc = "-I $inc";
        }

        # Compile and check for errors
        my $PERL        = $^X || 'perl';
        my $eval        = `$PERL $inc -c \"$file\" 2>&1`;
        my $quoted_file = quotemeta( $file );
        my $ok          = $eval =~ qr!$quoted_file syntax OK!ms;

        unless ( $ok )
        {
            die "Syntax check for file '$file' failed: $eval";
        }
    }
}

sub _tidy_with_perl_tidy($)
{
    my $files = shift;

    my $perltidy_config_file = MediaWords::Util::Paths::mc_script_path() . '/mediawords_perltidy_config_file';
    my $stderr_string;

    #say STDERR "Using $perltidy_config_file";

    my $arguments = join( ' ', @{ $files } );
    $arguments = ' -se ' . $arguments;          # append errorfile to stderr
    $arguments = ' -syn ' . $arguments;         # check the syntax
    $arguments = " -bext='/' " . $arguments;    #  don't make backups

    my $error = Perl::Tidy::perltidy(
        argv       => $arguments,
        perltidyrc => $perltidy_config_file,
        stderr     => \$stderr_string,
    );

    if (   $error
        or $stderr_string )
    {

        my $message = "Error while tidying file(s): " . join( ' ', @ARGV ) . "\n";
        $message .= "Error return code: $error\n";
        $message .= "Error message: $stderr_string\n";

        die $message;
    }
}

sub main
{
    _test_syntax( \@ARGV );
    _tidy_with_perl_tidy( \@ARGV );
}

main();

__END__