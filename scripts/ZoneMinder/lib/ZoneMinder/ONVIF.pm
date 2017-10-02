# ==========================================================================
#
# ZoneMinder ONVIF Module, $Date$, $Revision$
# Copyright (C) 2001-2008  Philip Coombes
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# ==========================================================================
#
# This module contains the common definitions and functions used by the rest
# of the ZoneMinder scripts
#
package ZoneMinder::ONVIF;

use 5.006;
use strict;
use warnings;

require Exporter;
require ZoneMinder::Base;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = (
    functions => [ qw(
      ) ]
    );
push( @{$EXPORT_TAGS{all}}, @{$EXPORT_TAGS{$_}} ) foreach keys %EXPORT_TAGS;

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw();

our $VERSION = $ZoneMinder::Base::VERSION;

use Getopt::Std;
use Data::UUID;

use vars qw( $verbose $soap_version );

require ONVIF::Client;

require WSDiscovery10::Interfaces::WSDiscovery::WSDiscoveryPort;
require WSDiscovery10::Elements::Header;
require WSDiscovery10::Elements::Types;
require WSDiscovery10::Elements::Scopes;

require WSDiscovery::TransportUDP;

sub deserialize_message {
  my ($wsdl_client, $response) = @_;

# copied and adapted from SOAP::WSDL::Client

# get deserializer 
  my $deserializer = $wsdl_client->get_deserializer();
  
  if(! $deserializer) {
    $deserializer = SOAP::WSDL::Factory::Deserializer->get_deserializer({
        soap_version => $wsdl_client->get_soap_version(),
        %{ $wsdl_client->get_deserializer_args() },
        });
  }
# set class resolver if serializer supports it
  $deserializer->set_class_resolver( $wsdl_client->get_class_resolver() )
    if ( $deserializer->can('set_class_resolver') );

# Try deserializing response - there may be some,
# even if transport did not succeed (got a 500 response)
  if ( ! $response ) {
    return;
  }

# as our faults are false, returning a success marker is the only
# reliable way of determining whether the deserializer succeeded.
# Custom deserializers may return an empty list, or undef,
# and $@ is not guaranteed to be undefined.
  my ($success, $result_body, $result_header) = eval {
    (1, $deserializer->deserialize( $response ));
  }; 
  if (defined $success) {
    return wantarray
    ? ($result_body, $result_header)
    : $result_body;
  } elsif (blessed $@) { #}&& $@->isa('SOAP::WSDL::SOAP::Typelib::Fault11')) {
    return $@;
  } 

  #else
  return $deserializer->generate_fault({
      code => 'soap:Server',
      role => 'urn:localhost',
      message => "Error deserializing message: $@. \n"
      . "Message was: \n$response"
    });
} # end sub deserialize_message

sub interpret_messages {
  my ($svc_discover, $services, @responses ) = @_;

  my @results;
  foreach my $response ( @responses ) {

    if($verbose) {
      print "Received message:\n" . $response . "\n";
    }

    my $result = deserialize_message($svc_discover, $response);
    if(not $result) {
      print "Error deserializing message. No message returned from deserializer.\n" if $verbose;
      next;
    }

    my $xaddr;
    foreach my $l_xaddr (split ' ', $result->get_ProbeMatch()->get_XAddrs()) {
#   find IPv4 address
      print "l_xaddr = $l_xaddr\n" if $verbose;
      if($l_xaddr =~ m|//[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[:/]|) {
        $xaddr = $l_xaddr;
        last;
      } else {
        print STDERR "Unable to find IPv4 address from xaddr $l_xaddr\n";
      }
    }

# No usable address found
    next if not $xaddr;

# ignore multiple responses from one service
    next if defined $services->{$xaddr};
    $services->{$xaddr} = 1;

    print "$xaddr, " . $svc_discover->get_soap_version() . ", ";

    print "(";
    my $scopes = $result->get_ProbeMatch()->get_Scopes();
    my $count = 0;
    my %scopes;
    foreach my $scope(split ' ', $scopes) {
      if($scope =~ m|onvif://www\.onvif\.org/(.+)/(.*)|) {
        my ($attr, $value) = ($1,$2);
        if( 0 < $count ++) {
          print ", ";
        }
        print $attr . "=\'" . $value . "\'";
        $scopes{$attr} = $value;
      }
    }
    print ")\n";
    push @results, { xaddr=>$xaddr,
      soap_version  => $svc_discover->get_soap_version(),
      scopes  =>  \%scopes,
    };

  }
  return @results;
} # end sub interpret_messages

# functions

sub discover {
  my ( $soap_version ) = @_;
  my @results;

## collect all responses
  my @responses = ();

  no warnings 'redefine';

  *WSDiscovery::TransportUDP::_notify_response = sub {
    my ($transport, $response) = @_;
    push @responses, $response;
  };

## try both soap versions
  my %services;

  my $uuid_gen = Data::UUID->new();

  if ( ( ! $soap_version ) or ( $soap_version eq '1.1' ) ) {

    if($verbose) {
      print "Probing for SOAP 1.1\n"
    }
    my $svc_discover = WSDiscovery10::Interfaces::WSDiscovery::WSDiscoveryPort->new({
#    no_dispatch => '1',
        });
    $svc_discover->set_soap_version('1.1');

    my $uuid = $uuid_gen->create_str();

    my $result = $svc_discover->ProbeOp(
        { # WSDiscovery::Types::ProbeType
        Types => 'http://www.onvif.org/ver10/network/wsdl:NetworkVideoTransmitter http://www.onvif.org/ver10/device/wsdl:Device', # QNameListType
        Scopes =>  { value => '' },
        },
        WSDiscovery10::Elements::Header->new({
          Action => { value => 'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe' },
          MessageID => { value => "urn:uuid:$uuid" },
          To => { value => 'urn:schemas-xmlsoap-org:ws:2005:04:discovery' },
          })
        );
    print $result . "\n" if $verbose;

    push @results, interpret_messages($svc_discover, \%services, @responses);
    @responses = ();
  } # end if doing soap 1.1

  if ( ( ! $soap_version ) or ( $soap_version eq '1.2' ) ) {
    if($verbose) {
      print "Probing for SOAP 1.2\n"
    }
    my $svc_discover = WSDiscovery10::Interfaces::WSDiscovery::WSDiscoveryPort->new({
#    no_dispatch => '1',
        });
    $svc_discover->set_soap_version('1.2');

# copies of the same Probe message must have the same MessageID. 
# This is not a copy. So we generate a new uuid.
    my $uuid = $uuid_gen->create_str();

# Everyone else, like the nodejs onvif code and odm only ask for NetworkVideoTransmitter
    my $result = $svc_discover->ProbeOp(
        { # WSDiscovery::Types::ProbeType
        xmlattr => { 'xmlns:dn'  => 'http://www.onvif.org/ver10/network/wsdl', },
        Types => 'dn:NetworkVideoTransmitter', # QNameListType
        Scopes =>  { value => '' },
        },
        WSDiscovery10::Elements::Header->new({
          Action => { value => 'http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe' },
          MessageID => { value => "urn:uuid:$uuid" },
          To => { value => 'urn:schemas-xmlsoap-org:ws:2005:04:discovery' },
          })
        );
    print $result . "\n" if $verbose;
    push @results, interpret_messages($svc_discover, \%services, @responses);
  } # end if doing soap 1.2
  return @results;
}

sub profiles {
  my ( $client ) = @_;

  my $result = $client->get_endpoint('media')->GetProfiles( { } ,, );
  die $result if not $result;
  if($verbose) {
    print "Received message:\n" . $result . "\n";
  }

  my $profiles = $result->get_Profiles();

  foreach  my $profile ( @{ $profiles } ) {

    my $token = $profile->attr()->get_token() ;
    print $token . ", " .
      $profile->get_Name() . ", " .
      $profile->get_VideoEncoderConfiguration()->get_Encoding() . ", " .
      $profile->get_VideoEncoderConfiguration()->get_Resolution()->get_Width() . ", " .
      $profile->get_VideoEncoderConfiguration()->get_Resolution()->get_Height() . ", " .
      $profile->get_VideoEncoderConfiguration()->get_RateControl()->get_FrameRateLimit() .
      ", ";

# Specification gives conflicting values for unicast stream types, try both.
# http://www.onvif.org/onvif/ver10/media/wsdl/media.wsdl#op.GetStreamUri
    foreach my $streamtype ( 'RTP_unicast', 'RTP-Unicast' ) {
      $result = $client->get_endpoint('media')->GetStreamUri( {
          StreamSetup =>  { # ONVIF::Media::Types::StreamSetup
          Stream => $streamtype, # StreamType
          Transport =>  { # ONVIF::Media::Types::Transport
          Protocol => 'RTSP', # TransportProtocol
          },
          },
          ProfileToken => $token, # ReferenceToken
          } ,, );
      last if $result;
    }
    die $result if not $result;
#  print $result . "\n";

    print $result->get_MediaUri()->get_Uri() .
      "\n";
  } # end foreach profile

#
# use message parser without schema validation ???
#

}

sub move {
  my ($client, $dir) = @_;

  my $result = $client->get_endpoint('ptz')->GetNodes( { } ,, );

  die $result if not $result;
  print $result . "\n";
} # end sub move

sub metadata {
  my ( $client ) = @_;
  my $result = $client->get_endpoint('media')->GetMetadataConfigurations( { } ,, );
  die $result if not $result;
  print $result . "\n";

  $result = $client->get_endpoint('media')->GetVideoAnalyticsConfigurations( { } ,, );
  die $result if not $result;
  print $result . "\n";

#  $result = $client->get_endpoint('analytics')->GetServiceCapabilities( { } ,, );
#  die $result if not $result;
#  print $result . "\n";

}



1;
__END__

=head1 NAME

ZoneMinder::ONVIF - perl module to access onvif functions for ZoneMinder

=head1 SYNOPSIS

use ZoneMinder::ONVIF;

=head1 DESCRIPTION

This is a module to contain useful functions and import all the other modules 
required for ONVIF to work.

=head2 EXPORT

None by default.

=head1 SEE ALSO

http://www.zoneminder.com

=head1 AUTHOR

Philip Coombes, E<lt>philip.coombes@zoneminder.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2001-2008  Philip Coombes

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.3 or,
at your option, any later version of Perl 5 you may have available.


=cut
