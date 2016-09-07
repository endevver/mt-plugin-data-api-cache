package DataAPICache::Plugin;

use strict;
use warnings;

use Sub::Install;
use Digest::MD5 qw( md5_hex );
use Encode qw(encode_utf8);

sub init_app {
    my ( $cb, $app, %args ) = @_;

    # Override to add caching to all requests.
    Sub::Install::reinstall_sub({
        code => \&api,
        into => 'MT::App::DataAPI',
        as   => 'api'
    });
}

# Add a cache to all requests. (This is really just MT::App::DataAPI::api
# with some changes to add a cache for requests.)
sub api {
    my ($app) = @_;
    my ( $version, $path ) = $app->_version_path;

    return $app->print_error( 'API Version is required', 400 )
        unless defined $version;

    my $request_method = $app->_request_method
        or return;
    my ( $endpoint, $params )
        = $app->find_endpoint_by_path( $request_method, $version, $path )
        or return
        lc($request_method) eq 'options'
        ? $app->default_options_response
        : $app->print_error( 'Unknown endpoint', 404 );
    my $user = $app->authenticate;

    if ( !$user || ( $endpoint->{requires_login} && $user->is_anonymous ) ) {
        return $app->print_error( 'Unauthorized', 401 );
    }
    $user ||= MT::Author->anonymous;
    $app->user($user);
    $app->permissions(undef);

    # Should we use the cache?
    my ($cache, $cache_key);
    unless ( $app->param('no_cache') ) {
        # MT::Cache::Negotiate will use Memcached if available and fall back to
        # storing data in MT::Session.
        require MT::Cache::Negotiate;

        # The cache TTL can be supplied in the request, or fall back to a 60
        # second cache. One minute is probably a good and safe starting point.
        my $ttl = $app->param('cache_ttl') || 60;

        $cache = MT::Cache::Negotiate->new(
            ttl       => $ttl,
            kind      => 'DA', # for MT:Session; as in *D*ata *A*PI
            expirable => 1,    # for Memcached
        );

        # The cache key needs to be 80 characters or less for the MT::Session
        # table. Hopefully the endpoint ID is short? md5_hex creates a
        # 22-character string, so that leaves a max of 57 characters for the
        # endpoint ID, and one for the colon.
        $cache_key = join(':',
            $endpoint->{id},
            md5_hex(
                encode_utf8($ENV{'REQUEST_URI'}),
                encode_utf8($ENV{'QUERY_STRING'})
            )
        );
        $cache_key =~ s! !_!g;

        my $json = $cache->get( $cache_key );

        if ( $json ) {
            $app->send_http_header( 'application/json' );
            $app->{no_print_body} = 1;
            $app->print_encode($json);
            return;
        }
    }

    if ( defined $params->{site_id} ) {
        my $id = $params->{site_id};
        if ($id) {
            my $site = $app->blog( scalar $app->model('blog')->load($id) )
                or return $app->print_error( 'Site not found', 404 );
        }
        $app->param( 'blog_id', $id );

        require MT::CMS::Blog;
        if (   !$user->is_superuser
            && !MT::CMS::Blog::data_api_is_enabled( $app, $id ) )
        {
            return $app->print_error(403);
        }

        $app->permissions( $user->permissions($id) )
            unless $user->is_anonymous;
    }
    else {
        $app->param( 'blog_id', undef );
    }

    foreach my $k (%$params) {
        $app->param( $k, $params->{$k} );
    }
    if ( my $default_params = $endpoint->{default_params} ) {
        my $request_param = $app->param->Vars;
        foreach my $k (%$default_params) {
            if ( !exists( $request_param->{$k} ) ) {
                $app->param( $k, $default_params->{$k} );
            }
        }
    }

    $endpoint->{handler_ref}
        ||= $app->handler_to_coderef( $endpoint->{handler} )
        or return $app->print_error( 'Unknown endpoint', 404 );

    $app->current_endpoint($endpoint);
    $app->current_api_version($version);

    $app->run_callbacks( 'pre_run_data_api.' . $endpoint->{id},
        $app, $endpoint );
    my $response = $endpoint->{handler_ref}->( $app, $endpoint );
    $app->run_callbacks( 'post_run_data_api.' . $endpoint->{id},
        $app, $endpoint, $response );

    my $response_ref = ref $response;

    if (   UNIVERSAL::isa( $response, 'MT::Object' )
        || $response_ref =~ m/\A(?:HASH|ARRAY|MT::DataAPI::Resource::Type::)/
        || UNIVERSAL::can( $response, 'to_resource' ) )
    {
        my $format   = $app->current_format;
        my $fields   = $app->param('fields') || '';
        my $resource = $app->object_to_resource( $response,
            $fields ? [ split ',', $fields ] : undef );
        my $data = $format->{serialize}->($resource);

        # Save the $data to the cache!
        $cache->set( $cache_key => $data )
            unless $app->param('no_cache');

        if ( $app->requires_plain_text_result ) {
            $app->send_http_header('text/plain');
        }
        else {
            $app->send_http_header( $format->{mime_type} );
        }

        $app->{no_print_body} = 1;
        $app->print_encode($data);
        undef;
    }
    elsif ( lc($request_method) eq 'options' && !$response ) {
        $app->send_http_header();
        $app->{no_print_body} = 1;
        undef;
    }
    else {
        $response;
    }
}

1;

__END__
