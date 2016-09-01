# Data API Cache

This plugin adds a request-level cache to the Movable Type Data API. By
default, all requests will be cached for 60 seconds. If set up, the cache will
be stored in Memcached, otherwise in MT::Session records.

# Additional Arguments

Installing this plugin is all that's required to start caching requests. But,
you may want to include some additional arguments in your requests to override
the default behavior of this plugin:

* `no_cache`: do not cache this result; by default caching is enabled, of
  course. Example: `no_cache=1`.

* `cache_ttl`: specify the cache TTL in seconds. The default is 60 seconds,
  which is likely a good starting point. Example to cache for five minutes:
  `cache_ttl=300`.

# License

This plugin is licensed under the same terms as Perl itself.

# Copyright

Copyright 2016, Endevver LLC. All rights reserved.
