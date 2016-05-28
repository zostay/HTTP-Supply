#!smackup
use v6;

use Test;
use HTTP::Request::Supply;

my @chunk-sizes = 1, 3, 11, 101, 1009;
my @tests =
    {
        source   => 'http-1.0-close.txt',
        expected => $[{
            REQUEST_METHOD     => 'POST',
            REQUEST_URI        => '/index.html',
            SERVER_PROTOCOL    => 'HTTP/1.0',
            CONTENT_TYPE       => 'application/x-www-form-urlencoded; charset=utf8',
            CONTENT_LENGTH     => '11',
            HTTP_AUTHORIZATION => 'Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==',
            HTTP_REFERER       => 'http://example.com/awesome.html',
            HTTP_CONNECTION    => 'close',
            HTTP_USER_AGENT    => 'Mozilla/Inf',
            'p6w.input'        => 'a=1&b=2&c=3',
        }],
    },
    {
        source   => 'http-1.0-dumb.txt',
        expected => $[{
            REQUEST_METHOD     => 'POST',
            REQUEST_URI        => '/index.html',
            SERVER_PROTOCOL    => 'HTTP/1.0',
            CONTENT_TYPE       => 'application/x-www-form-urlencoded; charset=utf8',
            CONTENT_LENGTH     => '11',
            HTTP_AUTHORIZATION => 'Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==',
            HTTP_REFERER       => 'http://example.com/awesome.html',
            HTTP_USER_AGENT    => 'Mozilla/Inf',
            'p6w.input'        => 'a=1&b=2&c=3',
        }],
    },
    {
        source   => 'http-1.0-keep-alive.txt',
        expected => $[{
            REQUEST_METHOD     => 'POST',
            REQUEST_URI        => '/index.html',
            SERVER_PROTOCOL    => 'HTTP/1.0',
            CONTENT_TYPE       => 'application/x-www-form-urlencoded; charset=utf8',
            CONTENT_LENGTH     => '11',
            HTTP_AUTHORIZATION => 'Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==',
            HTTP_REFERER       => 'http://example.com/awesome.html',
            HTTP_USER_AGENT    => 'Mozilla/Inf',
            HTTP_CONNECTION    => 'Keep-Alive',
            'p6w.input'        => 'a=1&b=2&c=3',
        }],
    },
;

plan @tests * @chunk-sizes * 4;

sub run-test($envs, @expected) {
    react {
        whenever $envs -> %env {
            my %exp = @expected.shift;

            flunk 'unexpected environment received: ', %env.perl
                unless %exp.defined;

            my $input   = %env<p6w.input> :delete;
            my $content = %exp<p6w.input> :delete;

            is-deeply %env, %exp, 'environment looks good';

            ok $input.defined, 'input found in environment';

            my $acc = buf8.new;
            react {
                whenever $input -> $chunk {
                    $acc ~= $chunk;
                }
                $input.wait;
            }

            is $acc.decode('utf8'), $content, 'message body looks good';

            LAST {
                is @expected.elems, 0, 'no more requests expected';
            }

            QUIT {
                warn $_;
                flunk $_;
            }
        }
    }
}

for @tests -> $test {

    # Run the tests at various chunk sizes
    for @chunk-sizes -> $chunk-size {
        my $test-file = "t/data/$test<source>".IO;
        my $envs = HTTP::Request::Supply.parse-http(
            $test-file.open(:r).Supply(:size($chunk-size), :bin)
        );

        my @expected = $test<expected>;

        run-test($envs, @expected);

        CATCH {
            default {
                warn $_;
                flunk $_;
            }
        }
    }
}
