package WWW::Collmex;
use strict;
use warnings;
use WWW::Mechanize;
use XML::Dumper;
use Data::Dumper;
use File::Util;
use HTML::TreeBuilder;
use Time::ParseDate;
use Class::Date qw/localdate/;
use POSIX qw/strftime/;

use 5.010000;
our $VERSION = '0.1';

use constant BASE_URL  => 'https://www.collmex.de/cgi-bin/cgi.exe?';
use constant SLEEP_AFTER_TIMEOUT => 60;

sub new
{
    my ($class, $args_ref ) = @_;
    my $self = {}; 
    
    my %args = %$args_ref;
    # Some Defaults
    foreach my $arg (keys %args)
    {
        $self->{$arg} = $args{$arg};
    }

    # Check for required parameters
    foreach( qw/account_number user_id password/ )
    {
        unless( $self->{$_} )
        {
            die( "Required parameter $_ not defined\n" );
        }
    }

    # Insert the competition details
    $self->{urls}->{login} = BASE_URL . $self->{account_number} . ',0,login';

    # A counter to see how many requests this object makes
    $self->{requests_made} = 0;

    # Create a new Mech for each connection (no shared cookies)
    my $mech = WWW::Mechanize->new();

    # use a proxy if it's defined
    if( $self->{proxy} )
    {
        $mech->proxy( ['http', 'ftp'], $self->{proxy} );
    }
    $self->{mech} = $mech;

    bless($self);
    return($self);
}

# Allow login to your account
sub login
{
    my( $self, $force ) = @_;

    # It's safe to call login often - it will only log in if necessary, or a re-login is forced
    if( $force || ! $self->{logged_in} )
    {
        $self->debug( "Logging in $self->{account_number}/$self->{user_id}" );
        $self->getURL( $self->{urls}->{login} );
        $self->submitForm( 'form1', 
                           { 'group_benutzerId' => $self->{user_id},
                             'group_kennwort'   => $self->{password} } );
        
        if( $self->content !~ />Abmelden</ )
        {
            $self->die( "Seems login failed..." );
        }
        $self->{logged_in} = 1;
    }

    # Now get some URLs from the first page
    my %url_keys = ( 'taetigkeit_erfassen' => 'Tätigkeiten erfassen',
                     'belege_buchen'       => 'Belege buchen',
        );
    
    foreach( keys( %url_keys ) )
    {
        my $link = $self->{mech}->find_link( text => $url_keys{$_} );
        if( $link )
        {
            $self->{urls}->{$_} = $link->url();
        }
        else
        {
            warn( "Couldn't find url for $url_keys{$_}\n" );
        }
    }
}

sub taetigkeitErfassen
{
    my( $self, $details ) = @_;

    if( ! $self->{urls}->{taetigkeit_erfassen} )
    {
        $self->die( "Don't have a url for taetigkeit_erfassen" );
    }

    # Get the year and month from the date
    my $booking_time = localdate( parsedate( $details->{date} ) );
    $details->{month} = $booking_time->month();
    $details->{year} = $booking_time->year();
    $details->{date} = strftime( "%d.%m.%Y", localtime( $booking_time->epoch ) );

    my $debug_txt = '';
    foreach( qw/employee company project rate date year month from_time to_time breaks notes/ )
    {
        $debug_txt .= sprintf( "    %-20s %s\n", $_, $details->{$_} );
    }
    $self->debug( "TaetigkeitErfassen:\n$debug_txt" );

    $self->getURL( $self->{urls}->{taetigkeit_erfassen} );
    
    eval
    {
        # Set the headers
        $self->submitForm( 'form1', 
                           { 
                               'group_mitarbeiterNr' => $details->{employee},
                               'group_firmaNr'       => $details->{company},
                               'group_monat'         => $details->{month},
                               'group_jahr'          => $details->{year},
                               'group_sortierung'    => 1,
                               'table'               => 1,
                           } );
        if( $self->content =~ m/style="color:red"/ )
        {
            $self->die( "Something went wrong (1)..." );
        }

        $self->submitForm( 'form1', 
                           { 
                               'table_1_projektNr'   => $details->{project},
                           } );
        if( $self->content =~ m/style="color:red"/ )
        {
            $self->die( "Something went wrong (1)..." );
        }
#        die( 'Test' );
        # Enter the details and save
        $self->submitForm( 'form1',
                           {
                               'table_1_satz'         => $details->{project} . ',' . $details->{rate},
                               'table_1_datum'        => $details->{date},
                               'table_1_von'          => $details->{from_time},
                               'table_1_bis'          => $details->{to_time},
                               'table_1_pausen'       => $details->{breaks},
                               'table_1_beschreibung' => $details->{notes},
                           }, undef, 'speichern', 
            );
        if( $self->content =~ m/style="color:red"/ )
        {
            $self->die( "Something went wrong (3)..." );
        }
    };
    if( $@ )
    {
        $self->die( $@ );
    }
}

sub submitForm
{
    my( $self, $form_name, $fields, $ticks, $button ) = @_;

    if( ! $self->{mech}->form_name( $form_name ) )
    {
        $self->die( "Could not find form ($form_name)" );
    }

    if( $fields && ref( $fields ) eq 'HASH' )
    {
        foreach( keys( %$fields ) )
        {
            $self->{mech}->field( $_, $fields->{$_} );
        }
    }

    if( $ticks && ref( $ticks ) eq 'HASH' )
    {
        foreach( keys( %$ticks ) )
        {
            $self->{mech}->tick( $_, $ticks->{$_} );
        }
    }
    
    my $success = undef;
    my $response = undef;
    while( ! $success )
    {
        eval
        {
            if( $button )
            {
                $response = $self->{mech}->click_button( name => $button );
            }
            else
            {
                $response = $self->{mech}->submit_form();
            }
            $self->{requests_made}++;
            if( $response->code != 200 )
            {
                $self->die( "Server responded with code " . $response->code() . " to uri " . $self->{mech}->uri() );
            }
        };
        if( $@ )
        {
            # If the error was a timeout, wait and try again...
            if( $@ =~ m/(timeout|closed connection without sending any data back)/i )
            {
                $self->logLast();
                print "Connection timed out... going to try again in " . SLEEP_AFTER_TIMEOUT . " seconds\n";
                sleep( SLEEP_AFTER_TIMEOUT );
            }
            else
            {
                $self->die( $@ );
            }
        }
        else
        {
            $success = 1;
        }
    }
}

sub getURL
{
    my( $self, $url ) = @_;
    # Assuming the first request will always be a get, set a referer for the first one
    # just to confuse the server a bit more...
    if( $self->{requests_made} == 0 && $self->{referer} )
    {
        $self->{mech}->add_header( Referer => $self->{referer} );
    }
    my $success = undef;
    my $response = undef;
    while( ! $success )
    {
        eval
        {
            $response = $self->{mech}->get( $url );
            $self->{requests_made}++;
            $self->{mech}->delete_header( 'Referer' );

            if( $response->code != 200 )
            {
                $self->die( "Server responded with code " . $response->code() . " to uri " . $self->{mech}->uri() );
            }
        };
        if( $@ )
        {
            # If the error was a timeout, wait and try again...
            if( $@ =~ m/(timeout|closed connection without sending any data back)/i )
            {
                $self->logLast();
                print "Connection timed out... going to try again in " . SLEEP_AFTER_TIMEOUT . " seconds\n";
                sleep( SLEEP_AFTER_TIMEOUT );
            }
            else
            {
                $self->die( $@ );
            }
        }
        else
        {
            $success = 1;
        }
    }
}


sub postURL
{
    my( $self, $url, $post_args ) = @_;
    
    my $success = undef;
    my $response = undef;
    while( ! $success )
    {
        eval
        {
            $response = $self->{mech}->post( $url, $post_args );
            $self->{requests_made}++;
            if( $response->code != 200 )
            {
                $self->die( "Server responded with code " . $response->code() . " to uri " . $self->{mech}->uri() );
            }
        };
        if( $@ )
        {
            # If the error was a timeout, wait and try again...
            if( $@ =~ m/(timeout|closed connection without sending any data back)/i )
            {
                $self->logLast();
                print "Connection timed out... going to try again in " . SLEEP_AFTER_TIMEOUT . " seconds\n";
                sleep( SLEEP_AFTER_TIMEOUT );
            }
            else
            {
                $self->die( $@ );
            }
        }
        else
        {
            $success = 1;
        }
    }
}

sub content
{
    my $self = shift;
    return $self->{mech}->response->content;
}

sub response
{
    my $self = shift;
    return $self->{mech}->response;
}

sub requests
{
    my $self = shift;
    return $self->{requests_made};
}

# Die nicely...
sub die
{
    my( $self, $message ) = @_;
    $self->logLast();
    die( $message . "\n" );
}

# Log the last connection details for debugging...
sub logLast
{
    my( $self ) = @_;
    my $f = File::Util->new();

    if( $self->{mech} )
    {
        pl2xml( $self->{mech}, 'last_mech.xml' );

        $f->write_file( 'file'    => 'last_mech.txt',
                        'content' => Dumper( $self->{mech} ) );
        if( $self->{mech}->response() )
        {
            $f->write_file( 'file'    => 'last_response.txt', 
                            'content' => Dumper( $self->{mech}->response() ) );

            if( $self->{mech}->response()->content() )
            {
                $f->write_file( 'file'    => 'last_content.html', 
                                'content' => $self->{mech}->response()->content() );
            }
        }
    }
}

sub debug
{
    my( $self, $message ) = @_;
    if( $self->{debug} )
    {
        print $message . "\n";
    }
}
__END__

=pod

=head1 NAME

Collmex

=head1 SYNOPSIS

  use Collmex;
  my $st = Collmex->new( 'account_number' => $account_number, 'user_id' => $user_id, 'password' => $password );

=head1 DESCRIPTION

Interface to Collmex bookkeeping

=cut
