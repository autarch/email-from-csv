package EFC;

use strict;
use warnings;
use utf8;

use Courriel::Builder -all => { -prefix => 'cb_' };
use Email::Address;
use Email::Sender::Simple qw( sendmail );
use Email::Valid;
use Encode qw( decode );
use Encode::ZapCP1252 qw( zap_cp1252 );
use File::Slurp;
use IO::File;
use Markdent::Simple::Document;
use Text::CSV_XS;
use Text::Template;

use Moose;
use Moose::Util::TypeConstraints;

with 'MooseX::Getopt';

has 'name' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has 'dir' => (
    is      => 'ro',
    isa     => 'Str',
    default => q{.},
);

has '_body_file' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { $_[0]->dir() . q{/} . $_[0]->name() . '-body' },
);

has '_body_template' => (
    is      => 'ro',
    isa     => 'Text::Template',
    lazy    => 1,
    builder => '_build_body_template',
);

class_type('Email::Address');

subtype 'EFCEmailAddress' => as 'Email::Address';

coerce 'EFCEmailAddress' => from 'Str' =>
    via { ( Email::Address->parse($_) )[0] };

has 'from' => (
    is       => 'ro',
    isa      => 'EFCEmailAddress',
    required => 1,
    coerce   => 1,
);

has 'subject' => (
    is       => 'ro',
    isa      => 'Str',
    required => 1,
);

has '_subject_template' => (
    is      => 'ro',
    isa     => 'Text::Template',
    lazy    => 1,
    builder => '_build_subject_template',
);

has '_csv_file' => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    default => sub { $_[0]->dir() . q{/} . $_[0]->name() . '.csv' },
);

has '_seen_map' => (
    traits   => ['Hash'],
    is       => 'ro',
    isa      => 'HashRef[Str]',
    default  => sub { {} },
    init_arg => undef,
    handles  => {
        _record_as_seen => 'set',
        _seen           => 'get',
    },
);

has 'send' => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has 'test' => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

MooseX::Getopt::OptionTypeMap->add_option_type_to_map(
    'EFCEmailAddress' => '=s' );

sub BUILD {
    my $self = shift;

    die 'Must provide a name for the email address'
        unless $self->from()->phrase();

    die 'Cannot pass both --send and --test'
        if $self->send() && $self->test();

    return $self;
}

sub _build_subject_template {
    my $self = shift;

    return Text::Template->new( TYPE => 'STRING',
        SOURCE => $self->subject() );
}

sub _build_body_template {
    my $self = shift;

    my $body = decode( 'utf-8', read_file( $self->_body_file() ) )
        or die 'empty body';

    $body = $self->_demoronize($body);

    return Text::Template->new( TYPE => 'STRING', SOURCE => $body );
}

{
    my %map = (
        '‚' => ',',      # 82, SINGLE LOW-9 QUOTATION MARK
        '„' => ',,',     # 84, DOUBLE LOW-9 QUOTATION MARK
        '…' => '...',    # 85, HORIZONTAL ELLIPSIS
        'ˆ'  => '^',      # 88, MODIFIER LETTER CIRCUMFLEX ACCENT
        '‘' => "'",      # 91, LEFT SINGLE QUOTATION MARK
        '’' => "'",      # 92, RIGHT SINGLE QUOTATION MARK
        '’' => "'",
        '“' => '"',      # 93, LEFT DOUBLE QUOTATION MARK
        '”' => '"',      # 94, RIGHT DOUBLE QUOTATION MARK
        '“' => '"',
        '”' => '"',
        '•' => '*',      # 95, BULLET
        '–' => '-',      # 96, EN DASH
        '—' => '-',      # 97, EM DASH
        '‹' => '<',      # 8B, SINGLE LEFT-POINTING ANGLE QUOTATION MARK
        '›' => '>',      # 9B, SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
    );

    sub _demoronize {
        my $self = shift;
        my $body = shift;

        zap_cp1252($body);

        $body =~ s/$_/$map{$_}/g for keys %map;

        return $body;
    }
}

sub run {
    my $self = shift;

    my $csv = Text::CSV_XS->new( { binary => 1 } );

    my $io = IO::File->new( $self->_csv_file(), 'r' )
        or die $!;

    my $header = $csv->getline($io);

    $self->_check_header($header);

    $csv->column_names( @{$header} );

    until ( $io->eof() ) {
        my $fields = $csv->getline_hr($io);

        my $address = $fields->{email};

        next
            unless defined $address && length $address;

        $address =~ s/^\s+|\s+$//g;

        next unless Email::Valid->address( $address );

        next if $self->_seen($address);

        my $email = $self->_create_email($fields);

        if ( $self->send() || $self->test() ) {
            $self->_send_email($email);
            exit 0 if $self->test();
        }

        $self->_record_as_seen( $address => 1 );
    }
}

sub _check_header {
    my $self   = shift;
    my $header = shift;

    my %fields = map { $_ => 1 } @{$header};

    die 'CSV file does not include an email address (invalid header?)'
        unless $fields{email};
}

sub _create_email {
    my $self   = shift;
    my $fields = shift;

    my $subject = $self->_subject_template()->fill_in( HASH => $fields );
    my $body = $self->_body_template()->fill_in( HASH => $fields );

    print "Creating email for $fields->{email}\n";

    my $html = Markdent::Simple::Document->new()->markdown_to_html(
        title    => $subject,
        markdown => $body,
    );

    my $to = $self->test() ? 'autarch@urth.org' : $fields->{email};

    return cb_build_email(
        cb_from( $self->from() ),
        cb_to($to),
        cb_subject($subject),
        cb_plain_body($body),
        cb_html_body($html)
    );
}

sub _send_email {
    my $self  = shift;
    my $email = shift;

    sendmail($email);
}

no Moose;
no Moose::Util::TypeConstraints;

1;
