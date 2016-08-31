package Util::Parser;

use strict;
use warnings;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use DBI;
use File::Spec;
use IO::All -utf8;
use Mojo::DOM;
use Moo;
use Text::CSV_XS;
use URI;
use List::Util qw(first);
use List::MoreUtils qw(uniq);

use Util::DB;

my %links;

has perldoc_url => ( is => 'lazy' );
sub _build_perldoc_url {
    'http://perldoc.perl.org/';
}

has indexer => (
    is       => 'ro',
    isa      => sub { die 'Not a Util::Index' unless ref $_[0] eq 'Util::Index' },
    required => 1,
    doc      => 'Used to generate indices for parsing',
);

has db => (
    is      => 'ro',
    isa     => sub { die 'Not a Util::DB' unless ref $_[0] eq 'Util::DB' },
    doc     => 'Internal database interface',
    builder => 1,
    lazy    => 1,
);

sub _build_db {
    return Util::DB->new;
}

sub dom_for_file { Mojo::DOM->new( io($_[0])->all ); }

# Parsers for the 'index-*' keys will run on *all* files produced from parsing
# links in the index files.
# Parsers for other keys (basenames) will only run on the matching file.
my %parser_map = (
    'index-faq'       => ['parse_faq'],
    'index-functions' => ['parse_functions'],
    'index-module'    => ['get_synopsis'],
    'index-default'   => ['get_anchors'],
    'perldiag'        => ['parse_diag_messages'],
    'perlglossary'    => ['parse_glossary_definitions'],
    'perlop'          => ['parse_operators'],
    'perlpod'         => ['parse_pod_formatting_codes'],
    'perlpodspec'     => ['parse_pod_commands'],
    'perlre'          => [
        'parse_regex_modifiers',
    ],
    'perlrun'         => ['parse_cli_switches'],
    'perlvar'         => ['parse_variables'],
);

my @parsers = sort keys %parser_map;

sub get_parsers {
    my ($index, $basename) = @_;
    my $index_parsers = $parser_map{$index};
    my $basename_parsers = $parser_map{$basename};
    return (@{$index_parsers || []}, @{$basename_parsers || []});
}

my %link_parser_for_index = (
    'functions' => 'parse_index_functions_links',
    'default'   => 'parse_index_links',
);

sub link_parser_for_index {
    my $index = shift;
    $index =~ s/index-//;
    return $link_parser_for_index{$index} // $link_parser_for_index{default};
}

sub parse_index_links {
    my ($self, $dom) = @_;
    my $content = $dom->find('ul')->[4];
    return @{$content->find('a')->to_array};
}

sub normalize_dom_links {
    my ($url, $dom)  = @_;
    $dom->find('a')->map(sub {
        my $link = $_[0]->attr('href') or return;
        $_[0]->attr(href => URI->new_abs($link, $url)->as_string);
    });
}

#######################################################################
#                       Normalize Parse Results                       #
#######################################################################

sub normalize_article {
    my ($article) = @_;
    my $text = $article->{text};
    $text =~ s/\n/ /g;
    # Okay, the parser *really* hates links...
    my $dom = Mojo::DOM->new->parse($text);
    $dom->find('a')->map(tag => 'span');
    $text = $dom->to_string;
    return {
        %$article,
        text => $text,
    };
}

sub normalize_parse_result {
    my ($parsed) = @_;
    $parsed->{articles} = [
        map { normalize_article($_) } (@{$parsed->{articles}})
    ];
    return $parsed;
}

sub dom_for_parsing {
    my ($page) = @_;
    # NOTE: This probably destructively modifies the pages DOM.
    my $dom = $page->dom;
    normalize_dom_links($page->url, $dom);
    $dom->find('strong')->map('strip');
    return $dom;
}

sub parse_page {
    my ( $self, $index, $page ) = @_;
    my @parsed;
    foreach my $parser (@{$index->parsers_for($page)}) {
        push @parsed, $parser->(dom_for_parsing($page));
    }
    foreach my $parsed (@parsed) {
        $parsed = normalize_parse_result($parsed);
        for my $article ( @{ $parsed->{articles} } ) {
            $self->db->article($article);
        }

        for my $alias ( @{ $parsed->{aliases} } ) {
            $self->db->alias( $alias->{new}, $alias->{orig} );
        }
        for my $disambiguation ( @{ $parsed->{disambiguations} } ) {
            $self->db->disambiguation( $disambiguation );
        }
    }
}

sub text_for_disambiguation {
    my ($abstract) = @_;
    return $abstract;
}

sub parse {
    my ( $self ) = @_;

    my @pages = @{$self->indexer->build_indices};
    foreach my $page (@pages) {
        $self->parse_page($self->indexer, $page);
    }

    $self->db->build_output;

}

1;
