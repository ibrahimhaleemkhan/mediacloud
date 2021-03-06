package MediaWords::Solr::WordCounts;

use Moose;

=head1 NAME

MediaWords::Solr::WordCounts - handle word counting from solr

=head1 DESCRIPTION

Uses sampling to generate quick word counts from solr queries.

=cut

use strict;
use warnings;
use utf8;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use CHI;
use Data::Dumper;
use Encode;
use List::Util;
use Readonly;
use URI::Escape;

use MediaWords::Languages::Language;
use MediaWords::Solr;
use MediaWords::Util::Config;
use MediaWords::Util::IdentifyLanguage;
use MediaWords::Util::JSON;
use MediaWords::Util::Text;

# Max. length of the sentence to tokenize
Readonly my $MAX_SENTENCE_LENGTH => 1024;

# Max. number of times to count a word in a single sentence
Readonly my $MAX_REPEATS_PER_SENTENCE => 3;

# mediawords.wc_cache_version from config
my $_wc_cache_version;

# Moose instance fields

has 'q'                         => ( is => 'rw', isa => 'Str' );
has 'fq'                        => ( is => 'rw', isa => 'ArrayRef' );
has 'num_words'                 => ( is => 'rw', isa => 'Int', default => 500 );
has 'sample_size'               => ( is => 'rw', isa => 'Int', default => 1000 );
has 'ngram_size'                => ( is => 'rw', isa => 'Int', default => 1 );
has 'include_stopwords'         => ( is => 'rw', isa => 'Bool' );
has 'no_remote'                 => ( is => 'rw', isa => 'Bool' );
has 'include_stats'             => ( is => 'rw', isa => 'Bool' );
has 'cached_combined_stopwords' => ( is => 'rw', isa => 'HashRef' );
has 'db' => ( is => 'rw' );

# list of all attribute names that should be exposed as cgi params
sub get_cgi_param_attributes
{
    return [ qw(q fq num_words sample_size include_stopwords include_stats no_remote ngram_size) ];
}

# return hash of attributes for use as cgi params
sub _get_cgi_param_hash($)
{
    my ( $self ) = @_;

    my $keys = get_cgi_param_attributes;

    my $meta = $self->meta;

    my $hash = {};
    map { $hash->{ $_ } = $meta->get_attribute( $_ )->get_value( $self ) } @{ $keys };

    return $hash;
}

# add support for constructor in this form:
#   WordsCounts->new( cgi_params => $cgi_params )
# where $cgi_params is a hash of cgi params directly from a web request
around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;

    my $args;
    if ( ref( $_[ 0 ] ) )
    {
        $args = $_[ 0 ];
    }
    elsif ( defined( $_[ 0 ] ) )
    {
        $args = { @_ };
    }
    else
    {
        $args = {};
    }

    my $vals;
    if ( $args->{ cgi_params } )
    {
        my $cgi_params = $args->{ cgi_params };

        $vals = {};
        my $keys = get_cgi_param_attributes;
        for my $key ( @{ $keys } )
        {
            if ( exists( $cgi_params->{ $key } ) )
            {
                $vals->{ $key } = $cgi_params->{ $key };
            }
        }

        if ( $args->{ db } )
        {
            $vals->{ db } = $args->{ db };
        }
    }
    else
    {
        $vals = $args;
    }

    if ( $vals->{ fq } && !ref( $vals->{ fq } ) )
    {
        $vals->{ fq } = [ $vals->{ fq } ];
    }

    $vals->{ fq } ||= [];

    return $class->$orig( $vals );
};

# Cache merged hashes of stopwords for speed
sub _combine_stopwords($$)
{
    my ( $self, $languages ) = @_;

    unless ( ref( $languages ) eq ref( [] ) )
    {
        die "Languages is not a hashref.";
    }
    unless ( scalar( @{ $languages } ) > 0 )
    {
        die "Languages should have at least one language set.";
    }

    my $language_codes = [];
    foreach my $language ( @{ $languages } )
    {
        push( @{ $language_codes }, $language->language_code() );
    }
    $language_codes = [ sort( @{ $language_codes } ) ];

    my $cache_key = join( '-', @{ $language_codes } );

    unless ( $self->cached_combined_stopwords() )
    {
        $self->cached_combined_stopwords( {} );
    }

    unless ( defined $self->cached_combined_stopwords->{ $cache_key } )
    {
        my $combined_stopwords = {};
        foreach my $language ( @{ $languages } )
        {
            my $stopwords = $language->stop_words_map();
            $combined_stopwords = { ( %{ $combined_stopwords }, %{ $stopwords } ) };
        }

        $self->cached_combined_stopwords->{ $cache_key } = $combined_stopwords;
    }

    return $self->cached_combined_stopwords->{ $cache_key };
}

# Expects the following arrayref of hashrefs:
#
# [
#     {
#         'story_language' => '...',
#         'sentence' => '...',
#     },
#     {
#         'story_language' => '...',
#         'sentence' => '...',
#     },
#     ...
# ]
#
# parse the text and return a count of stems and terms in the sentence in the
# following format:
#
# { $stem => { count => $stem_count, terms => { $term => $term_count, ... } } }
#
# if ngram_size is > 1, use the unstemmed phrases of ngram_size as the stems
sub count_stems($$)
{
    my ( $self, $sentences_and_story_languages ) = @_;

    # Set any duplicate sentences blank
    my $dup_sentences = {};
    map {
        $dup_sentences->{ $_->{ 'sentence' } }
          ? ( $_->{ 'sentence' } = '' )
          : ( $dup_sentences->{ $_->{ 'sentence' } } = 1 );
    } grep { defined( $_->{ 'sentence' } ) } @{ $sentences_and_story_languages };

    # Tokenize each sentence and add count to $words for each token
    my $stem_counts = {};
    for my $sentence_and_story_language ( @{ $sentences_and_story_languages } )
    {
        unless ( defined( $sentence_and_story_language ) )
        {
            next;
        }

        my $sentence = $sentence_and_story_language->{ 'sentence' };
        unless ( defined( $sentence ) )
        {
            next;
        }

        my $story_language = $sentence_and_story_language->{ 'story_language' };
        unless ( defined( $story_language ) )
        {
            $story_language = '';
        }

        # Very long sentences tend to be noise -- html text and the like.
        $sentence = substr( $sentence, 0, $MAX_SENTENCE_LENGTH );

        # Remove urls so they don't get tokenized into noise
        $sentence =~ s~https?://[^\s]+~~gi;

        my $sentence_language = MediaWords::Util::IdentifyLanguage::language_code_for_text( $sentence );
        unless ( $sentence_language )
        {
            TRACE "Unable to determine sentence language for sentence '$sentence', falling back to default language";
            $sentence_language = MediaWords::Languages::Language::default_language_code();
        }
        unless ( MediaWords::Languages::Language::language_is_enabled( $story_language ) )
        {
            TRACE "Language '$sentence_language' for story is not enabled, falling back to default language";
            $story_language = MediaWords::Languages::Language::default_language_code();
        }
        unless ( MediaWords::Languages::Language::language_is_enabled( $sentence_language ) )
        {
            TRACE "Language '$sentence_language' for sentence '$sentence' is not enabled, falling back to default language";
            $sentence_language = MediaWords::Languages::Language::default_language_code();
        }

        # Language objects are cached in ::Languages::Language, no need to have a separate cache
        my $lang_en       = MediaWords::Languages::Language::default_language();
        my $lang_story    = MediaWords::Languages::Language::language_for_code( $story_language );
        my $lang_sentence = MediaWords::Languages::Language::language_for_code( $sentence_language );

        # Tokenize into words
        my $sentence_words = $lang_sentence->split_sentence_to_words( $sentence );

        # Remove stopwords;
        # (don't stem stopwords first as they will usually be stemmed too much)
        my $combined_stopwords = {};
        unless ( $self->include_stopwords )
        {
            # Use both sentence's language and English stopwords
            $combined_stopwords = $self->_combine_stopwords( [ $lang_en, $lang_story, $lang_sentence ] );
        }

        sub _word_is_valid_token($$)
        {
            my ( $word, $stopwords ) = @_;

            # Remove numbers
            if ( $word =~ /^\d+?$/ )
            {
                return 0;
            }

            # Remove stopwords
            if ( $stopwords->{ $word } )
            {
                return 0;
            }

            return 1;
        }

        $sentence_words = [ grep { _word_is_valid_token( $_, $combined_stopwords ) } @{ $sentence_words } ];

        # Stem using sentence language's algorithm
        my $sentence_word_stems =
          ( $self->ngram_size > 1 ) ? $sentence_words : $lang_sentence->stem_words( $sentence_words );

        my $n          = $self->ngram_size;
        my $num_ngrams = scalar( @{ $sentence_words } ) - $n + 1;

        my $sentence_stem_counts = {};

        for ( my $i = 0 ; $i < $num_ngrams ; ++$i )
        {
            my $term = join( ' ', @{ $sentence_words }[ $i ..      ( $i + $n - 1 ) ] );
            my $stem = join( ' ', @{ $sentence_word_stems }[ $i .. ( $i + $n - 1 ) ] );

            $sentence_stem_counts->{ $stem } //= {};
            ++$sentence_stem_counts->{ $stem }->{ count };

            next if ( $sentence_stem_counts->{ $stem }->{ count } > $MAX_REPEATS_PER_SENTENCE );

            $stem_counts->{ $stem } //= {};
            ++$stem_counts->{ $stem }->{ count };

            $stem_counts->{ $stem }->{ terms } //= {};
            ++$stem_counts->{ $stem }->{ terms }->{ $term };
        }
    }

    return $stem_counts;
}

# connect to solr server directly and count the words resulting from the query
sub _get_words_from_solr_server($)
{
    my ( $self ) = @_;

    my $db = $self->db;

    unless ( $self->q() || ( $self->fq && @{ $self->fq } ) )
    {
        return [];
    }

    my $solr_params = {
        q    => $self->q(),
        fq   => $self->fq,
        rows => $self->sample_size,
        fl   => 'story_sentences_id',
        sort => 'random_1 asc'
    };

    DEBUG( "executing solr query ..." );
    DEBUG Dumper( $solr_params );

    my $solr_data = MediaWords::Solr::query( $self->db, $solr_params );

    my $sentences_found = $solr_data->{ response }->{ numFound };

    my $story_sentences_ids = [ map { int( $_->{ story_sentences_id } ) } @{ $solr_data->{ response }->{ docs } } ];

    my $ids_table = $db->get_temporary_ids_table( $story_sentences_ids );

    my $sentences_and_story_languages = $db->query(
        <<SQL

        SELECT story_sentences.sentence,
               stories.language AS story_language

        -- Select from temporary table and INNER JOIN afterwards because if
        -- temporary table is empty, PostgreSQL decides to do sequential scan
        -- on "stories" table
        FROM $ids_table
            INNER JOIN story_sentences
              ON $ids_table.id = story_sentences.story_sentences_id
            INNER JOIN stories
                ON story_sentences.stories_id = stories.stories_id
        WHERE
            not stories.url ilike '%.pdf' -- don't try to count words from pdfs
SQL
    )->hashes;

    DEBUG( "counting sentences..." );
    my $words = $self->count_stems( $sentences_and_story_languages );
    DEBUG( "done counting sentences" );

    my @word_list;
    while ( my ( $stem, $count ) = each( %{ $words } ) )
    {
        push( @word_list, [ $stem, $count->{ count } ] );
    }

    @word_list = sort { $b->[ 1 ] <=> $a->[ 1 ] } @word_list;

    my $counts = [];
    for my $w ( @word_list )
    {
        my $terms = $words->{ $w->[ 0 ] }->{ terms };
        my ( $max_term, $max_term_count );
        while ( my ( $term, $term_count ) = each( %{ $terms } ) )
        {
            if ( !$max_term || ( $term_count > $max_term_count ) )
            {
                $max_term       = $term;
                $max_term_count = $term_count;
            }
        }

        if ( !MediaWords::Util::Text::is_valid_utf8( $w->[ 0 ] ) || !MediaWords::Util::Text::is_valid_utf8( $max_term ) )
        {
            WARN "invalid utf8: $w->[ 0 ] / $max_term";
            next;
        }

        push( @{ $counts }, { stem => $w->[ 0 ], count => $w->[ 1 ], term => $max_term } );
    }

    splice( @{ $counts }, $self->num_words );

    if ( $self->include_stats )
    {
        return {
            stats => {
                num_words_returned     => scalar( @{ $counts } ),
                num_sentences_returned => scalar( @{ $sentences_and_story_languages } ),
                num_sentences_found    => $sentences_found,
                num_words_param        => $self->num_words,
                sample_size_param      => $self->sample_size
            },
            words => $counts
        };
    }
    else
    {
        return $counts;
    }
}

# fetch word counts from a separate server
sub _get_remote_words
{
    my ( $self ) = @_;

    my $url = MediaWords::Util::Config::get_config->{ mediawords }->{ solr_wc_url };
    my $key = MediaWords::Util::Config::get_config->{ mediawords }->{ solr_wc_key };

    unless ( $url && $key )
    {
        return undef;
    }

    my $ua = MediaWords::Util::Web::UserAgent->new();

    $ua->set_timeout( 900 );
    $ua->set_max_size( undef );

    my $uri          = URI->new( $url );
    my $query_params = $self->_get_cgi_param_hash();

    $query_params->{ no_remote } = 1;
    $query_params->{ key }       = $key;

    $uri->query_form( $query_params );

    my $request = MediaWords::Util::Web::UserAgent::Request->new( 'GET', $uri->as_string );
    $request->set_header( 'Accept', 'application/json' );
    my $res = $ua->request( $request );

    unless ( $res->is_success )
    {
        die( "error retrieving words from solr: " . $res->decoded_content );
    }

    my $words = MediaWords::Util::JSON::decode_json( $res->decoded_content );

    unless ( $words && ref( $words ) )
    {
        die( "Unable to parse json" );
    }

    return $words;
}

# return CHI cache for word counts
sub _get_cache
{
    my $mediacloud_data_dir = MediaWords::Util::Config::get_config->{ mediawords }->{ data_dir };

    return CHI->new(
        driver           => 'File',
        expires_in       => '1 day',
        expires_variance => '0.1',
        root_dir         => "${ mediacloud_data_dir }/cache/word_counts",
        depth            => 4
    );
}

# return key that uniquely identifies the query
sub _get_cache_key
{
    my ( $self ) = @_;

    $_wc_cache_version //= MediaWords::Util::Config::get_config->{ mediawords }->{ wc_cache_version } || '1';

    my $meta = $self->meta;

    my $keys = $self->get_cgi_param_attributes;

    my $hash_key = "$_wc_cache_version:" . Dumper( map { $meta->get_attribute( $_ )->get_value( $self ) } @{ $keys } );

    return $hash_key;
}

# get a cached value for the given word count
sub _get_cached_words
{
    my ( $self ) = @_;

    return $self->_get_cache->get( $self->_get_cache_key );
}

# set a cached value for the given word count
sub _set_cached_words
{
    my ( $self, $value ) = @_;

    return $self->_get_cache->set( $self->_get_cache_key, $value );
}

# get sorted list of most common words in sentences matching a Solr query,
# exclude stop words. Assumes english stemming and stopwording for now.
sub get_words
{
    my ( $self ) = @_;

    my $words = $self->_get_cached_words;

    if ( $words )
    {
        return $words;
    }

    unless ( $self->no_remote )
    {
        $words = $self->_get_remote_words;
    }

    $words ||= $self->_get_words_from_solr_server();

    $self->_set_cached_words( $words );

    return $words;
}

1;
