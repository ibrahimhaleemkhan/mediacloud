package MediaWords::Languages::en;

use strict;
use warnings;

use base 'MediaWords::Languages::Language::PythonWrapper';

use Modern::Perl "2015";
use MediaWords::CommonLibs;

sub _python_language_class_path
{
    return 'mediawords.languages.en';
}

sub _python_language_class_name
{
    return 'EnglishLanguage';
}

1;
