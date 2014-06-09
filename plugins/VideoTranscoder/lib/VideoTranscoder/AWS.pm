package VideoTranscoder::AWS;
use strict;
use warnings;

package VideoTranscoder::AWS::Signature;
use HTTP::Date;

sub new {
    my $class = shift;
    my ( $access_key_id, $secret, $region, $service ) = @_;
    my $self = {
        access_key_id   => $access_key_id,
        secret          => $secret,
        region          => $region,
        service         => $service,
    };
    bless $self, $class;
}

sub sign {
    my $self = shift;
    my ( $req ) = @_;
    die 'call abstract method.';
    return $req;
}

sub _datetime {
    my $self = shift;
    my ( $ctime ) = @_;
    my ( $sec, $min, $hour, $mday, $mon, $year, $wday ) = gmtime( $ctime );
    return sprintf( "%04d%02d%02dT%02d%02d%02dZ", $year+1900, $mon+1, $mday, $hour, $min, $sec );
}

sub _date {
    my $self = shift;
    my ( $ctime ) = @_;
    my( $sec, $min, $hour, $mday, $mon, $year, $wday ) = gmtime( $ctime );
    return sprintf( "%04d%02d%02d", $year+1900, $mon+1, $mday );
}

sub _request_datetime {
    my $self = shift;
    my ( $req ) = @_;
    my $amz_date = $req->headers->header( 'x-amz-date' );
    if ( $amz_date && $amz_date =~ /^\d{4}\d{2}\d{2}T\d{2}\d{2}\d{2}Z$/i ) {
        return $amz_date;
    } else {
        my $http_date = $req->headers->header( 'date' );
        my $ctime = str2time( $http_date );
        return _datetime( $ctime );
    }
}

sub _request_date {
    my $self = shift;
    my ( $req ) = @_;
    my $amz_date = $req->headers->header( 'x-amz-date' );
    if ( $amz_date && $amz_date =~ /^(\d{4}\d{2}\d{2})/i ) {
        return $1
    } else {
        my $http_date = $req->headers->header( 'date' );
        my $ctime = str2time( $http_date );
        die $http_date;
        return _date( $ctime );
    }
}

package VideoTranscoder::AWS::Signature::V4;
use base qw( VideoTranscoder::AWS::Signature );
use Digest::SHA qw(hmac_sha256_base64 sha256_hex hmac_sha256_hex hmac_sha256);
use Net::SSL;
use HTTP::Date;
use URI::Escape;
use Encode;

sub sign {
    my $self = shift;
    my ( $req ) = @_;
    my $access_key = $self->{ access_key_id };
    my $secret = $self->{ secret };
    my $region = $self->{ region };
    my $service = $self->{ service };
    
    my $http_verb = $req->method;
    my $uri = $req->uri;
    # $uri->scheme .  $uri->host . $uri->path . $uri->query ;
    my $resource = $uri->path;
    my $query = $uri->query;
    my $payload = $req->content;
    
    my $header = $req->headers();
    unless ( $header->header( 'host' ) ) {
        $header->header( 'host' => $uri->host );
    }
    
    my $t;
    if ( my $httpdate = $header->header( 'date' ) ) {
        $t = str2time( $httpdate );
    } else {
        $t = time;
    }
    $header->header( 'x-amz-date' => $self->_datetime( $t ) );
    
    my $authorization = $self->authorize( $req );
    $header->header('Authorization' => $authorization);
    
    return $req;
}

sub _hashed_canonical {
    my $self = shift;
    my ( $req ) = @_;
    my $uri = $req->uri;
    my $header = $req->headers();
    
    my @lines;
    push @lines, $req->method;
    push @lines, $uri->path;
    push @lines, $uri->query || '';

    my @header_field_names = sort { lc($a) cmp lc($b) } $header->header_field_names;
    my $canonical_headers = join( '',
        map {
            my $k = $_;
            my $v = $header->header( $k );
            $v =~ s/^\s*(.*?)\s*$/$1/;
            sprintf( "%s:%s\n", lc( $k ), $v );
        } @header_field_names
    );

    push @lines, $canonical_headers;
    push @lines, join ';', sort { $a cmp $b } map { lc } $header->header_field_names;
    if ( $header->header( 'x-amz-content-sha256' ) ) {
        push @lines, $header->header( 'x-amz-content-sha256' );
    } else {
        push @lines, sha256_hex( $req->content );
    }
    
    my $canonical = join "\n", @lines;
    
    return sha256_hex( $canonical );
}

sub _string_to_sign {
    my $self = shift;
    my ( $req ) = @_;
    my $uri = $req->uri;
    my $header = $req->headers();
    my $hashed_canonical = $self->_hashed_canonical( $req );
    my $datetime = $self->_request_datetime( $req );
    my $date = $self->_request_date( $req );
    
    my @lines;
    push @lines, "AWS4-HMAC-SHA256";
    push @lines, $datetime;
    push @lines, sprintf( "%s/%s/%s/aws4_request", $date, $self->{ region }, $self->{ service } );
    push @lines, $hashed_canonical;
    my $string_to_sign = join "\n", @lines;

    return $string_to_sign;
}

sub authorize {
    my $self = shift;
    my ( $req ) = @_;
    my $uri = $req->uri;
    my $header = $req->headers();

    my $string_to_sign = $self->_string_to_sign( $req );
    my $date = $self->_request_date( $req );

    my $k_date = hmac_sha256( $date, "AWS4" . $self->{ secret } );
    my $k_region = hmac_sha256( $self->{ region }, $k_date );
    my $k_service = hmac_sha256( $self->{ service }, $k_region );
    my $signing_key = hmac_sha256( "aws4_request", $k_service );
    my $signature = hmac_sha256_hex($string_to_sign, $signing_key);
    
    my $signed_headers = join ';', sort { $a cmp $b } map { lc } $header->header_field_names;
    my $authorization = sprintf( "AWS4-HMAC-SHA256 Credential=%s/%s/%s/%s/aws4_request, SignedHeaders=%s, Signature=%s",
                                 $self->{ access_key_id },
                                 $date,
                                 $self->{ region },
                                 $self->{ service },
                                 $signed_headers,
                                 $signature );

    return $authorization;
}

package VideoTranscoder::AWS::Client;
use MT;
use Encode;
use URI::Escape;
use LWP::UserAgent;
use base qw( MT::ErrorHandler );
use JSON;
use Digest::SHA qw( sha256_hex );

if ( MT->config->https_ca_dir ) {
    $ENV{HTTPS_CA_DIR} = MT->config->https_ca_dir;
}

sub signature { 'VideoTranscoder::AWS::Signature'; }

sub new {
    my $class = shift;
    my %args = @_;
    my $self = {};
    
    my $plugin = MT->component( 'videotranscoder' );
    my %config = (
        region => 'us-east-1',
        access_key_id =>
            $plugin->get_config_value( 'access_key_id' ),
        secret_access_key =>
            $plugin->get_config_value( 'secret_access_key' ),
    );
    foreach my $key ( %args ) {
        $config{ $key } = $args{ $key };
    }
    $self->{ config } = \%config;
    
    bless $self, $class;
}

sub config {
    my $self = shift;
    return $self->{ config };
}

sub _raw_get {
    my $self = shift;
    my ( $resource, $params, $header ) = @_;
    unless ( $params ) {
        $params = {};
    }
    my @pairs = ();
    foreach my $key ( %$params ) {
        my $val = $params->{ $key };
        my $pair = sprintf( '%s=%s', uri_escape(encode('utf-8', $key)), uri_escape(encode('utf-8', $val)) );
    }
    my $query = join '&', @pairs;
    my $url = $self->_build_resource_url( $resource, $query );
    
    my $ua = LWP::UserAgent->new;

    my $req = HTTP::Request->new('GET', $url, $header);
    $ua->agent( $self );
    
    my $sig = $self->signature->new( $self->config->{ access_key_id },
                                     $self->config->{ secret_access_key },
                                     $self->config->{ region },
                                     $self->service );
    $req = $sig->sign( $req );
 
    my $response = $ua->request( $req );
    if ( $response->is_success ) {
        return $response;
    } else {
        return $self->error( $response->content );
    }
}

sub get {
    my $self = shift;
    if ( my $response = $self->_raw_get( @_ ) ) {
        require MT::Util;
        return MT::Util::from_json( decode_utf8( $response->content ) );
    } else {
        my $error_response = $self->errstr;
        my $decoded_error_response = decode_utf8( $error_response );
        require MT::Log;
        my $log = MT::Log->new;
        $log->message( $decoded_error_response );
        $log->level( MT::Log::ERROR() );
        $log->save
            or die $log->errstr;
        return $self->error( $decoded_error_response );
    }
}

sub head {
    my $self = shift;
    my ( $resource, $params, $header ) = @_;
    unless ( $params ) {
        $params = {};
    }
    my @pairs = ();
    foreach my $key ( %$params ) {
        my $val = $params->{ $key };
        my $pair = sprintf( '%s=%s', uri_escape(encode('utf-8', $key)), uri_escape(encode('utf-8', $val)) );
    }
    my $query = join '&', @pairs;
    my $url = $self->_build_resource_url( $resource, $query );
    
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new('HEAD', $url, $header);
    $ua->agent( $self );
    
    my $sig = $self->signature->new( $self->config->{ access_key_id },
                                     $self->config->{ secret_access_key },
                                     $self->config->{ region },
                                     $self->service );
    $req = $sig->sign( $req );

    my $response = $ua->request( $req );
    if ( $response->is_success ) {
        return 1;
    } else {
        my $decoded_error_response = decode_utf8( $response->content );
        require MT::Log;
        my $log = MT::Log->new;
        $log->message( $decoded_error_response );
        $log->level( MT::Log::ERROR() );
        $log->save
            or die $log->errstr;
        return $self->error( $decoded_error_response );
    }
}

sub post {
    my $self = shift;
    my ( $resource, $body, $header ) = @_;
    my $url = $self->_build_resource_url( $resource );
    
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new( 'POST', $url, $header );
    
    $req->content( $body );
    $ua->agent( $self );
    my $sig = $self->signature->new( $self->config->{ access_key_id },
                                     $self->config->{ secret_access_key },
                                     $self->config->{ region },
                                     $self->service );
    $req = $sig->sign( $req );

    my $response = $ua->request( $req );
    if ( $response->is_success ) {
        require MT::Util;
        return MT::Util::from_json( decode_utf8( $response->content ) );
    } else {
        my $decoded_error_response = decode_utf8( $response->content );
        require MT::Log;
        my $log = MT::Log->new;
        $log->message( $decoded_error_response );
        $log->level( MT::Log::ERROR() );
        $log->save
            or die $log->errstr;
        return $self->error( $decoded_error_response );
    }
}


sub put {
    my $self = shift;
    my ( $resource, $content, $header ) = @_;
    my $url = $self->_build_resource_url( $resource );
    
    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new('PUT', $url, $header);
    
    $req->content( $content );
    $ua->agent( $self );
    my $sig = $self->signature->new( $self->config->{ access_key_id },
                                     $self->config->{ secret_access_key },
                                     $self->config->{ region },
                                     $self->service );
    $req = $sig->sign( $req );

    my $response = $ua->request( $req );
    if ( $response->is_success ) {
        return 1;
    } else {
        my $decoded_error_response = decode_utf8( $response->content );
        require MT::Log;
        my $log = MT::Log->new;
        $log->message( $decoded_error_response );
        $log->level( MT::Log::ERROR() );
        $log->save
            or die $log->errstr;
        return $self->error( $decoded_error_response );
    }
}

sub _build_resource_url {
    my $self = shift;
    my ( $resource, $query ) = @_;
    sprintf( 'https://%s.%s.amazonaws.com%s%s', $self->service, $self->config->{ region }, $resource, $query || '' );
}

sub api_version { die 'api_version'; }
sub service { die 'service'; };

package VideoTranscoder::AWS::ElasticTranscoder;
use base 'VideoTranscoder::AWS::Client';

sub new {
    my $class = shift;
    my $self = $class->SUPER::new( @_ );
    my $plugin = MT->component( 'videotranscoder' );
    $self->config->{ region } = $plugin->get_config_value( 'elastic_transcoder_region' );
    return $self;
}

sub get {
    my $self = shift;
    my ( $path, $params, $header ) = @_;
    my $resource = sprintf( '/%s/%s/', $self->api_version, $path );
    $self->SUPER::get( $resource, $params, $header );
}

sub post {
    my $self = shift;
    my ( $path, $body, $header ) = @_;
    my $resource = sprintf( '/%s/%s', $self->api_version, $path );
    $self->SUPER::post( $resource, $body, $header );
}

sub list_presets {
    my $self = shift;
    my $page_token = '';
    my @presets;
    while ( my $results = $self->get( 'presets',
                                      { Ascending => 'true', pageToken => $page_token } ) ) {
        push @presets, @{ $results->{ Presets } };
        unless ( $page_token = $results->{ NextPageToken } ) {
            last;
        }
    }
    return @presets;
}

# http://docs.aws.amazon.com/elastictranscoder/latest/developerguide/list-pipelines.html
sub list_pipelines {
    my $self = shift;
    my $page_token = '';
    my @presets;
    while ( my $results = $self->get( 'pipelines',
                                      { Ascending => 'true', pageToken => $page_token } ) ) {
        push @presets, @{ $results->{ Pipelines } };
        unless ( $page_token = $results->{ NextPageToken } ) {
            last;
        }
    }
    return @presets;
}

# http://docs.aws.amazon.com/elastictranscoder/latest/developerguide/get-pipeline.html
sub read_pipeline {
    my $self = shift;
    my ( $pipeline_id ) = @_;
    if ( my $results = $self->get( sprintf( 'pipelines/%s', $pipeline_id ) ) ) {
        return $results->{ Pipeline };
    } else {
        return;
    }
}

sub read_preset {
    my $self = shift;
    my ( $preset_id ) = @_;
    if ( my $results = $self->get( sprintf( 'presets/%s', $preset_id ) ) ) {
        return $results->{ Preset };
    } else {
        return;
    }
}

# http://docs.aws.amazon.com/elastictranscoder/latest/developerguide/create-job.html
sub create_job {
    my $self = shift;
    my ( $input_key, $output_key, $pipeline_id, $preset_id ) = @_;
    
    my $preset = $self->read_preset( $preset_id );
    
    require File::Basename;
    my ( $basename, $dirname, $ext ) = File::Basename::fileparse( $output_key, qr/\..*$/ );
    my $post_data = {
        Input   => {
            Key => $input_key,
        },
        OutputKeyPrefix => $dirname,
        Outputs => [
            {
                Key => $basename . $ext,
                ( $preset->{ Thumbnails } ? ( ThumbnailPattern => $basename . '_[{count}]' ) : () ),
                PresetId => $preset_id,
                Composition => [
                    {
                        TimeSpan    => {
                            StartTime   => '00:00:00.000',
                        }
                    }
                ],
            }
        ],
        PipelineId  => $pipeline_id
    };
    if ( $preset->{ Container } eq 'ts' ) {
        $post_data->{ Outputs }->[0]->{ Key } = $basename;
        $post_data->{ Outputs }->[0]->{ SegmentDuration } = '10';
        $post_data->{ Playlists } = [
            {
                Format => 'HLSv3',
                Name => $basename . '_master',
                OutputKeys => [
                    $basename
                ],
            }
        ];
    }
    require MT::Util;
    my $json = MT::Util::to_json( $post_data );
    my $headers = [
        'Content-Length'    => length( $json ),
        'Content-Type'      => 'application/json; charset=UTF-8',
        'Accept'            => '*/*',
    ];
    if ( my $results = $self->post( 'jobs', $json, $headers ) ) {
        return $results->{ Job };
    } else {
        return;
    }
}

sub read_job {
    my $self = shift;
    my ( $job_id ) = @_;
    if ( my $results = $self->get( sprintf( 'jobs/%s', $job_id ) ) ) {
        return $results->{ Job };
    } else {
        return;
    }
}

sub api_version { '2012-09-25'; };
sub service { 'elastictranscoder'; };
sub signature { 'VideoTranscoder::AWS::Signature::V4'; }

package VideoTranscoder::AWS::S3;
use base 'VideoTranscoder::AWS::Client';
use Encode;
use Digest::SHA qw( sha256_hex );

sub new {
    my $class = shift;
    my $self = $class->SUPER::new( @_ );
    my $plugin = MT->component( 'videotranscoder' );
    $self->config->{ region } = $plugin->get_config_value( 's3_region' );
    return $self;
}


sub get {
    my $self = shift;
    my ( $object_name, $params, $header ) = @_;
    my $resource = sprintf( '/%s', $object_name );
    $self->SUPER::get( $resource, $params, $header );
}

sub _raw_get {
    my $self = shift;
    my ( $object_name, $params, $header ) = @_;
    my $resource = sprintf( '/%s', $object_name );
    $self->SUPER::_raw_get( $resource, $params, $header );
}

sub head {
    my $self = shift;
    my ( $object_name, $params, $header ) = @_;
    my $resource = sprintf( '/%s', $object_name );
    $self->SUPER::head( $resource, $params, $header );
}

sub put {
    my $self = shift;
    my ( $object_name, $params, $header ) = @_;
    my $resource = sprintf( '/%s', $object_name );
    $self->SUPER::put( $resource, $params, $header );
}

sub post {
    my $self = shift;
    my ( $object_name, $params, $header ) = @_;
    my $resource = sprintf( '/%s', $object_name );
    $self->SUPER::post( $resource, $params, $header );
}

# http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectHEAD.html
sub head_object {
    my $self = shift;
    my ( $object_name ) = @_;
    if ( my $binary = $self->head( $object_name, {}, [ 'x-amz-content-sha256' => 'SHA256' ] ) ) {
        return $binary;
    } else {
        return;
    }
}

sub put_object {
    my $self = shift;
    my ( $object_name, $bytes, $mime_type ) = @_;
    my $headers = [
        'Content-Type'  => $mime_type,
        'Content-Length'  => length( $bytes ),
        'x-amz-content-sha256' => sha256_hex( $bytes ),
        'x-amz-storage-class' => 'REDUCED_REDUNDANCY',
    ];
    if ( my $results = $self->put( $object_name, $bytes, $headers  ) ) {
        return 1;
    } else {
        return;
    }
}

sub get_object {
    my $self = shift;
    my ( $object_name ) = @_;
    my $response = $self->_raw_get( $object_name, {}, [ 'x-amz-content-sha256' => 'SHA256' ] );
    if ( $response ) {
        return $response->content, $response->headers->header( 'Content-Type' );
    } else {
        return;
    }
}

sub _build_resource_url {
    my $self = shift;
    my ( $resource, $query ) = @_;
    sprintf( 'http://%s.s3.amazonaws.com%s%s', $self->config->{ bucket_name }, $resource, $query || '' );
}

sub api_version { '2006-03-01'; };
sub service { 's3'; };
sub signature { 'VideoTranscoder::AWS::Signature::V4'; }

1;