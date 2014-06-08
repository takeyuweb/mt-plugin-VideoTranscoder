package VideoTranscoder::Plugin;
use strict;
use warnings;
use VideoTranscoder::AWS;

sub _new_transcode_job {
    my $app = shift;
    my $blog = $app->blog;
    my $blog_id = $blog->id;
    if ( $app->param( 'all_selected' ) ) {
        $app->setup_filtered_ids;
    }
    my @ids = $app->param( 'id' );
    my $ets = VideoTranscoder::AWS::ElasticTranscoder->new;
    my @presets = $ets->list_presets;
    my @pipelines = $ets->list_pipelines();
    my %params = (
        blog_id     => $blog->id,
        ids         => \@ids,
        presets     => \@presets,
        pipelines   => \@pipelines,
    );
    $app->build_page('new_transcode_job.tmpl', \%params);
}

sub _save_transcode_job {
    my $app = shift;
    my $blog = $app->blog;
    my $blog_id = $blog->id;
    $app->validate_magic() or
        return $app->errtrans( 'Invalid request.' );
    my @ids = $app->param( 'id' );
    my $preset_id = $app->param( 'preset_id' );
    my $pipeline_id = $app->param( 'pipeline_id' );
    my $added = 0;
    foreach my $id ( @ids ) {
        my $asset = MT->model( 'asset' )->load( $id ) or next;
        my $job = MT->model( 'videotranscoder_job' )->new;
        $job->blog_id( $blog_id );
        $job->name( $asset->label );
        $job->asset_id( $asset->id );
        $job->ets_preset_id( $preset_id );
        $job->ets_pipeline_id( $pipeline_id );
        $job->ets_job_status( undef );
        $job->ets_job_body( undef );
        $job->status( 0 );
        $job->save or die $job->errstr;
        $added++;
    }
    $app->redirect(
        $app->uri(
            mode => 'list',
            args => {
                blog_id => $blog_id,
                added   => $added,
                _type   => 'videotranscoder_job',
            }
        )
    );
}

sub _do_lanch_transcoder_jobs {
    my $job_iter =MT->model( 'videotranscoder_job' )->load_iter( { status => 0 } );
    while ( my $job = $job_iter->() ) {
        $job->run();
    }
}

sub _do_poll_transcoder_jobs {
    my $job_iter =MT->model( 'videotranscoder_job' )->load_iter( { status => 1 } );
    while ( my $job = $job_iter->() ) {
        $job->run();
    }
}

1;