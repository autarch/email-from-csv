package EFC;

use strict;
use warnings;

use Email::Address;
use Email::Date;
use Email::MessageID;
use Email::Send;
use Email::Simple::Creator;
use Email::Valid;
use Encode::ZapCP1252 qw( zap_cp1252 );
use File::Slurp;
use IO::File;
use Text::CSV_XS;
use Text::Template;

use Moose;
use Moose::Util::TypeConstraints;


with 'MooseX::Getopt';

has 'name' =>
    ( is       => 'ro',
      isa      => 'Str',
      required => 1,
    );

has '_body_template' =>
    ( is      => 'ro',
      isa     => 'Text::Template',
      lazy    => 1,
      builder => '_build_body_template',
    );

class_type( 'Email::Address' );

subtype 'EFC.EmailAddress'
    => as 'Email::Address';

coerce 'EFC.EmailAddress'
    => from 'Str'
    => via { ( Email::Address->parse($_) )[0] };

has 'from' =>
    ( is       => 'ro',
      isa      => 'EFC.EmailAddress',
      required => 1,
      coerce   => 1,
    );

has 'subject' =>
    ( is       => 'ro',
      isa      => 'Str',
      required => 1,
    );

has '_subject_template' =>
    ( is      => 'ro',
      isa     => 'Text::Template',
      lazy    => 1,
      builder => '_build_subject_template',
    );

has 'send' =>
    ( is      => 'ro',
      isa     => 'Bool',
      default => 0,
    );

has 'test' =>
    ( is      => 'ro',
      isa     => 'Bool',
      default => 0,
    );

MooseX::Getopt::OptionTypeMap->add_option_type_to_map
    ( 'EFC.EmailAddress' => '=s' );

$Email::Send::Sendmail::SENDMAIL = '/usr/sbin/sendmail';

has '_sender' =>
    ( is      => 'ro',
      isa     => 'Email::Send',
      default => sub { Email::Send->new( { mailer => 'Sendmail' } ) },
    );



sub BUILD
{
    my $self = shift;

    die 'Must provide a name for the email address'
        unless $self->from()->phrase();

    die 'Cannot pass both --send and --test'
        if $self->send() && $self->test();

    return $self;
}

sub _build_subject_template
{
    my $self = shift;

    return Text::Template->new( TYPE => 'STRING', SOURCE => $self->subject() );
}

sub _build_body_template
{
    my $self = shift;

    my $body_file = $self->name() . '-body';

    my $body = read_file($body_file)
        or die 'empty body';

    $self->_demoronize($body);

    return Text::Template->new( TYPE => 'STRING', SOURCE => $body );
}

sub _demoronize
{
    my $self = shift;
    my $body = shift;

    zap_cp1252($body);
}

sub run
{
    my $self = shift;

    my $csv = Text::CSV_XS->new( { binary => 1 } );

    my $io = IO::File->new( $self->name() . '.csv', 'r' )
        or die $!;

    my $header = $csv->getline($io);

    $self->_check_header($header);

    $csv->column_names( @{ $header } );

    until ( $io->eof() )
    {
        my $fields = $csv->getline_hr($io);

        next unless
            defined $fields->{email} && length $fields->{email};

        next unless Email::Valid->address( $fields->{email} );

        my $email = $self->_create_email($fields);

        if ( $self->send() || $self->test() )
        {
            $self->_send_email($email);
            exit 0 if $self->test();
        }
    }
}

sub _check_header
{
    my $self   = shift;
    my $header = shift;

    my %fields = map { $_ => 1 } @{ $header };

    die 'CSV file does not include an email address (invalid header?)'
        unless $fields{email};
}

sub _create_email
{
    my $self   = shift;
    my $fields = shift;

    my $subject = $self->_subject_template()->fill_in( HASH => $fields );
    my $body = $self->_body_template()->fill_in( HASH => $fields );

    print "Creating email for $fields->{email}\n";

    my $to = $self->test() ? 'autarch@urth.org' : $fields->{email};

    my $email =
        Email::Simple->create
            ( header =>
              [ From           => $self->from()->as_string(),
                To             => $to,
                Subject        => $subject,
                Date           => Email::Date::format_date(time),
                'Message-Id'   => Email::MessageID->new()->in_brackets(),
                'Content-Type' => 'text/plain; charset=ascii',
              ],
              body => $body,
            );
}

sub _send_email
{
    my $self  = shift;
    my $email = shift;

    $self->_sender()->send($email);
}

no Moose;
no Moose::Util::TypeConstraints;

1;
