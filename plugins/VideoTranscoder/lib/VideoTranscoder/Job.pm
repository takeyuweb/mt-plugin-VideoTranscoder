package VideoTranscoder::Job;
use strict;
use base qw( MT::Object );

__PACKAGE__->install_properties(
    {
        column_defs => {
            id              => 'integer not null auto_increment',
            status          => 'smallint not null default 0',
            blog_id         => 'integer not null',
            name            => 'string(255)',
            asset_id        => 'integer not null',
            ets_pipeline_id => 'string(255) not null',
            ets_pipeline_name => 'string(255) not null',
            ets_preset_id   => 'string(255) not null',
            ets_preset_name => 'string(255) not null',
            ets_job_id      => 'string(255)',
            ets_job_status  => 'string(255)',
            ets_job_body    => 'text',
        },
        indexes     => {
            status          => 1,
            blog_id         => 1,
            ets_pipeline_id => 1,
            ets_preset_id   => 1,
            asset_id        => 1,
            created_by      => 1,
        },
        audit       => 1,
        datasource  => 'videotranscoder_job',
        primary_key => 'id',
    }
);

sub save {
    my $job = shift;
    unless ( undef ( my $ets_pipeline_name = $job->ets_pipeline_name ) ) {
        $job->ets_pipeline_name( $job->_pipeline()->{ Name } );
    }
    unless ( undef ( my $ets_preset_name = $job->ets_preset_name ) ) {
        $job->ets_preset_name( $job->_preset()->{ Name } );
    }
    $job->SUPER::save( @_ );
}

sub blog {
    my $job = shift;
    $job->cache_property(
        'blog',
        sub {
            require MT::Blog;
            MT::Blog->load( $job->blog_id );
        },
        @_
    );
}

sub asset {
    my $job = shift;
    $job->cache_property(
        'asset',
        sub {
            require MT::Asset;
            if ( $job->asset_id ) {
                return
                    scalar MT::Asset->load( $job->asset_id );
            }
        },
        @_
    );
}

sub _pipeline {
    my $job = shift;
    $job->cache_property(
        'pipeline',
        sub {
            require VideoTranscoder::AWS;
            my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
            my $pipeline = $ets->read_pipeline( $job->ets_pipeline_id );
            return $pipeline;
        },
        @_
    );
}

sub _preset {
    my $job = shift;
    $job->cache_property(
        'preset',
        sub {
            require VideoTranscoder::AWS;
            my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
            my $preset = $ets->read_preset( $job->ets_preset_id );
            return $preset;
        },
        @_
    );
}

sub _job {
    my $job = shift;
    $job->cache_property(
        'job',
        sub {
            require VideoTranscoder::AWS;
            my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
            my $ets_job = $ets->read_job( $job->ets_job_id );
            return $ets_job;
        },
        @_
    );
}

sub _thumbnail_format {
    my $job = shift;
    my $preset = $job->_preset;
    if ( $preset && $preset->{ Thumbnails } ) {
        return $preset->{ Thumbnails }->{ Format };
    } else {
        return;
    }
}

sub is_video {
    my $job = shift;
    my $preset = $job->_preset;
    $preset && $preset->{ Video } ? 1 : 0;
}

sub is_audio {
    my $job = shift;
    my $preset = $job->_preset;
    $preset && $preset->{ Audio } ? 1 : 0;
}

sub _input_bucket {
    my $job = shift;
    $job->_pipeline ?
        $job->_pipeline()->{ InputBucket } :
        undef;
}

sub _output_bucket {
    my $job = shift;
    $job->_pipeline ? 
        $job->_pipeline()->{ OutputBucket } :
        undef;
}

sub input_key {
    my $job = shift;
    if ( $job->_pipeline && $job->asset ) {
        File::Spec->catfile( 'upload',
                             sprintf( '%d.%s',
                                      $job->id,
                                      $job->asset->file_ext ) );
    }
}

sub output_key {
    my $job = shift;
    if ( $job->_pipeline && $job->asset && $job->_preset ) {
        my $container = $job->_preset()->{ Container };
        File::Spec->catfile( 'encoded',
                             sprintf( '%d.%s',
                                      $job->id,
                                      $container ) );
    }
}

sub run {
    my $job = shift;
    if ( $job->status == 0 ) {
        $job->_create_ets_job();
    } elsif ( $job->status == 1 ) {
        $job->_check_ets_job();
    }
}

sub _create_ets_job {
    my $job = shift;
    if ( $job->_input_bucket && $job->input_key ) {
        require VideoTranscoder::AWS;
        my $upload = VideoTranscoder::AWS::S3->new( bucket_name => $job->_input_bucket );
        unless ( $upload->head_object( $job->input_key ) ) {
            require MT::FileMgr;
            my $fmgr = $job->blog->file_mgr || MT::FileMgr->new( 'Local' );
            my $bytes = $fmgr->get_data( $job->asset->file_path, 'upload' );
            $upload->put_object( $job->input_key, $bytes, $job->asset->mime_type );
            unless ( $upload->head_object( $job->input_key ) ) {
                die 'upload failed';
            }
        }
        my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
        my $ets_job = $ets->create_job( $job->input_key, $job->output_key, $job->ets_pipeline_id, $job->ets_preset_id );
        unless ( $ets_job ) {
            die 'create ElasticTranscoder job failed.:' . $ets->errstr;
        }
        $job->ets_job_id( $ets_job->{ Id } );
        $job->ets_job_status( $ets_job->{ Status } );
        require MT::Util;
        my $json = MT::Util::to_json( $ets_job );
        $job->ets_job_body( $json );
        $job->status( 1 );
        my @ts = MT::Util::offset_time_list( time, $job->blog_id );
        my $ts = sprintf '%04d%02d%02d%02d%02d%02d',
            $ts[5] + 1900, $ts[4] + 1, @ts[ 3, 2, 1, 0 ];
        $job->modified_on( $ts );
        $job->save or die $job->errstr;
        return 1;
    }
    return 0;
}

sub _check_ets_job {
    my $job = shift;
    
    my $ets_job = $job->_job;
    unless ( $ets_job ) {
        die 'create ElasticTranscoder job failed.';
    }
    $job->ets_job_status( $ets_job->{ Status } );
    require MT::Util;
    my $json = MT::Util::to_json( $ets_job );
    $job->ets_job_body( $json );
    if ( $ets_job->{ Status } eq 'Complete' ) {
        $job->status( 2 );
        $job->_create_children();
    } elsif ( $ets_job->{ Status } eq 'Canceled' ) {
        $job->status( 3 );
    } elsif ( $ets_job->{ Status } eq 'Error' ) {
        $job->status( 4 );
    }
    my @ts = MT::Util::offset_time_list( time, $job->blog_id );
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d',
        $ts[5] + 1900, $ts[4] + 1, @ts[ 3, 2, 1, 0 ];
    $job->modified_on( $ts );
    $job->save or die $job->errstr;
    return 1;
}

sub _create_children {
    my $job = shift;
    require VideoTranscoder::AWS;
    my $encoded = VideoTranscoder::AWS::S3->new( bucket_name => $job->_output_bucket );
    my $ets_job = $job->_job;
    my $container = $job->_preset()->{ Container };
    my $child_asset;
    if ( $container eq 'ts' &&
            $ets_job->{ Playlists } &&
            $ets_job->{ Playlists }->[0] &&
            $ets_job->{ Playlists }->[0]->{ Name } ) {
        my $playlist_key = File::Spec->catfile( $ets_job->{ OutputKeyPrefix } || '',
                                                $ets_job->{ Output }->{ Key } . '.m3u8' );
        my ( $playlist, $playlist_mime_type ) = $encoded->get_object( $playlist_key ) or die $encoded->errstr;
        $child_asset = $job->_save_child( sprintf( '%s.%s', $ets_job->{ Output }->{ Key }, 'm3u8' ), $playlist_mime_type, $playlist );
        my @playlist_lines = split "\n", $playlist;
        my @ts_assets = ();
        foreach my $line ( @playlist_lines ) {
            next if $line =~ /^#/;
            next unless $line =~ /\.ts$/;
            my $ts_name = $line;
            my $ts_key = File::Spec->catfile( $ets_job->{ OutputKeyPrefix } || '',
                                              $ts_name );
            my ( $ts, $ts_mime_type ) = $encoded->get_object( $ts_key ) or die $encoded->errstr;
            my $ts_asset = $job->_save_child( $ts_name, $ts_mime_type, $ts, $child_asset );
        }
    } else {
        my ( $data, $output_mime_type ) = $encoded->get_object( $job->output_key );
        unless ( $data ) {
            require MT::Log;
            my $log = MT::Log->new;
            $log->message( $encoded->errstr );
            $log->level( MT::Log::ERROR() );
            $log->save
                or die $log->errstr;
            return 0;
        }
        my $mime_type = $output_mime_type;
        $child_asset = $job->_save_child( sprintf( '%d.%s', $job->id, $container ),
                                          $mime_type,
                                          $data );
    }
    
    if ( my $thumbnail_format = $job->_thumbnail_format ) {
        require File::Basename;
        my ( $child_basename, $child_dirname, $child_ext ) =
            File::Basename::fileparse( $job->output_key, qr/\..*$/ );
        my $thumbnail_key = File::Spec->catfile( $child_dirname,
                                                 $child_basename . '_[00001].' . $thumbnail_format);
        my ( $thumbnail, $thumbnail_mime_type ) = $encoded->get_object( $thumbnail_key );
        $job->_save_child( sprintf( '%d.%s', $job->id, $thumbnail_format ),
                           $thumbnail_mime_type,
                           $thumbnail,
                           $child_asset );
    }
    
    return $child_asset;
}

sub _save_child {
    my $job = shift;
    my ( $output_name, $mime_type, $data, $parent ) = @_;
    
    require File::Basename;
    my ( $basename, $dirname, $ext ) = File::Basename::fileparse( $job->asset->file_path, qr/\..*$/ );
    my $output_dir = File::Spec->catfile( $dirname, $basename, $job->id );
    my $output_ext = (  File::Basename::fileparse( $output_name, qr/\..*$/ ) )[2];
    
    # 書き込む際日本語ファイル名で書き込めないので内部文字列からUTF-8に
    require Encode;
    $output_dir = Encode::encode_utf8( $output_dir );
    $output_name = Encode::encode_utf8( $output_name );
    my $output_path = File::Spec->catfile( $output_dir, $output_name );
    my $fmgr = $job->blog->file_mgr || MT::FileMgr->new( 'Local' );
    $fmgr->mkpath( $output_dir ) or die $fmgr->errstr;
    $fmgr->put_data( $data, $output_path ) or die $fmgr->errstr;
    
    # 内部文字列に戻す
    $output_dir = Encode::decode_utf8( $output_dir );
    $output_name = Encode::decode_utf8( $output_name );
    $output_path = Encode::decode_utf8( $output_path );
    
    require MT::Util;
    #my $asset_pkg = MT->model( 'asset' )->handler_for_file( $output_name );
    my $asset_pkg;
    if ( $mime_type =~ /^video\// ) {
        $asset_pkg = MT->model( 'video' );
    } elsif ( $mime_type =~ /^audio\// ) {
        $asset_pkg = MT->model( 'audio' );
    } elsif ( $mime_type =~ /^image\// ) {
        $asset_pkg = MT->model( 'image' );
    } else {
        $asset_pkg = MT->model( 'asset' );
    }
    my $asset = $asset_pkg->new();
    $asset->mime_type( $mime_type );
    $asset->blog_id( $job->asset->blog_id );
    $asset->label( sprintf( '%s (%s)', $output_name, $job->asset->label ) );
    
    my $site_path = $job->blog->site_path;
    my $rel_path = File::Spec->abs2rel($output_path, $site_path );
    $rel_path =~ s/\\/\//;
    my @rel_path_parts = map{ MT::Util::encode_url( $_ ) } split '/', $rel_path;
    $asset->url( '%r/' . join( '/', @rel_path_parts ) );
    $asset->file_path( '%r/' . $rel_path );
    
    $asset->description( $job->asset->description );
    $asset->file_name( $output_name );
    $asset->file_ext( $output_ext );
    $asset->parent( $parent ? $parent->id : $job->asset_id );
    $asset->created_by( $job->created_by );
    require MT::Util;
    $asset->created_on( MT::Util::epoch2ts( $job->blog, time ) );
    $asset->save or die $asset->errstr;
    return $asset;
}

1;